#!/bin/bash -p
set -uo pipefail

set +x
set +a
unset _CF_AGENT_WECHAT_TEST_CALLER_PATH
_CF_AGENT_WECHAT_TEST_CALLER_PATH="${PATH:-}"
readonly _CF_AGENT_WECHAT_TEST_CALLER_PATH
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LANG=C.UTF-8
LC_ALL=C.UTF-8
export PATH LANG LC_ALL
if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
  case "$-" in
    *p*) ;;
    *) printf '%s\n' 'Production management requires direct protected-mode script execution.' >&2; exit 1 ;;
  esac
fi
unset BASH_ENV ENV CDPATH

unset _CF_AGENT_WECHAT_EARLY_OVERRIDES
_CF_AGENT_WECHAT_EARLY_OVERRIDES=""
for _management_env_name in \
    API_URL WS_URL TOKEN_FILE SESSION_ID CONTAINER_NAME PYTHON_BIN \
    REQUIREMENTS_FILE VENV_DIR CF_AGENT_WECHAT_VENV AGENT_WECHAT_IMAGE \
    CF_AGENT_WECHAT_CURL_BIN \
    AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT AGENT_WECHAT_CONTAINER_NAME \
    COMPOSE_PROJECT_NAME PROXY RUST_LOG CF_AGENT_WECHAT_STORAGE_ROOT \
    CF_AGENT_WECHAT_RUNTIME_ROOT CF_AGENT_WECHAT_ARCHIVE_ROOT \
    CF_AGENT_WECHAT_MIN_FREE_BYTES CF_AGENT_WECHAT_MIN_FREE_PERCENT \
    CF_AGENT_WECHAT_MIN_FREE_INODES CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES \
    CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES \
    CF_AGENT_WECHAT_COMPOSE_FILE CF_AGENT_WECHAT_ENV_FILE \
    CF_AGENT_WECHAT_LOCK_FILE CF_AGENT_WECHAT_RUNTIME_UID \
    CF_AGENT_WECHAT_RUNTIME_GID CF_AGENT_WECHAT_RUNTIME_MODE \
    CF_AGENT_WECHAT_MANAGEMENT_GID CF_AGENT_GATEWAY_COMPOSE_FILE \
    CF_AGENT_GATEWAY_PROJECT_DIR CF_AGENT_GATEWAY_ENV_FILE \
    CF_AGENT_GATEWAY_HEARTBEAT_COMMAND \
    CF_AGENT_WECHAT_DOCKER_BIN CF_AGENT_WECHAT_SYSTEMCTL_BIN \
    CF_AGENT_WECHAT_DOCKER_SOCKET_PATH CF_AGENT_WECHAT_DF_BIN \
    CF_AGENT_WECHAT_TEST_ROOT \
    CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT \
    CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT \
    CF_AGENT_WECHAT_TOKEN CF_AGENT_WECHAT_TOKEN_FILE AUTH_TOKEN \
    CF_AGENT_WECHAT_TEST_PIP_INSTALL_TIMEOUT \
    CF_AGENT_WECHAT_TEST_PIP_NETWORK_TIMEOUT \
    CF_AGENT_WECHAT_TEST_PIP_RETRIES \
    CF_AGENT_WECHAT_TEST_VENV_CREATE_TIMEOUT \
    HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy \
    NO_PROXY no_proxy TMPDIR \
    HTTP_CONNECT_TIMEOUT HTTP_TIMEOUT DOCKER_READ_TIMEOUT LOGIN_TIMEOUT_MS \
    LOGIN_CONFIRM_RETRIES LOGIN_CONFIRM_INTERVAL SERVER_READY_TIMEOUT \
    WECHAT_READY_TIMEOUT WECHAT_STABLE_SECONDS POST_LOGIN_READY_TIMEOUT \
    RUNTIME_POLL_INTERVAL DOCKER_COMMAND_TIMEOUT COMPOSE_COMMAND_TIMEOUT \
    WORKER_READY_TIMEOUT WORKER_STABLE_SECONDS WORKER_HEARTBEAT_TIMEOUT \
    TOKEN_SCAN_TIMEOUT ARCHIVE_TOOL_TIMEOUT \
    CF_AGENT_WECHAT_TEST_ARCHIVE_TOOL_TIMEOUT; do
    if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ] &&
      [[ -v $_management_env_name ]]; then
      _CF_AGENT_WECHAT_EARLY_OVERRIDES+="${_CF_AGENT_WECHAT_EARLY_OVERRIDES:+,}${_management_env_name}"
    fi
    if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
      unset "$_management_env_name"
    else
      export -n "$_management_env_name" 2>/dev/null || :
      case "$_management_env_name" in
        AUTH_TOKEN|CF_AGENT_WECHAT_TOKEN|PROXY|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|NO_PROXY|no_proxy)
          unset "$_management_env_name"
          ;;
      esac
    fi
  done
for _management_sensitive_name in \
  CF_GATEWAY_API_TOKEN CF_AGENT_GATEWAY_ADMIN_TOKEN HERMES_API_KEY; do
  unset "$_management_sensitive_name"
done
unset _management_sensitive_name
readonly _CF_AGENT_WECHAT_EARLY_OVERRIDES
unset _management_env_name

unset _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
  _management_uid="$(/usr/bin/id -u)"

  _management_validate_node() {
    local path="$1"
    local expected_kind="$2"
    local metadata owner mode links file_type _dev _inode _gid

    if [ -L "$path" ]; then
      printf '%s\n' 'Production management path is a symlink.' >&2
      return 1
    fi
    if ! metadata="$(
      /usr/bin/stat -c '%d:%i:%u:%g:%a:%h:%F' -- "$path" 2>/dev/null
    )"; then
      printf '%s\n' 'Production management path metadata is unavailable.' >&2
      return 1
    fi
    IFS=: read -r _dev _inode owner _gid mode links file_type <<< "$metadata"
    case "$owner" in
      0|"$_management_uid") ;;
      *)
        printf '%s\n' 'Production management path owner is not approved.' >&2
        return 1
        ;;
    esac
    case "$expected_kind" in
      directory)
        if [ "$file_type" != directory ] || [ "$mode" != 755 ]; then
          printf '%s\n' 'Production management directory metadata is unsafe.' >&2
          return 1
        fi
        ;;
      file)
        if [ "$file_type" != 'regular file' ] ||
          [ "$mode" != 755 ] || [ "$links" != 1 ]; then
          printf '%s\n' 'Production management file metadata is unsafe.' >&2
          return 1
        fi
        ;;
      *) return 1 ;;
    esac
    MANAGEMENT_NODE_METADATA="$metadata"
  }

  _management_source_library() {
    local library_path="$1"
    local path_before path_after fd_metadata library_fd
    local content_before content_after fd_content_before fd_content_after
    local library_source="" source_status=0

    _management_validate_node "$library_path" file || return 1
    path_before="$MANAGEMENT_NODE_METADATA"
    if ! exec {library_fd}<"$library_path"; then
      printf '%s\n' 'Production management library could not be opened.' >&2
      return 1
    fi
    if ! fd_metadata="$(
      /usr/bin/stat -Lc '%d:%i:%u:%g:%a:%h:%F' -- \
        "/proc/self/fd/${library_fd}" 2>/dev/null
    )" ||
      [ -L "$library_path" ] ||
      ! path_after="$(
        /usr/bin/stat -c '%d:%i:%u:%g:%a:%h:%F' -- \
          "$library_path" 2>/dev/null
      )" ||
      [ "$path_before" != "$fd_metadata" ] ||
      [ "$path_before" != "$path_after" ] ||
      ! content_before="$(
        /usr/bin/stat -c '%d:%i:%s:%y:%z' -- \
          "$library_path" 2>/dev/null
      )" ||
      ! fd_content_before="$(
        /usr/bin/stat -Lc '%d:%i:%s:%y:%z' -- \
          "/proc/self/fd/${library_fd}" 2>/dev/null
      )" ||
      [ "$content_before" != "$fd_content_before" ]; then
      exec {library_fd}<&-
      printf '%s\n' 'Production management library changed while loading.' >&2
      return 1
    fi
    if IFS= read -r -d '' library_source <&"$library_fd"; then
      library_source=""
      exec {library_fd}<&-
      printf '%s\n' 'Production management library contains a NUL byte.' >&2
      return 1
    fi
    if [ -L "$library_path" ] ||
      ! content_after="$(
        /usr/bin/stat -c '%d:%i:%s:%y:%z' -- \
          "$library_path" 2>/dev/null
      )" ||
      ! fd_content_after="$(
        /usr/bin/stat -Lc '%d:%i:%s:%y:%z' -- \
          "/proc/self/fd/${library_fd}" 2>/dev/null
      )" ||
      [ "$content_after" != "$content_before" ] ||
      [ "$fd_content_after" != "$content_before" ]; then
      library_source=""
      exec {library_fd}<&-
      printf '%s\n' 'Production management library changed while loading.' >&2
      return 1
    fi
    # shellcheck disable=SC1091
    source /dev/stdin <<< "$library_source" || source_status=$?
    if [ -L "$library_path" ] ||
      ! content_after="$(
        /usr/bin/stat -c '%d:%i:%s:%y:%z' -- \
          "$library_path" 2>/dev/null
      )" ||
      ! fd_content_after="$(
        /usr/bin/stat -Lc '%d:%i:%s:%y:%z' -- \
          "/proc/self/fd/${library_fd}" 2>/dev/null
      )" ||
      [ "$content_after" != "$content_before" ] ||
      [ "$fd_content_after" != "$content_before" ]; then
      library_source=""
      exec {library_fd}<&-
      printf '%s\n' 'Production management library changed while loading.' >&2
      return 1
    fi
    library_source=""
    exec {library_fd}<&-
    [ "$source_status" -eq 0 ] || return "$source_status"
  }

  if [ "${BASH_SOURCE[0]##*/}" != status.sh ] ||
    [ -L "${BASH_SOURCE[0]}" ] ||
    ! _management_validate_node "$SCRIPT_DIR" directory ||
    ! _management_validate_node "${SCRIPT_DIR}/status.sh" file; then
    exit 1
  fi
  _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR="$SCRIPT_DIR"
  readonly _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR

  _management_source_library "${SCRIPT_DIR}/common.sh" || exit 1
  _management_source_library "${SCRIPT_DIR}/qr-runtime-common.sh" || exit 1
  unset -f _management_validate_node _management_source_library
  unset _management_uid MANAGEMENT_NODE_METADATA
else
  # shellcheck source=common.sh
  source "${SCRIPT_DIR}/common.sh" || exit 1
  # shellcheck source=qr-runtime-common.sh
  source "${SCRIPT_DIR}/qr-runtime-common.sh" || exit 1
fi
if [ "${CF_AGENT_WECHAT_COMMON_LOADED:-0}" != 1 ] ||
  [ "${CF_AGENT_WECHAT_RUNTIME_COMMON_LOADED:-0}" != 1 ]; then
  printf '%s\n' 'Management libraries did not load completely.' >&2
  exit 1
fi
if ! restore_testing_management_path "$_CF_AGENT_WECHAT_TEST_CALLER_PATH"; then
  error "${LAST_ERROR:-Testing command path is not isolated.}"
  exit 1
fi
if ! runtime_validate_testing_isolation; then
  error "${LAST_ERROR:-Testing management assets are not isolated.}"
  exit 1
fi

print_status() {
  local container_status="$1"
  local docker_health="$2"
  local server_status="$3"
  local process_status="$4"
  local auth_status="$5"
  local runtime_mode="$6"
  local message_status="$7"
  local worker_status="$8"
  local worker_health="$9"
  local worker_heartbeat="${10}"

  printf '%s\n' '================================'
  printf '%s\n' 'CF Agent WeChat Status'
  printf '%s\n' '================================'
  printf 'Container:\n  %s\n' "$container_status"
  printf 'Docker Health:\n  %s\n' "$docker_health"
  printf 'Agent Server:\n  %s\n' "$server_status"
  printf 'WeChat Process:\n  %s\n' "$process_status"
  printf 'Auth:\n  %s\n' "$auth_status"
  printf 'QR Runtime Mode:\n  %s\n' "$runtime_mode"
  printf 'Message API:\n  %s\n' "$message_status"
  printf 'Gateway WeChat Worker:\n  %s\n' "$worker_status"
  printf 'Gateway Worker Health:\n  %s\n' "$worker_health"
  printf 'Gateway Worker Heartbeat:\n  %s\n' "$worker_heartbeat"
  printf '%s\n' '================================'
}

detect_runtime_mode() {
  local inspect_json

  if ! inspect_json="$(runtime_docker inspect "$CONTAINER_NAME" 2>/dev/null)"; then
    printf 'unknown'
    return
  fi
  if printf '%s' "$inspect_json" | run_isolated_python -c '
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

prepare_status_management_configuration() {
  local protected_path

  runtime_authorize_sudo || return 1
  for protected_path in "$RUNTIME_REPO_ROOT" \
    "${RUNTIME_REPO_ROOT}/docker" "$AGENT_COMPOSE_FILE" \
    "$AGENT_ENV_FILE"; do
    runtime_validate_no_symlink_ancestors \
      "$protected_path" "Production status path" || return 1
  done
  runtime_validate_management_file \
    "$AGENT_COMPOSE_FILE" "agent-wechat Compose" || return 1
  runtime_validate_management_file \
    "$AGENT_ENV_FILE" "agent-wechat environment file" "600 0600 640 0640" ||
    return 1
  runtime_load_management_environment || return 1
  for protected_path in "$STORAGE_ROOT" "$RUNTIME_ROOT" "$ARCHIVE_ROOT" \
    "$TOKEN_FILE" "$GATEWAY_PROJECT_DIR" "$GATEWAY_COMPOSE_FILE" \
    "$GATEWAY_ENV_FILE" "$GATEWAY_HEARTBEAT_COMMAND" \
    "$GATEWAY_CONTRACT_VERIFIER" \
    "$MANAGEMENT_SOURCE_SECRET_VERIFIER"; do
    runtime_validate_no_symlink_ancestors \
      "$protected_path" "Production status path" || return 1
  done
  runtime_validate_management_directory \
    "$GATEWAY_PROJECT_DIR" "Gateway project directory" 1 || return 1
  runtime_validate_management_file \
    "$GATEWAY_COMPOSE_FILE" "Gateway Compose" || return 1
  runtime_validate_management_file \
    "$GATEWAY_ENV_FILE" "Gateway environment file" "600 0600 640 0640" ||
    return 1
  runtime_validate_management_file \
    "$GATEWAY_HEARTBEAT_COMMAND" "Gateway heartbeat checker" || return 1
  [ -x "$GATEWAY_HEARTBEAT_COMMAND" ] || return 1
  runtime_validate_management_file \
    "$GATEWAY_CONTRACT_VERIFIER" "Gateway contract verifier" \
    "755 0755" || return 1
  runtime_validate_management_file \
    "$MANAGEMENT_SOURCE_SECRET_VERIFIER" \
    "Management source Token verifier" "755 0755" || return 1
  runtime_assert_management_sources_have_no_auth_token || return 1
  runtime_select_compose_access || return 1
  runtime_prepare_compose_snapshots
}

main() {
  local container_status="unknown"
  local docker_health="unavailable"
  local server_status="unavailable"
  local process_status="not_running"
  local auth_status="unavailable"
  local runtime_mode="unknown"
  local message_status="unavailable"
  local worker_status="unavailable"
  local worker_health="unavailable"
  local worker_heartbeat="unavailable"
  local initial_wechat_identity="" final_wechat_identity="" encoded_chat=""
  local worker_container_id=""
  local configuration_ok=1 token_ok=1 docker_ok=0
  local agent_runtime_attested=0
  local container_query_ok=0 worker_query_ok=0 process_identity_ok=0

  prepare_status_management_configuration || configuration_ok=0
  if ! validate_configuration; then
    configuration_ok=0
  fi
  if ! resolve_python; then
    configuration_ok=0
  fi
  if [ "$configuration_ok" -eq 1 ] &&
    ! runtime_verify_gateway_contract; then
    configuration_ok=0
  fi
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    configuration_ok=0
  fi
  if [ "$configuration_ok" -eq 1 ] && ! runtime_acquire_lock shared; then
    configuration_ok=0
  fi
  if [ "$configuration_ok" -eq 1 ]; then
    if ! load_auth_token; then
      token_ok=0
    fi
  else
    token_ok=0
  fi

  if [ "$configuration_ok" -eq 1 ] && runtime_select_docker; then
    docker_ok=1
    if container_status="$(agent_container_state)"; then
      container_query_ok=1
      if [ "$container_status" = "running" ] && [ "$token_ok" -eq 1 ] &&
        runtime_attest_agent_compose &&
        runtime_attest_actual_agent_container; then
        agent_runtime_attested=1
        docker_health="$(container_health_status "$CONTAINER_NAME" 2>/dev/null || printf unavailable)"
      elif [ "$container_status" = "running" ]; then
        container_status="contract_violation"
      fi
    else
      container_status="unavailable"
    fi
    if [ -f "$GATEWAY_COMPOSE_FILE" ] && [ -d "$GATEWAY_PROJECT_DIR" ] &&
      worker_status="$(gateway_worker_state)"; then
      worker_query_ok=1
    else
      worker_status="unavailable"
    fi
    if [ "$worker_status" = "running" ] &&
      worker_container_id="$(gateway_compose ps --status running --quiet \
        "$GATEWAY_SERVICE" 2>/dev/null)" &&
      [ -n "$worker_container_id" ]; then
      worker_health="$(container_health_status "$worker_container_id" 2>/dev/null || printf unavailable)"
      if [ "$worker_health" = "healthy" ] &&
        gateway_worker_heartbeat_is_healthy; then
        worker_heartbeat="verified"
      fi
    fi
  fi
  if [ "$configuration_ok" -eq 1 ] && [ "$agent_runtime_attested" -eq 1 ] &&
    check_agent_server 2>/dev/null; then
    server_status="reachable"
  fi
  if [ "$docker_ok" -eq 1 ] && [ "$agent_runtime_attested" -eq 1 ] &&
    initial_wechat_identity="$(runtime_wechat_process_identity)" &&
    [ -n "$initial_wechat_identity" ]; then
    process_status="running"
  fi
  if [ "$agent_runtime_attested" -eq 1 ]; then
    runtime_mode="$(detect_runtime_mode)"
  fi

  if [ "$token_ok" -eq 1 ] && fetch_auth_status; then
    auth_status="$AUTH_STATUS"
  fi
  if [ "$token_ok" -eq 1 ] &&
    encoded_chat="$(fetch_first_chat_path)" &&
    check_messages_api "$encoded_chat"; then
    message_status="chats and messages readable"
  fi

  if [ -n "$initial_wechat_identity" ] &&
    final_wechat_identity="$(runtime_wechat_process_identity)" &&
    [ "$final_wechat_identity" = "$initial_wechat_identity" ]; then
    process_identity_ok=1
  elif [ -n "$initial_wechat_identity" ]; then
    process_status="exited_or_replaced"
  fi

  print_status \
    "$container_status" "$docker_health" "$server_status" "$process_status" \
    "$auth_status" "$runtime_mode" "$message_status" "$worker_status" \
    "$worker_health" "$worker_heartbeat"

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
  if [ "$docker_health" != "healthy" ]; then
    error "agent-wechat Docker health is not healthy."
    return 3
  fi
  if [ "$server_status" != "reachable" ]; then
    error "Agent API health is not reachable."
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
  if [ "$message_status" != "chats and messages readable" ]; then
    error "Chats or messages API is not readable."
    return 1
  fi
  if [ "$worker_status" != "running" ] || [ "$worker_health" != "healthy" ] ||
    [ "$worker_heartbeat" != "verified" ]; then
    error "Gateway wechat-worker is not running, healthy, and heartbeat-verified."
    return 1
  fi
  return 0
}

main "$@"
