#!/bin/bash -p
set -Eeuo pipefail

set +x
set +a
_bootstrap_testing_value="${CF_BOOTSTRAP_TESTING:-0}"
case "$_bootstrap_testing_value" in
  0)
    _CF_AGENT_WECHAT_BOOTSTRAP_TESTING=0
    ;;
  1)
    if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${CF_REQUIRE_BOOTSTRAP_DEPLOYMENT_TEST:-}" != 1 ]; then
      printf '%s\n' '[FAIL] CF_BOOTSTRAP_TESTING=1 requires the isolated GitHub Actions deployment test gate.' >&2
      exit 1
    fi
    _CF_AGENT_WECHAT_BOOTSTRAP_TESTING=1
    ;;
  *)
    printf '%s\n' '[FAIL] CF_BOOTSTRAP_TESTING must be 0 or 1.' >&2
    exit 1
    ;;
esac
readonly _CF_AGENT_WECHAT_BOOTSTRAP_TESTING
unset _bootstrap_testing_value CF_BOOTSTRAP_TESTING GITHUB_ACTIONS CF_REQUIRE_BOOTSTRAP_DEPLOYMENT_TEST

unset _CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES \
  _bootstrap_early_override_names
_CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES=""
_bootstrap_early_override_names=(
  DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
  DOCKER_API_VERSION DOCKER_CONFIG BUILDX_BUILDER
  COMPOSE_FILE COMPOSE_PROFILES COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR
  COMPOSE_PROJECT_DIR COMPOSE_PARALLEL_LIMIT COMPOSE_IGNORE_ORPHANS
  COMPOSE_REMOVE_ORPHANS COMPOSE_STATUS_STDOUT COMPOSE_ANSI
  COMPOSE_PROGRESS COMPOSE_EXPERIMENTAL COMPOSE_MENU
  HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  http_proxy https_proxy all_proxy no_proxy
  AUTH_TOKEN CF_AGENT_WECHAT_TOKEN CF_AGENT_WECHAT_TOKEN_FILE
  CF_GATEWAY_API_TOKEN CF_AGENT_GATEWAY_ADMIN_TOKEN HERMES_API_KEY
  API_URL WS_URL TOKEN_FILE SESSION_ID CONTAINER_NAME PYTHON_BIN
  REQUIREMENTS_FILE VENV_DIR CF_AGENT_WECHAT_VENV AGENT_WECHAT_IMAGE
  AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT AGENT_WECHAT_CONTAINER_NAME
  COMPOSE_PROJECT_NAME PROXY RUST_LOG CF_AGENT_WECHAT_ROOT
  CF_AGENT_WECHAT_COMPOSE_FILE CF_AGENT_WECHAT_ENV_FILE
  CF_AGENT_WECHAT_STORAGE_ROOT CF_AGENT_WECHAT_RUNTIME_ROOT
  CF_AGENT_WECHAT_ARCHIVE_ROOT CF_AGENT_WECHAT_RUNTIME_UID
  CF_AGENT_WECHAT_RUNTIME_GID CF_AGENT_WECHAT_RUNTIME_MODE
  CF_AGENT_WECHAT_MANAGEMENT_GID CF_AGENT_GATEWAY_COMPOSE_FILE
  CF_AGENT_GATEWAY_PROJECT_DIR CF_AGENT_GATEWAY_ENV_FILE
  CF_AGENT_GATEWAY_HEARTBEAT_COMMAND
  CF_AGENT_WECHAT_CURL_BIN CF_AGENT_WECHAT_DOCKER_BIN
  CF_AGENT_WECHAT_SYSTEMCTL_BIN CF_AGENT_WECHAT_DOCKER_SOCKET_PATH
  CF_AGENT_WECHAT_DF_BIN CF_AGENT_WECHAT_TESTING
  CF_BOOTSTRAP_OS_RELEASE_FILE CF_BOOTSTRAP_DOCKER_BIN
  CF_BOOTSTRAP_SYSTEMCTL_BIN CF_BOOTSTRAP_DOCKER_SOCKET_PATH
  CF_BOOTSTRAP_DOCKER_TIMEOUT CF_BOOTSTRAP_COMPOSE_TIMEOUT
  CF_AGENT_WECHAT_TEST_ROOT
  CF_BOOTSTRAP_TEST_GATEWAY_VERIFIER_REPLACEMENT
  CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT TMPDIR
)
if [ "$_CF_AGENT_WECHAT_BOOTSTRAP_TESTING" != "1" ]; then
  for _bootstrap_early_override_name in \
    "${_bootstrap_early_override_names[@]}"; do
    if [[ -v $_bootstrap_early_override_name ]]; then
      _CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES+="${_CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES:+,}${_bootstrap_early_override_name}"
    fi
    unset "$_bootstrap_early_override_name"
  done
else
  for _bootstrap_early_override_name in \
    "${_bootstrap_early_override_names[@]}"; do
    export -n "${_bootstrap_early_override_name?}" 2>/dev/null || :
    case "$_bootstrap_early_override_name" in
      AUTH_TOKEN|CF_AGENT_WECHAT_TOKEN|CF_GATEWAY_API_TOKEN|CF_AGENT_GATEWAY_ADMIN_TOKEN|HERMES_API_KEY|PROXY|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|NO_PROXY|no_proxy)
        unset "$_bootstrap_early_override_name"
        ;;
    esac
  done
fi
readonly _CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES
unset _bootstrap_early_override_name _bootstrap_early_override_names

if [ "$_CF_AGENT_WECHAT_BOOTSTRAP_TESTING" != "1" ]; then
  case "$-" in
    *p*) ;;
    *) printf '%s\n' '[FAIL] Bootstrap requires direct protected-mode script execution.' >&2; exit 1 ;;
  esac
fi
unset BASH_ENV ENV CDPATH
LANG=C.UTF-8
LC_ALL=C.UTF-8
export LANG LC_ALL
umask 077
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_AGENT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

AGENT_ROOT="${CF_AGENT_WECHAT_ROOT:-$DEFAULT_AGENT_ROOT}"
AGENT_COMPOSE_FILE="${CF_AGENT_WECHAT_COMPOSE_FILE:-${AGENT_ROOT}/docker/compose.cfserver.yaml}"
AGENT_ENV_FILE="${CF_AGENT_WECHAT_ENV_FILE:-${AGENT_ROOT}/docker/.env}"
STORAGE_ROOT="${CF_AGENT_WECHAT_STORAGE_ROOT:-/srv/storage/cf-agent-wechat}"
RUNTIME_ROOT="${CF_AGENT_WECHAT_RUNTIME_ROOT:-${STORAGE_ROOT}/runtime}"
ARCHIVE_ROOT="${CF_AGENT_WECHAT_ARCHIVE_ROOT:-${STORAGE_ROOT}/session-archive}"
SECRETS_ROOT="${STORAGE_ROOT}/secrets"
TOKEN_FILE="${CF_AGENT_WECHAT_TOKEN_FILE:-${SECRETS_ROOT}/auth-token}"
LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"
LEGACY_HOME_ROOT="${STORAGE_ROOT}/wechat-home"

GATEWAY_PROJECT_DIR="${CF_AGENT_GATEWAY_PROJECT_DIR:-/opt/cf-agent-gateway}"
GATEWAY_COMPOSE_FILE="${CF_AGENT_GATEWAY_COMPOSE_FILE:-${GATEWAY_PROJECT_DIR}/docker-compose.prod.yml}"
GATEWAY_ENV_FILE="${CF_AGENT_GATEWAY_ENV_FILE:-${GATEWAY_PROJECT_DIR}/.env}"
GATEWAY_HEARTBEAT_COMMAND="${GATEWAY_PROJECT_DIR}/deploy/check-wechat-worker-heartbeat"
GATEWAY_RELEASE_GATE_COMMAND="${GATEWAY_PROJECT_DIR}/deploy/wechat-runtime-release-gate"
GATEWAY_CONTRACT_FILE="${GATEWAY_PROJECT_DIR}/deploy/wechat-runtime-contract.json"
GATEWAY_CONTRACT_VERIFIER="${SCRIPT_DIR}/verify_gateway_contract.py"
MANAGEMENT_ENV_PARSER="${SCRIPT_DIR}/parse_management_env.py"
MANAGEMENT_SOURCE_SECRET_VERIFIER="${SCRIPT_DIR}/verify_management_source_secrets.py"
GATEWAY_PROJECT="cf-agent-gateway"
GATEWAY_HEARTBEAT_MAX_AGE=30
GATEWAY_PRODUCER_REPOSITORY="Tangbohu09527/CF_agent-gateway"
GATEWAY_COMPATIBLE_COMMIT=""
GATEWAY_CHECKER_SHA256=""
GATEWAY_RELEASE_GATE_SHA256=""
IFS= read -r -d '' GATEWAY_VERIFIER_SNAPSHOT_LOADER <<'PYTHON' || :
import hashlib
import hmac
import os
import stat
import sys

MAX_SOURCE_BYTES = 1024 * 1024
FAILURE = "Gateway verifier snapshot validation failed."


def fail():
    print(FAILURE, file=sys.stderr)
    raise SystemExit(126)


def metadata_signature(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


try:
    mode, path, expected_digest, approved_uid_raw = sys.argv[1:5]
    script_arguments = sys.argv[5:]
    approved_uid = int(approved_uid_raw)
    if (
        mode not in {"digest", "execute"}
        or not os.path.isabs(path)
        or approved_uid < 0
        or not hasattr(os, "O_NOFOLLOW")
    ):
        fail()

    before = os.lstat(path)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_IMODE(before.st_mode) != 0o755
        or before.st_uid not in {0, approved_uid}
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > MAX_SOURCE_BYTES
    ):
        fail()

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if metadata_signature(opened) != metadata_signature(before):
            fail()
        chunks = []
        total = 0
        while True:
            chunk = os.read(
                descriptor,
                min(65536, MAX_SOURCE_BYTES + 1 - total),
            )
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_SOURCE_BYTES:
                fail()
            chunks.append(chunk)
        final = os.fstat(descriptor)
    finally:
        os.close(descriptor)

    visible = os.lstat(path)
    if (
        metadata_signature(final) != metadata_signature(opened)
        or metadata_signature(visible) != metadata_signature(before)
    ):
        fail()
    source = b"".join(chunks)
    digest = hashlib.sha256(source).hexdigest()

    if mode == "digest":
        if expected_digest != "-":
            fail()
        sys.stdout.write(digest)
        raise SystemExit(0)
    if (
        len(expected_digest) != 64
        or any(character not in "0123456789abcdef" for character in expected_digest)
        or not hmac.compare_digest(digest, expected_digest)
    ):
        fail()
    code = compile(source, path, "exec")
except (OSError, OverflowError, SyntaxError, TypeError, ValueError):
    fail()

sys.argv = [path, *script_arguments]
namespace = {
    "__name__": "__main__",
    "__file__": path,
    "__package__": None,
    "__cached__": None,
    "__spec__": None,
}
exec(code, namespace, namespace)
PYTHON
readonly GATEWAY_VERIFIER_SNAPSHOT_LOADER

RUNTIME_UID="${CF_AGENT_WECHAT_RUNTIME_UID:-1000}"
RUNTIME_GID="${CF_AGENT_WECHAT_RUNTIME_GID:-1000}"
RUNTIME_MODE="${CF_AGENT_WECHAT_RUNTIME_MODE:-700}"
TESTING="$_CF_AGENT_WECHAT_BOOTSTRAP_TESTING"
TEST_ASSET_ROOT="${CF_AGENT_WECHAT_TEST_ROOT:-}"
DOCKER_TIMEOUT=30
COMPOSE_TIMEOUT=120
MAX_TEST_DOCKER_TIMEOUT=120
MAX_TEST_COMPOSE_TIMEOUT=300
MAX_SIGNED_INTEGER="9223372036854775807"
MAX_UID_GID="4294967294"
readonly MAX_SIGNED_INTEGER MAX_UID_GID
if [ "$TESTING" = "1" ]; then
  DOCKER_TIMEOUT="${CF_BOOTSTRAP_DOCKER_TIMEOUT:-$DOCKER_TIMEOUT}"
  COMPOSE_TIMEOUT="${CF_BOOTSTRAP_COMPOSE_TIMEOUT:-$COMPOSE_TIMEOUT}"
fi
TIMEOUT_GRACE=2

NETWORK_NAME="cf-internal"
NETWORK_ALIAS="cf-agent-wechat"
AGENT_SERVICE="agent-wechat"
GATEWAY_SERVICE="worker"
AGENT_PROJECT="cf-agent-wechat"

OS_RELEASE_FILE="${CF_BOOTSTRAP_OS_RELEASE_FILE:-/etc/os-release}"
DOCKER_BIN="${CF_BOOTSTRAP_DOCKER_BIN:-}"
SYSTEMCTL_BIN="${CF_BOOTSTRAP_SYSTEMCTL_BIN:-}"
DOCKER_SOCKET_PATH="${CF_BOOTSTRAP_DOCKER_SOCKET_PATH:-/var/run/docker.sock}"
OPENSSL_BIN="/usr/bin/openssl"
TIMEOUT_BIN="/usr/bin/timeout"

if [ "$TESTING" = "1" ]; then
  TRUSTED_TMP_ROOT="${TMPDIR:-/tmp}"
else
  TRUSTED_TMP_ROOT="/tmp"
fi
EFFECTIVE_UID="$EUID"
MANAGEMENT_PRIMARY_GID="$(/usr/bin/id -g)"
# SUDO_UID/SUDO_GID are caller-controlled outside a verified sudo boundary.
# Direct invocation trusts the effective operator; elevated invocation trusts root.
MANAGEMENT_UID="$EFFECTIVE_UID"
SUDO_AUTHORIZED=0
DOCKER_USE_SUDO=0
NORMALIZED_PATH=""
ATTESTATION_FILE=""

TEMP_VENV_DIR=""
ENV_IMAGE=""
ENV_BIND_IP=""
ENV_PORT=""
ENV_CONTAINER=""
ENV_PROJECT=""
ENV_STORAGE_ROOT=""
ENV_RUNTIME_ROOT=""
ENV_ARCHIVE_ROOT=""
ENV_RUST_LOG=""
ENV_PROXY=""
ENV_RUNTIME_UID=""
ENV_RUNTIME_GID=""
ENV_RUNTIME_MODE=""
ENV_MANAGEMENT_GID=""
ENV_MIN_FREE_BYTES=""
ENV_MIN_FREE_PERCENT=""
ENV_MIN_FREE_INODES=""
ENV_TOKEN_SCAN_MAX_FILES=""
ENV_TOKEN_SCAN_MAX_BYTES=""

log() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$ATTESTATION_FILE" ]; then
    rm -f -- "$ATTESTATION_FILE"
  fi
  if [ -n "$TEMP_VENV_DIR" ]; then
    rm -rf -- "$TEMP_VENV_DIR"
  fi
}

run_privileged_with_hard_timeout() {
  local seconds="$1"
  shift
  if [ "$EFFECTIVE_UID" = 0 ]; then
    run_with_hard_timeout "$seconds" "$@"
  else
    [ "$SUDO_AUTHORIZED" -eq 1 ] ||
      die "internal error: sudo was not authorized"
    run_with_hard_timeout "$seconds" sudo -n -- "$@"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap-cfserver.sh

Prepare and validate the production deployment. This command never creates a
WeChat session, starts agent-wechat, or starts Gateway wechat-worker.
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
  [[ "$2" =~ ^(0|[1-9][0-9]*)$ ]] ||
    die "$1 must be a non-negative integer"
  decimal_is_at_most "$2" "$MAX_SIGNED_INTEGER" ||
    die "$1 exceeds the approved numeric range"
}

validate_positive_uint() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer"
  decimal_is_at_most "$2" "$MAX_SIGNED_INTEGER" ||
    die "$1 exceeds the approved numeric range"
}

decimal_is_at_most() {
  local value="$1" maximum="$2"
  local value_length maximum_length
  local LC_ALL=C

  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [[ "$maximum" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  value_length="${#value}"
  maximum_length="${#maximum}"
  [ "$value_length" -lt "$maximum_length" ] && return 0
  [ "$value_length" -gt "$maximum_length" ] && return 1
  [[ "$value" == "$maximum" || "$value" < "$maximum" ]]
}

validate_bounded_positive_uint() {
  local label="$1" value="$2" maximum="$3" suffix="$4"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
    die "$label must be a positive integer"
  if ! decimal_is_at_most "$value" "$maximum"; then
    die "$label must not exceed ${maximum} ${suffix}"
  fi
}

validate_mode() {
  [[ "$2" =~ ^[0-7]{3}$ ]] || die "$1 must be a three-digit octal mode"
}
proxy_is_safe() {
  local value="$1" remainder host port

  [ -z "$value" ] && return 0
  case "$value" in
    http://*) remainder="${value#http://}" ;;
    https://*) remainder="${value#https://}" ;;
    socks5://*) remainder="${value#socks5://}" ;;
    socks5h://*) remainder="${value#socks5h://}" ;;
    *) return 1 ;;
  esac
  case "$remainder" in
    *"@"*|*"/"*|*"?"*|*"#"*|*[[:cntrl:]]*) return 1 ;;
  esac
  host="${remainder%:*}"
  port="${remainder##*:}"
  [ "$host" != "$remainder" ] && [ -n "$host" ] || return 1
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || return 1
  case "$host" in
    \[*\])
      host="${host#[}"
      host="${host%]}"
      [[ "$host" =~ ^[0-9A-Fa-f:]+$ ]]
      ;;
    *)
      [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
        [[ "$host" != *..* ]]
      ;;
  esac
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

testing_canonical_path() {
  local path="$1"

  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *[[:cntrl:]]*) return 1 ;; esac
  realpath -m -s -- "$path" 2>/dev/null
}

testing_path_overlaps_production_asset() {
  local candidate production

  candidate="$(testing_canonical_path "$1")" || return 2
  production="$(testing_canonical_path "$2")" || return 2
  case "${candidate}/" in "${production}/"*) return 0 ;; esac
  case "${production}/" in "${candidate}/"*) return 0 ;; esac
  return 1
}

validate_testing_identity_and_root() {
  local real_uid effective_uid canonical resolved metadata owner mode production

  [ "$TESTING" = 1 ] || return 0
  real_uid="$(/usr/bin/id -ru 2>/dev/null)" ||
    die "testing identity could not be verified"
  effective_uid="$(/usr/bin/id -u 2>/dev/null)" ||
    die "testing identity could not be verified"
  if [ "$real_uid" = 0 ] || [ "$effective_uid" = 0 ] ||
    [ "$real_uid" != "$effective_uid" ]; then
    die "testing helpers require one non-root, non-elevated identity"
  fi
  canonical="$(testing_canonical_path "$TEST_ASSET_ROOT")" ||
    die "testing requires an explicit isolated CF_AGENT_WECHAT_TEST_ROOT"
  if [ "$canonical" = / ] || [ -L "$canonical" ] || [ ! -d "$canonical" ] ||
    ! resolved="$(readlink -f -- "$canonical" 2>/dev/null)" ||
    [ "$resolved" != "$canonical" ]; then
    die "testing root must be an existing non-symlink canonical directory"
  fi
  for production in \
    /srv/storage/cf-agent-wechat /opt/cf-agent-gateway /opt/cf-agent-wechat; do
    testing_path_overlaps_production_asset "$canonical" "$production" &&
      die "testing root overlaps a production asset"
  done
  metadata="$(stat -Lc '%u:%a' -- "$canonical" 2>/dev/null)" ||
    die "testing root metadata could not be verified"
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  [ "$owner" = "$effective_uid" ] ||
    die "testing root must be owned by the non-elevated caller"
  if (( (8#$mode & 8#022) != 0 )); then
    die "testing root must not be group/other writable"
  fi
}

validate_testing_asset() {
  local label="$1" path="$2" confinement="${3:-confined}"
  local canonical resolved root_canonical production

  [ "$TESTING" = 1 ] || return 0
  validate_testing_identity_and_root
  canonical="$(testing_canonical_path "$path")" ||
    die "testing $label must be an absolute control-free path"
  resolved="$(realpath -m -- "$canonical" 2>/dev/null)" ||
    die "testing $label could not be resolved safely"
  for production in \
    /srv/storage/cf-agent-wechat /opt/cf-agent-gateway /opt/cf-agent-wechat; do
    if testing_path_overlaps_production_asset "$canonical" "$production" ||
      testing_path_overlaps_production_asset "$resolved" "$production"; then
      die "testing $label overlaps a production asset"
    fi
  done
  if [ "$confinement" = confined ]; then
    root_canonical="$(testing_canonical_path "$TEST_ASSET_ROOT")" ||
      die "testing root could not be normalized"
    path_is_within "$canonical" "$root_canonical" ||
      die "testing $label must remain within the isolated testing root"
    path_is_within "$resolved" "$root_canonical" ||
      die "testing $label resolves outside the isolated testing root"
  fi
}

validate_testing_mock_executable() {
  local label="$1" path="$2" metadata owner mode links

  validate_testing_asset "$label" "$path" confined
  if [ -L "$path" ] || [ ! -f "$path" ] || [ ! -x "$path" ]; then
    die "testing $label must be an executable non-symlink regular file"
  fi
  metadata="$(stat -Lc '%u:%a:%h' -- "$path" 2>/dev/null)" ||
    die "testing $label metadata could not be verified"
  owner="${metadata%%:*}"
  mode="${metadata#*:}"; mode="${mode%%:*}"
  links="${metadata##*:}"
  if { [ "$owner" != 0 ] && [ "$owner" != "$(/usr/bin/id -u)" ]; } ||
    [ "$links" != 1 ] || (( (8#$mode & 8#022) != 0 )); then
    die "testing $label has unsafe owner, mode, or link count"
  fi
}

validate_testing_isolation() {
  local path

  [ "$TESTING" = 1 ] || return 0
  validate_testing_identity_and_root
  for path in \
    "$AGENT_ROOT" "$AGENT_COMPOSE_FILE" "$AGENT_ENV_FILE" \
    "$STORAGE_ROOT" "$RUNTIME_ROOT" "$ARCHIVE_ROOT" "$SECRETS_ROOT" \
    "$TOKEN_FILE" "$GATEWAY_PROJECT_DIR" "$GATEWAY_COMPOSE_FILE" \
    "$GATEWAY_ENV_FILE" "$GATEWAY_HEARTBEAT_COMMAND" \
    "$GATEWAY_RELEASE_GATE_COMMAND" \
    "$GATEWAY_CONTRACT_FILE" "$TRUSTED_TMP_ROOT" "$DOCKER_SOCKET_PATH"; do
    validate_testing_asset "management asset" "$path" confined
  done
  for path in "$SCRIPT_DIR" "$GATEWAY_CONTRACT_VERIFIER" \
    "$MANAGEMENT_ENV_PARSER" "$MANAGEMENT_SOURCE_SECRET_VERIFIER"; do
    validate_testing_asset "repository helper" "$path" external
  done
  if [ "$OS_RELEASE_FILE" != /etc/os-release ]; then
    validate_testing_asset "os-release fixture" "$OS_RELEASE_FILE" confined
  fi
  validate_testing_mock_executable "Docker mock" "$DOCKER_BIN"
  validate_testing_mock_executable "systemctl mock" "$SYSTEMCTL_BIN"
  [ -z "${CF_BOOTSTRAP_TEST_GATEWAY_VERIFIER_REPLACEMENT:-}" ] ||
    die "Bootstrap testing does not permit destructive verifier replacement hooks"
}

run_with_hard_timeout() {
  local seconds="$1" soft
  shift
  if [ "$seconds" -le "$TIMEOUT_GRACE" ]; then
    "$TIMEOUT_BIN" --signal=KILL "${seconds}s" "$@"
    return
  fi
  soft=$((seconds - TIMEOUT_GRACE))
  "$TIMEOUT_BIN" --signal=TERM --kill-after="${TIMEOUT_GRACE}s" "${soft}s" "$@"
}

bootstrap_python_with_timeout() {
  local seconds="$1"
  shift
  run_with_hard_timeout "$seconds" /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /usr/bin/python3 -I "$@"
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
    executable) [ "$mode" = 755 ] || die "$label mode must be exactly 755" ;;
    data) [ "$mode" = 644 ] || die "$label mode must be exactly 644" ;;
    readonly)
      if (( (8#$mode & 8#022) != 0 )); then
        die "$label must not be group/other writable"
      fi
      ;;
    *) die "internal error: unknown file mode contract" ;;
  esac
}

validate_agent_environment_metadata_contract() {
  local metadata owner group mode links

  metadata="$(privileged stat -c '%u:%g:%a:%h' -- "$AGENT_ENV_FILE" 2>/dev/null)" ||
    die "production environment file metadata could not be read"
  owner="${metadata%%:*}"
  metadata="${metadata#*:}"
  group="${metadata%%:*}"
  metadata="${metadata#*:}"
  mode="${metadata%%:*}"
  links="${metadata##*:}"
  [ "$links" = 1 ] ||
    die "production environment file must not have additional hard links"

  case "$mode" in
    600)
      if { [ "$owner" = 0 ] && [ "$group" = 0 ]; } ||
        { [ "$owner" = "$MANAGEMENT_UID" ] &&
          [ "$group" = "$MANAGEMENT_PRIMARY_GID" ]; }; then
        return 0
      fi
      ;;
    640)
      if { [ "$owner" = 0 ] || [ "$owner" = "$MANAGEMENT_UID" ]; } &&
        [ "$group" = "$ENV_MANAGEMENT_GID" ]; then
        return 0
      fi
      ;;
  esac
  die "production environment file owner, group, and mode do not match the approved management contract"
}

validate_root_file() {
  local label="$1"
  local path="$2"
  local expected_mode="$3"
  local metadata

  if privileged test -L "$path" || ! privileged test -f "$path"; then
    die "$label must be an existing non-symlink regular file"
  fi
  metadata="$(privileged stat -Lc '%u:%g:%a:%h' -- "$path" 2>/dev/null)" ||
    die "$label metadata could not be read"
  [ "$metadata" = "0:0:${expected_mode}:1" ] ||
    die "$label must be root:root $expected_mode with one hard link"

}

validate_directory_without_extended_attributes() {
  local label="$1" path="$2"
  local -a python_command=(
    /usr/bin/env -i
    HOME=/nonexistent
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    LANG=C.UTF-8
    LC_ALL=C.UTF-8
    /usr/bin/python3 -I - "$path"
  )

  if run_privileged_with_hard_timeout "$DOCKER_TIMEOUT" "${python_command[@]}" >/dev/null 2>&1 <<'PY'
import os
import stat
import sys

path = sys.argv[1]
required_flags = ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC")
if any(not hasattr(os, name) for name in required_flags):
    raise SystemExit(1)

def identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_ctime_ns,
    )

descriptor = -1
try:
    before = os.lstat(path)
    if not stat.S_ISDIR(before.st_mode):
        raise OSError
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(path, flags)
    opened = os.fstat(descriptor)
    if identity(opened) != identity(before):
        raise OSError
    attributes = os.listxattr(descriptor)
    after = os.fstat(descriptor)
    final = os.lstat(path)
    if (
        attributes
        or identity(after) != identity(opened)
        or identity(final) != identity(opened)
    ):
        raise OSError
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if descriptor >= 0:
        os.close(descriptor)
PY
  then
    return 0
  fi
  die "$label must be a stable no-follow directory without extended attributes or ACLs"
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
  validate_directory_without_extended_attributes "$label" "$path"
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
  validate_directory_without_extended_attributes "$label" "$path"
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
  local command_name os_id os_like temp_metadata
  case "$TESTING" in 0|1) ;; *) die "CF_BOOTSTRAP_TESTING must be 0 or 1" ;; esac
  if [ "$TESTING" = "1" ]; then
    validate_bounded_positive_uint "CF_BOOTSTRAP_DOCKER_TIMEOUT" \
      "$DOCKER_TIMEOUT" "$MAX_TEST_DOCKER_TIMEOUT" "seconds in testing mode"
    validate_bounded_positive_uint "CF_BOOTSTRAP_COMPOSE_TIMEOUT" \
      "$COMPOSE_TIMEOUT" "$MAX_TEST_COMPOSE_TIMEOUT" "seconds in testing mode"
  fi
  for command_name in \
    apt-get awk chmod chown curl dirname dpkg-query env flock grep id install ln \
    mktemp mv openssl python3 readlink realpath rm stat timeout; do
    require_command "$command_name"
  done
  [ -x /usr/bin/python3 ] || die "fixed /usr/bin/python3 is unavailable"
  if [ -L "$TRUSTED_TMP_ROOT" ] || [ ! -d "$TRUSTED_TMP_ROOT" ]; then
    die "trusted temporary root must be an existing non-symlink directory"
  fi
  temp_metadata="$(stat -Lc '%u:%g:%a' -- "$TRUSTED_TMP_ROOT" 2>/dev/null)" ||
    die "trusted temporary root metadata could not be inspected"
  if [ "$TESTING" != "1" ] && [ "$temp_metadata" != "0:0:1777" ]; then
    die "production /tmp must be root:root mode 1777"
  fi
  bootstrap_python_with_timeout 30 -c 'import json, venv' >/dev/null 2>&1 ||
    die "Python 3 json and venv support are required"
  bootstrap_python_with_timeout 30 -c '
import platform
import sys
import sysconfig
supported = (
    platform.python_implementation() == "CPython"
    and (3, 10) <= sys.version_info[:2] <= (3, 14)
    and sysconfig.get_config_var("Py_GIL_DISABLED") in (None, 0, "", "0")
)
raise SystemExit(0 if supported else 1)
' >/dev/null 2>&1 || die "GIL-enabled CPython 3.10 through 3.14 is required"
  TEMP_VENV_DIR="$(mktemp -d "${TRUSTED_TMP_ROOT}/cf-agent-wechat-venv-check.XXXXXX")" ||
    die "temporary venv validation directory could not be created"
  bootstrap_python_with_timeout 30 -m venv "$TEMP_VENV_DIR" >/dev/null 2>&1 ||
    die "python3-venv could not create a working isolated environment"
  run_with_hard_timeout 30 /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "${TEMP_VENV_DIR}/bin/python" -I -c '
import ensurepip
import json
import sysconfig
raise SystemExit(
    0 if sysconfig.get_config_var("Py_GIL_DISABLED") in (None, 0, "", "0") else 1
)
' >/dev/null 2>&1 ||
    die "the created Python venv is not GIL-enabled or does not provide ensurepip"
  run_with_hard_timeout 30 /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    "${TEMP_VENV_DIR}/bin/python" -I -m pip --version >/dev/null 2>&1 ||
    die "the created Python venv does not provide a runnable pip"

  [ -f "$OS_RELEASE_FILE" ] || die "Linux os-release metadata is missing"
  os_id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print tolower($2); exit }' "$OS_RELEASE_FILE")"
  os_like="$(awk -F= '$1 == "ID_LIKE" { gsub(/"/, "", $2); print tolower($2); exit }' "$OS_RELEASE_FILE")"
  case " ${os_id} ${os_like} " in
    *' debian '*|*' ubuntu '*) ;;
    *) die "a Debian-family host is required" ;;
  esac

  validate_uint "CF_AGENT_WECHAT_RUNTIME_UID" "$RUNTIME_UID"
  validate_uint "CF_AGENT_WECHAT_RUNTIME_GID" "$RUNTIME_GID"
  decimal_is_at_most "$RUNTIME_UID" "$MAX_UID_GID" ||
    die "CF_AGENT_WECHAT_RUNTIME_UID exceeds the approved numeric ID range"
  decimal_is_at_most "$RUNTIME_GID" "$MAX_UID_GID" ||
    die "CF_AGENT_WECHAT_RUNTIME_GID exceeds the approved numeric ID range"
  validate_mode "CF_AGENT_WECHAT_RUNTIME_MODE" "$RUNTIME_MODE"
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
    if [ "$TESTING" = 1 ]; then
      if [ -L "$path" ] || [ ! -f "$path" ]; then
        die "$label must be a non-symlink regular file"
      fi
      metadata="$(stat -c '%u:%a:%h' -- "$path" 2>/dev/null)" ||
        die "$label metadata could not be read"
    else
      if privileged test -L "$path" || ! privileged test -f "$path"; then
        die "$label must be a non-symlink regular file"
      fi
      metadata="$(privileged stat -c '%u:%a:%h' -- "$path" 2>/dev/null)" ||
        die "$label metadata could not be read"
    fi
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

environment_variable_is_exported() {
  local name="$1" definition attributes

  definition="$(declare -p "$name" 2>/dev/null)" || return 1
  attributes="${definition#declare -}"
  [ "$attributes" != "$definition" ] || return 1
  attributes="${attributes%% *}"
  [[ "$attributes" == *x* ]]
}

reject_environment_overrides() {
  local variable
  if [ "$TESTING" != 1 ] &&
    [ -n "$_CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES" ]; then
    variable="${_CF_AGENT_WECHAT_BOOTSTRAP_EARLY_OVERRIDES%%,*}"
    die "$variable is forbidden as a production Bootstrap environment override"
  fi
  for variable in \
    DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH \
    DOCKER_API_VERSION DOCKER_CONFIG BUILDX_BUILDER; do
    if environment_variable_is_exported "$variable"; then
      die "$variable cannot override the production local Docker daemon"
    fi
  done
  if [ "$TESTING" = 1 ]; then
    [ -z "${CF_BOOTSTRAP_TEST_GATEWAY_VERIFIER_REPLACEMENT:-}" ] ||
      die "Bootstrap testing does not permit verifier replacement hooks"
    return 0
  fi
  for variable in \
    COMPOSE_FILE COMPOSE_PROFILES COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR \
    COMPOSE_PROJECT_DIR COMPOSE_PARALLEL_LIMIT COMPOSE_IGNORE_ORPHANS \
    COMPOSE_REMOVE_ORPHANS COMPOSE_STATUS_STDOUT COMPOSE_ANSI \
    COMPOSE_PROGRESS COMPOSE_EXPERIMENTAL COMPOSE_MENU \
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy no_proxy \
    AUTH_TOKEN CF_AGENT_WECHAT_TOKEN CF_GATEWAY_API_TOKEN \
    CF_AGENT_GATEWAY_ADMIN_TOKEN HERMES_API_KEY \
    API_URL WS_URL TOKEN_FILE SESSION_ID CONTAINER_NAME PYTHON_BIN \
    REQUIREMENTS_FILE VENV_DIR CF_AGENT_WECHAT_VENV AGENT_WECHAT_IMAGE \
    AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT AGENT_WECHAT_CONTAINER_NAME \
    COMPOSE_PROJECT_NAME PROXY RUST_LOG CF_AGENT_WECHAT_ROOT \
    CF_AGENT_WECHAT_COMPOSE_FILE CF_AGENT_WECHAT_ENV_FILE \
    CF_AGENT_WECHAT_STORAGE_ROOT CF_AGENT_WECHAT_RUNTIME_ROOT \
    CF_AGENT_WECHAT_ARCHIVE_ROOT CF_AGENT_WECHAT_TOKEN_FILE \
    CF_AGENT_WECHAT_RUNTIME_UID CF_AGENT_WECHAT_RUNTIME_GID \
    CF_AGENT_WECHAT_RUNTIME_MODE CF_AGENT_WECHAT_MANAGEMENT_GID \
    CF_AGENT_GATEWAY_COMPOSE_FILE CF_AGENT_GATEWAY_PROJECT_DIR \
    CF_AGENT_GATEWAY_ENV_FILE CF_AGENT_GATEWAY_HEARTBEAT_COMMAND \
    CF_AGENT_WECHAT_CURL_BIN CF_AGENT_WECHAT_DOCKER_BIN \
    CF_AGENT_WECHAT_SYSTEMCTL_BIN CF_AGENT_WECHAT_DOCKER_SOCKET_PATH \
    CF_AGENT_WECHAT_DF_BIN CF_AGENT_WECHAT_TESTING \
    CF_BOOTSTRAP_OS_RELEASE_FILE CF_BOOTSTRAP_DOCKER_BIN \
    CF_BOOTSTRAP_SYSTEMCTL_BIN CF_BOOTSTRAP_DOCKER_SOCKET_PATH \
    CF_BOOTSTRAP_DOCKER_TIMEOUT CF_BOOTSTRAP_COMPOSE_TIMEOUT \
    CF_AGENT_WECHAT_TEST_ROOT \
    CF_BOOTSTRAP_TEST_GATEWAY_VERIFIER_REPLACEMENT \
    CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT TMPDIR; do
    if environment_variable_is_exported "$variable"; then
      die "$variable is forbidden as a production Bootstrap environment override"
    fi
  done
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
  normalize_path "Gateway project directory" "$GATEWAY_PROJECT_DIR"; GATEWAY_PROJECT_DIR="$NORMALIZED_PATH"
  normalize_path "Gateway Compose" "$GATEWAY_COMPOSE_FILE"; GATEWAY_COMPOSE_FILE="$NORMALIZED_PATH"
  normalize_path "Gateway environment" "$GATEWAY_ENV_FILE"; GATEWAY_ENV_FILE="$NORMALIZED_PATH"
  GATEWAY_HEARTBEAT_COMMAND="${GATEWAY_PROJECT_DIR}/deploy/check-wechat-worker-heartbeat"
  GATEWAY_RELEASE_GATE_COMMAND="${GATEWAY_PROJECT_DIR}/deploy/wechat-runtime-release-gate"
  GATEWAY_CONTRACT_FILE="${GATEWAY_PROJECT_DIR}/deploy/wechat-runtime-contract.json"
  normalize_path "Gateway heartbeat checker" "$GATEWAY_HEARTBEAT_COMMAND"
  GATEWAY_HEARTBEAT_COMMAND="$NORMALIZED_PATH"
  normalize_path "Gateway runtime release gate" "$GATEWAY_RELEASE_GATE_COMMAND"
  GATEWAY_RELEASE_GATE_COMMAND="$NORMALIZED_PATH"
  normalize_path "Gateway runtime contract" "$GATEWAY_CONTRACT_FILE"
  GATEWAY_CONTRACT_FILE="$NORMALIZED_PATH"

  STORAGE_ROOT="$storage"; RUNTIME_ROOT="$runtime"; ARCHIVE_ROOT="$archive"
  TOKEN_FILE="$token"; SECRETS_ROOT="$secrets"
  LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"; LEGACY_HOME_ROOT="${STORAGE_ROOT}/wechat-home"
  expected_token="${STORAGE_ROOT}/secrets/auth-token"
  [ "$TOKEN_FILE" = "$expected_token" ] ||
    die "Token file must remain at the independent storage secrets path"
  [ "$SECRETS_ROOT" = "${STORAGE_ROOT}/secrets" ] || die "invalid secrets root"
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
  local helper

  validate_no_symlink_ancestors "repository root" "$AGENT_ROOT"
  validate_no_symlink_ancestors "production Compose file" "$AGENT_COMPOSE_FILE"
  validate_no_symlink_ancestors "production environment file" "$AGENT_ENV_FILE"
  validate_no_symlink_ancestors "storage root" "$STORAGE_ROOT"
  validate_no_symlink_ancestors "runtime root" "$RUNTIME_ROOT"
  validate_no_symlink_ancestors "archive root" "$ARCHIVE_ROOT"
  validate_no_symlink_ancestors "Token file" "$TOKEN_FILE"
  validate_no_symlink_ancestors "Gateway project directory" "$GATEWAY_PROJECT_DIR"
  validate_no_symlink_ancestors "Gateway Compose file" "$GATEWAY_COMPOSE_FILE"
  validate_no_symlink_ancestors "Gateway environment file" "$GATEWAY_ENV_FILE"
  validate_no_symlink_ancestors "Gateway heartbeat checker" "$GATEWAY_HEARTBEAT_COMMAND"
  validate_no_symlink_ancestors "Gateway runtime release gate" "$GATEWAY_RELEASE_GATE_COMMAND"
  validate_no_symlink_ancestors "Gateway runtime contract" "$GATEWAY_CONTRACT_FILE"
  for helper in \
    bootstrap-cfserver.sh common.sh qr-runtime-common.sh start-qr-login.sh \
    stop-qr-runtime.sh status.sh login.sh qr_login.py \
    ensure-login-environment.sh verify_login_dependencies.py \
    archive-runtime.py scan_runtime_tree.py verify_gateway_contract.py \
    verify_management_source_secrets.py parse_management_env.py \
    requirements.txt; do
    validate_no_symlink_ancestors \
      "management helper ${helper}" "${SCRIPT_DIR}/${helper}"
  done
}

validate_repository_inputs() {
  local helper

  validate_management_directory "repository root" "$AGENT_ROOT"
  validate_management_directory "management scripts directory" "$SCRIPT_DIR"
  validate_management_directory "docker configuration directory" "$(dirname -- "$AGENT_ENV_FILE")"
  validate_management_file "production Compose file" "$AGENT_COMPOSE_FILE" data
  validate_management_file "production environment file" "$AGENT_ENV_FILE" environment
  for helper in \
    bootstrap-cfserver.sh common.sh qr-runtime-common.sh start-qr-login.sh \
    stop-qr-runtime.sh status.sh login.sh qr_login.py \
    ensure-login-environment.sh verify_login_dependencies.py \
    archive-runtime.py scan_runtime_tree.py verify_gateway_contract.py \
    verify_management_source_secrets.py parse_management_env.py; do
    validate_management_file \
      "management helper ${helper}" "${SCRIPT_DIR}/${helper}" executable
  done
  validate_management_file \
    "QR login requirements lock" "${SCRIPT_DIR}/requirements.txt" data
  validate_management_directory "Gateway project directory" "$GATEWAY_PROJECT_DIR"
  validate_management_file "Gateway Compose file" "$GATEWAY_COMPOSE_FILE" readonly
  if [ "$TESTING" = "1" ]; then
    validate_management_file "Gateway environment/config file" "$GATEWAY_ENV_FILE" environment
    validate_management_file "Gateway runtime contract" "$GATEWAY_CONTRACT_FILE" readonly
    validate_management_file "Gateway heartbeat checker" "$GATEWAY_HEARTBEAT_COMMAND" readonly
    validate_management_file "Gateway runtime release gate" "$GATEWAY_RELEASE_GATE_COMMAND" readonly
  else
    validate_root_file "Gateway environment/config file" "$GATEWAY_ENV_FILE" 600
    validate_root_file "Gateway runtime contract" "$GATEWAY_CONTRACT_FILE" 644
    validate_root_file "Gateway heartbeat checker" "$GATEWAY_HEARTBEAT_COMMAND" 755
    validate_root_file "Gateway runtime release gate" "$GATEWAY_RELEASE_GATE_COMMAND" 755
  fi
  [ -x "$GATEWAY_HEARTBEAT_COMMAND" ] ||
    die "Gateway heartbeat checker must be executable by the management user"
  [ -x "$GATEWAY_RELEASE_GATE_COMMAND" ] ||
    die "Gateway runtime release gate must be executable by the management user"
}

parse_agent_environment() {
  local content line key value parser_snapshot parser_fd
  local pair_count=0
  local -a parser_args
  local -A seen=()
  parser_snapshot="$(mktemp \
    "${TRUSTED_TMP_ROOT}/cf-agent-wechat-management-env.XXXXXXXXXX")" ||
    die "docker/.env parser snapshot could not be isolated"
  chmod 600 "$parser_snapshot" || {
    rm -f -- "$parser_snapshot"
    die "docker/.env parser snapshot could not be protected"
  }
  parser_args=("$MANAGEMENT_ENV_PARSER" --env-file "$AGENT_ENV_FILE" --format nul)
  if [ "$TESTING" = "1" ]; then
    parser_args+=(--path-contract portable)
  fi
  if ! run_privileged_with_hard_timeout "$DOCKER_TIMEOUT" \
    /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /usr/bin/python3 -I "${parser_args[@]}" \
    >"$parser_snapshot" 2>/dev/null; then
    rm -f -- "$parser_snapshot"
    die "docker/.env failed byte-safe validation"
  fi
  if ! { exec {parser_fd}<"$parser_snapshot"; } 2>/dev/null; then
    rm -f -- "$parser_snapshot"
    die "docker/.env parser snapshot could not be opened"
  fi
  rm -f -- "$parser_snapshot"
  content=""
  while IFS= read -r -d '' key <&"$parser_fd"; do
    if ! IFS= read -r -d '' value <&"$parser_fd"; then
      exec {parser_fd}<&-
      die "docker/.env parser output was incomplete"
    fi
    content+="${key}=${value}"$'\n'
    pair_count=$((pair_count + 1))
  done
  exec {parser_fd}<&-
  [ "$pair_count" -eq 19 ] ||
    die "docker/.env parser output was incomplete"
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
      AGENT_WECHAT_IMAGE) ENV_IMAGE="$value" ;;
      AGENT_WECHAT_BIND_IP) ENV_BIND_IP="$value" ;;
      AGENT_WECHAT_PORT) ENV_PORT="$value" ;;
      AGENT_WECHAT_CONTAINER_NAME) ENV_CONTAINER="$value" ;;
      COMPOSE_PROJECT_NAME) ENV_PROJECT="$value" ;;
      CF_AGENT_WECHAT_STORAGE_ROOT) ENV_STORAGE_ROOT="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_ROOT) ENV_RUNTIME_ROOT="$value" ;;
      CF_AGENT_WECHAT_ARCHIVE_ROOT) ENV_ARCHIVE_ROOT="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_UID) ENV_RUNTIME_UID="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_GID) ENV_RUNTIME_GID="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_MODE) ENV_RUNTIME_MODE="$value" ;;
      CF_AGENT_WECHAT_MANAGEMENT_GID) ENV_MANAGEMENT_GID="$value" ;;
      CF_AGENT_WECHAT_MIN_FREE_BYTES) ENV_MIN_FREE_BYTES="$value" ;;
      CF_AGENT_WECHAT_MIN_FREE_PERCENT) ENV_MIN_FREE_PERCENT="$value" ;;
      CF_AGENT_WECHAT_MIN_FREE_INODES) ENV_MIN_FREE_INODES="$value" ;;
      CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES) ENV_TOKEN_SCAN_MAX_FILES="$value" ;;
      CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES) ENV_TOKEN_SCAN_MAX_BYTES="$value" ;;
      PROXY) ENV_PROXY="$value"; proxy_is_safe "$value" ||
        die "PROXY must be empty or an approved credential-free scheme, host, and port" ;;
      RUST_LOG) ENV_RUST_LOG="$value" ;;
      *TOKEN*|*PASSWORD*|*SECRET*) die "production environment must not contain secret-bearing key: $key" ;;
      *) die "production environment contains an unsupported key: $key" ;;
    esac
  done <<< "$content"
  content=""

  [[ "$ENV_IMAGE" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]] ||
    die "AGENT_WECHAT_IMAGE must be pinned to an immutable sha256 digest"
  [ "$ENV_BIND_IP" = 127.0.0.1 ] || die "AGENT_WECHAT_BIND_IP must be 127.0.0.1"
  validate_positive_uint "AGENT_WECHAT_PORT" "$ENV_PORT"
  decimal_is_at_most "$ENV_PORT" 65535 ||
    die "AGENT_WECHAT_PORT must not exceed 65535"
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
  case "$ENV_RUST_LOG" in error|warn|info) ;; *) die "RUST_LOG must be error, warn, or info" ;; esac
  validate_positive_uint "CF_AGENT_WECHAT_RUNTIME_UID" "$ENV_RUNTIME_UID"
  validate_positive_uint "CF_AGENT_WECHAT_RUNTIME_GID" "$ENV_RUNTIME_GID"
  decimal_is_at_most "$ENV_RUNTIME_UID" "$MAX_UID_GID" ||
    die "CF_AGENT_WECHAT_RUNTIME_UID exceeds the approved numeric ID range"
  decimal_is_at_most "$ENV_RUNTIME_GID" "$MAX_UID_GID" ||
    die "CF_AGENT_WECHAT_RUNTIME_GID exceeds the approved numeric ID range"
  [ "$ENV_RUNTIME_MODE" = 700 ] ||
    die "CF_AGENT_WECHAT_RUNTIME_MODE must be exactly 700"
  validate_positive_uint "CF_AGENT_WECHAT_MANAGEMENT_GID" "$ENV_MANAGEMENT_GID"
  decimal_is_at_most "$ENV_MANAGEMENT_GID" "$MAX_UID_GID" ||
    die "CF_AGENT_WECHAT_MANAGEMENT_GID exceeds the approved numeric ID range"
  validate_positive_uint "CF_AGENT_WECHAT_MIN_FREE_BYTES" "$ENV_MIN_FREE_BYTES"
  validate_uint "CF_AGENT_WECHAT_MIN_FREE_PERCENT" "$ENV_MIN_FREE_PERCENT"
  decimal_is_at_most "$ENV_MIN_FREE_PERCENT" 100 ||
    die "CF_AGENT_WECHAT_MIN_FREE_PERCENT must be between 0 and 100"
  validate_positive_uint "CF_AGENT_WECHAT_MIN_FREE_INODES" "$ENV_MIN_FREE_INODES"
  validate_positive_uint "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES" "$ENV_TOKEN_SCAN_MAX_FILES"
  if ! decimal_is_at_most "$ENV_TOKEN_SCAN_MAX_FILES" 200000; then
    die "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES must not exceed the compiled scanner limit"
  fi
  validate_positive_uint "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES" "$ENV_TOKEN_SCAN_MAX_BYTES"
  RUNTIME_UID="$ENV_RUNTIME_UID"
  RUNTIME_GID="$ENV_RUNTIME_GID"
  RUNTIME_MODE="$ENV_RUNTIME_MODE"
}

systemd_definition_references_agent_runtime() {
  local definition="$1"
  [[ "$definition" == *"$AGENT_COMPOSE_FILE"* ]] ||
    [[ "$definition" == *"${AGENT_ROOT}/scripts/start-qr-login.sh"* ]] ||
    [[ "$definition" == *"start-qr-login.sh"* ]] ||
    [[ "$definition" == *"$AGENT_PROJECT"* ]] ||
    [[ "$definition" == *"$ENV_CONTAINER"* ]]
}

systemd_unit_name_is_valid() {
  local unit="$1" remainder

  [ -n "$unit" ] && [ "${#unit}" -le 255 ] || return 1
  case "$unit" in
    *.service|*.timer|*.path|*.socket|*.target|*.device|*.mount|\
    *.automount|*.swap|*.slice|*.scope) ;;
    *) return 1 ;;
  esac
  remainder="${unit%.*}"
  [ -n "$remainder" ] || return 1
  while [ -n "$remainder" ]; do
    case "$remainder" in
      \\x[0-9A-Fa-f][0-9A-Fa-f]*) remainder="${remainder:4}" ;;
      [A-Za-z0-9_.@:-]*) remainder="${remainder:1}" ;;
      *) return 1 ;;
    esac
  done
}

systemd_unit_name_references_agent_runtime() {
  case "${1,,}" in
    *agent-wechat*|*agent_wechat*|*wechat-agent*|*wechat_agent*) return 0 ;;
    *) return 1 ;;
  esac
}

bootstrap_systemctl() {
  local -a clean_env

  if [ "$TESTING" = "1" ]; then
    clean_env=(
      -u SYSTEMD_COLORS -u SYSTEMD_URLIFY -u SYSTEMD_PAGER
      -u SYSTEMD_PAGERSECURE -u SYSTEMD_LESS -u SYSTEMD_LOG_LEVEL
      -u SYSTEMD_LOG_TARGET -u SYSTEMD_LOG_TIME -u SYSTEMD_LOG_LOCATION
      -u SYSTEMD_LOG_TID -u SYSTEMD_UNIT_PATH
    )
  else
    clean_env=(
      -i HOME=/nonexistent
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      LANG=C.UTF-8 LC_ALL=C.UTF-8 SYSTEMD_PAGER=
    )
  fi
  run_with_hard_timeout "$DOCKER_TIMEOUT" /usr/bin/env \
    "${clean_env[@]}" "$SYSTEMCTL_BIN" "$@"
}

capture_systemctl_probe() {
  local captured probe_status

  if captured="$(bootstrap_systemctl "$@" 2>/dev/null)"; then
    probe_status=0
  else
    probe_status=$?
  fi
  SYSTEMD_PROBE_OUTPUT="$captured"
  SYSTEMD_PROBE_STATUS="$probe_status"
  return 0
}

systemd_read_unit_definition() {
  local unit="$1"

  SYSTEMD_UNIT_DEFINITION="$(
    bootstrap_systemctl cat "$unit" --no-pager 2>/dev/null
  )" || return 1
  [ -n "$SYSTEMD_UNIT_DEFINITION" ]
}

systemd_show_unit_property() {
  local unit="$1" property="$2"

  SYSTEMD_PROPERTY_VALUE="$(
    bootstrap_systemctl show "$unit" --property="$property" --value --no-pager 2>/dev/null
  )" || return 1
  case "$SYSTEMD_PROPERTY_VALUE" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
}

systemd_reject_agent_activation() {
  local activation_kind="$1"

  case "$activation_kind" in
    timer) die "an enabled systemd timer could automatically start agent-wechat" ;;
    path) die "an enabled systemd path unit could automatically start agent-wechat" ;;
    socket) die "an enabled systemd socket could automatically start agent-wechat" ;;
    target) die "an enabled systemd target could automatically start agent-wechat" ;;
    *) die "an enabled systemd unit could automatically start agent-wechat" ;;
  esac
}

systemd_inspect_activation_target() {
  local activation_kind="$1" target="$2" expected_type="$3"

  if [ "$expected_type" = service ]; then
    case "$target" in
      *.service) ;;
      *) die "enabled systemd $activation_kind target must resolve to a service unit" ;;
    esac
  fi
  case "$target" in
    *@.service|*%*)
      die "enabled systemd $activation_kind target uses unsupported templated activation"
      ;;
  esac
  systemd_unit_name_is_valid "$target" ||
    die "enabled systemd $activation_kind target is not a valid inspectable unit"
  if systemd_unit_name_references_agent_runtime "$target"; then
    systemd_reject_agent_activation "$activation_kind"
  fi
  systemd_read_unit_definition "$target" ||
    die "enabled systemd $activation_kind target definitions could not be inspected"
  if systemd_definition_references_agent_runtime "$SYSTEMD_UNIT_DEFINITION"; then
    systemd_reject_agent_activation "$activation_kind"
  fi
}

systemd_inspect_single_activation() {
  local unit="$1" property="$2" activation_kind="$3"
  local -a targets=()

  systemd_show_unit_property "$unit" "$property" ||
    die "enabled systemd $activation_kind target could not be resolved safely"
  read -r -a targets <<< "$SYSTEMD_PROPERTY_VALUE"
  [ "${#targets[@]}" -eq 1 ] ||
    die "enabled systemd $activation_kind target is missing or ambiguous"
  systemd_inspect_activation_target "$activation_kind" "${targets[0]}" service
}

systemd_inspect_target_dependencies() {
  local unit="$1" property dependency
  local -a dependencies=()

  for property in Wants Requires; do
    systemd_show_unit_property "$unit" "$property" ||
      die "enabled systemd target dependencies could not be resolved safely"
    [ -n "$SYSTEMD_PROPERTY_VALUE" ] || continue
    read -r -a dependencies <<< "$SYSTEMD_PROPERTY_VALUE"
    [ "${#dependencies[@]}" -gt 0 ] ||
      die "enabled systemd target dependencies are malformed"
    for dependency in "${dependencies[@]}"; do
      systemd_inspect_activation_target target "$dependency" any
    done
    dependencies=()
  done
}

validate_systemd() {
  local state activity agent_activity enablement agent_enablement probe_status
  local enabled_units active_units unit unit_state
  local loaded_state active_state sub_state
  capture_systemctl_probe is-system-running
  state="$SYSTEMD_PROBE_OUTPUT"
  probe_status="$SYSTEMD_PROBE_STATUS"
  case "${state}:${probe_status}" in
    running:0|degraded:1) ;;
    *) die "systemd state probe failed or systemd is not running or degraded" ;;
  esac
  capture_systemctl_probe is-active docker.service
  activity="$SYSTEMD_PROBE_OUTPUT"
  probe_status="$SYSTEMD_PROBE_STATUS"
  [ "$activity" = active ] && [ "$probe_status" -eq 0 ] ||
    die "docker.service must be active"
  capture_systemctl_probe is-enabled docker.service
  enablement="$SYSTEMD_PROBE_OUTPUT"
  probe_status="$SYSTEMD_PROBE_STATUS"
  [ "$enablement" = enabled ] && [ "$probe_status" -eq 0 ] ||
    die "docker.service must be enabled"
  capture_systemctl_probe is-active cf-agent-wechat.service
  agent_activity="$SYSTEMD_PROBE_OUTPUT"
  probe_status="$SYSTEMD_PROBE_STATUS"
  case "${agent_activity}:${probe_status}" in
    inactive:3|failed:3) ;;
    active:0|activating:0|reloading:0|deactivating:0)
      die "cf-agent-wechat.service must be inactive"
      ;;
    *) die "cf-agent-wechat.service activity probe failed or returned an unsafe state" ;;
  esac
  capture_systemctl_probe is-enabled cf-agent-wechat.service
  agent_enablement="$SYSTEMD_PROBE_OUTPUT"
  probe_status="$SYSTEMD_PROBE_STATUS"
  case "$agent_enablement" in
    enabled|enabled-runtime|linked|linked-runtime|alias)
      [ "$probe_status" -eq 0 ] ||
        die "cf-agent-wechat.service enablement probe failed"
      die "cf-agent-wechat.service must not be enabled for automatic boot"
      ;;
    disabled|static|masked|indirect|generated|transient)
      [ "$probe_status" -eq 1 ] ||
        die "cf-agent-wechat.service enablement probe failed"
      ;;
    not-found)
      { [ "$probe_status" -eq 1 ] || [ "$probe_status" -eq 4 ]; } ||
        die "cf-agent-wechat.service enablement probe failed"
      ;;
    *)
      die "cf-agent-wechat.service enablement could not be determined safely"
      ;;
  esac
  enabled_units="$(
    bootstrap_systemctl list-unit-files \
      --type=service,timer,path,socket,target \
      --state=enabled,enabled-runtime,linked,linked-runtime,alias \
      --no-legend --no-pager 2>/dev/null
  )" || die "enabled systemd unit inventory could not be inspected"
  while read -r unit unit_state _; do
    [ -n "$unit" ] || continue
    case "$unit_state" in
      enabled|enabled-runtime|linked|linked-runtime|alias) ;;
      *) die "enabled systemd unit inventory returned an unexpected state" ;;
    esac
    case "$unit" in
      *.service|*.timer|*.path|*.socket|*.target) ;;
      *) die "enabled systemd unit inventory returned an unsupported unit type" ;;
    esac
    systemd_unit_name_is_valid "$unit" ||
      die "enabled systemd unit inventory returned an invalid unit name"
    if systemd_unit_name_references_agent_runtime "$unit"; then
      die "an enabled systemd unit could automatically start agent-wechat"
    fi
    systemd_read_unit_definition "$unit" ||
      die "enabled systemd unit definitions could not be inspected"
    if systemd_definition_references_agent_runtime "$SYSTEMD_UNIT_DEFINITION"; then
      die "an enabled systemd unit could automatically start agent-wechat"
    fi
    case "$unit" in
      *.timer) systemd_inspect_single_activation "$unit" Unit timer ;;
      *.path) systemd_inspect_single_activation "$unit" Unit path ;;
      *.socket) systemd_inspect_single_activation "$unit" Service socket ;;
      *.target) systemd_inspect_target_dependencies "$unit" ;;
    esac
  done <<< "$enabled_units"

  active_units="$(
    bootstrap_systemctl list-units \
      --type=service,timer,path,socket,target \
      --state=active,activating,reloading \
      --plain --no-legend --no-pager 2>/dev/null
  )" || die "active systemd unit inventory could not be inspected"
  while read -r unit loaded_state active_state sub_state _; do
    [ -n "$unit" ] || continue
    [ "$loaded_state" = loaded ] ||
      die "active systemd unit inventory returned an unexpected load state"
    case "$active_state" in
      active|activating|reloading) ;;
      *) die "active systemd unit inventory returned an unexpected activity state" ;;
    esac
    [ -n "$sub_state" ] ||
      die "active systemd unit inventory returned an incomplete state"
    case "$unit" in
      *.service|*.timer|*.path|*.socket|*.target) ;;
      *) die "active systemd unit inventory returned an unsupported unit type" ;;
    esac
    systemd_unit_name_is_valid "$unit" ||
      die "active systemd unit inventory returned an invalid unit name"
    if systemd_unit_name_references_agent_runtime "$unit"; then
      die "an active systemd unit could supervise agent-wechat"
    fi
    systemd_read_unit_definition "$unit" ||
      die "active systemd unit definitions could not be inspected"
    if systemd_definition_references_agent_runtime "$SYSTEMD_UNIT_DEFINITION"; then
      die "an active systemd unit could supervise agent-wechat"
    fi
    case "$unit" in
      *.timer) systemd_inspect_single_activation "$unit" Unit timer ;;
      *.path) systemd_inspect_single_activation "$unit" Unit path ;;
      *.socket) systemd_inspect_single_activation "$unit" Service socket ;;
      *.target) systemd_inspect_target_dependencies "$unit" ;;
    esac
  done <<< "$active_units"
  pass "systemd and docker.service are ready"
}

execute_docker() {
  local seconds="$1" mode="$2"
  shift 2
  local -a clean=(
    -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH
    -u DOCKER_API_VERSION
    -u COMPOSE_FILE -u COMPOSE_PROFILES -u COMPOSE_ENV_FILES
    -u COMPOSE_PATH_SEPARATOR -u COMPOSE_PROJECT_DIR
    -u COMPOSE_PARALLEL_LIMIT -u COMPOSE_IGNORE_ORPHANS
    -u COMPOSE_REMOVE_ORPHANS -u COMPOSE_STATUS_STDOUT -u COMPOSE_ANSI
    -u COMPOSE_PROGRESS -u COMPOSE_EXPERIMENTAL -u COMPOSE_MENU
    -u DOCKER_CONFIG -u BUILDX_BUILDER -u HTTP_PROXY -u HTTPS_PROXY
    -u ALL_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u all_proxy
    -u no_proxy
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
        "AGENT_WECHAT_IMAGE=$ENV_IMAGE"
        "AGENT_WECHAT_BIND_IP=$ENV_BIND_IP"
        "AGENT_WECHAT_PORT=$ENV_PORT"
        "AGENT_WECHAT_CONTAINER_NAME=$ENV_CONTAINER"
        "COMPOSE_PROJECT_NAME=$ENV_PROJECT"
        "PROXY=$ENV_PROXY"
        "RUST_LOG=$ENV_RUST_LOG"
        "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT"
        "CF_AGENT_WECHAT_ARCHIVE_ROOT=$ARCHIVE_ROOT"
        "CF_AGENT_WECHAT_TOKEN_FILE=$TOKEN_FILE"
      )
      ;;
    gateway)
      clean+=(
        -u AGENT_WECHAT_IMAGE -u AGENT_WECHAT_BIND_IP -u AGENT_WECHAT_PORT
        -u AGENT_WECHAT_CONTAINER_NAME -u CF_AGENT_WECHAT_STORAGE_ROOT
        -u CF_AGENT_WECHAT_RUNTIME_ROOT -u CF_AGENT_WECHAT_ARCHIVE_ROOT
        -u CF_AGENT_WECHAT_TOKEN_FILE -u COMPOSE_PROJECT_NAME -u PROXY -u RUST_LOG
        -u CF_GATEWAY_ENV_FILE -u CF_GATEWAY_IMAGE
        -u CF_GATEWAY_CONFIG_FILE -u CF_GATEWAY_DATABASE_URL
        -u CF_GATEWAY_BIND_IP -u CF_GATEWAY_PORT
        -u CF_GATEWAY_STOP_GRACE_PERIOD -u CF_GATEWAY_LOG_LEVEL
        -u CF_GATEWAY_WORKER_HEARTBEAT_FILE
        -u CF_GATEWAY_WORKER_HEARTBEAT_MAX_AGE
        -u CF_GATEWAY_CONFIG -u CF_AGENT_GATEWAY_DATABASE_URL
        -u CF_GATEWAY_STARTUP_MIGRATION_MODE -u CF_GATEWAY_API_TOKEN
        -u CF_AGENT_GATEWAY_ADMIN_TOKEN -u CF_AGENT_WECHAT_TOKEN
        -u HERMES_API_KEY -u CF_GATEWAY_WORKER_CONCURRENCY
        -u CF_GATEWAY_WORKER_LEASE_SECONDS -u CF_GATEWAY_WORKER_RETRY_LIMIT
        -u CF_GATEWAY_WORKER_HEARTBEAT_INTERVAL_SECONDS
        -u CF_GATEWAY_WORKER_HEARTBEAT_MAX_AGE_SECONDS
        -u CF_GATEWAY_RUNTIME_HEARTBEAT_MAX_AGE_SECONDS
        -u CF_GATEWAY_BIND_ADDRESS -u CF_GATEWAY_LOG_MAX_SIZE
        -u CF_GATEWAY_LOG_MAX_FILES
      )
      assignments+=("CF_GATEWAY_ENV_FILE=$GATEWAY_ENV_FILE")
      ;;
    raw) ;;
    *) die "internal error: invalid Docker execution mode" ;;
  esac

  if [ "$TESTING" != "1" ]; then
    clean=(
      -i HOME=/nonexistent
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      LANG=C.UTF-8 LC_ALL=C.UTF-8
      DOCKER_CONFIG=/nonexistent
    )
  fi
  if [ "$DOCKER_USE_SUDO" -eq 1 ]; then
    [ "$TESTING" != 1 ] ||
      die "testing Docker mocks must never execute through sudo"
    assignments[0]="CF_BOOTSTRAP_DOCKER_VIA_SUDO=1"
    run_with_hard_timeout "$seconds" sudo -n -- /usr/bin/env \
      "${clean[@]}" "${assignments[@]}" "$DOCKER_BIN" "$@"
  else
    run_with_hard_timeout "$seconds" /usr/bin/env \
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

gateway_compose() {
  execute_docker "$COMPOSE_TIMEOUT" gateway compose \
    --env-file "$GATEWAY_ENV_FILE" \
    --project-directory "$GATEWAY_PROJECT_DIR" \
    --project-name "$GATEWAY_PROJECT" \
    --profile worker \
    -f "$GATEWAY_COMPOSE_FILE" "$@"
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
  elif [ "$TESTING" = 1 ]; then
    die "testing Docker mock failed without privilege; sudo fallback is forbidden"
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
    { [ -r "$AGENT_COMPOSE_FILE" ] && [ -r "$AGENT_ENV_FILE" ] &&
      [ -r "$GATEWAY_COMPOSE_FILE" ] && [ -r "$GATEWAY_ENV_FILE" ]; }; then
    return
  fi
  [ "$TESTING" != 1 ] ||
    die "testing Compose fixtures must be readable without sudo"
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

create_auth_token() {
  local temp_file
  temp_file="$(privileged mktemp "${SECRETS_ROOT}/.auth-token.XXXXXX")" ||
    die "temporary Token file could not be created"
  # The positional parameters below are evaluated by privileged /bin/sh.
  # shellcheck disable=SC2016
  if ! privileged /bin/sh -eu -c '
    set +x
    output=$1
    openssl_bin=$2
    "$openssl_bin" rand -hex 32 > "$output"
    chown 0:0 "$output"
    chmod 600 "$output"
  ' bootstrap-token "$temp_file" "$OPENSSL_BIN"; then
    privileged rm -f -- "$temp_file"
    die "auth Token could not be generated"
  fi
  if ! privileged ln -- "$temp_file" "$TOKEN_FILE" 2>/dev/null; then
    if ! path_present "$TOKEN_FILE"; then
      privileged rm -f -- "$temp_file"
      die "auth Token could not be installed atomically"
    fi
  fi
  privileged rm -f -- "$temp_file"
  log "generated root-only API auth Token (content not displayed)"
}

validate_auth_token() {
  local metadata token_status
  if privileged test -L "$TOKEN_FILE" || ! privileged test -f "$TOKEN_FILE"; then
    die "auth Token must be a non-symlink regular file"
  fi
  metadata="$(privileged stat -c '%u:%g:%a:%h' -- "$TOKEN_FILE" 2>/dev/null)" ||
    die "auth Token metadata could not be inspected"
  [ "$metadata" = 0:0:600:1 ] ||
    die "auth Token must be root:root 600 with one hard link"
  # The positional parameters below are evaluated by privileged /bin/sh.
  # shellcheck disable=SC2016
  if privileged /bin/sh -c '
    [ "$(wc -l < "$1")" -eq 1 ] && grep -Eq "^[0-9a-f]{64}$" "$1"
  ' bootstrap-token-check "$TOKEN_FILE"; then
    token_status=0
  else
    token_status=$?
  fi
  [ "$token_status" -eq 0 ] || die "auth Token content is invalid"
  if ! run_privileged_with_hard_timeout "$DOCKER_TIMEOUT" \
    /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /usr/bin/python3 -I "$MANAGEMENT_SOURCE_SECRET_VERIFIER" \
    --token-file "$TOKEN_FILE" \
    --source "$AGENT_COMPOSE_FILE" \
    --source "$AGENT_ENV_FILE" \
    --source "$GATEWAY_COMPOSE_FILE" \
    --source "$GATEWAY_ENV_FILE" >/dev/null 2>&1; then
    die "management source files failed the bounded stable auth-token absence scan"
  fi
}

prepare_management_state() {
  local runtime_present=0 legacy_present=0 storage_device archive_device
  local runtime_parent archive_parent secrets_parent

  ensure_root_directory "storage root" "$STORAGE_ROOT" 755
  ensure_root_directory "archive root" "$ARCHIVE_ROOT" 700
  ensure_root_directory "secrets directory" "$SECRETS_ROOT" 700
  runtime_parent="$(dirname -- "$RUNTIME_ROOT")" ||
    die "runtime parent could not be resolved"
  archive_parent="$(dirname -- "$ARCHIVE_ROOT")" ||
    die "archive parent could not be resolved"
  secrets_parent="$(dirname -- "$SECRETS_ROOT")" ||
    die "secrets parent could not be resolved"
  validate_directory_without_extended_attributes "runtime parent" "$runtime_parent"
  validate_directory_without_extended_attributes "archive parent" "$archive_parent"
  validate_directory_without_extended_attributes "secrets parent" "$secrets_parent"
  if ! path_present "$TOKEN_FILE"; then
    create_auth_token
  fi
  validate_auth_token

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
  pass "management directories and independent root-only Token are ready"
}

attest_agent_compose() {
  agent_compose config --quiet >/dev/null 2>&1 ||
    die "production Compose validation failed or exceeded its hard timeout"
  ATTESTATION_FILE="$(mktemp "${TRUSTED_TMP_ROOT}/cf-agent-wechat-compose.XXXXXX")" ||
    die "temporary Compose attestation file could not be created"
  chmod 600 "$ATTESTATION_FILE"
  agent_compose config --format json >"$ATTESTATION_FILE" 2>/dev/null ||
    die "production Compose JSON render failed or exceeded its hard timeout"

  bootstrap_python_with_timeout "$DOCKER_TIMEOUT" - "$ATTESTATION_FILE" "$ENV_IMAGE" "$ENV_CONTAINER" \
    "$ENV_PROJECT" "$ENV_PORT" "$RUNTIME_ROOT" "$TOKEN_FILE" \
    "$NETWORK_NAME" "$NETWORK_ALIAS" "$ENV_PROXY" "$ENV_RUST_LOG" <<'PY'
import json
import sys

(
    config_path,
    expected_image,
    expected_container,
    expected_project,
    expected_port,
    runtime_root,
    token_file,
    network_name,
    network_alias,
    expected_proxy,
    expected_rust_log,
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
if not isinstance(config.get("services"), dict) or set(config["services"]) != {"agent-wechat"}:
    fail("exactly one approved service is required")


expected_service_keys = {
    "cap_add",
    "container_name",
    "environment",
    "healthcheck",
    "image",
    "logging",
    "networks",
    "ports",
    "restart",
    "security_opt",
    "stop_grace_period",
    "volumes",
}
if set(service) != expected_service_keys:
    fail("service contains an unapproved process or lifecycle override")
if config.get("name") != expected_project:
    fail("project name differs from the approved docker/.env value")
if service.get("image") != expected_image:
    fail("image is not the approved digest-pinned reference")
if service.get("container_name") != expected_container:
    fail("container name differs from the approved docker/.env value")
if service.get("restart") != "no":
    fail("restart policy must be no")
if (
    service.get("security_opt") != ["seccomp=unconfined"]
    or service.get("cap_add") != ["SYS_PTRACE"]
):
    fail("capability or seccomp contract is not exact")
if service.get("privileged") not in (None, False):
    fail("privileged mode is forbidden")
for forbidden_key in ("devices", "device_cgroup_rules", "pid", "ipc", "uts", "userns_mode"):
    if service.get(forbidden_key) not in (None, "", [], {}):
        fail("host namespace or device access is forbidden")
if service.get("stop_grace_period") != "30s":
    fail("stop grace period must be exactly 30s")
environment = service.get("environment")
expected_environment = {
    "AGENT_HOST": "0.0.0.0",
    "AGENT_PORT": "6174",
    "AGENT_DB_PATH": "/data/agent.db",
    "ENABLE_VNC": "0",
    "PROXY": expected_proxy,
    "RUST_LOG": expected_rust_log,
}
if (
    not isinstance(environment, dict)
    or {str(key): str(value) for key, value in environment.items()} != expected_environment
):
    fail("service environment differs from the exact approved values")

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
    bind_options = mount.get("bind")
    if not isinstance(bind_options, dict) or bind_options != {"create_host_path": False}:
        fail(f"{target} bind options differ from the approved set")
    if mount.get("type") != "bind" or mount.get("source") != source:
        fail(f"{target} source is not the approved bind path")
    if bool(mount.get("read_only", False)) != readonly:
        fail(f"{target} read-only contract is invalid")

service_networks = service.get("networks", {})
if set(service_networks) != {network_name}:
    fail("service must attach only to cf-internal")
aliases = service_networks[network_name].get("aliases", [])
if set(aliases) != {network_alias}:
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
if (
    health.get("interval") != "30s"
    or health.get("timeout") != "5s"
    or health.get("retries") != 5
    or health.get("start_period") != "1m30s"
):
    fail("healthcheck timing contract is invalid")

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

bootstrap_gateway_git() {
  local git_bin="/usr/bin/git"

  if [ "$TESTING" = "1" ] && [ ! -x "$git_bin" ]; then
    git_bin="$(command -v git)" || return 127
  fi
  run_with_hard_timeout "$DOCKER_TIMEOUT" /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
    GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 \
    GIT_LITERAL_PATHSPECS=1 GIT_TERMINAL_PROMPT=0 \
    "$git_bin" \
    -c "safe.directory=$GATEWAY_PROJECT_DIR" \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -c core.hooksPath=/dev/null \
    -c core.fileMode=true \
    -c core.symlinks=true \
    -c diff.ignoreSubmodules=none \
    -C "$GATEWAY_PROJECT_DIR" "$@"
}

bootstrap_attest_gateway_checkout() {
  local expected_commit="$1"
  local actual_commit actual_git_dir actual_origin actual_top config_status
  local index_entry index_inventory untracked_inventory

  if [ -L "${GATEWAY_PROJECT_DIR}/.git" ] ||
    [ ! -d "${GATEWAY_PROJECT_DIR}/.git" ]; then
    die "the deployed Gateway checkout must use its exact non-symlink Git directory"
  fi
  actual_top="$(bootstrap_gateway_git rev-parse --show-toplevel 2>/dev/null)" ||
    die "the deployed Gateway checkout root could not be verified"
  [ "$actual_top" = "$GATEWAY_PROJECT_DIR" ] ||
    die "the deployed Gateway checkout root is not the approved project directory"
  actual_git_dir="$(bootstrap_gateway_git rev-parse --absolute-git-dir 2>/dev/null)" ||
    die "the deployed Gateway Git directory could not be verified"
  [ "$actual_git_dir" = "${GATEWAY_PROJECT_DIR}/.git" ] ||
    die "the deployed Gateway Git directory is not the approved checkout metadata"
  actual_commit="$(bootstrap_gateway_git rev-parse --verify HEAD 2>/dev/null)" ||
    die "the deployed Gateway checkout commit could not be verified"
  [ "$actual_commit" = "$expected_commit" ] ||
    die "the deployed Gateway checkout does not match the approved compatible commit"

  if bootstrap_gateway_git config --local --no-includes --name-only \
    --get-regexp '^(include|includeif|url)\.' >/dev/null 2>&1; then
    die "the deployed Gateway repository contains forbidden local Git configuration"
  else
    config_status=$?
    [ "$config_status" -eq 1 ] ||
      die "the deployed Gateway local Git configuration could not be verified"
  fi
  actual_origin="$(bootstrap_gateway_git config --local --no-includes \
    --get-all remote.origin.url 2>/dev/null)" ||
    die "the deployed Gateway repository origin could not be verified"
  case "$actual_origin" in
    "https://github.com/${GATEWAY_PRODUCER_REPOSITORY}"|"https://github.com/${GATEWAY_PRODUCER_REPOSITORY}.git"|"git@github.com:${GATEWAY_PRODUCER_REPOSITORY}.git") ;;
    *) die "the deployed Gateway repository origin is not approved" ;;
  esac

  index_inventory="$(bootstrap_gateway_git ls-files -v -- 2>/dev/null)" ||
    die "the deployed Gateway index flags could not be verified"
  while IFS= read -r index_entry; do
    case "${index_entry:0:1}" in
      [a-z]|S)
        die "the deployed Gateway index contains hidden worktree state"
        ;;
    esac
  done <<< "$index_inventory"

  bootstrap_gateway_git diff-index --cached --quiet \
    --ignore-submodules=none \
    "$expected_commit" -- 2>/dev/null ||
    die "the deployed Gateway tracked index is not clean"
  bootstrap_gateway_git diff-files --quiet \
    --ignore-submodules=none -- 2>/dev/null ||
    die "the deployed Gateway tracked worktree is not clean"
  [ "$GATEWAY_ENV_FILE" = "${GATEWAY_PROJECT_DIR}/.env" ] ||
    die "the deployed Gateway environment is outside its fixed checkout path"
  untracked_inventory="$(bootstrap_gateway_git ls-files --others \
    --directory --no-empty-directory -- 2>/dev/null)" ||
    die "the deployed Gateway untracked inventory could not be verified"
  [ "$untracked_inventory" = ".env" ] ||
    die "the deployed Gateway checkout has files outside the validated environment allowlist"
}

verify_gateway_provenance() {
  local actual_checker_sha actual_gate_sha
  local actual_blob expected_blob relative_path absolute_path

  [ "$TESTING" != "1" ] || return 0
  if ! [[ "$GATEWAY_COMPATIBLE_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    ! [[ "$GATEWAY_CHECKER_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    ! [[ "$GATEWAY_RELEASE_GATE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    die "no compatible Gateway commit, checker digest, and release gate digest have been published for this contract"
  fi
  bootstrap_attest_gateway_checkout "$GATEWAY_COMPATIBLE_COMMIT"

  for relative_path in \
    docker-compose.prod.yml \
    deploy/wechat-runtime-contract.json \
    deploy/check-wechat-worker-heartbeat \
    deploy/wechat-runtime-release-gate; do
    absolute_path="${GATEWAY_PROJECT_DIR}/${relative_path}"
    bootstrap_gateway_git ls-files --error-unmatch -- "$relative_path" \
      >/dev/null 2>&1 ||
      die "Gateway contract artifacts are not tracked by the approved repository"
    expected_blob="$(bootstrap_gateway_git rev-parse \
      "${GATEWAY_COMPATIBLE_COMMIT}:${relative_path}" 2>/dev/null)" ||
      die "Gateway contract artifacts are missing from the approved commit"
    actual_blob="$(bootstrap_gateway_git hash-object -- "$absolute_path" 2>/dev/null)" ||
      die "Gateway contract artifact content could not be verified"
    [ "$actual_blob" = "$expected_blob" ] ||
      die "Gateway contract artifacts differ from the approved commit"
  done
  actual_checker_sha="$(bootstrap_capture_gateway_executable_digest \
    "$GATEWAY_HEARTBEAT_COMMAND")" ||
    die "Gateway checker digest could not be verified"
  [ "$actual_checker_sha" = "$GATEWAY_CHECKER_SHA256" ] ||
    die "Gateway checker digest does not match the approved compatible commit"
  actual_gate_sha="$(bootstrap_capture_gateway_executable_digest \
    "$GATEWAY_RELEASE_GATE_COMMAND")" ||
    die "Gateway release gate digest could not be verified"
  [ "$actual_gate_sha" = "$GATEWAY_RELEASE_GATE_SHA256" ] ||
    die "Gateway release gate digest does not match the approved compatible commit"
}

bootstrap_gateway_verifier_snapshot() {
  local mode="$1"
  local expected_digest="$2"
  local -a clean_env
  shift 2

  case "$mode" in
    digest|execute) ;;
    *) return 1 ;;
  esac
  clean_env=(
    -i
    HOME=/nonexistent
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    LANG=C.UTF-8
    LC_ALL=C.UTF-8
  )
  if [ "$TESTING" = "1" ]; then
    clean_env+=(CF_AGENT_WECHAT_TESTING=1)
  fi

  if [ "$TESTING" = 1 ]; then
    run_with_hard_timeout "$DOCKER_TIMEOUT" \
      /usr/bin/env "${clean_env[@]}" \
      /usr/bin/python3 -I -c "$GATEWAY_VERIFIER_SNAPSHOT_LOADER" \
      gateway-verifier-snapshot "$mode" "$GATEWAY_CONTRACT_VERIFIER" \
      "$expected_digest" "$MANAGEMENT_UID" "$@"
  else
    run_privileged_with_hard_timeout "$DOCKER_TIMEOUT" \
      /usr/bin/env "${clean_env[@]}" \
      /usr/bin/python3 -I -c "$GATEWAY_VERIFIER_SNAPSHOT_LOADER" \
      gateway-verifier-snapshot "$mode" "$GATEWAY_CONTRACT_VERIFIER" \
      "$expected_digest" "$MANAGEMENT_UID" "$@"
  fi
}

bootstrap_capture_gateway_verifier_digest() {
  local digest

  if ! digest="$(
    bootstrap_gateway_verifier_snapshot digest - 2>/dev/null
  )" || ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    die "Gateway contract verifier snapshot could not be validated"
  fi
  printf '%s' "$digest"
}

bootstrap_capture_gateway_executable_digest() {
  local path="$1" digest
  local -a clean_env=(
    -i
    HOME=/nonexistent
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    LANG=C.UTF-8
    LC_ALL=C.UTF-8
  )

  if ! digest="$(
    run_with_hard_timeout "$DOCKER_TIMEOUT" \
      /usr/bin/env "${clean_env[@]}" \
      /usr/bin/python3 -I -c "$GATEWAY_VERIFIER_SNAPSHOT_LOADER" \
      gateway-artifact-snapshot digest "$path" - "$MANAGEMENT_UID" \
      2>/dev/null
  )" || ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  printf '%s' "$digest"
}

verify_gateway_runtime_contract() {
  local checker_sha gate_sha verifier_digest

  verify_gateway_provenance
  checker_sha="$GATEWAY_CHECKER_SHA256"
  gate_sha="$GATEWAY_RELEASE_GATE_SHA256"
  if [ "$TESTING" = "1" ]; then
    checker_sha="$(bootstrap_capture_gateway_executable_digest \
      "$GATEWAY_HEARTBEAT_COMMAND")" ||
      die "Gateway checker digest could not be computed"
    gate_sha="$(bootstrap_capture_gateway_executable_digest \
      "$GATEWAY_RELEASE_GATE_COMMAND")" ||
      die "Gateway release gate digest could not be computed"
  fi
  [[ "$checker_sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "Gateway checker digest is not an approved SHA-256 value"
  [[ "$gate_sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "Gateway release gate digest is not an approved SHA-256 value"
  verifier_digest="$(bootstrap_capture_gateway_verifier_digest)"
  if ! gateway_compose config --format json 2>/dev/null |
    bootstrap_gateway_verifier_snapshot execute "$verifier_digest" \
    --contract-file "$GATEWAY_CONTRACT_FILE" \
    --gateway-env "$GATEWAY_ENV_FILE" \
    --token-file "$TOKEN_FILE" \
    --checker "$GATEWAY_HEARTBEAT_COMMAND" \
    --gate "$GATEWAY_RELEASE_GATE_COMMAND" \
    --service "$GATEWAY_SERVICE" \
    --project "$GATEWAY_PROJECT" \
    --alias "$NETWORK_ALIAS" \
    --port 6174 \
    --max-age "$GATEWAY_HEARTBEAT_MAX_AGE" \
    --producer-repository "$GATEWAY_PRODUCER_REPOSITORY" \
    --checker-sha256 "$checker_sha" \
    --gate-sha256 "$gate_sha" >/dev/null 2>&1; then
    die "Gateway runtime contract or Agent Token agreement could not be verified"
  fi
  pass "Gateway runtime contract v1 and Agent Token agreement are verified"
}

validate_gateway_compose() {
  local services
  gateway_compose config --quiet >/dev/null 2>&1 ||
    die "Gateway Compose validation failed or exceeded its hard timeout"
  services="$(gateway_compose config --services 2>/dev/null)" ||
    die "Gateway service list could not be read"
  printf '%s\n' "$services" | awk -v expected="$GATEWAY_SERVICE" '
    $0 == expected { found = 1 }
    END { exit(found ? 0 : 1) }
  ' || die "Gateway Compose does not define the worker service"
  pass "Gateway Compose/config is readable and defines the worker service"
}

confirm_services_stopped() {
  local running_ids all_ids restart_policy container_id worker_ids
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

  worker_ids="$(gateway_compose ps --status running --quiet "$GATEWAY_SERVICE" 2>/dev/null)" ||
    die "Gateway worker service state could not be queried"
  [ -z "$worker_ids" ] ||
    die "Gateway worker service must be stopped before a fresh runtime is verified"
  pass "agent-wechat and Gateway worker service are stopped"
}

main() {
  reject_environment_overrides
  configure_external_tools
  validate_testing_isolation
  validate_platform_and_tools
  validate_and_normalize_paths
  authorize_privilege
  validate_external_tool_integrity
  validate_docker_socket
  validate_input_path_chains
  validate_repository_inputs
  parse_agent_environment
  validate_agent_environment_metadata_contract
  validate_systemd
  select_local_rootful_docker
  select_compose_configuration_access
  verify_gateway_provenance

  # State created below is management-only and retryable. Runtime data and
  # WeChat HOME are intentionally created only by start-qr-login.sh.
  prepare_management_state
  verify_gateway_runtime_contract
  ensure_network
  attest_agent_compose
  validate_gateway_compose
  confirm_services_stopped

  pass "CF_agent-wechat base deployment preparation is complete"
  printf '%s\n' 'Next step (controlled SSH TTY):'
  printf '%s\n' '  ./scripts/start-qr-login.sh'
}

main "$@"
