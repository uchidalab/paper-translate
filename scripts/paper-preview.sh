#!/usr/bin/env bash
# fzf preview for a managed paper directory.
set -euo pipefail

dir="${1:-}"
[[ -d "$dir" ]] || { echo "No local data for $dir"; exit 0; }

if [[ -f "$dir/summary.md" ]]; then
  cat "$dir/summary.md"
elif [[ -f "$dir/metadata.json" ]]; then
  jq . "$dir/metadata.json" 2>/dev/null || cat "$dir/metadata.json"
elif [[ -f "$dir/meta.json" ]]; then
  jq . "$dir/meta.json" 2>/dev/null || cat "$dir/meta.json"
else
  ls "$dir" 2>/dev/null || true
fi
