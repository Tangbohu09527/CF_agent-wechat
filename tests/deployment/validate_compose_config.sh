#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
COMPOSE_FILE="${REPO_ROOT}/docker/compose.cfserver.yaml"
REQUIRE_COMPOSE="${CF_REQUIRE_DOCKER_COMPOSE_CONFIG:-0}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cf-agent-wechat-compose.XXXXXX")"

cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/cf-agent-wechat-compose.*) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'Refusing unsafe cleanup path: %s\n' "$TEST_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail_or_skip() {
  local message="$1"
  if [ "$REQUIRE_COMPOSE" = "1" ]; then
    printf 'FAIL: %s\n' "$message" >&2
    exit 1
  fi
  printf 'SKIP: %s\n' "$message"
  exit 0
}

command -v docker >/dev/null 2>&1 || fail_or_skip "Docker CLI is unavailable"
docker compose version >/dev/null 2>&1 || fail_or_skip "Docker Compose v2 is unavailable"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  printf 'FAIL: Python 3 is required to validate Compose JSON\n' >&2
  exit 1
fi

IMAGE="registry.example/cf-agent-wechat@sha256:$(printf 'a%.0s' {1..64})"

validate_render() {
  local label="$1"
  local root_key="$2"
  local runtime_root="$3"
  local env_file="${TEST_ROOT}/${label}.env"
  local json_file="${TEST_ROOT}/${label}.json"

  {
    printf '%s\n' \
      "AGENT_WECHAT_IMAGE=$IMAGE" \
      'AGENT_WECHAT_BIND_IP=127.0.0.1' \
      'AGENT_WECHAT_PORT=6174' \
      'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat' \
      "${root_key}=${runtime_root}"
  } > "$env_file"

  env -u AGENT_WECHAT_IMAGE -u AGENT_WECHAT_BIND_IP \
    -u AGENT_WECHAT_PORT -u AGENT_WECHAT_CONTAINER_NAME \
    -u CF_AGENT_WECHAT_RUNTIME_ROOT -u CF_AGENT_WECHAT_STORAGE_ROOT \
    -u PROXY -u RUST_LOG -u COMPOSE_PROJECT_NAME \
    docker compose \
      --env-file "$env_file" \
      --project-directory "$REPO_ROOT" \
      -f "$COMPOSE_FILE" \
      config --format json > "$json_file"

  "$PYTHON_BIN" - "$json_file" "$runtime_root" "$label" "$IMAGE" <<'PY'
import json
import sys

config_path, runtime_root, label, expected_image = sys.argv[1:]
with open(config_path, encoding="utf-8") as handle:
    config = json.load(handle)

service = config["services"]["agent-wechat"]
assert service.get("container_name") == "cf-agent-wechat", (
    label, service.get("container_name"))
assert service.get("image") == expected_image, (
    label, service.get("image"), expected_image)
assert service.get("restart") == "unless-stopped", (label, service.get("restart"))

healthcheck = service.get("healthcheck", {})
assert healthcheck.get("test") == [
    "CMD",
    "curl",
    "--fail",
    "--silent",
    "--show-error",
    "http://127.0.0.1:6174/health",
], (label, healthcheck)
assert healthcheck.get("interval") == "30s", (label, healthcheck)
assert healthcheck.get("timeout") == "5s", (label, healthcheck)
assert healthcheck.get("retries") == 5, (label, healthcheck)
assert healthcheck.get("start_period") == "1m30s", (label, healthcheck)

volumes = {volume["target"]: volume for volume in service.get("volumes", [])}
expected = {
    "/data": f"{runtime_root}/data",
    "/home/wechat": f"{runtime_root}/wechat-home",
    "/data/auth-token": f"{runtime_root}/secrets/auth-token",
}
assert set(volumes) == set(expected), (label, volumes)
for target, source in expected.items():
    volume = volumes[target]
    assert volume.get("type") == "bind", (label, target, volume)
    assert volume.get("source") == source, (label, target, volume)
    create_host_path = volume.get("bind", {}).get("create_host_path")
    assert create_host_path is None or create_host_path is False, (
        label, target, volume)

assert volumes["/data/auth-token"].get("read_only") is True
assert volumes["/data"].get("read_only", False) is False
assert volumes["/home/wechat"].get("read_only", False) is False

ports = service.get("ports", [])
assert len(ports) == 1, (label, ports)
port = ports[0]
assert port.get("target") == 6174, (label, port)
assert str(port.get("published")) == "6174", (label, port)
assert port.get("host_ip") == "127.0.0.1", (label, port)
assert port.get("protocol") == "tcp", (label, port)

service_networks = service.get("networks", {})
assert set(service_networks) == {"cf-internal"}, (label, service_networks)
aliases = service_networks["cf-internal"].get("aliases", [])
assert "cf-agent-wechat" in aliases, (label, aliases)
network = config.get("networks", {}).get("cf-internal", {})
assert network.get("name") == "cf-internal", network
assert network.get("external") is True, network
PY

  printf 'PASS: real Compose render (%s)\n' "$label"
}

validate_render new-only CF_AGENT_WECHAT_RUNTIME_ROOT /srv/compose-validation/new-runtime
validate_render legacy-only CF_AGENT_WECHAT_STORAGE_ROOT /srv/compose-validation/legacy-runtime
printf '%s\n' 'All real Compose render checks passed.'
