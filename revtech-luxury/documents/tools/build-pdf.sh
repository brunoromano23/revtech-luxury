#!/usr/bin/env bash
#
# Renders a Markdown document in documents/ to a print-styled PDF.
#
#   ./documents/tools/build-pdf.sh documents/01-business-requirements.md
#
# Requires: node/npx (marked) and Google Chrome. Both are already present on a
# standard Salesforce dev machine, which is why this uses them instead of adding
# a pandoc/LaTeX toolchain to the project.
#
set -euo pipefail

SRC="${1:?usage: build-pdf.sh <path/to/doc.md>}"
[ -f "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${SRC%.md}.pdf"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || CHROME="$(command -v google-chrome || command -v chromium || true)"
[ -n "$CHROME" ] || { echo "Google Chrome not found" >&2; exit 1; }

echo "› rendering markdown"
npx --yes marked --gfm -i "$SRC" -o "$WORK/body.html"

echo "› assembling html"
cat "$HERE/template-head.html" "$WORK/body.html" "$HERE/template-foot.html" > "$WORK/doc.html"

# Mermaid renders the ERD client-side, so Chrome needs time on the clock for the
# CDN fetch plus layout before the page is printed.
echo "› printing pdf"
"$CHROME" --headless=new --disable-gpu --no-sandbox \
  --no-pdf-header-footer \
  --virtual-time-budget=30000 \
  --run-all-compositor-stages-before-draw \
  --print-to-pdf="$WORK/out.pdf" \
  "file://$WORK/doc.html" 2>/dev/null

mv "$WORK/out.pdf" "$OUT"
echo "✓ $OUT"
