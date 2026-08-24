#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_HARNESS_ROOT=""
TEST_ROOT=""
DEPLOYMENT_DIR=""
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
TEST_STAGE="fixture setup"

fail() {
  printf 'FAIL [%s, line %s]: %s\n' \
    "$TEST_STAGE" "${BASH_LINENO[0]:-unknown}" "$*" >&2
  exit 1
}

report_unexpected_error() {
  local exit_status="$1"
  local line_number="$2"

  trap - ERR
  printf 'FAIL [%s, line %s]: unexpected command failure (exit %s)\n' \
    "$TEST_STAGE" "$line_number" "$exit_status" >&2
  exit "$exit_status"
}

cleanup() {
  trap - ERR
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
  if [ -n "$TEST_HARNESS_ROOT" ]; then
    rm -rf "$TEST_HARNESS_ROOT"
  fi
  if [ "$SECRETS_CREATED" -eq 1 ]; then
    rm -f "$TOKEN_FILE" "${TOKEN_FILE}.saved"
    rmdir "$SECRETS_DIR" 2>/dev/null
    rmdir "$DEPLOYMENT_DIR" 2>/dev/null
  fi
}
trap cleanup EXIT
trap 'report_unexpected_error "$?" "$LINENO"' ERR

if [ "${GITHUB_ACTIONS:-}" != "true" ] || \
  [ "${CF_AGENT_WECHAT_PERMISSION_TEST:-}" != "1" ]; then
  fail "refusing to run outside the disposable CI permission-test environment"
fi
if [ "$(id -u)" -ne 0 ]; then
  fail "this integration test must run as root"
fi
if id "$TEST_USER" >/dev/null 2>&1 || id "$NO_SUDO_USER" >/dev/null 2>&1; then
  fail "temporary test user already exists"
fi
if [ -e "$SUDOERS_FILE" ]; then
  fail "temporary sudoers file already exists: ${SUDOERS_FILE}"
fi
for command_name in docker flock openssl python3 sudo useradd visudo; do
  command -v "$command_name" >/dev/null 2>&1 || fail "missing command: ${command_name}"
done
REAL_DOCKER="$(command -v docker)"
REAL_SUDO="$(command -v sudo)"

TEST_HARNESS_ROOT="$(mktemp -d /tmp/cf-agent-wechat-permissions.XXXXXX)"
chmod 755 "$TEST_HARNESS_ROOT"
TEST_ROOT="${TEST_HARNESS_ROOT}/status-fixture"
install -d -m 755 "$TEST_ROOT"
DEPLOYMENT_DIR="${TEST_ROOT}/deployment"
STORAGE_ROOT="$DEPLOYMENT_DIR"
RUNTIME_ROOT="${STORAGE_ROOT}/runtime"
ARCHIVE_ROOT="${STORAGE_ROOT}/session-archive"
RUNTIME_LOCK_FILE="${TEST_ROOT}/runtime.lock"
DOCKER_SOCKET="${TEST_ROOT}/docker.sock"
TEST_AGENT_PORT=16174
TEST_REPO="${TEST_ROOT}/repo"
TEST_HOME="${TEST_ROOT}/home"
NO_SUDO_HOME="${TEST_ROOT}/no-sudo-home"
TEST_TMPDIR="${TEST_ROOT}/tmp"
NO_SUDO_TMPDIR="${NO_SUDO_HOME}/tmp"
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
APPROVED_AGENT_IMAGE="ghcr.io/example/agent-wechat@sha256:$(printf '%064d' 0)"
APPROVED_PROXY="http://${AGENT_ENV_SENTINEL}.invalid:8080"
GATEWAY_PROJECT_DIR="${TEST_ROOT}/gateway"
GATEWAY_COMPOSE_FILE="${GATEWAY_PROJECT_DIR}/compose.yaml"
GATEWAY_ENV_FILE="${GATEWAY_PROJECT_DIR}/.env"
GATEWAY_ENV_SENTINEL="gateway-env-fixture-sensitive-permissions-$$"
GATEWAY_DEPLOY_DIR="${GATEWAY_PROJECT_DIR}/deploy"
GATEWAY_HEARTBEAT_COMMAND="${GATEWAY_DEPLOY_DIR}/check-wechat-worker-heartbeat"
GATEWAY_RELEASE_GATE_COMMAND="${GATEWAY_DEPLOY_DIR}/wechat-runtime-release-gate"
GATEWAY_CONTRACT_FILE="${GATEWAY_DEPLOY_DIR}/wechat-runtime-contract.json"
MOCK_DOCKER_BACKEND="${AUDIT_BIN}/docker-backend"
MOCK_DOCKER_STATE_DIR="${TEST_ROOT}/docker-state"
MOCK_DOCKER_LOG="${TEST_ROOT}/docker-backend.log"
MOCK_DOCKER_MUTATION_LOG="${TEST_ROOT}/docker-mutations.log"

useradd --create-home --home-dir "$TEST_HOME" --shell /bin/bash "$TEST_USER"
useradd --create-home --home-dir "$NO_SUDO_HOME" --shell /bin/bash "$NO_SUDO_USER"
chown "${TEST_USER}:${TEST_USER}" "$TEST_ROOT"
TEST_RUNTIME_UID="$(id -u "$TEST_USER")"
TEST_RUNTIME_GID="$(id -g "$TEST_USER")"
install -d -o "$TEST_USER" -g "$TEST_USER" -m 700 "$TEST_TMPDIR"
install -d -o "$NO_SUDO_USER" -g "$NO_SUDO_USER" -m 700 "$NO_SUDO_TMPDIR"
if [ -L "$TEST_TMPDIR" ] ||
  [ "$(stat -Lc '%u:%g:%a' -- "$TEST_TMPDIR")" != \
    "${TEST_RUNTIME_UID}:${TEST_RUNTIME_GID}:700" ]; then
  fail "status fixture temporary directory metadata is unsafe"
fi
for isolated_asset in "$TEST_TMPDIR" "$TOKEN_FILE" "$DOCKER_SOCKET" \
  "$MOCK_DOCKER_STATE_DIR" "$RUNTIME_LOCK_FILE"; do
  case "${isolated_asset}/" in
    "${TEST_ROOT}/"?*) ;;
    *) fail "status fixture asset escaped its isolated testing root" ;;
  esac
done
unset isolated_asset

TEST_DOCKER_ENV=(
  "CF_AGENT_WECHAT_TEST_ROOT=${TEST_ROOT}"
  "TMPDIR=${TEST_TMPDIR}"
  "MOCK_TMPDIR=${TEST_TMPDIR}"
  "CF_AGENT_WECHAT_DOCKER_BIN=${AUDIT_BIN}/docker"
  "CF_AGENT_WECHAT_SYSTEMCTL_BIN=${AUDIT_BIN}/systemctl"
  "CF_AGENT_WECHAT_DF_BIN=${AUDIT_BIN}/df"
  "CF_AGENT_WECHAT_DOCKER_SOCKET_PATH=${DOCKER_SOCKET}"
  "CONTAINER_NAME=${TEST_CONTAINER}"
  "CF_AUDIT_DOCKER_BACKEND=${MOCK_DOCKER_BACKEND}"
  "MOCK_DOCKER_STATE_DIR=${MOCK_DOCKER_STATE_DIR}"
  "MOCK_DOCKER_LOG=${MOCK_DOCKER_LOG}"
  "MOCK_DOCKER_MUTATION_LOG=${MOCK_DOCKER_MUTATION_LOG}"
  "MOCK_APPROVED_AGENT_IMAGE=${APPROVED_AGENT_IMAGE}"
  "MOCK_APPROVED_AGENT_CONTAINER=${TEST_CONTAINER}"
  "MOCK_APPROVED_AGENT_PROJECT=cf-agent-wechat"
  "MOCK_APPROVED_STORAGE_ROOT=${STORAGE_ROOT}"
  "MOCK_APPROVED_RUNTIME_ROOT=${RUNTIME_ROOT}"
  "MOCK_APPROVED_ARCHIVE_ROOT=${ARCHIVE_ROOT}"
  "MOCK_APPROVED_TOKEN_FILE=${TOKEN_FILE}"
  "MOCK_APPROVED_BIND_IP=127.0.0.1"
  "MOCK_APPROVED_PORT=${TEST_AGENT_PORT}"
  "MOCK_APPROVED_PROXY=${APPROVED_PROXY}"
  "MOCK_APPROVED_RUST_LOG=info"
  "MOCK_APPROVED_DOCKER_SOCKET=${DOCKER_SOCKET}"
  "MOCK_AGENT_COMPOSE_FILE=${AGENT_COMPOSE_FILE}"
  "MOCK_AGENT_PROJECT_DIR=${TEST_REPO}"
  "MOCK_GATEWAY_COMPOSE_FILE=${GATEWAY_COMPOSE_FILE}"
  "MOCK_GATEWAY_ENV_FILE=${GATEWAY_ENV_FILE}"
  "MOCK_GATEWAY_PROJECT_DIR=${GATEWAY_PROJECT_DIR}"
  "MOCK_AUTH_STATE_FILE=${STATE_FILE}"
)
TEST_MANAGEMENT_ENV=(
  "CF_AGENT_WECHAT_TEST_ROOT=${TEST_ROOT}"
  "TMPDIR=${TEST_TMPDIR}"
  "TOKEN_FILE=${TOKEN_FILE}"
  "CF_AGENT_WECHAT_STORAGE_ROOT=${STORAGE_ROOT}"
  "CF_AGENT_WECHAT_RUNTIME_ROOT=${RUNTIME_ROOT}"
  "CF_AGENT_WECHAT_ARCHIVE_ROOT=${ARCHIVE_ROOT}"
  "CF_AGENT_WECHAT_LOCK_FILE=${RUNTIME_LOCK_FILE}"
  "CF_AGENT_GATEWAY_PROJECT_DIR=${GATEWAY_PROJECT_DIR}"
  "CF_AGENT_GATEWAY_COMPOSE_FILE=${GATEWAY_COMPOSE_FILE}"
  "CF_AGENT_GATEWAY_ENV_FILE=${GATEWAY_ENV_FILE}"
)

install -d -o root -g root -m 755 "${TEST_REPO}/scripts"
install -o root -g root -m 755 \
  "${REPO_ROOT}/scripts/common.sh" \
  "${REPO_ROOT}/scripts/qr-runtime-common.sh" \
  "${REPO_ROOT}/scripts/status.sh" \
  "${REPO_ROOT}/scripts/login.sh" \
  "${REPO_ROOT}/scripts/start-qr-login.sh" \
  "${REPO_ROOT}/scripts/qr_login.py" \
  "${REPO_ROOT}/scripts/ensure-login-environment.sh" \
  "${REPO_ROOT}/scripts/verify_login_dependencies.py" \
  "${REPO_ROOT}/scripts/stop-qr-runtime.sh" \
  "${REPO_ROOT}/scripts/archive-runtime.py" \
  "${REPO_ROOT}/scripts/scan_runtime_tree.py" \
  "${REPO_ROOT}/scripts/verify_management_source_secrets.py" \
  "${REPO_ROOT}/scripts/parse_management_env.py" \
  "${REPO_ROOT}/scripts/verify_gateway_contract.py" \
  "${TEST_REPO}/scripts/"
install -o root -g root -m 644 \
  "${REPO_ROOT}/scripts/requirements.txt" \
  "${TEST_REPO}/scripts/requirements.txt"
install -d -o "$TEST_USER" -g "$TEST_USER" -m 700 "$AUDIT_BIN"
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/audit_docker.sh" "${AUDIT_BIN}/docker"
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/audit_sudo.sh" "${AUDIT_BIN}/sudo"
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/mock_runtime_systemctl.sh" "${AUDIT_BIN}/systemctl"
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/mock_df.sh" "${AUDIT_BIN}/df"
install -o root -g root -m 755 \
  "${REPO_ROOT}/tests/helpers/mock_docker.sh" "$MOCK_DOCKER_BACKEND"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  ': "${MOCK_TMPDIR:?}"' \
  ': "${CF_AUDIT_LOG:?}"' \
  'printf "mktemp\tconfined\tlocal\n" >> "$CF_AUDIT_LOG"' \
  'TMPDIR="$MOCK_TMPDIR"' \
  'export TMPDIR' \
  'exec /usr/bin/mktemp "$@"' > "${AUDIT_BIN}/mktemp"
chown root:root "${AUDIT_BIN}/mktemp"
chmod 755 "${AUDIT_BIN}/mktemp"
python3 - "$DOCKER_SOCKET" <<'PY'
import socket
import sys

fixture = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
fixture.bind(sys.argv[1])
fixture.close()
PY
chown root:root "$DOCKER_SOCKET"
chmod 600 "$DOCKER_SOCKET"

install -d -o root -g root -m 755 "$GATEWAY_DEPLOY_DIR"
install -d -o "$TEST_USER" -g "$TEST_USER" -m 700 "$MOCK_DOCKER_STATE_DIR"
: > "$MOCK_DOCKER_LOG"
: > "$MOCK_DOCKER_MUTATION_LOG"
chown "$TEST_USER:$TEST_USER" "$MOCK_DOCKER_LOG" "$MOCK_DOCKER_MUTATION_LOG"
chmod 600 "$MOCK_DOCKER_LOG" "$MOCK_DOCKER_MUTATION_LOG"
printf '%s\n' 'services:' '  agent-wechat: {}' > "$AGENT_COMPOSE_FILE"
printf '%s\n' \
  'COMPOSE_PROJECT_NAME=cf-agent-wechat' \
  "AGENT_WECHAT_IMAGE=$APPROVED_AGENT_IMAGE" \
  "AGENT_WECHAT_CONTAINER_NAME=$TEST_CONTAINER" \
  "CF_AGENT_WECHAT_STORAGE_ROOT=$STORAGE_ROOT" \
  "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" \
  "CF_AGENT_WECHAT_ARCHIVE_ROOT=$ARCHIVE_ROOT" \
  "CF_AGENT_WECHAT_RUNTIME_UID=$TEST_RUNTIME_UID" \
  "CF_AGENT_WECHAT_RUNTIME_GID=$TEST_RUNTIME_GID" \
  'CF_AGENT_WECHAT_RUNTIME_MODE=700' \
  "CF_AGENT_WECHAT_MANAGEMENT_GID=$TEST_RUNTIME_GID" \
  'CF_AGENT_WECHAT_MIN_FREE_BYTES=1073741824' \
  'CF_AGENT_WECHAT_MIN_FREE_PERCENT=10' \
  'CF_AGENT_WECHAT_MIN_FREE_INODES=1024' \
  'CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES=200000' \
  'CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES=21474836480' \
  'AGENT_WECHAT_BIND_IP=127.0.0.1' \
  "AGENT_WECHAT_PORT=$TEST_AGENT_PORT" \
  "PROXY=$APPROVED_PROXY" \
  'RUST_LOG=info' > "$AGENT_ENV_FILE"
printf '%s\n' 'services:' '  worker: {}' > "$GATEWAY_COMPOSE_FILE"
chmod 600 "$AGENT_COMPOSE_FILE" "$GATEWAY_COMPOSE_FILE"
install -o "$TEST_USER" -g "$TEST_USER" -m 600 \
  "$AGENT_COMPOSE_FILE" "${MOCK_DOCKER_STATE_DIR}/approved-agent-compose"
install -o "$TEST_USER" -g "$TEST_USER" -m 600 \
  "$GATEWAY_COMPOSE_FILE" "${MOCK_DOCKER_STATE_DIR}/approved-gateway-compose"
printf '%s\n' \
  'CF_AGENT_WECHAT_TOKEN_FILE=/run/secrets/cf-agent-wechat-auth-token' \
  "FIXTURE_SENTINEL=$GATEWAY_ENV_SENTINEL" > "$GATEWAY_ENV_FILE"
chown root:root "$AGENT_ENV_FILE" "$GATEWAY_ENV_FILE"
chmod 600 "$AGENT_ENV_FILE" "$GATEWAY_ENV_FILE"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$GATEWAY_HEARTBEAT_COMMAND"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$GATEWAY_RELEASE_GATE_COMMAND"
chown root:root "$GATEWAY_HEARTBEAT_COMMAND" "$GATEWAY_RELEASE_GATE_COMMAND"
chmod 755 "$GATEWAY_HEARTBEAT_COMMAND" "$GATEWAY_RELEASE_GATE_COMMAND"
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
NO_SUDO_TOKEN_FILE="${NO_SUDO_HOME}/secrets/auth-token"
install -d -o root -g root -m 700 -- "${NO_SUDO_HOME}/secrets"
install -o root -g root -m 600 -- "$TOKEN_FILE" "$NO_SUDO_TOKEN_FILE"
python3 - "${REPO_ROOT}/scripts/verify_gateway_contract.py" \
  "$GATEWAY_CONTRACT_FILE" "$GATEWAY_HEARTBEAT_COMMAND" \
  "$GATEWAY_RELEASE_GATE_COMMAND" "$TOKEN_FILE" <<'PY'
import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

verifier_path, contract_path, checker_path, gate_path, token_path = map(
    Path, sys.argv[1:]
)
spec = importlib.util.spec_from_file_location(
    "permission_fixture_gateway_contract", verifier_path
)
if spec is None or spec.loader is None:
    raise SystemExit("Gateway contract fixture builder is unavailable")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
contract = verifier.expected_contract(
    argparse.Namespace(
        alias="cf-agent-wechat",
        port=6174,
        token_file=str(token_path),
        checker=str(checker_path),
        gate=str(gate_path),
        checker_sha256=hashlib.sha256(checker_path.read_bytes()).hexdigest(),
        gate_sha256=hashlib.sha256(gate_path.read_bytes()).hexdigest(),
        producer_repository="Tangbohu09527/CF_agent-gateway",
        service="worker",
        project="cf-agent-gateway",
        max_age=30,
    )
)
contract_path.write_text(json.dumps(contract) + "\n", encoding="utf-8")
PY
chown root:root "$GATEWAY_CONTRACT_FILE"
chmod 600 "$GATEWAY_CONTRACT_FILE"
printf '%s\n' 1 > "${MOCK_DOCKER_STATE_DIR}/agent_exists"
printf '%s\n' 1 > "${MOCK_DOCKER_STATE_DIR}/agent_running"
printf '%s\n' 1 > "${MOCK_DOCKER_STATE_DIR}/gateway_running"
printf 'logged_in\n' > "$STATE_FILE"
chown "$TEST_USER:$TEST_USER" "$STATE_FILE"
chown "$TEST_USER:$TEST_USER" \
  "${MOCK_DOCKER_STATE_DIR}/agent_exists" \
  "${MOCK_DOCKER_STATE_DIR}/agent_running" \
  "${MOCK_DOCKER_STATE_DIR}/gateway_running"
chmod 600 "${MOCK_DOCKER_STATE_DIR}/"{agent_exists,agent_running,gateway_running}
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
  : > "$MOCK_DOCKER_LOG"
  : > "$MOCK_DOCKER_MUTATION_LOG"
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
  local label="$1" first_sudo validation_count total_sudo_count

  validation_count="$(audit_count sudo validate)"
  total_sudo_count="$(awk -F '\t' \
    '$1 == "sudo" { count++ } END { print count + 0 }' "$AUDIT_LOG")"
  [ "$validation_count" -eq 1 ] || \
    fail "$label observed ${validation_count} sudo -v authorization calls; expected 1 (${total_sudo_count} total sudo calls)"
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

assert_no_sudo_docker() {
  [ "$(awk -F '\t' '$1 == "sudo" && $2 ~ /^docker-/ { count++ }
      END { print count + 0 }' "$AUDIT_LOG")" -eq 0 ] ||
    fail "$1 attempted to execute a testing Docker mock through sudo"
}

assert_runtime_mock_runs_directly() {
  local label="$1"
  shift

  if ! "$REAL_SUDO" -u "$TEST_USER" -H env \
    PATH="$AUDIT_PATH" \
    CF_AUDIT_LOG="$AUDIT_LOG" \
    CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
    CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
    CF_AUDIT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
    CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
    CF_AUDIT_DOCKER_VIA_SUDO=0 \
    docker "$@" > /dev/null 2>&1; then
    fail "direct runtime Docker ${label} failed"
  fi
  assert_no_sudo_docker "direct runtime Docker $label"
}

assert_status_docker_paths() {
  [ "$(audit_count mktemp confined)" -ge 1 ] || \
    fail "status.sh did not create temporary snapshots in its confined fixture"
  [ "$(audit_count docker info)" -eq 3 ] || \
    fail "status.sh did not inspect Docker availability, security, and live-restore"
  [ "$(audit_count docker context)" -eq 2 ] || \
    fail "status.sh did not inspect the Docker context and socket"
  [ "$(audit_count docker compose)" -ge 7 ] || \
    fail "status.sh used an unexpected Compose query sequence"
  [ "$(audit_count docker exec)" -eq 2 ] || \
    fail "status.sh did not attest a stable WeChat process"
  [ "$(audit_count docker inspect)" -ge 4 ] || \
    fail "status.sh did not inspect Agent/Worker health and runtime mounts"
  if [ "$(audit_count docker network)" -lt 1 ] ||
    [ "$(audit_count docker image)" -lt 1 ]; then
    fail "status.sh did not attest the approved image and network"
  fi
  assert_no_sudo_docker "status.sh"
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
  [ "$(stat -c '%U:%G %a' "$GATEWAY_RELEASE_GATE_COMMAND")" = "root:root 755" ] || \
    fail "Gateway runtime release gate permissions changed"
  [ "$(stat -c '%U:%G %a' "$GATEWAY_CONTRACT_FILE")" = "root:root 600" ] || \
    fail "Gateway runtime contract permissions changed"
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
    CF_AGENT_WECHAT_TESTING=1 \
    "${TEST_DOCKER_ENV[@]}" \
    "${TEST_MANAGEMENT_ENV[@]}" \
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

TEST_STAGE="root-only secret and isolated Docker socket"
assert_secret_permissions
[ "$(CF_AGENT_WECHAT_TESTING=1 /bin/bash -c \
  'source "$1"; printf "%s" "$CONTAINER_NAME"' \
  cf-agent-wechat-test "${TEST_REPO}/scripts/common.sh")" = "cf-agent-wechat" ] || \
  fail "default container name is not cf-agent-wechat"
if "$REAL_SUDO" -u "$TEST_USER" -H test -r "$DOCKER_SOCKET"; then
  fail "ordinary user unexpectedly reads the isolated Docker socket"
fi
[ -S "$DOCKER_SOCKET" ] || fail "isolated Docker socket fixture is missing"
printf 'PASS isolated fake Docker socket is root protected\n'

TEST_STAGE="real Docker socket sudo fallback"
REAL_DOCKER_FALLBACK_OUTPUT="${TEST_ROOT}/real-docker-fallback.out"
if "$REAL_SUDO" -u "$TEST_USER" -H /usr/bin/docker info \
  >/dev/null 2>&1; then
  fail "ordinary test user unexpectedly reached the real Docker socket directly"
fi
if ! "$REAL_SUDO" -u "$TEST_USER" -H /usr/bin/env -i \
  HOME="$TEST_HOME" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /bin/bash -p -c '
scripts_dir="$1"
_CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR="$scripts_dir"
readonly _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR
source "$scripts_dir/common.sh" || exit 1
docker_readonly_capture info --format "{{json .ServerVersion}}"
' real-docker-fallback "${TEST_REPO}/scripts" \
  >"$REAL_DOCKER_FALLBACK_OUTPUT" 2>&1; then
  print_redacted_file "$REAL_DOCKER_FALLBACK_OUTPUT"
  fail "production fixed Docker did not use sudo -v then sudo -n socket fallback"
fi
grep -Eq '"[^"]+"' "$REAL_DOCKER_FALLBACK_OUTPUT" ||
  fail "real Docker fallback did not return the daemon version fixture"
assert_file_has_no_token "$REAL_DOCKER_FALLBACK_OUTPUT"
printf 'PASS production fixed Docker uses real sudo socket fallback in disposable CI\n'

TEST_STAGE="runtime management lock permissions"
AUDIT_COMMANDS="$("$REAL_SUDO" -u "$TEST_USER" -H env PATH="$AUDIT_PATH" \
  /bin/bash -c 'command -v docker; command -v sudo')"
EXPECTED_AUDIT_COMMANDS="$(printf '%s\n%s' "${AUDIT_BIN}/docker" "${AUDIT_BIN}/sudo")"
[ "$AUDIT_COMMANDS" = "$EXPECTED_AUDIT_COMMANDS" ] || \
  fail "audit wrappers were not selected through PATH"

LOCK_METADATA="$("$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" \
  TMPDIR="$TEST_TMPDIR" \
  CF_AGENT_WECHAT_LOCK_FILE="$RUNTIME_LOCK_FILE" \
  CF_AGENT_WECHAT_MANAGEMENT_GID="$TEST_RUNTIME_GID" \
  /bin/bash -c '
set -e
cd "$1"
source scripts/common.sh
source scripts/qr-runtime-common.sh
runtime_acquire_lock
stat -Lc "%u:%g:%a:%h:%s" -- "$RUNTIME_LOCK_FILE"
' lock-test "$TEST_REPO")"
[ "$LOCK_METADATA" = \
  "${TEST_RUNTIME_UID}:${TEST_RUNTIME_GID}:640:1:0" ] || \
  fail "runtime lock does not have the approved owner/group/mode/link/size"
[ -f "$RUNTIME_LOCK_FILE" ] || \
  fail "stale runtime lock file was not retained after holder exit"
if ! "$REAL_SUDO" -u "$TEST_USER" -H /bin/bash -c \
  'set -e; exec 9<"$1"; flock -n 9' \
  lock-reopen "$RUNTIME_LOCK_FILE"; then
  fail "approved management user could not reacquire the released runtime lock"
fi
NON_MANAGEMENT_LOCK_OUTPUT="${TEST_ROOT}/non-management-lock.out"
if "$REAL_SUDO" -u "$NO_SUDO_USER" -H /bin/bash -c \
  'set -e; exec 9<"$1"; flock -n 9' \
  lock-denied "$RUNTIME_LOCK_FILE" \
  >"$NON_MANAGEMENT_LOCK_OUTPUT" 2>&1; then
  fail "non-management user unexpectedly opened and held the runtime lock"
fi
assert_file_has_no_token "$NON_MANAGEMENT_LOCK_OUTPUT"
printf 'PASS protected runtime lock ownership, mode, and lifecycle\n'

TEST_STAGE="approved Runtime ownership contract"
ROOT_OWNED_RUNTIME="${TEST_ROOT}/root-owned-runtime"
install -d -o root -g root -m 700 \
  "$ROOT_OWNED_RUNTIME" \
  "${ROOT_OWNED_RUNTIME}/data" \
  "${ROOT_OWNED_RUNTIME}/wechat-home"
ROOT_OWNED_RUNTIME_OUTPUT="${TEST_ROOT}/root-owned-runtime.out"
if CF_AGENT_WECHAT_TESTING=1 /bin/bash -c '
set -e
cd "$1"
source scripts/common.sh
source scripts/qr-runtime-common.sh
RUNTIME_DEFAULT_UID=1000
RUNTIME_DEFAULT_GID=1000
RUNTIME_DEFAULT_MODE=700
if runtime_validate_approved_runtime_directory "$2" "Runtime root" 1; then
  exit 0
fi
printf "%s\n" "$LAST_ERROR" >&2
exit 1
' runtime-owner-contract "$TEST_REPO" "$ROOT_OWNED_RUNTIME" \
  > "$ROOT_OWNED_RUNTIME_OUTPUT" 2>&1; then
  fail "root:root 0700 Runtime matched the approved 1000:1000/0700 contract"
fi
grep -Fq 'approved UID:GID:mode 1000:1000:700' \
  "$ROOT_OWNED_RUNTIME_OUTPUT" ||
  fail "root-owned Runtime rejection did not identify the exact approved contract"
[ "$(stat -Lc '%u:%g:%a' -- "$ROOT_OWNED_RUNTIME")" = "0:0:700" ] ||
  fail "root-owned Runtime fixture changed while its permission drift was rejected"
assert_file_has_no_token "$ROOT_OWNED_RUNTIME_OUTPUT"
rm -rf -- "$ROOT_OWNED_RUNTIME"
printf 'PASS root:root 0700 Runtime rejected by approved 1000:1000/0700 contract\n'

TEST_STAGE="ordinary-user direct Docker status"
reset_audit
DETECT_OUTPUT="$("$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  "${TEST_DOCKER_ENV[@]}" \
  CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
  CF_AUDIT_DOCKER_VIA_SUDO=0 \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CONTAINER_NAME="$TEST_CONTAINER" /bin/bash -c \
  'cd "$1"; source scripts/common.sh; detect_container_status' \
  cf-agent-wechat-test "$TEST_REPO")"
[ "$DETECT_OUTPUT" = 'running' ] || \
  fail "detect_container_status did not use the direct testing Docker mock"
[ "$(audit_count docker inspect)" -eq 1 ] ||
  fail "detect_container_status did not use exactly one direct Docker inspect"
assert_no_sudo_calls "direct testing Docker status"
printf 'PASS testing Docker status runs directly without sudo\n'

TEST_STAGE="canonical WeChat process identity"
reset_audit
COMMON_IDENTITY_OUTPUT="${TEST_ROOT}/common-identity.out"
if ! "$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  "${TEST_DOCKER_ENV[@]}" \
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
  fail "common WeChat identity check did not use direct testing Docker"
fi
[ "$(cat "$COMMON_IDENTITY_OUTPUT")" = "4242:9001" ] || \
  fail "common WeChat identity check returned an unexpected identity"
[ "$(audit_count docker exec)" -eq 1 ] || \
  fail "common WeChat identity check did not use exactly one direct Docker exec"
assert_no_sudo_calls "common WeChat identity direct Docker"
assert_no_sudo_python "common WeChat identity Docker fallback"
assert_file_has_no_token "$COMMON_IDENTITY_OUTPUT"
printf 'PASS canonical WeChat identity with direct testing Docker\n'

TEST_STAGE="non-permission Docker error handling"
reset_audit
if NONPERMISSION_OUTPUT="$("$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  "${TEST_DOCKER_ENV[@]}" \
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

TEST_STAGE="runtime Docker mock privilege boundary"
reset_audit
WECHAT_IDENTITY_PROBE='
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
'
assert_runtime_mock_runs_directly info info
assert_runtime_mock_runs_directly compose \
  compose --env-file "$AGENT_ENV_FILE" \
  --project-directory "$TEST_REPO" -f "$AGENT_COMPOSE_FILE" \
  ps --all --quiet agent-wechat
assert_runtime_mock_runs_directly exec \
  exec "$TEST_CONTAINER" sh -c "$WECHAT_IDENTITY_PROBE"
assert_runtime_mock_runs_directly inspect inspect "$TEST_CONTAINER"
unset WECHAT_IDENTITY_PROBE
printf 'PASS runtime Docker mock rejects every sudo execution path\n'

TEST_STAGE="failed-agent cleanup privilege boundary"
reset_audit
CLEANUP_ERROR="${TEST_ROOT}/cleanup.err"
if ! CLEANUP_OUTPUT="$("$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  "${TEST_DOCKER_ENV[@]}" \
  "${TEST_MANAGEMENT_ENV[@]}" \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_DOCKER="$REAL_DOCKER" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  CF_AUDIT_DOCKER_RUNTIME_MOCK=1 \
  CF_AUDIT_DOCKER_VIA_SUDO=0 \
  CF_AUDIT_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
  CF_AUDIT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
  CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
  CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV_FILE" \
  /bin/bash -c '
cd "$1"
_cleanup_test_caller_path="$PATH"
source scripts/common.sh
source scripts/qr-runtime-common.sh
if ! restore_testing_management_path "$_cleanup_test_caller_path"; then
  printf "%s\n" "$LAST_ERROR" >&2
  exit 1
fi
unset _cleanup_test_caller_path
runtime_authorize_sudo
runtime_load_management_environment
runtime_prepare_compose_snapshots
runtime_select_docker
cleanup_failed_agent_container
printf "%s:%s:%s\n" \
  "$AGENT_FAILURE_CLEANUP_ATTEMPTED" \
  "$AGENT_FAILURE_CLEANUP_STOP_RESULT" \
  "$AGENT_FAILURE_CLEANUP_REMOVE_RESULT"
' cf-agent-wechat-test "$TEST_REPO" 2>"$CLEANUP_ERROR")"; then
  print_redacted_file "$CLEANUP_ERROR"
  printf '%s\n' "$CLEANUP_OUTPUT" >&2
  fail "failed-agent cleanup did not use direct testing Docker"
fi
[ "$CLEANUP_OUTPUT" = "true:succeeded:succeeded" ] ||
  fail "failed-agent cleanup returned unexpected results"
[ -s "$CLEANUP_ERROR" ] ||
  fail "failed-agent cleanup did not emit the sudo authorization prompt"
[ "$(cat "${MOCK_DOCKER_STATE_DIR}/agent_exists")" = 0 ] ||
  fail "failed-agent cleanup left a restartable container"
[ "$(cat "${MOCK_DOCKER_STATE_DIR}/agent_running")" = 0 ] ||
  fail "failed-agent cleanup left the container running"
[ "$(audit_count docker info)" -eq 3 ] ||
  fail "failed-agent cleanup did not inspect Docker security and live-restore"
[ "$(audit_count docker context)" -eq 2 ] ||
  fail "failed-agent cleanup did not attest the local Docker endpoint"
assert_no_sudo_docker "failed-agent cleanup"
assert_sudo_contract "failed-agent cleanup"
[ "$(grep -Fxc 'agent container stop' "$MOCK_DOCKER_MUTATION_LOG")" -eq 1 ] ||
  fail "failed-agent cleanup did not stop the agent container"
[ "$(grep -Fxc 'agent container remove' "$MOCK_DOCKER_MUTATION_LOG")" -eq 1 ] ||
  fail "failed-agent cleanup did not remove the agent container"
assert_no_sudo_python "failed-agent cleanup"
CLEANUP_OUTPUT_FILE="${TEST_ROOT}/cleanup.out"
printf '%s\n' "$CLEANUP_OUTPUT" > "$CLEANUP_OUTPUT_FILE"
assert_file_has_no_token "$CLEANUP_OUTPUT_FILE"
assert_file_has_no_token "$CLEANUP_ERROR"
assert_file_has_no_token "$AUDIT_LOG"
assert_file_has_no_token "$MOCK_DOCKER_LOG"
assert_file_has_no_token "$MOCK_DOCKER_MUTATION_LOG"
printf 'PASS failed-agent cleanup with direct testing Docker and protected config sudo\n'

TEST_STAGE="ordinary-user root-only Token status"
printf '%s\n' 1 > "${MOCK_DOCKER_STATE_DIR}/agent_exists"
printf '%s\n' 1 > "${MOCK_DOCKER_STATE_DIR}/agent_running"
reset_audit

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
assert_status_docker_paths
assert_file_has_no_token "$MOCK_DOCKER_LOG"
assert_file_has_no_token "$MOCK_DOCKER_MUTATION_LOG"
printf 'PASS root-only token with ordinary-user status.sh\n'

TEST_STAGE="shell trace and curl credential redaction"
printf '%s\n' '--verbose' > "${TEST_HOME}/.curlrc"
chown "$TEST_USER:$TEST_USER" "${TEST_HOME}/.curlrc"
TRACE_OUTPUT="${TEST_ROOT}/trace.out"
# The redirect intentionally belongs to the root test harness, not sudo.
# shellcheck disable=SC2024
if sudo -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  "${TEST_DOCKER_ENV[@]}" \
  "${TEST_MANAGEMENT_ENV[@]}" \
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

TEST_STAGE="forced fresh QR compatibility entrypoint"
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

TEST_STAGE="root-only Token process isolation"
reset_audit
TOKEN_PROCESS_OUTPUT="${TEST_ROOT}/token-process.out"
TOKEN_PROCESS_READY="${TEST_HOME}/token-process.ready"
"$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_TMPDIR" \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  TOKEN_FILE="$TOKEN_FILE" \
  /bin/bash -c '
cd "$1"
_token_test_caller_path="$PATH"
source scripts/common.sh
if ! restore_testing_management_path "$_token_test_caller_path"; then
  error "$LAST_ERROR"
  exit 1
fi
unset _token_test_caller_path
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

TEST_STAGE="root-only Token ancestor validation"
TOKEN_ANCESTOR_LINK="${TEST_ROOT}/token-ancestor-link"
ln -s -- "$SECRETS_DIR" "$TOKEN_ANCESTOR_LINK"
reset_audit
TOKEN_ANCESTOR_OUTPUT="${TEST_ROOT}/token-ancestor.out"
if "$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_TMPDIR" \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  TOKEN_FILE="${TOKEN_ANCESTOR_LINK}/auth-token" \
  /bin/bash -c '
cd "$1"
_token_test_caller_path="$PATH"
source scripts/common.sh
if ! restore_testing_management_path "$_token_test_caller_path"; then
  error "$LAST_ERROR"
  exit 1
fi
unset _token_test_caller_path
if ! load_auth_token; then
  error "$LAST_ERROR"
  exit 1
fi
' cf-agent-wechat-test "$TEST_REPO" > "$TOKEN_ANCESTOR_OUTPUT" 2>&1; then
  fail "Token loader accepted a symbolic-link ancestor"
fi
grep -q 'symbolic link ancestors' "$TOKEN_ANCESTOR_OUTPUT" ||
  fail "Token ancestor rejection returned an unexpected error"
assert_token_read_once "symbolic-link Token ancestor"
assert_sudo_contract "symbolic-link Token ancestor"
assert_no_sudo_python "symbolic-link Token ancestor"
assert_file_has_no_token "$TOKEN_ANCESTOR_OUTPUT"
assert_file_has_no_token "$AUDIT_LOG"
rm -f -- "$TOKEN_ANCESTOR_LINK"
printf 'PASS root-only Token rejects symbolic-link ancestors after sudo authorization\n'

TEST_STAGE="testing helper root rejection"
reset_audit
ROOT_TOKEN_OUTPUT="${TEST_ROOT}/root-token.out"
if env CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_TMPDIR" \
  TOKEN_FILE="$TOKEN_FILE" \
  /bin/bash -c '
cd "$1"
source scripts/common.sh
load_auth_token
' cf-agent-wechat-test "$TEST_REPO" > "$ROOT_TOKEN_OUTPUT" 2>&1; then
  fail "root executed testing Token helpers"
fi
grep -q 'non-root, non-elevated identity' "$ROOT_TOKEN_OUTPUT" || \
  fail "root testing-helper rejection returned an unexpected error"
assert_no_sudo_calls "root Token load"
assert_file_has_no_token "$ROOT_TOKEN_OUTPUT"
printf 'PASS testing helpers reject root execution before reading Token data\n'

TEST_STAGE="ordinary-user Python environment"
reset_audit
"$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_TMPDIR" \
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

TEST_STAGE="missing root-only Token distinction"
reset_audit
mv "$TOKEN_FILE" "${TOKEN_FILE}.saved"
MISSING_OUTPUT="${TEST_ROOT}/missing.out"
if "$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_TMPDIR" \
  PATH="$AUDIT_PATH" \
  CF_AUDIT_LOG="$AUDIT_LOG" \
  CF_AUDIT_REAL_SUDO="$REAL_SUDO" \
  TOKEN_FILE="$TOKEN_FILE" \
  /bin/bash -c '
cd "$1"
_token_test_caller_path="$PATH"
source scripts/common.sh
if ! restore_testing_management_path "$_token_test_caller_path"; then
  error "$LAST_ERROR"
  exit 1
fi
unset _token_test_caller_path
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

TEST_STAGE="ordinary user without sudo"
NO_SUDO_OUTPUT="${TEST_ROOT}/no-sudo.out"
if timeout 15s sudo -u "$NO_SUDO_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$NO_SUDO_HOME" TMPDIR="$NO_SUDO_TMPDIR" \
  API_URL="http://127.0.0.1:${HTTP_PORT}" \
  WS_URL="ws://127.0.0.1:${WS_PORT}/api/ws/login" \
  TOKEN_FILE="$NO_SUDO_TOKEN_FILE" \
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

TEST_STAGE="root-only management file loading"
reset_audit
ROOT_CONFIG_OUTPUT="${TEST_ROOT}/root-config.out"
ROOT_CONFIG_ERROR="${TEST_ROOT}/root-config.error"
if ! "$REAL_SUDO" -u "$TEST_USER" -H env \
  CF_AGENT_WECHAT_TESTING=1 \
  "${TEST_MANAGEMENT_ENV[@]}" \
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
_management_test_caller_path="$PATH"
source scripts/common.sh
source scripts/qr-runtime-common.sh
if ! restore_testing_management_path "$_management_test_caller_path"; then
  printf "%s\n" "$LAST_ERROR" >&2
  exit 1
fi
unset _management_test_caller_path
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
