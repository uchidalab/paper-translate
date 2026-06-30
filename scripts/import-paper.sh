#!/usr/bin/env bash
# Import a manually obtained paper PDF into the managed library.
set -euo pipefail

export PATH="$PATH:/Users/ishimarutaisei/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANUAL_DIR="$ROOT/papers/manual"
LOG_DIR="$ROOT/.logs"
LOG_FILE="$LOG_DIR/import.log"

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-minimax-m3:cloud}"
METADATA_MAX_CHARS="${PAPER_METADATA_MAX_CHARS:-20000}"
S2_SLEEP="${S2_SLEEP:-0}"
S2_LOG_FILE="$LOG_FILE"
# shellcheck source=semantic-scholar.sh
source "$SCRIPT_DIR/semantic-scholar.sh"

usage() {
  cat >&2 <<'EOF'
usage: import-paper.sh <pdf> [options]

Options:
  --doi DOI              Identify the paper by DOI
  --arxiv ID             Identify the paper by arXiv ID
  --s2-id ID             Identify the paper by Semantic Scholar paper ID
  --title TITLE          Override the detected title
  --author NAME          Override authors (repeatable)
  --published DATE       Override publication date
  --category CATEGORY    Override category or field
  --source-url URL       Record the PDF source URL
  --no-process           Import only; do not run the processing daemon
  --move-source          Remove the source PDF after a successful import
EOF
}

log() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

snake() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^[:alnum:]]+/_/g; s/^_+//; s/_+$//'
}

s2_fields='paperId,title,authors,abstract,publicationDate,year,externalIds,url,s2FieldsOfStudy'

pdf="${1:-}"
[[ -n "$pdf" ]] || { usage; exit 2; }
shift

doi=""
arxiv=""
s2_id=""
title_override=""
published_override=""
category_override=""
source_url=""
authors_override=()
process=1
move_source=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --doi) doi="${2:-}"; shift 2 ;;
    --arxiv) arxiv="${2:-}"; shift 2 ;;
    --s2-id) s2_id="${2:-}"; shift 2 ;;
    --title) title_override="${2:-}"; shift 2 ;;
    --author) authors_override+=("${2:-}"); shift 2 ;;
    --published) published_override="${2:-}"; shift 2 ;;
    --category) category_override="${2:-}"; shift 2 ;;
    --source-url) source_url="${2:-}"; shift 2 ;;
    --no-process) process=0; shift ;;
    --move-source) move_source=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

[[ -f "$pdf" ]] || { echo "ERROR: PDF not found: $pdf" >&2; exit 1; }
for tool in jq pdfinfo pdftotext shasum python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found" >&2; exit 1; }
done
if ! pdfinfo "$pdf" >/dev/null 2>&1; then
  echo "ERROR: invalid or unreadable PDF: $pdf" >&2
  exit 1
fi

pdf="$(cd "$(dirname "$pdf")" && pwd)/$(basename "$pdf")"
sha256="$(shasum -a 256 "$pdf" | awk '{print $1}')"
mkdir -p "$MANUAL_DIR" "$LOG_DIR"

# A duplicate import is successful and consumes an inbox source when requested.
while IFS= read -r existing; do
  [[ "$existing" == "$pdf" ]] && continue
  if [[ "$(shasum -a 256 "$existing" | awk '{print $1}')" == "$sha256" ]]; then
    existing_dir="$(dirname "$existing")"
    printf '%s\n' "$existing_dir"
    log "duplicate PDF skipped: $pdf -> $existing_dir"
    [[ "$move_source" -eq 1 ]] && rm -f "$pdf"
    exit 0
  fi
done < <(find "$ROOT/papers" -path "$ROOT/papers/by-title" -prune -o -name paper.pdf -type f -print 2>/dev/null)

explicit_keys=0
[[ -n "$doi" ]] && explicit_keys=$((explicit_keys + 1))
[[ -n "$arxiv" ]] && explicit_keys=$((explicit_keys + 1))
[[ -n "$s2_id" ]] && explicit_keys=$((explicit_keys + 1))
if [[ "$explicit_keys" -gt 1 ]]; then
  echo "ERROR: specify at most one of --doi, --arxiv, and --s2-id" >&2
  exit 2
fi

s2_json=""
explicit_key=""
[[ -n "$s2_id" ]] && explicit_key="$s2_id"
[[ -n "$doi" ]] && explicit_key="DOI:$doi"
[[ -n "$arxiv" ]] && explicit_key="ARXIV:${arxiv%v[0-9]*}"
if [[ -n "$explicit_key" ]]; then
  if ! s2_json="$(s2_lookup_key "$explicit_key" "$s2_fields")"; then
    echo "ERROR: the supplied paper identifier was not found: $explicit_key" >&2
    exit 1
  fi
fi

inferred='{}'
if [[ -z "$explicit_key" ]]; then
  if [[ -n "$title_override" ]]; then
    inferred="$(jq -n --arg title "$title_override" \
      '{title:$title,authors:[],abstract:"",published:"",category:"",identifiers:{doi:"",arxiv:""}}')"
  else
    command -v ollama >/dev/null 2>&1 || { echo "ERROR: ollama not found" >&2; exit 1; }
    pdf_info="$(pdfinfo "$pdf" 2>/dev/null || true)"
    body="$(pdftotext -f 1 -l 3 "$pdf" - 2>/dev/null | head -c "$METADATA_MAX_CHARS")"
    [[ -n "$body" ]] || { echo "ERROR: no text could be extracted from $pdf" >&2; exit 1; }
    prompt="$(cat <<EOF
Extract bibliographic metadata from this academic paper. Return one JSON object only.
Use this exact shape, using empty strings or empty arrays when unknown:
{"title":"","authors":[],"abstract":"","published":"","category":"","identifiers":{"doi":"","arxiv":""}}
Do not guess identifiers that are not printed in the paper.

PDF metadata:
$pdf_info

First pages:
$body
EOF
  )"
    if ! inferred="$(printf '%s' "$prompt" \
        | OLLAMA_HOST="$OLLAMA_HOST" ollama run --format json --hidethinking --nowordwrap "$OLLAMA_MODEL" 2>>"$LOG_FILE")" \
        || ! jq -e 'type == "object" and (.title | type == "string")' >/dev/null 2>&1 <<<"$inferred"; then
      echo "ERROR: failed to infer valid metadata from $pdf" >&2
      exit 1
    fi
  fi

  doi="$(jq -r '.identifiers.doi // ""' <<<"$inferred")"
  arxiv="$(jq -r '.identifiers.arxiv // ""' <<<"$inferred")"
  inferred_key=""
  [[ -n "$doi" ]] && inferred_key="DOI:$doi"
  [[ -z "$inferred_key" && -n "$arxiv" ]] && inferred_key="ARXIV:${arxiv%v[0-9]*}"
  if [[ -n "$inferred_key" ]]; then
    s2_json="$(s2_lookup_key "$inferred_key" "$s2_fields" 2>/dev/null || true)"
  fi

  inferred_title="$(jq -r '.title // ""' <<<"$inferred")"
  if [[ -z "$s2_json" && -n "$inferred_title" ]]; then
    candidate="$(s2_lookup_title "$inferred_title" "$s2_fields" 2>/dev/null || true)"
    [[ -n "$candidate" ]] || candidate='{}'
    candidate_title="$(jq -r '.title // ""' <<<"$candidate" 2>/dev/null || true)"
    if [[ -n "$candidate_title" \
        && "$(s2_normalize_title "$candidate_title")" == "$(s2_normalize_title "$inferred_title")" ]]; then
      s2_json="$candidate"
    fi
  fi
fi

[[ -n "$s2_json" ]] || s2_json='{}'
s2_title="$(jq -r '.title // ""' <<<"$s2_json" 2>/dev/null || true)"
inferred_title="$(jq -r '.title // ""' <<<"$inferred")"
title="${title_override:-${s2_title:-$inferred_title}}"
[[ -n "$title" ]] || { echo "ERROR: no title could be determined" >&2; exit 1; }

if [[ ${#authors_override[@]} -gt 0 ]]; then
  authors_json="$(printf '%s\n' "${authors_override[@]}" | jq -R . | jq -s .)"
elif jq -e '.authors | type == "array" and length > 0' >/dev/null 2>&1 <<<"$s2_json"; then
  authors_json="$(jq '[.authors[] | .name // empty]' <<<"$s2_json")"
else
  authors_json="$(jq '.authors // []' <<<"$inferred")"
fi

abstract="$(jq -r '.abstract // ""' <<<"$s2_json")"
[[ -n "$abstract" ]] || abstract="$(jq -r '.abstract // ""' <<<"$inferred")"
published="${published_override:-$(jq -r 'if .publicationDate then .publicationDate elif .year then (.year | tostring) else "" end' <<<"$s2_json")}"
[[ -n "$published" ]] || published="$(jq -r '.published // ""' <<<"$inferred")"
category="${category_override:-$(jq -r '.s2FieldsOfStudy[0].category // ""' <<<"$s2_json")}"
[[ -n "$category" ]] || category="$(jq -r '.category // ""' <<<"$inferred")"

s2_id="$(jq -r '.paperId // ""' <<<"$s2_json")"
s2_doi="$(jq -r '.externalIds.DOI // ""' <<<"$s2_json")"
s2_arxiv="$(jq -r '.externalIds.ArXiv // ""' <<<"$s2_json")"
doi="${s2_doi:-$doi}"
arxiv="${s2_arxiv:-$arxiv}"
[[ -n "$arxiv" ]] && arxiv="${arxiv%v[0-9]*}"

if [[ -n "$s2_id" ]]; then
  library_id="s2:$s2_id"
elif [[ -n "$doi" ]]; then
  library_id="doi:${doi,,}"
elif [[ -n "$arxiv" ]]; then
  library_id="arxiv:$arxiv"
else
  library_id="local:${sha256:0:12}"
fi

# Reject a second file for an already managed scholarly record, even if its PDF
# bytes differ (for example, publisher and author-manuscript variants).
while IFS= read -r metadata_file; do
  existing_dir="$(dirname "$metadata_file")"
  existing_id="$(jq -r '.id // ""' "$metadata_file" 2>/dev/null || true)"
  existing_arxiv="$(jq -r '.identifiers.arxiv // ""' "$metadata_file" 2>/dev/null || true)"
  existing_doi="$(jq -r '.identifiers.doi // ""' "$metadata_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  existing_s2="$(jq -r '.identifiers.semantic_scholar // ""' "$metadata_file" 2>/dev/null || true)"
  if [[ "$existing_id" == "$library_id" \
      || ( -n "$arxiv" && "$existing_arxiv" == "$arxiv" ) \
      || ( -n "$doi" && "$existing_doi" == "${doi,,}" ) \
      || ( -n "$s2_id" && "$existing_s2" == "$s2_id" ) ]]; then
    printf '%s\n' "$existing_dir"
    log "duplicate identifier skipped: $pdf -> $existing_dir"
    [[ "$move_source" -eq 1 ]] && rm -f "$pdf"
    exit 0
  fi
done < <(find "$MANUAL_DIR" -name metadata.json -type f -print 2>/dev/null)

if [[ -n "$arxiv" ]]; then
  existing_arxiv_meta=""
  while IFS= read -r -d '' candidate_meta; do
    if [[ "$(jq -r '.id // ""' "$candidate_meta" 2>/dev/null)" == "$arxiv" ]]; then
      existing_arxiv_meta="$candidate_meta"
      break
    fi
  done < <(find "$ROOT/papers/arxiv.org" -name meta.json -type f -print0 2>/dev/null)
  if [[ -n "$existing_arxiv_meta" ]]; then
    existing_dir="$(dirname "$existing_arxiv_meta")"
    printf '%s\n' "$existing_dir"
    log "duplicate arXiv identifier skipped: $pdf -> $existing_dir"
    [[ "$move_source" -eq 1 ]] && rm -f "$pdf"
    exit 0
  fi
fi

slug="$(snake "$title")"
[[ -n "$slug" ]] || slug="paper"
dest="$MANUAL_DIR/${slug}_${sha256:0:8}"
if [[ -e "$dest" ]]; then
  echo "ERROR: destination already exists: $dest" >&2
  exit 1
fi

tmpdir="$(mktemp -d "$MANUAL_DIR/.import.XXXXXX")"
cleanup() { [[ -d "$tmpdir" ]] && rm -rf "$tmpdir"; }
trap cleanup EXIT
cp "$pdf" "$tmpdir/paper.pdf"

jq -n \
  --arg id "$library_id" \
  --arg sha256 "$sha256" \
  --arg title "$title" \
  --argjson authors "$authors_json" \
  --arg abstract "$abstract" \
  --arg published "$published" \
  --arg category "$category" \
  --arg arxiv "$arxiv" \
  --arg doi "$doi" \
  --arg s2 "$s2_id" \
  --arg source_name "$(basename "$pdf")" \
  --arg source_url "$source_url" \
  --arg inferred "$( [[ -n "$explicit_key" ]] && echo false || echo true )" \
  --arg added_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{
    schema_version: 1,
    id: $id,
    sha256: $sha256,
    title: $title,
    authors: $authors,
    abstract: $abstract,
    published: $published,
    category: $category,
    identifiers: {arxiv: $arxiv, doi: $doi, semantic_scholar: $s2},
    source: {type: "manual", original_filename: $source_name, url: $source_url},
    provenance: {metadata_inferred_from_pdf: ($inferred == "true")},
    added_at: $added_at
  }' > "$tmpdir/metadata.json"

mv "$tmpdir" "$dest"
trap - EXIT
[[ "$move_source" -eq 1 ]] && rm -f "$pdf"
log "imported: $pdf -> $dest"
printf '%s\n' "$dest"

if [[ "$process" -eq 1 ]]; then
  bash "$SCRIPT_DIR/translate-papers-daemon.sh"
fi
