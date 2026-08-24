#!/bin/bash -p

# Shared configuration for the host-side agent-wechat management scripts.
set +x
set +a
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LANG=C.UTF-8
LC_ALL=C.UTF-8
export PATH LANG LC_ALL
CF_AGENT_WECHAT_TESTING="${CF_AGENT_WECHAT_TESTING:-0}"
unset PRODUCTION_MANAGEMENT_OVERRIDES
PRODUCTION_MANAGEMENT_OVERRIDES=""
_MANAGEMENT_OVERRIDE_NAMES=(
  API_URL WS_URL TOKEN_FILE SESSION_ID CONTAINER_NAME PYTHON_BIN
  REQUIREMENTS_FILE VENV_DIR CF_AGENT_WECHAT_VENV AGENT_WECHAT_IMAGE
  CF_AGENT_WECHAT_CURL_BIN
  AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT AGENT_WECHAT_CONTAINER_NAME
  COMPOSE_PROJECT_NAME PROXY RUST_LOG CF_AGENT_WECHAT_STORAGE_ROOT
  CF_AGENT_WECHAT_RUNTIME_ROOT CF_AGENT_WECHAT_ARCHIVE_ROOT
  CF_AGENT_WECHAT_MIN_FREE_BYTES CF_AGENT_WECHAT_MIN_FREE_PERCENT
  CF_AGENT_WECHAT_MIN_FREE_INODES CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES
  CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES
  CF_AGENT_WECHAT_COMPOSE_FILE CF_AGENT_WECHAT_ENV_FILE
  CF_AGENT_WECHAT_LOCK_FILE CF_AGENT_WECHAT_RUNTIME_UID
  CF_AGENT_WECHAT_RUNTIME_GID CF_AGENT_WECHAT_RUNTIME_MODE
  CF_AGENT_WECHAT_MANAGEMENT_GID CF_AGENT_GATEWAY_COMPOSE_FILE
  CF_AGENT_GATEWAY_PROJECT_DIR CF_AGENT_GATEWAY_ENV_FILE
  CF_AGENT_GATEWAY_HEARTBEAT_COMMAND
  CF_AGENT_WECHAT_DOCKER_BIN CF_AGENT_WECHAT_SYSTEMCTL_BIN
  CF_AGENT_WECHAT_DOCKER_SOCKET_PATH CF_AGENT_WECHAT_DF_BIN
  CF_AGENT_WECHAT_TEST_ROOT
  CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT
  CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT
  CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT
  CF_AGENT_WECHAT_TOKEN CF_AGENT_WECHAT_TOKEN_FILE AUTH_TOKEN
  CF_GATEWAY_API_TOKEN CF_AGENT_GATEWAY_ADMIN_TOKEN HERMES_API_KEY
  CF_AGENT_WECHAT_TEST_PIP_INSTALL_TIMEOUT
  CF_AGENT_WECHAT_TEST_PIP_NETWORK_TIMEOUT
  CF_AGENT_WECHAT_TEST_PIP_RETRIES
  CF_AGENT_WECHAT_TEST_VENV_CREATE_TIMEOUT
  HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
  NO_PROXY no_proxy
  TMPDIR
  HTTP_CONNECT_TIMEOUT HTTP_TIMEOUT DOCKER_READ_TIMEOUT LOGIN_TIMEOUT_MS
  LOGIN_CONFIRM_RETRIES LOGIN_CONFIRM_INTERVAL SERVER_READY_TIMEOUT
  WECHAT_READY_TIMEOUT WECHAT_STABLE_SECONDS POST_LOGIN_READY_TIMEOUT
  RUNTIME_POLL_INTERVAL DOCKER_COMMAND_TIMEOUT COMPOSE_COMMAND_TIMEOUT
  WORKER_READY_TIMEOUT WORKER_STABLE_SECONDS WORKER_HEARTBEAT_TIMEOUT
  TOKEN_SCAN_TIMEOUT ARCHIVE_TOOL_TIMEOUT CF_AGENT_WECHAT_TEST_ARCHIVE_TOOL_TIMEOUT
)
if [ "$CF_AGENT_WECHAT_TESTING" != "1" ]; then
  if [[ -v _CF_AGENT_WECHAT_EARLY_OVERRIDES ]]; then
    IFS=, read -r -a _entry_override_names <<< \
      "$_CF_AGENT_WECHAT_EARLY_OVERRIDES"
    for _entry_override_name in "${_entry_override_names[@]}"; do
      _entry_override_allowed=0
      [ -n "$_entry_override_name" ] || continue
      for _override_name in "${_MANAGEMENT_OVERRIDE_NAMES[@]}"; do
        if [ "$_entry_override_name" = "$_override_name" ]; then
          _entry_override_allowed=1
          break
        fi
      done
      if [ "$_entry_override_allowed" -ne 1 ]; then
        printf '%s\n' \
          'Production management early environment state is invalid.' >&2
        return 1
      fi
    done
    PRODUCTION_MANAGEMENT_OVERRIDES="$_CF_AGENT_WECHAT_EARLY_OVERRIDES"
  fi
  for _override_name in "${_MANAGEMENT_OVERRIDE_NAMES[@]}"; do
    if [[ -v $_override_name ]]; then
      PRODUCTION_MANAGEMENT_OVERRIDES+="${PRODUCTION_MANAGEMENT_OVERRIDES:+,}${_override_name}"
    fi
    unset "$_override_name"
  done
else
  for _override_name in "${_MANAGEMENT_OVERRIDE_NAMES[@]}"; do
    export -n "${_override_name?}" 2>/dev/null || :
    case "$_override_name" in
      AUTH_TOKEN|CF_AGENT_WECHAT_TOKEN|CF_GATEWAY_API_TOKEN|CF_AGENT_GATEWAY_ADMIN_TOKEN|HERMES_API_KEY|PROXY|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|NO_PROXY|no_proxy)
        unset "$_override_name"
        ;;
    esac
  done
fi
readonly PRODUCTION_MANAGEMENT_OVERRIDES
unset _entry_override_allowed _entry_override_name _entry_override_names \
  _override_name

if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
  case "$-" in
    *p*) ;;
    *) printf '%s\n' 'Production management requires direct protected-mode script execution.' >&2; return 1 ;;
  esac
  unset BASH_ENV ENV CDPATH
fi

if [ "${CF_AGENT_WECHAT_TESTING:-0}" = "1" ]; then
  SCRIPTS_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
else
  if ! _scripts_dir_declaration="$(
    declare -p _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR 2>/dev/null
  )"; then
    printf '%s\n' 'Production management scripts directory is unavailable.' >&2
    return 1
  fi
  case "$_scripts_dir_declaration" in
    'declare -r '*) ;;
    *)
      printf '%s\n' 'Production management scripts directory is not immutable.' >&2
      return 1
      ;;
  esac
  SCRIPTS_DIR="$_CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR"
  readonly SCRIPTS_DIR
  unset _scripts_dir_declaration
fi

# Production endpoints are replaced after docker/.env has been safely parsed.
API_URL="${API_URL:-http://127.0.0.1:6174}"
DEFAULT_TOKEN_FILE="/srv/storage/cf-agent-wechat/secrets/auth-token"
TOKEN_FILE="${TOKEN_FILE:-$DEFAULT_TOKEN_FILE}"
SESSION_ID="${SESSION_ID:-default}"
CONTAINER_NAME="${CONTAINER_NAME:-${AGENT_WECHAT_CONTAINER_NAME:-cf-agent-wechat}}"

if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
  HTTP_CONNECT_TIMEOUT="${HTTP_CONNECT_TIMEOUT:-5}"
  HTTP_TIMEOUT="${HTTP_TIMEOUT:-45}"
  DOCKER_READ_TIMEOUT="${DOCKER_READ_TIMEOUT:-20}"
  LOGIN_TIMEOUT_MS="${LOGIN_TIMEOUT_MS:-300000}"
  LOGIN_CONFIRM_RETRIES="${LOGIN_CONFIRM_RETRIES:-5}"
  LOGIN_CONFIRM_INTERVAL="${LOGIN_CONFIRM_INTERVAL:-2}"
else
  HTTP_CONNECT_TIMEOUT=5
  HTTP_TIMEOUT=45
  DOCKER_READ_TIMEOUT=20
  LOGIN_TIMEOUT_MS=300000
  LOGIN_CONFIRM_RETRIES=5
  LOGIN_CONFIRM_INTERVAL=2
fi

if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
  PYTHON_BIN="${PYTHON_BIN:-python3}"
  REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${SCRIPTS_DIR}/requirements.txt}"
  if [ -n "${XDG_DATA_HOME:-}" ]; then
    _DEFAULT_DATA_HOME="$XDG_DATA_HOME"
  elif [ -n "${HOME:-}" ]; then
    _DEFAULT_DATA_HOME="${HOME}/.local/share"
  else
    _DEFAULT_DATA_HOME=""
  fi
  VENV_DIR="${VENV_DIR:-${CF_AGENT_WECHAT_VENV:-${_DEFAULT_DATA_HOME:+${_DEFAULT_DATA_HOME}/cf-agent-wechat/venv}}}"
else
  PYTHON_BIN=/usr/bin/python3
  REQUIREMENTS_FILE="${SCRIPTS_DIR}/requirements.txt"
  _operator_home="$(/usr/bin/python3 -I -c '
import os
import pwd
print(pwd.getpwuid(os.getuid()).pw_dir, end="")
' 2>/dev/null || true)"
  case "$_operator_home" in
    /*) VENV_DIR="${_operator_home}/.local/share/cf-agent-wechat/venv" ;;
    *) VENV_DIR="" ;;
  esac
  unset _operator_home
fi
if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
  CURL_BIN="${CF_AGENT_WECHAT_CURL_BIN:-curl}"
else
  CURL_BIN=/usr/bin/curl
fi

WS_URL="${WS_URL:-ws://127.0.0.1:6174/api/ws/login}"

unset AUTH_TOKEN
AUTH_TOKEN=""
export -n AUTH_TOKEN
AUTH_STATUS=""
LAST_ERROR=""
LOGIN_PYTHON=""
SUDO_AUTHORIZED=0

error() {
  printf '错误：%s\n' "$*" >&2
}

reject_production_management_overrides() {
  case "$CF_AGENT_WECHAT_TESTING" in
    0) ;;
    1) return 0 ;;
    *)
      LAST_ERROR="CF_AGENT_WECHAT_TESTING must be 0 or 1."
      return 1
      ;;
  esac
  if [ -n "$PRODUCTION_MANAGEMENT_OVERRIDES" ]; then
    LAST_ERROR="Production management environment overrides are forbidden: ${PRODUCTION_MANAGEMENT_OVERRIDES}."
    return 1
  fi
}

configure_agent_endpoints() {
  local bind_ip="$1"
  local port="$2"

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    return 0
  fi
  API_URL="http://${bind_ip}:${port}"
  WS_URL="ws://${bind_ip}:${port}/api/ws/login"
}

testing_canonical_path() {
  local path="$1"
  local component canonical="/"
  local -a components path_stack=()

  case "$path" in
    /*) ;;
    *)
      LAST_ERROR="Testing asset paths must be absolute."
      return 1
      ;;
  esac
  if [[ "$path" =~ [[:cntrl:]] ]]; then
    LAST_ERROR="Testing asset path contains control characters."
    return 1
  fi
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    case "$component" in
      ''|.) ;;
      ..)
        if [ "${#path_stack[@]}" -gt 0 ]; then
          unset "path_stack[${#path_stack[@]} - 1]"
        fi
        ;;
      *) path_stack+=("$component") ;;
    esac
  done
  if [ "${#path_stack[@]}" -gt 0 ]; then
    printf -v canonical '/%s' "${path_stack[@]}"
  fi
  printf '%s' "$canonical"
}

testing_path_overlaps_production_asset() {
  local candidate="$1"
  local production="$2"
  local candidate_canonical production_canonical

  candidate_canonical="$(testing_canonical_path "$candidate")" || return 2
  production_canonical="$(testing_canonical_path "$production")" || return 2
  case "${candidate_canonical}/" in
    "${production_canonical}/"*) return 0 ;;
  esac
  case "${production_canonical}/" in
    "${candidate_canonical}/"*) return 0 ;;
  esac
  return 1
}

testing_validate_unprivileged_identity() {
  local real_uid effective_uid

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  real_uid="$(/usr/bin/id -ru 2>/dev/null)" || {
    LAST_ERROR="Testing identity could not be verified."
    return 1
  }
  effective_uid="$(/usr/bin/id -u 2>/dev/null)" || {
    LAST_ERROR="Testing identity could not be verified."
    return 1
  }
  if [ "$real_uid" = 0 ] || [ "$effective_uid" = 0 ] ||
    [ "$real_uid" != "$effective_uid" ]; then
    LAST_ERROR="Testing helpers require one non-root, non-elevated identity."
    return 1
  fi
}

testing_validate_root_contract() {
  local canonical resolved metadata owner mode production_root

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  testing_validate_unprivileged_identity || return 1
  canonical="$(testing_canonical_path "${CF_AGENT_WECHAT_TEST_ROOT:-}")" || {
    LAST_ERROR="Testing requires an explicit isolated CF_AGENT_WECHAT_TEST_ROOT."
    return 1
  }
  if [ "$canonical" = / ] || [ -L "$canonical" ] || [ ! -d "$canonical" ] ||
    ! resolved="$(/usr/bin/readlink -f -- "$canonical" 2>/dev/null)" ||
    [ "$resolved" != "$canonical" ]; then
    LAST_ERROR="Testing root must be an existing non-symlink canonical directory."
    return 1
  fi
  for production_root in \
    /srv/storage/cf-agent-wechat /opt/cf-agent-gateway /opt/cf-agent-wechat; do
    if testing_path_overlaps_production_asset "$canonical" "$production_root"; then
      LAST_ERROR="Testing root overlaps a production asset."
      return 1
    fi
  done
  metadata="$(/usr/bin/stat -Lc '%u:%a' -- "$canonical" 2>/dev/null)" || {
    LAST_ERROR="Testing root metadata could not be verified."
    return 1
  }
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  if [ "$owner" != "$(/usr/bin/id -u)" ] ||
    (( (8#$mode & 8#022) != 0 )); then
    LAST_ERROR="Testing root must be caller-owned and not group/other writable."
    return 1
  fi
}

validate_testing_asset_isolation() {
  local path="$1" label="$2" confinement="${3:-confined}"
  local canonical resolved root_canonical production_root

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  testing_validate_root_contract || return 1
  canonical="$(testing_canonical_path "$path")" || return 1
  resolved="$(/usr/bin/readlink -m -- "$canonical" 2>/dev/null)" || {
    LAST_ERROR="Testing ${label} could not be resolved safely."
    return 1
  }
  for production_root in \
    /srv/storage/cf-agent-wechat /opt/cf-agent-gateway /opt/cf-agent-wechat; do
    if testing_path_overlaps_production_asset "$canonical" "$production_root" ||
      testing_path_overlaps_production_asset "$resolved" "$production_root"; then
      LAST_ERROR="Testing ${label} overlaps a production asset."
      return 1
    fi
  done
  if [ "$confinement" = confined ]; then
    root_canonical="$(testing_canonical_path "$CF_AGENT_WECHAT_TEST_ROOT")" ||
      return 1
    case "${canonical}/" in
      "${root_canonical}/"?*) ;;
      *)
        LAST_ERROR="Testing ${label} must remain within the isolated testing root."
        return 1
        ;;
    esac
    case "${resolved}/" in
      "${root_canonical}/"?*) ;;
      *)
        LAST_ERROR="Testing ${label} resolves outside the isolated testing root."
        return 1
        ;;
    esac
  fi
}

restore_testing_management_path() {
  local requested="$1"
  local first_component metadata owner mode
  local fixed_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  case "$requested" in
    ""|"$fixed_path")
      PATH="$fixed_path"
      ;;
    *)
      first_component="${requested%%:*}"
      validate_testing_asset_isolation \
        "$first_component" "command path directory" confined || return 1
      if [ -L "$first_component" ] || [ ! -d "$first_component" ]; then
        LAST_ERROR="Testing command path prefix must be a non-symlink directory."
        return 1
      fi
      metadata="$(/usr/bin/stat -Lc '%u:%a' -- "$first_component" 2>/dev/null)" || {
        LAST_ERROR="Testing command path prefix metadata could not be verified."
        return 1
      }
      owner="${metadata%%:*}"
      mode="${metadata#*:}"
      if [ "$owner" != "$(/usr/bin/id -u)" ] ||
        (( (8#$mode & 8#022) != 0 )); then
        LAST_ERROR="Testing command path prefix must be caller-owned and not group/other writable."
        return 1
      fi
      PATH="${first_component}:${fixed_path}"
      ;;
  esac
  export PATH
}

validate_testing_executable_isolation() {
  local requested="$1" label="$2" policy="${3:-confined}"
  local resolved canonical metadata owner mode links trusted_system=0

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  testing_validate_root_contract || return 1
  if [ -z "$requested" ] ||
    ! resolved="$(command -v -- "$requested" 2>/dev/null)"; then
    LAST_ERROR="Testing ${label} executable is unavailable."
    return 1
  fi
  case "$resolved" in
    /*) ;;
    *)
      LAST_ERROR="Testing ${label} executable must resolve to an absolute path."
      return 1
      ;;
  esac
  canonical="$(/usr/bin/readlink -f -- "$resolved" 2>/dev/null)" || {
    LAST_ERROR="Testing ${label} executable could not be resolved safely."
    return 1
  }
  if [ ! -f "$canonical" ] || [ ! -x "$canonical" ]; then
    LAST_ERROR="Testing ${label} executable has unsafe metadata."
    return 1
  fi
  metadata="$(/usr/bin/stat -Lc '%u:%a:%h' -- "$canonical" 2>/dev/null)" || {
    LAST_ERROR="Testing ${label} executable metadata could not be verified."
    return 1
  }
  owner="${metadata%%:*}"
  mode="${metadata#*:}"; mode="${mode%%:*}"
  links="${metadata##*:}"
  if [ "$policy" = system-or-confined ] && [ "$owner" = 0 ] &&
    (( (8#$mode & 8#022) == 0 )); then
    case "$label:$canonical" in
      Python:/usr/bin/python|Python:/usr/bin/python3|Python:/usr/bin/python3.*|\
      Python:/usr/local/bin/python|Python:/usr/local/bin/python3|\
      Python:/usr/local/bin/python3.*|\
      curl:/usr/bin/curl|curl:/usr/local/bin/curl|\
      df:/usr/bin/df|df:/usr/local/bin/df|\
      timeout:/usr/bin/timeout)
        trusted_system=1
        ;;
    esac
  fi
  if [ "$trusted_system" -eq 0 ]; then
    [ ! -L "$resolved" ] && [ "$links" = 1 ] &&
      { [ "$owner" = 0 ] || [ "$owner" = "$(/usr/bin/id -u)" ]; } || {
        LAST_ERROR="Testing ${label} mock must have a trusted owner and one link."
        return 1
      }
    if (( (8#$mode & 8#022) != 0 )); then
      LAST_ERROR="Testing ${label} mock must not be group/other writable."
      return 1
    fi
    validate_testing_asset_isolation "$canonical" "${label} mock" confined ||
      return 1
  else
    validate_testing_asset_isolation "$canonical" "${label} executable" external ||
      return 1
  fi
}

validate_testing_login_asset_isolation() {
  local requirements_canonical scripts_canonical helper

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  validate_testing_asset_isolation "$SCRIPTS_DIR" "scripts directory" external ||
    return 1
  validate_testing_asset_isolation "$VENV_DIR" "venv directory" confined ||
    return 1
  validate_testing_asset_isolation "${TMPDIR:-}" "temporary directory" confined ||
    return 1
  scripts_canonical="$(testing_canonical_path "$SCRIPTS_DIR")" || return 1
  requirements_canonical="$(testing_canonical_path "$REQUIREMENTS_FILE")" ||
    return 1
  case "${requirements_canonical}/" in
    "${scripts_canonical}/"?*)
      validate_testing_asset_isolation \
        "$REQUIREMENTS_FILE" "requirements file" external || return 1
      ;;
    *)
      validate_testing_asset_isolation \
        "$REQUIREMENTS_FILE" "requirements file" confined || return 1
      ;;
  esac
  for helper in qr_login.py ensure-login-environment.sh \
    verify_login_dependencies.py requirements.txt; do
    validate_testing_asset_isolation \
      "${SCRIPTS_DIR}/${helper}" "login helper" external || return 1
  done
  validate_testing_executable_isolation \
    "$PYTHON_BIN" "Python" system-or-confined || return 1
  validate_testing_executable_isolation \
    "$CURL_BIN" "curl" system-or-confined || return 1
}

validate_testing_token_isolation() {
  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  validate_testing_asset_isolation "$TOKEN_FILE" "Token path" confined
}

validate_testing_endpoint_isolation() {
  local api_port ws_port

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  testing_validate_root_contract || return 1
  if ! [[ "$API_URL" =~ ^http://127[.]0[.]0[.]1:([1-9][0-9]{0,4})$ ]]; then
    LAST_ERROR="Testing API endpoint must use an isolated loopback port."
    return 1
  fi
  api_port="${BASH_REMATCH[1]}"
  if ! [[ "$WS_URL" =~ ^ws://127[.]0[.]0[.]1:([1-9][0-9]{0,4})/api/ws/login([?][^[:cntrl:]]*)?$ ]]; then
    LAST_ERROR="Testing WebSocket endpoint must use an isolated loopback port."
    return 1
  fi
  ws_port="${BASH_REMATCH[1]}"
  if [ "$api_port" -gt 65535 ] || [ "$ws_port" -gt 65535 ] ||
    [ "$api_port" -eq 6174 ] || [ "$ws_port" -eq 6174 ]; then
    LAST_ERROR="Testing endpoints must not use the production Agent port."
    return 1
  fi
}

validate_testing_docker_isolation() {
  local requested_docker resolved_docker canonical_docker
  local socket_path canonical_socket
  local system_docker

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  testing_validate_root_contract || return 1
  requested_docker="${DOCKER_BIN:-${CF_AGENT_WECHAT_DOCKER_BIN:-}}"
  if [ -z "$requested_docker" ] ||
    ! resolved_docker="$(command -v -- "$requested_docker" 2>/dev/null)"; then
    LAST_ERROR="Testing Docker requires an explicit fake executable."
    return 1
  fi
  case "$resolved_docker" in
    /*) ;;
    *)
      LAST_ERROR="Testing Docker fake executable must resolve to an absolute path."
      return 1
      ;;
  esac
  if [ -L "$resolved_docker" ] || [ ! -f "$resolved_docker" ] ||
    [ ! -x "$resolved_docker" ] ||
    ! canonical_docker="$(/usr/bin/readlink -f -- "$resolved_docker" 2>/dev/null)"; then
    LAST_ERROR="Testing Docker fake executable has unsafe metadata."
    return 1
  fi
  validate_testing_executable_isolation \
    "$resolved_docker" "Docker" confined || return 1
  for system_docker in /usr/bin/docker /usr/local/bin/docker /bin/docker /snap/bin/docker; do
    if [ -e "$system_docker" ] &&
      [ "$canonical_docker" -ef "$system_docker" ]; then
      LAST_ERROR="Testing mode must not invoke the system Docker CLI."
      return 1
    fi
  done

  socket_path="${DOCKER_SOCKET_PATH:-${CF_AGENT_WECHAT_DOCKER_SOCKET_PATH:-}}"
  if [ -z "${CF_AGENT_WECHAT_DOCKER_SOCKET_PATH:-}" ] ||
    [ "$socket_path" != "$CF_AGENT_WECHAT_DOCKER_SOCKET_PATH" ]; then
    LAST_ERROR="Testing Docker requires an explicit isolated socket path."
    return 1
  fi
  canonical_socket="$(testing_canonical_path "$socket_path")" || return 1
  case "$canonical_socket" in
    /var/run/docker.sock|/run/docker.sock)
      LAST_ERROR="Testing mode must not use the production Docker socket."
      return 1
      ;;
  esac
  validate_testing_asset_isolation \
    "$canonical_socket" "Docker socket" confined || return 1
  if [ ! -S "$socket_path" ] || [ -L "$socket_path" ]; then
    LAST_ERROR="Testing Docker socket must be an isolated Unix socket."
    return 1
  fi
  if [ -z "${CONTAINER_NAME:-}" ] ||
    [ "$CONTAINER_NAME" = "cf-agent-wechat" ]; then
    LAST_ERROR="Testing container name must be isolated from production."
    return 1
  fi
}

authorize_management_sudo() {
  local purpose="${1:-执行生产管理操作}"

  if [ "$(id -u)" -eq 0 ] || [ "$SUDO_AUTHORIZED" -eq 1 ]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    LAST_ERROR="$purpose 需要 sudo，但系统未安装 sudo。"
    return 1
  fi
  printf '需要 sudo 权限以%s；请在当前终端完成授权。\n' "$purpose" >&2
  if ! sudo -v; then
    LAST_ERROR="$purpose 失败：当前用户没有可用的 sudo 权限。"
    return 1
  fi
  SUDO_AUTHORIZED=1
}

resolve_python() {
  local candidate candidate_path
  local -a candidates

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    candidates=("$PYTHON_BIN" python3 python)
  else
    candidates=(/usr/bin/python3)
  fi
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    candidate_path="$(command -v -- "$candidate" 2>/dev/null || true)"
    case "$candidate_path" in
      /*) ;;
      *) continue ;;
    esac
    if /usr/bin/env -i \
      HOME=/nonexistent \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      "$candidate_path" -I -c 'import json' >/dev/null 2>&1; then
      PYTHON_BIN="$candidate_path"
      return 0
    fi
  done

  LAST_ERROR="No approved Python 3 interpreter is available."
  return 1
}

run_isolated_python() {
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    "$PYTHON_BIN" -I "$@"
  else
    /usr/bin/env -i \
      HOME=/nonexistent \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      "$PYTHON_BIN" -I "$@"
  fi
}
validate_configuration() {
  local api_port ws_port

  reject_production_management_overrides || return 1
  validate_testing_token_isolation || return 1
  validate_testing_endpoint_isolation || return 1
  validate_testing_login_asset_isolation || return 1
  if ! [[ "$API_URL" =~ ^http://127[.]0[.]0[.]1:([1-9][0-9]{0,4})$ ]]; then
    LAST_ERROR="API_URL must be a validated loopback endpoint."
    return 1
  fi
  api_port="${BASH_REMATCH[1]}"
  if ! [[ "$WS_URL" =~ ^ws://127[.]0[.]0[.]1:([1-9][0-9]{0,4})/api/ws/login([?][^[:cntrl:]]*)?$ ]]; then
    LAST_ERROR="WS_URL must be a validated loopback WebSocket endpoint."
    return 1
  fi
  ws_port="${BASH_REMATCH[1]}"
  if [ "$CF_AGENT_WECHAT_TESTING" != "1" ] && [ "$api_port" != "$ws_port" ]; then
    LAST_ERROR="API and WebSocket endpoints must use the same validated loopback port."
    return 1
  fi
  if [ "$api_port" -gt 65535 ] || [ "$ws_port" -gt 65535 ]; then
    LAST_ERROR="Agent management endpoint port is invalid."
    return 1
  fi
  if [ "$CF_AGENT_WECHAT_TESTING" != "1" ]; then
    if [ "$TOKEN_FILE" != "$DEFAULT_TOKEN_FILE" ] ||
      [ "$SESSION_ID" != "default" ]; then
      LAST_ERROR="Production Token path and session ID must use the approved fixed values."
      return 1
    fi
  fi

  case "$SESSION_ID" in
    *$'\r'*|*$'\n'*)
      LAST_ERROR="SESSION_ID 不能包含换行符。"
      return 1
      ;;
  esac
  if ! [[ "$LOGIN_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="LOGIN_TIMEOUT_MS must be positive."
    return 1
  fi
  if ! [[ "$LOGIN_CONFIRM_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="LOGIN_CONFIRM_RETRIES must be positive."
    return 1
  fi
  if ! [[ "$LOGIN_CONFIRM_INTERVAL" =~ ^[0-9]+$ ]]; then
    LAST_ERROR="LOGIN_CONFIRM_INTERVAL must be a non-negative integer."
    return 1
  fi
  if ! [[ "$HTTP_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="HTTP_CONNECT_TIMEOUT must be a positive integer."
    return 1
  fi
  if ! [[ "$HTTP_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="HTTP_TIMEOUT must be a positive integer."
    return 1
  fi
  if ! [[ "$DOCKER_READ_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="DOCKER_READ_TIMEOUT must be a positive integer."
    return 1
  fi

}

validate_token_file_content() {
  local token_path="$1"

  /usr/bin/od -An -v -t u1 -- "$token_path" | /usr/bin/awk '
    BEGIN { bytes = 0; ended = 0; bad = 0; long = 0; control = 0; nonhex = 0 }
    {
      for (field = 1; field <= NF; field++) {
        byte = $field + 0
        if (byte == 10) {
          if (bytes == 0 || ended) bad = 1
          ended = 1
        } else {
          if (ended) bad = 1
          bytes++
          if (bytes > 8192) long = 1
          if (byte < 32 || byte == 127) control = 1
          if (!((byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102))) nonhex = 1
        }
      }
    }
    END {
      if (bytes == 0 || bad) exit 48
      if (long) exit 49
      if (control) exit 50
      if (bytes != 64 || nonhex) exit 51
    }
  '
}

set_token_content_error() {
  case "$1" in
    48) LAST_ERROR="token 文件必须只包含一行非空 token：${TOKEN_FILE}" ;;
    49) LAST_ERROR="token 内容不能超过 8192 字节：${TOKEN_FILE}" ;;
    50) LAST_ERROR="token 不能包含 C0 或 DEL 控制字符：${TOKEN_FILE}" ;;
    51) LAST_ERROR="Token must contain exactly 64 lowercase hexadecimal characters: ${TOKEN_FILE}" ;;
    *) LAST_ERROR="无法验证 token 文件内容：${TOKEN_FILE}" ;;
  esac
}

validate_token_path_ancestors() {
  local current

  current="$(/usr/bin/dirname -- "$TOKEN_FILE")" || {
    LAST_ERROR="Token path ancestors could not be inspected: ${TOKEN_FILE}"
    return 1
  }
  while [ "$current" != / ]; do
    if [ -L "$current" ]; then
      LAST_ERROR="Token path must not contain symbolic link ancestors: ${TOKEN_FILE}"
      return 1
    fi
    current="$(/usr/bin/dirname -- "$current")" || {
      LAST_ERROR="Token path ancestors could not be inspected: ${TOKEN_FILE}"
      return 1
    }
  done
}

load_auth_token() {
  local token_value token_status metadata token_dir current_uid

  AUTH_TOKEN=""
  export -n AUTH_TOKEN
  validate_testing_token_isolation || return 1
  token_dir="$(dirname -- "$TOKEN_FILE")"
  if [ -r "$TOKEN_FILE" ]; then
    validate_token_path_ancestors || return 1
    if [ -L "$TOKEN_FILE" ]; then
      LAST_ERROR="token 文件不能是符号链接：${TOKEN_FILE}"
      return 1
    fi
    if [ ! -f "$TOKEN_FILE" ]; then
      LAST_ERROR="token 路径不是普通文件：${TOKEN_FILE}"
      return 1
    fi
    token_dir="$(dirname -- "$TOKEN_FILE")"
    if [ -L "$token_dir" ] || [ ! -d "$token_dir" ]; then
      LAST_ERROR="secrets 路径必须是非符号链接目录：${token_dir}"
      return 1
    fi
    if [ "$TOKEN_FILE" = "$DEFAULT_TOKEN_FILE" ]; then
      if ! metadata="$(stat -Lc '%u:%g:%a' -- "$token_dir")" ||
        [ "$metadata" != "0:0:700" ]; then
        LAST_ERROR="secrets 目录必须保持 root:root 700：${token_dir}"
        return 1
      fi
      if ! metadata="$(stat -Lc '%u:%g:%a:%h' -- "$TOKEN_FILE")" ||
        [ "$metadata" != "0:0:600:1" ]; then
        LAST_ERROR="auth-token 必须保持 root:root 600 且无额外硬链接：${TOKEN_FILE}"
        return 1
      fi
    elif [ "$(uname -s)" = "Linux" ]; then
      current_uid="$(id -u)"
      if ! metadata="$(stat -Lc '%u:%a' -- "$token_dir")" ||
        [ "$metadata" != "$current_uid:700" ]; then
        LAST_ERROR="自定义 secrets 目录必须由当前用户持有且 mode 700：${token_dir}"
        return 1
      fi
      if ! metadata="$(stat -Lc '%u:%a:%h' -- "$TOKEN_FILE")" ||
        [ "$metadata" != "$current_uid:600:1" ]; then
        LAST_ERROR="自定义 auth-token 必须由当前用户持有、mode 600 且无额外硬链接：${TOKEN_FILE}"
        return 1
      fi
    fi
    if validate_token_file_content "$TOKEN_FILE"; then
      token_status=0
    else
      token_status=$?
    fi
    if [ "$token_status" -ne 0 ]; then
      set_token_content_error "$token_status"
      return 1
    fi
    if ! token_value="$(/bin/cat -- "$TOKEN_FILE")"; then
      LAST_ERROR="无法读取 token 文件：${TOKEN_FILE}"
      return 1
    fi
  else
    if [ "$CF_AGENT_WECHAT_TESTING" != "1" ] && [ "$TOKEN_FILE" != "$DEFAULT_TOKEN_FILE" ]; then
      LAST_ERROR="当前用户无法读取自定义 token 路径；sudo 读取仅允许默认路径：${DEFAULT_TOKEN_FILE}"
      return 1
    fi
    if ! authorize_management_sudo "读取受保护的生产 auth-token"; then
      return 1
    fi

    if token_value="$(
      sudo -n -- /bin/sh -c '
token_file=$1
secrets_dir=$2
current=$(/usr/bin/dirname -- "$token_file") || exit 52
while [ "$current" != / ]; do
  if [ -L "$current" ]; then
    exit 52
  fi
  current=$(/usr/bin/dirname -- "$current") || exit 52
done
if [ ! -e "$secrets_dir" ]; then
  exit 41
fi
if [ -L "$secrets_dir" ] || [ ! -d "$secrets_dir" ]; then
  exit 47
fi
if [ -L "$token_file" ]; then
  exit 42
fi
if [ ! -e "$token_file" ]; then
  exit 41
fi
if [ ! -f "$token_file" ]; then
  exit 43
fi
if [ ! -r "$token_file" ]; then
  exit 44
fi
if [ "$(/usr/bin/stat -c "%u:%g:%a" "$secrets_dir")" != "0:0:700" ]; then
  exit 45
fi
if [ "$(/usr/bin/stat -Lc "%u:%g:%a:%h" "$token_file")" != "0:0:600:1" ]; then
  exit 46
fi
/usr/bin/od -An -v -t u1 -- "$token_file" | /usr/bin/awk "
  BEGIN { bytes = 0; ended = 0; bad = 0; long = 0; control = 0; nonhex = 0 }
  {
    for (field = 1; field <= NF; field++) {
      byte = \$field + 0
      if (byte == 10) {
        if (bytes == 0 || ended) bad = 1
        ended = 1
      } else {
        if (ended) bad = 1
        bytes++
        if (bytes > 8192) long = 1
        if (byte < 32 || byte == 127) control = 1
        if (!((byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102))) nonhex = 1
      }
    }
  }
  END {
    if (bytes == 0 || bad) exit 48
    if (long) exit 49
    if (control) exit 50
    if (bytes != 64 || nonhex) exit 51
  }
"
token_status=$?
if [ "$token_status" -ne 0 ]; then
  exit "$token_status"
fi
exec /bin/cat -- "$token_file"
' cf-agent-wechat-token-reader "$TOKEN_FILE" "$token_dir"
    )"; then
      token_status=0
    else
      token_status=$?
    fi
    case "$token_status" in
      0) ;;
      41) LAST_ERROR="token 文件不存在：${TOKEN_FILE}" ;;
      42) LAST_ERROR="token 文件不能是符号链接：${TOKEN_FILE}" ;;
      43) LAST_ERROR="token 路径不是普通文件：${TOKEN_FILE}" ;;
      44) LAST_ERROR="sudo 无法读取 token 文件：${TOKEN_FILE}" ;;
      45) LAST_ERROR="secrets 目录必须保持 root:root 700：/srv/storage/cf-agent-wechat/secrets" ;;
      46) LAST_ERROR="auth-token 必须保持 root:root 600 且无额外硬链接：${TOKEN_FILE}" ;;
      47) LAST_ERROR="secrets 路径必须是非符号链接目录：/srv/storage/cf-agent-wechat/secrets" ;;
      48) LAST_ERROR="token 文件必须只包含一行非空 token：${TOKEN_FILE}" ;;
      49) LAST_ERROR="token 内容不能超过 8192 字节：${TOKEN_FILE}" ;;
      50) LAST_ERROR="token 不能包含 C0 或 DEL 控制字符：${TOKEN_FILE}" ;;
      51) LAST_ERROR="Token must contain exactly 64 lowercase hexadecimal characters: ${TOKEN_FILE}" ;;
      52) LAST_ERROR="Token path must not contain symbolic link ancestors: ${TOKEN_FILE}" ;;
      *) LAST_ERROR="当前用户无法读取 token，且没有可用的 sudo 权限：${TOKEN_FILE}" ;;
    esac
    if [ "$token_status" -ne 0 ]; then
      return 1
    fi
  fi

  AUTH_TOKEN="$token_value"
  export -n AUTH_TOKEN
  if [ -z "$AUTH_TOKEN" ]; then
    LAST_ERROR="token 文件为空：${TOKEN_FILE}"
    return 1
  fi
  case "$AUTH_TOKEN" in
    *$'\r'*|*$'\n'*)
      LAST_ERROR="token 文件必须只包含一行 token：${TOKEN_FILE}"
      AUTH_TOKEN=""
      return 1
      ;;
  esac
}
run_agent_curl() {
  validate_testing_token_isolation || return 1
  validate_testing_endpoint_isolation || return 1
  /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "$CURL_BIN" "$@"
}

declare -a LOGIN_PYTHON_COMMAND=()

prepare_login_python_command() {
  validate_testing_token_isolation || return 1
  validate_testing_endpoint_isolation || return 1
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    LOGIN_PYTHON_COMMAND=("$LOGIN_PYTHON")
  else
    LOGIN_PYTHON_COMMAND=(
      /usr/bin/env -i
      HOME=/nonexistent
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      LANG=C.UTF-8 LC_ALL=C.UTF-8
      PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
      "$LOGIN_PYTHON" -I -B
    )
  fi
}

run_login_python() {
  prepare_login_python_command || return 1
  "${LOGIN_PYTHON_COMMAND[@]}" "$@"
}


api_request() {
  local method="$1"
  local path="$2"

  validate_testing_token_isolation || return 1
  validate_testing_endpoint_isolation || return 1
  printf 'Authorization: Bearer %s\nX-Session-Id: %s\n' \
    "$AUTH_TOKEN" "$SESSION_ID" | run_agent_curl \
    --disable \
    --noproxy '*' \
    --request "$method" \
    --fail \
    --silent \
    --show-error \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
    --max-time "$HTTP_TIMEOUT" \
    --header @- \
    "${API_URL}${path}"
}

parse_auth_response() {
  local response="$1"
  local parsed

  if ! parsed="$(printf '%s' "$response" | run_isolated_python -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError) as exc:
    print(f"认证状态响应不是有效 JSON：{exc}", file=sys.stderr)
    raise SystemExit(2)

if not isinstance(payload, dict):
    print("认证状态响应必须是 JSON 对象。", file=sys.stderr)
    raise SystemExit(2)

status = payload.get("status")
if not isinstance(status, str) or not status:
    print("认证状态响应缺少 status 字段。", file=sys.stderr)
    raise SystemExit(2)

if any(ord(character) < 0x20 or ord(character) == 0x7F for character in status):
    print("status contains an invalid control character.", file=sys.stderr)
    raise SystemExit(2)

sys.stdout.write(status)
')"; then
    LAST_ERROR="无法解析 agent-wechat 认证状态。"
    return 1
  fi

  # Read by the scripts that source this shared library.
  # shellcheck disable=SC2034
  AUTH_STATUS="$parsed"
}

fetch_auth_status() {
  local response

  if ! response="$(api_request GET /api/status/auth 2>/dev/null)"; then
    LAST_ERROR="认证状态接口调用失败。"
    return 1
  fi
  parse_auth_response "$response"
}

auth_status_is_qr_ready() {
  case "$1" in
    logged_out|qr_pending|waiting_for_qr|waiting_for_scan) return 0 ;;
    *) return 1 ;;
  esac
}

check_agent_server() {
  run_agent_curl \
    --disable \
    --noproxy '*' \
    --request GET \
    --fail \
    --silent \
    --show-error \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
    --max-time "$HTTP_TIMEOUT" \
    "${API_URL}/health" >/dev/null
}

parse_chats_response() {
  local response="$1"
  local mode="${2:-validate}"

  printf '%s' "$response" | run_isolated_python -c '
import json
import sys
from urllib.parse import quote

mode = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(2)

def chat_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        if value.get("success") is False or "error" in value:
            return None
        for key in ("chats", "data", "items", "results", "list"):
            if key in value:
                candidate = chat_list(value[key])
                if candidate is not None:
                    return candidate
    return None

chats = chat_list(payload)
if chats is None:
    raise SystemExit(2)
if mode == "validate":
    raise SystemExit(0)
if mode != "first":
    raise SystemExit(2)

for chat in chats:
    if not isinstance(chat, dict):
        continue
    for key in ("chatId", "chat_id", "id", "userName", "username"):
        value = chat.get(key)
        if isinstance(value, (str, int)) and str(value):
            sys.stdout.write(quote(str(value), safe=""))
            raise SystemExit(0)
raise SystemExit(3)
' "$mode"
}

check_chats_api() {
  local response

  if ! response="$(api_request GET /api/chats 2>/dev/null)"; then
    LAST_ERROR="聊天接口不可读。"
    return 1
  fi
  if ! parse_chats_response "$response" validate >/dev/null 2>&1; then
    LAST_ERROR="聊天接口未返回可识别的 JSON 列表。"
    return 1
  fi
}

fetch_first_chat_path() {
  local response encoded_chat

  if ! response="$(api_request GET /api/chats 2>/dev/null)"; then
    LAST_ERROR="聊天接口不可读。"
    return 1
  fi
  if ! encoded_chat="$(parse_chats_response "$response" first 2>/dev/null)"; then
    LAST_ERROR="聊天接口没有返回可用于验证的聊天。"
    return 1
  fi
  printf '%s' "$encoded_chat"
}

check_messages_api() {
  local encoded_chat="$1"
  local response

  if ! response="$(api_request GET "/api/messages/${encoded_chat}" 2>/dev/null)"; then
    LAST_ERROR="消息接口不可读。"
    return 1
  fi
  if ! printf '%s' "$response" | run_isolated_python -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(2)

def message_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        if value.get("success") is False or "error" in value:
            return None
        for key in ("messages", "data", "items", "results", "list"):
            if key in value:
                candidate = message_list(value[key])
                if candidate is not None:
                    return candidate
    return None

if message_list(payload) is None:
    raise SystemExit(2)
' >/dev/null 2>&1; then
    LAST_ERROR="消息接口未返回可识别的消息列表。"
    return 1
  fi
}

docker_readonly_capture() {
  local output status output_lower docker_bin timeout_bin
  local -a clean_env

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    docker_bin="${DOCKER_BIN:-${CF_AGENT_WECHAT_DOCKER_BIN:-}}"
    timeout_bin="${TIMEOUT_BIN:-/usr/bin/timeout}"
  else
    docker_bin="/usr/bin/docker"
    timeout_bin="/usr/bin/timeout"
  fi
  validate_testing_docker_isolation || return 1

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    clean_env=(
      -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY
      -u DOCKER_CERT_PATH -u DOCKER_CONFIG -u DOCKER_API_VERSION
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY
      -u http_proxy -u https_proxy -u all_proxy -u no_proxy
      -u AUTH_TOKEN -u CF_AGENT_WECHAT_TOKEN -u TOKEN_FILE
    )
  else
    clean_env=(
      -i HOME=/nonexistent
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      LANG=C.UTF-8 LC_ALL=C.UTF-8 DOCKER_CONFIG=/nonexistent
    )
  fi

  if output="$("$timeout_bin" --signal=TERM --kill-after=2s \
    "${DOCKER_READ_TIMEOUT}s" /usr/bin/env "${clean_env[@]}" \
    "$docker_bin" "$@" 2>&1)"; then
    printf '%s' "$output"
    return 0
  else
    status=$?
  fi
  output_lower="${output,,}"
  case "$output_lower" in
    *permission\ denied*|*access\ denied*|*operation\ not\ permitted*) ;;
    *) return "$status" ;;
  esac
  case "$output_lower" in
    *docker.sock*|*docker\ daemon\ socket*|*docker\ socket*|*connect\ to\ the\ docker\ daemon*) ;;
    *) return "$status" ;;
  esac
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    return "$status"
  fi
  command -v sudo >/dev/null 2>&1 || return "$status"
  if ! authorize_management_sudo "查询本机 Docker"; then
    return "$status"
  fi
  "$timeout_bin" --signal=TERM --kill-after=2s "${DOCKER_READ_TIMEOUT}s" \
    sudo -n -- /usr/bin/env "${clean_env[@]}" "$docker_bin" "$@"
}

get_wechat_process_identity() {
  # Variables in this snippet are expanded by the shell inside the container.
  # shellcheck disable=SC2016
  docker_readonly_capture exec "$CONTAINER_NAME" sh -c '
launcher_real="$(readlink -f /usr/bin/wechat 2>/dev/null || true)"
case "$launcher_real" in
  /*) ;;
  *) exit 1 ;;
esac

for process_dir in /proc/[0-9]*; do
  proc_exe="$(readlink "$process_dir/exe" 2>/dev/null || true)"
  [ "$proc_exe" = "$launcher_real" ] || continue
  process_id="${process_dir##*/}"
  start_time="$(awk "{ print \$22 }" "$process_dir/stat" 2>/dev/null || true)"
  [ -n "$start_time" ] || continue
  printf "%s:%s\n" "$process_id" "$start_time"
  exit 0
done
exit 1
' 2>/dev/null
}

wechat_process_is_running() {
  local identity

  identity="$(get_wechat_process_identity)" && [ -n "$identity" ]
}

detect_container_status() {
  local inspect_output inspect_state line

  if ! inspect_output="$(docker_readonly_capture inspect \
    --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)"; then
    return 1
  fi

  inspect_state=""
  while IFS= read -r line; do
    case "$line" in
      true|false)
        if [ -n "$inspect_state" ] && [ "$inspect_state" != "$line" ]; then
          return 1
        fi
        inspect_state="$line"
        ;;
    esac
  done <<< "$inspect_output"

  case "$inspect_state" in
    true)
      printf 'running'
      return 0
      ;;
    false)
      printf 'stopped'
      return 0
      ;;
    *) return 1 ;;
  esac
}

validate_venv_location() {
  local expected metadata path venv_parent

  if [ -z "$VENV_DIR" ]; then
    LAST_ERROR="Could not determine the ordinary-user venv path."
    return 1
  fi
  case "$VENV_DIR" in
    /*) ;;
    *)
      LAST_ERROR="venv path must be absolute: ${VENV_DIR}"
      return 1
      ;;
  esac
  if [ -L "$VENV_DIR" ]; then
    LAST_ERROR="venv path must not be a symlink: ${VENV_DIR}"
    return 1
  fi
  venv_parent="$(/usr/bin/dirname -- "$VENV_DIR")"
  if [ -L "$venv_parent" ]; then
    LAST_ERROR="venv parent must not be a symlink: ${venv_parent}"
    return 1
  fi

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    validate_testing_login_asset_isolation || return 1
    if [ -e "$VENV_DIR" ] && [ ! -d "$VENV_DIR" ]; then
      LAST_ERROR="venv path is not a directory: ${VENV_DIR}"
      return 1
    fi
    if [ -d "$VENV_DIR" ] && { [ ! -O "$VENV_DIR" ] ||
      [ ! -w "$VENV_DIR" ]; }; then
      LAST_ERROR="test venv must be owned and writable by the current user."
      return 1
    fi
    return 0
  fi

  expected="$(/usr/bin/id -u):$(/usr/bin/id -g):700:directory"
  for path in "$venv_parent" "$VENV_DIR"; do
    [ -e "$path" ] || continue
    if [ -L "$path" ] || [ ! -d "$path" ]; then
      LAST_ERROR="managed venv leaf is not a real directory: ${path}"
      return 1
    fi
    metadata="$(/usr/bin/stat -Lc '%u:%g:%a:%F' -- "$path" 2>/dev/null)" || {
      LAST_ERROR="managed venv metadata is not readable: ${path}"
      return 1
    }
    if [ "$metadata" != "$expected" ]; then
      LAST_ERROR="managed venv owner/mode must match the current user and 0700: ${path}"
      return 1
    fi
  done
}

ensure_login_environment() {
  local dependency_verifier="${SCRIPTS_DIR}/verify_login_dependencies.py"
  local environment_helper="${SCRIPTS_DIR}/ensure-login-environment.sh"
  local pip_install_timeout=300
  local pip_network_timeout=15
  local pip_retries=2
  local venv_create_timeout=60
  local selected_python

  set +x
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    pip_install_timeout="${CF_AGENT_WECHAT_TEST_PIP_INSTALL_TIMEOUT:-$pip_install_timeout}"
    pip_network_timeout="${CF_AGENT_WECHAT_TEST_PIP_NETWORK_TIMEOUT:-$pip_network_timeout}"
    pip_retries="${CF_AGENT_WECHAT_TEST_PIP_RETRIES:-$pip_retries}"
    venv_create_timeout="${CF_AGENT_WECHAT_TEST_VENV_CREATE_TIMEOUT:-$venv_create_timeout}"
  fi
  if ! resolve_python || ! validate_venv_location; then
    return 1
  fi
  if [ -L "$environment_helper" ] || [ ! -f "$environment_helper" ] ||
    [ ! -r "$environment_helper" ] ||
    [ -L "$dependency_verifier" ] || [ ! -f "$dependency_verifier" ] ||
    [ ! -r "$dependency_verifier" ]; then
    LAST_ERROR="The QR dependency management helpers are missing or unsafe."
    return 1
  fi
  if ! selected_python="$(/usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /bin/bash "$environment_helper" \
    "$PYTHON_BIN" \
    "$VENV_DIR" \
    "$REQUIREMENTS_FILE" \
    "$dependency_verifier" \
    "$pip_install_timeout" \
    "$pip_network_timeout" \
    "$pip_retries" \
    "$venv_create_timeout" \
    "$CF_AGENT_WECHAT_TESTING")"; then
    LAST_ERROR="The QR login dependency environment could not be verified."
    LOGIN_PYTHON=""
    return 1
  fi
  case "$selected_python" in
    "${VENV_DIR}/bin/python"|"${VENV_DIR}/Scripts/python.exe") ;;
    *)
      # Read by the entrypoint that sources this shared library.
      # shellcheck disable=SC2034
      LAST_ERROR="The dependency helper returned an unexpected Python path."
      LOGIN_PYTHON=""
      return 1
      ;;
  esac
  LOGIN_PYTHON="$selected_python"
}

CF_AGENT_WECHAT_COMMON_LOADED=1
# Read by scripts that source this shared library.
# shellcheck disable=SC2034
readonly CF_AGENT_WECHAT_COMMON_LOADED
