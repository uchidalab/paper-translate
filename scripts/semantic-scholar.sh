#!/usr/bin/env bash
# Shared Semantic Scholar client functions. Source this file from another script.

S2_BASE="${S2_BASE:-https://api.semanticscholar.org/graph/v1/paper}"
S2_MAX_RETRY="${S2_MAX_RETRY:-4}"
S2_SLEEP="${S2_SLEEP:-0}"
S2_LOG_FILE="${S2_LOG_FILE:-/dev/null}"

s2_log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$S2_LOG_FILE"
}

s2_uri_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

s2_normalize_title() {
  python3 - "$1" <<'PY'
import re, sys, unicodedata
value = unicodedata.normalize("NFKC", sys.argv[1]).casefold()
print(re.sub(r"[^\w]+", "", value, flags=re.UNICODE))
PY
}

s2_get() {
  local url="$1" attempt=0 response code body backoff
  local curl_args=(-sS -m 30 -w $'\n%{http_code}')
  [[ -n "${S2_API_KEY:-}" ]] && curl_args+=(-H "x-api-key: $S2_API_KEY")
  while :; do
    response="$(curl "${curl_args[@]}" "$url" 2>>"$S2_LOG_FILE" || true)"
    code="${response##*$'\n'}"
    body="${response%$'\n'*}"
    case "$code" in
      200) printf '%s' "$body"; [[ "$S2_SLEEP" == 0 ]] || sleep "$S2_SLEEP"; return 0 ;;
      404) return 4 ;;
      429|5*)
        attempt=$((attempt + 1))
        if [[ "$attempt" -gt "$S2_MAX_RETRY" ]]; then
          s2_log "request failed after $S2_MAX_RETRY retries ($code): $url"
          return 1
        fi
        backoff=$((5 * 3 ** (attempt - 1)))
        s2_log "rate limited ($code), retrying in ${backoff}s: $url"
        sleep "$backoff"
        ;;
      *) s2_log "unexpected HTTP $code: $url"; return 1 ;;
    esac
  done
}

s2_lookup_key() {
  local key="$1" fields="$2" encoded
  encoded="$(s2_uri_encode "$key")"
  s2_get "$S2_BASE/$encoded?fields=$fields"
}

s2_lookup_title() {
  local title="$1" fields="$2" encoded
  encoded="$(s2_uri_encode "$title")"
  s2_get "$S2_BASE/search/match?query=$encoded&fields=$fields"
}
