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

ptero_fetch_server_by_query() {
  local query="$1"
  local page=1
  local response matched total_pages

  while :; do
    response="$(ptero_api GET "/api/application/servers?include=allocations&per_page=100&page=${page}")"

    matched="$(
      printf '%s\n' "$response" \
        | jq -c --arg query "$query" '
            .data[]
            | .attributes as $s
            | select(
                ($s.id | tostring) == $query
                or ($s.external_id // "") == $query
                or $s.uuid == $query
                or (($s.uuid | split("-"))[0]) == $query
                or $s.name == $query
              )
            | {
                id: $s.id,
                external_id: ($s.external_id // "-"),
                uuid: $s.uuid,
                identifier: (($s.uuid | split("-"))[0]),
                name: $s.name,
                allocations: (
                  $s.relationships.allocations.data // []
                  | map({
                      id: .attributes.id,
                      ip: .attributes.ip,
                      ip_alias: (.attributes.ip_alias // ""),
                      port: .attributes.port,
                      is_default: (.attributes.is_default // false)
                    })
                )
              }
          '
    )"

    if [[ -n "$matched" ]]; then
      printf '%s\n' "$matched"
      return 0
    fi

    total_pages="$(printf '%s\n' "$response" | jq -r '.meta.pagination.total_pages // 1')"
    if [[ "$page" -ge "$total_pages" ]]; then
      break
    fi

    page=$((page + 1))
  done

  return 1
}

ptero_fetch_velocity_server_json() {
  local page=1
  local response matched total_pages
  local -a matches=()

  if [[ -n "${PTERO_VELOCITY_SERVER:-}" ]]; then
    ptero_fetch_server_by_query "$PTERO_VELOCITY_SERVER"
    return $?
  fi

  while :; do
    response="$(ptero_api GET "/api/application/servers?include=allocations&per_page=100&page=${page}")"

    matched="$(
      printf '%s\n' "$response" \
        | jq -cs '
            map(
              .data[]
              | .attributes as $s
              | select(
                  (($s.external_id // "") | ascii_downcase | contains("velocity"))
                  or ($s.name | ascii_downcase | contains("velocity"))
                )
              | {
                  id: $s.id,
                  external_id: ($s.external_id // "-"),
                  uuid: $s.uuid,
                  identifier: (($s.uuid | split("-"))[0]),
                  name: $s.name,
                  allocations: (
                    $s.relationships.allocations.data // []
                    | map({
                        id: .attributes.id,
                        ip: .attributes.ip,
                        ip_alias: (.attributes.ip_alias // ""),
                        port: .attributes.port,
                        is_default: (.attributes.is_default // false)
                      })
                  )
                }
            )
            | add
          '
    )"

    if [[ -n "$matched" && "$matched" != "null" ]]; then
      matches+=("$matched")
    fi

    total_pages="$(printf '%s\n' "$response" | jq -r '.meta.pagination.total_pages // 1')"
    if [[ "$page" -ge "$total_pages" ]]; then
      break
    fi

    page=$((page + 1))
  done

  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [[ "${#matches[@]}" -eq 0 ]]; then
    printf 'Could not auto-detect a Velocity Panel server. Set PTERO_VELOCITY_SERVER to a server ID, external ID, UUID, or exact name.\n' >&2
  else
    printf 'Auto-detected multiple Velocity-like Panel servers. Set PTERO_VELOCITY_SERVER to the intended server.\n' >&2
    printf '%s\n' "${matches[@]}" | jq -r '"  - ID \(.id): \(.name) [\(.external_id)]"' >&2
  fi

  return 1
}

ptero_velocity_volume_dir() {
  local velocity_server_json="$1"
  local velocity_uuid

  ptero_require_env PTERO_VOLUMES_DIR

  velocity_uuid="$(printf '%s\n' "$velocity_server_json" | jq -r '.uuid')"
  printf '%s/%s\n' "${PTERO_VOLUMES_DIR%/}" "$velocity_uuid"
}

ptero_velocity_toml_path() {
  local velocity_server_json="$1"

  if [[ -n "${PTERO_VELOCITY_TOML:-}" ]]; then
    printf '%s\n' "$PTERO_VELOCITY_TOML"
    return 0
  fi

  printf '%s/velocity.toml\n' "$(ptero_velocity_volume_dir "$velocity_server_json")"
}

ptero_velocity_secret_path() {
  local velocity_server_json="$1"
  printf '%s/forwarding.secret\n' "$(ptero_velocity_volume_dir "$velocity_server_json")"
}

ptero_velocity_forwarding_mode() {
  local velocity_server_json="$1"
  local velocity_toml_path mode

  velocity_toml_path="$(ptero_velocity_toml_path "$velocity_server_json")"
  [[ -f "$velocity_toml_path" ]] || {
    printf 'Velocity config file not found: %s\n' "$velocity_toml_path" >&2
    return 1
  }

  mode="$(
    jq -nr --rawfile toml "$velocity_toml_path" '
      $toml
      | split("\n")
      | map(capture("^[[:space:]]*player-info-forwarding-mode[[:space:]]*=[[:space:]]*\"(?<mode>[^\"]+)\"")?.mode)
      | map(select(. != null))
      | .[0] // empty
    '
  )"

  [[ -n "$mode" ]] || {
    printf 'Velocity forwarding mode not found in %s\n' "$velocity_toml_path" >&2
    return 1
  }

  printf '%s\n' "$mode"
}

ptero_velocity_forwarding_secret() {
  local velocity_server_json="$1"
  local secret_path secret

  secret_path="$(ptero_velocity_secret_path "$velocity_server_json")"
  [[ -f "$secret_path" ]] || {
    printf 'Velocity forwarding secret file not found: %s\n' "$secret_path" >&2
    return 1
  }

  secret="$(tr -d '\r' < "$secret_path")"
  secret="${secret%$'\n'}"

  [[ -n "$secret" ]] || {
    printf 'Velocity forwarding secret file is empty: %s\n' "$secret_path" >&2
    return 1
  }

  printf '%s\n' "$secret"
}
