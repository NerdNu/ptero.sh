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
      | map(try capture("^[[:space:]]*player-info-forwarding-mode[[:space:]]*=[[:space:]]*\"(?<mode>[^\"]+)\"").mode catch empty)
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

ptero_velocity_online_mode() {
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
      | map(try capture("^[[:space:]]*online-mode[[:space:]]*=[[:space:]]*(?<mode>true|false)").mode catch empty)
      | map(select(. != null))
      | .[0] // empty
    '
  )"

  [[ -n "$mode" ]] || {
    printf 'Velocity online-mode not found in %s\n' "$velocity_toml_path" >&2
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

ptero_server_volume_dir() {
  local server_json="$1"
  local server_uuid

  ptero_require_env PTERO_VOLUMES_DIR

  server_uuid="$(printf '%s\n' "$server_json" | jq -r '.uuid')"
  printf '%s/%s\n' "${PTERO_VOLUMES_DIR%/}" "$server_uuid"
}

ptero_yaml_trim_value() {
  local value="$1"

  value="${value%%#*}"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"

  if [[ "$value" == '"'*'"' && "$value" == *'"' ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == "'"*"'" && "$value" == *"'" ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s\n' "$value"
}

ptero_read_backend_forwarding_config() {
  local server_json="$1"
  local volume_dir paper_global paper_yml spigot_yml line value
  local in_proxies=0 in_velocity=0 in_settings=0 in_velocity_support=0 in_spigot_settings=0

  ptero_backend_forwarding_mode=""
  ptero_backend_forwarding_secret=""
  ptero_backend_forwarding_online_mode=""
  ptero_backend_forwarding_config_path=""
  ptero_backend_forwarding_format=""
  ptero_backend_bungeecord_enabled=""

  volume_dir="$(ptero_server_volume_dir "$server_json")"
  paper_global="${volume_dir}/config/paper-global.yml"
  paper_yml="${volume_dir}/paper.yml"
  spigot_yml="${volume_dir}/spigot.yml"

  if [[ -f "$paper_global" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        proxies:)
          in_proxies=1
          in_velocity=0
          ;;
        '  '*)
          if [[ "$in_proxies" == "1" && "$line" == '  velocity:' ]]; then
            in_velocity=1
          elif [[ "$in_velocity" == "1" && "$line" == '  '* && "$line" != '    '* ]]; then
            in_velocity=0
          fi
          ;;
        *)
          if [[ "$line" != '    '* ]]; then
            in_velocity=0
          fi
          if [[ "$line" != '  '* ]]; then
            in_proxies=0
          fi
          ;;
      esac

      if [[ "$in_velocity" == "1" ]]; then
        case "$line" in
          '    enabled:'*)
            value="${line#'    enabled:'}"
            value="$(ptero_yaml_trim_value "$value")"
            if [[ "$value" == "true" ]]; then
              ptero_backend_forwarding_mode="modern"
            fi
            ;;
          '    secret:'*)
            value="${line#'    secret:'}"
            ptero_backend_forwarding_secret="$(ptero_yaml_trim_value "$value")"
            ;;
          '    online-mode:'*)
            value="${line#'    online-mode:'}"
            ptero_backend_forwarding_online_mode="$(ptero_yaml_trim_value "$value")"
            ;;
        esac
      fi
    done < "$paper_global"

    if [[ -n "$ptero_backend_forwarding_mode" || -n "$ptero_backend_forwarding_secret" || -n "$ptero_backend_forwarding_online_mode" ]]; then
      ptero_backend_forwarding_config_path="$paper_global"
      ptero_backend_forwarding_format="paper-global"
    fi
  fi

  if [[ -z "$ptero_backend_forwarding_config_path" && -f "$paper_yml" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        settings:)
          in_settings=1
          in_velocity_support=0
          ;;
        '  '*)
          if [[ "$in_settings" == "1" && "$line" == '  velocity-support:' ]]; then
            in_velocity_support=1
          elif [[ "$in_velocity_support" == "1" && "$line" == '  '* && "$line" != '    '* ]]; then
            in_velocity_support=0
          fi
          ;;
        *)
          if [[ "$line" != '    '* ]]; then
            in_velocity_support=0
          fi
          if [[ "$line" != '  '* ]]; then
            in_settings=0
          fi
          ;;
      esac

      if [[ "$in_velocity_support" == "1" ]]; then
        case "$line" in
          '    enabled:'*)
            value="${line#'    enabled:'}"
            value="$(ptero_yaml_trim_value "$value")"
            if [[ "$value" == "true" ]]; then
              ptero_backend_forwarding_mode="modern"
            fi
            ;;
          '    secret:'*)
            value="${line#'    secret:'}"
            ptero_backend_forwarding_secret="$(ptero_yaml_trim_value "$value")"
            ;;
          '    online-mode:'*)
            value="${line#'    online-mode:'}"
            ptero_backend_forwarding_online_mode="$(ptero_yaml_trim_value "$value")"
            ;;
        esac
      fi
    done < "$paper_yml"

    if [[ -n "$ptero_backend_forwarding_mode" || -n "$ptero_backend_forwarding_secret" || -n "$ptero_backend_forwarding_online_mode" ]]; then
      ptero_backend_forwarding_config_path="$paper_yml"
      ptero_backend_forwarding_format="paper-yml"
    fi
  fi

  if [[ -f "$spigot_yml" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        settings:)
          in_spigot_settings=1
          ;;
        '  '*)
          ;;
        *)
          if [[ "$line" != '  '* ]]; then
            in_spigot_settings=0
          fi
          ;;
      esac

      if [[ "$in_spigot_settings" == "1" && "$line" == '  bungeecord:'* ]]; then
        value="${line#'  bungeecord:'}"
        ptero_backend_bungeecord_enabled="$(ptero_yaml_trim_value "$value")"
      fi
    done < "$spigot_yml"

    if [[ -z "$ptero_backend_forwarding_mode" && "$ptero_backend_bungeecord_enabled" == "true" ]]; then
      ptero_backend_forwarding_mode="legacy"
      ptero_backend_forwarding_config_path="$spigot_yml"
      ptero_backend_forwarding_format="spigot-yml"
    fi
  fi
}
