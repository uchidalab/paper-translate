#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WORK="$TMP_ROOT/work"
BIN="$TMP_ROOT/bin"
mkdir -p "$WORK/scripts" "$WORK/tests" "$WORK/papers" "$WORK/inbox" "$BIN"
cp "$PROJECT_ROOT"/scripts/{paper-metadata.sh,semantic-scholar.sh,import-paper.sh,import-inbox.sh,fetch-references.sh,generate-obsidian-note.sh,update-by-title.sh,translate-papers-daemon.sh} "$WORK/scripts/"
chmod +x "$WORK/scripts/"*.sh

cat > "$BIN/pdfinfo" <<'EOF'
#!/usr/bin/env bash
echo 'Title: Mock PDF'
echo 'Author: Test Author'
EOF
cat > "$BIN/pdftotext" <<'EOF'
#!/usr/bin/env bash
echo 'Exact Paper'
echo 'Test Author'
echo 'Abstract text.'
EOF
cat > "$BIN/ollama" <<'EOF'
#!/usr/bin/env bash
[[ "${MOCK_OLLAMA_FAIL:-0}" == 1 ]] && exit 1
jq -n \
  --arg title "${MOCK_INFER_TITLE:-Exact Paper}" \
  '{title:$title,authors:["Test Author"],abstract:"Abstract text.",published:"2025",category:"Computer Science",identifiers:{doi:"",arxiv:""}}'
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_CURL_STATUS:-}" ]]; then
  printf '{}\n%s' "$MOCK_CURL_STATUS"
  exit 0
fi
url="${*: -1}"
case "$url" in
  */search/match*)
    jq -cn --arg title "${MOCK_S2_TITLE:-Exact Paper}" \
      '{paperId:"mock-paper",title:$title,authors:[{name:"Canonical Author"}],abstract:"Canonical abstract",publicationDate:"2025-01-02",externalIds:{DOI:"10.1000/mock"},url:"https://www.semanticscholar.org/paper/mock-paper",s2FieldsOfStudy:[{category:"Computer Science"}]}'
    ;;
  */mock-paper/references*)
    printf '%s' '{"data":[{"citedPaper":{"paperId":"ref-paper","title":"Reference Paper","externalIds":{"DOI":"10.1000/ref"},"url":"https://www.semanticscholar.org/paper/ref-paper"}}]}'
    ;;
  */mock-paper/citations*)
    printf '%s' '{"data":[{"citingPaper":{"paperId":"cite-paper","title":"Citing Paper","externalIds":{"ArXiv":"2501.00001v2"},"url":"https://www.semanticscholar.org/paper/cite-paper"}}]}'
    ;;
  */mock-paper\?*)
    printf '%s' '{"paperId":"mock-paper","title":"Exact Paper","externalIds":{"DOI":"10.1000/mock"},"url":"https://www.semanticscholar.org/paper/mock-paper"}'
    ;;
  *) printf '%s' '{}' ;;
esac
printf '\n200'
EOF
cat > "$BIN/pdf2zh" <<'EOF'
#!/usr/bin/env bash
echo 'pdf2zh should not run in this test' >&2
exit 1
EOF
chmod +x "$BIN/"*

export PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export OLLAMA_MODEL="mock-model"
export S2_SLEEP=0
export MOCK_INFER_TITLE="Exact Paper"
export MOCK_S2_TITLE="Exact Paper"

SOURCE="$TMP_ROOT/exact.pdf"
printf 'mock-pdf-one\n' > "$SOURCE"
dest="$("$WORK/scripts/import-paper.sh" "$SOURCE" --no-process)"
[[ -f "$dest/paper.pdf" ]]
[[ -f "$SOURCE" ]]
jq -e '
  .id == "s2:mock-paper"
  and .title == "Exact Paper"
  and .authors == ["Canonical Author"]
  and .identifiers.doi == "10.1000/mock"
  and .provenance.metadata_inferred_from_pdf == true
' "$dest/metadata.json" >/dev/null

duplicate="$("$WORK/scripts/import-paper.sh" "$SOURCE" --no-process)"
[[ "$duplicate" == "$dest" ]]
[[ "$(find "$WORK/papers/manual" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 1 ]]

"$WORK/scripts/fetch-references.sh" "$dest"
jq -e '
  .status == "matched"
  and .references[0].doi == "10.1000/ref"
  and .citations[0].arxiv_id == "2501.00001"
' "$dest/references.json" >/dev/null

"$WORK/scripts/generate-obsidian-note.sh" "$dest"
note="$dest/exact_paper.md"
[[ -f "$note" ]]
grep -q 'source_type: manual' "$note"
grep -q 'https://doi.org/10.1000/ref' "$note"

# A non-identical title match must remain a local paper without an S2 ID.
export MOCK_INFER_TITLE="Ambiguous Paper"
export MOCK_S2_TITLE="Different Paper"
AMBIGUOUS="$TMP_ROOT/ambiguous.pdf"
printf 'mock-pdf-two\n' > "$AMBIGUOUS"
ambiguous_dest="$("$WORK/scripts/import-paper.sh" "$AMBIGUOUS" --no-process)"
jq -e '
  (.id | startswith("local:"))
  and .identifiers.semantic_scholar == ""
' "$ambiguous_dest/metadata.json" >/dev/null
"$WORK/scripts/fetch-references.sh" "$ambiguous_dest"
jq -e '.status == "unmatched" and .references == [] and .citations == []' \
  "$ambiguous_dest/references.json" >/dev/null

# An explicit title bypasses Ollama, while still applying explicit author data.
export MOCK_OLLAMA_FAIL=1
export MOCK_S2_TITLE="Different Paper"
TITLED="$TMP_ROOT/titled.pdf"
printf 'mock-pdf-three\n' > "$TITLED"
titled_dest="$("$WORK/scripts/import-paper.sh" "$TITLED" --title "Manual Title" --author "Override Author" --no-process)"
jq -e '
  .title == "Manual Title"
  and .authors == ["Override Author"]
  and (.id | startswith("local:"))
' "$titled_dest/metadata.json" >/dev/null
unset MOCK_OLLAMA_FAIL

# Temporary API failures remain retryable and must not create unmatched state.
transient_dir="$WORK/papers/manual/transient"
mkdir -p "$transient_dir"
printf 'transient\n' > "$transient_dir/paper.pdf"
printf '%s\n' '{"id":"s2:transient","title":"Transient","identifiers":{"semantic_scholar":"transient"}}' > "$transient_dir/metadata.json"
export MOCK_CURL_STATUS=500
if S2_MAX_RETRY=0 "$WORK/scripts/fetch-references.sh" "$transient_dir"; then
  echo 'expected Semantic Scholar failure' >&2
  exit 1
fi
[[ ! -e "$transient_dir/references.json" ]]
unset MOCK_CURL_STATUS

# Inbox imports consume successful duplicates, but retain failed PDFs.
cp "$SOURCE" "$WORK/inbox/duplicate.pdf"
"$WORK/scripts/import-inbox.sh" --no-process
[[ ! -e "$WORK/inbox/duplicate.pdf" ]]
printf 'bad-metadata\n' > "$WORK/inbox/failure.pdf"
export MOCK_OLLAMA_FAIL=1
if "$WORK/scripts/import-inbox.sh" --no-process; then
  echo 'expected inbox import failure' >&2
  exit 1
fi
[[ -f "$WORK/inbox/failure.pdf" ]]
unset MOCK_OLLAMA_FAIL

# Existing arq metadata stays supported and both storage roots enter by-title.
arq_dir="$WORK/papers/arxiv.org/cs.CL/1234.56789"
mkdir -p "$arq_dir"
printf 'arq-pdf\n' > "$arq_dir/paper.pdf"
printf '%s\n' '{"id":"1234.56789","title":"Arq Paper","authors":["A. Author"],"published":"2024-01-01","category":"cs.CL"}' > "$arq_dir/meta.json"
jq -e '.kind == "arxiv" and .identifiers.arxiv == "1234.56789"' \
  < <("$WORK/scripts/paper-metadata.sh" "$arq_dir") >/dev/null
"$WORK/scripts/update-by-title.sh"
[[ -L "$WORK/papers/by-title/arq_paper" ]]
[[ -L "$WORK/papers/by-title/exact_paper" ]]

# The daemon accepts both metadata formats in one run and refreshes all notes.
while IFS= read -r -d '' paper; do
  paper_dir="$(dirname "$paper")"
  cp "$paper" "$paper_dir/paper_ja.pdf"
  printf '# summary\n' > "$paper_dir/summary.md"
  printf 'png\n' > "$paper_dir/overview.png"
  [[ -f "$paper_dir/references.json" ]] \
    || printf '%s\n' '{"status":"unmatched","references":[],"citations":[]}' > "$paper_dir/references.json"
done < <(find "$WORK/papers" -path "$WORK/papers/by-title" -prune -o -name paper.pdf -type f -print0)
PAPER_LIBRARY_AUTO_PUSH=0 "$WORK/scripts/translate-papers-daemon.sh"
[[ -f "$ambiguous_dest/ambiguous_paper.md" ]]
[[ -f "$arq_dir/arq_paper.md" ]]

echo 'manual import tests passed'
