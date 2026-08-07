#!/usr/bin/env bash
# Stamp docs/reference.md with the current version/date/commit and render it.
#
# The stamp is generated rather than hand-edited so the title page cannot
# drift from the tree the document actually describes.  Version comes from
# the plugin manifest; the commit is the one being documented.
#
# Usage: docs/render-reference.sh [--no-render]

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
md="$root/docs/reference.md"

# Version comes from `git describe`, not the plugin manifest: the manifest is
# hand-edited and had sat at 1.0.0 while the tags reached v1.5.0, so the stamp
# was quietly claiming a version nobody had shipped.  Tags are the released
# version, and `git describe` says how far past one we are.
version="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
ahead="$(git -C "$root" rev-list --count "$version..HEAD" 2>/dev/null || echo 0)"

# A reader wants the human-readable version first.  The commit is kept as a
# precise fallback, since a version alone cannot identify a point between
# releases.
if [ "$ahead" != "0" ]; then
  version="$version+$ahead"
fi

# A commit hash on the title page is noise to a reader: it identifies the
# tree precisely but means nothing to anyone not holding the repository.  The
# version does the job.  A dirty tree is still called out, because then the
# version is a claim the tree does not support.
if ! git -C "$root" diff --quiet -- ':!docs/reference.md' ':!docs/reference.pdf'; then
  version="$version (uncommitted changes)"
fi

# Version only: the komabook title block prints the render date itself, so
# repeating it here puts the same date on the page twice.
stamp="$version"

python3 - "$md" "$stamp" <<'PY'
import re, sys
path, stamp = sys.argv[1], sys.argv[2]
s = open(path).read()
new = f'date: "{stamp}"'
if re.search(r'^date: ".*"$', s, flags=re.M):
    s = re.sub(r'^date: ".*"$', new, s, count=1, flags=re.M)
else:
    s = re.sub(r'^(author: .*)$', r'\1\n' + new, s, count=1, flags=re.M)
open(path, 'w').write(s)
PY

echo "stamped: $stamp"

[ "${1:-}" = "--no-render" ] && exit 0

# Render here rather than telling a human which preset to pass.  The settings
# used to live only in whoever last invoked the tool, and the preset was duly
# lost on the next render -- the document came back as a plain report.
#
# mcp-latex ships as an MCP server with no CLI, so this speaks the protocol to
# it over stdio.  That also pins the version: the plugin cache can hold several,
# and an older server silently ignores `preset` instead of rejecting it, which
# is a slow thing to notice.
preset="classic-komabook"
pdf="$root/docs/reference.pdf"

cache="$HOME/.claude/plugins/cache/mcp-latex/mcp-latex"
server="$(ls -d "$cache"/*/mcp/dist/index.js 2>/dev/null \
            | sort -t/ -k9 -V | tail -1)"

if [ -z "$server" ]; then
  echo "mcp-latex not found under $cache; stamped only" >&2
  exit 0
fi
echo "using $(echo "$server" | sed -E 's|.*/mcp-latex/([^/]+)/.*|mcp-latex \1|')"

node - "$server" "$md" "$pdf" "$preset" <<'JS'
const { spawn } = require("node:child_process");
const readline = require("node:readline");
const [server, md, pdf, preset] = process.argv.slice(2);

const p = spawn("node", [server], { stdio: ["pipe", "pipe", "inherit"] });
const send = (o) => p.stdin.write(JSON.stringify(o) + "\n");

readline.createInterface({ input: p.stdout }).on("line", (line) => {
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.id === 1) {
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    send({ jsonrpc: "2.0", id: 2, method: "tools/call",
           params: { name: "render_markdown_to_pdf",
                     arguments: { markdown_path: md, output_path: pdf,
                                  preset } } });
  }
  if (m.id === 2) {
    const text = m.result?.content?.[0]?.text ?? JSON.stringify(m.error);
    console.log(text);
    // The server echoes the preset it actually used.  A server too old to
    // know about presets renders a default-styled PDF and says nothing, so
    // treat a missing echo as a failure rather than a success.
    p.kill();
    process.exit(text.includes(`preset: ${preset}`) ? 0 : 1);
  }
});

send({ jsonrpc: "2.0", id: 1, method: "initialize",
       params: { protocolVersion: "2024-11-05", capabilities: {},
                 clientInfo: { name: "render-reference", version: "1" } } });
JS
