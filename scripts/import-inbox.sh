#!/usr/bin/env bash
# Import every PDF currently waiting in the repository-local inbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INBOX="$ROOT/inbox"

process=1
[[ "${1:-}" == "--no-process" ]] && process=0
[[ $# -le 1 ]] || { echo "usage: $0 [--no-process]" >&2; exit 2; }

mkdir -p "$INBOX"
imported=0
failed=0
while IFS= read -r -d '' pdf; do
  if bash "$SCRIPT_DIR/import-paper.sh" "$pdf" --move-source --no-process; then
    imported=$((imported + 1))
  else
    failed=$((failed + 1))
    printf 'ERROR: import failed; retained in inbox: %s\n' "$pdf" >&2
  fi
done < <(find "$INBOX" -maxdepth 1 -type f -iname '*.pdf' -print0)

if [[ "$imported" -gt 0 && "$process" -eq 1 ]]; then
  bash "$SCRIPT_DIR/translate-papers-daemon.sh"
fi

[[ "$failed" -eq 0 ]]
