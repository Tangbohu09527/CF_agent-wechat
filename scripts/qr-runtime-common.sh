#!/usr/bin/env bash

set +x

RUNTIME_SCRIPTS_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNTIME_REPO_ROOT="$(CDPATH='' cd -- "${RUNTIME_SCRIPTS_DIR}/.." && pwd -P)"

AGENT_COMPOSE_FILE="${CF_AGENT_WECHAT_COMPOSE_FILE:-${RUNTIME_REPO_ROOT}/docker/compose.cfserver.yaml}"
AGENT_ENV_FILE="${CF_AGENT_WECHAT_ENV_FILE:-${RUNTIME_REPO_ROOT}/docker/.env}"
STORAGE_ROOT="${CF_AGENT_WECHAT_STORAGE_ROOT:-/srv/storage/cf-agent-wechat}"
RUNTIME_ROOT="${CF_AGENT_WECHAT_RUNTIME_ROOT:-${STORAGE_ROOT}/runtime}"
ARCHIVE_ROOT="${CF_AGENT_WECHAT_ARCHIVE_ROOT:-${STORAGE_ROOT}/session-archive}"
LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"
LEGACY_WECHAT_HOME_ROOT="${STORAGE_ROOT}/wechat-home"
RUNTIME_LOCK_FILE="${CF_AGENT_WECHAT_LOCK_FILE:-/run/lock/cf-agent-wechat-qr-runtime.lock}"
GATEWAY_COMPOSE_FILE="${CF_AGENT_GATEWAY_COMPOSE_FILE:-/opt/cf-agent-gateway/deploy/compose.yaml}"
GATEWAY_PROJECT_DIR="${CF_AGENT_GATEWAY_PROJECT_DIR:-/opt/cf-agent-gateway/deploy}"
GATEWAY_ENV_FILE="${CF_AGENT_GATEWAY_ENV_FILE:-/opt/cf-agent-gateway/deploy/.env}"
GATEWAY_HEARTBEAT_COMMAND="${GATEWAY_PROJECT_DIR}/check-wechat-worker-heartbeat"

# These globals are validated indirectly and consumed by start-qr-login.sh.
# shellcheck disable=SC2034
RUNTIME_DEFAULT_UID="${CF_AGENT_WECHAT_RUNTIME_UID:-1000}"
# shellcheck disable=SC2034
RUNTIME_DEFAULT_GID="${CF_AGENT_WECHAT_RUNTIME_GID:-1000}"
RUNTIME_DEFAULT_MODE="${CF_AGENT_WECHAT_RUNTIME_MODE:-700}"
SERVER_READY_TIMEOUT="${SERVER_READY_TIMEOUT:-120}"
WECHAT_READY_TIMEOUT="${WECHAT_READY_TIMEOUT:-120}"
WECHAT_STABLE_SECONDS="${WECHAT_STABLE_SECONDS:-10}"
POST_LOGIN_READY_TIMEOUT="${POST_LOGIN_READY_TIMEOUT:-120}"
RUNTIME_POLL_INTERVAL="${RUNTIME_POLL_INTERVAL:-2}"
DOCKER_COMMAND_TIMEOUT="${DOCKER_COMMAND_TIMEOUT:-20}"
COMPOSE_COMMAND_TIMEOUT="${COMPOSE_COMMAND_TIMEOUT:-60}"
WORKER_READY_TIMEOUT="${WORKER_READY_TIMEOUT:-60}"
WORKER_STABLE_SECONDS="${WORKER_STABLE_SECONDS:-5}"
WORKER_HEARTBEAT_TIMEOUT="${WORKER_HEARTBEAT_TIMEOUT:-10}"
TOKEN_SCAN_TIMEOUT="${TOKEN_SCAN_TIMEOUT:-120}"
TIMEOUT_BIN="/usr/bin/timeout"

GATEWAY_SERVICE="wechat-worker"
RUNTIME_LOCK_FD=""
RUNTIME_DOCKER_USES_SUDO=0
RUNTIME_COMPOSE_USES_SUDO=0
RUNTIME_SUDO_AUTHORIZED=0
STABLE_WECHAT_IDENTITY=""
AGENT_IMAGE_DIGEST=""
AGENT_WECHAT_PUBLISHED_PORT="6174"
RUNTIME_MANAGEMENT_ENV_ERROR=""
LAST_ERROR="${LAST_ERROR:-}"

runtime_load_management_environment() {
  local line key value env_contents
  declare -A seen=()

  RUNTIME_MANAGEMENT_ENV_ERROR=""
  if [ -r "$AGENT_ENV_FILE" ]; then
    if ! env_contents="$(/bin/cat -- "$AGENT_ENV_FILE")"; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env could not be read."
      return 1
    fi
  elif [ "$(id -u)" -eq 0 ]; then
    if ! env_contents="$(/bin/cat -- "$AGENT_ENV_FILE")"; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env could not be read."
      return 1
    fi
  elif [ "$RUNTIME_SUDO_AUTHORIZED" -eq 1 ]; then
    if ! env_contents="$(sudo -n -- /bin/cat -- "$AGENT_ENV_FILE")"; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env could not be read through the authorized sudo path."
      return 1
    fi
  else
    return 2
  fi
  if [ "${#env_contents}" -gt 65536 ]; then
    RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env exceeds the 65536-character safety limit."
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if ! [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env contains unsupported syntax."
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ -v seen[$key] ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env contains a duplicate ${key} assignment."
      return 1
    fi
    seen[$key]=1
    if { [ -z "$value" ] && [ "$key" != "PROXY" ]; } ||
      [[ "$value" =~ [[:cntrl:]] ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} is empty or contains control characters."
      return 1
    fi
    case "$value" in
      *'$'*|*'"'*|*"'"*|*\\*|*[[:space:]]*)
        RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} must be an unquoted literal without whitespace."
        return 1
        ;;
    esac
    if [[ "$value" == *$'\x60'* ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} must be an unquoted literal without whitespace."
      return 1
    fi
    case "$key" in
      COMPOSE_PROJECT_NAME|CF_AGENT_WECHAT_STORAGE_ROOT|CF_AGENT_WECHAT_RUNTIME_ROOT|CF_AGENT_WECHAT_ARCHIVE_ROOT|AGENT_WECHAT_BIND_IP|AGENT_WECHAT_PORT|AGENT_WECHAT_CONTAINER_NAME|AGENT_WECHAT_IMAGE|PROXY|RUST_LOG) ;;
      *)
        RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env contains unsupported key: ${key}."
        return 1
        ;;
    esac
    case "$key" in
      CF_AGENT_WECHAT_STORAGE_ROOT|CF_AGENT_WECHAT_RUNTIME_ROOT|CF_AGENT_WECHAT_ARCHIVE_ROOT)
        if ! [[ "$value" =~ ^/[-A-Za-z0-9._/@%+,=:~]+$ ]] ||
          [[ "$value" == *'/../'* ]] || [[ "$value" == */.. ]]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} is not a safe absolute path."
          return 1
        fi
        ;;
      AGENT_WECHAT_BIND_IP)
        if [ "$value" != "127.0.0.1" ]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env AGENT_WECHAT_BIND_IP must be 127.0.0.1."
          return 1
        fi
        ;;
      AGENT_WECHAT_PORT)
        if ! [[ "$value" =~ ^[1-9][0-9]*$ ]] || [ "$value" -gt 65535 ]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env AGENT_WECHAT_PORT is invalid."
          return 1
        fi
        ;;
      AGENT_WECHAT_CONTAINER_NAME)
        if ! [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env container name is invalid."
          return 1
        fi
        ;;
      AGENT_WECHAT_IMAGE)
        if ! [[ "$value" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env AGENT_WECHAT_IMAGE must be digest pinned."
          return 1
        fi
        ;;
      COMPOSE_PROJECT_NAME)
        if [ "$value" != "cf-agent-wechat" ]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env COMPOSE_PROJECT_NAME must be cf-agent-wechat."
          return 1
        fi
        ;;
      PROXY)
        case "$value" in
          ""|http://*|https://*|socks5://*|socks5h://*) ;;
          *)
            RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env PROXY uses an unsupported scheme."
            return 1
            ;;
        esac
        ;;
      RUST_LOG)
        case "$value" in
          error|warn|info) ;;
          *)
            RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env RUST_LOG must be error, warn, or info."
            return 1
            ;;
        esac
        ;;
    esac
    case "$key" in
      CF_AGENT_WECHAT_STORAGE_ROOT) STORAGE_ROOT="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_ROOT) RUNTIME_ROOT="$value" ;;
      CF_AGENT_WECHAT_ARCHIVE_ROOT) ARCHIVE_ROOT="$value" ;;
      AGENT_WECHAT_CONTAINER_NAME) CONTAINER_NAME="$value" ;;
      AGENT_WECHAT_PORT) AGENT_WECHAT_PUBLISHED_PORT="$value" ;;
    esac
  done <<< "$env_contents"

  LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"
  LEGACY_WECHAT_HOME_ROOT="${STORAGE_ROOT}/wechat-home"
  if [ "$API_URL" = "http://127.0.0.1:6174" ]; then
    API_URL="http://127.0.0.1:${AGENT_WECHAT_PUBLISHED_PORT}"
    if [ "$WS_URL" = "ws://127.0.0.1:6174/api/ws/login" ]; then
      WS_URL="ws://127.0.0.1:${AGENT_WECHAT_PUBLISHED_PORT}/api/ws/login"
    fi
  fi
}

runtime_require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    LAST_ERROR="Required command is missing: $1"
    return 1
  fi
}

runtime_validate_uint() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    LAST_ERROR="${name} must be a non-negative integer."
    return 1
  fi
}

runtime_validate_mode() {
  [[ "$1" =~ ^[0-7]{3,4}$ ]]
}

runtime_authorize_sudo() {
  if [ "$(id -u)" -eq 0 ] || [ "$RUNTIME_SUDO_AUTHORIZED" -eq 1 ]; then
    return 0
  fi
  if ! authorize_management_sudo "执行 forced-QR 生产管理操作"; then
    return 1
  fi
  RUNTIME_SUDO_AUTHORIZED=1
}

runtime_with_timeout() {
  local duration="$1"
  shift

  "$TIMEOUT_BIN" --signal=TERM --kill-after=2s "${duration}s" "$@"
}

runtime_canonical_path() {
  readlink -m -- "$1"
}

runtime_path_is_within() {
  local candidate="$1"
  local parent="$2"

  case "${candidate}/" in
    "${parent}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_path_exists() {
  runtime_privileged test -e "$1" || runtime_privileged test -L "$1"
}

runtime_validate_directory_or_missing() {
  local path="$1"
  local label="$2"

  if runtime_privileged test -L "$path"; then
    LAST_ERROR="${label} must not be a symlink."
    return 1
  fi
  if runtime_privileged test -e "$path" &&
    ! runtime_privileged test -d "$path"; then
    LAST_ERROR="${label} must be a directory when it exists."
    return 1
  fi
}

runtime_validate_empty_token_mountpoint() {
  local path="$1"
  local label="$2"
  local size

  if runtime_privileged test -L "$path"; then
    LAST_ERROR="${label} contains an unsafe auth-token symlink."
    return 1
  fi
  if ! runtime_privileged test -e "$path"; then
    return 0
  fi
  if ! runtime_privileged test -f "$path"; then
    LAST_ERROR="${label} contains a non-file auth-token mountpoint."
    return 1
  fi
  if ! size="$(runtime_privileged stat -c '%s' -- "$path")"; then
    LAST_ERROR="${label} auth-token mountpoint could not be inspected."
    return 1
  fi
  if [ "$size" != "0" ]; then
    LAST_ERROR="${label} contains auth-token data; refusing to archive it."
    return 1
  fi
}

runtime_assert_tree_has_no_auth_token() {
  local root="$1"
  local label="$2"
  local scan_status

  if ! runtime_privileged test -d "$root"; then
    return 0
  fi
  if runtime_privileged "$TIMEOUT_BIN" --signal=TERM --kill-after=2s \
    "${TOKEN_SCAN_TIMEOUT}s" /usr/bin/env LC_ALL=C /usr/bin/grep \
    -R -F -q -f "$TOKEN_FILE" -- "$root" >/dev/null 2>&1; then
    LAST_ERROR="${label} contains auth-token bytes and cannot be archived."
    return 1
  else
    scan_status=$?
  fi
  if [ "$scan_status" -eq 1 ]; then
    return 0
  fi
  LAST_ERROR="${label} could not be scanned for protected auth-token bytes."
  return 1
}

runtime_validate_management_file() {
  local path="$1"
  local label="$2"
  local allowed_modes="${3:-}"
  local metadata owner mode links current_uid

  if runtime_privileged test -L "$path" ||
    ! runtime_privileged test -f "$path"; then
    LAST_ERROR="${label} must be a non-symlink regular file."
    return 1
  fi
  if ! metadata="$(runtime_privileged stat -Lc '%u:%a:%h' -- "$path")"; then
    LAST_ERROR="${label} metadata could not be read."
    return 1
  fi
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  mode="${mode%%:*}"
  links="${metadata##*:}"
  current_uid="$(id -u)"
  if [ "$owner" != "0" ] && [ "$owner" != "$current_uid" ]; then
    LAST_ERROR="${label} must be owned by root or the current management user."
    return 1
  fi
  if [ "$links" != "1" ]; then
    LAST_ERROR="${label} must not have additional hard links."
    return 1
  fi
  if [ -n "$allowed_modes" ]; then
    case " ${allowed_modes} " in
      *" ${mode} "*) ;;
      *)
        LAST_ERROR="${label} has an unsafe mode."
        return 1
        ;;
    esac
  elif (( (8#$mode & 8#022) != 0 )); then
    LAST_ERROR="${label} must not be writable by group or other."
    return 1
  fi
}

runtime_validate_management_directory() {
  local path="$1"
  local label="$2"
  local privileged="${3:-0}"
  local metadata owner mode current_uid
  local -a command=(stat -Lc '%u:%a' -- "$path")

  if [ "$privileged" -eq 1 ]; then
    if runtime_privileged test -L "$path" ||
      ! runtime_privileged test -d "$path" ||
      ! metadata="$(runtime_privileged "${command[@]}")"; then
      LAST_ERROR="${label} must be an existing non-symlink directory."
      return 1
    fi
  elif [ -L "$path" ] || [ ! -d "$path" ] ||
    ! metadata="$("${command[@]}")"; then
    LAST_ERROR="${label} must be an existing non-symlink directory."
    return 1
  fi
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  current_uid="$(id -u)"
  if [ "$owner" != "0" ] && [ "$owner" != "$current_uid" ]; then
    LAST_ERROR="${label} must be owned by root or the current management user."
    return 1
  fi
  if (( (8#$mode & 8#022) != 0 )); then
    LAST_ERROR="${label} must not be writable by group or other."
    return 1
  fi
}

runtime_select_docker() {
  local override context endpoint security_options live_restore

  for override in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
    if [[ -v $override ]]; then
      LAST_ERROR="${override} must be unset for production local Docker."
      return 1
    fi
  done

  if runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" \
    docker info >/dev/null 2>&1; then
    RUNTIME_DOCKER_USES_SUDO=0
  elif [ "$(id -u)" -ne 0 ] && runtime_authorize_sudo &&
    runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" \
      sudo -n -- docker info >/dev/null 2>&1; then
    RUNTIME_DOCKER_USES_SUDO=1
  else
    LAST_ERROR="Docker daemon is unavailable, timed out, or permission was denied."
    return 1
  fi

  if ! context="$(runtime_docker context show 2>/dev/null)" ||
    [ "$context" != "default" ]; then
    LAST_ERROR="Production Docker context must be default."
    return 1
  fi
  if ! endpoint="$(runtime_docker context inspect default \
    --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" ||
    [ "$endpoint" != "unix:///var/run/docker.sock" ]; then
    LAST_ERROR="Production Docker endpoint must be unix:///var/run/docker.sock."
    return 1
  fi
  if ! security_options="$(runtime_docker info \
    --format '{{json .SecurityOptions}}' 2>/dev/null)"; then
    LAST_ERROR="Docker security options could not be inspected."
    return 1
  fi
  case "${security_options,,}" in
    *rootless*)
      LAST_ERROR="Rootless Docker is not supported for this production deployment."
      return 1
      ;;
  esac
  if ! live_restore="$(runtime_docker info \
    --format '{{json .LiveRestoreEnabled}}' 2>/dev/null)"; then
    LAST_ERROR="Docker live-restore state could not be inspected."
    return 1
  fi
  if [ "$live_restore" != "false" ]; then
    LAST_ERROR="Docker live-restore must be disabled for the forced fresh QR lifecycle."
    return 1
  fi
}

runtime_docker() {
  if [ "$RUNTIME_DOCKER_USES_SUDO" -eq 1 ]; then
    runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" \
      sudo -n -- docker "$@"
  else
    runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" docker "$@"
  fi
}

runtime_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n -- "$@"
  fi
}
runtime_select_compose_access() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if [ -r "$AGENT_COMPOSE_FILE" ] && [ -r "$AGENT_ENV_FILE" ] &&
    [ -r "$GATEWAY_COMPOSE_FILE" ] && [ -r "$GATEWAY_ENV_FILE" ]; then
    return 0
  fi
  runtime_authorize_sudo || return 1
  RUNTIME_COMPOSE_USES_SUDO=1
}



agent_compose() {
  if [ "$RUNTIME_DOCKER_USES_SUDO" -eq 1 ] ||
    [ "$RUNTIME_COMPOSE_USES_SUDO" -eq 1 ]; then
    runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" \
      sudo -n -- env "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" docker compose \
      --env-file "$AGENT_ENV_FILE" \
      --project-directory "$RUNTIME_REPO_ROOT" \
      -f "$AGENT_COMPOSE_FILE" "$@"
  else
    runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" \
      env "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" docker compose \
      --env-file "$AGENT_ENV_FILE" \
      --project-directory "$RUNTIME_REPO_ROOT" \
      -f "$AGENT_COMPOSE_FILE" "$@"
  fi
}

gateway_compose() {
  if [ "$RUNTIME_DOCKER_USES_SUDO" -eq 1 ] ||
    [ "$RUNTIME_COMPOSE_USES_SUDO" -eq 1 ]; then
    runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" \
      sudo -n -- docker compose \
      --env-file "$GATEWAY_ENV_FILE" \
      --project-directory "$GATEWAY_PROJECT_DIR" \
      -f "$GATEWAY_COMPOSE_FILE" "$@"
  else
    runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" docker compose \
      --env-file "$GATEWAY_ENV_FILE" \
      --project-directory "$GATEWAY_PROJECT_DIR" \
      -f "$GATEWAY_COMPOSE_FILE" "$@"
  fi
}

runtime_attest_agent_compose() {
  local config_json attested_image runtime_canonical token_canonical

  if ! config_json="$(agent_compose config --format json 2>/dev/null)"; then
    LAST_ERROR="agent-wechat Compose JSON configuration could not be inspected."
    return 1
  fi
  if ! runtime_canonical="$(runtime_canonical_path "$RUNTIME_ROOT")" ||
    ! token_canonical="$(runtime_canonical_path "$TOKEN_FILE")"; then
    LAST_ERROR="Runtime or Token paths could not be canonicalized."
    return 1
  fi
  if ! attested_image="$(printf '%s' "$config_json" | "$PYTHON_BIN" -c '
import json
import os
import re
import sys

try:
    payload = json.load(sys.stdin)
    service = payload["services"]["agent-wechat"]
except (json.JSONDecodeError, KeyError, TypeError):
    raise SystemExit(2)

expected_runtime = os.path.normpath(sys.argv[1])
expected_token = os.path.normpath(sys.argv[2])
expected_port = sys.argv[3]
image = service.get("image")
if not isinstance(image, str) or not re.fullmatch(
    r"[^\s]+@sha256:[0-9a-fA-F]{64}", image
):
    raise SystemExit(2)
if service.get("restart") != "no":
    raise SystemExit(2)

volumes = service.get("volumes")
if not isinstance(volumes, list):
    raise SystemExit(2)
by_target = {
    volume.get("target"): volume
    for volume in volumes
    if isinstance(volume, dict) and isinstance(volume.get("target"), str)
}
if set(by_target) != {"/data", "/home/wechat", "/data/auth-token"}:
    raise SystemExit(2)
for target, source, read_only in (
    ("/data", os.path.join(expected_runtime, "data"), False),
    ("/home/wechat", os.path.join(expected_runtime, "wechat-home"), False),
    ("/data/auth-token", expected_token, True),
):
    mount = by_target[target]
    if (
        mount.get("type") != "bind"
        or os.path.normpath(str(mount.get("source", ""))) != source
        or bool(mount.get("read_only", False)) is not read_only
        or mount.get("bind", {}).get("create_host_path") not in (None, False)
    ):
        raise SystemExit(2)

ports = service.get("ports")
if not isinstance(ports, list) or len(ports) != 1:
    raise SystemExit(2)
port = ports[0]
if not isinstance(port, dict) or (
    str(port.get("target")) != "6174"
    or str(port.get("published")) != expected_port
    or port.get("host_ip") != "127.0.0.1"
    or port.get("protocol") != "tcp"
):
    raise SystemExit(2)

environment = service.get("environment")
if not isinstance(environment, dict) or str(environment.get("ENABLE_VNC")) != "0":
    raise SystemExit(2)

networks = service.get("networks")
network = networks.get("cf-internal") if isinstance(networks, dict) else None
if not isinstance(networks, dict) or set(networks) != {"cf-internal"}:
    raise SystemExit(2)
if not isinstance(network, dict) or "cf-agent-wechat" not in network.get("aliases", []):
    raise SystemExit(2)
top_networks = payload.get("networks")
top_network = top_networks.get("cf-internal") if isinstance(top_networks, dict) else None
if not isinstance(top_networks, dict) or set(top_networks) != {"cf-internal"}:
    raise SystemExit(2)
if not isinstance(top_network, dict) or top_network.get("external") is not True or top_network.get("name") != "cf-internal":
    raise SystemExit(2)

health = service.get("healthcheck")
if not isinstance(health, dict):
    raise SystemExit(2)
if health.get("test") != ["CMD", "curl", "--fail", "--silent", "--show-error", "http://127.0.0.1:6174/health"]:
    raise SystemExit(2)
if health.get("interval") != "30s" or health.get("timeout") != "5s" or health.get("retries") != 5 or health.get("start_period") != "1m30s":
    raise SystemExit(2)
if "seccomp=unconfined" not in service.get("security_opt", []):
    raise SystemExit(2)
if "SYS_PTRACE" not in service.get("cap_add", []):
    raise SystemExit(2)
logging = service.get("logging")
if not isinstance(logging, dict) or logging.get("driver") != "json-file":
    raise SystemExit(2)
options = logging.get("options")
if not isinstance(options, dict) or (
    str(options.get("max-size")) != "20m"
    or str(options.get("max-file")) != "3"
):
    raise SystemExit(2)
sys.stdout.write(image)
' "$runtime_canonical" "$token_canonical" "$AGENT_WECHAT_PUBLISHED_PORT")"; then
    LAST_ERROR="Rendered agent-wechat Compose violates the production attestation contract."
    return 1
  fi
  # Consumed by start-qr-login.sh after this helper is sourced.
  # shellcheck disable=SC2034
  AGENT_IMAGE_DIGEST="$attested_image"
}

runtime_validate_configuration() {
  local command_name services
  local storage_canonical runtime_canonical archive_canonical token_canonical
  local lock_canonical
  local archive_parent runtime_parent lock_parent
  local archive_parent_device runtime_parent_device
  local required_file required_path value_name
  local runtime_present=0 legacy_present=0

  if [ -n "$RUNTIME_MANAGEMENT_ENV_ERROR" ]; then
    LAST_ERROR="$RUNTIME_MANAGEMENT_ENV_ERROR"
    return 1
  fi

  for command_name in \
    docker flock stat date mv install readlink awk curl mktemp mkdir chmod \
    chown rm sleep cksum sh dirname env id grep /bin/cat "$TIMEOUT_BIN"; do
    runtime_require_command "$command_name" || return 1
  done
  runtime_authorize_sudo || return 1

  for value_name in \
    RUNTIME_DEFAULT_UID RUNTIME_DEFAULT_GID SERVER_READY_TIMEOUT \
    WECHAT_READY_TIMEOUT WECHAT_STABLE_SECONDS POST_LOGIN_READY_TIMEOUT \
    RUNTIME_POLL_INTERVAL DOCKER_COMMAND_TIMEOUT COMPOSE_COMMAND_TIMEOUT \
    WORKER_READY_TIMEOUT WORKER_STABLE_SECONDS WORKER_HEARTBEAT_TIMEOUT TOKEN_SCAN_TIMEOUT; do
    runtime_validate_uint "$value_name" "${!value_name}" || return 1
  done
  if ! runtime_validate_mode "$RUNTIME_DEFAULT_MODE"; then
    LAST_ERROR="CF_AGENT_WECHAT_RUNTIME_MODE must be an octal mode."
    return 1
  fi
  if [ "$RUNTIME_POLL_INTERVAL" -eq 0 ]; then
    LAST_ERROR="RUNTIME_POLL_INTERVAL must be greater than zero."
    return 1
  fi
  if [ "$SERVER_READY_TIMEOUT" -eq 0 ] || [ "$WECHAT_READY_TIMEOUT" -eq 0 ] ||
    [ "$WECHAT_STABLE_SECONDS" -eq 0 ] ||
    [ "$POST_LOGIN_READY_TIMEOUT" -eq 0 ] ||
    [ "$DOCKER_COMMAND_TIMEOUT" -eq 0 ] ||
    [ "$COMPOSE_COMMAND_TIMEOUT" -eq 0 ] ||
    [ "$WORKER_READY_TIMEOUT" -eq 0 ] ||
    [ "$TOKEN_SCAN_TIMEOUT" -eq 0 ] ||
    [ "$WORKER_HEARTBEAT_TIMEOUT" -eq 0 ]; then
    LAST_ERROR="Runtime readiness timeouts must be greater than zero."
    return 1
  fi

  case "$AGENT_ENV_FILE" in
    /*) ;;
    *)
      LAST_ERROR="agent-wechat environment file path must be absolute: $AGENT_ENV_FILE"
      return 1
      ;;
  esac
  if runtime_privileged test -L "$AGENT_ENV_FILE" ||
    ! runtime_privileged test -f "$AGENT_ENV_FILE"; then
    LAST_ERROR="agent-wechat environment file must be an existing non-symlink regular file: $AGENT_ENV_FILE"
    return 1
  fi
  runtime_validate_management_directory \
    "$RUNTIME_REPO_ROOT" "Repository root" || return 1
  runtime_validate_management_directory \
    "${RUNTIME_REPO_ROOT}/docker" "Production configuration directory" || return 1
  runtime_validate_management_file \
    "$AGENT_COMPOSE_FILE" "agent-wechat Compose" || return 1
  runtime_validate_management_file \
    "$AGENT_ENV_FILE" "agent-wechat environment file" "600 0600 640 0640" || return 1
  if ! runtime_load_management_environment; then
    LAST_ERROR="${RUNTIME_MANAGEMENT_ENV_ERROR:-docker/.env could not be loaded.}"
    return 1
  fi


  for required_path in \
    "$AGENT_COMPOSE_FILE" "$STORAGE_ROOT" "$RUNTIME_ROOT" "$ARCHIVE_ROOT" \
    "$GATEWAY_COMPOSE_FILE" "$GATEWAY_PROJECT_DIR" "$GATEWAY_ENV_FILE" "$GATEWAY_HEARTBEAT_COMMAND" \
    "$TOKEN_FILE" \
    "$RUNTIME_LOCK_FILE"; do
    case "$required_path" in
      /*) ;;
      *)
        LAST_ERROR="Production paths must be absolute."
        return 1
        ;;
    esac
  done

  for required_file in "$AGENT_COMPOSE_FILE" "$GATEWAY_COMPOSE_FILE"; do
    if runtime_privileged test -L "$required_file" ||
      ! runtime_privileged test -f "$required_file"; then
      LAST_ERROR="Required Compose file is missing or is a symlink."
      return 1
    fi
  done
  if runtime_privileged test -L "$GATEWAY_ENV_FILE" ||
    ! runtime_privileged test -f "$GATEWAY_ENV_FILE"; then
    LAST_ERROR="Gateway environment file must be an existing non-symlink regular file: $GATEWAY_ENV_FILE"
    return 1
  fi
  runtime_validate_management_directory \
    "$GATEWAY_PROJECT_DIR" "Gateway project directory" 1 || return 1
  runtime_validate_management_file \
    "$GATEWAY_COMPOSE_FILE" "Gateway Compose" || return 1
  runtime_validate_management_file \
    "$GATEWAY_ENV_FILE" "Gateway environment file" "600 0600 640 0640" || return 1
  runtime_validate_management_file \
    "$GATEWAY_HEARTBEAT_COMMAND" "Gateway heartbeat checker" || return 1
  if [ ! -x "$GATEWAY_HEARTBEAT_COMMAND" ]; then
    LAST_ERROR="Gateway heartbeat checker must be executable by the management user."
    return 1
  fi

  if runtime_privileged test -L "$STORAGE_ROOT" ||
    ! runtime_privileged test -d "$STORAGE_ROOT"; then
    LAST_ERROR="Storage root must be an existing non-symlink directory."
    return 1
  fi
  runtime_validate_management_directory \
    "$STORAGE_ROOT" "Storage root" 1 || return 1
  runtime_validate_directory_or_missing "$RUNTIME_ROOT" "Runtime path" || return 1
  runtime_validate_directory_or_missing "$ARCHIVE_ROOT" "Archive path" || return 1
  runtime_validate_directory_or_missing \
    "${RUNTIME_ROOT}/data" "Runtime data path" || return 1
  runtime_validate_directory_or_missing \
    "${RUNTIME_ROOT}/wechat-home" "Runtime WeChat HOME path" || return 1
  runtime_validate_directory_or_missing "$LEGACY_DATA_ROOT" "Legacy data path" || return 1
  runtime_validate_directory_or_missing \
    "$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME path" || return 1
  for required_path in \
    "$RUNTIME_ROOT" "$ARCHIVE_ROOT" "${RUNTIME_ROOT}/data" \
    "${RUNTIME_ROOT}/wechat-home" "$LEGACY_DATA_ROOT" \
    "$LEGACY_WECHAT_HOME_ROOT"; do
    if runtime_privileged test -d "$required_path"; then
      runtime_validate_management_directory \
        "$required_path" "Runtime management directory" 1 || return 1
    fi
  done

  if ! storage_canonical="$(runtime_canonical_path "$STORAGE_ROOT")" ||
    ! runtime_canonical="$(runtime_canonical_path "$RUNTIME_ROOT")" ||
    ! archive_canonical="$(runtime_canonical_path "$ARCHIVE_ROOT")" ||
    ! token_canonical="$(runtime_canonical_path "$TOKEN_FILE")" ||
    ! lock_canonical="$(runtime_canonical_path "$RUNTIME_LOCK_FILE")"; then
    LAST_ERROR="Production paths could not be canonicalized."
    return 1
  fi
  if [ "$runtime_canonical" = "/" ] || [ "$archive_canonical" = "/" ] ||
    [ "$runtime_canonical" = "$archive_canonical" ] ||
    runtime_path_is_within "$runtime_canonical" "$archive_canonical" ||
    runtime_path_is_within "$archive_canonical" "$runtime_canonical"; then
    LAST_ERROR="Runtime and archive paths must be separate, non-nested directories."
    return 1
  fi
  if ! runtime_path_is_within "$runtime_canonical" "$storage_canonical" ||
    ! runtime_path_is_within "$archive_canonical" "$storage_canonical"; then
    LAST_ERROR="Runtime and archive paths must remain within the storage root."
    return 1
  fi
  if runtime_path_is_within "$lock_canonical" "$runtime_canonical" ||
    runtime_path_is_within "$lock_canonical" "$archive_canonical"; then
    LAST_ERROR="Runtime lock file must remain outside runtime and archive directories."
    return 1
  fi
  if runtime_path_is_within "$token_canonical" "$runtime_canonical" ||
    runtime_path_is_within "$token_canonical" "$archive_canonical"; then
    LAST_ERROR="Token path must remain outside runtime and archive directories."
    return 1
  fi
  if runtime_privileged test -L "$TOKEN_FILE" ||
    ! runtime_privileged test -f "$TOKEN_FILE"; then
    LAST_ERROR="Token source must be an existing non-symlink regular file."
    return 1
  fi
  runtime_validate_empty_token_mountpoint \
    "${RUNTIME_ROOT}/data/auth-token" "Runtime" || return 1
  runtime_validate_empty_token_mountpoint \
    "${LEGACY_DATA_ROOT}/auth-token" "Legacy data" || return 1

  if runtime_privileged test -d "$RUNTIME_ROOT"; then
    runtime_present=1
  fi
  if runtime_privileged test -d "$LEGACY_DATA_ROOT" ||
    runtime_privileged test -d "$LEGACY_WECHAT_HOME_ROOT"; then
    legacy_present=1
  fi
  if [ "$runtime_present" -eq 1 ] && [ "$legacy_present" -eq 1 ]; then
    LAST_ERROR="Both runtime and legacy data/wechat-home layouts exist; refusing to modify either layout."
    return 1
  fi

  if ! runtime_parent="$(dirname -- "$RUNTIME_ROOT")" ||
    ! archive_parent="$(dirname -- "$ARCHIVE_ROOT")" ||
    ! lock_parent="$(dirname -- "$RUNTIME_LOCK_FILE")"; then
    LAST_ERROR="Production path parents could not be resolved."
    return 1
  fi
  if ! runtime_privileged test -d "$runtime_parent" ||
    ! runtime_privileged test -d "$archive_parent"; then
    LAST_ERROR="Runtime and archive parent directories must already exist."
    return 1
  fi
  if runtime_privileged test -L "$lock_parent" ||
    ! runtime_privileged test -d "$lock_parent"; then
    LAST_ERROR="Runtime lock parent must be an existing non-symlink directory."
    return 1
  fi
  if runtime_privileged test -L "$RUNTIME_LOCK_FILE" ||
    { runtime_privileged test -e "$RUNTIME_LOCK_FILE" &&
      ! runtime_privileged test -f "$RUNTIME_LOCK_FILE"; }; then
    LAST_ERROR="Runtime lock path must be a regular non-symlink file."
    return 1
  fi
  if ! runtime_parent_device="$(runtime_privileged stat -c '%d' -- "$runtime_parent")" ||
    ! archive_parent_device="$(runtime_privileged stat -c '%d' -- "$archive_parent")"; then
    LAST_ERROR="Runtime and archive filesystems could not be inspected."
    return 1
  fi
  if [ "$runtime_parent_device" != "$archive_parent_device" ]; then
    LAST_ERROR="Runtime and archive must be on the same filesystem."
    return 1
  fi

  runtime_select_compose_access || return 1
  runtime_select_docker || return 1
  if ! agent_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="agent-wechat Compose configuration is invalid."
    return 1
  fi
  runtime_attest_agent_compose || return 1
  if ! gateway_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="Gateway Compose configuration is invalid."
    return 1
  fi
  if ! services="$(gateway_compose config --services 2>/dev/null)"; then
    LAST_ERROR="Gateway services could not be inspected."
    return 1
  fi
  if ! printf '%s\n' "$services" | awk -v service="$GATEWAY_SERVICE" '
    $0 == service { found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
    LAST_ERROR="Gateway Compose does not define the required wechat-worker service."
    return 1
  fi
}

runtime_validate_stop_configuration() {
  local command_name required_path required_file services lock_parent

  if [ -n "$RUNTIME_MANAGEMENT_ENV_ERROR" ]; then
    LAST_ERROR="$RUNTIME_MANAGEMENT_ENV_ERROR"
    return 1
  fi

  for command_name in \
    docker flock readlink install stat awk chmod sh dirname env id \
    /bin/cat "$TIMEOUT_BIN"; do
    runtime_require_command "$command_name" || return 1
  done
  runtime_authorize_sudo || return 1
  runtime_validate_uint DOCKER_COMMAND_TIMEOUT "$DOCKER_COMMAND_TIMEOUT" || return 1
  runtime_validate_uint COMPOSE_COMMAND_TIMEOUT "$COMPOSE_COMMAND_TIMEOUT" || return 1
  if [ "$DOCKER_COMMAND_TIMEOUT" -eq 0 ] ||
    [ "$COMPOSE_COMMAND_TIMEOUT" -eq 0 ]; then
    LAST_ERROR="Docker and Compose timeouts must be greater than zero."
    return 1
  fi
  case "$AGENT_ENV_FILE" in
    /*) ;;
    *)
      LAST_ERROR="agent-wechat environment file path must be absolute: $AGENT_ENV_FILE"
      return 1
      ;;
  esac
  if runtime_privileged test -L "$AGENT_ENV_FILE" ||
    ! runtime_privileged test -f "$AGENT_ENV_FILE"; then
    LAST_ERROR="agent-wechat environment file must be an existing non-symlink regular file: $AGENT_ENV_FILE"
    return 1
  fi
  runtime_validate_management_directory \
    "$RUNTIME_REPO_ROOT" "Repository root" || return 1
  runtime_validate_management_directory \
    "${RUNTIME_REPO_ROOT}/docker" "Production configuration directory" || return 1
  runtime_validate_management_file \
    "$AGENT_COMPOSE_FILE" "agent-wechat Compose" || return 1
  runtime_validate_management_file \
    "$AGENT_ENV_FILE" "agent-wechat environment file" "600 0600 640 0640" || return 1
  if ! runtime_load_management_environment; then
    LAST_ERROR="${RUNTIME_MANAGEMENT_ENV_ERROR:-docker/.env could not be loaded.}"
    return 1
  fi


  for required_path in \
    "$AGENT_COMPOSE_FILE" "$STORAGE_ROOT" "$GATEWAY_COMPOSE_FILE" \
    "$GATEWAY_PROJECT_DIR" "$GATEWAY_ENV_FILE" "$RUNTIME_LOCK_FILE"; do
    case "$required_path" in
      /*) ;;
      *)
        LAST_ERROR="Production control paths must be absolute."
        return 1
        ;;
    esac
  done
  for required_file in "$AGENT_COMPOSE_FILE" "$GATEWAY_COMPOSE_FILE"; do
    if runtime_privileged test -L "$required_file" ||
      ! runtime_privileged test -f "$required_file"; then
      LAST_ERROR="Required Compose file is missing or is a symlink."
      return 1
    fi
  done
  if runtime_privileged test -L "$GATEWAY_ENV_FILE" ||
    ! runtime_privileged test -f "$GATEWAY_ENV_FILE"; then
    LAST_ERROR="Gateway environment file must be an existing non-symlink regular file: $GATEWAY_ENV_FILE"
    return 1
  fi
  runtime_validate_management_file \
    "$GATEWAY_COMPOSE_FILE" "Gateway Compose" || return 1
  runtime_validate_management_file \
    "$GATEWAY_ENV_FILE" "Gateway environment file" "600 0600 640 0640" || return 1
  if runtime_privileged test -L "$STORAGE_ROOT" ||
    ! runtime_privileged test -d "$STORAGE_ROOT"; then
    LAST_ERROR="Storage root must be an existing non-symlink directory."
    return 1
  fi
  runtime_validate_management_directory \
    "$STORAGE_ROOT" "Storage root" 1 || return 1
  runtime_validate_management_directory \
    "$GATEWAY_PROJECT_DIR" "Gateway project directory" 1 || return 1
  if ! lock_parent="$(dirname -- "$RUNTIME_LOCK_FILE")"; then
    LAST_ERROR="Runtime lock parent could not be resolved."
    return 1
  fi
  if runtime_privileged test -L "$lock_parent" ||
    ! runtime_privileged test -d "$lock_parent"; then
    LAST_ERROR="Runtime lock parent must be an existing non-symlink directory."
    return 1
  fi
  if runtime_privileged test -L "$RUNTIME_LOCK_FILE" ||
    { runtime_privileged test -e "$RUNTIME_LOCK_FILE" &&
      ! runtime_privileged test -f "$RUNTIME_LOCK_FILE"; }; then
    LAST_ERROR="Runtime lock path must be a regular non-symlink file."
    return 1
  fi

  runtime_select_docker || return 1
  runtime_select_compose_access || return 1
  if ! agent_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="agent-wechat Compose configuration is invalid."
    return 1
  fi
  if ! gateway_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="Gateway Compose configuration is invalid."
    return 1
  fi
  if ! services="$(gateway_compose config --services 2>/dev/null)"; then
    LAST_ERROR="Gateway services could not be inspected."
    return 1
  fi
  if ! printf '%s\n' "$services" | awk -v service="$GATEWAY_SERVICE" '
    $0 == service { found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
    LAST_ERROR="Gateway Compose does not define the required wechat-worker service."
    return 1
  fi
}

runtime_acquire_lock() {
  local lock_size

  if ! runtime_path_exists "$RUNTIME_LOCK_FILE"; then
    # Positional parameters are expanded by the privileged child shell.
    # shellcheck disable=SC2016
    if ! runtime_privileged sh -c '
      umask 022
      set -C
      : > "$1"
    ' cf-agent-wechat-lock "$RUNTIME_LOCK_FILE" &&
      ! runtime_path_exists "$RUNTIME_LOCK_FILE"; then
      LAST_ERROR="Runtime lock file could not be created."
      return 1
    fi
  fi
  if [ -L "$RUNTIME_LOCK_FILE" ] || [ ! -f "$RUNTIME_LOCK_FILE" ]; then
    LAST_ERROR="Runtime lock path is not a safe regular file."
    return 1
  fi
  if ! lock_size="$(runtime_privileged stat -c '%s' -- "$RUNTIME_LOCK_FILE")" ||
    [ "$lock_size" != "0" ]; then
    LAST_ERROR="Runtime lock file must remain empty."
    return 1
  fi
  if ! runtime_privileged chmod 644 "$RUNTIME_LOCK_FILE"; then
    LAST_ERROR="Runtime lock file permissions could not be set."
    return 1
  fi
  if ! { exec {RUNTIME_LOCK_FD}<"$RUNTIME_LOCK_FILE"; } 2>/dev/null; then
    LAST_ERROR="Runtime lock file could not be opened."
    return 1
  fi
  if ! flock -n "$RUNTIME_LOCK_FD"; then
    LAST_ERROR="Another QR runtime operation is already in progress."
    return 1
  fi
}

gateway_worker_state() {
  local container_ids

  if ! container_ids="$(gateway_compose ps --status running --quiet \
    "$GATEWAY_SERVICE" 2>/dev/null)"; then
    LAST_ERROR="Gateway wechat-worker state could not be queried."
    return 2
  fi
  if [ -n "$container_ids" ]; then
    printf 'running'
  else
    printf 'stopped'
  fi
}

gateway_worker_is_running() {
  local state

  if ! state="$(gateway_worker_state)"; then
    LAST_ERROR="Gateway wechat-worker state could not be queried."
    return 2
  fi
  [ "$state" = "running" ]
}

stop_gateway_worker() {
  local state

  if ! gateway_compose stop "$GATEWAY_SERVICE" >/dev/null 2>&1; then
    LAST_ERROR="Gateway wechat-worker stop command failed."
    return 1
  fi
  if ! state="$(gateway_worker_state)"; then
    LAST_ERROR="Gateway wechat-worker state could not be queried after stop."
    return 1
  fi
  if [ "$state" != "stopped" ]; then
    LAST_ERROR="Gateway wechat-worker did not stop."
    return 1
  fi
}

start_gateway_worker() {
  local state

  if ! gateway_compose up -d --no-deps "$GATEWAY_SERVICE" \
    >/dev/null 2>&1; then
    LAST_ERROR="Gateway wechat-worker start command failed."
    return 1
  fi
  if ! state="$(gateway_worker_state)"; then
    LAST_ERROR="Gateway wechat-worker state could not be queried after start."
    return 1
  fi
  if [ "$state" != "running" ]; then
    LAST_ERROR="Gateway wechat-worker did not reach running state."
    return 1
  fi
  wait_for_gateway_worker_health
}

container_health_status() {
  local container_id="$1"

  runtime_docker inspect --format \
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
    "$container_id" 2>/dev/null
}

gateway_worker_heartbeat_is_healthy() {
  runtime_with_timeout "$WORKER_HEARTBEAT_TIMEOUT" \
    "$GATEWAY_HEARTBEAT_COMMAND" >/dev/null 2>&1
}

wait_for_gateway_worker_health() {
  local started_at=$SECONDS container_id first_id="" health

  while [ "$((SECONDS - started_at))" -lt "$WORKER_READY_TIMEOUT" ]; do
    if container_id="$(gateway_compose ps --status running --quiet \
      "$GATEWAY_SERVICE" 2>/dev/null)" &&
      [ -n "$container_id" ] &&
      [ "${container_id//$'\n'/}" = "$container_id" ] &&
      health="$(container_health_status "$container_id")" &&
      [ "$health" = "healthy" ] &&
      gateway_worker_heartbeat_is_healthy; then
      first_id="$container_id"
      sleep "$WORKER_STABLE_SECONDS"
      if container_id="$(gateway_compose ps --status running --quiet \
        "$GATEWAY_SERVICE" 2>/dev/null)" &&
        [ "$container_id" = "$first_id" ] &&
        health="$(container_health_status "$container_id")" &&
        [ "$health" = "healthy" ] &&
        gateway_worker_heartbeat_is_healthy; then
        return 0
      fi
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="Gateway wechat-worker did not reach stable Docker health with a verified application heartbeat."
  return 1
}

agent_container_state() {
  local all_ids running_ids

  if ! all_ids="$(agent_compose ps --all --quiet agent-wechat 2>/dev/null)"; then
    LAST_ERROR="agent-wechat container state could not be queried."
    return 2
  fi
  if [ -z "$all_ids" ]; then
    printf 'absent'
    return 0
  fi
  if ! running_ids="$(agent_compose ps --status running --quiet \
    agent-wechat 2>/dev/null)"; then
    LAST_ERROR="agent-wechat running state could not be queried."
    return 2
  fi
  if [ -n "$running_ids" ]; then
    printf 'running'
  else
    printf 'stopped'
  fi
}

agent_container_exists() {
  local state

  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried."
    return 2
  fi
  [ "$state" != "absent" ]
}

agent_container_is_running() {
  local state

  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried."
    return 2
  fi
  [ "$state" = "running" ]
}

stop_agent_container() {
  local state

  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried before stop."
    return 1
  fi
  if [ "$state" = "running" ]; then
    if ! agent_compose stop agent-wechat >/dev/null 2>&1; then
      LAST_ERROR="agent-wechat stop command failed."
      return 1
    fi
    if ! state="$(agent_container_state)"; then
      LAST_ERROR="agent-wechat container state could not be queried after stop."
      return 1
    fi
    if [ "$state" = "running" ]; then
      LAST_ERROR="agent-wechat did not stop."
      return 1
    fi
  fi
}

remove_agent_container() {
  local state

  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried before removal."
    return 1
  fi
  if [ "$state" != "absent" ]; then
    if ! agent_compose rm --force agent-wechat >/dev/null 2>&1; then
      LAST_ERROR="agent-wechat remove command failed."
      return 1
    fi
    if ! state="$(agent_container_state)"; then
      LAST_ERROR="agent-wechat container state could not be queried after removal."
      return 1
    fi
    if [ "$state" != "absent" ]; then
      LAST_ERROR="agent-wechat container still exists after removal."
      return 1
    fi
  fi
}

cleanup_failed_agent_container() {
  local cleanup_failed=0

  # These result globals are written to the lifecycle manifest by the caller.
  # shellcheck disable=SC2034
  AGENT_FAILURE_CLEANUP_ATTEMPTED=true
  if stop_agent_container; then
    # shellcheck disable=SC2034
    AGENT_FAILURE_CLEANUP_STOP_RESULT="succeeded"
  else
    # shellcheck disable=SC2034
    AGENT_FAILURE_CLEANUP_STOP_RESULT="failed"
    cleanup_failed=1
  fi
  if remove_agent_container; then
    # shellcheck disable=SC2034
    AGENT_FAILURE_CLEANUP_REMOVE_RESULT="succeeded"
  else
    # shellcheck disable=SC2034
    AGENT_FAILURE_CLEANUP_REMOVE_RESULT="failed"
    cleanup_failed=1
  fi
  return "$cleanup_failed"
}

start_agent_container() {
  local state

  if ! agent_compose up -d --force-recreate --no-deps agent-wechat \
    >/dev/null 2>&1; then
    LAST_ERROR="agent-wechat start command failed."
    return 1
  fi
  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried after start."
    return 1
  fi
  if [ "$state" != "running" ]; then
    LAST_ERROR="agent-wechat did not reach running state."
    return 1
  fi
}

wait_for_agent_health() {
  local started_at=$SECONDS state health

  while [ "$((SECONDS - started_at))" -lt "$SERVER_READY_TIMEOUT" ]; do
    if state="$(agent_container_state)" && [ "$state" = "running" ] &&
      health="$(container_health_status "$CONTAINER_NAME")" &&
      [ "$health" = "healthy" ]; then
      return 0
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="agent-wechat did not reach Docker healthy state before timeout."
  return 1
}

runtime_wechat_process_identity() {
  # Variables in this snippet are expanded by the shell inside the container.
  # shellcheck disable=SC2016
  runtime_docker exec "$CONTAINER_NAME" sh -c '
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

wait_for_agent_server() {
  local started_at=$SECONDS

  while [ "$((SECONDS - started_at))" -lt "$SERVER_READY_TIMEOUT" ]; do
    if check_agent_server; then
      return 0
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="Agent Server did not become reachable before timeout."
  return 1
}

wait_for_stable_wechat_process() {
  local started_at=$SECONDS
  local first_identity second_identity

  while [ "$((SECONDS - started_at))" -lt "$WECHAT_READY_TIMEOUT" ]; do
    if first_identity="$(runtime_wechat_process_identity)" &&
      [ -n "$first_identity" ]; then
      sleep "$WECHAT_STABLE_SECONDS"
      if second_identity="$(runtime_wechat_process_identity)" &&
        [ "$second_identity" = "$first_identity" ]; then
        # Read by start-qr-login.sh after this shared function returns.
        # shellcheck disable=SC2034
        STABLE_WECHAT_IDENTITY="$second_identity"
        return 0
      fi
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="/usr/bin/wechat did not remain stable before timeout."
  return 1
}
