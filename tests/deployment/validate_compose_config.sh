#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
COMPOSE_FILE="$REPO_ROOT/docker/compose.cfserver.yaml"
REQUIRE_COMPOSE="$(printenv CF_REQUIRE_DOCKER_COMPOSE_CONFIG 2>/dev/null || printf 0)"
TEST_ROOT="$(mktemp -d /tmp/cf-agent-wechat-compose.XXXXXX)"

cleanup() {
  case "$TEST_ROOT" in
    /tmp/cf-agent-wechat-compose.*) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'Refusing unsafe test cleanup path: %s\n' "$TEST_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

fail_or_skip() {
  if [ "$REQUIRE_COMPOSE" = 1 ]; then
    fail "$1"
  fi
  printf 'SKIP: %s\n' "$1"
  exit 0
}

case "$REQUIRE_COMPOSE" in
  0|1) ;;
  *) fail "CF_REQUIRE_DOCKER_COMPOSE_CONFIG must be 0 or 1" ;;
esac
command -v docker >/dev/null 2>&1 ||
  fail_or_skip "Docker CLI is unavailable"
docker compose version >/dev/null 2>&1 ||
  fail_or_skip "Docker Compose v2 is unavailable"
command -v python3 >/dev/null 2>&1 ||
  fail "Python 3 is required for Compose JSON validation"
command -v timeout >/dev/null 2>&1 ||
  fail "GNU timeout is required for bounded Compose rendering"

IMAGE="registry.example/cf-agent-wechat@sha256:$(printf 'b%.0s' {1..64})"
RUNTIME_ROOT=/srv/compose-validation/fresh-runtime
TOKEN_FILE=/srv/storage/cf-agent-wechat/secrets/auth-token
ENV_FILE="$TEST_ROOT/production.env"
JSON_FILE="$TEST_ROOT/compose.json"

{
  printf '%s\n' \
    "AGENT_WECHAT_IMAGE=$IMAGE" \
    'AGENT_WECHAT_BIND_IP=127.0.0.1' \
    'AGENT_WECHAT_PORT=6174' \
    'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat' \
    'COMPOSE_PROJECT_NAME=cf-agent-wechat' \
    'CF_AGENT_WECHAT_STORAGE_ROOT=/srv/storage/cf-agent-wechat' \
    "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" \
    'CF_AGENT_WECHAT_ARCHIVE_ROOT=/srv/storage/cf-agent-wechat/session-archive' \
    'PROXY=' \
    'RUST_LOG=info'
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

if ! env \
  -u AGENT_WECHAT_IMAGE -u AGENT_WECHAT_BIND_IP -u AGENT_WECHAT_PORT \
  -u AGENT_WECHAT_CONTAINER_NAME -u CF_AGENT_WECHAT_STORAGE_ROOT \
  -u CF_AGENT_WECHAT_RUNTIME_ROOT -u CF_AGENT_WECHAT_ARCHIVE_ROOT \
  -u CF_AGENT_WECHAT_TOKEN_FILE -u COMPOSE_PROJECT_NAME -u PROXY -u RUST_LOG \
  timeout --signal=TERM --kill-after=2s 30s \
  docker compose \
    --env-file "$ENV_FILE" \
    --project-directory "$REPO_ROOT" \
    --project-name cf-agent-wechat-compose-validation \
    -f "$COMPOSE_FILE" \
    config --format json > "$JSON_FILE"; then
  fail "production Compose did not render successfully"
fi

python3 - "$JSON_FILE" "$IMAGE" "$RUNTIME_ROOT" "$TOKEN_FILE" <<'PY'
import json
import re
import sys

config_path, expected_image, runtime_root, token_file = sys.argv[1:]

with open(config_path, encoding="utf-8") as stream:
    config = json.load(stream)

service = config["services"]["agent-wechat"]
assert service.get("image") == expected_image, service.get("image")
assert re.fullmatch(r"[^\s]+@sha256:[0-9a-fA-F]{64}", expected_image)
assert service.get("container_name") == "cf-agent-wechat"
assert service.get("restart") == "no", service.get("restart")
assert service.get("security_opt") == ["seccomp=unconfined"]
assert service.get("cap_add") == ["SYS_PTRACE"]
assert str(service.get("environment", {}).get("ENABLE_VNC")) == "0"

ports = service.get("ports", [])
assert len(ports) == 1, ports
port = ports[0]
assert port.get("host_ip") == "127.0.0.1", port
assert str(port.get("published")) == "6174", port
assert port.get("target") == 6174, port
assert port.get("protocol") == "tcp", port

volumes = service.get("volumes", [])
assert len(volumes) == 3, volumes
by_target = {volume["target"]: volume for volume in volumes}
expected_mounts = {
    "/data": (f"{runtime_root}/data", False),
    "/home/wechat": (f"{runtime_root}/wechat-home", False),
    "/data/auth-token": (token_file, True),
}
assert set(by_target) == set(expected_mounts), by_target
for target, (source, readonly) in expected_mounts.items():
    mount = by_target[target]
    assert mount.get("type") == "bind", mount
    assert mount.get("source") == source, mount
    assert bool(mount.get("read_only", False)) is readonly, mount
    assert mount.get("bind", {}).get("create_host_path") in (None, False), mount

networks = service.get("networks", {})
assert set(networks) == {"cf-internal"}, networks
assert "cf-agent-wechat" in networks["cf-internal"].get("aliases", []), networks
network = config.get("networks", {}).get("cf-internal", {})
assert network.get("name") == "cf-internal", network
assert network.get("external") is True, network

health = service.get("healthcheck", {})
assert health.get("test") == [
    "CMD",
    "curl",
    "--fail",
    "--silent",
    "--show-error",
    "http://127.0.0.1:6174/health",
], health
assert health.get("interval") == "30s", health
assert health.get("timeout") == "5s", health
assert health.get("retries") == 5, health
assert health.get("start_period") == "1m30s", health

logging = service.get("logging", {})
assert logging.get("driver") == "json-file", logging
assert str(logging.get("options", {}).get("max-size")) == "20m", logging
assert str(logging.get("options", {}).get("max-file")) == "3", logging
PY

printf '%s\n' 'PASS: real production Compose render enforces forced fresh QR contracts'
