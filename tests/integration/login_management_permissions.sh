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
AGENT_ENV_FILE="${TEST_ROOT}/agent.env"
AGENT_ENV_SENTINEL="agent-env-fixture-sensitive-permissions-$$"
GATEWAY_PROJECT_DIR="${TEST_ROOT}/gateway"
GATEWAY_COMPOSE_FILE="${GATEWAY_PROJECT_DIR}/compose.yaml"
GATEWAY_ENV_FILE="${GATEWAY_PROJECT_DIR}/.env"
GATEWAY_ENV_SENTINEL="gateway-env-fixture-sensitive-permissions-$$"
GATEWAY_HEARTBEAT_COMMAND="${GATEWAY_PROJECT_DIR}/check-wechat-worker-heartbeat"
AGENT_STATE_FILE="${TEST_ROOT}/agent-state"

install -d -o root -g root -m 755 "${TEST_REPO}/scripts"
install -o root -g root -m 755 \
  "${REPO_ROOT}/scripts/common.sh" \
  "${REPO_ROOT}/scripts/qr-runtime-common.sh" \
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
install -d -o root -g root -m 755 "$GATEWAY_PROJECT_DIR"
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
  "PROXY=http://${AGENT_ENV_SENTINEL}.invalid" \
  'RUST_LOG=info' > "$AGENT_ENV_FILE"
printf '%s\n' 'services:' '  wechat-worker: {}' > "$GATEWAY_COMPOSE_FILE"
chmod 600 "$AGENT_COMPOSE_FILE" "$GATEWAY_COMPOSE_FILE"
printf '%s\n' "$GATEWAY_ENV_SENTINEL" > "$GATEWAY_ENV_FILE"
chown root:root "$AGENT_ENV_FILE" "$GATEWAY_ENV_FILE"
chmod 600 "$AGENT_ENV_FILE" "$GATEWAY_ENV_FILE"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$GATEWAY_HEARTBEAT_COMMAND"
chown root:root "$GATEWAY_HEARTBEAT_COMMAND"
chmod 755 "$GATEWAY_HEARTBEAT_COMMAND"
printf '%s\n' 'running' > "$AGENT_STATE_FILE"

useradd --create-home --home-dir "$TEST_HOME" --shell /bin/bash "$TEST_USER"
useradd --create-home --home-dir "$NO_SUDO_HOME" --shell /bin/bash "$NO_SUDO_USER"
chown "$TEST_USER:$TEST_USER" "$AGENT_STATE_FILE"
chmod 600 "$AGENT_STATE_FILE"
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
  if [ -s "$AUDIT_LOG" ] &&
    grep -Fq -- "$AGENT_ENV_SENTINEL" "$AUDIT_LOG"; then
    fail "agent-wechat environment sentinel leaked into the audit log"
  fi
  if [ -s "$AUDIT_LOG" ] &&
    grep -Fq -- "$GATEWAY_ENV_SENTINEL" "$AUDIT_LOG"; then
    fail "Gateway environment sentinel leaked into the audit log"
  fi
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
    CF_AUDIT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
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
  [ "$(audit_count sudo docker-compose)" -eq 4 ] || \
    fail "status.sh used an unexpected Compose query sequence"
  [ "$(audit_count sudo docker-exec)" -eq 2 ] || \
    fail "status.sh did not attest a stable WeChat process"
  [ "$(audit_count sudo docker-inspect)" -eq 3 ] || \
    fail "status.sh did not inspect Agent/Worker health and runtime mounts"
  assert_token_read_once "status.sh"
  assert_sudo_contract "status.sh"
}

: > "$LOG_FILE"
printf '%s\n' '{}' > "$SCENARIO_FILE"

assert_secret_permissions() {
  [ "$(stat -c '%U:%G %a' "$SECRETS_DIR")" = "root:root 700" ] || \
    fail "secrets directory permissions changed"
  [ "$(stat -c '%U:%G %a' "$TOKEN_FILE")" = "root:root 600" ] || \
    fail "auth-token permissions changed"
  [ "$(stat -c '%U:%G %a' "$AGENT_ENV_FILE")" = "root:root 600" ] || \
    fail "agent-wechat environment file permissions changed"
  [ "$(stat -c '%U:%G %a' "$AGENT_COMPOSE_FILE")" = "root:root 600" ] || \
    fail "agent-wechat Compose permissions changed"
  [ "$(stat -c '%U:%G %a' "$GATEWAY_COMPOSE_FILE")" = "root:root 600" ] || \
    fail "Gateway Compose permissions changed"
  [ "$(stat -c '%U:%G %a' "$GATEWAY_ENV_FILE")" = "root:root 600" ] || \
    fail "Gateway environment file permissions changed"
  [ "$(stat -c '%U:%G %a' "$GATEWAY_HEARTBEAT_COMMAND")" = "root:root 755" ] || \
    fail "Gateway heartbeat checker permissions changed"
}

assert_file_has_no_token() {
  python3 - "$TOKEN_FILE" "$AGENT_ENV_SENTINEL" \
    "$GATEWAY_ENV_SENTINEL" "$1" <<'PY'
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes().rstrip(b"\n")
agent_env_sentinel = sys.argv[2].encode()
gateway_env_sentinel = sys.argv[3].encode()
content = Path(sys.argv[4]).read_bytes()
for name, sensitive in (
    ("token", token),
    ("agent-wechat environment sentinel", agent_env_sentinel),
    ("Gateway environment sentinel", gateway_env_sentinel),
):
    if sensitive in content:
        raise SystemExit(f"{name} leaked into {sys.argv[4]}")
PY
}

print_redacted_file() {
  python3 - "$TOKEN_FILE" "$AGENT_ENV_SENTINEL" \
    "$GATEWAY_ENV_SENTINEL" "$1" <<'PY'
import sys
from pathlib import Path

token = Path(sys.argv[1]).read_bytes().rstrip(b"\n")
agent_env_sentinel = sys.argv[2].encode()
gateway_env_sentinel = sys.argv[3].encode()
path = Path(sys.argv[4])
content = path.read_bytes() if path.exists() else b"<missing output>\n"
for sensitive, replacement in (
    (token, b"<redacted-token>"),
    (agent_env_sentinel, b"<redacted-agent-env>"),
    (gateway_env_sentinel, b"<redacted-gateway-env>"),
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
    CF_AUDIT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
    CONTAINER_NAME="$TEST_CONTAINER" \
    CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
    CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV_FILE" \
    CF_AGENT_GATEWAY_COMPOSE_FILE="$GATEWAY_COMPOSE_FILE" \
    CF_AGENT_GATEWAY_PROJECT_DIR="$GATEWAY_PROJECT_DIR" \
    CF_AGENT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
    CF_AGENT_GATEWAY_HEARTBEAT_COMMAND="$GATEWAY_HEARTBEAT_COMMAND" \
    "$@" \
    /bin/bash -c '
cd "$1"
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
COMMON_IDENTITY_OUTPUT="${TEST_ROOT}/common-identity.out"
if ! "$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
  CF_AUDIT_DOCKER_VIA_SUDO=0 \
  CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
  CF_AUDIT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
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
if ! CLEANUP_OUTPUT="$("$REAL_SUDO" -u "$TEST_USER" -H env \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
  CF_AUDIT_DOCKER_VIA_SUDO=0 \
  CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
  CF_AUDIT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
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
' cf-agent-wechat-test "$TEST_REPO" 2>&1)"; then
  printf '%s\n' "$CLEANUP_OUTPUT" >&2
  fail "failed-agent cleanup did not use the sudo Docker fallback"
fi
[ "$CLEANUP_OUTPUT" = "true:succeeded:succeeded" ] ||
  fail "failed-agent cleanup returned unexpected results"
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
  CF_AUDIT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
  CONTAINER_NAME="$TEST_CONTAINER" \
  CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
  CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV_FILE" \
  CF_AGENT_GATEWAY_COMPOSE_FILE="$GATEWAY_COMPOSE_FILE" \
  CF_AGENT_GATEWAY_PROJECT_DIR="$GATEWAY_PROJECT_DIR" \
  CF_AGENT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
  CF_AGENT_GATEWAY_HEARTBEAT_COMMAND="$GATEWAY_HEARTBEAT_COMMAND" \
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
  CF_AGENT_GATEWAY_COMPOSE_FILE="$GATEWAY_COMPOSE_FILE" \
  CF_AGENT_GATEWAY_PROJECT_DIR="$GATEWAY_PROJECT_DIR" \
  CF_AGENT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
  /bin/bash -c '
cd "$1"
source scripts/common.sh
source scripts/qr-runtime-common.sh
runtime_authorize_sudo
runtime_validate_management_file "$AGENT_COMPOSE_FILE" "agent Compose" "600"
runtime_validate_management_file "$AGENT_ENV_FILE" "agent env" "600"
runtime_load_management_environment
runtime_validate_management_file "$GATEWAY_COMPOSE_FILE" "Gateway Compose" "600"
runtime_validate_management_file "$GATEWAY_ENV_FILE" "Gateway env" "600"
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
