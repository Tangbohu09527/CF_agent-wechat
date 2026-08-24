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
_management_test_passthrough_names=(
  API_URL WS_URL TOKEN_FILE SESSION_ID CONTAINER_NAME PYTHON_BIN
  REQUIREMENTS_FILE VENV_DIR CF_AGENT_WECHAT_VENV AGENT_WECHAT_IMAGE
  CF_AGENT_WECHAT_CURL_BIN AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT
  AGENT_WECHAT_CONTAINER_NAME COMPOSE_PROJECT_NAME RUST_LOG
  CF_AGENT_WECHAT_STORAGE_ROOT CF_AGENT_WECHAT_RUNTIME_ROOT
  CF_AGENT_WECHAT_ARCHIVE_ROOT CF_AGENT_WECHAT_COMPOSE_FILE
  CF_AGENT_WECHAT_MIN_FREE_BYTES CF_AGENT_WECHAT_MIN_FREE_PERCENT
  CF_AGENT_WECHAT_MIN_FREE_INODES CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES
  CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES
  CF_AGENT_WECHAT_ENV_FILE CF_AGENT_WECHAT_LOCK_FILE
  CF_AGENT_WECHAT_RUNTIME_UID CF_AGENT_WECHAT_RUNTIME_GID
  CF_AGENT_WECHAT_RUNTIME_MODE CF_AGENT_WECHAT_MANAGEMENT_GID
  CF_AGENT_GATEWAY_COMPOSE_FILE CF_AGENT_GATEWAY_PROJECT_DIR
  CF_AGENT_GATEWAY_ENV_FILE CF_AGENT_GATEWAY_HEARTBEAT_COMMAND
  CF_AGENT_WECHAT_DOCKER_BIN CF_AGENT_WECHAT_SYSTEMCTL_BIN
  CF_AGENT_WECHAT_DOCKER_SOCKET_PATH CF_AGENT_WECHAT_DF_BIN
  CF_AGENT_WECHAT_TEST_ROOT
  CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT
  CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT
  CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT
  CF_AGENT_WECHAT_TOKEN_FILE CF_AGENT_WECHAT_TEST_PIP_INSTALL_TIMEOUT
  CF_AGENT_WECHAT_TEST_PIP_NETWORK_TIMEOUT CF_AGENT_WECHAT_TEST_PIP_RETRIES
  CF_AGENT_WECHAT_TEST_VENV_CREATE_TIMEOUT TMPDIR HTTP_CONNECT_TIMEOUT
  HTTP_TIMEOUT DOCKER_READ_TIMEOUT LOGIN_TIMEOUT_MS LOGIN_CONFIRM_RETRIES
  LOGIN_CONFIRM_INTERVAL SERVER_READY_TIMEOUT WECHAT_READY_TIMEOUT
  WECHAT_STABLE_SECONDS POST_LOGIN_READY_TIMEOUT RUNTIME_POLL_INTERVAL
  DOCKER_COMMAND_TIMEOUT COMPOSE_COMMAND_TIMEOUT WORKER_READY_TIMEOUT
  WORKER_STABLE_SECONDS WORKER_HEARTBEAT_TIMEOUT TOKEN_SCAN_TIMEOUT
  ARCHIVE_TOOL_TIMEOUT CF_AGENT_WECHAT_TEST_ARCHIVE_TOOL_TIMEOUT
)
if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
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
    if [[ -v $_management_env_name ]]; then
      _CF_AGENT_WECHAT_EARLY_OVERRIDES+="${_CF_AGENT_WECHAT_EARLY_OVERRIDES:+,}${_management_env_name}"
    fi
    unset "$_management_env_name"
  done
else
  for _management_env_name in "${_management_test_passthrough_names[@]}"; do
    export -n "${_management_env_name?}" 2>/dev/null || :
  done
fi
for _management_sensitive_name in \
  AUTH_TOKEN CF_AGENT_WECHAT_TOKEN CF_GATEWAY_API_TOKEN \
  CF_AGENT_GATEWAY_ADMIN_TOKEN HERMES_API_KEY PROXY \
  HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy \
  NO_PROXY no_proxy; do
  unset "$_management_sensitive_name"
done
unset _management_sensitive_name
readonly _CF_AGENT_WECHAT_EARLY_OVERRIDES
unset _management_env_name
if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ] &&
  [ -n "$_CF_AGENT_WECHAT_EARLY_OVERRIDES" ]; then
  printf 'Production management environment overrides are forbidden: %s.\n' \
    "$_CF_AGENT_WECHAT_EARLY_OVERRIDES" >&2
  exit 1
fi

unset _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
START_QR_LOGIN="${SCRIPT_DIR}/start-qr-login.sh"

if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
  _management_uid="$(/usr/bin/id -u)"
  _management_target_fd=""

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

  if [ "${BASH_SOURCE[0]##*/}" != login.sh ] ||
    [ -L "${BASH_SOURCE[0]}" ] ||
    ! _management_validate_node "$SCRIPT_DIR" directory ||
    ! _management_validate_node "${SCRIPT_DIR}/login.sh" file ||
    ! _management_validate_node "$START_QR_LOGIN" file; then
    exit 1
  fi
  _management_target_path_metadata="$MANAGEMENT_NODE_METADATA"
  if ! exec {_management_target_fd}<"$START_QR_LOGIN"; then
    printf '%s\n' 'Forced fresh QR entry could not be opened.' >&2
    exit 1
  fi
  if ! _management_target_fd_metadata="$(
    /usr/bin/stat -Lc '%d:%i:%u:%g:%a:%h:%F' -- \
      "/proc/self/fd/${_management_target_fd}" 2>/dev/null
  )" ||
    [ -L "$START_QR_LOGIN" ] ||
    ! _management_target_path_after="$(
      /usr/bin/stat -c '%d:%i:%u:%g:%a:%h:%F' -- \
        "$START_QR_LOGIN" 2>/dev/null
    )" ||
    [ "$_management_target_path_metadata" != \
      "$_management_target_fd_metadata" ] ||
    [ "$_management_target_path_metadata" != \
      "$_management_target_path_after" ]; then
    exec {_management_target_fd}<&-
    printf '%s\n' 'Forced fresh QR entry changed while loading.' >&2
    exit 1
  fi

  unset -f _management_validate_node
  unset _management_uid MANAGEMENT_NODE_METADATA \
    _management_target_fd_metadata _management_target_path_after \
    _management_target_path_metadata
fi

if [ "${CF_AGENT_WECHAT_TESTING:-0}" = "1" ]; then
  _management_test_root="${CF_AGENT_WECHAT_TEST_ROOT:-}"
  _management_fixed_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  case "$_management_test_root" in
    /*) ;;
    *) printf '%s\n' 'Testing requires an absolute isolated root.' >&2; exit 1 ;;
  esac
  if [ "$_management_test_root" = / ] || [ -L "$_management_test_root" ] ||
    [ ! -d "$_management_test_root" ] ||
    ! _management_test_root_resolved="$(
      /usr/bin/readlink -f -- "$_management_test_root" 2>/dev/null
    )" || [ "$_management_test_root_resolved" != "$_management_test_root" ] ||
    ! _management_test_root_metadata="$(
      /usr/bin/stat -Lc '%u:%a' -- "$_management_test_root" 2>/dev/null
    )" ||
    [ "${_management_test_root_metadata%%:*}" != "$(/usr/bin/id -u)" ] ||
    (( (8#${_management_test_root_metadata#*:} & 8#022) != 0 )); then
    printf '%s\n' 'Testing root failed the caller-owned confinement contract.' >&2
    exit 1
  fi
  case "${_management_test_root}/" in
    /srv/storage/cf-agent-wechat/*|/opt/cf-agent-gateway/*|/opt/cf-agent-wechat/*)
      printf '%s\n' 'Testing root overlaps a production asset.' >&2
      exit 1
      ;;
  esac
  _management_test_path_prefix="${_CF_AGENT_WECHAT_TEST_CALLER_PATH%%:*}"
  case "$_management_test_path_prefix" in
    /usr/local/sbin|/usr/local/bin|/usr/sbin|/usr/bin|/sbin|/bin)
      PATH="$_management_fixed_path"
      ;;
    "${_management_test_root}/"*)
      if [ -L "$_management_test_path_prefix" ] ||
        [ ! -d "$_management_test_path_prefix" ] ||
        ! _management_test_path_metadata="$(
          /usr/bin/stat -Lc '%u:%a' -- "$_management_test_path_prefix" 2>/dev/null
        )" ||
        [ "${_management_test_path_metadata%%:*}" != "$(/usr/bin/id -u)" ] ||
        (( (8#${_management_test_path_metadata#*:} & 8#022) != 0 )); then
        printf '%s\n' 'Testing command path failed the confinement contract.' >&2
        exit 1
      fi
      PATH="${_management_test_path_prefix}:${_management_fixed_path}"
      ;;
    *)
      printf '%s\n' 'Testing command path is outside the isolated root.' >&2
      exit 1
      ;;
  esac
  export PATH
  for _management_env_name in "${_management_test_passthrough_names[@]}"; do
    [[ -v $_management_env_name ]] && export "${_management_env_name?}"
  done
fi

cat >&2 <<'EOF'
Notice: login.sh is a compatibility wrapper. Production login always runs the
forced fresh QR lifecycle through start-qr-login.sh.
EOF

if [ "${CF_AGENT_WECHAT_TESTING:-0}" = "1" ]; then
  exec /bin/bash -p "$START_QR_LOGIN" "$@"
fi
exec /bin/bash -p "/proc/self/fd/${_management_target_fd}" "$@"
