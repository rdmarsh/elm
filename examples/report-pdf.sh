#!/bin/sh
# report-pdf.sh -- turn a Markdown page into a PDF with examples/report.css.
#
# Usage:
#   examples/report-pdf.sh FILE.md [OUT.pdf]      (OUT defaults to FILE.pdf)
#
# Markdown -> HTML (pandoc) -> PDF (weasyprint), styled by report.css: A4
# landscape for wide tables, a small font, header rows repeated on each page,
# page numbers. Made for compare-portals.sh's page, but any Markdown works:
#
#   examples/compare-portals.sh prod,preprod,test critical.txt > differences.md
#   examples/report-pdf.sh differences.md
#
# Needs pandoc and weasyprint (macOS: brew install pandoc weasyprint). Without
# weasyprint it still writes the HTML: open that in a browser and print it to
# PDF, which applies the same styles.

set -eu
md=${1:?usage: $0 FILE.md [OUT.pdf]}
pdf=${2:-${md%.md}.pdf}
html=${pdf%.pdf}.html
css="$(dirname "$0")/report.css"

command -v pandoc >/dev/null || { echo "report-pdf: pandoc not found (brew install pandoc)" >&2; exit 1; }

# the page's first heading names the document (pagetitle sets <title> only, so
# it is not printed a second time)
title=$(sed -n 's/^# //p' "$md" | head -1)
pandoc "$md" -s --embed-resources -c "$css" --metadata pagetitle="${title:-Report}" -o "$html"

if command -v weasyprint >/dev/null; then
    # weasyprint warns about pandoc's screen-only styles and font subsetting; not useful here
    weasyprint "$html" "$pdf" 2>/dev/null
    rm -f "$html"
    echo "$pdf" >&2
else
    echo "report-pdf: weasyprint not found (brew install weasyprint); wrote $html -- open it in a browser and print to PDF" >&2
    exit 1
fi
