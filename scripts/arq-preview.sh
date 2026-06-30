#!/usr/bin/env bash
# Backward-compatible preview accepting either an arXiv ID or paper directory.

set -euo pipefail

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

value="${1:-}"
[[ -z "$value" ]] && exit 0

if [[ -d "$value" ]]; then
  dir="$value"
else
  pdf_path="$(arq path "$value" 2>/dev/null || true)"
  [[ -n "$pdf_path" ]] || { echo "No local data for $value"; exit 0; }
  dir="$(dirname "$pdf_path")"
fi

exec "$SCRIPT_DIR/paper-preview.sh" "$dir"
