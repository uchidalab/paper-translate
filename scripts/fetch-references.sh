#!/usr/bin/env bash
# Fetch references and citations for arXiv or manually imported papers.
set -euo pipefail

export PATH="$PATH:/Users/ishimarutaisei/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT/.logs"
LOG_FILE="$LOG_DIR/references.log"

S2_LIMIT="${S2_LIMIT:-1000}"
S2_SLEEP="${S2_SLEEP:-3}"
S2_LOG_FILE="$LOG_FILE"
# shellcheck source=semantic-scholar.sh
source "$SCRIPT_DIR/semantic-scholar.sh"

dir="${1:-}"
force=0
[[ "${2:-}" == "--force" ]] && force=1

mkdir -p "$LOG_DIR"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"; }

if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "usage: $0 <paper_dir> [--force]" >&2
  exit 2
fi
for tool in curl jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { log "ERROR: $tool not found"; exit 1; }
done

out="$dir/references.json"
if [[ -f "$out" && "$force" -eq 0 ]]; then
  log "SKIP: references.json already exists in $dir"
  exit 0
fi

metadata="$(bash "$SCRIPT_DIR/paper-metadata.sh" "$dir" 2>/dev/null || true)"
[[ -n "$metadata" ]] || { log "SKIP: no supported metadata in $dir"; exit 0; }
id="$(jq -r '.id // ""' <<<"$metadata")"
title="$(jq -r '.title // ""' <<<"$metadata")"

# Resolve the local metadata to one canonical Semantic Scholar paper ID.
s2_id="$(jq -r '.identifiers.semantic_scholar // ""' <<<"$metadata")"
doi="$(jq -r '.identifiers.doi // ""' <<<"$metadata")"
arxiv="$(jq -r '.identifiers.arxiv // ""' <<<"$metadata")"
lookup_key=""
[[ -n "$s2_id" ]] && lookup_key="$s2_id"
[[ -z "$lookup_key" && -n "$doi" ]] && lookup_key="DOI:$doi"
[[ -z "$lookup_key" && -n "$arxiv" ]] && lookup_key="ARXIV:$arxiv"

paper=''
fields='paperId,title,externalIds,url'
if [[ -n "$lookup_key" ]]; then
  set +e
  paper="$(s2_lookup_key "$lookup_key" "$fields" 2>/dev/null)"
  lookup_status=$?
  set -e
  [[ "$lookup_status" -eq 1 ]] && exit 1
elif [[ -n "$title" ]]; then
  set +e
  candidate="$(s2_lookup_title "$title" "$fields" 2>/dev/null)"
  lookup_status=$?
  set -e
  [[ "$lookup_status" -eq 1 ]] && exit 1
  [[ -n "$candidate" ]] || candidate='{}'
  candidate_title="$(jq -r '.title // ""' <<<"$candidate" 2>/dev/null || true)"
  if [[ -n "$candidate_title" \
      && "$(s2_normalize_title "$candidate_title")" == "$(s2_normalize_title "$title")" ]]; then
    paper="$candidate"
  fi
fi

if [[ -z "$paper" ]]; then
  tmp="$out.tmp.$$"
  jq -n --arg id "$id" --arg title "$title" \
    '{id: $id, title: $title, status: "unmatched", matched_paper: null, references: [], citations: []}' > "$tmp"
  mv "$tmp" "$out"
  log "no exact Semantic Scholar match for $id; wrote unmatched result"
  exit 0
fi

paper_id="$(jq -r '.paperId // ""' <<<"$paper")"
[[ -n "$paper_id" ]] || { log "ERROR: Semantic Scholar response had no paperId"; exit 1; }
encoded_id="$(s2_uri_encode "$paper_id")"

log "fetching references/citations for $id via $paper_id"
refs_raw="$(s2_get "$S2_BASE/$encoded_id/references?fields=externalIds,title,url&limit=$S2_LIMIT")" || exit 1
cites_raw="$(s2_get "$S2_BASE/$encoded_id/citations?fields=externalIds,title,url&limit=$S2_LIMIT")" || exit 1

extract() {
  local key="$1"
  jq -c --arg key "$key" '
    [ .data[]? | .[$key] | select(. != null)
      | {
          paper_id: (.paperId // ""),
          arxiv_id: (.externalIds.ArXiv // "" | sub("v[0-9]+$"; "")),
          doi: (.externalIds.DOI // ""),
          title: (.title // ""),
          url: (.url // "")
        }
    ]'
}

references="$(printf '%s' "$refs_raw" | extract citedPaper)"
citations="$(printf '%s' "$cites_raw" | extract citingPaper)"
tmp="$out.tmp.$$"
if jq -n \
    --arg id "$id" \
    --argjson matched "$paper" \
    --argjson references "$references" \
    --argjson citations "$citations" \
    '{id: $id, status: "matched", matched_paper: $matched, references: $references, citations: $citations}' > "$tmp"; then
  mv "$tmp" "$out"
  log "done: $out (references=$(jq length <<<"$references"), citations=$(jq length <<<"$citations"))"
else
  rm -f "$tmp"
  log "ERROR: failed to assemble references.json for $id"
  exit 1
fi
