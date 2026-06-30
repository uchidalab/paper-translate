#!/usr/bin/env bash
# Watch arq/manual paper additions and the manual-PDF inbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$ROOT/papers" "$ROOT/inbox"

# Process anything that arrived while the watcher was stopped before subscribing.
bash "$SCRIPT_DIR/process-paper-events.sh"

exec watchexec \
  --watch "$ROOT/papers" \
  --watch "$ROOT/inbox" \
  --filter "**/*.pdf" \
  --ignore "**/paper_ja.pdf" \
  --ignore "**/*-dual.pdf" \
  --ignore "**/*-mono.pdf" \
  --debounce 30s \
  --on-busy-update queue \
  --no-meta \
  -- "$SCRIPT_DIR/process-paper-events.sh"
