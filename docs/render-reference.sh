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

# Render with pandoc directly, rather than through mcp-latex's
# render_markdown_to_pdf, for one reason: the title page.  That tool composes
# its LaTeX header from its own partials (common + type + layout) and passes
# the result as --include-in-header, which displaces a document's own
# `header-includes' -- so there is no way to append to the preamble from
# reference.md, and no caller hook that would let one.
#
# So the partials are read here and docs/reference-titlepage.tex is appended
# after them.  Styling still comes from mcp-latex; only the title block is
# this repository's own.  The trade-off is that the pandoc flags below
# duplicate what the server would have passed, and can drift from it -- hence
# the version pin and the list kept in one place.
preset_layout="classic"
preset_type="komabook"
pdf="$root/docs/reference.pdf"
titlepage="$root/docs/reference-titlepage.tex"

cache="$HOME/.claude/plugins/cache/mcp-latex/mcp-latex"
assets="$(ls -d "$cache"/*/mcp/assets 2>/dev/null | sort -t/ -k9 -V | tail -1)"

if [ -z "$assets" ]; then
  echo "mcp-latex assets not found under $cache; stamped only" >&2
  exit 0
fi
echo "using $(echo "$assets" | sed -E 's|.*/mcp-latex/([^/]+)/.*|mcp-latex \1|') partials"

for f in "$assets/common.tex.tmpl" \
         "$assets/types/$preset_type.tex.tmpl" \
         "$assets/layouts/$preset_layout.tex.tmpl" \
         "$titlepage"; do
  [ -r "$f" ] || { echo "missing header part: $f" >&2; exit 1; }
done

# The partials carry placeholders the server would have substituted.  Only the
# ones this document actually uses are filled; the rest are emptied, since a
# literal __TITLE__ would otherwise print on every page.
header="$(mktemp -t reference-header.XXXXXX)"
trap 'rm -f "$header"' EXIT
cat "$assets/common.tex.tmpl" \
    "$assets/types/$preset_type.tex.tmpl" \
    "$assets/layouts/$preset_layout.tex.tmpl" \
    "$titlepage" \
  | sed -e "s|__TITLE__|mcp-emacs — Source Reference|g" \
        -e "s|__DOC_STAMP__|$(date +%Y-%m-%d)|g" \
        -e "s|__HEADER_RIGHT__||g" \
        -e "s|__DOC_VERSION_SUFFIX__||g" \
        -e "s|__LOGO_PATH__||g" \
        -e "s|__LINK_COLOR__|1F4E79|g" \
  > "$header"

# Flags mirror what mcp-latex passes for classic-komabook: scrreprt, oneside,
# chapters as the top-level division, a three-level TOC.
# Image paths in the document are relative to docs/, not to wherever this was
# invoked from, so the resource path is explicit.  Without it every diagram is
# silently replaced by its alt text.
pandoc "$md" -o "$pdf" \
  --standalone \
  --from markdown \
  --resource-path="$root/docs" \
  --pdf-engine=xelatex \
  --include-in-header="$header" \
  --top-level-division=chapter \
  --toc --toc-depth=3 \
  --number-sections \
  -V documentclass=scrreprt \
  -V classoption=oneside \
  -V papersize=a4 \
  -V fontsize=11pt \
  -V geometry:margin=2.5cm \
  -V mainfont=Palatino \
  -V monofont=Menlo \
  -V colorlinks=true \
  -V linkcolor=Blue \
  -V urlcolor=Blue \
  -V toccolor=black

echo "Rendered PDF: $pdf (classic-komabook partials + local title page)"
