#!/usr/bin/env bash
# One-shot setup: configure arq root and disable built-in LLM translation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAPERS_DIR="$ROOT/papers"
LOG_DIR="$ROOT/.logs"

echo "=== arq + pdf2zh setup ==="

mkdir -p "$PAPERS_DIR" "$ROOT/inbox" "$LOG_DIR"
echo "created: $PAPERS_DIR and $ROOT/inbox"
echo "created: $LOG_DIR"

if ! command -v git-lfs >/dev/null 2>&1; then
  echo "ERROR: git-lfs is required (brew install git-lfs)" >&2
  exit 1
fi
git -C "$ROOT" lfs install --local
echo "Git LFS: configured for this repository"

# PyMuPDF (figure cropping) lives in a project venv to avoid PEP 668 issues.
if [[ ! -x "$ROOT/.venv/bin/python" ]] || ! "$ROOT/.venv/bin/python" -c "import fitz" 2>/dev/null; then
  echo "installing PyMuPDF into $ROOT/.venv ..."
  uv venv "$ROOT/.venv"
  uv pip install --python "$ROOT/.venv/bin/python" pymupdf
fi
echo "PyMuPDF: $("$ROOT/.venv/bin/python" -c 'import fitz; print(fitz.pymupdf_version)')"

arq config set root "$PAPERS_DIR"
arq config set translate.enabled false
arq config set summarize.enabled false

echo ""
echo "=== current arq config ==="
arq config
echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1. ollama signin            # minimax-m3:cloud requires Ollama account"
echo "  2. scripts/install_agent.sh install   # start watchexec daemon via launchd"
echo "  3. arq get <arxiv_id>       # fetch a paper"
echo "     or: cp paper.pdf $ROOT/inbox/  # import a manually obtained PDF"
