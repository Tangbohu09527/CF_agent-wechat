#!/usr/bin/env bash
set -Eeuo pipefail

set +x
umask 077
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_AGENT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=gateway-controller-common.sh
source "${SCRIPT_DIR}/gateway-controller-common.sh"

AGENT_ROOT="${CF_AGENT_WECHAT_ROOT:-$DEFAULT_AGENT_ROOT}"
AGENT_COMPOSE_FILE="${CF_AGENT_WECHAT_COMPOSE_FILE:-${AGENT_ROOT}/docker/compose.cfserver.yaml}"
AGENT_ENV_FILE="${CF_AGENT_WECHAT_ENV_FILE:-${AGENT_ROOT}/docker/.env}"
STORAGE_ROOT="/srv/storage/cf-agent-wechat"
RUNTIME_ROOT="${STORAGE_ROOT}/runtime"
ARCHIVE_ROOT="${STORAGE_ROOT}/session-archive"
SECRETS_ROOT="/srv/storage/cf-agent-wechat/secrets"
TOKEN_FILE="${SECRETS_ROOT}/auth-token"
LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"
LEGACY_HOME_ROOT="${STORAGE_ROOT}/wechat-home"

GATEWAY_RUNTIME_CONTROL="/opt/cf-agent-gateway/deploy/wechat-runtime-control"

# Service identity is persistent deployment configuration, not the sudo caller.
unset CF_AGENT_WECHAT_RUNTIME_UID CF_AGENT_WECHAT_RUNTIME_GID CF_AGENT_WECHAT_RUNTIME_MODE
RUNTIME_UID=1000
RUNTIME_GID=1000
RUNTIME_MODE=700
DOCKER_TIMEOUT="${CF_BOOTSTRAP_DOCKER_TIMEOUT:-30}"
COMPOSE_TIMEOUT="${CF_BOOTSTRAP_COMPOSE_TIMEOUT:-120}"
TIMEOUT_GRACE=2

NETWORK_NAME="cf-internal"
NETWORK_ALIAS="cf-agent-wechat"
AGENT_SERVICE="agent-wechat"
AGENT_PROJECT="cf-agent-wechat"

TESTING="${CF_BOOTSTRAP_TESTING:-0}"
OS_RELEASE_FILE="${CF_BOOTSTRAP_OS_RELEASE_FILE:-/etc/os-release}"
DOCKER_BIN="${CF_BOOTSTRAP_DOCKER_BIN:-}"
SYSTEMCTL_BIN="${CF_BOOTSTRAP_SYSTEMCTL_BIN:-}"
DOCKER_SOCKET_PATH="${CF_BOOTSTRAP_DOCKER_SOCKET_PATH:-/var/run/docker.sock}"
OPENSSL_BIN="/usr/bin/openssl"
TIMEOUT_BIN="/usr/bin/timeout"

EFFECTIVE_UID="$(id -u)"
# The actual caller is the management identity; never trust SUDO_UID/SUDO_USER.
MANAGEMENT_UID="$EFFECTIVE_UID"
SUDO_AUTHORIZED=0
DOCKER_USE_SUDO=0
NORMALIZED_PATH=""
ATTESTATION_FILE=""

ENV_IMAGE=""
ENV_BIND_IP=""
ENV_PORT=""
ENV_CONTAINER=""
ENV_PROJECT=""
ENV_STORAGE_ROOT=""
ENV_RUNTIME_ROOT=""
ENV_ARCHIVE_ROOT=""
ENV_RUST_LOG=""

log() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$ATTESTATION_FILE" ]; then
    rm -f -- "$ATTESTATION_FILE"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap-cfserver.sh

Prepare and validate the production deployment. This command never creates a
WeChat session, starts agent-wechat, or starts Gateway controlled workers.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

validate_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer"
}

validate_positive_uint() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer"
}

validate_mode() {
  [[ "$2" =~ ^[0-7]{3}$ ]] || die "$1 must be a three-digit octal mode"
}

validate_absolute_path() {
  local label="$1" path="$2"
  case "$path" in /*) ;; *) die "$label must be an absolute path" ;; esac
  case "$path" in
    *[[:cntrl:]]*) die "$label must not contain control characters" ;;
    */../*|*/..) die "$label must not contain a parent path segment" ;;
  esac
}

validate_dotenv_safe_path() {
  local label="$1" path="$2" LC_ALL=C
  local pattern='^/[-A-Za-z0-9._/@%+,=:~]*$'
  [[ "$path" =~ $pattern ]] ||
    die "$label contains characters that are unsafe in docker/.env"
}

normalize_path() {
  local label="$1" path="$2" normalized
  validate_absolute_path "$label" "$path"
  validate_dotenv_safe_path "$label" "$path"
  normalized="$(realpath -m -s -- "$path" 2>/dev/null)" ||
    die "$label could not be normalized"
  [ "$normalized" != / ] || die "$label must not resolve to the filesystem root"
  validate_dotenv_safe_path "$label normalized value" "$normalized"
  NORMALIZED_PATH="$normalized"
}

path_is_within() {
  case "${1}/" in "${2}/"*) return 0 ;; *) return 1 ;; esac
}

run_with_hard_timeout() {
  local seconds="$1" soft
  local -a privilege=()
  shift
  if [ "${1:-}" = --privileged ]; then
    privilege=(privileged)
    shift
  fi
  if [ "$seconds" -le "$TIMEOUT_GRACE" ]; then
    "${privilege[@]}" "$TIMEOUT_BIN" --signal=KILL "${seconds}s" "$@"
    return
  fi
  soft=$((seconds - TIMEOUT_GRACE))
  "${privilege[@]}" "$TIMEOUT_BIN" --signal=TERM --kill-after="${TIMEOUT_GRACE}s" "${soft}s" "$@"
}

authorize_privilege() {
  if [ "$EFFECTIVE_UID" = 0 ]; then
    SUDO_AUTHORIZED=1
    return
  fi
  require_command sudo
  log "root access is required for protected deployment paths; authorize sudo"
  sudo -v || die "sudo authorization failed"
  sudo -n -- true >/dev/null 2>&1 ||
    die "sudo authorization did not provide a non-interactive follow-up path"
  SUDO_AUTHORIZED=1
}

privileged() {
  if [ "$EFFECTIVE_UID" = 0 ]; then
    "$@"
  else
    [ "$SUDO_AUTHORIZED" -eq 1 ] || die "internal error: sudo was not authorized"
    sudo -n -- "$@"
  fi
}

path_present() {
  privileged test -e "$1" || privileged test -L "$1"
}

validate_owner() {
  if [ "$2" != 0 ] && [ "$2" != "$MANAGEMENT_UID" ]; then
    die "$1 must be owned by root or the fixed management user"
  fi
}

validate_management_directory() {
  local label="$1" path="$2" metadata owner mode
  if privileged test -L "$path" || ! privileged test -d "$path"; then
    die "$label must be an existing non-symlink directory"
  fi
  metadata="$(privileged stat -c '%u:%a' -- "$path" 2>/dev/null)" ||
    die "$label metadata could not be read"
  owner="${metadata%%:*}"; mode="${metadata#*:}"
  validate_mode "$label mode" "$mode"
  validate_owner "$label" "$owner"
  if (( (8#$mode & 8#022) != 0 )); then
    die "$label must not be group/other writable"
  fi
}

validate_management_file() {
  local label="$1" path="$2" contract="$3" metadata owner mode links
  if privileged test -L "$path" || ! privileged test -f "$path"; then
    die "$label must be an existing non-symlink regular file"
  fi
  privileged test -r "$path" || die "$label must be readable"
  metadata="$(privileged stat -c '%u:%a:%h' -- "$path" 2>/dev/null)" ||
    die "$label metadata could not be read"
  owner="${metadata%%:*}"; mode="${metadata#*:}"; mode="${mode%%:*}"
  links="${metadata##*:}"
  validate_mode "$label mode" "$mode"
  validate_owner "$label" "$owner"
  [ "$links" = 1 ] || die "$label must not have additional hard links"
  case "$contract" in
    environment) case "$mode" in 600|640) ;; *) die "$label mode must be 600 or 640" ;; esac ;;
    protected) [ "$mode" = 600 ] || die "$label mode must be 600" ;;
    readonly)
      if (( (8#$mode & 8#022) != 0 )); then
        die "$label must not be group/other writable"
      fi
      ;;
    *) die "internal error: unknown file mode contract" ;;
  esac
}

ensure_root_directory() {
  local label="$1" path="$2" mode="$3" metadata
  privileged test ! -L "$path" || die "$label must not be a symlink"
  if ! privileged test -e "$path"; then
    privileged install -d -o 0 -g 0 -m "$mode" -- "$path" ||
      die "$label could not be created"
    log "created $label"
  elif ! privileged test -d "$path"; then
    die "$label is not a directory"
  fi
  metadata="$(privileged stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" ||
    die "$label metadata could not be read"
  [ "$metadata" = "0:0:${mode}" ] ||
    die "$label must be owned by root:root with mode $mode"
}

validate_runtime_directory() {
  local label="$1" path="$2" metadata
  path_present "$path" || return 0
  if privileged test -L "$path" || ! privileged test -d "$path"; then
    die "$label must be a non-symlink directory when present"
  fi
  metadata="$(privileged stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" ||
    die "$label metadata could not be read"
  [ "$metadata" = "${RUNTIME_UID}:${RUNTIME_GID}:${RUNTIME_MODE}" ] ||
    die "$label must match configured runtime owner and mode"
}

validate_empty_token_mountpoint() {
  local label="$1" path="$2" size
  path_present "$path" || return 0
  if privileged test -L "$path" || ! privileged test -f "$path"; then
    die "$label must be a regular non-symlink file when present"
  fi
  size="$(privileged stat -c '%s' -- "$path" 2>/dev/null)" ||
    die "$label size could not be inspected"
  [ "$size" = 0 ] || die "$label must remain empty so Token data is never archived"
}

validate_platform_and_tools() {
  local command_name os_id os_like
  for command_name in \
    apt-get awk chmod chown curl dirname dpkg-query env flock grep id install \
    mktemp mv openssl python3 readlink realpath rm stat timeout wc; do
    require_command "$command_name"
  done
  python3 -c 'import json, venv' >/dev/null 2>&1 ||
    die "Python 3 json and venv support are required"

  [ -f "$OS_RELEASE_FILE" ] || die "Linux os-release metadata is missing"
  os_id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print tolower($2); exit }' "$OS_RELEASE_FILE")"
  os_like="$(awk -F= '$1 == "ID_LIKE" { gsub(/"/, "", $2); print tolower($2); exit }' "$OS_RELEASE_FILE")"
  case " ${os_id} ${os_like} " in
    *' debian '*|*' ubuntu '*) ;;
    *) die "a Debian-family host is required" ;;
  esac

  validate_uint "CF_AGENT_WECHAT_RUNTIME_UID" "$RUNTIME_UID"
  validate_uint "CF_AGENT_WECHAT_RUNTIME_GID" "$RUNTIME_GID"
  validate_mode "CF_AGENT_WECHAT_RUNTIME_MODE" "$RUNTIME_MODE"
  validate_positive_uint "CF_BOOTSTRAP_DOCKER_TIMEOUT" "$DOCKER_TIMEOUT"
  validate_positive_uint "CF_BOOTSTRAP_COMPOSE_TIMEOUT" "$COMPOSE_TIMEOUT"
  case "$TESTING" in 0|1) ;; *) die "CF_BOOTSTRAP_TESTING must be 0 or 1" ;; esac
}

configure_external_tools() {
  if [ "$TESTING" = 0 ]; then
    if [ -n "${CF_BOOTSTRAP_DOCKER_BIN:-}" ] ||
      [ -n "${CF_BOOTSTRAP_SYSTEMCTL_BIN:-}" ] ||
      [ "${CF_BOOTSTRAP_OS_RELEASE_FILE:-/etc/os-release}" != /etc/os-release ] ||
      [ -n "${CF_BOOTSTRAP_DOCKER_SOCKET_PATH:-}" ]; then
      die "test-only tool overrides are not allowed in production mode"
    fi
    DOCKER_BIN="/usr/bin/docker"
    SYSTEMCTL_BIN="/usr/bin/systemctl"
    DOCKER_SOCKET_PATH="/var/run/docker.sock"
  else
    if [ -z "$DOCKER_BIN" ]; then
      DOCKER_BIN="$(command -v docker 2>/dev/null || true)"
    fi
    if [ -z "$SYSTEMCTL_BIN" ]; then
      SYSTEMCTL_BIN="$(command -v systemctl 2>/dev/null || true)"
    fi
  fi
  [ -n "$DOCKER_BIN" ] && [ -x "$DOCKER_BIN" ] || die "Docker CLI is unavailable"
  [ -n "$SYSTEMCTL_BIN" ] && [ -x "$SYSTEMCTL_BIN" ] || die "systemctl is unavailable"
  [ -x "$OPENSSL_BIN" ] || die "OpenSSL is unavailable"
  [ -x "$TIMEOUT_BIN" ] || die "timeout is unavailable"
  validate_absolute_path "Docker CLI" "$DOCKER_BIN"
  validate_absolute_path "systemctl" "$SYSTEMCTL_BIN"
  validate_absolute_path "OpenSSL" "$OPENSSL_BIN"
  validate_absolute_path "timeout" "$TIMEOUT_BIN"
  validate_absolute_path "Docker socket" "$DOCKER_SOCKET_PATH"
}

validate_external_tool_integrity() {
  local entry label path metadata owner mode links

  for entry in \
    "Docker CLI:$DOCKER_BIN" \
    "systemctl:$SYSTEMCTL_BIN" \
    "OpenSSL:$OPENSSL_BIN" \
    "timeout:$TIMEOUT_BIN"; do
    label="${entry%%:*}"
    path="${entry#*:}"
    if privileged test -L "$path" || ! privileged test -f "$path"; then
      die "$label must be a non-symlink regular file"
    fi
    metadata="$(privileged stat -c '%u:%a:%h' -- "$path" 2>/dev/null)" ||
      die "$label metadata could not be read"
    owner="${metadata%%:*}"
    mode="${metadata#*:}"
    mode="${mode%%:*}"
    links="${metadata##*:}"
    if [ "$TESTING" = 0 ]; then
      [ "$owner" = 0 ] || die "$label must be owned by root"
    else
      validate_owner "$label" "$owner"
    fi
    [ "$links" = 1 ] || die "$label must not have additional hard links"
    if (( (8#$mode & 8#022) != 0 )); then
      die "$label must not be group/other writable"
    fi
  done
}

validate_docker_socket() {
  local metadata owner mode links
  if privileged test -L "$DOCKER_SOCKET_PATH" ||
    ! privileged test -S "$DOCKER_SOCKET_PATH"; then
    die "Docker socket must be a non-symlink Unix socket"
  fi
  metadata="$(privileged stat -c '%u:%a:%h' -- "$DOCKER_SOCKET_PATH" 2>/dev/null)" ||
    die "Docker socket metadata could not be read"
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  mode="${mode%%:*}"
  links="${metadata##*:}"
  if [ "$TESTING" = 0 ]; then
    [ "$owner" = 0 ] || die "Docker socket must be owned by root"
  else
    validate_owner "Docker socket" "$owner"
  fi
  [ "$links" = 1 ] || die "Docker socket must not have additional hard links"
  if (( (8#$mode & 8#002) != 0 )); then
    die "Docker socket must not be writable by other"
  fi
}

reject_environment_overrides() {
  local variable

  # Legacy process-level management paths are not production inputs.
  unset CF_AGENT_WECHAT_STORAGE_ROOT CF_AGENT_WECHAT_RUNTIME_ROOT
  unset CF_AGENT_WECHAT_ARCHIVE_ROOT CF_AGENT_WECHAT_TOKEN_FILE

  for variable in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
    if [[ -v $variable ]]; then
      die "$variable cannot override the production local Docker daemon"
    fi
  done
  for variable in \
    AGENT_WECHAT_IMAGE AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT \
    AGENT_WECHAT_CONTAINER_NAME COMPOSE_PROJECT_NAME PROXY RUST_LOG; do
    if [[ -v $variable ]]; then
      die "$variable must come from the authoritative docker/.env file"
    fi
  done
}

proxy_is_safe() {
  local value="$1" port
  local pattern='^(http|https|socks5|socks5h)://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]*):([1-9][0-9]{0,4})$'

  [ -z "$value" ] && return 0
  [[ "$value" =~ $pattern ]] || return 1
  port="${BASH_REMATCH[3]}"
  [ "$port" -le 65535 ]
}

validate_gateway_runtime_contract() {
  local contract_json

  if ! gateway_controller_check_file run_with_hard_timeout \
    "$COMPOSE_TIMEOUT" --privileged 2>/dev/null; then
    die "Gateway Runtime Contract controller is unavailable or unsafe at the fixed path"
  fi
  contract_json="$(run_with_hard_timeout "$COMPOSE_TIMEOUT" --privileged \
    "$GATEWAY_RUNTIME_CONTROL" contract 2>/dev/null)" ||
    die "Gateway Runtime Contract v1 could not be read"
  [ "${#contract_json}" -le 65536 ] ||
    die "Gateway Runtime Contract response is too large"
  printf '%s' "$contract_json" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(2)
expected = {
    "contract_version": 1,
    "poll_worker_service": "worker",
    "delivery_worker_service": "delivery-worker",
    "dispatch_worker_service": "dispatch-worker",
    "token_mode": "file",
    "token_container_path": "/run/secrets/cf-agent-wechat-auth-token",
}
if not isinstance(payload, dict):
    raise SystemExit(2)
if set(payload) != set(expected):
    raise SystemExit(2)
if type(payload.get("contract_version")) is not int:
    raise SystemExit(2)
for key, value in expected.items():
    if payload.get(key) != value:
        raise SystemExit(2)
for key in expected:
    if key != "contract_version" and not isinstance(payload.get(key), str):
        raise SystemExit(2)
' || die "Gateway Runtime Contract does not match required version 1"
  unset contract_json
  pass "Gateway Runtime Contract v1 is compatible"
}

validate_and_normalize_paths() {
  local storage runtime archive token secrets expected_token
  normalize_path "CF_agent-wechat repository" "$AGENT_ROOT"; AGENT_ROOT="$NORMALIZED_PATH"
  normalize_path "production Compose" "$AGENT_COMPOSE_FILE"; AGENT_COMPOSE_FILE="$NORMALIZED_PATH"
  normalize_path "production environment" "$AGENT_ENV_FILE"; AGENT_ENV_FILE="$NORMALIZED_PATH"
  normalize_path "storage root" "$STORAGE_ROOT"; storage="$NORMALIZED_PATH"
  normalize_path "runtime root" "$RUNTIME_ROOT"; runtime="$NORMALIZED_PATH"
  normalize_path "archive root" "$ARCHIVE_ROOT"; archive="$NORMALIZED_PATH"
  normalize_path "Token file" "$TOKEN_FILE"; token="$NORMALIZED_PATH"
  normalize_path "secrets root" "$SECRETS_ROOT"; secrets="$NORMALIZED_PATH"
  normalize_path "Gateway Runtime controller" "$GATEWAY_RUNTIME_CONTROL"
  GATEWAY_RUNTIME_CONTROL="$NORMALIZED_PATH"

  STORAGE_ROOT="$storage"; RUNTIME_ROOT="$runtime"; ARCHIVE_ROOT="$archive"
  TOKEN_FILE="$token"; SECRETS_ROOT="$secrets"
  LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"; LEGACY_HOME_ROOT="${STORAGE_ROOT}/wechat-home"
  expected_token="/srv/storage/cf-agent-wechat/secrets/auth-token"
  [ "$TOKEN_FILE" = "$expected_token" ] ||
    die "Token file must remain at the fixed production host path"
  [ "$SECRETS_ROOT" = "/srv/storage/cf-agent-wechat/secrets" ] ||
    die "invalid fixed secrets root"
  [ "$GATEWAY_RUNTIME_CONTROL" = "/opt/cf-agent-gateway/deploy/wechat-runtime-control" ] ||
    die "Gateway Runtime controller must remain at the fixed path"
  path_is_within "$RUNTIME_ROOT" "$STORAGE_ROOT" ||
    die "runtime root must remain within the storage root"
  path_is_within "$ARCHIVE_ROOT" "$STORAGE_ROOT" ||
    die "archive root must remain within the storage root"
  if [ "$RUNTIME_ROOT" = "$ARCHIVE_ROOT" ] ||
    path_is_within "$RUNTIME_ROOT" "$ARCHIVE_ROOT" ||
    path_is_within "$ARCHIVE_ROOT" "$RUNTIME_ROOT"; then
    die "runtime and archive roots must be separate non-nested paths"
  fi
  if path_is_within "$TOKEN_FILE" "$RUNTIME_ROOT" ||
    path_is_within "$TOKEN_FILE" "$ARCHIVE_ROOT"; then
    die "Token file must remain outside runtime and archive roots"
  fi
}

validate_no_symlink_ancestors() {
  local label="$1" current
  current="$(dirname -- "$2")"
  while [ "$current" != / ]; do
    privileged test ! -L "$current" ||
      die "$label must not contain symbolic link ancestors"
    current="$(dirname -- "$current")"
  done
}

validate_input_path_chains() {
  validate_no_symlink_ancestors "repository root" "$AGENT_ROOT"
  validate_no_symlink_ancestors "production Compose file" "$AGENT_COMPOSE_FILE"
  validate_no_symlink_ancestors "production environment file" "$AGENT_ENV_FILE"
  validate_no_symlink_ancestors "storage root" "$STORAGE_ROOT"
  validate_no_symlink_ancestors "runtime root" "$RUNTIME_ROOT"
  validate_no_symlink_ancestors "archive root" "$ARCHIVE_ROOT"
  validate_no_symlink_ancestors "Token file" "$TOKEN_FILE"
  validate_no_symlink_ancestors "Gateway Runtime controller" "$GATEWAY_RUNTIME_CONTROL"
}

validate_repository_inputs() {
  validate_management_directory "repository root" "$AGENT_ROOT"
  validate_management_directory "docker configuration directory" "$(dirname -- "$AGENT_ENV_FILE")"
  validate_management_file "production Compose file" "$AGENT_COMPOSE_FILE" readonly
  validate_management_file "production environment file" "$AGENT_ENV_FILE" environment
  [ -r "${SCRIPT_DIR}/requirements.txt" ] || die "QR login requirements file is not readable"
}

parse_agent_environment() {
  local content line key value
  local -A seen=()
  content="$(privileged /bin/cat -- "$AGENT_ENV_FILE")" ||
    die "production environment file could not be read"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[[:cntrl:]]*) die "production environment contains a control character" ;; esac
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if ! [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      die "production environment contains an invalid assignment"
    fi
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    [ -z "${seen[$key]+x}" ] || die "production environment contains a duplicate key: $key"
    seen[$key]=1
    case "$value" in
      *'$'*|*'"'*|*"'"*|*\\*|*[[:space:]]*)
        die "production environment values must be unquoted, literal, and whitespace-free"
        ;;
    esac
    [[ "$value" != *$'\x60'* ]] ||
      die "production environment values must be unquoted, literal, and whitespace-free"
    case "$key" in
      *TOKEN*|*PASSWORD*|*SECRET*) die "production environment must not contain secret-bearing key: $key" ;;
      AGENT_WECHAT_IMAGE) ENV_IMAGE="$value" ;;
      AGENT_WECHAT_BIND_IP) ENV_BIND_IP="$value" ;;
      AGENT_WECHAT_PORT) ENV_PORT="$value" ;;
      AGENT_WECHAT_CONTAINER_NAME) ENV_CONTAINER="$value" ;;
      COMPOSE_PROJECT_NAME) ENV_PROJECT="$value" ;;
      CF_AGENT_WECHAT_STORAGE_ROOT) ENV_STORAGE_ROOT="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_ROOT) ENV_RUNTIME_ROOT="$value" ;;
      CF_AGENT_WECHAT_ARCHIVE_ROOT) ENV_ARCHIVE_ROOT="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_UID|CF_AGENT_WECHAT_RUNTIME_GID)
        [[ "$value" =~ ^(0|[1-9][0-9]{0,9})$ ]] && [ "$value" -le 2147483647 ] ||
          die "$key must be a valid numeric service identity"
        if [ "$key" = CF_AGENT_WECHAT_RUNTIME_UID ]; then RUNTIME_UID="$value"; else RUNTIME_GID="$value"; fi
        ;;
      CF_AGENT_WECHAT_RUNTIME_MODE)
        validate_mode "$key" "$value"
        (( (8#$value & 8#022) == 0 )) || die "runtime mode must not grant group/other write"
        RUNTIME_MODE="$value"
        ;;
      PROXY)
        proxy_is_safe "$value" ||
          die "PROXY must be unauthenticated and contain only an approved scheme, host, and port"
        ;;
      RUST_LOG) ENV_RUST_LOG="$value" ;;
      *) die "production environment contains an unsupported key: $key" ;;
    esac
  done <<< "$content"
  content=""

  [[ "$ENV_IMAGE" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]] ||
    die "AGENT_WECHAT_IMAGE must be pinned to an immutable sha256 digest"
  [ "$ENV_BIND_IP" = 127.0.0.1 ] || die "AGENT_WECHAT_BIND_IP must be 127.0.0.1"
  validate_positive_uint "AGENT_WECHAT_PORT" "$ENV_PORT"
  [ "$ENV_PORT" -le 65535 ] || die "AGENT_WECHAT_PORT must not exceed 65535"
  [[ "$ENV_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
    die "AGENT_WECHAT_CONTAINER_NAME is invalid"
  [ "$ENV_PROJECT" = "$AGENT_PROJECT" ] ||
    die "COMPOSE_PROJECT_NAME must be cf-agent-wechat"
  [ -n "$ENV_STORAGE_ROOT" ] || die "docker/.env must define CF_AGENT_WECHAT_STORAGE_ROOT"
  [ -n "$ENV_RUNTIME_ROOT" ] || die "docker/.env must define CF_AGENT_WECHAT_RUNTIME_ROOT"
  [ -n "$ENV_ARCHIVE_ROOT" ] || die "docker/.env must define CF_AGENT_WECHAT_ARCHIVE_ROOT"
  normalize_path "CF_AGENT_WECHAT_STORAGE_ROOT in docker/.env" "$ENV_STORAGE_ROOT"
  [ "$NORMALIZED_PATH" = "$STORAGE_ROOT" ] ||
    die "docker/.env storage root differs from the selected production storage root"
  normalize_path "CF_AGENT_WECHAT_RUNTIME_ROOT in docker/.env" "$ENV_RUNTIME_ROOT"
  [ "$NORMALIZED_PATH" = "$RUNTIME_ROOT" ] ||
    die "docker/.env runtime root differs from the selected production runtime root"
  normalize_path "CF_AGENT_WECHAT_ARCHIVE_ROOT in docker/.env" "$ENV_ARCHIVE_ROOT"
  [ "$NORMALIZED_PATH" = "$ARCHIVE_ROOT" ] ||
    die "docker/.env archive root differs from the selected production archive root"
  if [ -n "$ENV_RUST_LOG" ]; then
    case "$ENV_RUST_LOG" in error|warn|info) ;; *) die "RUST_LOG must be error, warn, or info" ;; esac
  fi
}

validate_systemd() {
  local state activity enablement agent_enablement
  state="$(run_with_hard_timeout "$DOCKER_TIMEOUT" "$SYSTEMCTL_BIN" is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) ;; *) die "systemd must be running or degraded" ;; esac
  activity="$(run_with_hard_timeout "$DOCKER_TIMEOUT" "$SYSTEMCTL_BIN" is-active docker.service 2>/dev/null || true)"
  [ "$activity" = active ] || die "docker.service must be active"
  enablement="$(run_with_hard_timeout "$DOCKER_TIMEOUT" "$SYSTEMCTL_BIN" is-enabled docker.service 2>/dev/null || true)"
  [ "$enablement" = enabled ] || die "docker.service must be enabled"
  agent_enablement="$(run_with_hard_timeout "$DOCKER_TIMEOUT" "$SYSTEMCTL_BIN" is-enabled cf-agent-wechat.service 2>/dev/null || true)"
  case "$agent_enablement" in
    enabled|enabled-runtime|linked|linked-runtime|alias)
      die "cf-agent-wechat.service must not be enabled for automatic boot"
      ;;
  esac
  pass "systemd and docker.service are ready"
}

execute_docker() {
  local seconds="$1" mode="$2"
  shift 2
  local -a clean=(
    -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH
  )
  local -a assignments=("CF_BOOTSTRAP_DOCKER_VIA_SUDO=0")

  case "$mode" in
    agent)
      clean+=(
        -u AGENT_WECHAT_IMAGE -u AGENT_WECHAT_BIND_IP -u AGENT_WECHAT_PORT
        -u AGENT_WECHAT_CONTAINER_NAME -u CF_AGENT_WECHAT_STORAGE_ROOT
        -u CF_AGENT_WECHAT_RUNTIME_ROOT -u CF_AGENT_WECHAT_ARCHIVE_ROOT
        -u CF_AGENT_WECHAT_TOKEN_FILE -u COMPOSE_PROJECT_NAME -u PROXY -u RUST_LOG
      )
      assignments+=(
        "CF_AGENT_WECHAT_STORAGE_ROOT=$STORAGE_ROOT"
        "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT"
        "CF_AGENT_WECHAT_ARCHIVE_ROOT=$ARCHIVE_ROOT"
        "CF_AGENT_WECHAT_TOKEN_FILE=$TOKEN_FILE"
      )
      ;;
    raw) ;;
    *) die "internal error: invalid Docker execution mode" ;;
  esac

  if [ "$DOCKER_USE_SUDO" -eq 1 ]; then
    assignments[0]="CF_BOOTSTRAP_DOCKER_VIA_SUDO=1"
    run_with_hard_timeout "$seconds" sudo -n -- env \
      "${clean[@]}" "${assignments[@]}" "$DOCKER_BIN" "$@"
  else
    run_with_hard_timeout "$seconds" env \
      "${clean[@]}" "${assignments[@]}" "$DOCKER_BIN" "$@"
  fi
}

docker_raw() {
  execute_docker "$DOCKER_TIMEOUT" raw "$@"
}

agent_compose() {
  execute_docker "$COMPOSE_TIMEOUT" agent compose \
    --env-file "$AGENT_ENV_FILE" \
    --project-directory "$AGENT_ROOT" \
    --project-name "$AGENT_PROJECT" \
    -f "$AGENT_COMPOSE_FILE" "$@"
}

validate_selected_docker_contract() {
  local context endpoint security live_restore compose_version
  context="$(docker_raw context show 2>/dev/null)" || die "Docker context could not be determined"
  [ "$context" = default ] || die "Docker context must be default"
  endpoint="$(docker_raw context inspect --format '{{.Endpoints.docker.Host}}' default 2>/dev/null)" ||
    die "Docker context endpoint could not be inspected"
  [ "$endpoint" = unix:///var/run/docker.sock ] ||
    die "Docker must use the local rootful unix:///var/run/docker.sock endpoint"
  security="$(docker_raw info --format '{{json .SecurityOptions}}' 2>/dev/null)" ||
    die "Docker security options could not be inspected"
  case "${security,,}" in *rootless*) die "rootless Docker is not supported" ;; esac
  live_restore="$(docker_raw info --format '{{json .LiveRestoreEnabled}}' 2>/dev/null)" ||
    die "Docker live-restore state could not be inspected"
  [ "$live_restore" = false ] ||
    die "Docker live-restore must be disabled for the forced fresh QR lifecycle"

  compose_version="$(docker_raw compose version --short 2>/dev/null)" ||
    die "Docker Compose v2 is unavailable"
  [[ "$compose_version" =~ ^v?2\. ]] || die "Docker Compose v2 is required"
}

select_local_rootful_docker() {
  if execute_docker "$DOCKER_TIMEOUT" raw --version >/dev/null 2>&1 &&
    execute_docker "$DOCKER_TIMEOUT" raw info >/dev/null 2>&1; then
    DOCKER_USE_SUDO=0
  elif [ "$EFFECTIVE_UID" != 0 ]; then
    DOCKER_USE_SUDO=1
    execute_docker "$DOCKER_TIMEOUT" raw info >/dev/null 2>&1 ||
      die "Docker daemon is unavailable through the authorized sudo -n path"
  else
    die "Docker daemon is unavailable"
  fi
  validate_selected_docker_contract
  pass "local rootful Docker and Compose v2 are ready"
}

select_compose_configuration_access() {
  if [ "$DOCKER_USE_SUDO" -eq 1 ] ||
    { [ -r "$AGENT_COMPOSE_FILE" ] && [ -r "$AGENT_ENV_FILE" ]; }; then
    return
  fi
  DOCKER_USE_SUDO=1
  docker_raw info >/dev/null 2>&1 ||
    die "protected Compose configuration is not accessible through sudo -n Docker"
  validate_selected_docker_contract
  log "using sudo -n for root-protected Compose configuration"
}

ensure_network() {
  local contract
  if ! docker_raw network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    docker_raw network create --driver bridge "$NETWORK_NAME" >/dev/null 2>&1 ||
      die "cf-internal network could not be created"
  fi
  contract="$(docker_raw network inspect --format '{{.Name}}|{{.Driver}}|{{.Scope}}' "$NETWORK_NAME" 2>/dev/null)" ||
    die "cf-internal network could not be inspected"
  [ "$contract" = 'cf-internal|bridge|local' ] ||
    die "cf-internal must be a local bridge network"
  pass "cf-internal network is ready"
}

prepare_auth_token() {
  local action status grep_status
  local fsync_code='import os, sys; fd = os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)'

  if action="$(privileged /bin/sh -u -c '
set +x
token_file=$1
secrets_dir=$2
openssl_bin=$3
python_bin=$4
fsync_code=$5

is_current() {
  [ ! -L "$token_file" ] &&
    [ -f "$token_file" ] &&
    [ "$(stat -c "%u:%g:%a:%h" -- "$token_file" 2>/dev/null)" = "10001:10001:600:1" ] &&
    [ "$(wc -c < "$token_file")" -eq 64 ] &&
    LC_ALL=C grep -Eq "^[0-9a-f]{64}$" "$token_file"
}

is_legacy() {
  [ ! -L "$token_file" ] &&
    [ -f "$token_file" ] &&
    [ "$(stat -c "%u:%g:%a:%h" -- "$token_file" 2>/dev/null)" = "0:0:600:1" ] &&
    [ "$(wc -c < "$token_file")" -eq 65 ] &&
    LC_ALL=C grep -Eq "^[0-9a-f]{64}$" "$token_file"
}

if is_current; then
  action=unchanged
elif [ ! -e "$token_file" ] && [ ! -L "$token_file" ]; then
  action=generated
elif is_legacy; then
  action=migrated
else
  exit 62
fi

if [ "$action" = unchanged ]; then
  printf "%s\n" "$action"
  exit 0
fi

temp_file="$(mktemp "$secrets_dir/.auth-token.XXXXXX")" || exit 63
trap "rm -f -- \"$temp_file\"" EXIT HUP INT TERM
umask 077
if [ "$action" = generated ]; then
  token_value="$("$openssl_bin" rand -hex 32)" || exit 63
else
  token_value="$(cat -- "$token_file")" || exit 63
fi
[ "${#token_value}" -eq 64 ] &&
  printf "%s" "$token_value" | LC_ALL=C grep -Eq "^[0-9a-f]{64}$" ||
  exit 63
printf "%s" "$token_value" > "$temp_file" || exit 63
unset token_value
chown 10001:10001 "$temp_file" || exit 63
chmod 600 "$temp_file" || exit 63
"$python_bin" -c "$fsync_code" "$temp_file" || exit 63
mv -fT -- "$temp_file" "$token_file" || exit 63
trap - EXIT HUP INT TERM
is_current || exit 64
printf "%s\n" "$action"
' bootstrap-token "$TOKEN_FILE" "$SECRETS_ROOT" "$OPENSSL_BIN" \
    python3 "$fsync_code")"; then
    :
  else
    status=$?
    case "$status" in
      62)
        die "auth Token has an unknown format; preserve it and repair owner/mode/content offline"
        ;;
      *) die "auth Token could not be prepared without exposing its contents" ;;
    esac
  fi

  if privileged grep -Fq -f "$TOKEN_FILE" -- "$AGENT_ENV_FILE"; then
    die "auth Token content must not appear in docker/.env"
  else
    grep_status=$?
  fi
  [ "$grep_status" -eq 1 ] ||
    die "docker/.env could not be checked for auth Token content"
  case "$action" in
    generated) log "generated Contract v1 API auth Token (content not displayed)" ;;
    migrated) log "migrated the sole supported legacy API auth Token format" ;;
  esac
}

prepare_management_state() {
  local runtime_present=0 legacy_present=0 storage_device archive_device

  ensure_root_directory "storage root" "$STORAGE_ROOT" 755
  ensure_root_directory "archive root" "$ARCHIVE_ROOT" 700
  ensure_root_directory "secrets directory" "$SECRETS_ROOT" 700
  prepare_auth_token

  validate_runtime_directory "runtime root" "$RUNTIME_ROOT"
  validate_runtime_directory "runtime data" "${RUNTIME_ROOT}/data"
  validate_runtime_directory "runtime WeChat HOME" "${RUNTIME_ROOT}/wechat-home"
  validate_runtime_directory "legacy data" "$LEGACY_DATA_ROOT"
  validate_runtime_directory "legacy WeChat HOME" "$LEGACY_HOME_ROOT"
  validate_empty_token_mountpoint "runtime auth-token mountpoint" "${RUNTIME_ROOT}/data/auth-token"
  validate_empty_token_mountpoint "legacy auth-token mountpoint" "${LEGACY_DATA_ROOT}/auth-token"

  privileged test -d "$RUNTIME_ROOT" && runtime_present=1
  if privileged test -d "$LEGACY_DATA_ROOT" || privileged test -d "$LEGACY_HOME_ROOT"; then
    legacy_present=1
  fi
  if [ "$runtime_present" -eq 1 ] && [ "$legacy_present" -eq 1 ]; then
    die "runtime and legacy data layouts both exist; Bootstrap will not merge them"
  fi

  storage_device="$(privileged stat -c '%d' -- "$STORAGE_ROOT")" ||
    die "storage filesystem could not be inspected"
  archive_device="$(privileged stat -c '%d' -- "$ARCHIVE_ROOT")" ||
    die "archive filesystem could not be inspected"
  [ "$storage_device" = "$archive_device" ] ||
    die "runtime and archive management roots must use one filesystem"
  pass "management directories and Contract v1 Token file are ready"
}

attest_agent_compose() {
  agent_compose config --quiet >/dev/null 2>&1 ||
    die "production Compose validation failed or exceeded its hard timeout"
  ATTESTATION_FILE="$(mktemp "${TMPDIR:-/tmp}/cf-agent-wechat-compose.XXXXXX")" ||
    die "temporary Compose attestation file could not be created"
  chmod 600 "$ATTESTATION_FILE"
  agent_compose config --format json >"$ATTESTATION_FILE" 2>/dev/null ||
    die "production Compose JSON render failed or exceeded its hard timeout"

  python3 - "$ATTESTATION_FILE" "$ENV_IMAGE" "$ENV_PORT" \
    "$RUNTIME_ROOT" "$TOKEN_FILE" "$NETWORK_NAME" "$NETWORK_ALIAS" \
    "$ENV_CONTAINER" "$AGENT_PROJECT" <<'PY'
import json
import sys

(
    config_path,
    expected_image,
    expected_port,
    runtime_root,
    token_file,
    network_name,
    network_alias,
    expected_container,
    expected_project,
) = sys.argv[1:]

def fail(message: str) -> None:
    print(f"Compose attestation failed: {message}", file=sys.stderr)
    raise SystemExit(1)

try:
    with open(config_path, encoding="utf-8") as stream:
        config = json.load(stream)
    service = config["services"]["agent-wechat"]
except (OSError, json.JSONDecodeError, KeyError, TypeError):
    fail("invalid service JSON")

if config.get("name") != expected_project:
    fail("Compose project name is not cf-agent-wechat")
if service.get("container_name") != expected_container:
    fail("container name differs from the approved value")
if service.get("image") != expected_image:
    fail("image is not the approved digest-pinned reference")
if service.get("restart") != "no":
    fail("restart policy must be no")
if "seccomp=unconfined" not in service.get("security_opt", []):
    fail("required seccomp contract is missing")
if "SYS_PTRACE" not in service.get("cap_add", []):
    fail("required SYS_PTRACE capability is missing")
if str(service.get("environment", {}).get("ENABLE_VNC")) != "0":
    fail("production VNC must remain disabled")

ports = service.get("ports", [])
if len(ports) != 1 or not isinstance(ports[0], dict):
    fail("exactly one port mapping is required")
port = ports[0]
if (
    port.get("host_ip") != "127.0.0.1"
    or str(port.get("published")) != expected_port
    or port.get("target") != 6174
    or port.get("protocol") != "tcp"
):
    fail("port must be the configured loopback mapping to 6174/tcp")

volumes = service.get("volumes", [])
if not isinstance(volumes, list) or len(volumes) != 3:
    fail("exactly three production bind mounts are required")
by_target = {
    item.get("target"): item
    for item in volumes
    if isinstance(item, dict) and isinstance(item.get("target"), str)
}
expected_mounts = {
    "/data": (f"{runtime_root}/data", False),
    "/home/wechat": (f"{runtime_root}/wechat-home", False),
    "/data/auth-token": (token_file, True),
}
if set(by_target) != set(expected_mounts):
    fail("production mount targets differ from the approved set")
for target, (source, readonly) in expected_mounts.items():
    mount = by_target[target]
    if mount.get("type") != "bind" or mount.get("source") != source:
        fail(f"{target} source is not the approved bind path")
    if bool(mount.get("read_only", False)) != readonly:
        fail(f"{target} read-only contract is invalid")
    if mount.get("bind", {}).get("create_host_path") not in (None, False):
        fail(f"{target} must not auto-create its source")

service_networks = service.get("networks", {})
if set(service_networks) != {network_name}:
    fail("service must attach only to cf-internal")
aliases = service_networks[network_name].get("aliases", [])
if network_alias not in aliases:
    fail("fixed cf-agent-wechat alias is missing")
network = config.get("networks", {}).get(network_name, {})
if network.get("external") is not True or network.get("name") != network_name:
    fail("cf-internal must be the fixed external network")

health = service.get("healthcheck", {})
if health.get("test") != [
    "CMD", "curl", "--fail", "--silent", "--show-error",
    "http://127.0.0.1:6174/health",
]:
    fail("healthcheck command is invalid")
if health.get("timeout") != "5s" or health.get("retries") != 5:
    fail("healthcheck timeout/retry contract is invalid")

logging = service.get("logging", {})
options = logging.get("options", {})
if (
    logging.get("driver") != "json-file"
    or str(options.get("max-size")) != "20m"
    or str(options.get("max-file")) != "3"
):
    fail("json-file log rotation contract is invalid")
PY
  pass "production Compose is digest-pinned, restart=no, loopback-only, and correctly isolated"
}

confirm_agent_stopped() {
  local running_ids all_ids restart_policy container_id
  running_ids="$(agent_compose ps --status running --quiet "$AGENT_SERVICE" 2>/dev/null)" ||
    die "agent-wechat running state could not be queried"
  [ -z "$running_ids" ] ||
    die "agent-wechat is running; Bootstrap refuses to treat it as a long-lived service"

  all_ids="$(agent_compose ps --all --quiet "$AGENT_SERVICE" 2>/dev/null)" ||
    die "agent-wechat container inventory could not be queried"
  while IFS= read -r container_id; do
    [ -n "$container_id" ] || continue
    restart_policy="$(docker_raw inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_id" 2>/dev/null)" ||
      die "existing agent-wechat restart policy could not be inspected"
    [ "$restart_policy" = no ] ||
      die "existing agent-wechat container must use restart policy no"
  done <<< "$all_ids"

  pass "agent-wechat is stopped with restart=no"
}

main() {
  validate_platform_and_tools
  configure_external_tools
  reject_environment_overrides
  validate_and_normalize_paths
  authorize_privilege
  validate_gateway_runtime_contract
  validate_external_tool_integrity
  validate_docker_socket
  validate_input_path_chains
  validate_repository_inputs
  parse_agent_environment
  validate_systemd
  select_local_rootful_docker
  select_compose_configuration_access

  # State created below is management-only and retryable. Runtime data and
  # WeChat HOME are intentionally created only by start-qr-login.sh.
  prepare_management_state
  ensure_network
  attest_agent_compose
  confirm_agent_stopped

  pass "CF_agent-wechat base deployment preparation is complete"
  printf '%s\n' 'Next step (controlled SSH TTY):'
  printf '%s\n' '  ./scripts/start-qr-login.sh'
}

main "$@"
