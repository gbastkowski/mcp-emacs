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
date="$(date +%Y-%m-%d)"

# A reader wants the human-readable version first.  The commit is kept as a
# precise fallback, since a version alone cannot identify a point between
# releases.
if [ "$ahead" != "0" ]; then
  version="$version+$ahead"
fi

commit="$(git -C "$root" rev-parse --short HEAD)"

# Dirty tree means the stamp would claim a commit that does not contain the
# state being described; say so rather than lying on the title page.
if ! git -C "$root" diff --quiet -- ':!docs/reference.md' ':!docs/reference.pdf'; then
  commit="$commit+dirty"
fi

stamp="$version — $date — commit $commit"

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

command -v pandoc >/dev/null || { echo "pandoc not found; stamped only" >&2; exit 0; }
echo "Render via the mcp-latex render_markdown_to_pdf tool (preset classic-report)."
