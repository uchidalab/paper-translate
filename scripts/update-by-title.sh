#!/usr/bin/env bash
# Rebuild papers/by-title symlinks for both arq and manually imported papers.
set -euo pipefail

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAPERS_DIR="$ROOT/papers"
BYTITLE_DIR="$PAPERS_DIR/by-title"
LOG_DIR="$ROOT/.logs"
LOG_FILE="$LOG_DIR/by-title.log"

mkdir -p "$LOG_DIR"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"; }

command -v jq >/dev/null 2>&1 || { log "ERROR: jq not found"; exit 1; }

# Title -> snake_case slug: lowercase, non-alnum runs -> "_", trim edges.
sanitize_title() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^[:alnum:]]+/_/g; s/^_+//; s/_+$//'
}

# Rebuild from scratch so stale links are removed.
rm -rf "$BYTITLE_DIR"
mkdir -p "$BYTITLE_DIR"

count=0
while IFS= read -r -d '' pdf; do
  dir="$(dirname "$pdf")"
  metadata="$(bash "$SCRIPT_DIR/paper-metadata.sh" "$dir" 2>/dev/null || true)"
  [[ -n "$metadata" ]] || continue
  id="$(jq -r '.id // ""' <<<"$metadata")"
  title="$(jq -r '.title // ""' <<<"$metadata")"
  [[ -z "$title" ]] && title="$id"
  name="$(sanitize_title "$title")"
  [[ -z "$name" ]] && name="$id"

  link="$BYTITLE_DIR/$name"
  if [[ -e "$link" || -L "$link" ]]; then
    name="${name}_${id//./_}"
    link="$BYTITLE_DIR/$name"
  fi

  # Relative target from papers/by-title/ to any managed paper directory.
  rel="../${dir#$PAPERS_DIR/}"
  ln -s "$rel" "$link"
  count=$((count + 1))
done < <(find "$PAPERS_DIR" -path "$BYTITLE_DIR" -prune -o -name paper.pdf -type f -print0 2>/dev/null)

log "rebuilt by-title: $count link(s)"
