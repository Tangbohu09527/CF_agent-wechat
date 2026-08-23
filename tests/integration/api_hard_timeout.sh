#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT=""
SERVER_PID=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  set +e
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1
    wait "$SERVER_PID" >/dev/null 2>&1
  fi
  case "$TEST_ROOT" in
    /tmp/cf-agent-wechat-api-timeout.*) rm -rf -- "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT

if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' 'SKIP API hard-timeout integration test requires Linux'
  exit 0
fi
for command_name in curl python3; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail "missing required command: $command_name"
done

TEST_ROOT="$(mktemp -d /tmp/cf-agent-wechat-api-timeout.XXXXXX)"
SECRETS_DIR="$TEST_ROOT/secrets"
TOKEN_FILE="$SECRETS_DIR/auth-token"
READY_FILE="$TEST_ROOT/server.ready"
SERVER_LOG="$TEST_ROOT/server.log"
TOKEN_VALUE='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
mkdir -p -- "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
printf '%s\n' "$TOKEN_VALUE" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

python3 - "$READY_FILE" > "$SERVER_LOG" 2>&1 <<'PY' &
import socket
import sys
import time
from pathlib import Path

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(1)
Path(sys.argv[1]).write_text(str(listener.getsockname()[1]), encoding="ascii")
connection, _ = listener.accept()
try:
    connection.recv(65536)
    time.sleep(30)
finally:
    connection.close()
    listener.close()
PY
SERVER_PID=$!

for _attempt in $(seq 1 100); do
  [ -s "$READY_FILE" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || fail "black-hole HTTP server exited early"
  sleep 0.05
done
[ -s "$READY_FILE" ] || fail "black-hole HTTP server did not become ready"
PORT="$(cat -- "$READY_FILE")"

STARTED_AT="$(date +%s)"
set +e
OUTPUT="$(env \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" \
  TMPDIR="$TEST_ROOT" \
  HOME="$TEST_ROOT" \
  CF_AGENT_WECHAT_CURL_BIN="$(command -v curl)" \
  API_URL="http://127.0.0.1:$PORT" \
  TOKEN_FILE="$TOKEN_FILE" \
  HTTP_CONNECT_TIMEOUT=1 \
  HTTP_TIMEOUT=1 \
  bash -c '
set -e
source "$1/scripts/common.sh"
validate_configuration
load_auth_token
api_request GET /never-responds
' api-timeout-test "$REPO_ROOT" 2>&1)"
STATUS=$?
set -e
ELAPSED=$(( $(date +%s) - STARTED_AT ))

[ "$STATUS" -ne 0 ] || fail "black-hole API request unexpectedly succeeded"
[ "$ELAPSED" -le 5 ] || fail "API request exceeded its hard timeout"
case "$OUTPUT" in
  *"$TOKEN_VALUE"*) fail "API timeout error disclosed the auth Token" ;;
esac
printf '%s\n' 'PASS curl API request fails within the configured total timeout without Token disclosure'
