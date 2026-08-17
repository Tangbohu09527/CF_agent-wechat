#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=qr-runtime-common.sh
source "${SCRIPT_DIR}/qr-runtime-common.sh"

print_status() {
  local container_status="$1"
  local server_status="$2"
  local process_status="$3"
  local auth_status="$4"
  local runtime_mode="$5"
  local message_status="$6"
  local worker_status="$7"

  printf '%s\n' '================================'
  printf '%s\n' 'CF Agent WeChat Status'
  printf '%s\n' '================================'
  printf 'Container:\n  %s\n' "$container_status"
  printf 'Agent Server:\n  %s\n' "$server_status"
  printf 'WeChat Process:\n  %s\n' "$process_status"
  printf 'Auth:\n  %s\n' "$auth_status"
  printf 'QR Runtime Mode:\n  %s\n' "$runtime_mode"
  printf 'Message API:\n  %s\n' "$message_status"
  printf 'Gateway WeChat Worker:\n  %s\n' "$worker_status"
  printf '%s\n' '================================'
}

detect_runtime_mode() {
  local inspect_json

  if ! inspect_json="$(docker_readonly_capture inspect "$CONTAINER_NAME" 2>/dev/null)"; then
    printf 'unknown'
    return
  fi
  if printf '%s' "$inspect_json" | "$PYTHON_BIN" -c '
import json
import os
import sys

expected_data = os.path.normpath(sys.argv[1])
expected_home = os.path.normpath(sys.argv[2])
expected_token = os.path.normpath(sys.argv[3])
try:
    payload = json.load(sys.stdin)
    mounts = payload[0]["Mounts"]
except (json.JSONDecodeError, KeyError, IndexError, TypeError):
    raise SystemExit(2)

found = {}
for mount in mounts:
    if not isinstance(mount, dict):
        continue
    destination = mount.get("Destination")
    if destination in {"/data", "/home/wechat", "/data/auth-token"}:
        found[destination] = mount

checks = (
    os.path.normpath(str(found.get("/data", {}).get("Source", "")))
        == expected_data,
    os.path.normpath(str(found.get("/home/wechat", {}).get("Source", "")))
        == expected_home,
    os.path.normpath(str(found.get("/data/auth-token", {}).get("Source", "")))
        == expected_token,
    found.get("/data/auth-token", {}).get("RW") is False,
)
raise SystemExit(0 if all(checks) else 1)
' "${RUNTIME_ROOT}/data" "${RUNTIME_ROOT}/wechat-home" \
    "$TOKEN_FILE" >/dev/null 2>&1; then
    printf 'fresh'
  else
    printf 'legacy_or_unknown'
  fi
}

main() {
  local container_status="unknown"
  local server_status="unavailable"
  local process_status="not_running"
  local auth_status="unavailable"
  local runtime_mode="unknown"
  local message_status="unavailable"
  local worker_status="unavailable"
  local initial_wechat_identity="" final_wechat_identity=""
  local configuration_ok=1 token_ok=1 docker_ok=0
  local container_query_ok=0 worker_query_ok=0 process_identity_ok=0

  if ! validate_configuration; then
    configuration_ok=0
  fi
  if ! resolve_python; then
    configuration_ok=0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    configuration_ok=0
  fi

  if runtime_select_docker; then
    docker_ok=1
    if container_status="$(agent_container_state)"; then
      container_query_ok=1
    else
      container_status="unavailable"
    fi
    if [ -f "$GATEWAY_COMPOSE_FILE" ] && [ -d "$GATEWAY_PROJECT_DIR" ] &&
      worker_status="$(gateway_worker_state)"; then
      worker_query_ok=1
    else
      worker_status="unavailable"
    fi
  fi
  if [ "$configuration_ok" -eq 1 ] && check_agent_server 2>/dev/null; then
    server_status="reachable"
  fi
  if [ "$docker_ok" -eq 1 ] &&
    initial_wechat_identity="$(runtime_wechat_process_identity)" &&
    [ -n "$initial_wechat_identity" ]; then
    process_status="running"
  fi
  runtime_mode="$(detect_runtime_mode)"

  if [ "$configuration_ok" -eq 1 ]; then
    if ! load_auth_token; then
      token_ok=0
    fi
  else
    token_ok=0
  fi
  if [ "$token_ok" -eq 1 ] && fetch_auth_status; then
    auth_status="$AUTH_STATUS"
  fi
  if [ "$token_ok" -eq 1 ] && check_chats_api; then
    message_status="chats readable"
  fi

  if [ -n "$initial_wechat_identity" ] &&
    final_wechat_identity="$(runtime_wechat_process_identity)" &&
    [ "$final_wechat_identity" = "$initial_wechat_identity" ]; then
    process_identity_ok=1
  elif [ -n "$initial_wechat_identity" ]; then
    process_status="exited_or_replaced"
  fi

  print_status \
    "$container_status" "$server_status" "$process_status" "$auth_status" \
    "$runtime_mode" "$message_status" "$worker_status"

  if [ "$configuration_ok" -ne 1 ]; then
    error "Status configuration or required commands are unavailable."
    return 1
  fi
  if [ "$container_query_ok" -ne 1 ] || [ "$worker_query_ok" -ne 1 ]; then
    error "Container or Gateway wechat-worker state could not be queried."
    return 1
  fi
  if [ "$token_ok" -ne 1 ]; then
    error "Authentication token could not be loaded securely."
    return 1
  fi
  if [ "$process_identity_ok" -ne 1 ]; then
    error "/usr/bin/wechat is not running."
    return 3
  fi
  if [ "$container_status" != "running" ]; then
    error "agent-wechat container is not running."
    return 3
  fi
  if [ "$runtime_mode" != "fresh" ]; then
    error "agent-wechat is not using the forced-QR runtime mounts."
    return 3
  fi
  if [ "$auth_status" != "logged_in" ]; then
    if [ "$auth_status" = "logged_out" ]; then
      error "WeChat is logged out; use start-qr-login.sh."
      return 2
    fi
    error "WeChat authentication is not usable."
    return 3
  fi
  if [ "$message_status" != "chats readable" ]; then
    error "Chats API is not readable."
    return 1
  fi
  return 0
}

main "$@"
