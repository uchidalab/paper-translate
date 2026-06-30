#!/usr/bin/env bash
# Generate an Obsidian note for one arq or manually imported paper.
set -euo pipefail

export PATH="$PATH:/Users/ishimarutaisei/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT/.logs"
LOG_FILE="$LOG_DIR/obsidian.log"

dir="${1:-}"
force=0
[[ "${2:-}" == "--force" ]] && force=1

mkdir -p "$LOG_DIR"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"; }
snake() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^[:alnum:]]+/_/g; s/^_+//; s/_+$//'
}

if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "usage: $0 <paper_dir> [--force]" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { log "ERROR: jq not found"; exit 1; }

metadata="$(bash "$SCRIPT_DIR/paper-metadata.sh" "$dir" 2>/dev/null || true)"
[[ -n "$metadata" ]] || { log "SKIP: no supported metadata in $dir"; exit 0; }

abs_dir="$(cd "$dir" && pwd)"
rel="${abs_dir#$ROOT/}"
id="$(jq -r '.id // ""' <<<"$metadata")"
[[ -n "$id" ]] || { log "ERROR: no id in metadata for $dir"; exit 1; }
title="$(jq -r '.title // ""' <<<"$metadata")"
category="$(jq -r '.category // ""' <<<"$metadata")"
published="$(jq -r '.published // ""' <<<"$metadata")"
kind="$(jq -r '.kind // ""' <<<"$metadata")"

declare -A NOTE_OF
if [[ -n "${LOCAL_MAP_FILE:-}" && -f "$LOCAL_MAP_FILE" ]]; then
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] && NOTE_OF["$key"]="$value"
  done < "$LOCAL_MAP_FILE"
fi

slug="${NOTE_OF[$id]:-$(snake "$title")}"
[[ -n "$slug" ]] || slug="$(snake "$id")"
out="$dir/$slug.md"

render_links() {
  local paper_id arxiv doi ref_title url safe key note href
  while IFS=$'\x1f' read -r paper_id arxiv doi ref_title url; do
    [[ -z "$paper_id" && -z "$arxiv" && -z "$doi" && -z "$ref_title" ]] && continue
    safe="${ref_title//[\[\]|]/ }"
    note=""
    if [[ -n "$paper_id" ]]; then
      key="s2:$paper_id"
      note="${NOTE_OF[$key]:-}"
    fi
    if [[ -z "$note" && -n "$arxiv" ]]; then
      key="arxiv:$arxiv"
      note="${NOTE_OF[$key]:-}"
    fi
    if [[ -z "$note" && -n "$doi" ]]; then
      key="doi:$(printf '%s' "$doi" | tr '[:upper:]' '[:lower:]')"
      note="${NOTE_OF[$key]:-}"
    fi
    if [[ -n "$note" ]]; then
      printf -- '- [[%s|%s]]\n' "$note" "$safe"
      continue
    fi
    href=""
    [[ -n "$arxiv" ]] && href="https://arxiv.org/abs/$arxiv"
    [[ -z "$href" && -n "$doi" ]] && href="https://doi.org/$doi"
    [[ -z "$href" && -n "$url" ]] && href="$url"
    if [[ -n "$href" ]]; then
      printf -- '- [%s](%s)\n' "$safe" "$href"
    else
      printf -- '- %s\n' "$safe"
    fi
  done
}

refs_tsv=""
cites_tsv=""
if [[ -f "$dir/references.json" ]]; then
  refs_tsv="$(jq -r '.references[]? | [(.paper_id // ""), (.arxiv_id // ""), (.doi // ""), (.title // ""), (.url // "")] | join("\u001f")' "$dir/references.json")"
  cites_tsv="$(jq -r '.citations[]? | [(.paper_id // ""), (.arxiv_id // ""), (.doi // ""), (.title // ""), (.url // "")] | join("\u001f")' "$dir/references.json")"
fi

if [[ -f "$out" && "$force" -eq 0 ]]; then
  log "SKIP: note already exists for $id"
  exit 0
fi

tmp="$out.tmp.$$"
{
  echo "---"
  printf 'id: "%s"\n' "${id//\"/\\\"}"
  printf 'title: "%s"\n' "${title//\"/\\\"}"
  printf 'aliases: ["%s"]\n' "${title//\"/\\\"}"
  jq -r '"authors:\n" + ((.authors // []) | map("  - \"" + (gsub("\\\""; "\\\\\"")) + "\"") | join("\n"))' <<<"$metadata"
  printf 'category: "%s"\n' "${category//\"/\\\"}"
  printf 'published: "%s"\n' "${published//\"/\\\"}"
  [[ -f "$dir/overview.png" ]] && echo "thumbnail: $rel/overview.png"
  echo "source_type: $kind"
  echo "tags: [paper]"
  echo "---"
  echo
  echo "# $title"
  echo
  if [[ -f "$dir/overview.png" ]]; then
    echo "![[$rel/overview.png]]"
    echo
  fi
  echo "**分野**: $category ・ **公開**: $published"
  echo
  links=()
  [[ -f "$dir/paper.pdf" ]] && links+=("[原文PDF]($rel/paper.pdf)")
  [[ -f "$dir/paper_ja.pdf" ]] && links+=("[日本語PDF]($rel/paper_ja.pdf)")
  if [[ ${#links[@]} -gt 0 ]]; then
    line="${links[0]}"
    for link in "${links[@]:1}"; do line+=" · $link"; done
    echo "$line"
    echo
  fi
  if [[ -f "$dir/summary.md" ]]; then
    echo "## 要約"
    echo
    echo "![[$rel/summary.md]]"
    echo
  fi
  echo "## 参考文献 (references)"
  echo
  [[ -n "$refs_tsv" ]] && printf '%s\n' "$refs_tsv" | render_links || echo "_（取得なし）_"
  echo
  echo "## 被引用 (citations)"
  echo
  [[ -n "$cites_tsv" ]] && printf '%s\n' "$cites_tsv" | render_links || echo "_（取得なし）_"
} > "$tmp"

mv "$tmp" "$out"
log "wrote note: $out"
