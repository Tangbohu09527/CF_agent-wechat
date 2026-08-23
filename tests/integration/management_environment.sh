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
DIGEST="$(printf '%064d' 0)"

write_env() {
  printf '%s\n' "$@" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

read_contract() {
  env \
    CF_AGENT_WECHAT_ENV_FILE="$ENV_FILE" \
    CF_AGENT_WECHAT_STORAGE_ROOT=/process/storage \
    CF_AGENT_WECHAT_RUNTIME_ROOT=/process/runtime \
    CF_AGENT_WECHAT_ARCHIVE_ROOT=/process/archive \
    CONTAINER_NAME=process-container \
    bash -c '
      source "$1/scripts/common.sh"
      source "$1/scripts/qr-runtime-common.sh"
      if ! runtime_load_management_environment; then
        printf "%s" "$RUNTIME_MANAGEMENT_ENV_ERROR" >&2
        exit 1
      fi
      printf "%s|%s|%s|%s" \
        "$STORAGE_ROOT" "$RUNTIME_ROOT" "$ARCHIVE_ROOT" "$CONTAINER_NAME"
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

write_env \
  '  # safe whitespace-prefixed comment' \
  'COMPOSE_PROJECT_NAME=cf-agent-wechat' \
  "AGENT_WECHAT_IMAGE=ghcr.io/example/agent-wechat@sha256:${DIGEST}" \
  'CF_AGENT_WECHAT_STORAGE_ROOT=/srv/storage/cf-agent-wechat' \
  'CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/storage/cf-agent-wechat/runtime' \
  'CF_AGENT_WECHAT_ARCHIVE_ROOT=/srv/storage/cf-agent-wechat/session-archive' \
  'AGENT_WECHAT_BIND_IP=127.0.0.1' \
  'AGENT_WECHAT_PORT=6174' \
  'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat' \
  'PROXY=http://proxy.example:8080' \
  'RUST_LOG=info'

[ "$(read_contract)" = \
  '/srv/storage/cf-agent-wechat|/srv/storage/cf-agent-wechat/runtime|/srv/storage/cf-agent-wechat/session-archive|cf-agent-wechat' ] || {
  printf '%s\n' 'FAIL valid docker/.env was not authoritative' >&2
  exit 1
}
printf '%s\n' 'PASS safe docker/.env is authoritative'

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

printf '%s\n' 'All management environment tests passed.'
