#!/usr/bin/env bash
# Interactive selector covering both arq and manually imported papers.
set -euo pipefail

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAPERS_DIR="$ROOT/papers"

rows="$(mktemp)"
trap 'rm -f "$rows"' EXIT
while IFS= read -r -d '' pdf; do
  dir="$(dirname "$pdf")"
  metadata="$(bash "$SCRIPT_DIR/paper-metadata.sh" "$dir" 2>/dev/null || true)"
  [[ -n "$metadata" ]] || continue
  jq -r --arg dir "$dir" '
    [
      $dir,
      (.title // .id // ""),
      ((.authors // [])[:3] | join(", ")),
      (.published // ""),
      (.id // ""),
      (.kind // "")
    ] | @tsv
  ' <<<"$metadata" >> "$rows"
done < <(find "$PAPERS_DIR" -path "$PAPERS_DIR/by-title" -prune -o -name paper.pdf -type f -print0 2>/dev/null)

if [[ ! -s "$rows" ]]; then
  echo "No papers found. Run arq get <id> or scripts/import-paper.sh <pdf>."
  exit 0
fi

selected="$(sort -t $'\t' -k4,4r "$rows" | fzf \
  --prompt 'Paper> ' \
  --with-nth=2..4 \
  --preview "$SCRIPT_DIR/paper-preview.sh {1}" \
  --preview-window=right:50%:wrap \
  --height=80%)"
[[ -n "$selected" ]] || exit 0

dir="$(cut -f1 <<<"$selected")"
id="$(cut -f5 <<<"$selected")"
kind="$(cut -f6 <<<"$selected")"
actions="Note\nPDF (English)"
[[ -f "$dir/paper_ja.pdf" ]] && actions+="\nPDF (Japanese)"
[[ "$kind" == "arxiv" ]] && actions+="\nSummary (arq browser)"
action="$(printf '%b' "$actions" | fzf --prompt 'Action> ' --height=10)"

case "$action" in
  "Note")
    note="$(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name summary.md -print -quit)"
    [[ -n "$note" ]] && open "$note"
    ;;
  "PDF (English)") open -a Skim "$dir/paper.pdf" ;;
  "PDF (Japanese)") open -a Skim "$dir/paper_ja.pdf" ;;
  "Summary (arq browser)") arq view "$id" ;;
esac
