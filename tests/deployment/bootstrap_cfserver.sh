#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
BOOTSTRAP="$REPO_ROOT/scripts/bootstrap-cfserver.sh"
TEST_ROOT="$(mktemp -d /tmp/cf-agent-wechat-bootstrap.XXXXXX)"
IMAGE="registry.example/cf-agent-wechat@sha256:$(printf 'a%.0s' {1..64})"
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
REQUIRE_TEST="$(printenv CF_REQUIRE_BOOTSTRAP_DEPLOYMENT_TEST 2>/dev/null || printf 0)"
GATEWAY_RUNTIME_CONTROL="/opt/cf-agent-gateway/deploy/wechat-runtime-control"
STORAGE_ROOT="/srv/storage/cf-agent-wechat"
CONTROLLER_CREATED=0
STORAGE_RESERVED=0

cleanup() {
  set +e
  if [ "$STORAGE_RESERVED" -eq 1 ]; then
    case "$STORAGE_ROOT" in
      /srv/storage/cf-agent-wechat)
        sudo -n -- rm -rf -- "$STORAGE_ROOT" 2>/dev/null
        ;;
    esac
  fi
  if [ "$CONTROLLER_CREATED" -eq 1 ]; then
    sudo -n -- rm -f -- "$GATEWAY_RUNTIME_CONTROL" 2>/dev/null
    sudo -n -- rmdir /opt/cf-agent-gateway/deploy 2>/dev/null
    sudo -n -- rmdir /opt/cf-agent-gateway 2>/dev/null
  fi
  case "$TEST_ROOT" in
    /tmp/cf-agent-wechat-bootstrap.*)
      if command -v sudo >/dev/null 2>&1; then
        sudo -n -- rm -rf -- "$TEST_ROOT" 2>/dev/null
      else
        rm -rf -- "$TEST_ROOT" 2>/dev/null
      fi
      ;;
    *)
      printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_ROOT" >&2
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

skip() {
  if [ "$REQUIRE_TEST" = 1 ]; then
    fail "$*"
  fi
  printf 'SKIP: %s\n' "$*"
  exit 0
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || {
    sed -n '1,200p' "$file" >&2
    fail "missing expected output: $expected"
  }
}

assert_not_contains() {
  local file="$1" rejected="$2"
  if grep -Fq -- "$rejected" "$file"; then
    fail "sensitive or forbidden text was written to $file"
  fi
}

assert_no_lifecycle_commands() {
  local log_file="$MOCK_STATE/docker.log"
  [ ! -f "$log_file" ] || {
    if grep -Eq '(^|[[:space:]])(up|start|stop|restart|rm|down)([[:space:]]|$)' "$log_file"; then
      sed -n '1,200p' "$log_file" >&2
      fail "Bootstrap issued a Docker Compose lifecycle command"
    fi
  }
}

assert_process_reaped() {
  local pid_file="$1" label="$2" pid
  [ -s "$pid_file" ] || fail "$label did not record its PID"
  pid="$(cat "$pid_file")"
  for _ in {1..30}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return
    fi
    sleep 0.1
  done
  fail "$label left timed-out process $pid running"
}

case "$REQUIRE_TEST" in
  0|1) ;;
  *) fail "CF_REQUIRE_BOOTSTRAP_DEPLOYMENT_TEST must be 0 or 1" ;;
esac

case "$(uname -s)" in
  Linux) ;;
  *) skip "Bootstrap deployment test requires Linux" ;;
esac

[ "$CURRENT_UID" -ne 0 ] ||
  skip "Bootstrap deployment test requires an ordinary user"
command -v sudo >/dev/null 2>&1 ||
  skip "Bootstrap deployment test requires sudo"
sudo -n -- true >/dev/null 2>&1 ||
  skip "Bootstrap deployment test requires passwordless sudo"
for command_name in bash install openssl python3 realpath stat timeout; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "missing test prerequisite: $command_name"
done

[ ! -e "$STORAGE_ROOT" ] && [ ! -L "$STORAGE_ROOT" ] ||
  skip "Bootstrap deployment test requires an unused fixed storage path"
[ ! -e "$GATEWAY_RUNTIME_CONTROL" ] && [ ! -L "$GATEWAY_RUNTIME_CONTROL" ] ||
  skip "Bootstrap deployment test requires an unused fixed Controller path"
sudo -n -- install -d -o root -g root -m 755 /opt/cf-agent-gateway/deploy
sudo -n -- install -o root -g root -m 755 \
  "$REPO_ROOT/tests/helpers/mock_gateway_runtime_control.sh" \
  "$GATEWAY_RUNTIME_CONTROL"
CONTROLLER_CREATED=1
STORAGE_RESERVED=1

prepare_fixture() {
  local name="$1"

  if sudo -n -- test -e "$STORAGE_ROOT" ||
    sudo -n -- test -L "$STORAGE_ROOT"; then
    sudo -n -- rm -rf -- "$STORAGE_ROOT"
  fi

  SCENARIO_ROOT="$TEST_ROOT/$name"
  APP_ROOT="$SCENARIO_ROOT/agent"
  RUNTIME_ROOT="$STORAGE_ROOT/runtime"
  ARCHIVE_ROOT="$STORAGE_ROOT/session-archive"
  TOKEN_FILE="$STORAGE_ROOT/secrets/auth-token"
  AGENT_ENV="$APP_ROOT/docker/.env"
  AGENT_COMPOSE="$APP_ROOT/docker/compose.cfserver.yaml"
  MOCK_BIN="$SCENARIO_ROOT/bin"
  MOCK_STATE="$MOCK_BIN/state"
  OUTPUT="$SCENARIO_ROOT/bootstrap.out"
  DOCKER_SOCKET="$SCENARIO_ROOT/docker.sock"

  install -d -m 755 -- "$APP_ROOT/docker" "$MOCK_BIN" \
    "$MOCK_STATE" "$SCENARIO_ROOT/tmp"
  : > "$MOCK_STATE/controller.log"
  : > "$MOCK_STATE/controller-mutations.log"
  install -m 644 -- "$REPO_ROOT/docker/compose.cfserver.yaml" "$AGENT_COMPOSE"
  install -m 755 -- "$REPO_ROOT/tests/helpers/mock_bootstrap_docker.sh" \
    "$MOCK_BIN/docker"
  install -m 755 -- "$REPO_ROOT/tests/helpers/mock_bootstrap_systemctl.sh" \
    "$MOCK_BIN/systemctl"
  python3 - "$DOCKER_SOCKET" <<'PY'
import socket
import sys

server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.close()
PY
  {
    printf '%s\n' \
      '# managed production fixture' \
      '  # whitespace-prefixed comment' \
      "AGENT_WECHAT_IMAGE=$IMAGE" \
      'AGENT_WECHAT_BIND_IP=127.0.0.1' \
      'AGENT_WECHAT_PORT=6174' \
      'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat' \
      'COMPOSE_PROJECT_NAME=cf-agent-wechat' \
      "CF_AGENT_WECHAT_STORAGE_ROOT=$STORAGE_ROOT" \
      "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" \
      "CF_AGENT_WECHAT_ARCHIVE_ROOT=$ARCHIVE_ROOT" \
      'PROXY=' \
      'RUST_LOG=info'
  } > "$AGENT_ENV"
  chmod 600 "$AGENT_ENV"
  chmod 660 "$DOCKER_SOCKET"
}
run_bootstrap() {
  local output="$1" status=0
  shift
  env \
    -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    -u AGENT_WECHAT_IMAGE -u AGENT_WECHAT_BIND_IP -u AGENT_WECHAT_PORT \
    -u AGENT_WECHAT_CONTAINER_NAME -u COMPOSE_PROJECT_NAME -u PROXY -u RUST_LOG \
    -u CF_AGENT_WECHAT_STORAGE_ROOT -u CF_AGENT_WECHAT_RUNTIME_ROOT \
    -u CF_AGENT_WECHAT_ARCHIVE_ROOT -u CF_AGENT_WECHAT_TOKEN_FILE \
    -u SUDO_UID -u SUDO_GID \
    CF_BOOTSTRAP_TESTING=1 \
    CF_BOOTSTRAP_DOCKER_BIN="$MOCK_BIN/docker" \
    CF_BOOTSTRAP_SYSTEMCTL_BIN="$MOCK_BIN/systemctl" \
    CF_BOOTSTRAP_DOCKER_SOCKET_PATH="$DOCKER_SOCKET" \
    CF_BOOTSTRAP_DOCKER_TIMEOUT=2 \
    CF_BOOTSTRAP_COMPOSE_TIMEOUT=2 \
    CF_AGENT_WECHAT_ROOT="$APP_ROOT" \
    CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE" \
    CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV" \
    CF_AGENT_WECHAT_RUNTIME_UID="$CURRENT_UID" \
    CF_AGENT_WECHAT_RUNTIME_GID="$CURRENT_GID" \
    CF_AGENT_WECHAT_RUNTIME_MODE=700 \
    MOCK_GATEWAY_STATE_DIR="$MOCK_STATE" \
    MOCK_GATEWAY_LOG="$MOCK_STATE/controller.log" \
    MOCK_GATEWAY_MUTATION_LOG="$MOCK_STATE/controller-mutations.log" \
    TMPDIR="$SCENARIO_ROOT/tmp" \
    "$@" \
    /bin/bash "$BOOTSTRAP" > "$output" 2>&1 || status=$?
  assert_no_lifecycle_commands
  assert_controller_contract_only
  return "$status"
}
expect_failure() {
  local expected="$1"
  shift
  if run_bootstrap "$OUTPUT" "$@"; then
    fail "Bootstrap unexpectedly succeeded: $expected"
  fi
  assert_contains "$OUTPUT" "$expected"
}

prepare_fixture retry
touch "$MOCK_STATE/fail-agent-compose"
expect_failure 'production Compose validation failed'
sudo -n -- test -f "$TOKEN_FILE" ||
  fail "staged failure did not retain the Token"
TOKEN_BEFORE="$(sudo -n -- cat "$TOKEN_FILE")"
[ "$(printf '%s' "$TOKEN_BEFORE" | wc -c)" -eq 64 ] ||
  fail "generated Token length is invalid"
[ "$(sudo -n -- stat -c '%u:%g:%a:%h' "$TOKEN_FILE")" = '10001:10001:600:1' ] ||
  fail "generated Token is not 10001:10001 600 with one hard link"
[ ! -e "$RUNTIME_ROOT" ] || fail "Bootstrap created the fresh runtime root"
[ ! -e "$STORAGE_ROOT/data" ] || fail "Bootstrap created legacy data"
[ ! -e "$STORAGE_ROOT/wechat-home" ] || fail "Bootstrap created legacy WeChat HOME"
rm -f -- "$MOCK_STATE/fail-agent-compose"
SECOND_OUTPUT="$SCENARIO_ROOT/bootstrap-retry.out"
run_bootstrap "$SECOND_OUTPUT" || {
  sed -n '1,200p' "$SECOND_OUTPUT" >&2
  fail "retry after staged failure did not succeed"
}
TOKEN_AFTER="$(sudo -n -- cat "$TOKEN_FILE")"
[ "$TOKEN_AFTER" = "$TOKEN_BEFORE" ] || fail "Bootstrap retry replaced the Token"
[ ! -e "$RUNTIME_ROOT" ] || fail "successful Bootstrap created a WeChat runtime"
[ -z "$(sudo -n -- find "$ARCHIVE_ROOT" -mindepth 1 -print -quit)" ] ||
  fail "Bootstrap wrote runtime or secret data into the archive"
assert_contains "$SECOND_OUTPUT" './scripts/start-qr-login.sh'
assert_not_contains "$OUTPUT" "$TOKEN_BEFORE"
assert_not_contains "$SECOND_OUTPUT" "$TOKEN_BEFORE"
assert_not_contains "$MOCK_STATE/docker.log" "$TOKEN_BEFORE"
assert_not_contains "$AGENT_ENV" "$TOKEN_BEFORE"
if sudo -n -- grep -R -Fq -- "$TOKEN_BEFORE" "$ARCHIVE_ROOT"; then
  fail "Token content entered the archive"
fi
if grep -Eq 'BOOTSTRAPPED|INITIALIZED|session[.]marker' "$AGENT_ENV"; then
  fail "Bootstrap forged a login/session initialization marker"
fi
pass "staged Bootstrap is retryable, reuses its root-only Token, and creates no session"
prepare_fixture malicious-path
EVIL_BIN="$SCENARIO_ROOT/evil-bin"
EVIL_MARKER="$SCENARIO_ROOT/evil-executed"
install -d -m 755 -- "$EVIL_BIN"
for tool in docker openssl systemctl timeout; do
  printf '%s\n' \
    '#!/bin/sh' \
    'touch "${CF_EVIL_MARKER:?}"' \
    'exit 99' > "$EVIL_BIN/$tool"
  chmod 755 "$EVIL_BIN/$tool"
done
run_bootstrap "$OUTPUT" \
  "PATH=$EVIL_BIN:/usr/sbin:/usr/bin:/sbin:/bin" \
  "CF_EVIL_MARKER=$EVIL_MARKER" || {
  sed -n '1,200p' "$OUTPUT" >&2
  fail "Bootstrap allowed the caller PATH to replace trusted tools"
}
[ ! -e "$EVIL_MARKER" ] || fail "Bootstrap executed a caller-PATH tool"
pass "caller PATH cannot replace Docker, OpenSSL, systemctl, or timeout"

prepare_fixture unsafe-docker-tool
chmod 777 "$MOCK_BIN/docker"
expect_failure 'Docker CLI must not be group/other writable'
pass "unsafe Docker CLI metadata is rejected before privileged execution"

prepare_fixture docker-fallback
touch "$MOCK_STATE/deny-direct"
run_bootstrap "$OUTPUT" || {
  sed -n '1,200p' "$OUTPUT" >&2
  fail "Docker socket permission fallback did not succeed"
}
grep -Fq $'via_sudo=0\tinfo' "$MOCK_STATE/docker.log" ||
  fail "ordinary Docker access was not attempted first"
grep -Fq $'via_sudo=1\tinfo' "$MOCK_STATE/docker.log" ||
  fail "Docker access did not fall back to sudo -n"
[ "$(sudo -n -- stat -c '%u:%g:%a' "$TOKEN_FILE")" = '10001:10001:600' ] ||
  fail "ordinary-user flow did not retain the 10001:10001 Token contract"
pass "ordinary user authorizes once and uses Docker socket sudo fallback"

prepare_fixture root-protected-config
sudo -n -- chown 0:0 "$AGENT_ENV"
run_bootstrap "$OUTPUT" || {
  sed -n '1,200p' "$OUTPUT" >&2
  fail "root-protected Compose configuration did not use sudo -n"
}
grep -Fq $'via_sudo=0\tinfo' "$MOCK_STATE/docker.log" ||
  fail "root-protected config scenario did not probe Docker directly first"
grep -Fq $'via_sudo=1\tcompose' "$MOCK_STATE/docker.log" ||
  fail "root-protected Compose configuration was not rendered through sudo -n"
pass "root-only Compose environment uses the authorized sudo -n path"

prepare_fixture docker-host
expect_failure 'DOCKER_HOST cannot override the production local Docker daemon' \
  DOCKER_HOST=tcp://remote.invalid:2376
pass "DOCKER_HOST override is rejected before deployment mutation"
prepare_fixture socket-regular-file
rm -f -- "$DOCKER_SOCKET"
touch "$DOCKER_SOCKET"
expect_failure 'Docker socket must be a non-symlink Unix socket'
pass "regular file cannot impersonate the Docker socket"

prepare_fixture socket-symlink
mv -- "$DOCKER_SOCKET" "${DOCKER_SOCKET}.real"
ln -s -- "$(basename -- "${DOCKER_SOCKET}.real")" "$DOCKER_SOCKET"
expect_failure 'Docker socket must be a non-symlink Unix socket'
pass "Docker socket symlink is rejected"

prepare_fixture socket-world-writable
chmod 666 "$DOCKER_SOCKET"
expect_failure 'Docker socket must not be writable by other'
pass "world-writable Docker socket is rejected"


prepare_fixture remote-context
touch "$MOCK_STATE/remote-context"
expect_failure 'Docker context must be default'
pass "remote Docker context is rejected"

prepare_fixture rootless
touch "$MOCK_STATE/rootless"
expect_failure 'rootless Docker is not supported'
pass "rootless Docker is rejected"

prepare_fixture live-restore
touch "$MOCK_STATE/live-restore"
expect_failure 'Docker live-restore must be disabled'
pass "Docker live-restore is rejected"

prepare_fixture systemd
touch "$MOCK_STATE/systemd-offline"
expect_failure 'systemd must be running or degraded'
pass "unavailable systemd fails closed"

prepare_fixture agent-unit-enabled
touch "$MOCK_STATE/agent-unit-enabled"
expect_failure 'cf-agent-wechat.service must not be enabled for automatic boot'
[ ! -e "$STORAGE_ROOT" ] || fail "boot-unit rejection mutated deployment state"
pass "boot-enabled agent-wechat systemd unit is rejected"


prepare_fixture docker-timeout
touch "$MOCK_STATE/hang-info-once"
STARTED=$SECONDS
run_bootstrap "$OUTPUT" CF_BOOTSTRAP_DOCKER_TIMEOUT=1 || {
  sed -n '1,200p' "$OUTPUT" >&2
  fail "Docker timeout did not continue through the authorized fallback"
}
ELAPSED=$((SECONDS - STARTED))
[ "$ELAPSED" -le 6 ] || fail "Docker hard timeout exceeded six seconds"
assert_process_reaped "$MOCK_STATE/hang.pid" "Docker hard timeout"
pass "Docker commands have a hard timeout and timed-out children are reaped"

prepare_fixture compose-timeout
touch "$MOCK_STATE/hang-compose"
STARTED=$SECONDS
expect_failure 'production Compose validation failed' CF_BOOTSTRAP_COMPOSE_TIMEOUT=1
ELAPSED=$((SECONDS - STARTED))
[ "$ELAPSED" -le 4 ] || fail "Compose hard timeout exceeded four seconds"
assert_process_reaped "$MOCK_STATE/hang.pid" "Compose hard timeout"
pass "Compose rendering has a hard timeout and timed-out children are reaped"

prepare_fixture rendered-restart
touch "$MOCK_STATE/bad-compose-restart"
expect_failure 'Compose attestation failed: restart policy must be no'
pass "rendered Compose must attest restart=no"

prepare_fixture agent-running
touch "$MOCK_STATE/agent-running"
expect_failure 'agent-wechat is running'
pass "Bootstrap refuses a long-lived agent-wechat container"

prepare_fixture controller-contract-malformed
printf '%s\n' malformed > "$MOCK_STATE/contract_mode"
expect_failure 'Gateway Runtime Contract does not match required version 1'
[ ! -e "$STORAGE_ROOT" ] ||
  fail "invalid Controller contract mutated deployment state"
pass "malformed Gateway Runtime Contract fails closed before Bootstrap mutation"
prepare_fixture existing-restart
touch "$MOCK_STATE/agent-existing" "$MOCK_STATE/agent-bad-restart"
expect_failure 'existing agent-wechat container must use restart policy no'
pass "existing agent-wechat containers must use restart=no"

prepare_fixture env-symlink
mv -- "$AGENT_ENV" "$AGENT_ENV.real"
ln -s -- "$(basename -- "$AGENT_ENV.real")" "$AGENT_ENV"
expect_failure 'production environment file must be an existing non-symlink regular file'
pass "docker/.env symlink is rejected"

prepare_fixture env-hardlink
ln -- "$AGENT_ENV" "$AGENT_ENV.copy"
expect_failure 'production environment file must not have additional hard links'
pass "docker/.env hardlink is rejected"

prepare_fixture env-mode
chmod 666 "$AGENT_ENV"
expect_failure 'production environment file mode must be 600 or 640'
pass "unsafe docker/.env mode is rejected"

prepare_fixture env-owner
sudo -n -- chown 12345:12345 "$AGENT_ENV"
expect_failure 'production environment file must be owned by root or the fixed management user'
pass "unapproved docker/.env owner is rejected"

prepare_fixture env-assignment
sed -i 's|^PROXY=.*|PROXY=$(printf unsafe)|' "$AGENT_ENV"
expect_failure 'production environment values must be unquoted, literal, and whitespace-free'
[ ! -e "$STORAGE_ROOT" ] || fail "unsafe dotenv assignment mutated deployment state"
pass "unsafe docker/.env assignment is rejected without evaluation"

prepare_fixture env-path-mismatch
sed -i \
  "s|^CF_AGENT_WECHAT_ARCHIVE_ROOT=.*|CF_AGENT_WECHAT_ARCHIVE_ROOT=$STORAGE_ROOT/wrong-archive|" \
  "$AGENT_ENV"
expect_failure 'docker/.env archive root differs from the selected production archive root'
[ ! -e "$STORAGE_ROOT" ] || fail "mismatched docker/.env paths mutated deployment state"
pass "docker/.env management paths must match the selected deployment paths"

prepare_fixture repo-mode
chmod 777 "$APP_ROOT"
expect_failure 'repository root must not be group/other writable'
pass "group/other-writable repository is rejected"

prepare_fixture compose-symlink
mv -- "$AGENT_COMPOSE" "$AGENT_COMPOSE.real"
ln -s -- "$(basename -- "$AGENT_COMPOSE.real")" "$AGENT_COMPOSE"
expect_failure 'production Compose file must be an existing non-symlink regular file'
pass "production Compose symlink is rejected"

prepare_fixture compose-hardlink
ln -- "$AGENT_COMPOSE" "$AGENT_COMPOSE.copy"
expect_failure 'production Compose file must not have additional hard links'
pass "production Compose hardlink is rejected"

prepare_fixture env-relative-path
expect_failure 'production environment must be an absolute path' \
  CF_AGENT_WECHAT_ENV_FILE=relative-docker.env
pass "relative docker/.env path is rejected"

prepare_fixture env-duplicate-key
printf '%s\n' 'AGENT_WECHAT_PORT=6174' >> "$AGENT_ENV"
expect_failure 'production environment contains a duplicate key: AGENT_WECHAT_PORT'
pass "duplicate docker/.env keys are rejected"

prepare_fixture env-unknown-key
printf '%s\n' 'UNAPPROVED_SETTING=value' >> "$AGENT_ENV"
expect_failure 'production environment contains an unsupported key: UNAPPROVED_SETTING'
pass "unknown docker/.env keys are rejected"

prepare_fixture env-image-tag
sed -i 's|^AGENT_WECHAT_IMAGE=.*|AGENT_WECHAT_IMAGE=registry.example/cf-agent-wechat:latest|' "$AGENT_ENV"
expect_failure 'AGENT_WECHAT_IMAGE must be pinned to an immutable sha256 digest'
pass "mutable image tags are rejected"

prepare_fixture env-authenticated-proxy
sed -i 's|^PROXY=.*|PROXY=http://user:password@proxy.example:8080|' "$AGENT_ENV"
expect_failure 'PROXY must be unauthenticated'
pass "authenticated proxy URLs are rejected"

prepare_fixture token-hardlink
touch "$MOCK_STATE/fail-agent-compose"
expect_failure 'production Compose validation failed'
rm -f -- "$MOCK_STATE/fail-agent-compose"
TOKEN_VALUE="$(sudo -n -- cat "$TOKEN_FILE")"
sudo -n -- ln -- "$TOKEN_FILE" "$STORAGE_ROOT/secrets/auth-token.extra"
expect_failure 'auth Token has an unknown format'
assert_not_contains "$OUTPUT" "$TOKEN_VALUE"
assert_not_contains "$MOCK_STATE/docker.log" "$TOKEN_VALUE"
pass "Token hardlinks fail closed without disclosure"

prepare_fixture token-in-env
touch "$MOCK_STATE/fail-agent-compose"
expect_failure 'production Compose validation failed'
rm -f -- "$MOCK_STATE/fail-agent-compose"
TOKEN_VALUE="$(sudo -n -- cat "$TOKEN_FILE")"
printf '# embedded-token=%s\n' "$TOKEN_VALUE" >> "$AGENT_ENV"
expect_failure 'auth Token content must not appear in docker/.env'
assert_not_contains "$OUTPUT" "$TOKEN_VALUE"
assert_not_contains "$MOCK_STATE/docker.log" "$TOKEN_VALUE"
pass "embedded Token content is rejected without entering output or Docker logs"

printf '%s\n' 'All forced fresh QR Bootstrap deployment tests passed.'
