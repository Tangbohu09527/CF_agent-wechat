#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT=""
DEPLOYMENT_DIR="/srv/storage/cf-agent-wechat"
TEST_USER="cfwtest$$"
NO_SUDO_USER="cfwnosudo$$"
MOCK_PID=""
LOGIN_PID=""
CONTAINER_CREATED=0
SECRETS_CREATED=0
TEST_CONTAINER="cf-agent-wechat-permissions-$$"
SUDOERS_FILE="/etc/sudoers.d/${TEST_USER}"
AUDIT_BIN=""
AUDIT_LOG=""
AUDIT_PATH=""
REAL_DOCKER=""
REAL_SUDO=""
GATEWAY_RUNTIME_CONTROL="/opt/cf-agent-gateway/deploy/wechat-runtime-control"
CONTROLLER_STATE_DIR="/opt/cf-agent-gateway/deploy/.wechat-runtime-control-test-state"
CONTROLLER_CREATED=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  set +e
  if [ -n "$LOGIN_PID" ]; then
    kill "$LOGIN_PID" 2>/dev/null
    wait "$LOGIN_PID" 2>/dev/null
  fi
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
  fi
  if [ "$CONTAINER_CREATED" -eq 1 ]; then
    docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1
  fi
  rm -f "$SUDOERS_FILE"
  if [ "$CONTROLLER_CREATED" -eq 1 ]; then
    case "$CONTROLLER_STATE_DIR" in
      /opt/cf-agent-gateway/deploy/.wechat-runtime-control-test-state)
        rm -rf -- "$CONTROLLER_STATE_DIR"
        ;;
    esac
    rm -f -- "$GATEWAY_RUNTIME_CONTROL"
    rmdir /opt/cf-agent-gateway/deploy 2>/dev/null
    rmdir /opt/cf-agent-gateway 2>/dev/null
  fi
  userdel --force --remove "$TEST_USER" >/dev/null 2>&1
  userdel --force --remove "$NO_SUDO_USER" >/dev/null 2>&1
  if [ -n "$TEST_ROOT" ]; then
    rm -rf "$TEST_ROOT"
  fi
  if [ "$SECRETS_CREATED" -eq 1 ]; then
    rm -f "$TOKEN_FILE" "${TOKEN_FILE}.saved"
    rmdir "$SECRETS_DIR" 2>/dev/null
    rmdir "$DEPLOYMENT_DIR" 2>/dev/null
  fi
}
trap cleanup EXIT

if [ "${GITHUB_ACTIONS:-}" != "true" ] || \
  [ "${CF_AGENT_WECHAT_PERMISSION_TEST:-}" != "1" ]; then
  fail "refusing to run outside the disposable CI permission-test environment"
fi
if [ "$(id -u)" -ne 0 ]; then
  fail "this integration test must run as root"
fi
if [ -e "$DEPLOYMENT_DIR" ]; then
  fail "refusing to touch an existing deployment path: ${DEPLOYMENT_DIR}"
fi
if id "$TEST_USER" >/dev/null 2>&1 || id "$NO_SUDO_USER" >/dev/null 2>&1; then
  fail "temporary test user already exists"
fi
if [ -e "$SUDOERS_FILE" ]; then
  fail "temporary sudoers file already exists: ${SUDOERS_FILE}"
fi
if [ -e "$GATEWAY_RUNTIME_CONTROL" ] || [ -L "$GATEWAY_RUNTIME_CONTROL" ]; then
  fail "refusing to replace an existing fixed Controller path"
fi
if [ -e "$CONTROLLER_STATE_DIR" ] || [ -L "$CONTROLLER_STATE_DIR" ]; then
  fail "refusing to replace an existing Controller test state path"
fi
for command_name in docker openssl python3 sudo useradd visudo; do
  command -v "$command_name" >/dev/null 2>&1 || fail "missing command: ${command_name}"
done
REAL_DOCKER="$(command -v docker)"
REAL_SUDO="$(command -v sudo)"

TEST_ROOT="$(mktemp -d /tmp/cf-agent-wechat-permissions.XXXXXX)"
chmod 755 "$TEST_ROOT"
TEST_REPO="${TEST_ROOT}/repo"
TEST_HOME="${TEST_ROOT}/home"
NO_SUDO_HOME="${TEST_ROOT}/no-sudo-home"
SECRETS_DIR="${DEPLOYMENT_DIR}/secrets"
TOKEN_FILE="${SECRETS_DIR}/auth-token"
STATE_FILE="${TEST_ROOT}/state"
LOG_FILE="${TEST_ROOT}/mock.log"
READY_FILE="${TEST_ROOT}/mock.ready"
PAUSE_FILE="${TEST_ROOT}/ws.pause"
CONTINUE_FILE="${TEST_ROOT}/ws.continue"
SCENARIO_FILE="${TEST_ROOT}/scenario.json"
AUDIT_BIN="${TEST_ROOT}/audit-bin"
AUDIT_LOG="${TEST_ROOT}/audit.log"
AUDIT_PATH="${AUDIT_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
AGENT_COMPOSE_FILE="${TEST_ROOT}/agent-compose.yaml"
AGENT_ENV_FILE="${TEST_ROOT}/agent.env"
AGENT_ENV_SENTINEL="agent-env-fixture-sensitive-permissions-$$"
AGENT_STATE_FILE="${TEST_ROOT}/agent-state"

install -d -o root -g root -m 755 "${TEST_REPO}/scripts" "${TEST_REPO}/docker"
install -o root -g root -m 755 \
  "${REPO_ROOT}/scripts/common.sh" \
  "${REPO_ROOT}/scripts/qr-runtime-common.sh" \
  "${REPO_ROOT}/scripts/gateway-controller-common.sh" \
  "${REPO_ROOT}/scripts/status.sh" \
  "${REPO_ROOT}/scripts/login.sh" \
  "${REPO_ROOT}/scripts/start-qr-login.sh" \
  "${REPO_ROOT}/scripts/qr_login.py" \
  "${TEST_REPO}/scripts/"
install -o root -g root -m 644 \
  "${REPO_ROOT}/scripts/requirements.txt" \
  "${TEST_REPO}/scripts/requirements.txt"
install -d -o root -g root -m 755 "$AUDIT_BIN"
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/audit_docker.sh" "${AUDIT_BIN}/docker"
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/audit_sudo.sh" "${AUDIT_BIN}/sudo"
install -d -o root -g root -m 755 /opt/cf-agent-gateway/deploy
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/mock_gateway_runtime_control.sh" \
  "$GATEWAY_RUNTIME_CONTROL"
CONTROLLER_CREATED=1
install -d -o root -g root -m 755 "$CONTROLLER_STATE_DIR"
: > "$CONTROLLER_STATE_DIR/controller.log"
: > "$CONTROLLER_STATE_DIR/mutations.log"
printf '%s\n' '1' > "$CONTROLLER_STATE_DIR/gateway_running"
printf '%s\n' 'true' > "$CONTROLLER_STATE_DIR/token_contract_valid"
printf '%s\n' 'healthy' > "$CONTROLLER_STATE_DIR/worker_health"
printf '%s\n' 'healthy' > "$CONTROLLER_STATE_DIR/delivery_health"
printf '%s\n' 'services:' '  agent-wechat: {}' > "$AGENT_COMPOSE_FILE"
printf '%s\n' \
  'COMPOSE_PROJECT_NAME=cf-agent-wechat' \
  "AGENT_WECHAT_IMAGE=ghcr.io/example/agent-wechat@sha256:$(printf '%064d' 0)" \
  "AGENT_WECHAT_CONTAINER_NAME=$TEST_CONTAINER" \
  'CF_AGENT_WECHAT_STORAGE_ROOT=/srv/storage/cf-agent-wechat' \
  'CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/storage/cf-agent-wechat/runtime' \
  'CF_AGENT_WECHAT_ARCHIVE_ROOT=/srv/storage/cf-agent-wechat/session-archive' \
  'AGENT_WECHAT_BIND_IP=127.0.0.1' \
  'AGENT_WECHAT_PORT=6174' \
  "PROXY=http://${AGENT_ENV_SENTINEL}.invalid:8080" \
  'RUST_LOG=info' > "$AGENT_ENV_FILE"
chown root:root "$AGENT_COMPOSE_FILE" "$AGENT_ENV_FILE"
chmod 600 "$AGENT_COMPOSE_FILE" "$AGENT_ENV_FILE"
printf '%s\n' 'running' > "$AGENT_STATE_FILE"

useradd --create-home --home-dir "$TEST_HOME" --shell /bin/bash "$TEST_USER"
useradd --create-home --home-dir "$NO_SUDO_HOME" --shell /bin/bash "$NO_SUDO_USER"
chown "$TEST_USER:$TEST_USER" "$AGENT_STATE_FILE" \
  "$CONTROLLER_STATE_DIR/controller.log" \
  "$CONTROLLER_STATE_DIR/mutations.log"
chmod 600 "$AGENT_STATE_FILE" \
  "$CONTROLLER_STATE_DIR/controller.log" \
  "$CONTROLLER_STATE_DIR/mutations.log"
: > "$AUDIT_LOG"
chown "$TEST_USER:$TEST_USER" "$AUDIT_LOG"
chmod 600 "$AUDIT_LOG"
if id -nG "$TEST_USER" | tr ' ' '\n' | grep -qx docker; then
  fail "test user must not belong to the docker group"
fi
printf '%s ALL=(root) NOPASSWD: ALL\n' "$TEST_USER" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

SECRETS_CREATED=1
install -d -o root -g root -m 755 "$DEPLOYMENT_DIR"
install -d -o root -g root -m 700 "$SECRETS_DIR"
umask 077
TOKEN_VALUE="$(openssl rand -hex 32)"
printf '%s' "$TOKEN_VALUE" > "$TOKEN_FILE"
unset TOKEN_VALUE
chown 10001:10001 "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
printf 'logged_in\n' > "$STATE_FILE"
reset_audit() {
  if [ -s "$AUDIT_LOG" ] &&
    grep -Fq -- "$AGENT_ENV_SENTINEL" "$AUDIT_LOG"; then
    fail "agent-wechat environment sentinel leaked into the audit log"
  fi
  : > "$AUDIT_LOG"
  rm -f -- \
    "$CONTROLLER_STATE_DIR/contract_mode" \
    "$CONTROLLER_STATE_DIR/stop_mode" \
    "$CONTROLLER_STATE_DIR/start_mode" \
    "$CONTROLLER_STATE_DIR/status_mode" \
    "$CONTROLLER_STATE_DIR/gateway_ready"
  printf '%s\n' '1' > "$CONTROLLER_STATE_DIR/gateway_running"
  printf '%s\n' 'true' > "$CONTROLLER_STATE_DIR/token_contract_valid"
  printf '%s\n' 'healthy' > "$CONTROLLER_STATE_DIR/worker_health"
  printf '%s\n' 'healthy' > "$CONTROLLER_STATE_DIR/delivery_health"
  : > "$CONTROLLER_STATE_DIR/controller.log"
  : > "$CONTROLLER_STATE_DIR/mutations.log"
}

controller_count() {
  awk -v expected="$1" '
    $0 == expected { count++ }
    END { print count + 0 }
  ' "$CONTROLLER_STATE_DIR/controller.log"
}
audit_count() {
  awk -F '\t' -v category="$1" -v kind="$2" '
    $1 == category && $2 == kind { count++ }
    END { print count + 0 }
  ' "$AUDIT_LOG"
}

assert_token_read_once() {
  [ "$(audit_count sudo token-reader)" -eq 1 ] || \
    fail "$1 did not use exactly one sudo token read"
}

assert_sudo_contract() {
  local label="$1" first_sudo

  [ "$(audit_count sudo validate)" -eq 1 ] || \
    fail "$label did not perform exactly one sudo -v authorization"
  first_sudo="$(awk -F '\t' '$1 == "sudo" { print $2 "\t" $3; exit }' \
    "$AUDIT_LOG")"
  [ "$first_sudo" = $'validate\tinteractive' ] || \
    fail "$label did not authorize with sudo -v before operational sudo"
  if awk -F '\t' \
    '$1 == "sudo" && $2 != "validate" && $3 != "noninteractive" { exit 1 }' \
    "$AUDIT_LOG"; then
    :
  else
    fail "$label used operational sudo without -n"
  fi
}

assert_no_sudo_calls() {
  [ "$(awk -F '\t' '$1 == "sudo" { count++ } END { print count + 0 }' \
    "$AUDIT_LOG")" -eq 0 ] || fail "$1 unexpectedly used sudo"
}

assert_no_sudo_python() {
  [ "$(audit_count sudo python-pip)" -eq 0 ] || \
    fail "$1 attempted to run Python or pip through sudo"
}

assert_docker_fallback_order() {
  local calls
  calls="$(awk -F '\t' '
    $1 == "docker" && $2 == "inspect" { print "ordinary" }
    $1 == "sudo" && $2 == "docker-inspect" { print "sudo" }
  ' "$AUDIT_LOG")"
  [ "$calls" = $'ordinary\nsudo' ] || \
    fail "Docker inspect order was not ordinary then sudo"
}

assert_runtime_mock_requires_sudo() {
  local label="$1"
  local error_file
  shift
  error_file="${TEST_ROOT}/runtime-docker-${label}.error"

  if "$REAL_SUDO" -u "$TEST_USER" -H env \
    PATH="$AUDIT_PATH" \
    CF_AUDIT_LOG="$AUDIT_LOG" \
    CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
    CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
    CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
    CF_AUDIT_DOCKER_VIA_SUDO=0 \
    docker "$@" > /dev/null 2> "$error_file"; then
    fail "bare runtime Docker ${label} unexpectedly succeeded"
  fi
  if ! grep -Eqi \
    'permission denied.*docker[.]sock|docker[.]sock.*permission denied' \
    "$error_file"; then
    fail "bare runtime Docker ${label} lacked a socket permission error"
  fi
}

assert_status_sudo_paths() {
  [ "$(audit_count sudo docker-info)" -eq 3 ] || \
    fail "status.sh did not inspect Docker availability, security, and live-restore"
  [ "$(audit_count sudo docker-context)" -eq 2 ] || \
    fail "status.sh did not inspect the Docker context and socket"
  [ "$(audit_count sudo docker-compose)" -eq 2 ] || \
    fail "status.sh used an unexpected Compose query sequence"
  [ "$(audit_count sudo docker-exec)" -eq 2 ] || \
    fail "status.sh did not attest a stable WeChat process"
  [ "$(audit_count sudo docker-inspect)" -eq 2 ] ||
    fail "status.sh did not inspect Agent health and runtime mounts"
  [ "$(controller_count 'gateway controller contract')" -eq 1 ] ||
    fail "status.sh did not validate Controller contract exactly once"
  [ "$(controller_count 'gateway controller status')" -eq 1 ] ||
    fail "status.sh did not query Controller status exactly once"
  assert_token_read_once "status.sh"
  assert_sudo_contract "status.sh"
}

: > "$LOG_FILE"
printf '%s\n' '{}' > "$SCENARIO_FILE"

assert_secret_permissions() {
  [ "$(stat -c '%u:%g %a' "$SECRETS_DIR")" = "0:0 700" ] ||
    fail "secrets directory permissions changed"
  [ "$(stat -c '%u:%g %a' "$TOKEN_FILE")" = "10001:10001 600" ] ||
    fail "auth-token permissions changed"
  [ "$(stat -c '%u:%g %a' "$AGENT_ENV_FILE")" = "0:0 600" ] ||
    fail "agent-wechat environment file permissions changed"
  [ "$(stat -c '%u:%g %a' "$AGENT_COMPOSE_FILE")" = "0:0 600" ] ||
    fail "agent-wechat Compose permissions changed"
  [ ! -L "$GATEWAY_RUNTIME_CONTROL" ] &&
    [ -f "$GATEWAY_RUNTIME_CONTROL" ] &&
    [ -x "$GATEWAY_RUNTIME_CONTROL" ] ||
    fail "Gateway Runtime Controller is not a regular executable"
  [ "$(stat -c '%u:%g:%a:%h' "$GATEWAY_RUNTIME_CONTROL")" = "0:0:755:1" ] ||
    fail "Gateway Runtime Controller metadata changed"
}

assert_file_has_no_token() {
  python3 - "$TOKEN_FILE" "$AGENT_ENV_SENTINEL" "$1" <<'PY'
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes()
agent_env_sentinel = sys.argv[2].encode()
content = Path(sys.argv[3]).read_bytes()
for name, sensitive in (
    ("token", token),
    ("agent-wechat environment sentinel", agent_env_sentinel),
):
    if sensitive in content:
        raise SystemExit(f"{name} leaked into {sys.argv[3]}")
PY
}

print_redacted_file() {
  python3 - "$TOKEN_FILE" "$AGENT_ENV_SENTINEL" "$1" <<'PY'
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes()
agent_env_sentinel = sys.argv[2].encode()
path = Path(sys.argv[3])
content = path.read_bytes() if path.exists() else b"<missing output>\n"
for sensitive, replacement in (
    (token, b"<redacted-token>"),
    (agent_env_sentinel, b"<redacted-agent-env>"),
    (b"account-fixture-not-for-output", b"<redacted-account>"),
    (b"chat-fixture-not-for-output", b"<redacted-chat>"),
):
    content = content.replace(sensitive, replacement)
sys.stderr.buffer.write(content)
PY
}

assert_user_processes_have_no_token() {
  python3 - "$TOKEN_FILE" "$(id -u "$TEST_USER")" <<'PY'
import os
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes().rstrip(b"\n")
target_uid = int(sys.argv[2])
for process in Path("/proc").iterdir():
    if not process.name.isdigit():
        continue
    try:
        if process.stat().st_uid != target_uid:
            continue
    except (FileNotFoundError, PermissionError):
        continue
    for name in ("cmdline", "environ"):
        try:
            content = (process / name).read_bytes()
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if token in content:
            raise SystemExit(f"token leaked into /proc/{process.name}/{name}")
PY
}

assert_home_has_no_token() {
  python3 - "$TOKEN_FILE" "$TEST_HOME" <<'PY'
import os
import stat
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes().rstrip(b"\n")
for root, _directories, files in os.walk(sys.argv[2]):
    for filename in files:
        path = Path(root, filename)
        try:
            if not stat.S_ISREG(path.stat().st_mode):
                continue
            if token in path.read_bytes():
                raise SystemExit(f"token leaked into {path}")
        except (FileNotFoundError, PermissionError, OSError):
            continue
PY
}

assert_tmp_has_no_token() {
  python3 - "$TOKEN_FILE" "$TEST_USER" <<'PY'
import os
import pwd
import stat
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes().rstrip(b"\n")
target_uid = pwd.getpwnam(sys.argv[2]).pw_uid
for root, _directories, files in os.walk("/tmp"):
    for filename in files:
        path = Path(root, filename)
        try:
            metadata = path.stat()
            if metadata.st_uid != target_uid or not stat.S_ISREG(metadata.st_mode):
                continue
            if token in path.read_bytes():
                raise SystemExit(f"token leaked into {path}")
        except (FileNotFoundError, PermissionError, OSError):
            continue
PY
}

run_script_as() {
  local user_name="$1"
  local script_name="$2"
  shift 2
  "$REAL_SUDO" -u "$user_name" -H env \
    API_URL="http://127.0.0.1:${HTTP_PORT}" \
    WS_URL="ws://127.0.0.1:${WS_PORT}/api/ws/login" \
    TOKEN_FILE="$TOKEN_FILE" \
    PYTHON_BIN=python3 \
    LOGIN_CONFIRM_INTERVAL=0 \
    AUTH_TOKEN=exported-sentinel \
    NO_COLOR=1 \
    HTTP_PROXY=http://127.0.0.1:9 \
    http_proxy=http://127.0.0.1:9 \
    NO_PROXY= \
    no_proxy= \
    PATH="$AUDIT_PATH" \
    CF_AUDIT_LOG="$AUDIT_LOG" \
    CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
    CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
    CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
    CF_AUDIT_DOCKER_VIA_SUDO=0 \
    CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
    CONTAINER_NAME="$TEST_CONTAINER" \
    CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
    CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV_FILE" \
    "$@" \
    /bin/bash -c '
cd "$1"
exec "./scripts/$2"
' \
    cf-agent-wechat-test "$TEST_REPO" "$script_name"
}

run_gateway_library_as() {
  local action="$1"
  shift
  "$REAL_SUDO" -u "$TEST_USER" -H env \
    PATH="$AUDIT_PATH" \
    CF_AUDIT_LOG="$AUDIT_LOG" \
    CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
    PYTHON_BIN=python3 \
    COMPOSE_COMMAND_TIMEOUT=1 \
    "$@" \
    /bin/bash -c '
cd "$1"
source scripts/common.sh
source scripts/qr-runtime-common.sh
action=$2
case "$action" in
  contract)
    gateway_validate_runtime_contract
    ;;
  stop)
    gateway_validate_runtime_contract &&
      runtime_authorize_sudo &&
      stop_gateway_workers
    ;;
  start)
    gateway_validate_runtime_contract &&
      runtime_authorize_sudo &&
      start_gateway_workers
    ;;
  summary)
    gateway_validate_runtime_contract &&
      runtime_authorize_sudo &&
      gateway_status_summary
    ;;
  ready)
    gateway_validate_runtime_contract &&
      runtime_authorize_sudo &&
      status_json="$(gateway_runtime_control status 2>/dev/null)" &&
      gateway_status_json_is_ready "$status_json"
    ;;
  *)
    LAST_ERROR="unsupported permission test action"
    false
    ;;
esac
status=$?
if [ "$status" -ne 0 ]; then
  printf "%s\n" "${LAST_ERROR:-Gateway Runtime Contract test action failed.}" >&2
fi
exit "$status"
' cf-agent-wechat-controller-test "$TEST_REPO" "$action"
}

run_gateway_library_root() {
  local action="$1"
  env \
    PATH="$AUDIT_PATH" \
    CF_AUDIT_LOG="$AUDIT_LOG" \
    CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
    PYTHON_BIN=python3 \
    COMPOSE_COMMAND_TIMEOUT=1 \
    /bin/bash -c '
cd "$1"
source scripts/common.sh
source scripts/qr-runtime-common.sh
case "$2" in
  contract)
    gateway_validate_runtime_contract
    ;;
  status)
    gateway_validate_runtime_contract &&
      gateway_runtime_control status
    ;;
  *)
    LAST_ERROR="unsupported root permission test action"
    false
    ;;
esac
status=$?
if [ "$status" -ne 0 ]; then
  printf "%s\n" "${LAST_ERROR:-Gateway Runtime Contract root action failed.}" >&2
fi
exit "$status"
' cf-agent-wechat-controller-root-test "$TEST_REPO" "$action"
}

restore_controller() {
  rm -f -- "$GATEWAY_RUNTIME_CONTROL"
  install -o root -g root -m 755 \
    "${REPO_ROOT}/tests/helpers/mock_gateway_runtime_control.sh" \
    "$GATEWAY_RUNTIME_CONTROL"
}

assert_secret_permissions

reset_audit
run_gateway_library_as contract >/dev/null ||
  fail "ordinary user could not validate Runtime Contract v1"
[ "$(controller_count 'gateway controller contract')" -eq 1 ] ||
  fail "contract operation was not recorded exactly once"
assert_no_sudo_calls "ordinary-user Controller contract validation"
printf 'PASS ordinary user validates fixed Runtime Contract v1 directly\n'

reset_audit
run_gateway_library_as stop >/dev/null ||
  fail "ordinary-user Controller stop failed"
[ "$(cat "$CONTROLLER_STATE_DIR/gateway_running")" = 0 ] ||
  fail "Controller stop did not close the Poll/Delivery gate"
[ "$(audit_count sudo gateway-controller-stop)" -eq 1 ] ||
  fail "ordinary-user stop did not use the controlled sudo Controller path"
assert_sudo_contract "ordinary-user Controller stop"
printf 'PASS ordinary user stops controlled workers through sudo -n\n'

reset_audit
run_gateway_library_as start >/dev/null ||
  fail "ordinary-user Controller start/status failed"
[ "$(controller_count 'gateway controller start')" -eq 1 ] ||
  fail "Controller start was not recorded exactly once"
[ "$(controller_count 'gateway controller status')" -eq 1 ] ||
  fail "Controller status was not checked after start"
[ "$(audit_count sudo gateway-controller-start)" -eq 1 ] ||
  fail "ordinary-user start did not use the controlled sudo Controller path"
[ "$(audit_count sudo gateway-controller-status)" -eq 1 ] ||
  fail "ordinary-user post-start status did not use sudo Controller path"
assert_sudo_contract "ordinary-user Controller start/status"
printf 'PASS ordinary user starts and verifies both controlled workers\n'

reset_audit
READY_SUMMARY="$(run_gateway_library_as summary)" ||
  fail "ready Controller status could not be summarized"
[ "$READY_SUMMARY" = $'true\ttrue\thealthy\thealthy' ] ||
  fail "ready Controller status summary was invalid"
printf 'PASS ready Controller status JSON is accepted\n'

reset_audit
printf '%s\n' false > "$CONTROLLER_STATE_DIR/gateway_ready"
printf '%s\n' stopped > "$CONTROLLER_STATE_DIR/worker_health"
printf '%s\n' stopped > "$CONTROLLER_STATE_DIR/delivery_health"
GATED_SUMMARY="$(run_gateway_library_as summary)" ||
  fail "gated Controller status could not be summarized"
[ "$GATED_SUMMARY" = $'false\ttrue\tstopped\tstopped' ] ||
  fail "gated Controller status summary was invalid"
printf 'PASS gated Controller status JSON remains explicit and fail-closed\n'

for mode in malformed nonzero timeout; do
  reset_audit
  printf '%s\n' "$mode" > "$CONTROLLER_STATE_DIR/contract_mode"
  CONTRACT_ERROR="$TEST_ROOT/controller-contract-$mode.error"
  STARTED=$SECONDS
  if run_gateway_library_as contract > /dev/null 2> "$CONTRACT_ERROR"; then
    fail "Controller contract mode $mode unexpectedly succeeded"
  fi
  ELAPSED=$((SECONDS - STARTED))
  [ "$mode" != timeout ] || [ "$ELAPSED" -le 5 ] ||
    fail "Controller contract timeout exceeded five seconds"
  assert_file_has_no_token "$CONTRACT_ERROR"
done
printf 'PASS malformed, non-zero, and timed-out Controller contracts fail closed\n'

for mode in malformed nonzero; do
  reset_audit
  printf '%s\n' "$mode" > "$CONTROLLER_STATE_DIR/status_mode"
  STATUS_ERROR="$TEST_ROOT/controller-status-$mode.error"
  if run_gateway_library_as summary > /dev/null 2> "$STATUS_ERROR"; then
    fail "Controller status mode $mode unexpectedly succeeded"
  fi
  assert_file_has_no_token "$STATUS_ERROR"
done
printf 'PASS malformed and non-zero Controller status responses fail closed\n'

for state_name in token_contract_valid worker_health delivery_health; do
  reset_audit
  case "$state_name" in
    token_contract_valid) printf '%s\n' false > "$CONTROLLER_STATE_DIR/$state_name" ;;
    *) printf '%s\n' unhealthy > "$CONTROLLER_STATE_DIR/$state_name" ;;
  esac
  READY_ERROR="$TEST_ROOT/controller-ready-$state_name.error"
  if run_gateway_library_as ready > /dev/null 2> "$READY_ERROR"; then
    fail "Controller accepted invalid $state_name"
  fi
  assert_file_has_no_token "$READY_ERROR"
done
printf 'PASS Token Contract, Poll Worker, and Delivery Worker health gate readiness\n'

reset_audit
ROOT_STATUS="$(run_gateway_library_root status)" ||
  fail "root direct Controller status failed"
case "$ROOT_STATUS" in
  *'"ready":true'*) ;;
  *) fail "root direct Controller status did not return ready JSON" ;;
esac
assert_no_sudo_calls "root direct Controller status"
[ "$(controller_count 'gateway controller contract')" -eq 1 ] ||
  fail "root did not validate Controller contract directly"
[ "$(controller_count 'gateway controller status')" -eq 1 ] ||
  fail "root did not query Controller status directly"
printf 'PASS root uses the fixed Controller directly without sudo\n'

reset_audit
rm -f -- "$GATEWAY_RUNTIME_CONTROL"
MISSING_CONTROLLER_ERROR="$TEST_ROOT/controller-missing.error"
if run_gateway_library_root contract > /dev/null 2> "$MISSING_CONTROLLER_ERROR"; then
  fail "missing fixed Controller unexpectedly passed validation"
fi
grep -Fq 'unavailable at the fixed path' "$MISSING_CONTROLLER_ERROR" ||
  fail "missing fixed Controller did not fail closed"
restore_controller

reset_audit
SYMLINK_TARGET="$TEST_ROOT/controller-symlink-target"
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/mock_gateway_runtime_control.sh" \
  "$SYMLINK_TARGET"
rm -f -- "$GATEWAY_RUNTIME_CONTROL"
ln -s -- "$SYMLINK_TARGET" "$GATEWAY_RUNTIME_CONTROL"
SYMLINK_CONTROLLER_ERROR="$TEST_ROOT/controller-symlink.error"
if run_gateway_library_root contract > /dev/null 2> "$SYMLINK_CONTROLLER_ERROR"; then
  fail "symlink fixed Controller unexpectedly passed validation"
fi
grep -Fq 'unavailable at the fixed path' "$SYMLINK_CONTROLLER_ERROR" ||
  fail "symlink fixed Controller did not fail closed"
restore_controller
assert_secret_permissions
printf 'PASS missing and symlink Controller paths fail closed\n'

assert_file_has_no_token "$CONTROLLER_STATE_DIR/controller.log"
assert_file_has_no_token "$CONTROLLER_STATE_DIR/mutations.log"
[ "$(/bin/bash -c 'source "$1"; printf "%s" "$CONTAINER_NAME"' \
  cf-agent-wechat-test "${TEST_REPO}/scripts/common.sh")" = "cf-agent-wechat" ] || \
  fail "default container name is not cf-agent-wechat"
if docker inspect "$TEST_CONTAINER" >/dev/null 2>&1; then
  fail "unique test container already exists: ${TEST_CONTAINER}"
fi
docker run --detach --name "$TEST_CONTAINER" alpine:3.20 sleep 300 >/dev/null
CONTAINER_CREATED=1

DOCKER_ERROR="${TEST_ROOT}/docker-error"
if "$REAL_SUDO" -u "$TEST_USER" -H "$REAL_DOCKER" inspect "$TEST_CONTAINER" \
  > /dev/null 2> "$DOCKER_ERROR"; then
  fail "ordinary docker inspect unexpectedly succeeded"
fi
grep -Eqi 'permission denied|access denied|operation not permitted' "$DOCKER_ERROR" || \
  fail "ordinary docker inspect did not fail with a socket permission error"
[ "$("$REAL_SUDO" -u "$TEST_USER" -H "$REAL_SUDO" -- "$REAL_DOCKER" inspect \
  --format '{{.State.Running}}' "$TEST_CONTAINER")" = "true" ] || \
  fail "sudo docker inspect did not report a running container"

AUDIT_COMMANDS="$("$REAL_SUDO" -u "$TEST_USER" -H env PATH="$AUDIT_PATH" \
  /bin/bash -c 'command -v docker; command -v sudo')"
EXPECTED_AUDIT_COMMANDS="$(printf '%s\n%s' "${AUDIT_BIN}/docker" "${AUDIT_BIN}/sudo")"
[ "$AUDIT_COMMANDS" = "$EXPECTED_AUDIT_COMMANDS" ] || \
  fail "audit wrappers were not selected through PATH"

reset_audit
DETECT_OUTPUT="$("$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CONTAINER_NAME="$TEST_CONTAINER" /bin/bash -c \
  'cd "$1"; source scripts/common.sh; detect_container_status' \
  cf-agent-wechat-test "$TEST_REPO")"
[ "$DETECT_OUTPUT" = 'running' ] || \
  fail "detect_container_status did not use the sudo fallback"
assert_docker_fallback_order
assert_no_sudo_python "Docker permission fallback"
printf 'PASS ordinary then sudo Docker socket permission fallback\n'

reset_audit
COMMON_IDENTITY_OUTPUT="${TEST_ROOT}/common-identity.out"
if ! "$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
  CF_AUDIT_DOCKER_VIA_SUDO=0 \
  CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
  CONTAINER_NAME="$TEST_CONTAINER" /bin/bash -c \
  'cd "$1"; source scripts/common.sh; get_wechat_process_identity' \
  cf-agent-wechat-test "$TEST_REPO" \
  > "$COMMON_IDENTITY_OUTPUT" 2>&1; then
  print_redacted_file "$COMMON_IDENTITY_OUTPUT"
  fail "common WeChat identity check did not use the sudo Docker fallback"
fi
[ "$(cat "$COMMON_IDENTITY_OUTPUT")" = "4242:9001" ] || \
  fail "common WeChat identity check returned an unexpected identity"
[ "$(audit_count sudo docker-exec)" -eq 1 ] || \
  fail "common WeChat identity check did not use exactly one sudo Docker exec"
assert_no_sudo_python "common WeChat identity Docker fallback"
assert_file_has_no_token "$COMMON_IDENTITY_OUTPUT"
printf 'PASS canonical WeChat identity with sudo Docker fallback\n'

reset_audit
if NONPERMISSION_OUTPUT="$("$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CF_AUDIT_DOCKER_MODE=nonpermission \
  CONTAINER_NAME=missing-container /bin/bash -c \
  'cd "$1"; source scripts/common.sh; detect_container_status' \
  cf-agent-wechat-test "$TEST_REPO" 2>&1)"; then
  fail "non-permission Docker error unexpectedly produced a status"
fi
NONPERMISSION_FILE="${TEST_ROOT}/nonpermission.out"
printf '%s\n' "$NONPERMISSION_OUTPUT" > "$NONPERMISSION_FILE"
assert_file_has_no_token "$NONPERMISSION_FILE"
[ "$(audit_count docker inspect)" -eq 1 ] || \
  fail "non-permission Docker error did not use one ordinary inspect"
[ "$(audit_count sudo docker-inspect)" -eq 0 ] || \
  fail "non-permission Docker error incorrectly used sudo"
assert_no_sudo_python "non-permission Docker error"
printf 'PASS non-permission Docker error does not use sudo\n'

reset_audit
assert_runtime_mock_requires_sudo info info
assert_runtime_mock_requires_sudo compose \
  compose --env-file "$AGENT_ENV_FILE" \
  --project-directory "$TEST_REPO" -f "$AGENT_COMPOSE_FILE" \
  ps --all --quiet agent-wechat
assert_runtime_mock_requires_sudo exec exec "$TEST_CONTAINER" true
assert_runtime_mock_requires_sudo inspect inspect "$TEST_CONTAINER"
printf 'PASS runtime Docker mock requires the sudo fallback\n'

reset_audit
CLEANUP_ERROR="${TEST_ROOT}/cleanup.err"
if ! CLEANUP_OUTPUT="$("$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
  CF_AUDIT_DOCKER_VIA_SUDO=0 \
  CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
  CF_AUDIT_AGENT_STATE_FILE="$AGENT_STATE_FILE" \
  CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
  CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV_FILE" \
  CF_AGENT_WECHAT_RUNTIME_ROOT="${TEST_ROOT}/runtime" \
  /bin/bash -c '
cd "$1"
source scripts/common.sh
source scripts/qr-runtime-common.sh
runtime_select_docker
cleanup_failed_agent_container
printf "%s:%s:%s\n" \
  "$AGENT_FAILURE_CLEANUP_ATTEMPTED" \
  "$AGENT_FAILURE_CLEANUP_STOP_RESULT" \
  "$AGENT_FAILURE_CLEANUP_REMOVE_RESULT"
' cf-agent-wechat-test "$TEST_REPO" 2>"$CLEANUP_ERROR")"; then
  print_redacted_file "$CLEANUP_ERROR"
  printf '%s\n' "$CLEANUP_OUTPUT" >&2
  fail "failed-agent cleanup did not use the sudo Docker fallback"
fi
[ "$CLEANUP_OUTPUT" = "true:succeeded:succeeded" ] ||
  fail "failed-agent cleanup returned unexpected results"
[ -s "$CLEANUP_ERROR" ] ||
  fail "failed-agent cleanup did not emit the sudo authorization prompt"
[ "$(cat "$AGENT_STATE_FILE")" = "absent" ] ||
  fail "failed-agent cleanup left a restartable container"
[ "$(audit_count sudo docker-info)" -eq 3 ] ||
  fail "failed-agent cleanup did not inspect Docker security and live-restore"
[ "$(audit_count sudo docker-context)" -eq 2 ] ||
  fail "failed-agent cleanup did not attest the local Docker endpoint"
assert_sudo_contract "failed-agent cleanup"
[ "$(audit_count docker compose-agent-stop)" -eq 1 ] ||
  fail "failed-agent cleanup did not stop the agent container"
[ "$(audit_count docker compose-agent-remove)" -eq 1 ] ||
  fail "failed-agent cleanup did not remove the agent container"
assert_no_sudo_python "failed-agent cleanup"
CLEANUP_OUTPUT_FILE="${TEST_ROOT}/cleanup.out"
printf '%s\n' "$CLEANUP_OUTPUT" > "$CLEANUP_OUTPUT_FILE"
assert_file_has_no_token "$CLEANUP_OUTPUT_FILE"
assert_file_has_no_token "$CLEANUP_ERROR"
assert_file_has_no_token "$AUDIT_LOG"
printf 'PASS failed-agent cleanup with sudo Docker fallback\n'

python3 "${REPO_ROOT}/tests/helpers/mock_agent_wechat.py" \
  --token-file "$TOKEN_FILE" \
  --state-file "$STATE_FILE" \
  --log-file "$LOG_FILE" \
  --ready-file "$READY_FILE" \
  --pause-file "$PAUSE_FILE" \
  --continue-file "$CONTINUE_FILE" \
  --scenario-file "$SCENARIO_FILE" &
MOCK_PID=$!
for _attempt in $(seq 1 100); do
  [ -s "$READY_FILE" ] && break
  kill -0 "$MOCK_PID" 2>/dev/null || fail "mock server exited before ready"
  sleep 0.1
done
[ -s "$READY_FILE" ] || fail "mock server did not become ready"
HTTP_PORT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["http_port"])' "$READY_FILE")"
WS_PORT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ws_port"])' "$READY_FILE")"
sed -i \
  "s|^AGENT_WECHAT_PORT=.*|AGENT_WECHAT_PORT=$HTTP_PORT|" \
  "$AGENT_ENV_FILE"
chmod 600 "$AGENT_ENV_FILE"

reset_audit
STATUS_OUTPUT="${TEST_ROOT}/status.out"
if ! run_script_as "$TEST_USER" status.sh > "$STATUS_OUTPUT" 2>&1; then
  printf '%s\n' 'status.sh failure output (token redacted):' >&2
  print_redacted_file "$STATUS_OUTPUT"
  printf '%s\n' 'status.sh audit log:' >&2
  print_redacted_file "$AUDIT_LOG"
  fail "ordinary-user status.sh failed"
fi
grep -q 'logged_in' "$STATUS_OUTPUT" || fail "status.sh did not report logged_in"
if grep -q 'account-fixture-not-for-output' "$STATUS_OUTPUT"; then
  fail "status.sh exposed the account identifier"
fi
assert_file_has_no_token "$STATUS_OUTPUT"
assert_secret_permissions
assert_status_sudo_paths
printf 'PASS root-only token with ordinary-user status.sh\n'

printf '%s\n' '--verbose' > "${TEST_HOME}/.curlrc"
chown "$TEST_USER:$TEST_USER" "${TEST_HOME}/.curlrc"
TRACE_OUTPUT="${TEST_ROOT}/trace.out"
# The redirect intentionally belongs to the root test harness, not sudo.
# shellcheck disable=SC2024
if sudo -u "$TEST_USER" -H env \
  API_URL="http://127.0.0.1:${HTTP_PORT}" \
  WS_URL="ws://127.0.0.1:${WS_PORT}/api/ws/login" \
  TOKEN_FILE="$TOKEN_FILE" \
  PYTHON_BIN=python3 \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
  CF_AUDIT_DOCKER_VIA_SUDO=0 \
  CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
  CONTAINER_NAME="$TEST_CONTAINER" \
  CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
  CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV_FILE" \
  NO_PROXY=127.0.0.1,localhost \
  /bin/bash -x "${TEST_REPO}/scripts/status.sh" > "$TRACE_OUTPUT" 2>&1; then
  :
else
  printf '%s\n' 'traced status.sh failure output (token redacted):' >&2
  print_redacted_file "$TRACE_OUTPUT"
  fail "traced ordinary-user status.sh failed"
fi
assert_file_has_no_token "$TRACE_OUTPUT"
if grep -q 'Authorization: Bearer' "$TRACE_OUTPUT"; then
  fail "curlrc or shell tracing exposed the Authorization header"
fi
printf 'PASS shell trace and curlrc token protection\n'

: > "$LOG_FILE"
reset_audit
LOGIN_SHORT_OUTPUT="${TEST_ROOT}/login-short.out"
if run_script_as "$TEST_USER" login.sh > "$LOGIN_SHORT_OUTPUT" 2>&1; then
  fail "login.sh unexpectedly bypassed the controlled-terminal fresh QR gate"
fi
grep -q 'compatibility wrapper' "$LOGIN_SHORT_OUTPUT" || \
  fail "login.sh did not identify itself as the compatibility wrapper"
grep -q 'interactive controlled terminal' "$LOGIN_SHORT_OUTPUT" || \
  fail "login.sh did not enter the forced fresh QR terminal gate"
if grep -Eq '^(POST|WS|EVENT) ' "$LOG_FILE"; then
  fail "non-TTY fresh lifecycle unexpectedly reached the Agent login API"
fi
assert_no_sudo_calls "non-TTY compatibility wrapper"
assert_file_has_no_token "$LOGIN_SHORT_OUTPUT"
assert_secret_permissions
printf 'PASS existing logged_in state cannot bypass the fresh QR entrypoint\n'

reset_audit
TOKEN_PROCESS_OUTPUT="${TEST_ROOT}/token-process.out"
TOKEN_PROCESS_READY="${TEST_HOME}/token-process.ready"
"$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  TOKEN_FILE="$TOKEN_FILE" \
  /bin/bash -c '
cd "$1"
source scripts/common.sh
if ! load_auth_token; then
  error "$LAST_ERROR"
  exit 1
fi
: > "$2"
sleep 30
' cf-agent-wechat-test "$TEST_REPO" "$TOKEN_PROCESS_READY" \
  > "$TOKEN_PROCESS_OUTPUT" 2>&1 &
LOGIN_PID=$!
for _attempt in $(seq 1 100); do
  [ -e "$TOKEN_PROCESS_READY" ] && break
  kill -0 "$LOGIN_PID" 2>/dev/null || {
    print_redacted_file "$TOKEN_PROCESS_OUTPUT"
    fail "ordinary-user root-only Token load exited early"
  }
  sleep 0.1
done
[ -e "$TOKEN_PROCESS_READY" ] || fail "ordinary-user Token load did not become ready"
assert_user_processes_have_no_token
kill "$LOGIN_PID"
wait "$LOGIN_PID" 2>/dev/null || true
LOGIN_PID=""
assert_token_read_once "ordinary-user Token load"
assert_sudo_contract "ordinary-user Token load"
assert_no_sudo_python "ordinary-user Token load"
assert_file_has_no_token "$TOKEN_PROCESS_OUTPUT"
printf 'PASS sudo -v then sudo -n root-only Token load without process leakage\n'

reset_audit
ROOT_TOKEN_OUTPUT="${TEST_ROOT}/root-token.out"
if ! env TOKEN_FILE="$TOKEN_FILE" /bin/bash -c '
cd "$1"
source scripts/common.sh
load_auth_token
printf "%s\n" token-loaded
' cf-agent-wechat-test "$TEST_REPO" > "$ROOT_TOKEN_OUTPUT" 2>&1; then
  print_redacted_file "$ROOT_TOKEN_OUTPUT"
  fail "root could not load the root-only Token"
fi
grep -qx 'token-loaded' "$ROOT_TOKEN_OUTPUT" || \
  fail "root Token test returned unexpected output"
assert_no_sudo_calls "root Token load"
assert_file_has_no_token "$ROOT_TOKEN_OUTPUT"
printf 'PASS root reads the protected Token without sudo or disclosure\n'

reset_audit
"$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  PYTHON_BIN=python3 \
  /bin/bash -c \
  'set -e; cd "$1"; source scripts/common.sh; ensure_login_environment' \
  cf-agent-wechat-test "$TEST_REPO" > "${TEST_ROOT}/venv-setup.out" 2>&1
assert_no_sudo_calls "venv setup"
assert_no_sudo_python "venv setup"
VENV_DIR="${TEST_HOME}/.local/share/cf-agent-wechat/venv"
[ -x "${VENV_DIR}/bin/python" ] || fail "default ordinary-user venv was not created"
if find "$VENV_DIR" ! -user "$TEST_USER" -print -quit | grep -q .; then
  fail "venv contains files not owned by the ordinary user"
fi
printf 'PASS default venv setup as ordinary user\n'
assert_home_has_no_token
assert_tmp_has_no_token
assert_secret_permissions
printf 'PASS ordinary-user venv and writable locations contain no Token\n'

reset_audit
mv "$TOKEN_FILE" "${TOKEN_FILE}.saved"
MISSING_OUTPUT="${TEST_ROOT}/missing.out"
if "$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  TOKEN_FILE="$TOKEN_FILE" \
  /bin/bash -c '
cd "$1"
source scripts/common.sh
if ! load_auth_token; then
  error "$LAST_ERROR"
  exit 1
fi
' cf-agent-wechat-test "$TEST_REPO" > "$MISSING_OUTPUT" 2>&1; then
  fail "Token loader unexpectedly accepted a missing root-only Token"
fi
grep -q 'token 文件不存在' "$MISSING_OUTPUT" || \
  fail "missing token was not distinguished from a permission failure"
assert_token_read_once "missing-token load"
assert_sudo_contract "missing-token load"
assert_no_sudo_python "missing-token load"
mv "${TOKEN_FILE}.saved" "$TOKEN_FILE"
assert_file_has_no_token "$MISSING_OUTPUT"
assert_secret_permissions
printf 'PASS missing root-only token distinction\n'

NO_SUDO_OUTPUT="${TEST_ROOT}/no-sudo.out"
if timeout 15s sudo -u "$NO_SUDO_USER" -H env \
  API_URL="http://127.0.0.1:${HTTP_PORT}" \
  WS_URL="ws://127.0.0.1:${WS_PORT}/api/ws/login" \
  TOKEN_FILE="$TOKEN_FILE" \
  PYTHON_BIN=python3 \
  NO_COLOR=1 \
  NO_PROXY=127.0.0.1,localhost \
  no_proxy=127.0.0.1,localhost \
  /bin/bash -c '
cd "$1"
source scripts/common.sh
if ! load_auth_token; then
  error "$LAST_ERROR"
  exit 1
fi
' \
  cf-agent-wechat-test "$TEST_REPO" \
  > "$NO_SUDO_OUTPUT" 2>&1 </dev/null; then
  fail "Token loader unexpectedly read the root-only Token without sudo permission"
fi
grep -q '没有可用的 sudo 权限' "$NO_SUDO_OUTPUT" || \
  fail "missing sudo authorization did not produce a clear error"
if grep -q 'token 文件不存在' "$NO_SUDO_OUTPUT"; then
  fail "permission failure was incorrectly reported as a missing token"
fi
assert_file_has_no_token "$NO_SUDO_OUTPUT"
assert_file_has_no_token "$AUDIT_LOG"
assert_file_has_no_token "$LOG_FILE"
assert_secret_permissions
printf 'PASS explicit no-sudo permission error\n'

reset_audit
ROOT_CONFIG_OUTPUT="${TEST_ROOT}/root-config.out"
ROOT_CONFIG_ERROR="${TEST_ROOT}/root-config.error"
if ! "$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
  CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV_FILE" \
  /bin/bash -c '
cd "$1"
source scripts/common.sh
source scripts/qr-runtime-common.sh
runtime_authorize_sudo
runtime_validate_management_file "$AGENT_COMPOSE_FILE" "agent Compose" "600"
runtime_validate_management_file "$AGENT_ENV_FILE" "agent env" "600"
runtime_load_management_environment
printf "%s\n" "$CONTAINER_NAME"
' cf-agent-wechat-test "$TEST_REPO" > "$ROOT_CONFIG_OUTPUT" 2> "$ROOT_CONFIG_ERROR"; then
  print_redacted_file "$ROOT_CONFIG_ERROR"
  fail "ordinary user could not validate and load root-only management files"
fi
grep -qx "$TEST_CONTAINER" "$ROOT_CONFIG_OUTPUT" ||
  fail "root-only docker/.env was not authoritative for the ordinary user"
assert_sudo_contract "root-only management files"
assert_no_sudo_python "root-only management files"
assert_file_has_no_token "$ROOT_CONFIG_OUTPUT"
assert_file_has_no_token "$ROOT_CONFIG_ERROR"
assert_file_has_no_token "$AUDIT_LOG"
assert_secret_permissions
printf 'PASS ordinary user validates and loads root-only Compose/env files\n'

printf 'All login management permission tests passed.\n'
