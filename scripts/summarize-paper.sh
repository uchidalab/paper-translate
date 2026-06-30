#!/usr/bin/env bash
# Generate a Japanese structured summary (summary.md) for a paper using Ollama.
#
# Usage: summarize-paper.sh <paper_dir> [--force]
#   <paper_dir> = papers/arxiv.org/<category>/<id>
set -euo pipefail

export PATH="$PATH:/Users/ishimarutaisei/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT/.logs"
LOG_FILE="$LOG_DIR/summarize.log"

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-minimax-m3:cloud}"
SUMMARY_MAX_CHARS="${SUMMARY_MAX_CHARS:-50000}"

dir="${1:-}"
force=0
[[ "${2:-}" == "--force" ]] && force=1

mkdir -p "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "usage: $0 <paper_dir> [--force]" >&2
  exit 2
fi

pdf="$dir/paper.pdf"
out="$dir/summary.md"

if [[ ! -f "$pdf" ]]; then
  log "SKIP: no paper.pdf in $dir"
  exit 0
fi
if [[ -f "$out" && "$force" -eq 0 ]]; then
  log "SKIP: summary.md already exists in $dir"
  exit 0
fi

for t in pdftotext ollama; do
  command -v "$t" >/dev/null 2>&1 || { log "ERROR: $t not found in PATH"; exit 1; }
done

log "summarizing: $pdf"

# Extract a title from either arq or manual metadata for a better heading.
title=""
if command -v jq >/dev/null 2>&1; then
  title="$(bash "$SCRIPT_DIR/paper-metadata.sh" "$dir" 2>/dev/null | jq -r '.title // ""' || true)"
fi

body="$(pdftotext "$pdf" - 2>/dev/null | head -c "$SUMMARY_MAX_CHARS")"
if [[ -z "$body" ]]; then
  log "ERROR: pdftotext produced no text for $pdf"
  exit 1
fi

prompt="$(cat <<EOF
あなたは学術論文の要約アシスタントです。以下の論文本文（英語、先頭部分の抜粋の場合あり）を読み、
日本語で構造化された研究ノートを作成してください。前置き・後置き・コードフェンスは出力しないこと。

出力形式（Markdown）:
# ${title:-（タイトル）} まとめ

## 概要
2〜3文で論文全体を要約する。

## 背景
取り組む問題設定と既存手法の限界。

## 手法
中核となる手法を、読者が再説明できる粒度で説明する。

## 結果
主要な実験結果・評価指標・比較対象。

## 限界
限界や今後の課題。本文から読み取れない場合は「本文からは不明」と書く。

規則:
- 見出しは上記の日本語のまま。手法名・データセット名・固有名詞・評価指標は英語のままでよい。
- 数式は LaTeX (\$...\$) で保持。引用番号 [12] はそのまま残す。
- 本文に無い情報を推測で補わない。

--- 論文本文 ---
${body}
EOF
)"

# minimax-m3 is a reasoning model; --hidethinking drops the thinking block and
# --nowordwrap stops the streaming re-wrap that injects ANSI control chars.
# A final perl pass strips any residual CSI/escape sequences as a safety net.
tmp="$out.tmp.$$"
if printf '%s' "$prompt" \
    | OLLAMA_HOST="$OLLAMA_HOST" ollama run --hidethinking --nowordwrap "$OLLAMA_MODEL" 2>>"$LOG_FILE" \
    | perl -pe 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g; s/\x1b\][^\x07]*\x07//g' > "$tmp" \
    && [[ -s "$tmp" ]]; then
  mv "$tmp" "$out"
  log "done: $out"
else
  rm -f "$tmp"
  log "ERROR: ollama summarization failed for $pdf"
  exit 1
fi
