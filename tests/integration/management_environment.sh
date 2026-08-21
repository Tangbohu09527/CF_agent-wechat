#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT=""
HOST_KERNEL=""
REAL_STAT=""
TEST_PATH=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TEST_ROOT" ]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

for command_name in bash chmod env grep id install ln mktemp mv realpath rm stat uname; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "missing command: $command_name"
done
HOST_KERNEL="$(uname -s)"
REAL_STAT="$(command -v stat)"
case "$REAL_STAT" in
  /*) ;;
  *) fail "stat did not resolve to an absolute path: $REAL_STAT" ;;
esac

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cf-wechat-management-env.XXXXXX")"
FIXTURE_ROOT="${TEST_ROOT}/repo"
ENV_FILE="${FIXTURE_ROOT}/docker/.env"
COMMON_FILE="${FIXTURE_ROOT}/scripts/common.sh"
INJECTION_MARKER="${TEST_ROOT}/injection-ran"
MOCK_BIN="${TEST_ROOT}/bin"

install -d -m 755 "$MOCK_BIN" "${FIXTURE_ROOT}/docker" "${FIXTURE_ROOT}/scripts"
install -m 644 "${REPO_ROOT}/scripts/common.sh" "$COMMON_FILE"
TEST_PATH="$PATH"
if [ "$HOST_KERNEL" != Linux ]; then
  install -m 755 "${REPO_ROOT}/tests/helpers/mock_management_stat.sh" \
    "${MOCK_BIN}/stat"
  TEST_PATH="${MOCK_BIN}:${PATH}"
  printf '%s\n' 'INFO non-Linux host uses controlled stat metadata for secure fixture modes'
fi

write_env() {
  printf '%s\n' "$@" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

run_common() {
  env -i PATH="$TEST_PATH" HOME="${HOME:-/tmp}" \
    CF_TEST_REAL_STAT="$REAL_STAT" \
    CF_TEST_STAT_REPO_ROOT="$FIXTURE_ROOT" \
    CF_TEST_STAT_DOCKER_DIR="${FIXTURE_ROOT}/docker" \
    CF_TEST_STAT_ENV_FILE="$ENV_FILE" \
    "$@" \
    bash --noprofile --norc -c '
      source "$1"
      if ! validate_configuration; then
        printf "ERROR:%s\n" "$LAST_ERROR" >&2
        exit 1
      fi
      printf "runtime=%s\napi=%s\ncontainer=%s\ntoken=%s\nhealth=%s\nws=%s\n" \
        "$RUNTIME_ROOT" "$API_URL" "$CONTAINER_NAME" "$TOKEN_FILE" \
        "$HEALTH_URL" "$WS_URL"
    ' cf-wechat-management-env "$COMMON_FILE"
}

assert_contains() {
  local output="$1" expected="$2" label="$3"
  printf '%s\n' "$output" | grep -Fqx "$expected" ||
    fail "$label (missing: $expected)"
}

expect_failure() {
  local label="$1" expected="$2" output
  shift 2
  if output="$(run_common "$@" 2>&1)"; then
    fail "$label unexpectedly succeeded"
  fi
  case "$output" in
    *"$expected"*) ;;
    *) fail "$label was not actionable: $output" ;;
  esac
}

output="$(run_common)" || fail "missing .env did not use management defaults"
assert_contains "$output" 'runtime=/srv/storage/cf-agent-wechat' 'default runtime'
assert_contains "$output" 'api=http://127.0.0.1:6174' 'default API URL'
assert_contains "$output" 'container=cf-agent-wechat' 'default container'
assert_contains "$output" 'health=http://127.0.0.1:6174/health' 'default health URL'
assert_contains "$output" 'ws=ws://127.0.0.1:6174/api/ws/login' 'default WebSocket URL'
printf 'PASS missing production env uses documented defaults and derived URLs\n'

write_env \
  '  CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/custom/cf-agent-wechat' \
  'AGENT_WECHAT_BIND_IP=127.0.0.1' \
  'AGENT_WECHAT_PORT=7314' \
  'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat-custom' \
  "API_URL=\$(touch ${INJECTION_MARKER})" \
  "TOKEN_FILE=\$(touch ${INJECTION_MARKER})" \
  'AGENT_WECHAT_IMAGE=ignored@example'
output="$(run_common)" || fail "valid production env was rejected"
assert_contains "$output" 'runtime=/srv/custom/cf-agent-wechat' 'persisted runtime'
assert_contains "$output" 'api=http://127.0.0.1:7314' 'persisted API port'
assert_contains "$output" 'container=cf-agent-wechat-custom' 'persisted container'
assert_contains "$output" 'token=/srv/custom/cf-agent-wechat/secrets/auth-token' 'derived token'
assert_contains "$output" 'health=http://127.0.0.1:7314/health' 'persisted health URL'
assert_contains "$output" 'ws=ws://127.0.0.1:7314/api/ws/login' 'persisted WebSocket URL'
[ ! -e "$INJECTION_MARKER" ] || fail 'production env content was executed'
printf 'PASS allowlisted production env is loaded without evaluating content\n'

output="$(run_common \
  CF_RUNTIME_ROOT=/srv/custom/cf-agent-wechat/ \
  CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/custom/cf-agent-wechat \
  CF_AGENT_WECHAT_STORAGE_ROOT=/srv/custom/cf-agent-wechat \
  AGENT_WECHAT_BIND_IP=127.0.0.1 \
  AGENT_WECHAT_PORT=7314 \
  AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat-custom \
  CONTAINER_NAME=cf-agent-wechat-custom \
  API_URL=http://127.0.0.1:7314 \
  HEALTH_URL=http://127.0.0.1:7314/health \
  WS_URL=ws://127.0.0.1:7314/api/ws/login \
  TOKEN_FILE=/srv/custom/cf-agent-wechat/secrets/auth-token)" ||
  fail "identical process values were rejected"
assert_contains "$output" 'runtime=/srv/custom/cf-agent-wechat' 'identical runtime'
assert_contains "$output" 'api=http://127.0.0.1:7314' 'identical API URL'
assert_contains "$output" 'token=/srv/custom/cf-agent-wechat/secrets/auth-token' 'identical token path'
printf 'PASS process values identical to persisted authority remain accepted\n'

expect_failure 'conflicting CF runtime' 'CF_RUNTIME_ROOT 与 docker/.env' \
  CF_RUNTIME_ROOT=/srv/explicit/runtime
expect_failure 'conflicting compose runtime' 'CF_AGENT_WECHAT_RUNTIME_ROOT 与 docker/.env' \
  CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/explicit/runtime
expect_failure 'conflicting legacy runtime' 'CF_AGENT_WECHAT_STORAGE_ROOT 与 docker/.env' \
  CF_AGENT_WECHAT_STORAGE_ROOT=/srv/explicit/runtime
expect_failure 'conflicting bind IP' 'AGENT_WECHAT_BIND_IP 与 docker/.env' \
  AGENT_WECHAT_BIND_IP=0.0.0.0
expect_failure 'conflicting port' 'AGENT_WECHAT_PORT 与 docker/.env' \
  AGENT_WECHAT_PORT=8123
expect_failure 'conflicting compose container' 'AGENT_WECHAT_CONTAINER_NAME 与 docker/.env' \
  AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat-explicit
expect_failure 'conflicting management container' 'CONTAINER_NAME 与 docker/.env' \
  CONTAINER_NAME=cf-agent-wechat-explicit
expect_failure 'conflicting API port' 'API_URL 必须精确匹配' \
  API_URL=http://127.0.0.1:9000
expect_failure 'conflicting token path' 'TOKEN_FILE 必须精确匹配 docker/.env runtime 派生路径' \
  TOKEN_FILE=/srv/explicit/token
printf 'PASS persisted runtime, token, bind, port, container, and API reject conflicts\n'

rm -f -- "$ENV_FILE"
output="$(run_common \
  CF_RUNTIME_ROOT=/srv/explicit/runtime \
  AGENT_WECHAT_PORT=9000 \
  AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat-explicit \
  API_URL=http://127.0.0.1:9000 \
  TOKEN_FILE=/srv/explicit/token)" || fail "process-only management values were rejected"
assert_contains "$output" 'runtime=/srv/explicit/runtime' 'process-only runtime'
assert_contains "$output" 'api=http://127.0.0.1:9000' 'process-only API URL'
assert_contains "$output" 'container=cf-agent-wechat-explicit' 'process-only container'
assert_contains "$output" 'token=/srv/explicit/token' 'process-only token'
assert_contains "$output" 'health=http://127.0.0.1:9000/health' 'derived explicit health'
assert_contains "$output" 'ws=ws://127.0.0.1:9000/api/ws/login' 'derived explicit WebSocket'
printf 'PASS process-only endpoint is loopback, port-consistent, and fully derived\n'

expect_failure 'external API host' 'API_URL 必须精确匹配' \
  API_URL=http://example.invalid:6174
expect_failure 'localhost alias' 'API_URL 必须精确匹配' \
  API_URL=http://localhost:6174
expect_failure 'TLS endpoint' 'API_URL 必须精确匹配' \
  API_URL=https://127.0.0.1:6174
expect_failure 'API port without management port' 'API_URL 必须精确匹配' \
  API_URL=http://127.0.0.1:9000
expect_failure 'independent health URL' 'HEALTH_URL 不能独立覆盖' \
  HEALTH_URL=http://127.0.0.1:9999/health
expect_failure 'independent WebSocket URL' 'WS_URL 不能独立覆盖' \
  WS_URL=ws://127.0.0.1:9999/api/ws/login
expect_failure 'nondefault session' '生产 SESSION_ID 必须是 default' \
  SESSION_ID=other
printf 'PASS external/TLS endpoints, independent derived URLs, and sessions fail closed\n'

extended_runtime='/srv/cf@prod%+foo,bar=baz:qux~'
write_env \
  "CF_AGENT_WECHAT_RUNTIME_ROOT=$extended_runtime" \
  'AGENT_WECHAT_BIND_IP=127.0.0.1' \
  'AGENT_WECHAT_PORT=6174' \
  'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat'
output="$(run_common)" || fail "bootstrap-compatible dotenv-safe runtime was rejected"
assert_contains "$output" "runtime=$extended_runtime" 'extended dotenv-safe runtime'
assert_contains "$output" "token=$extended_runtime/secrets/auth-token" \
  'extended dotenv-safe token path'
printf 'PASS bootstrap-compatible dotenv-safe runtime characters remain readable\n'

write_env \
  'CF_AGENT_WECHAT_STORAGE_ROOT=/srv/legacy/cf-agent-wechat' \
  'AGENT_WECHAT_BIND_IP=127.0.0.1' \
  'AGENT_WECHAT_PORT=6174' \
  'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat'
output="$(run_common)" || fail "legacy runtime key was not accepted"
assert_contains "$output" 'runtime=/srv/legacy/cf-agent-wechat' 'legacy runtime'
printf 'PASS legacy storage root remains readable\n'

write_env \
  'CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/current' \
  'CF_AGENT_WECHAT_STORAGE_ROOT=/srv/legacy' \
  'AGENT_WECHAT_BIND_IP=127.0.0.1' \
  'AGENT_WECHAT_PORT=6174' \
  'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat'
expect_failure 'conflicting legacy runtime roots' '新旧 runtime root 配置冲突'

write_env \
  'CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/one' \
  'CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/two'
expect_failure 'duplicate allowlisted key' '重复配置键：CF_AGENT_WECHAT_RUNTIME_ROOT'

write_env \
  'CF_AGENT_WECHAT_RUNTIME_ROOT=/' \
  'AGENT_WECHAT_BIND_IP=127.0.0.1'
expect_failure 'filesystem-root runtime' 'CF_AGENT_WECHAT_RUNTIME_ROOT 无效'

unsafe_runtime_values=(
  '/srv/has space'
  '/srv/has$cash'
  '/srv/has#comment'
  "/srv/has'quote"
  '/srv/has"quote'
  '/srv/has\backslash'
  '/srv/has;semicolon'
)
for unsafe_runtime in "${unsafe_runtime_values[@]}"; do
  write_env "CF_AGENT_WECHAT_RUNTIME_ROOT=$unsafe_runtime"
  expect_failure "dotenv-unsafe runtime: $unsafe_runtime" 'dotenv 不安全字符'
done
printf 'PASS persisted runtime rejects dotenv-unsafe characters\n'

write_env \
  'CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/custom' \
  'AGENT_WECHAT_BIND_IP=0.0.0.0'
expect_failure 'non-loopback bind' 'AGENT_WECHAT_BIND_IP 必须是 127.0.0.1'
printf 'PASS invalid, duplicate, and conflicting production env values fail closed\n'

write_env 'CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/custom'
if [ "$HOST_KERNEL" = 'Linux' ]; then
  mv "$ENV_FILE" "${ENV_FILE}.real"
  if ln -s "${ENV_FILE}.real" "$ENV_FILE" 2>/dev/null; then
    expect_failure 'symlink environment file' '非符号链接普通文件'
    rm -f -- "$ENV_FILE"
  else
    fail 'could not create environment symlink on Linux'
  fi
  mv "${ENV_FILE}.real" "$ENV_FILE"
else
  printf 'SKIP environment symlink check on non-Linux host\n'
fi

if [ "$HOST_KERNEL" = 'Linux' ]; then
  chmod 777 "$FIXTURE_ROOT"
  expect_failure 'group/other writable repository root' '仓库根目录不能被 group/other 写入'
  chmod 755 "$FIXTURE_ROOT"
  chmod 777 "${FIXTURE_ROOT}/docker"
  expect_failure 'group/other writable environment directory' '生产配置目录不能被 group/other 写入'
  chmod 755 "${FIXTURE_ROOT}/docker"
  chmod 640 "$ENV_FILE"
  run_common >/dev/null || fail 'environment file mode 0640 was rejected'
  chmod 644 "$ENV_FILE"
  expect_failure 'world-readable environment file' '权限必须是 0600 或 0640'
  chmod 666 "$ENV_FILE"
  expect_failure 'group/other writable environment file' '权限必须是 0600 或 0640'
  chmod 600 "$ENV_FILE"
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$ENV_FILE"
    expect_failure 'unreadable environment file' '当前管理用户无法读取'
    chmod 600 "$ENV_FILE"
  else
    printf 'SKIP unreadable environment check when running as root\n'
  fi
else
  printf 'SKIP POSIX environment mode checks on non-Linux host\n'
fi
printf 'PASS production env type and permissions fail closed\n'

printf 'All management environment tests passed.\n'
