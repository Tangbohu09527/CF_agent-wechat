#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
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
GATEWAY_PROJECT_DIR="${TEST_ROOT}/gateway"
GATEWAY_COMPOSE_FILE="${GATEWAY_PROJECT_DIR}/compose.yaml"

install -d -o root -g root -m 755 "${TEST_REPO}/scripts"
install -o root -g root -m 755 \
  "${REPO_ROOT}/scripts/common.sh" \
  "${REPO_ROOT}/scripts/qr-runtime-common.sh" \
  "${REPO_ROOT}/scripts/status.sh" \
  "${REPO_ROOT}/scripts/login.sh" \
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
install -d -o root -g root -m 755 "$GATEWAY_PROJECT_DIR"
printf '%s\n' 'services:' '  agent-wechat: {}' > "$AGENT_COMPOSE_FILE"
printf '%s\n' 'services:' '  wechat-worker: {}' > "$GATEWAY_COMPOSE_FILE"
chmod 644 "$AGENT_COMPOSE_FILE" "$GATEWAY_COMPOSE_FILE"

useradd --create-home --home-dir "$TEST_HOME" --shell /bin/bash "$TEST_USER"
useradd --create-home --home-dir "$NO_SUDO_HOME" --shell /bin/bash "$NO_SUDO_USER"
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
openssl rand -hex 32 > "$TOKEN_FILE"
chown root:root "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
printf 'logged_in\n' > "$STATE_FILE"
reset_audit() {
  : > "$AUDIT_LOG"
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

assert_only_token_sudo() {
  local sudo_count
  sudo_count="$(awk -F '\t' '$1 == "sudo" { count++ } END { print count + 0 }' \
    "$AUDIT_LOG")"
  [ "$sudo_count" -eq 1 ] || fail "$1 used sudo for more than the token read"
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

: > "$LOG_FILE"
printf '%s\n' '{}' > "$SCENARIO_FILE"

assert_secret_permissions() {
  [ "$(stat -c '%U:%G %a' "$SECRETS_DIR")" = "root:root 700" ] || \
    fail "secrets directory permissions changed"
  [ "$(stat -c '%U:%G %a' "$TOKEN_FILE")" = "root:root 600" ] || \
    fail "auth-token permissions changed"
}

assert_file_has_no_token() {
  python3 - "$TOKEN_FILE" "$1" <<'PY'
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes().rstrip(b"\n")
content = Path(sys.argv[2]).read_bytes()
if token in content:
    raise SystemExit(f"token leaked into {sys.argv[2]}")
PY
}

print_redacted_file() {
  python3 - "$TOKEN_FILE" "$1" <<'PY'
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes().rstrip(b"\n")
path = Path(sys.argv[2])
content = path.read_bytes() if path.exists() else b"<missing output>\n"
for sensitive, replacement in (
    (token, b"<redacted-token>"),
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
    CONTAINER_NAME="$TEST_CONTAINER" \
    CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
    CF_AGENT_GATEWAY_COMPOSE_FILE="$GATEWAY_COMPOSE_FILE" \
    CF_AGENT_GATEWAY_PROJECT_DIR="$GATEWAY_PROJECT_DIR" \
    "$@" \
    /bin/bash -c '
cd "$1"
if [ "${CF_TEST_FORCE_QR:-0}" = "1" ]; then
  exec "./scripts/$2" --force-qr
fi
exec "./scripts/$2"
' \
    cf-agent-wechat-test "$TEST_REPO" "$script_name"
}

assert_secret_permissions
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
[ "$(audit_count docker inspect)" -eq 1 ] || \
  fail "non-permission Docker error did not use one ordinary inspect"
[ "$(audit_count sudo docker-inspect)" -eq 0 ] || \
  fail "non-permission Docker error incorrectly used sudo"
assert_no_sudo_python "non-permission Docker error"
printf 'PASS non-permission Docker error does not use sudo\n'

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

reset_audit
STATUS_OUTPUT="${TEST_ROOT}/status.out"
if ! run_script_as "$TEST_USER" status.sh > "$STATUS_OUTPUT" 2>&1; then
  printf '%s\n' 'status.sh failure output (token redacted):' >&2
  print_redacted_file "$STATUS_OUTPUT"
  printf '%s\n' 'status.sh audit log:' >&2
  cat "$AUDIT_LOG" >&2
  fail "ordinary-user status.sh failed"
fi
grep -q 'logged_in' "$STATUS_OUTPUT" || fail "status.sh did not report logged_in"
if grep -q 'account-fixture-not-for-output' "$STATUS_OUTPUT"; then
  fail "status.sh exposed the account identifier"
fi
assert_file_has_no_token "$STATUS_OUTPUT"
assert_secret_permissions
assert_token_read_once "status.sh"
assert_only_token_sudo "successful management script"
assert_no_sudo_python "status.sh"
printf 'PASS root-only token with ordinary-user status.sh\n'

printf '%s\n' '--verbose' > "${TEST_HOME}/.curlrc"
chown "$TEST_USER:$TEST_USER" "${TEST_HOME}/.curlrc"
TRACE_OUTPUT="${TEST_ROOT}/trace.out"
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
  CONTAINER_NAME="$TEST_CONTAINER" \
  CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
  CF_AGENT_GATEWAY_COMPOSE_FILE="$GATEWAY_COMPOSE_FILE" \
  CF_AGENT_GATEWAY_PROJECT_DIR="$GATEWAY_PROJECT_DIR" \
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
run_script_as "$TEST_USER" login.sh > "$LOGIN_SHORT_OUTPUT" 2>&1
grep -q '微信已经登录。' "$LOGIN_SHORT_OUTPUT" || fail "logged_in did not short-circuit"
assert_only_token_sudo "successful management script"
assert_token_read_once "logged-in login.sh"
assert_no_sudo_python "logged-in login.sh"
if grep -Eq '^(POST|WS|EVENT) ' "$LOG_FILE"; then
  fail "logged_in short-circuit called POST or WebSocket"
fi
[ ! -e "${TEST_HOME}/.local/share/cf-agent-wechat/venv" ] || \
  fail "logged_in short-circuit unexpectedly created the venv"
assert_file_has_no_token "$LOGIN_SHORT_OUTPUT"
assert_secret_permissions
printf 'PASS ordinary-user login.sh logged_in short-circuit\n'

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

printf 'logged_out\n' > "$STATE_FILE"
: > "$LOG_FILE"
reset_audit
rm -f "$PAUSE_FILE" "$CONTINUE_FILE"
LOGIN_OUTPUT="${TEST_ROOT}/login.out"
run_script_as "$TEST_USER" login.sh > "$LOGIN_OUTPUT" 2>&1 &
LOGIN_PID=$!
for _attempt in $(seq 1 900); do
  [ -e "$PAUSE_FILE" ] && break
  kill -0 "$LOGIN_PID" 2>/dev/null || {
    cat "$LOGIN_OUTPUT" >&2
    fail "login.sh exited before WebSocket pause"
  }
  sleep 0.1
done
[ -e "$PAUSE_FILE" ] || fail "login.sh did not reach WebSocket login"
assert_user_processes_have_no_token
touch "$CONTINUE_FILE"
if ! wait "$LOGIN_PID"; then
  cat "$LOGIN_OUTPUT" >&2
  fail "ordinary-user login.sh failed"
fi
LOGIN_PID=""
grep -q '请在手机微信确认登录' "$LOGIN_OUTPUT" || fail "phone_confirm was not shown"
grep -q '登录成功。' "$LOGIN_OUTPUT" || fail "login_success was not shown"
assert_only_token_sudo "successful management script"
grep -q '登录状态已确认' "$LOGIN_OUTPUT" || fail "final logged_in state was not confirmed"
assert_token_read_once "logged-out login.sh"
assert_no_sudo_python "logged-out login.sh"
EXPECTED_LOG="${TEST_ROOT}/expected.log"
printf '%s\n' \
  'GET /api/status/auth' \
  'POST /api/status/login' \
  'WS /api/ws/login' \
  'EVENT phone_confirm' \
  'EVENT login_success' \
  'GET /api/status/auth' > "$EXPECTED_LOG"
diff -u "$EXPECTED_LOG" "$LOG_FILE" || fail "login request/event order differs"
assert_file_has_no_token "$LOGIN_OUTPUT"
assert_home_has_no_token
assert_tmp_has_no_token
assert_secret_permissions
printf 'PASS ordinary-user login.sh phone confirmation flow and user-owned venv\n'

printf '%s\n' 'logged_out' > "$STATE_FILE"
printf '%s\n' \
  '{"emit_qr":true,"require_new_account":true,"record_ws_query":true}' \
  > "$SCENARIO_FILE"
: > "$LOG_FILE"
reset_audit
rm -f "$PAUSE_FILE" "$CONTINUE_FILE"
FORCE_OUTPUT="${TEST_ROOT}/force-qr.out"
run_script_as "$TEST_USER" login.sh CF_TEST_FORCE_QR=1 \
  > "$FORCE_OUTPUT" 2>&1 &
LOGIN_PID=$!
for _attempt in $(seq 1 900); do
  [ -e "$PAUSE_FILE" ] && break
  kill -0 "$LOGIN_PID" 2>/dev/null || {
    cat "$FORCE_OUTPUT" >&2
    fail "login.sh --force-qr exited before WebSocket pause"
  }
  sleep 0.1
done
[ -e "$PAUSE_FILE" ] || fail "force-QR login did not reach WebSocket"
touch "$CONTINUE_FILE"
if ! wait "$LOGIN_PID"; then
  cat "$FORCE_OUTPUT" >&2
  fail "ordinary-user login.sh --force-qr failed"
fi
LOGIN_PID=""
grep -q '请使用手机微信扫描二维码' "$FORCE_OUTPUT" || \
  fail "force-QR flow did not render a terminal QR code"
grep -q '登录成功。' "$FORCE_OUTPUT" || \
  fail "force-QR flow did not report login success"
grep -q '^WS /api/ws/login newAccount=true$' "$LOG_FILE" || \
  fail "force-QR WebSocket did not use newAccount=true"
if grep -qi 'logout' "$LOG_FILE"; then
  fail "force-QR flow unexpectedly called logout"
fi
FORCE_EXPECTED_LOG="${TEST_ROOT}/force-expected.log"
printf '%s\n' \
  'GET /api/status/auth' \
  'POST /api/status/login' \
  'WS /api/ws/login newAccount=true' \
  'EVENT qr' \
  'EVENT phone_confirm' \
  'EVENT login_success' \
  'GET /api/status/auth' > "$FORCE_EXPECTED_LOG"
diff -u "$FORCE_EXPECTED_LOG" "$LOG_FILE" || \
  fail "force-QR request/event order differs"
assert_token_read_once "force-QR login.sh"
assert_only_token_sudo "force-QR login.sh"
assert_no_sudo_python "force-QR login.sh"
assert_file_has_no_token "$FORCE_OUTPUT"
if grep -q 'account-fixture-not-for-output' "$FORCE_OUTPUT"; then
  fail "force-QR output exposed the account identifier"
fi
printf '%s\n' '{}' > "$SCENARIO_FILE"
printf 'PASS forced new-device QR rendering and newAccount WebSocket flow\n'

reset_audit
mv "$TOKEN_FILE" "${TOKEN_FILE}.saved"
MISSING_OUTPUT="${TEST_ROOT}/missing.out"
if run_script_as "$TEST_USER" login.sh > "$MISSING_OUTPUT" 2>&1; then
  fail "login.sh unexpectedly accepted a missing token"
fi
grep -q 'token 文件不存在' "$MISSING_OUTPUT" || \
  fail "missing token was not distinguished from a permission failure"
assert_token_read_once "missing-token login.sh"
assert_no_sudo_python "missing-token login.sh"
mv "${TOKEN_FILE}.saved" "$TOKEN_FILE"
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
  /bin/bash -c 'cd "$1" && exec ./scripts/login.sh' \
  cf-agent-wechat-test "$TEST_REPO" \
  > "$NO_SUDO_OUTPUT" 2>&1 </dev/null; then
  fail "login.sh unexpectedly read root-only token without sudo permission"
fi
grep -q '没有可用的 sudo 权限' "$NO_SUDO_OUTPUT" || \
  fail "missing sudo authorization did not produce a clear error"
if grep -q 'token 文件不存在' "$NO_SUDO_OUTPUT"; then
  fail "permission failure was incorrectly reported as a missing token"
fi
assert_file_has_no_token "$NO_SUDO_OUTPUT"
assert_secret_permissions
printf 'PASS explicit no-sudo permission error\n'

printf 'All login management permission tests passed.\n'
