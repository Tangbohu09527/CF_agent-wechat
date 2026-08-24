#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
BOOTSTRAP="$REPO_ROOT/scripts/bootstrap-cfserver.sh"
TEST_ROOT="$(mktemp -d /tmp/cf-agent-wechat-bootstrap.XXXXXX)"
IMAGE="registry.example/cf-agent-wechat@sha256:$(printf 'a%.0s' {1..64})"
FIXTURE_TOKEN="$(printf 'c%.0s' {1..64})"
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
REQUIRE_TEST="$(printenv CF_REQUIRE_BOOTSTRAP_DEPLOYMENT_TEST 2>/dev/null || printf 0)"

cleanup() {
  case "$TEST_ROOT" in
    /tmp/cf-agent-wechat-bootstrap.*)
      if command -v sudo >/dev/null 2>&1; then
        sudo -n -- rm -rf -- "$TEST_ROOT" 2>/dev/null || true
      else
        rm -rf -- "$TEST_ROOT" 2>/dev/null || true
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

replace_agent_env_value() {
  local key="$1" value="$2"

  sed -i "s|^${key}=.*|${key}=${value}|" "$AGENT_ENV"
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
for command_name in bash install openssl python3 realpath setfacl stat timeout; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "missing test prerequisite: $command_name"
done

prepare_fixture() {
  local name="$1"
  SCENARIO_ROOT="$TEST_ROOT/$name"
  APP_ROOT="$SCENARIO_ROOT/agent"
  GATEWAY_PROJECT="$SCENARIO_ROOT/gateway"
  GATEWAY_DEPLOY="$GATEWAY_PROJECT/deploy"
  STORAGE_ROOT="$SCENARIO_ROOT/storage"
  RUNTIME_ROOT="$STORAGE_ROOT/runtime"
  ARCHIVE_ROOT="$STORAGE_ROOT/session-archive"
  GATEWAY_HEARTBEAT="$GATEWAY_DEPLOY/check-wechat-worker-heartbeat"
  GATEWAY_GATE="$GATEWAY_DEPLOY/wechat-runtime-release-gate"
  GATEWAY_CONTRACT="$GATEWAY_DEPLOY/wechat-runtime-contract.json"
  TOKEN_FILE="$STORAGE_ROOT/secrets/auth-token"
  AGENT_ENV="$APP_ROOT/docker/.env"
  AGENT_COMPOSE="$APP_ROOT/docker/compose.cfserver.yaml"
  GATEWAY_ENV="$GATEWAY_PROJECT/.env"
  GATEWAY_COMPOSE="$GATEWAY_PROJECT/docker-compose.prod.yml"
  MOCK_BIN="$SCENARIO_ROOT/bin"
  MOCK_STATE="$MOCK_BIN/state"
  OUTPUT="$SCENARIO_ROOT/bootstrap.out"
  DOCKER_SOCKET="$SCENARIO_ROOT/docker.sock"

  install -d -m 755 -- "$APP_ROOT/docker" "$GATEWAY_DEPLOY" "$MOCK_BIN" \
    "$MOCK_STATE" "$SCENARIO_ROOT/tmp"
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
      "CF_AGENT_WECHAT_RUNTIME_UID=$CURRENT_UID" \
      "CF_AGENT_WECHAT_RUNTIME_GID=$CURRENT_GID" \
      'CF_AGENT_WECHAT_RUNTIME_MODE=700' \
      "CF_AGENT_WECHAT_MANAGEMENT_GID=$CURRENT_GID" \
      'CF_AGENT_WECHAT_MIN_FREE_BYTES=1' \
      'CF_AGENT_WECHAT_MIN_FREE_PERCENT=0' \
      'CF_AGENT_WECHAT_MIN_FREE_INODES=1' \
      'CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES=1000' \
      'CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES=1048576' \
      'PROXY=' \
      'RUST_LOG=info'
  } > "$AGENT_ENV"
  chmod 600 "$AGENT_ENV"
  {
    printf '%s\n' \
      'services:' \
      '  worker:' \
      '    image: registry.example/gateway@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  } > "$GATEWAY_COMPOSE"
  printf '%s\n' \
    'GATEWAY_ENV=production' \
    'CF_AGENT_WECHAT_TOKEN_FILE=/run/secrets/cf-agent-wechat-auth-token' > "$GATEWAY_ENV"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$GATEWAY_HEARTBEAT"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$GATEWAY_GATE"
  python3 - "$GATEWAY_CONTRACT" "$TOKEN_FILE" "$GATEWAY_HEARTBEAT" \
    "$GATEWAY_GATE" <<'PY'
import hashlib
import json
import sys

contract_file, token_file, checker, gate = sys.argv[1:]
with open(checker, "rb") as stream:
    checker_sha256 = hashlib.sha256(stream.read()).hexdigest()
with open(gate, "rb") as stream:
    gate_sha256 = hashlib.sha256(stream.read()).hexdigest()
with open(contract_file, "w", encoding="utf-8") as stream:
    json.dump({
        "contractVersion": "1",
        "producer": {
            "repository": "Tangbohu09527/CF_agent-gateway",
            "checkerSha256": checker_sha256,
            "releaseGateSha256": gate_sha256,
        },
        "agent": {
            "networkAlias": "cf-agent-wechat",
            "port": 6174,
            "tokenAuthority": {
                "hostPath": token_file,
                "ownership": "root:root",
                "mode": "0600",
            },
        },
        "gateway": {
            "service": "worker",
            "composeProject": "cf-agent-gateway",
            "checker": checker,
            "checkerInterfaceVersion": 1,
            "checkerRequest": {
                "inputTransport": "stdin-json",
                "inputSchemaVersion": 1,
                "maxInputBytes": 4096,
                "hardTimeoutSeconds": 10,
                "requestFields": [
                    "schemaVersion",
                    "generationId",
                    "agentContainerId",
                    "workerContainerId",
                ],
                "binding": {
                    "generationId": "lowercase-hex-64",
                    "agentContainerId": "lowercase-hex-64",
                    "workerContainerId": "lowercase-hex-64",
                },
            },
            "heartbeatMaxAgeSeconds": 30,
            "requiresDockerHealth": True,
            "requiresSuccessfulPoll": True,
            "requiresLoggedIn": True,
            "silentOutput": True,
            "checkerExecution": {
                "caller": "management-user",
                "sudo": False,
                "dockerSocketAccess": False,
                "producerLinuxProof": "required",
            },
            "releaseGate": {
                "command": gate,
                "interfaceVersion": 1,
                "inputTransport": "stdin-json",
                "inputSchemaVersion": 1,
                "maxInputBytes": 4096,
                "hardTimeoutSeconds": 10,
                "silentOutput": True,
                "execution": {
                    "caller": "management-user",
                    "sudo": False,
                    "dockerSocketAccess": False,
                    "producerLinuxProof": "required",
                },
                "identifierFormats": {
                    "generationId": "lowercase-hex-64",
                    "agentContainerId": "lowercase-hex-64",
                    "workerContainerId": "lowercase-hex-64",
                },
                "operations": {
                    "begin": {
                        "requestFields": [
                            "schemaVersion",
                            "operation",
                            "generationId",
                        ],
                        "invalidatesPreviousReleases": True,
                    },
                    "assert-pending": {
                        "requestFields": [
                            "schemaVersion",
                            "operation",
                            "generationId",
                        ],
                        "requiresCurrentUnreleasedGeneration": True,
                    },
                    "release": {
                        "requestFields": [
                            "schemaVersion",
                            "operation",
                            "generationId",
                            "agentContainerId",
                            "workerContainerId",
                        ],
                        "requiresCurrentUnreleasedGeneration": True,
                        "agentContainerBinding": "exact",
                        "workerContainerBinding": "exact-stopped-candidate",
                    },
                    "abort": {
                        "requestFields": [
                            "schemaVersion",
                            "operation",
                            "generationId",
                        ],
                        "revokesGeneration": True,
                    },
                },
                "workerAuthorization": {
                    "default": "deny",
                    "requiresExactCurrentRelease": True,
                },
            },
            "lifecycle": {
                "restartPolicy": "no",
                "bootPolicy": "manual-after-fresh-qr",
                "producerLinuxProof": "required",
            },
            "credential": {
                "type": "file",
                "environmentVariable": "CF_AGENT_WECHAT_TOKEN_FILE",
                "workerPath": "/run/secrets/cf-agent-wechat-auth-token",
                "readOnly": True,
                "forbiddenEnvironmentVariable": "CF_AGENT_WECHAT_TOKEN",
                "workerReadabilityProof": "producer-linux-integration",
            },
        },
    }, stream)
PY
  chmod 644 "$GATEWAY_COMPOSE"
  chmod 644 "$GATEWAY_CONTRACT"
  chmod 600 "$GATEWAY_ENV"
  chmod 755 "$GATEWAY_HEARTBEAT"
  chmod 755 "$GATEWAY_GATE"
  chmod 660 "$DOCKER_SOCKET"
  sudo -n -- install -d -o 0 -g 0 -m 700 -- "$STORAGE_ROOT/secrets"
  printf '%s\n' "$FIXTURE_TOKEN" |
    sudo -n -- tee "$TOKEN_FILE" >/dev/null
  sudo -n -- chown 0:0 "$TOKEN_FILE"
  sudo -n -- chmod 600 "$TOKEN_FILE"
}

run_bootstrap() {
  local output="$1" status=0
  shift
  env \
    -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    -u AGENT_WECHAT_IMAGE -u AGENT_WECHAT_BIND_IP -u AGENT_WECHAT_PORT \
    -u AGENT_WECHAT_CONTAINER_NAME -u COMPOSE_PROJECT_NAME -u PROXY -u RUST_LOG \
    -u CF_AGENT_WECHAT_TOKEN_FILE -u SUDO_UID -u SUDO_GID -u SUDO_USER \
    CF_BOOTSTRAP_TESTING=1 \
    CF_AGENT_WECHAT_TEST_ROOT="$SCENARIO_ROOT" \
    CF_BOOTSTRAP_DOCKER_BIN="$MOCK_BIN/docker" \
    CF_BOOTSTRAP_SYSTEMCTL_BIN="$MOCK_BIN/systemctl" \
    CF_BOOTSTRAP_DOCKER_SOCKET_PATH="$DOCKER_SOCKET" \
    CF_BOOTSTRAP_DOCKER_TIMEOUT=2 \
    CF_BOOTSTRAP_COMPOSE_TIMEOUT=2 \
    CF_AGENT_WECHAT_ROOT="$APP_ROOT" \
    CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE" \
    CF_AGENT_WECHAT_ENV_FILE="$AGENT_ENV" \
    CF_AGENT_WECHAT_STORAGE_ROOT="$STORAGE_ROOT" \
    CF_AGENT_WECHAT_RUNTIME_ROOT="$RUNTIME_ROOT" \
    CF_AGENT_WECHAT_ARCHIVE_ROOT="$ARCHIVE_ROOT" \
    CF_AGENT_WECHAT_RUNTIME_UID="$CURRENT_UID" \
    CF_AGENT_WECHAT_RUNTIME_GID="$CURRENT_GID" \
    CF_AGENT_WECHAT_RUNTIME_MODE=700 \
    CF_AGENT_GATEWAY_PROJECT_DIR="$GATEWAY_PROJECT" \
    CF_AGENT_GATEWAY_COMPOSE_FILE="$GATEWAY_COMPOSE" \
    CF_AGENT_GATEWAY_ENV_FILE="$GATEWAY_ENV" \
    TMPDIR="$SCENARIO_ROOT/tmp" \
    "$@" \
    /bin/bash "$BOOTSTRAP" > "$output" 2>&1 || status=$?
  assert_no_lifecycle_commands
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

expect_production_override_failure() {
  local variable="$1" value="$2"
  local output="$TEST_ROOT/production-${variable}.out"

  if /usr/bin/env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    "${variable}=${value}" \
    /bin/bash -p "$BOOTSTRAP" >"$output" 2>&1; then
    fail "production Bootstrap accepted $variable"
  fi
  assert_contains "$output" \
    "$variable is forbidden as a production Bootstrap environment override"
  assert_not_contains "$output" "$value"
}

expect_production_override_failure CF_BOOTSTRAP_DOCKER_TIMEOUT 424242
expect_production_override_failure CF_BOOTSTRAP_COMPOSE_TIMEOUT 424243
expect_production_override_failure TOKEN_FILE /attacker/secret-sentinel
expect_production_override_failure \
  CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT \
  /attacker/release-gate-sentinel
pass "production Bootstrap rejects inherited overrides without echoing their values"

PRODUCTION_IDENTITY_OUTPUT="$TEST_ROOT/production-identity.out"
if /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  CF_BOOTSTRAP_TESTING=invalid \
  SUDO_UID=2147483646 SUDO_GID=2147483646 \
  /bin/bash -p "$BOOTSTRAP" >"$PRODUCTION_IDENTITY_OUTPUT" 2>&1; then
  fail "production identity validation unexpectedly succeeded"
fi
assert_contains "$PRODUCTION_IDENTITY_OUTPUT" \
  'CF_BOOTSTRAP_TESTING must be 0 or 1'
assert_not_contains "$PRODUCTION_IDENTITY_OUTPUT" 'invalid'
assert_not_contains "$PRODUCTION_IDENTITY_OUTPUT" \
  'TOKEN_FILE is forbidden as a production Bootstrap environment override'
pass "invalid Bootstrap test mode is rejected without echoing its value"

PRODUCTION_TEST_MODE_OUTPUT="$TEST_ROOT/production-test-mode.out"
if /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  CF_BOOTSTRAP_TESTING=1 \
  AUTH_TOKEN=bootstrap-test-mode-secret-never-print \
  /bin/bash -p "$BOOTSTRAP" >"$PRODUCTION_TEST_MODE_OUTPUT" 2>&1; then
  fail "production Bootstrap accepted isolated test mode without CI gates"
fi
assert_contains "$PRODUCTION_TEST_MODE_OUTPUT" \
  'CF_BOOTSTRAP_TESTING=1 requires the isolated GitHub Actions deployment test gate'
assert_not_contains "$PRODUCTION_TEST_MODE_OUTPUT" \
  'bootstrap-test-mode-secret-never-print'
pass "Bootstrap test mode 1 is rejected outside the isolated CI gate"

PRODUCTION_ZERO_OUTPUT="$TEST_ROOT/production-test-mode-zero.out"
if /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  CF_BOOTSTRAP_TESTING=0 \
  TOKEN_FILE=/attacker/bootstrap-zero-secret-never-print \
  /bin/bash -p "$BOOTSTRAP" >"$PRODUCTION_ZERO_OUTPUT" 2>&1; then
  fail "Bootstrap test mode 0 bypassed production override rejection"
fi
assert_contains "$PRODUCTION_ZERO_OUTPUT" \
  'TOKEN_FILE is forbidden as a production Bootstrap environment override'
assert_not_contains "$PRODUCTION_ZERO_OUTPUT" \
  'bootstrap-zero-secret-never-print'
pass "Bootstrap test mode 0 follows the production contract"

pass "internal management variables do not self-trigger and sudo metadata is not an authority"

prepare_fixture sudo-identity-spoof
run_identity_scenario() {
  local label="$1"
  shift

  run_bootstrap "$OUTPUT" "$@" || {
    sed -n '1,200p' "$OUTPUT" >&2
    fail "$label changed the trusted management identity"
  }
  [ "$(sudo -n -- stat -c '%u:%g:%a:%h' "$TOKEN_FILE")" = '0:0:600:1' ] ||
    fail "$label weakened the root-only Token contract"
  pass "$label cannot change management identity approval"
}

run_identity_scenario "ordinary-user execution through real test sudo"
run_identity_scenario "combined SUDO identity spoofing" \
  SUDO_UID=0 SUDO_GID=0 SUDO_USER=root
run_identity_scenario "single SUDO_UID spoofing" SUDO_UID=0
run_identity_scenario "single SUDO_GID spoofing" SUDO_GID=0
run_identity_scenario "single SUDO_USER spoofing" SUDO_USER=root
run_identity_scenario "invalid numeric SUDO identity metadata" \
  SUDO_UID=not-a-number SUDO_GID=-1
run_identity_scenario "mismatched SUDO username and numeric identity" \
  SUDO_UID=0 SUDO_GID=0 SUDO_USER=nobody
unset -f run_identity_scenario

prepare_fixture docker-timeout-upper-bound
expect_failure \
  'CF_BOOTSTRAP_DOCKER_TIMEOUT must not exceed 120 seconds in testing mode' \
  CF_BOOTSTRAP_DOCKER_TIMEOUT=121
pass "test Docker timeout has a bounded maximum"

prepare_fixture compose-timeout-upper-bound
expect_failure \
  'CF_BOOTSTRAP_COMPOSE_TIMEOUT must not exceed 300 seconds in testing mode' \
  CF_BOOTSTRAP_COMPOSE_TIMEOUT=301
pass "test Compose timeout has a bounded maximum"

prepare_fixture oversized-timeout
OVERSIZED_TIMEOUT=999999999999999999999999999999999999999999
expect_failure \
  'CF_BOOTSTRAP_DOCKER_TIMEOUT must not exceed 120 seconds in testing mode' \
  "CF_BOOTSTRAP_DOCKER_TIMEOUT=$OVERSIZED_TIMEOUT"
assert_not_contains "$OUTPUT" "$OVERSIZED_TIMEOUT"
pass "oversized timeout values fail closed without entering error output"

INT64_MAX=9223372036854775807
INT64_OVERFLOW=9223372036854775808
OVERSIZED_DECIMAL="$(printf '9%.0s' {1..128})"
prepare_fixture numeric-boundary
replace_agent_env_value CF_AGENT_WECHAT_MIN_FREE_BYTES "$INT64_MAX"
replace_agent_env_value CF_AGENT_WECHAT_MIN_FREE_PERCENT 100
replace_agent_env_value CF_AGENT_WECHAT_MIN_FREE_INODES "$INT64_MAX"
replace_agent_env_value CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES 200000
replace_agent_env_value CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES "$INT64_MAX"
run_bootstrap "$OUTPUT" || {
  sed -n '1,200p' "$OUTPUT" >&2
  fail "Bootstrap rejected exact signed 64-bit numeric boundaries"
}
assert_no_lifecycle_commands
pass "Bootstrap accepts exact approved numeric boundaries without lifecycle changes"
pass "Bootstrap test mode 1 is accepted only by the isolated CI fixture gate"

for numeric_contract in \
  'AGENT_WECHAT_PORT|65536' \
  'CF_AGENT_WECHAT_RUNTIME_UID|4294967295' \
  'CF_AGENT_WECHAT_RUNTIME_GID|4294967295' \
  'CF_AGENT_WECHAT_MANAGEMENT_GID|4294967295'; do
  IFS='|' read -r numeric_key numeric_value <<< "$numeric_contract"
  prepare_fixture "numeric-contract-${numeric_key,,}"
  replace_agent_env_value "$numeric_key" "$numeric_value"
  expect_failure 'docker/.env failed byte-safe validation'
  assert_no_lifecycle_commands
done
pass "Bootstrap rejects out-of-range ports and IDs without lifecycle changes"

for numeric_key in \
  CF_AGENT_WECHAT_MIN_FREE_BYTES \
  CF_AGENT_WECHAT_MIN_FREE_INODES \
  CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES; do
  prepare_fixture "numeric-overflow-${numeric_key,,}"
  replace_agent_env_value "$numeric_key" "$INT64_OVERFLOW"
  expect_failure 'docker/.env failed byte-safe validation'
  assert_not_contains "$OUTPUT" "$INT64_OVERFLOW"
  assert_no_lifecycle_commands

  prepare_fixture "numeric-oversized-${numeric_key,,}"
  replace_agent_env_value "$numeric_key" "$OVERSIZED_DECIMAL"
  expect_failure 'docker/.env failed byte-safe validation'
  assert_not_contains "$OUTPUT" "$OVERSIZED_DECIMAL"
  assert_no_lifecycle_commands
done
prepare_fixture numeric-scanner-files
replace_agent_env_value CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES 200001
expect_failure 'CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES must not exceed the compiled scanner limit'
assert_no_lifecycle_commands
prepare_fixture numeric-percent
replace_agent_env_value CF_AGENT_WECHAT_MIN_FREE_PERCENT 000
expect_failure 'docker/.env failed byte-safe validation'
assert_no_lifecycle_commands
pass "Bootstrap rejects overflow, overlong, scanner-limit, and non-canonical percent values"

prepare_fixture inherited-storage-default-acl
sudo -n -- rm -rf -- "$STORAGE_ROOT"
setfacl -m d:u:65534:rwx "$SCENARIO_ROOT"
expect_failure +  'storage root must be a stable no-follow directory without extended attributes or ACLs'
sudo -n -- test -d "$STORAGE_ROOT" ||
  fail "default-ACL fixture did not reach managed storage creation"
sudo -n -- test ! -e "$TOKEN_FILE" ||
  fail "Bootstrap created a Token after inherited storage ACL rejection"
pass "Bootstrap rejects a default ACL inherited during managed storage creation"

prepare_fixture archive-default-acl
sudo -n -- install -d -o 0 -g 0 -m 700 -- "$ARCHIVE_ROOT"
sudo -n -- setfacl -m d:u:65534:rwx "$ARCHIVE_ROOT"
expect_failure +  'archive root must be a stable no-follow directory without extended attributes or ACLs'
pass "Bootstrap rejects default ACLs on the Archive root"

prepare_fixture secrets-default-acl
sudo -n -- setfacl -m d:u:65534:rwx "$STORAGE_ROOT/secrets"
expect_failure +  'secrets directory must be a stable no-follow directory without extended attributes or ACLs'
pass "Bootstrap rejects default ACLs on the secrets directory"

prepare_fixture retry
sudo -n -- rm -rf -- "$STORAGE_ROOT"
printf '%s\n' 'GATEWAY_ENV=production' > "$GATEWAY_ENV"
chmod 600 "$GATEWAY_ENV"
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
sudo -n -- test -f "$TOKEN_FILE" ||
  fail "Gateway contract staging failure did not retain the generated Token"
TOKEN_BEFORE="$(sudo -n -- cat "$TOKEN_FILE")"
printf '%s\n' \
  'GATEWAY_ENV=production' \
  'CF_AGENT_WECHAT_TOKEN_FILE=/run/secrets/cf-agent-wechat-auth-token' > "$GATEWAY_ENV"
chmod 600 "$GATEWAY_ENV"
touch "$MOCK_STATE/fail-agent-compose"
expect_failure 'production Compose validation failed'
[ "$(printf '%s' "$TOKEN_BEFORE" | wc -c)" -eq 64 ] ||
  fail "generated Token length is invalid"
[ "$(sudo -n -- stat -c '%u:%g:%a:%h' "$TOKEN_FILE")" = '0:0:600:1' ] ||
  fail "generated Token is not root:root 600 with one hard link"
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
[ "$(sudo -n -- stat -c '%u:%g:%a' "$TOKEN_FILE")" = '0:0:600' ] ||
  fail "ordinary-user flow did not retain a root-only Token"
pass "ordinary user authorizes once and uses Docker socket sudo fallback"

prepare_fixture root-protected-config
sudo -n -- chown 0:0 "$AGENT_ENV" "$GATEWAY_ENV"
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
expect_failure 'systemd state probe failed or systemd is not running or degraded'
pass "unavailable systemd fails closed"

prepare_fixture systemd-partial-timeout
touch "$MOCK_STATE/systemd-partial-timeout"
expect_failure 'systemd state probe failed' CF_BOOTSTRAP_DOCKER_TIMEOUT=1
[ ! -e "$ARCHIVE_ROOT" ] || fail "timed-out systemd state probe mutated deployment state"
pass "partial systemd state output followed by a hard timeout fails closed"

prepare_fixture agent-activity-partial-timeout
touch "$MOCK_STATE/agent-activity-partial-timeout"
expect_failure 'activity probe failed' CF_BOOTSTRAP_DOCKER_TIMEOUT=1
[ ! -e "$ARCHIVE_ROOT" ] || fail "timed-out agent activity probe mutated deployment state"
pass "partial inactive output followed by a hard timeout fails closed"

prepare_fixture agent-enablement-partial-timeout
touch "$MOCK_STATE/agent-enablement-partial-timeout"
expect_failure 'enablement probe failed' CF_BOOTSTRAP_DOCKER_TIMEOUT=1
[ ! -e "$ARCHIVE_ROOT" ] || fail "timed-out enablement probe mutated deployment state"
pass "partial not-found output followed by a hard timeout fails closed"

prepare_fixture agent-unit-active
touch "$MOCK_STATE/agent-unit-active"
expect_failure 'cf-agent-wechat.service must be inactive'
[ ! -e "$ARCHIVE_ROOT" ] || fail "active Agent unit rejection mutated deployment state"
pass "active but boot-disabled cf-agent-wechat.service is rejected"

prepare_fixture hidden-agent-unit-active
touch "$MOCK_STATE/hidden-agent-unit-active"
expect_failure 'an active systemd unit could supervise agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "hidden active unit rejection mutated deployment state"
pass "active generic service content cannot hide Agent startup"

prepare_fixture generic-agent-timer-active
touch "$MOCK_STATE/generic-agent-timer-active"
expect_failure 'systemd timer could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "active timer rejection mutated deployment state"
pass "active timer activation target is inspected"

prepare_fixture generic-agent-path-active
touch "$MOCK_STATE/generic-agent-path-active"
expect_failure 'systemd path unit could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "active path rejection mutated deployment state"
pass "active path activation target is inspected"

prepare_fixture generic-agent-socket-active
touch "$MOCK_STATE/generic-agent-socket-active"
expect_failure 'systemd socket could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "active socket rejection mutated deployment state"
pass "active socket activation target is inspected"

prepare_fixture generic-agent-target-active
touch "$MOCK_STATE/generic-agent-target-active"
expect_failure 'systemd target could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "active target rejection mutated deployment state"
pass "active target dependency is inspected"

prepare_fixture agent-unit-enabled
touch "$MOCK_STATE/agent-unit-enabled"
expect_failure 'cf-agent-wechat.service must not be enabled for automatic boot'
[ ! -e "$ARCHIVE_ROOT" ] || fail "boot-unit rejection mutated deployment state"
pass "boot-enabled agent-wechat systemd unit is rejected"
prepare_fixture agent-unit-enable-unknown
touch "$MOCK_STATE/agent-unit-enable-unknown"
expect_failure 'cf-agent-wechat.service enablement could not be determined safely'
[ ! -e "$ARCHIVE_ROOT" ] || fail "unknown boot-unit state mutated deployment state"
pass "unknown agent-wechat systemd enablement state fails closed"

prepare_fixture agent-unit-enable-error
touch "$MOCK_STATE/agent-unit-enable-error"
expect_failure 'cf-agent-wechat.service enablement could not be determined safely'
[ ! -e "$ARCHIVE_ROOT" ] || fail "failed boot-unit probe mutated deployment state"
pass "failed agent-wechat systemd enablement probe fails closed"


prepare_fixture alternate-agent-unit-enabled
touch "$MOCK_STATE/alternate-agent-unit-enabled"
expect_failure 'an enabled systemd unit could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "alternate boot-unit rejection mutated deployment state"
pass "alternate enabled agent-wechat systemd unit is rejected"

prepare_fixture hidden-agent-unit-enabled
touch "$MOCK_STATE/hidden-agent-unit-enabled"
expect_failure 'an enabled systemd unit could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "hidden boot-unit rejection mutated deployment state"
pass "enabled systemd Unit content cannot hide agent-wechat automatic startup"

prepare_fixture unreadable-agent-unit-enabled
touch "$MOCK_STATE/unreadable-agent-unit-enabled"
expect_failure 'enabled systemd unit definitions could not be inspected'
[ ! -e "$ARCHIVE_ROOT" ] || fail "unreadable boot-unit rejection mutated deployment state"
pass "unreadable enabled systemd Unit definitions fail closed"

prepare_fixture generic-agent-service-enabled
touch "$MOCK_STATE/generic-agent-service-enabled"
expect_failure 'an enabled systemd unit could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "generic service rejection mutated deployment state"
pass "a generic linked service cannot hide agent-wechat Compose startup"

prepare_fixture generic-agent-timer-enabled
touch "$MOCK_STATE/generic-agent-timer-enabled"
expect_failure 'an enabled systemd timer could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "generic timer rejection mutated deployment state"
pass "an enabled generic timer is followed one hop to its agent startup service"
prepare_fixture default-agent-timer-enabled
touch "$MOCK_STATE/default-agent-timer-enabled"
expect_failure 'an enabled systemd timer could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "default timer target rejection mutated deployment state"
pass "an enabled timer without Unit uses and inspects its same-name service"

prepare_fixture generic-agent-path-enabled
touch "$MOCK_STATE/generic-agent-path-enabled"
expect_failure 'an enabled systemd path unit could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "explicit path rejection mutated deployment state"
pass "an enabled path follows its explicit Unit to the agent startup service"

prepare_fixture default-agent-path-enabled
touch "$MOCK_STATE/default-agent-path-enabled"
expect_failure 'an enabled systemd path unit could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "default path rejection mutated deployment state"
pass "an enabled path follows its resolved same-name service"

prepare_fixture generic-agent-socket-enabled
touch "$MOCK_STATE/generic-agent-socket-enabled"
expect_failure 'an enabled systemd socket could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "explicit socket rejection mutated deployment state"
pass "an enabled socket follows its explicit Service to the agent startup service"

prepare_fixture default-agent-socket-enabled
touch "$MOCK_STATE/default-agent-socket-enabled"
expect_failure 'an enabled systemd socket could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "default socket rejection mutated deployment state"
pass "an enabled socket follows its resolved same-name service"

prepare_fixture generic-agent-target-wants-enabled
touch "$MOCK_STATE/generic-agent-target-wants-enabled"
expect_failure 'an enabled systemd target could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "target Wants rejection mutated deployment state"
pass "an enabled target inspects every resolved Wants dependency"

prepare_fixture generic-agent-target-requires-enabled
touch "$MOCK_STATE/generic-agent-target-requires-enabled"
expect_failure 'an enabled systemd target could automatically start agent-wechat'
[ ! -e "$ARCHIVE_ROOT" ] || fail "target Requires rejection mutated deployment state"
pass "an enabled target inspects every resolved Requires dependency"

prepare_fixture malformed-activation-target
touch "$MOCK_STATE/malformed-activation-target"
expect_failure 'enabled systemd timer target is missing or ambiguous'
[ ! -e "$ARCHIVE_ROOT" ] || fail "malformed activation target mutated deployment state"
pass "ambiguous activation targets fail closed"

prepare_fixture unknown-activation-target
touch "$MOCK_STATE/unknown-activation-target"
expect_failure 'enabled systemd path target must resolve to a service unit'
[ ! -e "$ARCHIVE_ROOT" ] || fail "unknown activation target mutated deployment state"
pass "unsupported activation target types fail closed"

prepare_fixture activation-show-failure
touch "$MOCK_STATE/activation-show-failure"
expect_failure 'enabled systemd socket target could not be resolved safely'
[ ! -e "$ARCHIVE_ROOT" ] || fail "activation inspection failure mutated deployment state"
pass "activation property inspection failures fail closed"

prepare_fixture templated-socket-enabled
touch "$MOCK_STATE/templated-socket-enabled"
expect_failure 'enabled systemd socket target uses unsupported templated activation'
[ ! -e "$ARCHIVE_ROOT" ] || fail "templated socket rejection mutated deployment state"
pass "ambiguous templated socket activation fails closed"

prepare_fixture generic-unit-cat-failure
touch "$MOCK_STATE/generic-unit-cat-failure"
expect_failure 'enabled systemd unit definitions could not be inspected'
[ ! -e "$ARCHIVE_ROOT" ] || fail "systemd cat failure mutated deployment state"
pass "systemd cat failure for a generic enabled unit fails closed"

prepare_fixture docker-unit-cat-failure
touch "$MOCK_STATE/docker-unit-cat-failure"
expect_failure 'enabled systemd unit definitions could not be inspected'
[ ! -e "$ARCHIVE_ROOT" ] || fail "docker.service cat failure mutated deployment state"
pass "docker.service is included in enabled-unit definition inspection"


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

prepare_fixture rendered-image
touch "$MOCK_STATE/bad-compose-image"
expect_failure 'Compose attestation failed: image is not the approved digest-pinned reference'
pass "rendered Compose image must exactly match docker/.env"

prepare_fixture rendered-container
touch "$MOCK_STATE/bad-compose-container"
expect_failure 'Compose attestation failed: container name differs from the approved docker/.env value'
pass "rendered Compose container name must exactly match docker/.env"

prepare_fixture rendered-project
touch "$MOCK_STATE/bad-compose-project"
expect_failure 'Compose attestation failed: project name differs from the approved docker/.env value'
pass "rendered Compose project name must exactly match docker/.env"

prepare_fixture rendered-proxy
touch "$MOCK_STATE/bad-compose-proxy"
expect_failure 'Compose attestation failed: PROXY differs from the approved docker/.env value'
pass "rendered Compose PROXY must exactly match docker/.env"

prepare_fixture rendered-rust-log
touch "$MOCK_STATE/bad-compose-rust-log"
expect_failure 'Compose attestation failed: RUST_LOG differs from the approved docker/.env value'
pass "rendered Compose RUST_LOG must exactly match docker/.env"

prepare_fixture rendered-environment
touch "$MOCK_STATE/bad-compose-environment"
expect_failure 'Compose attestation failed: service environment differs from the exact approved values'
pass "rendered Compose environment must contain only the exact approved values"

prepare_fixture rendered-health-interval
touch "$MOCK_STATE/bad-compose-health-interval"
expect_failure 'Compose attestation failed: healthcheck timing contract is invalid'
pass "rendered Compose healthcheck interval must be exactly 30s"

prepare_fixture rendered-health-start-period
touch "$MOCK_STATE/bad-compose-health-start-period"
expect_failure 'Compose attestation failed: healthcheck timing contract is invalid'
pass "rendered Compose healthcheck start period must be exactly 1m30s"

prepare_fixture rendered-stop-grace-period
touch "$MOCK_STATE/bad-compose-stop-grace-period"
expect_failure 'Compose attestation failed: stop grace period must be exactly 30s'
pass "rendered Compose stop grace period must be exactly 30s"

prepare_fixture rendered-bind-options
touch "$MOCK_STATE/bad-compose-bind-options"
expect_failure 'Compose attestation failed: /data bind options differ from the approved set'
pass "rendered Compose bind options must disable host-path creation without extras"

prepare_fixture rendered-process-override
touch "$MOCK_STATE/bad-compose-process-override"
expect_failure 'Compose attestation failed: service contains an unapproved process or lifecycle override'
pass "rendered Compose cannot override the image process command"

prepare_fixture rendered-lifecycle-override
touch "$MOCK_STATE/bad-compose-lifecycle-override"
expect_failure 'Compose attestation failed: service contains an unapproved process or lifecycle override'
pass "rendered Compose cannot add an automatic activation profile"

prepare_fixture compose-host-overrides
run_bootstrap "$OUTPUT" \
  AGENT_WECHAT_IMAGE=registry.example/attacker:latest \
  AGENT_WECHAT_CONTAINER_NAME=wrong-container \
  COMPOSE_PROJECT_NAME=wrong-project \
  PROXY=http://wrong-proxy.invalid:8080 \
  RUST_LOG=debug || {
  sed -n '1,200p' "$OUTPUT" >&2
  fail "caller environment overrode the authoritative docker/.env values"
}
pass "caller Compose environment cannot override approved docker/.env values"

prepare_fixture gateway-compose-host-overrides
touch "$MOCK_STATE/assert-gateway-clean-env"
GATEWAY_OVERRIDE_SENTINEL='fixture-gateway-override-sentinel'
run_bootstrap "$OUTPUT" \
  CF_GATEWAY_CONFIG=/hostile/config.yaml \
  CF_AGENT_GATEWAY_DATABASE_URL="postgresql://hostile:${GATEWAY_OVERRIDE_SENTINEL}@attacker.invalid/gateway" \
  CF_GATEWAY_STARTUP_MIGRATION_MODE=migrate \
  CF_GATEWAY_LOG_LEVEL=TRACE \
  CF_GATEWAY_API_TOKEN="$GATEWAY_OVERRIDE_SENTINEL" \
  CF_AGENT_GATEWAY_ADMIN_TOKEN="$GATEWAY_OVERRIDE_SENTINEL" \
  CF_GATEWAY_WORKER_CONCURRENCY=999 \
  CF_GATEWAY_WORKER_LEASE_SECONDS=999 \
  CF_GATEWAY_WORKER_RETRY_LIMIT=999 \
  CF_GATEWAY_WORKER_HEARTBEAT_INTERVAL_SECONDS=999 \
  CF_GATEWAY_WORKER_HEARTBEAT_MAX_AGE_SECONDS=999 \
  CF_GATEWAY_RUNTIME_HEARTBEAT_MAX_AGE_SECONDS=999 \
  CF_AGENT_WECHAT_TOKEN="$GATEWAY_OVERRIDE_SENTINEL" \
  HERMES_API_KEY="$GATEWAY_OVERRIDE_SENTINEL" \
  CF_GATEWAY_IMAGE=registry.example/attacker:latest \
  CF_GATEWAY_ENV_FILE=/hostile/.env \
  CF_GATEWAY_CONFIG_FILE=/hostile/config.yaml \
  CF_GATEWAY_BIND_ADDRESS=0.0.0.0 \
  CF_GATEWAY_PORT=9999 \
  CF_GATEWAY_STOP_GRACE_PERIOD=1s \
  CF_GATEWAY_LOG_MAX_SIZE=999g \
  CF_GATEWAY_LOG_MAX_FILES=999 || {
  sed -n '1,200p' "$OUTPUT" >&2
  fail "Gateway caller environment reached the Compose process"
}
[ -e "$MOCK_STATE/gateway-env-clean" ] ||
  fail "Gateway Compose clean-environment assertion did not run"
[ ! -e "$MOCK_STATE/gateway-env-not-clean" ] || {
  sed -n '1,20p' "$MOCK_STATE/gateway-env-not-clean" >&2
  fail "Gateway Compose retained a scrubbed caller variable"
}
assert_not_contains "$OUTPUT" "$GATEWAY_OVERRIDE_SENTINEL"
assert_not_contains "$MOCK_STATE/docker.log" "$GATEWAY_OVERRIDE_SENTINEL"
pass "Gateway Compose receives only the approved env-file, not hostile host overrides"

prepare_fixture agent-running
touch "$MOCK_STATE/agent-running"
expect_failure 'agent-wechat is running'
pass "Bootstrap refuses a long-lived agent-wechat container"

prepare_fixture worker-running
touch "$MOCK_STATE/worker-running"
expect_failure 'Gateway worker service must be stopped before a fresh runtime is verified'
pass "Bootstrap gates Gateway wechat-worker before fresh QR verification"

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

prepare_fixture env-management-group
chmod 640 "$AGENT_ENV"
run_bootstrap "$OUTPUT" || {
  sed -n '1,200p' "$OUTPUT" >&2
  fail "management-group-readable docker/.env did not pass its exact contract"
}
pass "docker/.env mode 0640 requires and accepts the approved management group"

prepare_fixture env-wrong-group
wrong_gid=$((CURRENT_GID + 1))
sudo -n -- chown "${CURRENT_UID}:${wrong_gid}" "$AGENT_ENV"
sudo -n -- chmod 640 "$AGENT_ENV"
expect_failure \
  'production environment file owner, group, and mode do not match the approved management contract'
[ ! -e "$ARCHIVE_ROOT" ] ||
  fail "wrong docker/.env group mutated deployment state"
pass "docker/.env mode 0640 rejects a non-management group"

prepare_fixture env-assignment
sed -i 's|^PROXY=.*|PROXY=$(printf unsafe)|' "$AGENT_ENV"
expect_failure 'production environment values must be unquoted, literal, and whitespace-free'
[ ! -e "$ARCHIVE_ROOT" ] || fail "unsafe dotenv assignment mutated deployment state"
pass "unsafe docker/.env assignment is rejected without evaluation"

prepare_fixture env-path-mismatch
sed -i \
  "s|^CF_AGENT_WECHAT_ARCHIVE_ROOT=.*|CF_AGENT_WECHAT_ARCHIVE_ROOT=$STORAGE_ROOT/wrong-archive|" \
  "$AGENT_ENV"
expect_failure 'docker/.env archive root differs from the selected production archive root'
[ ! -e "$ARCHIVE_ROOT" ] || fail "mismatched docker/.env paths mutated deployment state"
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

prepare_fixture symlink-ancestor
mv -- "$SCENARIO_ROOT/gateway" "$SCENARIO_ROOT/gateway.real"
ln -s -- gateway.real "$SCENARIO_ROOT/gateway"
expect_failure 'Gateway project directory must not contain symbolic link ancestors'
[ ! -e "$ARCHIVE_ROOT" ] || fail "symlink ancestor rejection mutated deployment state"
pass "symbolic link ancestors cannot redirect managed paths"
prepare_fixture heartbeat-missing
rm -f -- "$GATEWAY_HEARTBEAT"
expect_failure 'Gateway heartbeat checker must be an existing non-symlink regular file'
[ ! -e "$ARCHIVE_ROOT" ] || fail "missing heartbeat checker mutated deployment state"
pass "missing Gateway heartbeat checker fails closed"

prepare_fixture heartbeat-symlink
mv -- "$GATEWAY_HEARTBEAT" "${GATEWAY_HEARTBEAT}.real"
ln -s -- "$(basename -- "${GATEWAY_HEARTBEAT}.real")" "$GATEWAY_HEARTBEAT"
expect_failure 'Gateway heartbeat checker must be an existing non-symlink regular file'
pass "Gateway heartbeat checker symlink is rejected"

prepare_fixture heartbeat-hardlink
ln -- "$GATEWAY_HEARTBEAT" "${GATEWAY_HEARTBEAT}.copy"
expect_failure 'Gateway heartbeat checker must not have additional hard links'
pass "Gateway heartbeat checker hardlinks are rejected"

prepare_fixture heartbeat-mode
chmod 777 "$GATEWAY_HEARTBEAT"
expect_failure 'Gateway heartbeat checker must not be group/other writable'
pass "group/other-writable Gateway heartbeat checker is rejected"

prepare_fixture heartbeat-not-executable
chmod 644 "$GATEWAY_HEARTBEAT"
expect_failure 'Gateway heartbeat checker must be executable by the management user'
pass "non-executable Gateway heartbeat checker is rejected"

prepare_fixture release-gate-missing
rm -f -- "$GATEWAY_GATE"
expect_failure 'Gateway runtime release gate must be an existing non-symlink regular file'
[ ! -e "$ARCHIVE_ROOT" ] || fail "missing release gate mutated deployment state"
pass "missing Gateway runtime release gate fails closed"

prepare_fixture release-gate-symlink
mv -- "$GATEWAY_GATE" "${GATEWAY_GATE}.real"
ln -s -- "$(basename -- "${GATEWAY_GATE}.real")" "$GATEWAY_GATE"
expect_failure 'Gateway runtime release gate must be an existing non-symlink regular file'
pass "Gateway runtime release gate symlink is rejected"

prepare_fixture release-gate-hardlink
ln -- "$GATEWAY_GATE" "${GATEWAY_GATE}.copy"
expect_failure 'Gateway runtime release gate must not have additional hard links'
pass "Gateway runtime release gate hardlinks are rejected"

prepare_fixture release-gate-mode
chmod 777 "$GATEWAY_GATE"
expect_failure 'Gateway runtime release gate must not be group/other writable'
pass "group/other-writable Gateway runtime release gate is rejected"

prepare_fixture release-gate-not-executable
chmod 644 "$GATEWAY_GATE"
expect_failure 'Gateway runtime release gate must be executable by the management user'
pass "non-executable Gateway runtime release gate is rejected"

prepare_fixture contract-missing
rm -f -- "$GATEWAY_CONTRACT"
expect_failure 'Gateway runtime contract must be an existing non-symlink regular file'
pass "missing Gateway versioned contract fails closed"

prepare_fixture contract-version
python3 - "$GATEWAY_CONTRACT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
payload["contractVersion"] = "2"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(payload, stream)
PY
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
pass "incompatible Gateway contract version fails closed"

prepare_fixture contract-checker
python3 - "$GATEWAY_CONTRACT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
payload["gateway"]["checker"] = "/tmp/unapproved-checker"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(payload, stream)
PY
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
pass "Gateway contract with a different checker path fails closed"

prepare_fixture contract-release-gate
python3 - "$GATEWAY_CONTRACT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
payload["gateway"]["releaseGate"]["command"] = "/tmp/unapproved-release-gate"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(payload, stream)
PY
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
pass "Gateway contract with a different release gate path fails closed"

prepare_fixture gateway-token-missing
printf '%s\n' 'GATEWAY_ENV=production' > "$GATEWAY_ENV"
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
pass "missing Gateway file credential assignment fails closed"

prepare_fixture gateway-legacy-plaintext-token
MISMATCH_TOKEN="$(printf 'd%.0s' {1..64})"
printf '%s\n' \
  'GATEWAY_ENV=production' \
  "CF_AGENT_WECHAT_TOKEN=$MISMATCH_TOKEN" > "$GATEWAY_ENV"
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
assert_not_contains "$OUTPUT" "$FIXTURE_TOKEN"
assert_not_contains "$OUTPUT" "$MISMATCH_TOKEN"
assert_not_contains "$MOCK_STATE/docker.log" "$FIXTURE_TOKEN"
assert_not_contains "$MOCK_STATE/docker.log" "$MISMATCH_TOKEN"
pass "legacy plaintext Gateway Token fails closed without disclosure"

prepare_fixture gateway-file-credential-drift
printf '%s\n' \
  'GATEWAY_ENV=production' \
  'CF_AGENT_WECHAT_TOKEN_FILE=/run/secrets/unapproved-token' > "$GATEWAY_ENV"
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
pass "Gateway file credential path drift fails closed"

prepare_fixture gateway-token-mount-drift
touch "$MOCK_STATE/gateway-token-mount-drift"
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
pass "Gateway Token authority mount drift fails closed"

prepare_fixture gateway-token-authority-contract-drift
python3 - "$GATEWAY_CONTRACT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
payload["agent"]["tokenAuthority"]["hostPath"] += ".drift"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(payload, stream)
PY
expect_failure 'Gateway runtime contract or Agent Token agreement could not be verified'
pass "Gateway Token authority contract drift fails closed"


prepare_fixture token-hardlink
touch "$MOCK_STATE/fail-agent-compose"
expect_failure 'production Compose validation failed'
rm -f -- "$MOCK_STATE/fail-agent-compose"
TOKEN_VALUE="$(sudo -n -- cat "$TOKEN_FILE")"
sudo -n -- ln -- "$TOKEN_FILE" "$STORAGE_ROOT/secrets/auth-token.extra"
expect_failure 'auth Token must be root:root 600 with one hard link'
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
