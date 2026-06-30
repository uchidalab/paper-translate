#!/usr/bin/env bash
# Backward-compatible entrypoint for the unified paper selector.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/paper-select.sh" "$@"
