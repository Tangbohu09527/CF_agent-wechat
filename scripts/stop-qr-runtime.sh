#!/bin/bash -p
set -euo pipefail

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
    CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT \
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
      export -n "${_management_env_name?}" 2>/dev/null || :
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

  if [ "${BASH_SOURCE[0]##*/}" != stop-qr-runtime.sh ] ||
    [ -L "${BASH_SOURCE[0]}" ] ||
    ! _management_validate_node "$SCRIPT_DIR" directory ||
    ! _management_validate_node "${SCRIPT_DIR}/stop-qr-runtime.sh" file; then
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

DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ./scripts/stop-qr-runtime.sh [--dry-run]

Stop Gateway wechat-worker and agent-wechat without deleting the runtime,
Token, container, or any session archive.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

print_status() {
  local container_status="$1"
  local worker_status="$2"

  printf '%s\n' '================================'
  printf '%s\n' 'QR Runtime Stop Status'
  printf '%s\n' '================================'
  printf 'Container:\n  %s\n' "$container_status"
  printf 'Gateway WeChat Worker:\n  %s\n' "$worker_status"
  printf 'Runtime:\n  preserved\n'
  printf 'Token:\n  preserved\n'
  printf 'Session Archives:\n  preserved\n'
  printf '%s\n' '================================'
}

main() {
  local container_status worker_status

  parse_args "$@"

  if ! runtime_validate_stop_configuration; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! validate_configuration; then
    error "$LAST_ERROR"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' 'Dry run: worker, container, runtime, Token, and archives are unchanged.'
    return 0
  fi
  if ! runtime_acquire_lock; then
    error "$LAST_ERROR"
    return 1
  fi

  if ! stop_gateway_worker; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! stop_agent_container; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! container_status="$(agent_container_state)"; then
    error "agent-wechat container state could not be queried after stop."
    return 1
  fi
  if [ "$container_status" = "running" ]; then
    error "agent-wechat did not stop."
    return 1
  fi
  if ! worker_status="$(gateway_worker_state)"; then
    error "Gateway wechat-worker state could not be queried after stop."
    return 1
  fi
  if [ "$worker_status" != "stopped" ]; then
    error "Gateway wechat-worker did not stop."
    return 1
  fi
  print_status "$container_status" "$worker_status"
}

main "$@"
