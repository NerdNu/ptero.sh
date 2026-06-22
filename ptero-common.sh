#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if [[ -f "${SCRIPT_DIR}/ptero.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/ptero.env"
fi

ptero_is_live_run() {
  [[ "${PTERO_LIVE_RUN:-0}" == "1" ]]
}

ptero_require_tools() {
  local missing=0

  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$tool" >&2
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

ptero_require_env() {
  local name

  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      printf 'Missing required environment variable: %s\n' "$name" >&2
      exit 1
    fi
  done
}

ptero_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local tmp_body
  local status

  ptero_require_tools
  ptero_require_env PTERO_URL PTERO_APP_API_KEY

  tmp_body="$(mktemp)"

  if [[ -n "$data" ]]; then
    status="$(
      curl -sS \
        -o "$tmp_body" \
        -w '%{http_code}' \
        -X "$method" \
        "${PTERO_URL%/}${path}" \
        -H "Authorization: Bearer ${PTERO_APP_API_KEY}" \
        -H "Accept: Application/vnd.pterodactyl.v1+json" \
        -H "Content-Type: application/json" \
        --data "$data"
    )"
  else
    status="$(
      curl -sS \
        -o "$tmp_body" \
        -w '%{http_code}' \
        -X "$method" \
        "${PTERO_URL%/}${path}" \
        -H "Authorization: Bearer ${PTERO_APP_API_KEY}" \
        -H "Accept: Application/vnd.pterodactyl.v1+json"
    )"
  fi

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    printf 'Panel API request failed: HTTP %s\n' "$status" >&2
    cat "$tmp_body" >&2
    printf '\n' >&2
    rm -f "$tmp_body"
    exit 1
  fi

  cat "$tmp_body"
  rm -f "$tmp_body"
}
