#!/usr/bin/env bash
#
# Renders a Markdown document in documents/ to a print-styled PDF.
#
#   ./documents/tools/build-pdf.sh documents/01-solution-design.md [output.pdf]
#
# Requires: node/npx (marked), and Python with weasyprint + beautifulsoup4:
#
#   brew install pango gdk-pixbuf libffi
#   pip3 install weasyprint beautifulsoup4
#
# WeasyPrint rather than headless Chrome. Chrome applies a single page size to the whole document,
# so the landscape page the ERD needs is impossible there; WeasyPrint supports named pages with
# their own size, resolves target-counter for the contents page, and runs no JavaScript — which is
# why every structural transform lives in assemble.py rather than in a browser.
#
set -euo pipefail

SRC="${1:?usage: build-pdf.sh <path/to/doc.md> [output.pdf]}"
[ -f "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$(dirname "$SRC")" && pwd)"
# The deliverable is named for a reader, not for its source file, so the output path is
# overridable. Defaults to the source name for quick local rebuilds.
OUT="${2:-${SRC%.md}.pdf}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "› rendering markdown"
npx --yes marked --gfm -i "$SRC" -o "$WORK/body.html"

echo "› assembling document"
python3 "$HERE/assemble.py" "$WORK/body.html" "$SRC_DIR" "$WORK/doc.html" "$HERE/template-head.html"

echo "› printing pdf"
python3 -m weasyprint "$WORK/doc.html" "$WORK/out.pdf" --base-url "$SRC_DIR/"

mv "$WORK/out.pdf" "$OUT"
echo "✓ $OUT"
