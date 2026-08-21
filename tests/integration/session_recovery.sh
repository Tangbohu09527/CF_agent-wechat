#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT=""
STATUS_PID=""
LOCK_PID=""
TEST_PYTHON=""
HOST_KERNEL=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_status_field() {
  local label="$1" expected="$2" file="$3"

  awk -v label="$label:" -v expected="  $expected" '
    $0 == label {
      if (getline > 0 && $0 == expected) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file" || fail "$label did not report $expected"
}

cleanup() {
  set +e
  if [ -n "$STATUS_PID" ]; then
    kill "$STATUS_PID" 2>/dev/null
    wait "$STATUS_PID" 2>/dev/null
  fi
  if [ -n "$LOCK_PID" ]; then
    kill "$LOCK_PID" 2>/dev/null
    wait "$LOCK_PID" 2>/dev/null
  fi
  if [ -n "$TEST_ROOT" ]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

for command_name in awk bash grep install mktemp sleep uname; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "missing command: $command_name"
done
HOST_KERNEL="$(uname -s)"
if [ "$HOST_KERNEL" = Linux ] && ! command -v flock >/dev/null 2>&1; then
  fail "missing command on Linux: flock"
fi

for candidate in "${PYTHON_BIN:-}" python3 python; do
  [ -n "$candidate" ] || continue
  if command -v "$candidate" >/dev/null 2>&1 &&
    "$candidate" -c 'import json' >/dev/null 2>&1; then
    TEST_PYTHON="$candidate"
    break
  fi
done
[ -n "$TEST_PYTHON" ] || fail "missing executable Python 3"


TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cf-wechat-recovery.XXXXXX")"
RUNTIME_ROOT="${TEST_ROOT}/runtime"
MOCK_BIN="${TEST_ROOT}/bin"
DOCKER_STATE="${TEST_ROOT}/docker.state"
API_STATE="${TEST_ROOT}/api.state"
AUTH_STATE="${TEST_ROOT}/auth.state"
REQUEST_LOG="${TEST_ROOT}/requests.log"
STATUS_OUTPUT="${TEST_ROOT}/status.out"
LOGIN_OUTPUT="${TEST_ROOT}/login.out"
TOKEN_FILE_PATH="${RUNTIME_ROOT}/secrets/auth-token"

install -d -m 755 "$MOCK_BIN"
if [ "$(/usr/bin/uname -s)" = "Linux" ]; then
  install -d -m 700 "$RUNTIME_ROOT/secrets"
else
  install -d -m 755 "$RUNTIME_ROOT/secrets"
fi
install -m 755 "${REPO_ROOT}/tests/helpers/mock_management_docker.sh" \
  "${MOCK_BIN}/docker"
install -m 755 "${REPO_ROOT}/tests/helpers/mock_management_curl.sh" \
  "${MOCK_BIN}/curl"
printf '%s\n' 'fixture-token-for-recovery-tests' > "$TOKEN_FILE_PATH"
chmod 600 "$TOKEN_FILE_PATH"
: > "$REQUEST_LOG"

run_status() {
  env -u TOKEN_FILE -u CF_AGENT_WECHAT_RUNTIME_ROOT \
    CF_RUNTIME_ROOT="$RUNTIME_ROOT" \
    API_URL="http://127.0.0.1:6174" \
    CURL_BIN="${MOCK_BIN}/curl" \
    DOCKER_BIN="${MOCK_BIN}/docker" \
    PYTHON_BIN="$TEST_PYTHON" \
    STATUS_WAIT_TIMEOUT=8 \
    STATUS_POLL_INTERVAL=1 \
    CF_TEST_DOCKER_STATE_FILE="$DOCKER_STATE" \
    CF_TEST_API_STATE_FILE="$API_STATE" \
    CF_TEST_AUTH_STATE_FILE="$AUTH_STATE" \
    CF_TEST_TOKEN_FILE="$TOKEN_FILE_PATH" \
    CF_TEST_REQUEST_LOG="$REQUEST_LOG" \
    AUTH_TOKEN=must-be-cleared \
    bash "${REPO_ROOT}/scripts/status.sh" "$@"
}

run_login() {
  env -u TOKEN_FILE -u CF_AGENT_WECHAT_RUNTIME_ROOT \
    CF_RUNTIME_ROOT="$RUNTIME_ROOT" \
    API_URL="http://127.0.0.1:6174" \
    CURL_BIN="${MOCK_BIN}/curl" \
    PYTHON_BIN="$TEST_PYTHON" \
    CF_TEST_API_STATE_FILE="$API_STATE" \
    CF_TEST_AUTH_STATE_FILE="$AUTH_STATE" \
    CF_TEST_TOKEN_FILE="$TOKEN_FILE_PATH" \
    CF_TEST_REQUEST_LOG="$REQUEST_LOG" \
    AUTH_TOKEN=must-be-cleared \
    bash "${REPO_ROOT}/scripts/login.sh" "$@"
}

assert_token_rejected() {
  local label="$1" expected="$2"

  if run_login > "$LOGIN_OUTPUT" 2>&1; then
    fail "$label token unexpectedly succeeded"
  fi
  grep -q "$expected" "$LOGIN_OUTPUT" ||
    fail "$label token error was not actionable"
}

for invalid_session in other $'default\001injected'; do
  session_error="$(
    SESSION_ID="$invalid_session" bash -c \
      'source "$1"; validate_configuration || printf "%s" "$LAST_ERROR"' \
      cf-wechat-recovery "$REPO_ROOT/scripts/common.sh"
  )"
  case "$session_error" in
    *'生产 SESSION_ID 必须是 default'*) ;;
    *) fail "shell management scripts accepted nondefault SESSION_ID" ;;
  esac
done
printf 'PASS SESSION_ID is fixed to default\n'

for escaped_control in '\u0001' '\u001f' '\u007f'; do
  auth_parse_output="$(
    PYTHON_BIN="$TEST_PYTHON" bash -c '
      source "$1"
      if parse_auth_response "$2"; then
        printf ACCEPTED
      else
        printf REJECTED
      fi
    ' cf-wechat-recovery "$REPO_ROOT/scripts/common.sh" \
      "{\"status\":\"logged${escaped_control}in\"}" 2>&1
  )"
  case "$auth_parse_output" in
    *REJECTED*) ;;
    *) fail "auth parser accepted control escape $escaped_control" ;;
  esac
done
printf 'PASS auth status rejects all C0 and DEL controls\n'

default_wait="$(
  bash -c 'source "$1"; printf "%s" "$STATUS_WAIT_TIMEOUT"' \
    cf-wechat-recovery "$REPO_ROOT/scripts/common.sh"
)"
[ "$default_wait" = 180 ] || fail "default STATUS_WAIT_TIMEOUT is not 180 seconds"
printf 'PASS status wait default is 180 seconds\n'
printf '%s\n' 'stopped none' > "$DOCKER_STATE"
printf '%s\n' 'unreachable' > "$API_STATE"
printf '%s\n' 'logged_in' > "$AUTH_STATE"
run_status --wait > "$STATUS_OUTPUT" 2>&1 &
STATUS_PID=$!

sleep 1
printf '%s\n' 'running starting' > "$DOCKER_STATE"
sleep 1
printf '%s\n' 'reachable' > "$API_STATE"
sleep 1
printf '%s\n' 'running healthy' > "$DOCKER_STATE"

if ! wait "$STATUS_PID"; then
  STATUS_PID=""
  cat "$STATUS_OUTPUT" >&2
  fail "status --wait did not recover after the simulated restart"
fi
STATUS_PID=""
assert_status_field "Container" "running" "$STATUS_OUTPUT"
assert_status_field "Container Health" "healthy" "$STATUS_OUTPUT"
assert_status_field "API" "reachable" "$STATUS_OUTPUT"
assert_status_field "Auth" "logged_in" "$STATUS_OUTPUT"
assert_status_field "Session" "active" "$STATUS_OUTPUT"
if grep -q 'account-must-not-print' "$STATUS_OUTPUT"; then
  fail "status output exposed the account identifier"
fi
grep -q '^GET health$' "$REQUEST_LOG" ||
  fail "status recovery did not probe the health API"
grep -q '^GET auth$' "$REQUEST_LOG" ||
  fail "status recovery did not probe the auth API"
printf 'PASS simulated restart state: stopped/starting -> running/healthy\n'
printf 'PASS simulated API recovery: unreachable -> reachable\n'

printf '%s\n' 'running unhealthy' > "$DOCKER_STATE"
if run_status > "$STATUS_OUTPUT" 2>&1; then
  fail "status unexpectedly accepted an unhealthy container"
else
  status_code=$?
fi
[ "$status_code" -eq 3 ] ||
  fail "unhealthy container returned ${status_code}, expected 3"
assert_status_field "Container Health" "unhealthy" "$STATUS_OUTPUT"
printf 'PASS unhealthy container is rejected with exit 3\n'

printf '%s\n' 'running healthy' > "$DOCKER_STATE"
printf '%s\n' 'logged_out' > "$AUTH_STATE"
if run_status > "$STATUS_OUTPUT" 2>&1; then
  fail "status unexpectedly accepted logged_out"
else
  status_code=$?
fi
[ "$status_code" -eq 2 ] ||
  fail "logged_out returned ${status_code}, expected 2"
assert_status_field "Session" "login_required" "$STATUS_OUTPUT"
grep -q './scripts/login.sh' "$STATUS_OUTPUT" ||
  fail "logged_out did not provide the login recovery command"
printf 'PASS logged_out session is actionable with exit 2\n'

: > "$REQUEST_LOG"
if run_login > "$LOGIN_OUTPUT" 2>&1; then
  fail "logged_out login unexpectedly accepted noninteractive stdout"
fi
grep -q 'stdout 连接交互式 TTY' "$LOGIN_OUTPUT" ||
  fail "noninteractive fresh login error was not actionable"
[ "$(cat "$REQUEST_LOG")" = 'GET auth' ] ||
  fail "noninteractive fresh login advanced past the initial auth check"
printf 'PASS fresh login rejects noninteractive stdout before setup or WebSocket\n'

printf '%s\n' 'logged_in' > "$AUTH_STATE"
: > "$REQUEST_LOG"
run_login > "$LOGIN_OUTPUT" 2>&1 ||
  fail "login.sh did not reuse the active persisted session"
grep -q '持久化 session 可继续使用' "$LOGIN_OUTPUT" ||
  fail "login.sh did not report the session reuse short-circuit"
[ "$(cat "$REQUEST_LOG")" = 'GET auth' ] ||
  fail "session reuse called POST login or another unexpected API"
printf 'PASS login/session recovery: logged_in short-circuits without POST or WebSocket\n'

: > "$TOKEN_FILE_PATH"
assert_token_rejected 'empty' '只包含一行非空 token'
printf 'first\nsecond\n' > "$TOKEN_FILE_PATH"
assert_token_rejected 'multiline' '只包含一行非空 token'
awk 'BEGIN { for (counter = 0; counter < 8193; counter++) printf "a"; printf "\n" }' \
  > "$TOKEN_FILE_PATH"
assert_token_rejected 'oversized' '不能超过 8192 字节'
printf 'prefix\001suffix\n' > "$TOKEN_FILE_PATH"
assert_token_rejected 'C0-control' '不能包含 C0 或 DEL'
printf 'prefix\177suffix\n' > "$TOKEN_FILE_PATH"
assert_token_rejected 'DEL-control' '不能包含 C0 或 DEL'
printf '%s\n' 'fixture-token-for-recovery-tests' > "$TOKEN_FILE_PATH"
chmod 600 "$TOKEN_FILE_PATH"
printf 'PASS token content rejects empty, multiline, oversized, C0, and DEL data\n'

if [ "$(/usr/bin/uname -s)" = "Linux" ]; then
  chmod 640 "$TOKEN_FILE_PATH"
  if run_login > "$LOGIN_OUTPUT" 2>&1; then
    fail "custom runtime token with mode 640 was accepted"
  fi
  grep -q '自定义 auth-token 必须由当前管理用户持有且 mode 600' "$LOGIN_OUTPUT" ||
    fail "custom runtime token owner/mode drift was not actionable"
  chmod 600 "$TOKEN_FILE_PATH"
  chmod 777 "$RUNTIME_ROOT/secrets"
  if run_login > "$LOGIN_OUTPUT" 2>&1; then
    fail "custom runtime secrets directory with mode 777 was accepted"
  fi
  grep -q '自定义 secrets 目录必须由当前管理用户持有且 mode 700' "$LOGIN_OUTPUT" ||
    fail "custom runtime secrets directory drift was not actionable"
  chmod 700 "$RUNTIME_ROOT/secrets"
  printf 'PASS custom runtime requires owner-held secrets 700 and token 600\n'
else
  printf 'SKIP custom token POSIX mode check on non-Linux host\n'
fi
derived_token="$(
  env -u TOKEN_FILE -u CF_AGENT_WECHAT_RUNTIME_ROOT \
    CF_RUNTIME_ROOT="$RUNTIME_ROOT" bash -c \
    'source "$1"; printf "%s" "$TOKEN_FILE"' \
    cf-wechat-recovery "${REPO_ROOT}/scripts/common.sh"
)"
[ "$derived_token" = "$TOKEN_FILE_PATH" ] ||
  fail "CF_RUNTIME_ROOT did not derive the expected token path"
custom_error="$(
  env -u TOKEN_FILE -u CF_AGENT_WECHAT_RUNTIME_ROOT \
    CF_RUNTIME_ROOT="${TEST_ROOT}/missing-runtime" bash -c \
    'source "$1"; load_auth_token || printf "%s" "$LAST_ERROR"' \
    cf-wechat-recovery "${REPO_ROOT}/scripts/common.sh"
)"
case "$custom_error" in
  *'sudo 自动读取仅允许批准路径 /srv/storage/cf-agent-wechat/secrets/auth-token'*) ;;
  *) fail "custom unreadable token did not preserve the fixed sudo boundary" ;;
esac
printf 'PASS custom runtime token derivation preserves fixed sudo boundary\n'

for path_kind in runtime token; do
  if [ "$path_kind" = runtime ]; then
    path_error="$(
      CF_RUNTIME_ROOT=$'/srv/recovery\001bad' bash -c \
        'source "$1"; validate_configuration || printf "%s" "$LAST_ERROR"' \
        cf-wechat-recovery "$REPO_ROOT/scripts/common.sh"
    )"
    expected_path_error='CF_RUNTIME_ROOT 包含不允许的路径或控制字符'
  else
    path_error="$(
      TOKEN_FILE=$'/srv/recovery\177bad' bash -c \
        'source "$1"; validate_configuration || printf "%s" "$LAST_ERROR"' \
        cf-wechat-recovery "$REPO_ROOT/scripts/common.sh"
    )"
    expected_path_error='TOKEN_FILE 包含不允许的路径或控制字符'
  fi
  case "$path_error" in
    *"$expected_path_error"*) ;;
    *) fail "$path_kind path accepted a non-CR/LF/TAB control" ;;
  esac
done
printf 'PASS process runtime and token paths reject all control characters\n'

if [ "$HOST_KERNEL" = Linux ]; then
  LOCK_HOME="${TEST_ROOT}/lock-home"
  LOCK_READY="${TEST_ROOT}/lock.ready"
  LOCK_RELEASE="${TEST_ROOT}/lock.release"
  install -d -m 700 "$LOCK_HOME"
  (
    HOME="$LOCK_HOME" bash -c '
      source "$1" --help >/dev/null
      acquire_login_lock || {
        printf "%s\n" "$LAST_ERROR" >&2
        exit 1
      }
      trap release_login_lock EXIT
      : > "$2"
      while [ ! -e "$3" ]; do
        sleep 0.05
      done
    ' cf-wechat-recovery "$REPO_ROOT/scripts/login.sh" "$LOCK_READY" "$LOCK_RELEASE"
  ) &
  LOCK_PID=$!
  for _attempt in {1..100}; do
    [ -e "$LOCK_READY" ] && break
    kill -0 "$LOCK_PID" 2>/dev/null || fail "lock holder exited before ready"
    sleep 0.05
  done
  [ -e "$LOCK_READY" ] || fail "lock holder did not acquire login lock"
  lock_error="$(
    HOME="$LOCK_HOME" bash -c '
      source "$1" --help >/dev/null
      if acquire_login_lock; then
        release_login_lock
        printf ACCEPTED
      else
        printf "%s" "$LAST_ERROR"
      fi
    ' cf-wechat-recovery "$REPO_ROOT/scripts/login.sh"
  )"
  case "$lock_error" in
    *'已有登录流程正在运行'*) ;;
    *) fail "second concurrent login did not fail with an actionable lock error" ;;
  esac
  touch "$LOCK_RELEASE"
  wait "$LOCK_PID" || fail "lock holder did not exit cleanly"
  LOCK_PID=""
  printf 'PASS concurrent fresh login lock is nonblocking and user-scoped\n'
else
  printf '%s\n' \
    'SKIP real flock concurrency and live interactive PTY flow on non-Linux host; TTY rejection and QR protocol remain covered'
fi

"$TEST_PYTHON" -m unittest -v "${REPO_ROOT}/tests/unit/test_qr_login.py"
printf 'PASS fresh QR failure/success unit coverage\n'
printf 'All restart and session recovery tests passed.\n'
