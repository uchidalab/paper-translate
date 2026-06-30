#!/usr/bin/env bash
# One idempotent watcher cycle: consume inbox PDFs, then process all papers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/import-inbox.sh" --no-process || true
bash "$SCRIPT_DIR/translate-papers-daemon.sh"
