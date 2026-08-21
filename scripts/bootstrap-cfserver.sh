#!/usr/bin/env bash
set -Eeuo pipefail

set +x
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_AGENT_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)"
DEFAULT_RUNTIME_ROOT="/srv/storage/cf-agent-wechat"

CF_AGENT_WECHAT_ROOT="${CF_AGENT_WECHAT_ROOT:-$DEFAULT_AGENT_ROOT}"
CF_GATEWAY_ROOT="${CF_GATEWAY_ROOT:-$(dirname -- "$CF_AGENT_WECHAT_ROOT")/cf-agent-gateway}"

CF_RUNTIME_ROOT_WAS_SET=0
CF_AGENT_WECHAT_RUNTIME_ROOT_WAS_SET=0
CF_AGENT_WECHAT_RUNTIME_ROOT_INPUT=""
RUNTIME_ROOT_EXPLICIT=0
if [ "${CF_RUNTIME_ROOT+x}" = x ]; then
  CF_RUNTIME_ROOT_WAS_SET=1
  RUNTIME_ROOT_EXPLICIT=1
elif [ "${CF_AGENT_WECHAT_RUNTIME_ROOT+x}" = x ]; then
  CF_AGENT_WECHAT_RUNTIME_ROOT_WAS_SET=1
  CF_AGENT_WECHAT_RUNTIME_ROOT_INPUT="$CF_AGENT_WECHAT_RUNTIME_ROOT"
  CF_RUNTIME_ROOT="$CF_AGENT_WECHAT_RUNTIME_ROOT"
  RUNTIME_ROOT_EXPLICIT=1
else
  CF_RUNTIME_ROOT="$DEFAULT_RUNTIME_ROOT"
fi
if [ "${CF_AGENT_WECHAT_RUNTIME_ROOT+x}" = x ]; then
  CF_AGENT_WECHAT_RUNTIME_ROOT_WAS_SET=1
  CF_AGENT_WECHAT_RUNTIME_ROOT_INPUT="$CF_AGENT_WECHAT_RUNTIME_ROOT"
fi
CF_AGENT_WECHAT_RUNTIME_ROOT="$CF_RUNTIME_ROOT"

COMPOSE_FILE="${CF_AGENT_WECHAT_ROOT}/docker/compose.cfserver.yaml"
ENV_FILE="${CF_AGENT_WECHAT_ROOT}/docker/.env"
SERVICE_NAME="agent-wechat"
NETWORK_NAME="cf-internal"
NETWORK_ALIAS="cf-agent-wechat"
PROJECT_NAME="cf-agent-wechat"

RUNTIME_UID="${CF_RUNTIME_UID:-1000}"
RUNTIME_GID="${CF_RUNTIME_GID:-1000}"
RUNTIME_MODE="${CF_RUNTIME_MODE:-700}"
STORAGE_UID="${CF_STORAGE_UID:-0}"
STORAGE_GID="${CF_STORAGE_GID:-0}"
SECRETS_UID="${CF_SECRETS_UID:-0}"
SECRETS_GID="${CF_SECRETS_GID:-0}"

BOOTSTRAP_TIMEOUT="${CF_BOOTSTRAP_TIMEOUT:-180}"
POLL_INTERVAL="${CF_BOOTSTRAP_POLL_INTERVAL:-2}"
HTTP_CONNECT_TIMEOUT="${CF_BOOTSTRAP_HTTP_CONNECT_TIMEOUT:-3}"
HTTP_TIMEOUT="${CF_BOOTSTRAP_HTTP_TIMEOUT:-45}"
DOCKER_COMMAND_TIMEOUT="${CF_BOOTSTRAP_DOCKER_TIMEOUT:-30}"
COMPOSE_UP_TIMEOUT="${CF_BOOTSTRAP_COMPOSE_UP_TIMEOUT:-900}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
TIMEOUT_TERM_GRACE=2
STAT_BIN="${STAT_BIN:-stat}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REALPATH_BIN="${REALPATH_BIN:-realpath}"

CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
DOCKER_USE_SUDO=0
ENV_CREATED=0
TOKEN_CREATED=0
IMAGE_REF=""
BIND_IP=""
HOST_PORT=""
CONTAINER_NAME=""
API_URL=""
NORMALIZED_RUNTIME_ROOT=""
CANONICAL_DEFAULT_RUNTIME_ROOT=""
BOOTSTRAP_INITIALIZED=0
BOOTSTRAP_MANAGED=0
RUNTIME_ENV_NEEDS_MIGRATION=0
PERSISTED_ENV_VALUE=""
BOUNDED_CONNECT_TIMEOUT=0
BOUNDED_HTTP_TIMEOUT=0

log() {
  printf '[INFO] %s\n' "$*"
}

pass() {
  printf '[PASS] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap-cfserver.sh

Initializes and starts the production CF_agent-wechat service. The only
required first-run input is a digest-pinned AGENT_WECHAT_IMAGE when docker/.env
does not already exist.

Primary path overrides:
  CF_AGENT_WECHAT_ROOT  repository root (default: root containing this script)
  CF_GATEWAY_ROOT       adjacent Gateway root (default: ../cf-agent-gateway)
  CF_RUNTIME_ROOT       persistent data root (default: /srv/storage/cf-agent-wechat)
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

validate_absolute_path() {
  local label="$1"
  local path="$2"

  case "$path" in
    /*) ;;
    *) die "$label must be an absolute path: $path" ;;
  esac
  case "$path" in
    *[[:cntrl:]]*) die "$label must not contain control characters" ;;
  esac
}

validate_dotenv_safe_absolute_path() {
  local label="$1"
  local path="$2"
  local LC_ALL=C
  local dotenv_path_pattern='^/[-A-Za-z0-9._/@%+,=:~]*$'

  [[ "$path" =~ $dotenv_path_pattern ]] || \
    die "$label must use only dotenv-safe ASCII absolute path characters (letters, digits, / . _ - @ % + , = : ~)"
}

normalize_runtime_root() {
  local label="$1"
  local value="$2"
  local normalized

  validate_absolute_path "$label" "$value"
  validate_dotenv_safe_absolute_path "$label" "$value"
  case "$value" in
    */../*|*/..)
      die "$label must not contain a '..' path segment: $value"
      ;;
  esac

  normalized="$("$REALPATH_BIN" -m -- "$value" 2>/dev/null)" || \
    die "$label could not be normalized: $value"
  [ "$normalized" != "/" ] || \
    die "$label must not resolve to the filesystem root"
  validate_absolute_path "$label normalized value" "$normalized"
  validate_dotenv_safe_absolute_path "$label normalized value" "$normalized"
  NORMALIZED_RUNTIME_ROOT="$normalized"
}

validate_integer() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be a non-negative integer"
}

validate_positive_integer() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$label must be a positive integer"
}

run_with_hard_timeout() {
  local hard_timeout="$1"
  local soft_timeout
  shift

  if [ "$hard_timeout" -le "$TIMEOUT_TERM_GRACE" ]; then
    "$TIMEOUT_BIN" --signal=KILL "${hard_timeout}s" "$@"
    return
  fi

  soft_timeout=$((hard_timeout - TIMEOUT_TERM_GRACE))
  "$TIMEOUT_BIN" --signal=TERM --kill-after="${TIMEOUT_TERM_GRACE}s" \
    "${soft_timeout}s" "$@"
}

bounded_command_timeout() {
  local maximum="$1"
  local deadline="${2:-0}"
  local remaining

  if [ "$deadline" -le 0 ]; then
    printf '%s' "$maximum"
    return 0
  fi

  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || return 1
  if [ "$maximum" -lt "$remaining" ]; then
    printf '%s' "$maximum"
  else
    printf '%s' "$remaining"
  fi
}

validate_mode() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[0-7]{3}$ ]] || die "$label must be a three-digit octal file mode"
}
validate_management_owner() {
  local label="$1" owner="$2" path="$3"

  if [ "$owner" != "0" ] && [ "$owner" != "$CURRENT_UID" ]; then
    die "$label must be owned by root or the invoking fixed management user: $path"
  fi
}

validate_management_permission_contract() {
  [ "$RUNTIME_MODE" = "700" ] ||
    die "CF_RUNTIME_MODE must be 700 for the production runtime"

  if [ "$CF_RUNTIME_ROOT" = "$CANONICAL_DEFAULT_RUNTIME_ROOT" ]; then
    if [ "$SECRETS_UID" != "0" ] || [ "$SECRETS_GID" != "0" ]; then
      die "the default runtime requires CF_SECRETS_UID=0 and CF_SECRETS_GID=0 for the fixed sudo token reader"
    fi
    return
  fi

  if [ "$SECRETS_UID" != "$CURRENT_UID" ]; then
    die "a custom runtime requires CF_SECRETS_UID to match the invoking management user UID $CURRENT_UID"
  fi
}

validate_fresh_runtime_state() {
  if path_is_present "${CF_RUNTIME_ROOT}/data" ||
    path_is_present "${CF_RUNTIME_ROOT}/wechat-home" ||
    path_is_present "${CF_RUNTIME_ROOT}/secrets"; then
    die "docker/.env is absent but persistent runtime state already exists; restore the matching environment file or select a fresh empty CF_RUNTIME_ROOT"
  fi
}

run_as_root() {
  if [ "$CURRENT_UID" = "0" ]; then
    "$@"
    return
  fi
  command -v sudo >/dev/null 2>&1 || \
    die "root access is required for $1; install/configure sudo or run as root"
  sudo -- "$@"
}

run_for_owner() {
  local uid="$1"
  local gid="$2"
  shift 2

  if [ "$uid" = "$CURRENT_UID" ] && [ "$gid" = "$CURRENT_GID" ]; then
    if "$@"; then
      return
    fi
  fi
  run_as_root "$@"
}

path_is_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

ensure_directory() {
  local label="$1"
  local path="$2"
  local uid="$3"
  local gid="$4"
  local mode="$5"
  local metadata

  if [ -L "$path" ]; then
    die "$label must not be a symbolic link: $path"
  fi
  if [ ! -e "$path" ]; then
    run_for_owner "$uid" "$gid" install -d -o "$uid" -g "$gid" -m "$mode" -- "$path" || \
      die "could not create $label: $path"
    log "created $label: $path"
  elif [ ! -d "$path" ]; then
    die "$label is not a directory: $path"
  fi

  metadata="$($STAT_BIN -c '%u:%g:%a' -- "$path" 2>/dev/null)" || \
    die "could not inspect $label: $path"
  [ "$metadata" = "${uid}:${gid}:${mode}" ] || \
    die "$label must be owned by ${uid}:${gid} with mode ${mode}; found ${metadata}: $path"
}

read_env_value() {
  local key="$1"

  if [ -r "$ENV_FILE" ]; then
    awk -F= -v key="$key" '
      $0 ~ "^[[:space:]]*" key "=" {
        sub(/^[^=]*=/, "")
        value = $0
      }
      END { print value }
    ' "$ENV_FILE"
  else
    run_as_root awk -F= -v key="$key" '
      $0 ~ "^[[:space:]]*" key "=" {
        sub(/^[^=]*=/, "")
        value = $0
      }
      END { print value }
    ' "$ENV_FILE"
  fi
}

validate_application_root() {
  local metadata owner mode

  metadata="$($STAT_BIN -c '%u:%a' -- "$CF_AGENT_WECHAT_ROOT" 2>/dev/null)" || \
    die "could not inspect CF_AGENT_WECHAT_ROOT: $CF_AGENT_WECHAT_ROOT"
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  validate_mode "CF_AGENT_WECHAT_ROOT mode" "$mode"
  validate_management_owner "CF_AGENT_WECHAT_ROOT" "$owner" "$CF_AGENT_WECHAT_ROOT"
  if (( (8#$mode & 8#022) != 0 )); then
    die "CF_AGENT_WECHAT_ROOT must not be group/other writable: $CF_AGENT_WECHAT_ROOT"
  fi
}

validate_environment_parent() {
  local env_dir metadata owner mode

  env_dir="$(dirname -- "$ENV_FILE")"
  if [ -L "$env_dir" ]; then
    die "environment file parent directory must not be a symbolic link: $env_dir"
  fi
  [ -d "$env_dir" ] || die "environment file parent directory is missing: $env_dir"

  metadata="$($STAT_BIN -c '%u:%a' -- "$env_dir" 2>/dev/null)" || \
    die "could not inspect environment file parent directory: $env_dir"
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  validate_mode "environment file parent directory mode" "$mode"
  validate_management_owner "environment file parent directory" "$owner" "$env_dir"
  if (( (8#$mode & 8#022) != 0 )); then
    die "environment file parent directory must not be group/other writable: $env_dir"
  fi
}

validate_production_compose_file() {
  local metadata owner mode link_count

  metadata="$($STAT_BIN -c '%u:%a:%h' -- "$COMPOSE_FILE" 2>/dev/null)" || \
    die "could not inspect production Compose file: $COMPOSE_FILE"
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  mode="${mode%%:*}"
  link_count="${metadata##*:}"
  validate_mode "production Compose file mode" "$mode"
  validate_management_owner "production Compose file" "$owner" "$COMPOSE_FILE"
  if (( (8#$mode & 8#022) != 0 )); then
    die "production Compose file must not be group/other writable: $COMPOSE_FILE"
  fi
  [ "$link_count" = "1" ] || \
    die "production Compose file must not have additional hard links: $COMPOSE_FILE"
}

env_key_count() {
  local key="$1"

  if [ -r "$ENV_FILE" ]; then
    awk -F= -v key="$key" '
      $0 ~ "^[[:space:]]*" key "=" { count++ }
      END { print count + 0 }
    ' "$ENV_FILE"
  else
    run_as_root awk -F= -v key="$key" '
      $0 ~ "^[[:space:]]*" key "=" { count++ }
      END { print count + 0 }
    ' "$ENV_FILE"
  fi
}

ensure_env_assignment() {
  local key="$1"
  local value="$2"
  local env_dir
  local -a update_command

  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid environment key: $key"
  case "$value" in
    *[[:cntrl:]]*) die "environment value for $key contains control characters" ;;
  esac

  env_dir="$(dirname -- "$ENV_FILE")"
  update_command=(
    /bin/sh -eu -c '
      target=$1
      directory=$2
      key=$3
      value=$4
      [ -f "$target" ] && [ ! -L "$target" ]

      if grep -Eq "^[[:space:]]*${key}=" "$target"; then
        [ "$(grep -Ec "^[[:space:]]*${key}=" "$target")" -eq 1 ]
        grep -Fxq "${key}=${value}" "$target"
        exit 0
      fi

      umask 077
      tmp=$(mktemp "$directory/.cf-agent-wechat.env.XXXXXX")
      trap '\''rm -f -- "$tmp"'\'' 0 1 2 15
      cp -p -- "$target" "$tmp"
      {
        while IFS= read -r line || [ -n "$line" ]; do
          printf "%s\n" "$line"
        done < "$target"
        printf "%s=%s\n" "$key" "$value"
      } > "$tmp"
      mv -f -- "$tmp" "$target"
      trap - 0 1 2 15
    ' bootstrap-env-update "$ENV_FILE" "$env_dir" "$key" "$value"
  )

  if [ "$CURRENT_UID" = "0" ] || [ -w "$env_dir" ]; then
    "${update_command[@]}" || die "could not persist $key in environment file: $ENV_FILE"
  else
    run_as_root "${update_command[@]}" || \
      die "could not persist $key in environment file: $ENV_FILE"
  fi

  log "persisted $key in environment file"
}

resolve_env_setting() {
  local key="$1"
  local current_value="$2"
  local explicit_marker="$3"
  local value_kind="$4"
  local count persisted_value

  count="$(env_key_count "$key")"
  [ "$count" -le 1 ] || die "environment file contains duplicate $key assignments"
  if [ "$count" -eq 0 ]; then
    PERSISTED_ENV_VALUE="$current_value"
    return
  fi

  persisted_value="$(read_env_value "$key")"
  case "$value_kind" in
    integer) validate_integer "$key in $ENV_FILE" "$persisted_value" ;;
    mode) validate_mode "$key in $ENV_FILE" "$persisted_value" ;;
    *) die "unsupported persisted setting kind: $value_kind" ;;
  esac
  if [ "$explicit_marker" = x ] && [ "$current_value" != "$persisted_value" ]; then
    die "$key differs from the authoritative environment file: $ENV_FILE"
  fi
  PERSISTED_ENV_VALUE="$persisted_value"
}

ensure_runtime_settings_persisted() {
  if [ "$(env_key_count CF_RUNTIME_UID)" -eq 0 ]; then
    ensure_env_assignment CF_RUNTIME_UID "$RUNTIME_UID"
  fi
  if [ "$(env_key_count CF_RUNTIME_GID)" -eq 0 ]; then
    ensure_env_assignment CF_RUNTIME_GID "$RUNTIME_GID"
  fi
  if [ "$(env_key_count CF_RUNTIME_MODE)" -eq 0 ]; then
    ensure_env_assignment CF_RUNTIME_MODE "$RUNTIME_MODE"
  fi
  if [ "$(env_key_count CF_STORAGE_UID)" -eq 0 ]; then
    ensure_env_assignment CF_STORAGE_UID "$STORAGE_UID"
  fi
  if [ "$(env_key_count CF_STORAGE_GID)" -eq 0 ]; then
    ensure_env_assignment CF_STORAGE_GID "$STORAGE_GID"
  fi
  if [ "$(env_key_count CF_SECRETS_UID)" -eq 0 ]; then
    ensure_env_assignment CF_SECRETS_UID "$SECRETS_UID"
  fi
  if [ "$(env_key_count CF_SECRETS_GID)" -eq 0 ]; then
    ensure_env_assignment CF_SECRETS_GID "$SECRETS_GID"
  fi
}

create_environment_file() {
  local image="$1"
  local bind_ip="$2"
  local port="$3"
  local container="$4"
  local runtime_root="$5"
  local env_dir
  local -a create_command

  env_dir="$(dirname -- "$ENV_FILE")"
  [ -d "$env_dir" ] || die "environment file parent directory is missing: $env_dir"
  create_command=(
    /bin/sh -eu -c '
      target=$1
      directory=$2
      image=$3
      bind_ip=$4
      port=$5
      container=$6
      runtime_root=$7
      owner_uid=$8
      owner_gid=$9
      runtime_uid=${10}
      runtime_gid=${11}
      runtime_mode=${12}
      storage_uid=${13}
      storage_gid=${14}
      secrets_uid=${15}
      secrets_gid=${16}
      umask 077
      tmp=$(mktemp "$directory/.cf-agent-wechat.env.XXXXXX")
      trap '\''rm -f -- "$tmp"'\'' 0 1 2 15
      printf "%s\n" \
        "AGENT_WECHAT_IMAGE=$image" \
        "AGENT_WECHAT_BIND_IP=$bind_ip" \
        "AGENT_WECHAT_PORT=$port" \
        "AGENT_WECHAT_CONTAINER_NAME=$container" \
        "CF_AGENT_WECHAT_RUNTIME_ROOT=$runtime_root" \
        "CF_RUNTIME_UID=$runtime_uid" \
        "CF_RUNTIME_GID=$runtime_gid" \
        "CF_RUNTIME_MODE=$runtime_mode" \
        "CF_STORAGE_UID=$storage_uid" \
        "CF_STORAGE_GID=$storage_gid" \
        "CF_SECRETS_UID=$secrets_uid" \
        "CF_SECRETS_GID=$secrets_gid" \
        "CF_AGENT_WECHAT_BOOTSTRAP_MANAGED=1" \
        "PROXY=" \
        "RUST_LOG=info" > "$tmp"
      if [ "$(id -u)" = "0" ]; then
        chown "$owner_uid:$owner_gid" "$tmp"
      fi
      chmod 600 "$tmp"
      if ! ln "$tmp" "$target" 2>/dev/null; then
        [ -f "$target" ] && [ ! -L "$target" ] || exit 1
      fi
      rm -f -- "$tmp"
      trap - 0 1 2 15
    ' bootstrap-env "$ENV_FILE" "$env_dir" "$image" "$bind_ip" "$port" "$container" \
      "$runtime_root" "$CURRENT_UID" "$CURRENT_GID" \
      "$RUNTIME_UID" "$RUNTIME_GID" "$RUNTIME_MODE" "$STORAGE_UID" "$STORAGE_GID" \
      "$SECRETS_UID" "$SECRETS_GID"
  )

  if [ "$CURRENT_UID" = "0" ] || [ -w "$env_dir" ]; then
    "${create_command[@]}" || die "could not create environment file: $ENV_FILE"
  else
    run_as_root "${create_command[@]}" || die "could not create environment file: $ENV_FILE"
  fi

  ENV_CREATED=1
  log "created production environment file: $ENV_FILE"
}

validate_environment_file() {
  local env_metadata env_owner env_mode env_link_count
  local file_image file_bind_ip file_port file_container file_rust_log
  local file_runtime_root file_legacy_runtime_root file_bootstrapped file_managed
  local runtime_key_count legacy_runtime_key_count bootstrapped_key_count managed_key_count
  local image_key_count bind_ip_key_count port_key_count container_key_count
  local proxy_key_count rust_log_key_count
  local canonical_runtime_root="" canonical_legacy_runtime_root=""
  local persisted_runtime_root

  if [ -L "$ENV_FILE" ]; then
    die "environment file must not be a symbolic link: $ENV_FILE"
  fi
  [ -f "$ENV_FILE" ] || die "environment path is not a regular file: $ENV_FILE"

  env_metadata="$($STAT_BIN -c '%u:%a:%h' -- "$ENV_FILE" 2>/dev/null)" || \
    die "could not inspect environment file permissions: $ENV_FILE"
  env_owner="${env_metadata%%:*}"
  env_mode="${env_metadata#*:}"
  env_mode="${env_mode%%:*}"
  env_link_count="${env_metadata##*:}"
  validate_mode "environment file mode" "$env_mode"
  validate_management_owner "environment file" "$env_owner" "$ENV_FILE"
  case "$env_mode" in
    600|640) ;; *) die "environment file must have mode 600 or 640: $ENV_FILE" ;;
  esac
  [ "$env_link_count" = "1" ] || \
    die "environment file must not have additional hard links: $ENV_FILE"

  file_image="$(read_env_value AGENT_WECHAT_IMAGE)"
  file_bind_ip="$(read_env_value AGENT_WECHAT_BIND_IP)"
  file_port="$(read_env_value AGENT_WECHAT_PORT)"
  file_container="$(read_env_value AGENT_WECHAT_CONTAINER_NAME)"
  file_runtime_root="$(read_env_value CF_AGENT_WECHAT_RUNTIME_ROOT)"
  file_legacy_runtime_root="$(read_env_value CF_AGENT_WECHAT_STORAGE_ROOT)"
  file_bootstrapped="$(read_env_value CF_AGENT_WECHAT_BOOTSTRAPPED)"
  file_managed="$(read_env_value CF_AGENT_WECHAT_BOOTSTRAP_MANAGED)"
  file_rust_log="$(read_env_value RUST_LOG)"

  runtime_key_count="$(env_key_count CF_AGENT_WECHAT_RUNTIME_ROOT)"
  legacy_runtime_key_count="$(env_key_count CF_AGENT_WECHAT_STORAGE_ROOT)"
  bootstrapped_key_count="$(env_key_count CF_AGENT_WECHAT_BOOTSTRAPPED)"
  managed_key_count="$(env_key_count CF_AGENT_WECHAT_BOOTSTRAP_MANAGED)"
  image_key_count="$(env_key_count AGENT_WECHAT_IMAGE)"
  bind_ip_key_count="$(env_key_count AGENT_WECHAT_BIND_IP)"
  port_key_count="$(env_key_count AGENT_WECHAT_PORT)"
  container_key_count="$(env_key_count AGENT_WECHAT_CONTAINER_NAME)"
  proxy_key_count="$(env_key_count PROXY)"
  rust_log_key_count="$(env_key_count RUST_LOG)"
  [ "$runtime_key_count" -le 1 ] || die "environment file contains duplicate CF_AGENT_WECHAT_RUNTIME_ROOT assignments"
  [ "$legacy_runtime_key_count" -le 1 ] || die "environment file contains duplicate CF_AGENT_WECHAT_STORAGE_ROOT assignments"
  [ "$bootstrapped_key_count" -le 1 ] || die "environment file contains duplicate CF_AGENT_WECHAT_BOOTSTRAPPED assignments"
  [ "$managed_key_count" -le 1 ] || die "environment file contains duplicate CF_AGENT_WECHAT_BOOTSTRAP_MANAGED assignments"
  [ "$image_key_count" -le 1 ] || die "environment file contains duplicate AGENT_WECHAT_IMAGE assignments"
  [ "$bind_ip_key_count" -le 1 ] || die "environment file contains duplicate AGENT_WECHAT_BIND_IP assignments"
  [ "$port_key_count" -le 1 ] || die "environment file contains duplicate AGENT_WECHAT_PORT assignments"
  [ "$container_key_count" -le 1 ] || die "environment file contains duplicate AGENT_WECHAT_CONTAINER_NAME assignments"
  [ "$proxy_key_count" -le 1 ] || die "environment file contains duplicate PROXY assignments"
  [ "$rust_log_key_count" -le 1 ] || die "environment file contains duplicate RUST_LOG assignments"
  if [ "$rust_log_key_count" -eq 1 ]; then
    case "$file_rust_log" in error|warn|info) ;; *) die "RUST_LOG must be error, warn, or info for production" ;; esac
  fi

  if [ "$bootstrapped_key_count" -eq 1 ]; then
    [ "$file_bootstrapped" = "1" ] || die "CF_AGENT_WECHAT_BOOTSTRAPPED must be exactly 1 when present"
    BOOTSTRAP_INITIALIZED=1
  fi
  if [ "$managed_key_count" -eq 1 ]; then
    [ "$file_managed" = "1" ] || die "CF_AGENT_WECHAT_BOOTSTRAP_MANAGED must be exactly 1 when present"
    BOOTSTRAP_MANAGED=1
  fi

  if [ -n "${AGENT_WECHAT_IMAGE+x}" ] && [ "$AGENT_WECHAT_IMAGE" != "$file_image" ]; then
    die "AGENT_WECHAT_IMAGE differs from the authoritative environment file: $ENV_FILE"
  fi
  if [ -n "${AGENT_WECHAT_BIND_IP+x}" ] && [ "$AGENT_WECHAT_BIND_IP" != "$file_bind_ip" ]; then
    die "AGENT_WECHAT_BIND_IP differs from the authoritative environment file: $ENV_FILE"
  fi
  if [ -n "${AGENT_WECHAT_PORT+x}" ] && [ "$AGENT_WECHAT_PORT" != "$file_port" ]; then
    die "AGENT_WECHAT_PORT differs from the authoritative environment file: $ENV_FILE"
  fi
  if [ -n "${AGENT_WECHAT_CONTAINER_NAME+x}" ] && \
    [ "$AGENT_WECHAT_CONTAINER_NAME" != "$file_container" ]; then
    die "AGENT_WECHAT_CONTAINER_NAME differs from the authoritative environment file: $ENV_FILE"
  fi

  if [ "$runtime_key_count" -eq 1 ]; then
    normalize_runtime_root "CF_AGENT_WECHAT_RUNTIME_ROOT in $ENV_FILE" "$file_runtime_root"
    canonical_runtime_root="$NORMALIZED_RUNTIME_ROOT"
  fi
  if [ "$legacy_runtime_key_count" -eq 1 ]; then
    normalize_runtime_root "CF_AGENT_WECHAT_STORAGE_ROOT in $ENV_FILE" "$file_legacy_runtime_root"
    canonical_legacy_runtime_root="$NORMALIZED_RUNTIME_ROOT"
  fi

  if [ "$runtime_key_count" -eq 1 ] && [ "$legacy_runtime_key_count" -eq 1 ] && [ "$canonical_runtime_root" != "$canonical_legacy_runtime_root" ]; then
    die "CF_AGENT_WECHAT_RUNTIME_ROOT and legacy CF_AGENT_WECHAT_STORAGE_ROOT differ in $ENV_FILE"
  fi

  if [ "$runtime_key_count" -eq 1 ]; then
    persisted_runtime_root="$canonical_runtime_root"
  elif [ "$legacy_runtime_key_count" -eq 1 ]; then
    persisted_runtime_root="$canonical_legacy_runtime_root"
    RUNTIME_ENV_NEEDS_MIGRATION=1
  else
    persisted_runtime_root="$CANONICAL_DEFAULT_RUNTIME_ROOT"
    RUNTIME_ENV_NEEDS_MIGRATION=1
  fi

  if [ "$RUNTIME_ROOT_EXPLICIT" -eq 1 ] && [ "$CF_RUNTIME_ROOT" != "$persisted_runtime_root" ]; then
    die "explicit runtime root differs from the persisted runtime root in $ENV_FILE"
  fi
  CF_RUNTIME_ROOT="$persisted_runtime_root"
  CF_AGENT_WECHAT_RUNTIME_ROOT="$CF_RUNTIME_ROOT"

  resolve_env_setting CF_RUNTIME_UID "$RUNTIME_UID" "${CF_RUNTIME_UID+x}" integer
  RUNTIME_UID="$PERSISTED_ENV_VALUE"
  resolve_env_setting CF_RUNTIME_GID "$RUNTIME_GID" "${CF_RUNTIME_GID+x}" integer
  RUNTIME_GID="$PERSISTED_ENV_VALUE"
  resolve_env_setting CF_RUNTIME_MODE "$RUNTIME_MODE" "${CF_RUNTIME_MODE+x}" mode
  RUNTIME_MODE="$PERSISTED_ENV_VALUE"
  resolve_env_setting CF_STORAGE_UID "$STORAGE_UID" "${CF_STORAGE_UID+x}" integer
  STORAGE_UID="$PERSISTED_ENV_VALUE"
  resolve_env_setting CF_STORAGE_GID "$STORAGE_GID" "${CF_STORAGE_GID+x}" integer
  STORAGE_GID="$PERSISTED_ENV_VALUE"
  resolve_env_setting CF_SECRETS_UID "$SECRETS_UID" "${CF_SECRETS_UID+x}" integer
  SECRETS_UID="$PERSISTED_ENV_VALUE"
  resolve_env_setting CF_SECRETS_GID "$SECRETS_GID" "${CF_SECRETS_GID+x}" integer
  SECRETS_GID="$PERSISTED_ENV_VALUE"

  IMAGE_REF="$file_image"
  BIND_IP="$file_bind_ip"
  HOST_PORT="$file_port"
  CONTAINER_NAME="$file_container"

  [[ "$IMAGE_REF" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]] || \
    die "AGENT_WECHAT_IMAGE must be pinned to an immutable sha256 digest"
  [ "$BIND_IP" = "127.0.0.1" ] || \
    die "AGENT_WECHAT_BIND_IP must be 127.0.0.1 for production"
  validate_positive_integer "AGENT_WECHAT_PORT" "$HOST_PORT"
  [ "$HOST_PORT" -le 65535 ] || die "AGENT_WECHAT_PORT must not exceed 65535"
  [[ "$CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || \
    die "AGENT_WECHAT_CONTAINER_NAME is invalid"

  API_URL="http://127.0.0.1:${HOST_PORT}"
  API_URL="${API_URL%/}"
}

create_auth_token() {
  local token_file="$1"
  local token_dir

  token_dir="$(dirname -- "$token_file")"
  run_for_owner "$SECRETS_UID" "$SECRETS_GID" /bin/sh -eu -c '
    target=$1
    directory=$2
    uid=$3
    gid=$4
    umask 077
    tmp=$(mktemp "$directory/.auth-token.XXXXXX")
    trap '\''rm -f -- "$tmp"'\'' 0 1 2 15
    openssl rand -hex 32 > "$tmp"
    grep -Eq "^[0-9a-f]{64}$" "$tmp"
    chown "$uid:$gid" "$tmp"
    chmod 600 "$tmp"
    if ! ln "$tmp" "$target" 2>/dev/null; then
      [ -f "$target" ] && [ ! -L "$target" ] || exit 1
    fi
    rm -f -- "$tmp"
    trap - 0 1 2 15
  ' bootstrap-token "$token_file" "$token_dir" "$SECRETS_UID" "$SECRETS_GID" || \
    die "could not create auth token: $token_file"
  TOKEN_CREATED=1
  log "generated a new auth token (content not displayed)"
}

validate_auth_token() {
  local token_file="$1"
  local metadata

  if [ -L "$token_file" ]; then
    die "auth token must not be a symbolic link: $token_file"
  fi
  [ -f "$token_file" ] || die "auth token path is not a regular file: $token_file"
  metadata="$($STAT_BIN -c '%u:%g:%a' -- "$token_file" 2>/dev/null)" || \
    die "could not inspect auth token metadata: $token_file"
  [ "$metadata" = "${SECRETS_UID}:${SECRETS_GID}:600" ] || \
    die "auth token must be owned by ${SECRETS_UID}:${SECRETS_GID} with mode 600; found ${metadata}"

  if [ -r "$token_file" ]; then
    awk 'END { exit(NR == 1 ? 0 : 1) }' "$token_file" && \
      grep -Eq '^[0-9a-f]{64}$' "$token_file" || \
      die "auth token must contain exactly one 64-character hexadecimal value"
  else
    run_as_root /bin/sh -c \
      'awk '\''END { exit(NR == 1 ? 0 : 1) }'\'' "$1" && grep -Eq '\''^[0-9a-f]{64}$'\'' "$1"' \
      bootstrap-token-check "$token_file" || \
      die "auth token must contain exactly one 64-character hexadecimal value"
  fi
}

run_docker_with_timeout() {
  local command_timeout="$1"
  shift
  local -a clean_environment=(
    -u AGENT_WECHAT_IMAGE
    -u AGENT_WECHAT_BIND_IP
    -u AGENT_WECHAT_PORT
    -u AGENT_WECHAT_CONTAINER_NAME
    -u CF_AGENT_WECHAT_RUNTIME_ROOT
    -u CF_AGENT_WECHAT_STORAGE_ROOT
    -u PROXY
    -u RUST_LOG
    -u COMPOSE_PROJECT_NAME
    -u DOCKER_HOST
    -u DOCKER_CONTEXT
    -u DOCKER_TLS_VERIFY
    -u DOCKER_CERT_PATH
  )
  local -a deployment_env=(
    "CF_AGENT_WECHAT_RUNTIME_ROOT=$CF_RUNTIME_ROOT"
    "AGENT_WECHAT_IMAGE=$IMAGE_REF"
    "AGENT_WECHAT_BIND_IP=$BIND_IP"
    "AGENT_WECHAT_PORT=$HOST_PORT"
    "AGENT_WECHAT_CONTAINER_NAME=$CONTAINER_NAME"
  )

  if [ "$DOCKER_USE_SUDO" -eq 1 ]; then
    run_with_hard_timeout "$command_timeout" \
      sudo -n -- env "${clean_environment[@]}" "${deployment_env[@]}" docker "$@"
  else
    run_with_hard_timeout "$command_timeout" \
      env "${clean_environment[@]}" "${deployment_env[@]}" docker "$@"
  fi
}

run_docker() {
  run_docker_with_timeout "$DOCKER_COMMAND_TIMEOUT" "$@"
}

compose_with_timeout() {
  local command_timeout="$1"
  shift

  run_docker_with_timeout "$command_timeout" compose \
    --env-file "$ENV_FILE" \
    --project-directory "$CF_AGENT_WECHAT_ROOT" \
    --project-name "$PROJECT_NAME" \
    -f "$COMPOSE_FILE" \
    "$@"
}

compose() {
  compose_with_timeout "$DOCKER_COMMAND_TIMEOUT" "$@"
}

raw_docker_with_timeout() {
  local command_timeout="$1"
  shift

  if [ "$DOCKER_USE_SUDO" -eq 1 ]; then
    run_with_hard_timeout "$command_timeout" sudo -n -- docker "$@"
  else
    run_with_hard_timeout "$command_timeout" docker "$@"
  fi
}

raw_docker() {
  raw_docker_with_timeout "$DOCKER_COMMAND_TIMEOUT" "$@"
}

select_docker_access() {
  local compose_version command_timeout context_name context_endpoint daemon_security
  local access_deadline

  run_with_hard_timeout "$DOCKER_COMMAND_TIMEOUT" docker --version >/dev/null 2>&1 || \
    die "Docker CLI is unavailable; install Docker Engine before running bootstrap"

  access_deadline=$((SECONDS + DOCKER_COMMAND_TIMEOUT))
  command_timeout="$(bounded_command_timeout "$DOCKER_COMMAND_TIMEOUT" "$access_deadline")" || \
    die "Docker access check exceeded ${DOCKER_COMMAND_TIMEOUT}s"
  if run_with_hard_timeout "$command_timeout" docker info >/dev/null 2>&1; then
    DOCKER_USE_SUDO=0
  elif [ "$CURRENT_UID" != "0" ] && command -v sudo >/dev/null 2>&1; then
    log "Docker socket requires sudo; authorize the foreground sudo prompt"
    if ! sudo -v; then
      die "sudo authorization failed; Docker access could not be established"
    fi
    access_deadline=$((SECONDS + DOCKER_COMMAND_TIMEOUT))
    command_timeout="$(bounded_command_timeout "$DOCKER_COMMAND_TIMEOUT" "$access_deadline")" || \
      die "Docker access check exceeded ${DOCKER_COMMAND_TIMEOUT}s"
    if ! run_with_hard_timeout "$command_timeout" sudo -n -- docker info >/dev/null 2>&1; then
      die "Docker daemon is unavailable through the authorized non-interactive sudo path"
    fi
    DOCKER_USE_SUDO=1
  else
    die "Docker daemon is unavailable or the current user has no approved access"
  fi
  context_name="$(raw_docker context show 2>/dev/null)" || \
    die "could not determine the effective Docker context"
  [ "$context_name" = "default" ] || \
    die "production bootstrap requires Docker context default; found: ${context_name:-unknown}"
  context_endpoint="$(raw_docker context inspect \
    --format '{{.Endpoints.docker.Host}}' default 2>/dev/null)" || \
    die "could not inspect the default Docker context endpoint"
  [ "$context_endpoint" = "unix:///var/run/docker.sock" ] || \
    die "production bootstrap requires the rootful local Docker socket unix:///var/run/docker.sock; found: ${context_endpoint:-unknown}"
  daemon_security="$(raw_docker info --format '{{json .SecurityOptions}}' 2>/dev/null)" || \
    die "could not inspect Docker daemon security options"
  case "${daemon_security,,}" in
    *rootless*)
      die "rootless Docker is not supported because docker.service boot recovery would not cover this deployment"
      ;;
  esac

  compose_version="$(raw_docker compose version --short 2>/dev/null || true)"
  [[ "$compose_version" =~ ^v?2\. ]] || \
    die "Docker Compose v2 is required; found: ${compose_version:-unavailable}"
  pass "Docker Engine and Compose v2 are available"
}

verify_docker_boot_recovery() {
  local system_state activity enablement

  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemd/systemctl is required to verify Docker boot-time recovery"
  fi
  system_state="$(systemctl is-system-running 2>/dev/null || true)"
  case "$system_state" in
    running|degraded) ;;
    *)
      die "systemd is not active; Docker boot-time recovery cannot be guaranteed (state: ${system_state:-unknown})"
      ;;
  esac

  activity="$(systemctl is-active docker.service 2>/dev/null || true)"
  case "$activity" in
    active)
      pass "docker.service is active on the verified local Docker socket"
      ;;
    *)
      die "docker.service is not active for the verified local Docker socket (state: ${activity:-unknown})"
      ;;
  esac

  enablement="$(systemctl is-enabled docker.service 2>/dev/null || true)"
  case "$enablement" in
    enabled)
      pass "docker.service is persistently enabled for boot recovery"
      ;;
    *)
      die "docker.service is not enabled for boot recovery (state: ${enablement:-unknown})"
      ;;
  esac
}

ensure_environment_file_access() {
  if [ "$CURRENT_UID" = "0" ] || [ -r "$ENV_FILE" ]; then
    return
  fi
  die "production environment file is not readable by the management user; use the same root identity for all management commands or apply an approved owner/group and 0600/0640 mode: $ENV_FILE"
}

ensure_network() {
  if run_docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    pass "Docker network exists: $NETWORK_NAME"
    return
  fi
  run_docker network create "$NETWORK_NAME" >/dev/null || \
    die "could not create Docker network: $NETWORK_NAME"
  pass "created Docker network: $NETWORK_NAME"
}

set_bounded_http_timeouts() {
  local deadline="$1"
  local remaining=$((deadline - SECONDS))

  [ "$remaining" -gt 0 ] || return 1
  BOUNDED_HTTP_TIMEOUT="$HTTP_TIMEOUT"
  if [ "$BOUNDED_HTTP_TIMEOUT" -gt "$remaining" ]; then
    BOUNDED_HTTP_TIMEOUT="$remaining"
  fi
  BOUNDED_CONNECT_TIMEOUT="$HTTP_CONNECT_TIMEOUT"
  if [ "$BOUNDED_CONNECT_TIMEOUT" -gt "$BOUNDED_HTTP_TIMEOUT" ]; then
    BOUNDED_CONNECT_TIMEOUT="$BOUNDED_HTTP_TIMEOUT"
  fi
}

sleep_until_deadline() {
  local deadline="$1"
  local remaining=$((deadline - SECONDS))
  local delay="$POLL_INTERVAL"

  [ "$remaining" -gt 0 ] || return 1
  if [ "$delay" -gt "$remaining" ]; then
    delay="$remaining"
  fi
  sleep "$delay"
}

wait_for_container() {
  local deadline=$((SECONDS + BOOTSTRAP_TIMEOUT))
  local command_timeout
  local container_id=""
  local state=""
  local health=""

  while [ "$SECONDS" -lt "$deadline" ]; do
    command_timeout="$(bounded_command_timeout "$DOCKER_COMMAND_TIMEOUT" "$deadline")" || break
    container_id="$(compose_with_timeout "$command_timeout" ps --all --quiet \
      "$SERVICE_NAME" 2>/dev/null || true)"
    if [ -n "$container_id" ]; then
      command_timeout="$(bounded_command_timeout "$DOCKER_COMMAND_TIMEOUT" "$deadline")" || break
      state="$(run_docker_with_timeout "$command_timeout" inspect --format \
        '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
      command_timeout="$(bounded_command_timeout "$DOCKER_COMMAND_TIMEOUT" "$deadline")" || break
      health="$(run_docker_with_timeout "$command_timeout" inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        "$container_id" 2>/dev/null || true)"
      if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
        printf '%s' "$container_id"
        return 0
      fi
      case "$state" in
        exited|dead)
          warn "container entered terminal state: $state"
          return 1
          ;;
      esac
    fi
    sleep_until_deadline "$deadline" || break
  done

  warn "timed out waiting for container (state=${state:-missing}, health=${health:-missing})"
  return 1
}

verify_container_identity() {
  local container_id="$1"
  local actual_image actual_name expected_name

  actual_image="$(run_docker inspect --format '{{.Config.Image}}' \
    "$container_id" 2>/dev/null || true)"
  [ "$actual_image" = "$IMAGE_REF" ] || \
    die "container image does not match AGENT_WECHAT_IMAGE (expected: $IMAGE_REF, found: ${actual_image:-missing})"

  expected_name="/${CONTAINER_NAME}"
  actual_name="$(run_docker inspect --format '{{.Name}}' \
    "$container_id" 2>/dev/null || true)"
  [ "$actual_name" = "$expected_name" ] || \
    die "container name does not match AGENT_WECHAT_CONTAINER_NAME (expected: $expected_name, found: ${actual_name:-missing})"
}

verify_mount() {
  local container_id="$1"
  local destination="$2"
  local expected_source="$3"
  local expected_rw="$4"
  local actual_mount actual_source actual_rw expected_access actual_access

  actual_mount="$(run_docker inspect --format \
    "{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{.Source}}|{{.RW}}{{end}}{{end}}" \
    "$container_id" 2>/dev/null || true)"
  actual_source="${actual_mount%|*}"
  actual_rw="${actual_mount##*|}"
  [ "$actual_source" = "$expected_source" ] || \
    die "container mount $destination is not persistent at $expected_source (found: ${actual_source:-missing})"

  if [ "$expected_rw" = "true" ]; then
    expected_access="read-write"
  else
    expected_access="read-only"
  fi
  if [ "$actual_rw" = "true" ]; then
    actual_access="read-write"
  elif [ "$actual_rw" = "false" ]; then
    actual_access="read-only"
  else
    actual_access="missing"
  fi
  [ "$actual_rw" = "$expected_rw" ] || \
    die "container mount $destination must be $expected_access (found: $actual_access)"
}

verify_runtime_networking() {
  local container_id="$1"
  local network_attachment network_alias port_binding expected_binding

  network_attachment="$(run_docker inspect --format \
    "{{if index .NetworkSettings.Networks \"${NETWORK_NAME}\"}}attached{{end}}" \
    "$container_id" 2>/dev/null || true)"
  [ "$network_attachment" = "attached" ] || \
    die "container is not attached to required Docker network: $NETWORK_NAME"

  network_alias="$(run_docker inspect --format \
    "{{range (index .NetworkSettings.Networks \"${NETWORK_NAME}\").Aliases}}{{if eq . \"${NETWORK_ALIAS}\"}}present{{end}}{{end}}" \
    "$container_id" 2>/dev/null || true)"
  [ "$network_alias" = "present" ] || \
    die "container network $NETWORK_NAME is missing required alias: $NETWORK_ALIAS"

  port_binding="$(run_docker inspect --format \
    '{{with (index .NetworkSettings.Ports "6174/tcp")}}{{(index . 0).HostIp}}:{{(index . 0).HostPort}}{{end}}' \
    "$container_id" 2>/dev/null || true)"
  expected_binding="${BIND_IP}:${HOST_PORT}"
  [ "$port_binding" = "$expected_binding" ] || \
    die "container port 6174/tcp must bind to $expected_binding (found: ${port_binding:-missing})"
}

wait_for_health_api() {
  local deadline=$((SECONDS + BOOTSTRAP_TIMEOUT))

  while [ "$SECONDS" -lt "$deadline" ]; do
    set_bounded_http_timeouts "$deadline" || break
    if curl --disable --noproxy '*' --fail --silent --show-error \
      --connect-timeout "$BOUNDED_CONNECT_TIMEOUT" \
      --max-time "$BOUNDED_HTTP_TIMEOUT" \
      "${API_URL}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep_until_deadline "$deadline" || break
  done
  return 1
}

authenticated_status_request() {
  local token_file="$1"
  local connect_timeout="$2"
  local request_timeout="$3"
  local request_status
  local token

  if [ -r "$token_file" ]; then
    token="$(/bin/cat -- "$token_file")"
    if printf 'Authorization: Bearer %s\nX-Session-Id: default\n' "$token" | curl \
      --disable \
      --noproxy '*' \
      --request GET \
      --fail \
      --silent \
      --show-error \
      --connect-timeout "$connect_timeout" \
      --max-time "$request_timeout" \
      --header @- \
      "${API_URL}/api/status/auth"; then
      request_status=0
    else
      request_status=$?
    fi
    token=""
    return "$request_status"
  else
    run_as_root /bin/bash -c '
      set +x
      token_file=$1
      api_url=$2
      connect_timeout=$3
      request_timeout=$4
      token=$(/bin/cat -- "$token_file")
      if printf "Authorization: Bearer %s\nX-Session-Id: default\n" "$token" | curl \
        --disable --noproxy "*" --request GET --fail --silent --show-error \
        --connect-timeout "$connect_timeout" --max-time "$request_timeout" \
        --header @- "$api_url/api/status/auth"; then
        request_status=0
      else
        request_status=$?
      fi
      token=
      exit "$request_status"
    ' bootstrap-auth "$token_file" "$API_URL" "$connect_timeout" "$request_timeout"
  fi
}

wait_for_authenticated_api() {
  local token_file="$1"
  local deadline=$((SECONDS + BOOTSTRAP_TIMEOUT))
  local response=""
  local auth_status=""
  local last_status="unavailable"

  while [ "$SECONDS" -lt "$deadline" ]; do
    set_bounded_http_timeouts "$deadline" || break
    if response="$(authenticated_status_request "$token_file" "$BOUNDED_CONNECT_TIMEOUT" "$BOUNDED_HTTP_TIMEOUT" 2>/dev/null)"; then
      if auth_status="$(printf '%s' "$response" | "$PYTHON_BIN" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(1)
status = payload.get("status") if isinstance(payload, dict) else None
if not isinstance(status, str) or not status or any(ord(c) < 32 or ord(c) == 127 for c in status):
    raise SystemExit(1)
sys.stdout.write(status)
')"; then
        last_status="$auth_status"
        case "$auth_status" in
          logged_in|logged_out|qr_pending|waiting_for_qr|waiting_for_scan)
            printf '%s' "$auth_status"
            return 0
            ;;
        esac
      else
        last_status="invalid_response"
      fi
    fi
    sleep_until_deadline "$deadline" || break
  done
  printf '%s' "$last_status"
  return 1
}

main() {
  local data_existed=0
  local home_existed=0
  local alias_runtime_root
  local token_file
  local container_id
  local restart_policy
  local auth_status
  local compose_status
  local command_name docker_override

  for command_name in awk cp curl env grep id install ln mktemp mv openssl sleep; do
    require_command "$command_name"
  done
  require_command "$REALPATH_BIN"
  require_command "$TIMEOUT_BIN"
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1 || \
    ! "$PYTHON_BIN" -c 'import json' >/dev/null 2>&1; then
    if command -v python >/dev/null 2>&1 && python -c 'import json' >/dev/null 2>&1; then
      PYTHON_BIN=python
    else
      die "Python 3 is required to validate the authenticated API response"
    fi
  fi
  command -v "$STAT_BIN" >/dev/null 2>&1 || die "stat command is unavailable: $STAT_BIN"
  if [ "${CF_AGENT_WECHAT_COMPOSE_FILE+x}" = x ]; then
    die "CF_AGENT_WECHAT_COMPOSE_FILE cannot override the production Compose file"
  fi
  if [ "${CF_AGENT_WECHAT_ENV_FILE+x}" = x ]; then
    die "CF_AGENT_WECHAT_ENV_FILE cannot override the production environment file"
  fi
  if [ "${CF_AGENT_WECHAT_API_URL+x}" = x ]; then
    die "CF_AGENT_WECHAT_API_URL cannot override the loopback verification endpoint"
  fi

  for docker_override in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
    if [[ -v $docker_override ]]; then
      die "$docker_override cannot override the production rootful local Docker daemon"
    fi
  done

  validate_absolute_path "CF_AGENT_WECHAT_ROOT" "$CF_AGENT_WECHAT_ROOT"
  validate_absolute_path "CF_GATEWAY_ROOT" "$CF_GATEWAY_ROOT"
  normalize_runtime_root "default runtime root" "$DEFAULT_RUNTIME_ROOT"
  CANONICAL_DEFAULT_RUNTIME_ROOT="$NORMALIZED_RUNTIME_ROOT"
  normalize_runtime_root "CF_RUNTIME_ROOT" "$CF_RUNTIME_ROOT"
  CF_RUNTIME_ROOT="$NORMALIZED_RUNTIME_ROOT"
  if [ "$CANONICAL_DEFAULT_RUNTIME_ROOT" != "$DEFAULT_RUNTIME_ROOT" ] &&
    [ "$CF_RUNTIME_ROOT" = "$CANONICAL_DEFAULT_RUNTIME_ROOT" ]; then
    die "default runtime root must not resolve through a symbolic link: $DEFAULT_RUNTIME_ROOT -> $CANONICAL_DEFAULT_RUNTIME_ROOT"
  fi
  if [ "$CF_RUNTIME_ROOT_WAS_SET" -eq 1 ] && [ "$CF_AGENT_WECHAT_RUNTIME_ROOT_WAS_SET" -eq 1 ]; then
    normalize_runtime_root "CF_AGENT_WECHAT_RUNTIME_ROOT" "$CF_AGENT_WECHAT_RUNTIME_ROOT_INPUT"
    alias_runtime_root="$NORMALIZED_RUNTIME_ROOT"
    [ "$CF_RUNTIME_ROOT" = "$alias_runtime_root" ] || die "CF_RUNTIME_ROOT and CF_AGENT_WECHAT_RUNTIME_ROOT must identify the same directory"
  fi
  CF_AGENT_WECHAT_RUNTIME_ROOT="$CF_RUNTIME_ROOT"

  validate_absolute_path "compose file" "$COMPOSE_FILE"
  validate_absolute_path "environment file" "$ENV_FILE"
  validate_integer "CF_RUNTIME_UID" "$RUNTIME_UID"
  validate_integer "CF_RUNTIME_GID" "$RUNTIME_GID"
  validate_integer "CF_STORAGE_UID" "$STORAGE_UID"
  validate_integer "CF_STORAGE_GID" "$STORAGE_GID"
  validate_integer "CF_SECRETS_UID" "$SECRETS_UID"
  validate_integer "CF_SECRETS_GID" "$SECRETS_GID"
  validate_mode "CF_RUNTIME_MODE" "$RUNTIME_MODE"
  validate_positive_integer "CF_BOOTSTRAP_TIMEOUT" "$BOOTSTRAP_TIMEOUT"
  validate_positive_integer "CF_BOOTSTRAP_POLL_INTERVAL" "$POLL_INTERVAL"
  validate_positive_integer "CF_BOOTSTRAP_HTTP_CONNECT_TIMEOUT" "$HTTP_CONNECT_TIMEOUT"
  validate_positive_integer "CF_BOOTSTRAP_HTTP_TIMEOUT" "$HTTP_TIMEOUT"
  validate_positive_integer "CF_BOOTSTRAP_DOCKER_TIMEOUT" "$DOCKER_COMMAND_TIMEOUT"
  validate_positive_integer "CF_BOOTSTRAP_COMPOSE_UP_TIMEOUT" "$COMPOSE_UP_TIMEOUT"

  if [ "${CF_AGENT_WECHAT_NETWORK+x}" = x ] && [ "$CF_AGENT_WECHAT_NETWORK" != "$NETWORK_NAME" ]; then
    die "CF_AGENT_WECHAT_NETWORK cannot override the production Compose network $NETWORK_NAME"
  fi
  if [ "${CF_AGENT_WECHAT_SERVICE_NAME+x}" = x ] && [ "$CF_AGENT_WECHAT_SERVICE_NAME" != "$SERVICE_NAME" ]; then
    die "CF_AGENT_WECHAT_SERVICE_NAME cannot override the production Compose service $SERVICE_NAME"
  fi

  [ -d "$CF_AGENT_WECHAT_ROOT" ] && [ ! -L "$CF_AGENT_WECHAT_ROOT" ] || \
    die "CF_AGENT_WECHAT_ROOT must be an existing non-symlink directory"
  [ -f "$COMPOSE_FILE" ] && [ ! -L "$COMPOSE_FILE" ] || \
    die "production compose file is missing, not regular, or a symlink: $COMPOSE_FILE"

  validate_application_root
  validate_production_compose_file
  validate_environment_parent
  if ! path_is_present "$ENV_FILE"; then
    validate_management_permission_contract
    validate_fresh_runtime_state
  fi
  if path_is_present "$CF_GATEWAY_ROOT"; then
    [ -d "$CF_GATEWAY_ROOT" ] && [ ! -L "$CF_GATEWAY_ROOT" ] || \
      die "CF_GATEWAY_ROOT must be a non-symlink directory when present: $CF_GATEWAY_ROOT"
    pass "Gateway root validated: $CF_GATEWAY_ROOT"
  else
    warn "Gateway root is not present; the shared network will still be prepared: $CF_GATEWAY_ROOT"
  fi

  # After Docker authority is verified, a fresh deployment persists a controlled,
  # bootstrap-managed staged environment, runtime, and token that retries can resume.
  # The initialized marker is written only after container and API verification.
  select_docker_access
  verify_docker_boot_recovery

  if ! path_is_present "$ENV_FILE"; then
    IMAGE_REF="${AGENT_WECHAT_IMAGE:-}"
    BIND_IP="${AGENT_WECHAT_BIND_IP:-127.0.0.1}"
    HOST_PORT="${AGENT_WECHAT_PORT:-6174}"
    CONTAINER_NAME="${AGENT_WECHAT_CONTAINER_NAME:-cf-agent-wechat}"
    [[ "$IMAGE_REF" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]] || \
      die "docker/.env is absent; set AGENT_WECHAT_IMAGE to an approved digest-pinned image"
    [ "$BIND_IP" = "127.0.0.1" ] || \
      die "AGENT_WECHAT_BIND_IP must be 127.0.0.1 for production"
    validate_positive_integer "AGENT_WECHAT_PORT" "$HOST_PORT"
    [ "$HOST_PORT" -le 65535 ] || die "AGENT_WECHAT_PORT must not exceed 65535"
    [[ "$CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || \
      die "AGENT_WECHAT_CONTAINER_NAME is invalid"
    create_environment_file "$IMAGE_REF" "$BIND_IP" "$HOST_PORT" "$CONTAINER_NAME" \
      "$CF_RUNTIME_ROOT"
  fi
  validate_environment_file
  ensure_environment_file_access
  validate_management_permission_contract

  if path_is_present "${CF_RUNTIME_ROOT}/data"; then
    data_existed=1
    [ -d "${CF_RUNTIME_ROOT}/data" ] && [ ! -L "${CF_RUNTIME_ROOT}/data" ] || \
      die "existing agent data path must be a non-symlink directory"
  fi
  if path_is_present "${CF_RUNTIME_ROOT}/wechat-home"; then
    home_existed=1
    [ -d "${CF_RUNTIME_ROOT}/wechat-home" ] && [ ! -L "${CF_RUNTIME_ROOT}/wechat-home" ] || \
      die "existing WeChat home path must be a non-symlink directory"
  fi
  token_file="${CF_RUNTIME_ROOT}/secrets/auth-token"

  if [ "$BOOTSTRAP_INITIALIZED" -eq 1 ] && { [ "$data_existed" -ne 1 ] || [ "$home_existed" -ne 1 ] || ! path_is_present "$token_file"; }; then
    die "bootstrap is marked initialized but persistent runtime is incomplete; restore data, wechat-home, and the original auth token together from backup, then verify the persistent mount"
  fi

  if ! path_is_present "$token_file" && \
    { [ "$data_existed" -eq 1 ] || [ "$home_existed" -eq 1 ]; }; then
    die "existing runtime has no auth token; restore the original token instead of generating a replacement"
  fi

  if [ "$BOOTSTRAP_INITIALIZED" -eq 0 ] && [ "$BOOTSTRAP_MANAGED" -eq 0 ] && { [ "$data_existed" -ne 1 ] || [ "$home_existed" -ne 1 ] || ! path_is_present "$token_file"; }; then
    die "pre-existing environment has no bootstrap provenance and its runtime is incomplete; verify the persistent mount or restore data, wechat-home, and the original token together before migration"
  fi

  if [ "$BOOTSTRAP_MANAGED" -eq 1 ]; then
    ensure_runtime_settings_persisted
    if [ "$RUNTIME_ENV_NEEDS_MIGRATION" -eq 1 ]; then
      ensure_env_assignment CF_AGENT_WECHAT_RUNTIME_ROOT "$CF_RUNTIME_ROOT"
    fi
  fi

  ensure_directory "runtime root" "$CF_RUNTIME_ROOT" "$STORAGE_UID" "$STORAGE_GID" 755
  ensure_directory "secrets directory" "${CF_RUNTIME_ROOT}/secrets" \
    "$SECRETS_UID" "$SECRETS_GID" 700

  if ! path_is_present "$token_file"; then
    create_auth_token "$token_file"
  fi
  validate_auth_token "$token_file"

  ensure_directory "agent data directory" "${CF_RUNTIME_ROOT}/data" \
    "$RUNTIME_UID" "$RUNTIME_GID" "$RUNTIME_MODE"
  ensure_directory "WeChat home directory" "${CF_RUNTIME_ROOT}/wechat-home" \
    "$RUNTIME_UID" "$RUNTIME_GID" "$RUNTIME_MODE"

  if [ "$BOOTSTRAP_MANAGED" -eq 0 ]; then
    ensure_runtime_settings_persisted
    if [ "$RUNTIME_ENV_NEEDS_MIGRATION" -eq 1 ]; then
      ensure_env_assignment CF_AGENT_WECHAT_RUNTIME_ROOT "$CF_RUNTIME_ROOT"
    fi
  fi

  CF_AGENT_WECHAT_ROOT="$("$REALPATH_BIN" -e -- "$CF_AGENT_WECHAT_ROOT")"
  CF_RUNTIME_ROOT="$("$REALPATH_BIN" -e -- "$CF_RUNTIME_ROOT")"
  CF_AGENT_WECHAT_RUNTIME_ROOT="$CF_RUNTIME_ROOT"
  token_file="${CF_RUNTIME_ROOT}/secrets/auth-token"

  compose config --quiet || die "production Compose validation failed"
  if ! compose config --services | grep -Fxq "$SERVICE_NAME"; then
    die "production Compose does not define required service: $SERVICE_NAME"
  fi
  pass "production Compose configuration is valid"

  ensure_network
  log "starting production service"
  if compose_with_timeout "$COMPOSE_UP_TIMEOUT" up -d "$SERVICE_NAME"; then
    :
  else
    compose_status=$?
    case "$compose_status" in
      124|137)
        die "Docker Compose up exceeded CF_BOOTSTRAP_COMPOSE_UP_TIMEOUT=${COMPOSE_UP_TIMEOUT}s"
        ;;
      *)
        die "Docker Compose failed to start $SERVICE_NAME"
        ;;
    esac
  fi

  container_id="$(wait_for_container)" || \
    die "container did not become running and healthy within ${BOOTSTRAP_TIMEOUT}s"
  pass "container is running and Docker health is healthy"
  verify_container_identity "$container_id"
  pass "container image and name match the production environment"


  restart_policy="$(run_docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' \
    "$container_id" 2>/dev/null || true)"
  [ "$restart_policy" = "unless-stopped" ] || \
    die "container restart policy must be unless-stopped; found: ${restart_policy:-missing}"
  pass "container restart policy is unless-stopped"

  verify_mount "$container_id" /data "${CF_RUNTIME_ROOT}/data" true
  verify_mount "$container_id" /home/wechat "${CF_RUNTIME_ROOT}/wechat-home" true
  verify_mount "$container_id" /data/auth-token "$token_file" false
  verify_runtime_networking "$container_id"
  pass "persistent mounts, network attachment, and loopback port binding are correct"

  wait_for_health_api || die "health API did not become ready within ${BOOTSTRAP_TIMEOUT}s: ${API_URL}/health"
  pass "health API is reachable"

  if ! auth_status="$(wait_for_authenticated_api "$token_file")"; then
    die "authenticated status API did not reach a supported ready state within ${BOOTSTRAP_TIMEOUT}s (last status: ${auth_status:-unavailable})"
  fi
  case "$auth_status" in
    logged_in)
      pass "authenticated API is ready (auth status: logged_in)"
      ;;
    logged_out|qr_pending|waiting_for_qr|waiting_for_scan)
      pass "authenticated API is ready (auth status: $auth_status)"
      warn "WeChat authentication is $auth_status; run scripts/login.sh to complete QR login"
      ;;
    *)
      die "internal error: unsupported authenticated ready status: $auth_status"
      ;;
  esac

  if [ "$BOOTSTRAP_MANAGED" -eq 0 ]; then
    ensure_env_assignment CF_AGENT_WECHAT_BOOTSTRAP_MANAGED 1
    BOOTSTRAP_MANAGED=1
  fi
  if [ "$BOOTSTRAP_INITIALIZED" -eq 0 ]; then
    ensure_env_assignment CF_AGENT_WECHAT_BOOTSTRAPPED 1
    BOOTSTRAP_INITIALIZED=1
  fi

  pass "CF_agent-wechat bootstrap completed"
  log "application root: $CF_AGENT_WECHAT_ROOT"
  log "gateway root: $CF_GATEWAY_ROOT"
  log "persistent runtime root: $CF_RUNTIME_ROOT"
  if [ "$ENV_CREATED" -eq 1 ]; then
    log "environment file was initialized"
  fi
  if [ "$TOKEN_CREATED" -eq 1 ]; then
    log "auth token was initialized and will be reused on later runs"
  fi
}

main "$@"
