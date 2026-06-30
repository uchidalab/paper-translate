#!/usr/bin/env bash
# Extract figures from a paper PDF and pick a method-overview image.
#
#   1. extract_figures.py (PyMuPDF) crops each "Figure N" region — vector
#      architecture diagrams included — to <dir>/figures/fig-NN.png and records
#      caption + score in <dir>/figures/figures.json.
#   2. The highest caption-scored figure is copied to <dir>/overview.png.
#   3. arq thumbnail set registers overview.png so arq view shows it too.
#
# If PyMuPDF finds no captioned figure, we fall back to rendering the best
# keyword-scored whole page (so text-only PDFs still get a thumbnail).
#
# Usage: extract-figures.sh <paper_dir> [--force] [--candidates-only]
#   <paper_dir> = papers/arxiv.org/<category>/<id>
#   A manual override figure number can be placed in <dir>/.overview-figure.
set -euo pipefail

export PATH="$PATH:/Users/ishimarutaisei/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$ROOT/.logs"
LOG_FILE="$LOG_DIR/figures.log"

FIGURE_ZOOM="${FIGURE_ZOOM:-3}"          # PyMuPDF clip-render zoom
FIGURE_DPI="${FIGURE_DPI:-130}"          # page-render fallback DPI
OVERVIEW_TOP_N="${OVERVIEW_TOP_N:-3}"    # page-render fallback candidates
OVERVIEW_MAX_WIDTH="${OVERVIEW_MAX_WIDTH:-1400}"

dir="${1:-}"
force=0
candidates_only=0
for arg in "${@:2}"; do
  case "$arg" in
    --force) force=1 ;;
    --candidates-only) candidates_only=1 ;;
    *) echo "usage: $0 <paper_dir> [--force] [--candidates-only]" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"; }

if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "usage: $0 <paper_dir> [--force] [--candidates-only]" >&2
  exit 2
fi

pdf="$dir/paper.pdf"
[[ -f "$pdf" ]] || { log "SKIP: no paper.pdf in $dir"; exit 0; }

for t in jq sips; do
  command -v "$t" >/dev/null 2>&1 || { log "ERROR: $t not found in PATH"; exit 1; }
done

# Prefer the project venv's python (has PyMuPDF); fall back to any python3 that
# can import fitz. Error with an install hint otherwise.
PYBIN=""
if [[ -x "$ROOT/.venv/bin/python" ]] && "$ROOT/.venv/bin/python" -c "import fitz" 2>/dev/null; then
  PYBIN="$ROOT/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import fitz" 2>/dev/null; then
  PYBIN="python3"
else
  log "ERROR: PyMuPDF not available. Run: uv pip install --python $ROOT/.venv/bin/python pymupdf"
  exit 1
fi

metadata="$(bash "$SCRIPT_DIR/paper-metadata.sh" "$dir" 2>/dev/null || printf '{}')"
id="$(jq -r '.id // ""' <<<"$metadata")"
kind="$(jq -r '.kind // ""' <<<"$metadata")"
overview="$dir/overview.png"
figures_dir="$dir/figures"

if [[ -f "$overview" && "$force" -eq 0 && "$candidates_only" -eq 0 ]]; then
  log "KEEP: overview.png already exists in $dir"
  exit 0
fi

# Fresh figure set each run so stale crops never linger.
rm -rf "$figures_dir"
mkdir -p "$figures_dir"

# --- 1. Crop figures with PyMuPDF -------------------------------------------
chosen="$("$PYBIN" "$SCRIPT_DIR/extract_figures.py" "$pdf" "$figures_dir" "$FIGURE_ZOOM" 2>>"$LOG_FILE" || echo NONE)"
log "figures: extracted to $figures_dir (overview candidate: $chosen)"

# Manual override: <dir>/.overview-figure holds a figure number to force.
if [[ -f "$dir/.overview-figure" && -f "$figures_dir/figures.json" ]]; then
  want="$(tr -dc '0-9' < "$dir/.overview-figure")"
  if [[ -n "$want" ]]; then
    pick="$(jq -r --argjson n "$want" 'map(select(.figure_no == $n)) | .[0].file // ""' "$figures_dir/figures.json")"
    [[ -n "$pick" ]] && chosen="$pick"
  fi
fi

# --- 2. Resolve overview.png -------------------------------------------------
if [[ "$chosen" != "NONE" && -f "$figures_dir/$chosen" ]]; then
  if [[ "$candidates_only" -eq 1 ]]; then
    log "CANDIDATES: $figures_dir ($(ls "$figures_dir"/fig-*.png 2>/dev/null | wc -l | tr -d ' ') figs)"
    exit 0
  fi
  sips -Z "$OVERVIEW_MAX_WIDTH" "$figures_dir/$chosen" --out "$overview" >/dev/null 2>&1
  log "overview: $overview (from figures/$chosen)"
else
  # --- Fallback: render the best keyword-scored whole page -------------------
  log "no captioned figure found; falling back to page render"
  command -v pdftotext >/dev/null 2>&1 && command -v pdftoppm >/dev/null 2>&1 \
    || { log "SKIP: poppler not available for fallback"; exit 0; }

  score_pages() {
    local text_file
    text_file="$(mktemp)"
    trap 'rm -f "$text_file"' RETURN
    pdftotext -layout "$pdf" "$text_file" 2>/dev/null || true
    "$PYBIN" - "$OVERVIEW_TOP_N" "$text_file" <<'PY'
import re, sys
top_n = int(sys.argv[1] or 3)
with open(sys.argv[2], "r", encoding="utf-8", errors="ignore") as h:
    pages = h.read().split("\f")
patterns = [
    (r"\b(fig\.?|figure)\s*1\b", 80), (r"\b(fig\.?|figure)\s*2\b", 18),
    (r"\bmethod\b|\bmethods\b", 8), (r"\bproposed\b|\bour method\b|\bour approach\b", 7),
    (r"\bframework\b|\bpipeline\b|\barchitecture\b|\boverview\b", 7),
    (r"\bschematic\b|\bsummary of our approach\b", 7),
]
scored = []
for i, body in enumerate(pages):
    low = body.lower()
    s = sum(len(re.findall(p, low)) * w for p, w in patterns)
    s += (8 - i) if i < 8 else -(i - 7) * 4
    if re.search(r"\breferences\b", low):
        s -= 50
    scored.append((s, i + 1))
scored.sort(key=lambda x: (-x[0], x[1]))
for s, p in scored[:top_n]:
    print(f"{p}\t{s:.1f}")
PY
  }

  page="$(score_pages | head -1 | cut -f1)"
  [[ -n "$page" ]] || { log "SKIP: no page to render for $pdf"; exit 0; }
  if [[ "$candidates_only" -eq 1 ]]; then
    log "CANDIDATES: fallback page $page"
    exit 0
  fi
  prefix="$figures_dir/page-$(printf '%03d' "$page")"
  pdftoppm -png -r "$FIGURE_DPI" -f "$page" -l "$page" -singlefile "$pdf" "$prefix" >/dev/null 2>&1
  [[ -f "$prefix.png" ]] || { log "SKIP: page render failed for $pdf"; exit 0; }
  sips -Z "$OVERVIEW_MAX_WIDTH" "$prefix.png" --out "$overview" >/dev/null 2>&1
  log "overview: $overview (fallback page $page)"
fi

# --- 3. Register with arq so its gallery shows the same thumbnail ------------
if [[ "$kind" == "arxiv" && -n "$id" ]] && command -v arq >/dev/null 2>&1; then
  if arq thumbnail set "$id" "$overview" >/dev/null 2>&1; then
    log "arq thumbnail set: $id"
  else
    log "WARN: arq thumbnail set failed for $id"
  fi
fi
