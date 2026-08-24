#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

if [ "$(uname -s)" != "Linux" ]; then
  printf '%s\n' 'SKIP management environment integration test requires Linux'
  exit 0
fi

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
ENV_FILE="${TEST_ROOT}/agent.env"
AGENT_COMPOSE_FILE="${TEST_ROOT}/agent-compose.yaml"
DIGEST="$(printf '%064d' 0)"
MOCK_DOCKER="${TEST_ROOT}/mock-docker"
MOCK_SYSTEMCTL="${TEST_ROOT}/mock-systemctl"
MOCK_DF="${TEST_ROOT}/mock-df"
COMPOSE_ARGS="${TEST_ROOT}/compose.args"
COMPOSE_ENV="${TEST_ROOT}/compose.env"
CURL_ARGS="${TEST_ROOT}/curl.args"
CURL_ENV="${TEST_ROOT}/curl.env"
REQUEST_MARKER="${TEST_ROOT}/network-requested"
AGENT_CURL_MARKER="${TEST_ROOT}/agent-curl-requested"
LOGIN_PYTHON_MARKER="${TEST_ROOT}/login-python-requested"
TOKEN_FILE="${TEST_ROOT}/secrets/auth-token"
TOKEN_VALUE='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
STORAGE_ROOT="${TEST_ROOT}/storage"
RUNTIME_ROOT="${STORAGE_ROOT}/runtime"
ARCHIVE_ROOT="${STORAGE_ROOT}/session-archive"
TEST_CONTAINER="cf-agent-wechat-management-fixture"
DOCKER_SOCKET="${TEST_ROOT}/docker.sock"
GATEWAY_PROJECT_DIR="${TEST_ROOT}/gateway"
GATEWAY_COMPOSE_FILE="${GATEWAY_PROJECT_DIR}/compose.yaml"
GATEWAY_ENV_FILE="${GATEWAY_PROJECT_DIR}/.env"
RUNTIME_LOCK_FILE="${TEST_ROOT}/runtime.lock"
TEST_AGENT_PORT=16174

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

write_env() {
  printf '%s\n' "$@" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

write_valid_env() {
  local proxy="${1:-http://proxy.example:8080}"
  local rust_log="${2:-info}"
  local storage_root="${3:-$STORAGE_ROOT}"
  local runtime_root="${4:-$RUNTIME_ROOT}"
  local archive_root="${5:-$ARCHIVE_ROOT}"

  write_env \
    '  # safe whitespace-prefixed comment' \
    'COMPOSE_PROJECT_NAME=cf-agent-wechat' \
    "AGENT_WECHAT_IMAGE=ghcr.io/example/agent-wechat@sha256:${DIGEST}" \
    "CF_AGENT_WECHAT_STORAGE_ROOT=${storage_root}" \
    "CF_AGENT_WECHAT_RUNTIME_ROOT=${runtime_root}" \
    "CF_AGENT_WECHAT_ARCHIVE_ROOT=${archive_root}" \
    'CF_AGENT_WECHAT_RUNTIME_UID=1000' \
    'CF_AGENT_WECHAT_RUNTIME_GID=1000' \
    'CF_AGENT_WECHAT_RUNTIME_MODE=700' \
    'CF_AGENT_WECHAT_MANAGEMENT_GID=1000' \
    'CF_AGENT_WECHAT_MIN_FREE_BYTES=1073741824' \
    'CF_AGENT_WECHAT_MIN_FREE_PERCENT=10' \
    'CF_AGENT_WECHAT_MIN_FREE_INODES=1024' \
    'CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES=200000' \
    'CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES=21474836480' \
    'AGENT_WECHAT_BIND_IP=127.0.0.1' \
    "AGENT_WECHAT_PORT=${TEST_AGENT_PORT}" \
    "AGENT_WECHAT_CONTAINER_NAME=${TEST_CONTAINER}" \
    "PROXY=${proxy}" \
    "RUST_LOG=${rust_log}"
}

read_contract() {
  /usr/bin/env -i \
    HOME="$TEST_ROOT" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    CF_AGENT_WECHAT_TESTING=1 \
    CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_ROOT" \
    CF_AGENT_WECHAT_ENV_FILE="$ENV_FILE" \
    bash -c '
      source "$1/scripts/common.sh"
      source "$1/scripts/qr-runtime-common.sh"
      if ! runtime_load_management_environment; then
        printf "%s" "$RUNTIME_MANAGEMENT_ENV_ERROR" >&2
        exit 1
      fi
      printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" \
        "$STORAGE_ROOT" "$RUNTIME_ROOT" "$ARCHIVE_ROOT" \
        "$CONTAINER_NAME" "$APPROVED_AGENT_IMAGE" \
        "$APPROVED_PROXY" "$APPROVED_RUST_LOG" \
        "$RUNTIME_DEFAULT_UID" "$RUNTIME_DEFAULT_GID" \
        "$RUNTIME_MANAGEMENT_GID" "$MIN_FREE_BYTES" \
        "$MIN_FREE_PERCENT" "$MIN_FREE_INODES" \
        "$TOKEN_SCAN_MAX_FILES" "$TOKEN_SCAN_MAX_BYTES"
    ' management-environment "$REPO_ROOT"
}

assert_rejected() {
  local expected="$1"
  shift
  local output

  write_env "$@"
  if output="$(read_contract 2>&1)"; then
    printf 'FAIL unsafe management environment was accepted: %s\n' "$output" >&2
    exit 1
  fi
  case "$output" in
    *"$expected"*) ;;
    *)
      printf 'FAIL expected %s, got: %s\n' "$expected" "$output" >&2
      exit 1
      ;;
  esac
}

replace_env_value() {
  local key="$1" value="$2"

  sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
}

assert_contract_value_rejected() {
  local key="$1" value="$2" expected="$3"
  local output

  write_valid_env
  replace_env_value "$key" "$value"
  if output="$(read_contract 2>&1)"; then
    fail "$key unsafe numeric value was accepted"
  fi
  case "$output" in
    *"$expected"*) ;;
    *) fail "$key rejection returned unexpected error: $output" ;;
  esac
  case "$output" in
    *"$value"*) fail "$key rejection disclosed its hostile value" ;;
  esac
}

assert_proxy_rejected() {
  local value="$1"
  local output

  write_valid_env "$value"
  if output="$(read_contract 2>&1)"; then
    fail 'unsafe proxy was accepted'
  fi
  case "$output" in
    *'credential-free'*|*'contains control characters'*) ;;
    *) fail 'unsafe proxy returned an unexpected redacted error' ;;
  esac
  case "$output" in
    *password*|*token-secret*) fail 'proxy error disclosed credential material' ;;
  esac
}

assert_production_override_rejected() {
  local name="$1"
  local value="$2"
  local output status

  rm -f -- "$AGENT_CURL_MARKER" "$LOGIN_PYTHON_MARKER"
  set +e
  output="$(/usr/bin/env -i \
    HOME="$TEST_ROOT" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    CF_AGENT_WECHAT_TESTING=0 \
    "$name=$value" \
    /bin/bash -p -c '
      readonly _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR="$1/scripts"
      source "$1/scripts/common.sh"
      agent_curl_marker="$2"
      login_python_marker="$3"
      run_agent_curl() {
        : > "$agent_curl_marker"
      }
      run_login_python() {
        : > "$login_python_marker"
      }
      if validate_configuration; then
        run_agent_curl
        run_login_python
        exit 0
      fi
      printf "%s" "$LAST_ERROR" >&2
      exit 1
    ' production-override "$REPO_ROOT" "$AGENT_CURL_MARKER" \
      "$LOGIN_PYTHON_MARKER" 2>&1)"
  status=$?
  set -e

  [ ! -e "$AGENT_CURL_MARKER" ] ||
    fail "$name reached the Agent API transport"
  [ ! -e "$LOGIN_PYTHON_MARKER" ] ||
    fail "$name reached the QR WebSocket transport"
  [ "$status" -ne 0 ] || fail "$name production override was accepted"
  case "$output" in
    *'Production management environment overrides are forbidden:'*"$name"*) ;;
    *) fail "$name rejection returned unexpected error: $output" ;;
  esac
  case "$output" in
    *"$value"*) fail "$name rejection disclosed its hostile value" ;;
  esac
}

assert_testing_transport_rejected() {
  local name="$1"
  local value="$2"
  local expected="$3"
  local output status

  rm -f -- "$REQUEST_MARKER"
  set +e
  output="$(/usr/bin/env -i \
    HOME="$TEST_ROOT" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    CF_AGENT_WECHAT_TESTING=1 \
    CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_ROOT" \
    API_URL=http://127.0.0.1:16175 \
    WS_URL=ws://127.0.0.1:16176/api/ws/login \
    TOKEN_FILE="$TOKEN_FILE" \
    "$name=$value" \
    /bin/bash -c '
      source "$1/scripts/common.sh"
      marker="$2"
      run_agent_curl() {
        : > "$marker"
      }
      run_login_python() {
        : > "$marker"
      }
      if validate_configuration; then
        api_request GET /must-not-run >/dev/null 2>&1 || true
        run_login_python >/dev/null 2>&1 || true
        exit 0
      fi
      printf "%s" "$LAST_ERROR" >&2
      exit 1
    ' testing-transport "$REPO_ROOT" "$REQUEST_MARKER" 2>&1)"
  status=$?
  set -e

  [ ! -e "$REQUEST_MARKER" ] ||
    fail "$name reached an Agent or QR transport"
  [ "$status" -ne 0 ] ||
    fail "$name testing override was accepted"
  case "$output" in
    *"$expected"*) ;;
    *) fail "$name testing rejection returned unexpected error: $output" ;;
  esac
  if [ -n "$value" ]; then
    case "$output" in
      *"$value"*) fail "$name testing rejection disclosed its hostile value" ;;
    esac
  fi
}


assert_testing_docker_rejected() {
  local docker_bin="$1"
  local socket_path="$2"
  local container_name="$3"
  local expected="$4"
  local output status

  rm -f -- "$REQUEST_MARKER"
  set +e
  output="$(/usr/bin/env -i \
    HOME="$TEST_ROOT" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    CF_AGENT_WECHAT_TESTING=1 \
    CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_ROOT" \
    CF_AGENT_WECHAT_DOCKER_BIN="$docker_bin" \
    CF_AGENT_WECHAT_DOCKER_SOCKET_PATH="$socket_path" \
    CONTAINER_NAME="$container_name" \
    API_URL=http://127.0.0.1:16175 \
    WS_URL=ws://127.0.0.1:16176/api/ws/login \
    TOKEN_FILE="$TOKEN_FILE" \
    /bin/bash -c '
      source "$1/scripts/common.sh"
      if validate_testing_docker_isolation; then
        exit 0
      fi
      printf "%s" "$LAST_ERROR" >&2
      exit 1
    ' testing-docker "$REPO_ROOT" 2>&1)"
  status=$?
  set -e

  [ ! -e "$REQUEST_MARKER" ] ||
    fail "rejected testing Docker configuration executed its CLI"
  [ "$status" -ne 0 ] ||
    fail "unsafe testing Docker configuration was accepted"
  case "$output" in
    *"$expected"*) ;;
    *) fail "testing Docker rejection returned unexpected error: $output" ;;
  esac
}

assert_testing_asset_rejected() {
  local name="$1"
  local value="$2"
  local expected="$3"
  local output status

  rm -f -- "$COMPOSE_ARGS"
  set +e
  output="$(/usr/bin/env -i \
    HOME="$TEST_ROOT" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    CF_AGENT_WECHAT_TESTING=1 \
    CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_ROOT" \
    API_URL=http://127.0.0.1:16175 \
    WS_URL=ws://127.0.0.1:16176/api/ws/login \
    TOKEN_FILE="$TOKEN_FILE" \
    CF_AGENT_WECHAT_DOCKER_BIN="$MOCK_DOCKER" \
    CF_AGENT_WECHAT_SYSTEMCTL_BIN="$MOCK_SYSTEMCTL" \
    CF_AGENT_WECHAT_DF_BIN="$MOCK_DF" \
    CF_AGENT_WECHAT_DOCKER_SOCKET_PATH="$DOCKER_SOCKET" \
    CONTAINER_NAME="$TEST_CONTAINER" \
    CF_AGENT_WECHAT_STORAGE_ROOT="$STORAGE_ROOT" \
    CF_AGENT_WECHAT_RUNTIME_ROOT="$RUNTIME_ROOT" \
    CF_AGENT_WECHAT_ARCHIVE_ROOT="$ARCHIVE_ROOT" \
    CF_AGENT_WECHAT_COMPOSE_FILE="$AGENT_COMPOSE_FILE" \
    CF_AGENT_WECHAT_ENV_FILE="$ENV_FILE" \
    CF_AGENT_WECHAT_LOCK_FILE="$RUNTIME_LOCK_FILE" \
    CF_AGENT_GATEWAY_PROJECT_DIR="$GATEWAY_PROJECT_DIR" \
    CF_AGENT_GATEWAY_COMPOSE_FILE="$GATEWAY_COMPOSE_FILE" \
    CF_AGENT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
    "$name=$value" \
    /bin/bash -c '
      source "$1/scripts/common.sh"
      source "$1/scripts/qr-runtime-common.sh"
      if runtime_validate_testing_isolation; then
        exit 0
      fi
      printf "%s" "$LAST_ERROR" >&2
      exit 1
    ' testing-assets "$REPO_ROOT" 2>&1)"
  status=$?
  set -e

  [ ! -e "$COMPOSE_ARGS" ] ||
    fail "$name rejection executed the fake Docker CLI"
  [ "$status" -ne 0 ] ||
    fail "$name production asset was accepted in testing mode"
  case "$output" in
    *"$expected"*) ;;
    *) fail "$name isolation rejection returned unexpected error: $output" ;;
  esac
}

assert_child_value() {
  local name="$1"
  local expected="$2"
  local actual

  actual="$(sed -n "s/^${name}=//p" "${COMPOSE_ENV}.lines")"
  [ "$actual" = "$expected" ] ||
    fail "Compose child $name expected $expected, got $actual"
}

assert_child_absent() {
  local name="$1"

  if grep -q "^${name}=" "${COMPOSE_ENV}.lines"; then
    fail "Compose child inherited forbidden variable $name"
  fi
}

LEXICAL_BLOCKED_ROOT="${TEST_ROOT}/lexical-blocked"
mkdir -p -- "$LEXICAL_BLOCKED_ROOT"
chmod 000 -- "$LEXICAL_BLOCKED_ROOT"
LEXICAL_CANONICAL="$(/usr/bin/env -i \
  HOME="$TEST_ROOT" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 \
  CF_AGENT_WECHAT_TESTING=1 \
  /bin/bash -c '
    source "$1/scripts/common.sh"
    testing_canonical_path "$2/unreadable/../auth-token"
  ' testing-lexical "$REPO_ROOT" "$LEXICAL_BLOCKED_ROOT")"
chmod 700 -- "$LEXICAL_BLOCKED_ROOT"
[ "$LEXICAL_CANONICAL" = "${LEXICAL_BLOCKED_ROOT}/auth-token" ] ||
  fail 'testing path isolation required filesystem traversal before sudo authorization'
printf '%s\n' 'PASS testing path isolation is lexical before sudo authorization'

write_valid_env
[ "$(read_contract)" = \
  "${STORAGE_ROOT}|${RUNTIME_ROOT}|${ARCHIVE_ROOT}|${TEST_CONTAINER}|ghcr.io/example/agent-wechat@sha256:${DIGEST}|http://proxy.example:8080|info|1000|1000|1000|1073741824|10|1024|200000|21474836480" ] || {
  printf '%s\n' 'FAIL valid docker/.env was not authoritative' >&2
  exit 1
}
printf '%s\n' 'PASS safe docker/.env is authoritative'

sed -i \
  -e 's/^CF_AGENT_WECHAT_RUNTIME_UID=.*/CF_AGENT_WECHAT_RUNTIME_UID=21001/' \
  -e 's/^CF_AGENT_WECHAT_RUNTIME_GID=.*/CF_AGENT_WECHAT_RUNTIME_GID=21002/' \
  -e 's/^CF_AGENT_WECHAT_MANAGEMENT_GID=.*/CF_AGENT_WECHAT_MANAGEMENT_GID=21003/' \
  -e 's/^CF_AGENT_WECHAT_MIN_FREE_BYTES=.*/CF_AGENT_WECHAT_MIN_FREE_BYTES=536870912/' \
  -e 's/^CF_AGENT_WECHAT_MIN_FREE_PERCENT=.*/CF_AGENT_WECHAT_MIN_FREE_PERCENT=17/' \
  -e 's/^CF_AGENT_WECHAT_MIN_FREE_INODES=.*/CF_AGENT_WECHAT_MIN_FREE_INODES=2048/' \
  -e 's/^CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES=.*/CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES=12345/' \
  -e 's/^CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES=.*/CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES=987654321/' \
  "$ENV_FILE"
[ "$(read_contract)" = \
  "${STORAGE_ROOT}|${RUNTIME_ROOT}|${ARCHIVE_ROOT}|${TEST_CONTAINER}|ghcr.io/example/agent-wechat@sha256:${DIGEST}|http://proxy.example:8080|info|21001|21002|21003|536870912|17|2048|12345|987654321" ] ||
  fail 'valid non-default management values were validated but not assigned'
printf '%s\n' 'PASS valid non-default management values are assigned'

INT64_MAX=9223372036854775807
INT64_OVERFLOW=9223372036854775808
OVERSIZED_DECIMAL="$(printf '9%.0s' {1..128})"
write_valid_env
replace_env_value CF_AGENT_WECHAT_MIN_FREE_BYTES "$INT64_MAX"
replace_env_value CF_AGENT_WECHAT_MIN_FREE_PERCENT 100
replace_env_value CF_AGENT_WECHAT_MIN_FREE_INODES "$INT64_MAX"
replace_env_value CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES 200000
replace_env_value CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES "$INT64_MAX"
numeric_boundary_contract="$(read_contract)" ||
  fail 'exact signed 64-bit numeric boundaries were rejected'
case "$numeric_boundary_contract" in
  *"|${INT64_MAX}|100|${INT64_MAX}|200000|${INT64_MAX}") ;;
  *) fail 'exact signed 64-bit numeric boundaries were not assigned' ;;
esac
for numeric_key in \
  CF_AGENT_WECHAT_MIN_FREE_BYTES \
  CF_AGENT_WECHAT_MIN_FREE_INODES \
  CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES; do
  assert_contract_value_rejected \
    "$numeric_key" "$INT64_OVERFLOW" 'failed byte-safe validation'
  assert_contract_value_rejected \
    "$numeric_key" "$OVERSIZED_DECIMAL" 'failed byte-safe validation'
done
assert_contract_value_rejected \
  AGENT_WECHAT_PORT 65536 'failed byte-safe validation'
for numeric_key in \
  CF_AGENT_WECHAT_RUNTIME_UID \
  CF_AGENT_WECHAT_RUNTIME_GID \
  CF_AGENT_WECHAT_MANAGEMENT_GID; do
  assert_contract_value_rejected \
    "$numeric_key" 4294967295 'failed byte-safe validation'
done
assert_contract_value_rejected \
  CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES 200001 \
  'must not exceed the compiled scanner limit'
assert_contract_value_rejected \
  CF_AGENT_WECHAT_MIN_FREE_PERCENT 000 \
  'failed byte-safe validation'
assert_contract_value_rejected \
  CF_AGENT_WECHAT_MIN_FREE_PERCENT "$INT64_OVERFLOW" \
  'failed byte-safe validation'
printf '%s\n' 'PASS ports, IDs, and management numeric values are bounded before Bash arithmetic'

write_valid_env http://proxy.example:8080 info \
  /srv/storage/cf-agent-wechat \
  /srv/storage/cf-agent-wechat/runtime \
  /srv/storage/cf-agent-wechat/session-archive
set +e
production_storage_output="$(read_contract 2>&1)"
production_storage_status=$?
set -e
[ "$production_storage_status" -ne 0 ] ||
  fail 'testing docker/.env accepted production storage paths'
case "$production_storage_output" in
  *'Testing storage root overlaps a production asset.'*) ;;
  *) fail "production storage rejection returned unexpected error: $production_storage_output" ;;
esac
printf '%s\n' 'PASS parsed testing docker/.env cannot select production storage'

assert_rejected 'duplicate' \
  'AGENT_WECHAT_PORT=6174' \
  'AGENT_WECHAT_PORT=6175'
assert_rejected 'unsupported syntax' \
  'export AGENT_WECHAT_PORT=6174'
assert_rejected 'safe absolute path' \
  'CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/storage/../escape'
assert_rejected 'must be 127.0.0.1' \
  'AGENT_WECHAT_BIND_IP=0.0.0.0'
assert_rejected 'digest pinned' \
  'AGENT_WECHAT_IMAGE=ghcr.io/example/agent-wechat:latest'
assert_rejected 'unsupported key' \
  'AUTH_TOKEN=must-not-be-accepted'
assert_rejected 'unquoted literal' \
  'PROXY=${HTTP_PROXY}'

assert_proxy_rejected 'http://user:password@proxy.example:8080'
assert_proxy_rejected 'https://proxy.example:8443/path'
assert_proxy_rejected 'https://proxy.example:8443?token=token-secret'
assert_proxy_rejected 'https://proxy.example:8443#token-secret'
assert_proxy_rejected $'http://proxy.example:8080\x01'
printf '%s\n' 'PASS unsafe proxy forms are rejected without credential disclosure'

assert_production_override_rejected API_URL 'https://attacker.example'
assert_production_override_rejected WS_URL \
  'wss://attacker.example'
assert_production_override_rejected TOKEN_FILE /tmp/attacker-token
assert_production_override_rejected SESSION_ID attacker-session
assert_production_override_rejected CONTAINER_NAME attacker-legacy-container
assert_production_override_rejected PYTHON_BIN /tmp/attacker-python
assert_production_override_rejected REQUIREMENTS_FILE \
  /tmp/attacker-requirements
assert_production_override_rejected VENV_DIR /tmp/attacker-venv
assert_production_override_rejected CF_AGENT_WECHAT_VENV \
  /tmp/attacker-legacy-venv
assert_production_override_rejected AGENT_WECHAT_IMAGE \
  "attacker.example/agent@sha256:${DIGEST}"
assert_production_override_rejected AGENT_WECHAT_BIND_IP 10.20.30.40
assert_production_override_rejected AGENT_WECHAT_PORT 65535
assert_production_override_rejected COMPOSE_PROJECT_NAME attacker-project
assert_production_override_rejected AGENT_WECHAT_CONTAINER_NAME \
  attacker-container
assert_production_override_rejected CF_AGENT_WECHAT_STORAGE_ROOT \
  /tmp/attacker-storage
assert_production_override_rejected CF_AGENT_WECHAT_RUNTIME_ROOT \
  /tmp/attacker-runtime
assert_production_override_rejected CF_AGENT_WECHAT_ARCHIVE_ROOT \
  /tmp/attacker-archive
assert_production_override_rejected PROXY \
  http://attacker.example:8080
assert_production_override_rejected RUST_LOG error
assert_production_override_rejected HTTP_PROXY \
  http://user:password@attacker.example:8080
assert_production_override_rejected HTTPS_PROXY \
  https://attacker.example:8443
assert_production_override_rejected ALL_PROXY \
  socks5://attacker.example:1080
assert_production_override_rejected http_proxy \
  http://attacker.example:8080
assert_production_override_rejected no_proxy attacker.example
assert_production_override_rejected CF_AGENT_WECHAT_TOKEN token-secret
assert_production_override_rejected CF_AGENT_WECHAT_TOKEN_FILE \
  /tmp/attacker-token
assert_production_override_rejected AUTH_TOKEN token-secret
assert_production_override_rejected HTTP_CONNECT_TIMEOUT 999
assert_production_override_rejected HTTP_TIMEOUT 999
assert_production_override_rejected DOCKER_READ_TIMEOUT 999
assert_production_override_rejected LOGIN_TIMEOUT_MS 999
assert_production_override_rejected DOCKER_COMMAND_TIMEOUT 999
assert_production_override_rejected COMPOSE_COMMAND_TIMEOUT 999
assert_production_override_rejected WORKER_HEARTBEAT_TIMEOUT 999
assert_production_override_rejected TOKEN_SCAN_TIMEOUT 999
assert_production_override_rejected CF_AGENT_WECHAT_MIN_FREE_BYTES 999
assert_production_override_rejected CF_AGENT_WECHAT_MIN_FREE_PERCENT 999
assert_production_override_rejected CF_AGENT_WECHAT_MIN_FREE_INODES 999
assert_production_override_rejected CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES 999
assert_production_override_rejected CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES 999
assert_production_override_rejected CF_AGENT_WECHAT_CURL_BIN \
  /tmp/attacker-curl
assert_production_override_rejected CF_AGENT_WECHAT_DOCKER_BIN \
  /tmp/attacker-docker
assert_production_override_rejected CF_AGENT_WECHAT_SYSTEMCTL_BIN \
  /tmp/attacker-systemctl
assert_production_override_rejected CF_AGENT_WECHAT_DF_BIN \
  /tmp/attacker-df
assert_production_override_rejected \
  CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT \
  /tmp/attacker-release-gate
printf '%s\n' 'PASS production overrides fail before Agent network access'
assert_testing_transport_rejected API_URL https://attacker.example "Testing API endpoint"
assert_testing_transport_rejected WS_URL wss://attacker.example/api/ws/login "Testing WebSocket endpoint"
printf '%s\n' 'PASS testing transport overrides fail before network access'
assert_testing_transport_rejected TOKEN_FILE /srv/storage/cf-agent-wechat/secrets/auth-token "Testing Token path overlaps"
printf '%s\n' 'PASS testing Token path cannot target production assets'
assert_testing_transport_rejected CF_AGENT_WECHAT_TEST_ROOT '' \
  "explicit isolated CF_AGENT_WECHAT_TEST_ROOT"
assert_testing_transport_rejected VENV_DIR \
  /srv/storage/cf-agent-wechat/testing-venv \
  "Testing venv directory overlaps a production asset"
assert_testing_transport_rejected TMPDIR \
  /opt/cf-agent-wechat/testing-tmp \
  "Testing temporary directory overlaps a production asset"
printf '%s\n' 'PASS missing test root and production VENV/TMPDIR fail before helpers or network'

clean_output="$(/usr/bin/env -i \
  HOME="$TEST_ROOT" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 \
  CF_AGENT_WECHAT_TESTING=0 \
  /bin/bash -p -c '
    readonly _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR="$1/scripts"
    source "$1/scripts/common.sh"
    validate_configuration || {
      printf "%s" "$LAST_ERROR" >&2
      exit 1
    }
    printf "%s|%s|%s|%s" \
      "$API_URL" "$WS_URL" "$TOKEN_FILE" "$SESSION_ID"
  ' clean-production "$REPO_ROOT")"
[ "$clean_output" = \
  'http://127.0.0.1:6174|ws://127.0.0.1:6174/api/ws/login|/srv/storage/cf-agent-wechat/secrets/auth-token|default' ] ||
  fail "clean production configuration was not accepted: $clean_output"
printf '%s\n' 'PASS clean production management defaults remain valid'

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'capture_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"' \
  'printf "%s\0" "$@" > "${capture_root}/compose.args"' \
  '/usr/bin/env -0 > "${capture_root}/compose.env"' \
  > "$MOCK_DOCKER"
chmod 700 "$MOCK_DOCKER"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$MOCK_SYSTEMCTL"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$1" in' \
  '  -Pk) printf "%s\n" "Filesystem 1024-blocks Used Available Capacity Mounted on" "fixture 100 1 99 1% /fixture" ;;' \
  '  -Pi) printf "%s\n" "Filesystem Inodes IUsed IFree IUse% Mounted on" "fixture 100 1 99 1% /fixture" ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$MOCK_DF"
chmod 700 "$MOCK_SYSTEMCTL" "$MOCK_DF"
printf '%s\n' 'services:' '  agent-wechat: {}' > "$AGENT_COMPOSE_FILE"
mkdir -p -- "$GATEWAY_PROJECT_DIR"
printf '%s\n' 'services:' '  worker: {}' > "$GATEWAY_COMPOSE_FILE"
printf '%s\n' 'fixture=1' > "$GATEWAY_ENV_FILE"
chmod 600 "$GATEWAY_COMPOSE_FILE" "$GATEWAY_ENV_FILE"
python3 - "$DOCKER_SOCKET" <<'PY'
import socket
import sys

fixture = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
fixture.bind(sys.argv[1])
fixture.close()
PY
SYSTEM_DOCKER="$(command -v docker)" ||
  fail "system Docker CLI is required for the rejection fixture"
assert_testing_docker_rejected "$MOCK_DOCKER" /var/run/docker.sock "$TEST_CONTAINER" "production Docker socket"
assert_testing_docker_rejected "$SYSTEM_DOCKER" "$DOCKER_SOCKET" "$TEST_CONTAINER" "Testing"
assert_testing_docker_rejected "$MOCK_DOCKER" "$DOCKER_SOCKET" cf-agent-wechat "Testing container name"
printf '%s\n' 'PASS testing Docker rejects production CLI, socket, and container name'

assert_testing_asset_rejected PYTHON_BIN /bin/true \
  'Testing Python mock must remain within the isolated testing root.'
assert_testing_asset_rejected CF_AGENT_WECHAT_CURL_BIN /bin/true \
  'Testing curl mock must remain within the isolated testing root.'
assert_testing_asset_rejected CF_AGENT_WECHAT_SYSTEMCTL_BIN \
  /usr/bin/systemctl \
  'Testing systemctl mock must remain within the isolated testing root.'
assert_testing_asset_rejected CF_AGENT_WECHAT_DF_BIN /bin/true \
  'Testing df mock must remain within the isolated testing root.'
assert_testing_asset_rejected REQUIREMENTS_FILE \
  /opt/cf-agent-wechat/scripts/requirements.txt \
  'Testing requirements file overlaps a production asset.'
assert_testing_asset_rejected CF_AGENT_WECHAT_COMPOSE_FILE \
  /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  'Testing agent Compose file overlaps a production asset.'
assert_testing_asset_rejected CF_AGENT_WECHAT_ENV_FILE \
  /srv/storage/cf-agent-wechat/docker.env \
  'Testing agent environment file overlaps a production asset.'
printf '%s\n' 'PASS testing executables and code/config assets remain confined'

assert_testing_asset_rejected CF_AGENT_WECHAT_STORAGE_ROOT \
  /srv/storage/cf-agent-wechat 'Testing storage root overlaps'
assert_testing_asset_rejected CF_AGENT_GATEWAY_PROJECT_DIR \
  /opt/cf-agent-gateway 'Testing Gateway project overlaps'
assert_testing_asset_rejected CF_AGENT_GATEWAY_COMPOSE_FILE \
  /opt/cf-agent-gateway/docker-compose.prod.yml \
  'Testing Gateway Compose file overlaps'
assert_testing_asset_rejected CF_AGENT_WECHAT_LOCK_FILE \
  /run/lock/cf-agent-wechat-qr-runtime.lock \
  'Testing runtime lock must not use the production lock file.'
printf '%s\n' 'PASS testing management assets are isolated from production'


write_valid_env 'http://approved-proxy.example:8080' warn
compose_output="$(/usr/bin/env -i \
  HOME="$TEST_ROOT" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_ROOT" \
  CF_AGENT_WECHAT_ENV_FILE="$ENV_FILE" \
  CF_AGENT_WECHAT_DOCKER_BIN="$MOCK_DOCKER" \
  CF_AGENT_WECHAT_DOCKER_SOCKET_PATH="$DOCKER_SOCKET" \
  TOKEN_FILE="$TOKEN_FILE" \
  CF_AGENT_WECHAT_LOCK_FILE="$RUNTIME_LOCK_FILE" \
  CF_AGENT_GATEWAY_PROJECT_DIR="$GATEWAY_PROJECT_DIR" \
  CF_AGENT_GATEWAY_COMPOSE_FILE="$GATEWAY_COMPOSE_FILE" \
  CF_AGENT_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
  CF_AGENT_GATEWAY_HEARTBEAT_COMMAND="$GATEWAY_PROJECT_DIR/check-heartbeat" \
  CONTAINER_NAME="$TEST_CONTAINER" \
  AGENT_WECHAT_IMAGE="attacker.example/agent@sha256:${DIGEST}" \
  AGENT_WECHAT_BIND_IP=10.20.30.40 \
  AGENT_WECHAT_PORT=65535 \
  AGENT_WECHAT_CONTAINER_NAME=attacker-container \
  COMPOSE_PROJECT_NAME=attacker-project \
  PROXY=http://attacker-proxy.example:9000 \
  RUST_LOG=error \
  HTTP_PROXY=http://user:token-secret@attacker.example:8080 \
  HTTPS_PROXY=https://user:token-secret@attacker.example:8443 \
  CF_AGENT_WECHAT_TOKEN=token-secret \
  AUTH_TOKEN=token-secret \
  bash -c '
    source "$1/scripts/common.sh"
    source "$1/scripts/qr-runtime-common.sh"
    runtime_load_management_environment || {
      printf "%s" "$RUNTIME_MANAGEMENT_ENV_ERROR" >&2
      exit 1
    }
    runtime_prepare_compose_snapshots || {
      printf "%s" "$LAST_ERROR" >&2
      exit 1
    }
    agent_compose config >/dev/null
  ' compose-isolation "$REPO_ROOT" 2>&1)" ||
  fail "isolated Compose invocation failed: $compose_output"

tr '\0' '\n' < "$COMPOSE_ENV" > "${COMPOSE_ENV}.lines"
tr '\0' '\n' < "$COMPOSE_ARGS" > "${COMPOSE_ARGS}.lines"
assert_child_value AGENT_WECHAT_IMAGE \
  "ghcr.io/example/agent-wechat@sha256:${DIGEST}"
assert_child_value AGENT_WECHAT_BIND_IP 127.0.0.1
assert_child_value AGENT_WECHAT_PORT "$TEST_AGENT_PORT"
assert_child_value AGENT_WECHAT_CONTAINER_NAME "$TEST_CONTAINER"
assert_child_value COMPOSE_PROJECT_NAME cf-agent-wechat
assert_child_value PROXY http://approved-proxy.example:8080
assert_child_value RUST_LOG warn
for forbidden_name in \
  HTTP_PROXY HTTPS_PROXY CF_AGENT_WECHAT_TOKEN TOKEN_FILE API_URL WS_URL \
  SESSION_ID CONTAINER_NAME AUTH_TOKEN; do
  assert_child_absent "$forbidden_name"
done
case "$(cat -- "${COMPOSE_ENV}.lines" "${COMPOSE_ARGS}.lines")${compose_output}" in
  *token-secret*)
    fail 'Token or proxy credential reached Compose argv, environment, or output'
    ;;
esac
grep -Fx -- '--project-name' "${COMPOSE_ARGS}.lines" >/dev/null ||
  fail 'Compose invocation omitted explicit project-name option'
grep -Fx -- 'cf-agent-wechat' "${COMPOSE_ARGS}.lines" >/dev/null ||
  fail 'Compose invocation did not use the approved project name'
printf '%s\n' 'PASS Compose receives only approved management values'

mkdir -p -- "$(dirname -- "$TOKEN_FILE")"
chmod 700 "$(dirname -- "$TOKEN_FILE")"
printf '%s\n' "$TOKEN_VALUE" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'capture_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"' \
  'printf "%s\0" "$@" > "${capture_root}/curl.args"' \
  '/usr/bin/env -0 > "${capture_root}/curl.env"' \
  'IFS= read -r authorization' \
  'IFS= read -r session_header' \
  '[[ "$authorization" =~ ^Authorization:\ Bearer\ [0-9a-f]{64}$ ]]' \
  '[ "$session_header" = "X-Session-Id: default" ]' \
  'printf "%s\n" "{\"ok\":true}"' \
  > "${TEST_ROOT}/mock-curl"
chmod 700 "${TEST_ROOT}/mock-curl"

curl_output="$(/usr/bin/env -i \
  HOME="$TEST_ROOT" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 \
  CF_AGENT_WECHAT_TESTING=1 \
  CF_AGENT_WECHAT_TEST_ROOT="$TEST_ROOT" TMPDIR="$TEST_ROOT" \
  CF_AGENT_WECHAT_CURL_BIN="${TEST_ROOT}/mock-curl" \
  API_URL="http://127.0.0.1:${TEST_AGENT_PORT}" \
  WS_URL="ws://127.0.0.1:${TEST_AGENT_PORT}/api/ws/login" \
  TOKEN_FILE="$TOKEN_FILE" \
  bash -x -c '
    source "$1/scripts/common.sh"
    validate_configuration || {
      printf "%s" "$LAST_ERROR" >&2
      exit 1
    }
    load_auth_token || {
      printf "%s" "$LAST_ERROR" >&2
      exit 1
    }
    api_request GET /transport-test
  ' curl-isolation "$REPO_ROOT" 2>&1)" ||
  fail "isolated curl transport test failed: $curl_output"
tr '\0' '\n' < "$CURL_ENV" > "${CURL_ENV}.lines"
tr '\0' '\n' < "$CURL_ARGS" > "${CURL_ARGS}.lines"
case "$(cat -- "${CURL_ENV}.lines" "${CURL_ARGS}.lines")${curl_output}" in
  *"$TOKEN_VALUE"*)
    fail 'Agent Token reached curl argv, environment, trace, or output'
    ;;
esac
grep -Fx -- '--header' "${CURL_ARGS}.lines" >/dev/null ||
  fail 'curl invocation omitted its stdin-backed header option'
grep -Fx -- '@-' "${CURL_ARGS}.lines" >/dev/null ||
  fail 'curl Authorization header was not passed through stdin'
if grep -q '^AUTH_TOKEN=' "${CURL_ENV}.lines"; then
  fail 'curl child inherited AUTH_TOKEN'
fi
printf '%s\n' 'PASS Token is absent from curl argv, environment, trace, and output'

printf '%s\n' 'All management environment tests passed.'
