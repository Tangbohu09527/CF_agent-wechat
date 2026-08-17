#!/usr/bin/env bash

set +x

RUNTIME_SCRIPTS_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNTIME_REPO_ROOT="$(CDPATH= cd -- "${RUNTIME_SCRIPTS_DIR}/.." && pwd -P)"

AGENT_COMPOSE_FILE="${CF_AGENT_WECHAT_COMPOSE_FILE:-${RUNTIME_REPO_ROOT}/docker/compose.cfserver.yaml}"
STORAGE_ROOT="${CF_AGENT_WECHAT_STORAGE_ROOT:-/srv/storage/cf-agent-wechat}"
RUNTIME_ROOT="${CF_AGENT_WECHAT_RUNTIME_ROOT:-${STORAGE_ROOT}/runtime}"
ARCHIVE_ROOT="${CF_AGENT_WECHAT_ARCHIVE_ROOT:-${STORAGE_ROOT}/session-archive}"
LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"
LEGACY_WECHAT_HOME_ROOT="${STORAGE_ROOT}/wechat-home"
RUNTIME_LOCK_FILE="${CF_AGENT_WECHAT_LOCK_FILE:-/run/lock/cf-agent-wechat-qr-runtime.lock}"
GATEWAY_COMPOSE_FILE="${CF_AGENT_GATEWAY_COMPOSE_FILE:-/opt/cf-agent-gateway/docker/compose.cfserver.yaml}"
GATEWAY_PROJECT_DIR="${CF_AGENT_GATEWAY_PROJECT_DIR:-/opt/cf-agent-gateway}"

RUNTIME_DEFAULT_UID="${CF_AGENT_WECHAT_RUNTIME_UID:-1000}"
RUNTIME_DEFAULT_GID="${CF_AGENT_WECHAT_RUNTIME_GID:-1000}"
RUNTIME_DEFAULT_MODE="${CF_AGENT_WECHAT_RUNTIME_MODE:-700}"
SERVER_READY_TIMEOUT="${SERVER_READY_TIMEOUT:-120}"
WECHAT_READY_TIMEOUT="${WECHAT_READY_TIMEOUT:-120}"
WECHAT_STABLE_SECONDS="${WECHAT_STABLE_SECONDS:-10}"
POST_LOGIN_READY_TIMEOUT="${POST_LOGIN_READY_TIMEOUT:-120}"
RUNTIME_POLL_INTERVAL="${RUNTIME_POLL_INTERVAL:-2}"

GATEWAY_SERVICE="wechat-worker"
RUNTIME_LOCK_FD=""
RUNTIME_DOCKER_USES_SUDO=0
STABLE_WECHAT_IDENTITY=""
LAST_ERROR="${LAST_ERROR:-}"

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

runtime_select_docker() {
  if docker info >/dev/null 2>&1; then
    RUNTIME_DOCKER_USES_SUDO=0
    return 0
  fi
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 &&
    sudo -- docker info >/dev/null 2>&1; then
    RUNTIME_DOCKER_USES_SUDO=1
    return 0
  fi
  LAST_ERROR="Docker daemon is unavailable or permission was denied."
  return 1
}

runtime_docker() {
  if [ "$RUNTIME_DOCKER_USES_SUDO" -eq 1 ]; then
    sudo -- docker "$@"
  else
    docker "$@"
  fi
}

runtime_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -- "$@"
  fi
}

agent_compose() {
  if [ "$RUNTIME_DOCKER_USES_SUDO" -eq 1 ]; then
    sudo -- env "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" docker compose \
      --project-directory "$RUNTIME_REPO_ROOT" \
      -f "$AGENT_COMPOSE_FILE" "$@"
  else
    env "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" docker compose \
      --project-directory "$RUNTIME_REPO_ROOT" \
      -f "$AGENT_COMPOSE_FILE" "$@"
  fi
}

gateway_compose() {
  runtime_docker compose \
    --project-directory "$GATEWAY_PROJECT_DIR" \
    -f "$GATEWAY_COMPOSE_FILE" "$@"
}

runtime_validate_agent_token_mount() {
  local config_json configured_source configured_canonical token_canonical

  if ! config_json="$(agent_compose config --format json 2>/dev/null)"; then
    LAST_ERROR="agent-wechat Compose JSON configuration could not be inspected."
    return 1
  fi
  if ! configured_source="$(printf '%s' "$config_json" | "$PYTHON_BIN" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
    service = payload["services"]["agent-wechat"]
    volumes = service["volumes"]
except (json.JSONDecodeError, KeyError, TypeError):
    raise SystemExit(2)

matches = [
    volume
    for volume in volumes
    if isinstance(volume, dict)
    and volume.get("target") == "/data/auth-token"
]
if len(matches) != 1:
    raise SystemExit(2)
mount = matches[0]
if (
    mount.get("type") != "bind"
    or mount.get("read_only") is not True
    or not isinstance(mount.get("source"), str)
):
    raise SystemExit(2)
sys.stdout.write(mount["source"])
')"; then
    LAST_ERROR="agent-wechat Compose must define one read-only auth-token bind mount."
    return 1
  fi
  if ! configured_canonical="$(runtime_canonical_path "$configured_source")" ||
    ! token_canonical="$(runtime_canonical_path "$TOKEN_FILE")"; then
    LAST_ERROR="Token mount paths could not be canonicalized."
    return 1
  fi
  if [ "$configured_canonical" != "$token_canonical" ]; then
    LAST_ERROR="TOKEN_FILE does not match the agent-wechat Compose auth-token source."
    return 1
  fi
}

runtime_validate_configuration() {
  local command_name services
  local storage_canonical runtime_canonical archive_canonical token_canonical
  local lock_canonical
  local archive_parent runtime_parent lock_parent
  local archive_parent_device runtime_parent_device
  local required_file required_path value_name
  local runtime_present=0 legacy_present=0

  for command_name in \
    docker flock stat date mv install readlink awk curl mktemp mkdir chmod \
    chown rm sleep cksum sh dirname env; do
    runtime_require_command "$command_name" || return 1
  done
  if [ "$(id -u)" -ne 0 ]; then
    runtime_require_command sudo || return 1
  fi

  for value_name in \
    RUNTIME_DEFAULT_UID RUNTIME_DEFAULT_GID SERVER_READY_TIMEOUT \
    WECHAT_READY_TIMEOUT WECHAT_STABLE_SECONDS POST_LOGIN_READY_TIMEOUT \
    RUNTIME_POLL_INTERVAL; do
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
    [ "$POST_LOGIN_READY_TIMEOUT" -eq 0 ]; then
    LAST_ERROR="Runtime readiness timeouts must be greater than zero."
    return 1
  fi

  for required_path in \
    "$AGENT_COMPOSE_FILE" "$STORAGE_ROOT" "$RUNTIME_ROOT" "$ARCHIVE_ROOT" \
    "$GATEWAY_COMPOSE_FILE" "$GATEWAY_PROJECT_DIR" "$TOKEN_FILE" \
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
    if [ -L "$required_file" ] || [ ! -f "$required_file" ]; then
      LAST_ERROR="Required Compose file is missing or is a symlink."
      return 1
    fi
  done
  if runtime_privileged test -L "$STORAGE_ROOT" ||
    ! runtime_privileged test -d "$STORAGE_ROOT"; then
    LAST_ERROR="Storage root must be an existing non-symlink directory."
    return 1
  fi
  if [ -L "$GATEWAY_PROJECT_DIR" ] || [ ! -d "$GATEWAY_PROJECT_DIR" ]; then
    LAST_ERROR="Gateway project directory is missing or is a symlink."
    return 1
  fi
  runtime_validate_directory_or_missing "$RUNTIME_ROOT" "Runtime path" || return 1
  runtime_validate_directory_or_missing "$ARCHIVE_ROOT" "Archive path" || return 1
  runtime_validate_directory_or_missing \
    "${RUNTIME_ROOT}/data" "Runtime data path" || return 1
  runtime_validate_directory_or_missing \
    "${RUNTIME_ROOT}/wechat-home" "Runtime WeChat HOME path" || return 1
  runtime_validate_directory_or_missing "$LEGACY_DATA_ROOT" "Legacy data path" || return 1
  runtime_validate_directory_or_missing \
    "$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME path" || return 1

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

  runtime_select_docker || return 1
  if ! agent_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="agent-wechat Compose configuration is invalid."
    return 1
  fi
  runtime_validate_agent_token_mount || return 1
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

  for command_name in docker flock readlink install stat awk chmod sh dirname env; do
    runtime_require_command "$command_name" || return 1
  done
  if [ "$(id -u)" -ne 0 ]; then
    runtime_require_command sudo || return 1
  fi
  for required_path in \
    "$AGENT_COMPOSE_FILE" "$STORAGE_ROOT" "$GATEWAY_COMPOSE_FILE" \
    "$GATEWAY_PROJECT_DIR" "$RUNTIME_LOCK_FILE"; do
    case "$required_path" in
      /*) ;;
      *)
        LAST_ERROR="Production control paths must be absolute."
        return 1
        ;;
    esac
  done
  for required_file in "$AGENT_COMPOSE_FILE" "$GATEWAY_COMPOSE_FILE"; do
    if [ -L "$required_file" ] || [ ! -f "$required_file" ]; then
      LAST_ERROR="Required Compose file is missing or is a symlink."
      return 1
    fi
  done
  if runtime_privileged test -L "$STORAGE_ROOT" ||
    ! runtime_privileged test -d "$STORAGE_ROOT"; then
    LAST_ERROR="Storage root must be an existing non-symlink directory."
    return 1
  fi
  if [ -L "$GATEWAY_PROJECT_DIR" ] || [ ! -d "$GATEWAY_PROJECT_DIR" ]; then
    LAST_ERROR="Gateway project directory is missing or is a symlink."
    return 1
  fi
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

runtime_wechat_process_identity() {
  runtime_docker exec "$CONTAINER_NAME" sh -c '
for process_dir in /proc/[0-9]*; do
  [ "$(readlink "$process_dir/exe" 2>/dev/null || true)" = /usr/bin/wechat ] ||
    continue
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
        STABLE_WECHAT_IDENTITY="$second_identity"
        return 0
      fi
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="/usr/bin/wechat did not remain stable before timeout."
  return 1
}
