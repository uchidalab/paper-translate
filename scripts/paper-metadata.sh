#!/usr/bin/env bash
# Print normalized metadata JSON for either an arq or manually imported paper.
set -euo pipefail

dir="${1:-}"
if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "usage: $0 <paper_dir>" >&2
  exit 2
fi

if [[ -f "$dir/meta.json" ]]; then
  jq '
    {
      schema_version: 1,
      kind: "arxiv",
      id: (.id // .ID // ""),
      title: (.title // .Title // ""),
      authors: (.authors // .Authors // []),
      abstract: (.abstract // .Abstract // ""),
      published: (.published // .Published // ""),
      category: (.category // .Category // ""),
      identifiers: {
        arxiv: (.id // .ID // ""),
        doi: "",
        semantic_scholar: ""
      },
      source: {
        type: "arxiv",
        url: (.pdf_url // "")
      },
      added_at: (.added_at // ""),
      sha256: ""
    }
  ' "$dir/meta.json"
elif [[ -f "$dir/metadata.json" ]]; then
  jq '
    {
      schema_version: (.schema_version // 1),
      kind: "manual",
      id: (.id // ""),
      title: (.title // ""),
      authors: (.authors // []),
      abstract: (.abstract // ""),
      published: (.published // ""),
      category: (.category // ""),
      identifiers: {
        arxiv: (.identifiers.arxiv // ""),
        doi: (.identifiers.doi // ""),
        semantic_scholar: (.identifiers.semantic_scholar // "")
      },
      source: (.source // {type: "manual", url: ""}),
      provenance: (.provenance // {}),
      added_at: (.added_at // ""),
      sha256: (.sha256 // "")
    }
  ' "$dir/metadata.json"
else
  echo "ERROR: no meta.json or metadata.json in $dir" >&2
  exit 1
fi
