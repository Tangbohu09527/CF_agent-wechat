#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
COMPOSE_FILE="${REPO_ROOT}/docker/compose.cfserver.yaml"
REQUIRE_DOCKER="${CF_REQUIRE_DOCKER_E2E:-0}"
SERVICE_NAME="agent-wechat"
NETWORK_NAME="cf-internal"
TEST_ROOT=""
RUNTIME_ROOT=""
ENV_FILE=""
OVERRIDE_FILE=""
BUILD_CONTEXT=""
PROJECT_NAME="cf-agent-wechat-e2e-$$"
CONTAINER_NAME="cf-agent-wechat-e2e-$$"
IMAGE_NAME="cf-agent-wechat-e2e:$$"
HOST_PORT=""
NETWORK_CREATED=0
COMPOSE_READY=0
IMAGE_OWNED=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ "$COMPOSE_READY" -eq 1 ]; then
    compose ps --all >&2 || true
    compose logs --no-color --tail=100 "$SERVICE_NAME" >&2 || true
  fi
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

fail_or_skip() {
  local message="$1"

  if [ "$REQUIRE_DOCKER" = "1" ]; then
    fail "$message"
  fi
  printf 'SKIP: %s\n' "$message"
  exit 0
}

compose() {
  env \
    -u AGENT_WECHAT_IMAGE \
    -u AGENT_WECHAT_BIND_IP \
    -u AGENT_WECHAT_PORT \
    -u AGENT_WECHAT_CONTAINER_NAME \
    -u CF_RUNTIME_ROOT \
    -u CF_AGENT_WECHAT_RUNTIME_ROOT \
    -u CF_AGENT_WECHAT_STORAGE_ROOT \
    -u CF_E2E_BUILD_CONTEXT \
    -u PROXY \
    -u RUST_LOG \
    -u COMPOSE_PROJECT_NAME \
    docker compose \
      --env-file "$ENV_FILE" \
      --project-directory "$REPO_ROOT" \
      --project-name "$PROJECT_NAME" \
      -f "$COMPOSE_FILE" \
      -f "$OVERRIDE_FILE" \
      "$@"
}

cleanup() {
  local status=$?
  local cleanup_failed=0

  trap - EXIT INT TERM HUP

  set +e
  if [ "$COMPOSE_READY" -eq 1 ]; then
    if ! compose down --remove-orphans --timeout 10; then
      printf 'CLEANUP ERROR: Compose down failed for project %s\n' "$PROJECT_NAME" >&2
      cleanup_failed=1
    fi
  fi
  if [ "$IMAGE_OWNED" -eq 1 ]; then
    if ! docker image rm -f "$IMAGE_NAME"; then
      printf 'CLEANUP ERROR: could not remove test image %s\n' "$IMAGE_NAME" >&2
      cleanup_failed=1
    fi
  fi
  if [ "$NETWORK_CREATED" -eq 1 ]; then
    if ! docker network rm "$NETWORK_NAME"; then
      printf 'CLEANUP ERROR: could not remove test network %s\n' "$NETWORK_NAME" >&2
      cleanup_failed=1
    fi
  fi
  if [ -n "$TEST_ROOT" ]; then
    case "$TEST_ROOT" in
      "${TMPDIR:-/tmp}"/cf-agent-wechat-compose-e2e.*)
        if ! rm -rf -- "$TEST_ROOT"; then
          printf 'CLEANUP ERROR: could not remove test directory %s\n' "$TEST_ROOT" >&2
          cleanup_failed=1
        fi
        ;;
      *)
        printf 'Refusing unsafe cleanup path: %s\n' "$TEST_ROOT" >&2
        cleanup_failed=1
        ;;
    esac
  fi
  if [ "$status" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then
    status=1
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

command -v docker >/dev/null 2>&1 || fail_or_skip "Docker CLI is unavailable; production Compose recovery E2E was not run"
docker compose version >/dev/null 2>&1 || fail_or_skip "Docker Compose v2 is unavailable; production Compose recovery E2E was not run"
docker info >/dev/null 2>&1 || fail_or_skip "Docker daemon is unavailable; production Compose recovery E2E was not run"

for command_name in curl env grep install mktemp python3 realpath sleep; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required test command is missing: $command_name"
done


if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  fail_or_skip "Docker network $NETWORK_NAME already exists; this E2E requires an isolated daemon and refuses to reuse the fixed production network"
fi

docker network create --driver bridge "$NETWORK_NAME" >/dev/null || \
  fail "could not create isolated external Docker network: $NETWORK_NAME"
NETWORK_CREATED=1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cf-agent-wechat-compose-e2e.XXXXXX")"
RUNTIME_ROOT="${TEST_ROOT}/runtime"
ENV_FILE="${TEST_ROOT}/compose.env"
OVERRIDE_FILE="${TEST_ROOT}/compose.override.yaml"
BUILD_CONTEXT="${TEST_ROOT}/image"

install -d -m 755 "$RUNTIME_ROOT" "$BUILD_CONTEXT"
install -d -m 700 \
  "$RUNTIME_ROOT/data" \
  "$RUNTIME_ROOT/wechat-home" \
  "$RUNTIME_ROOT/secrets"
RUNTIME_ROOT="$(realpath -e -- "$RUNTIME_ROOT")"

TOKEN="$(printf 'a%.0s' {1..64})"
RUNTIME_MARKER="runtime-marker-$$"
printf '%s\n' "$TOKEN" > "$RUNTIME_ROOT/secrets/auth-token"
printf '%s\n' "$RUNTIME_MARKER" > "$RUNTIME_ROOT/data/runtime.marker"
printf '%s\n' 'logged_in' > "$RUNTIME_ROOT/wechat-home/session.status"
chmod 600 "$RUNTIME_ROOT/secrets/auth-token"

HOST_PORT="$(python3 -c '
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
')"

cat > "$BUILD_CONTEXT/mock_agent.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import http.server
import json
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit


TOKEN_FILE = Path("/data/auth-token")
RUNTIME_MARKER = Path("/data/runtime.marker")
SESSION_FILE = Path("/home/wechat/session.status")


def curl_main() -> int:
    urls = [value for value in sys.argv[1:] if value.startswith(("http://", "https://"))]
    if len(urls) != 1:
        return 2
    try:
        with urllib.request.urlopen(urls[0], timeout=4) as response:
            response.read()
            return 0 if 200 <= response.status < 400 else 22
    except Exception:
        return 22


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args: object) -> None:
        return

    def respond(self, status: int, payload: dict[str, str]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def runtime_ready(self) -> bool:
        return TOKEN_FILE.is_file() and RUNTIME_MARKER.is_file() and SESSION_FILE.is_file()

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/health":
            if self.runtime_ready():
                self.respond(200, {"status": "ok"})
            else:
                self.respond(503, {"status": "runtime_missing"})
            return

        if path != "/api/status/auth":
            self.respond(404, {"error": "not_found"})
            return
        if not self.runtime_ready():
            self.respond(503, {"status": "runtime_missing"})
            return

        token = TOKEN_FILE.read_text(encoding="utf-8").rstrip("\n")
        if self.headers.get("Authorization") != f"Bearer {token}":
            self.respond(401, {"error": "unauthorized"})
            return
        if self.headers.get("X-Session-Id") != "default":
            self.respond(400, {"error": "invalid_session"})
            return

        self.respond(200, {"status": SESSION_FILE.read_text(encoding="utf-8").strip()})


def main() -> int:
    if Path(sys.argv[0]).name == "curl":
        return curl_main()
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 6174), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

cat > "$BUILD_CONTEXT/Dockerfile" <<'DOCKERFILE'
FROM python:3.12-alpine
COPY --chmod=0755 mock_agent.py /opt/mock_agent.py
RUN ln -s /opt/mock_agent.py /usr/local/bin/curl
ENTRYPOINT ["/opt/mock_agent.py"]
DOCKERFILE

cat > "$OVERRIDE_FILE" <<'YAML'
services:
  agent-wechat:
    build:
      context: "${CF_E2E_BUILD_CONTEXT:?Set CF_E2E_BUILD_CONTEXT in the test environment}"
    healthcheck:
      interval: 1s
      timeout: 2s
      retries: 30
      start_period: 1s
YAML

cat > "$ENV_FILE" <<EOF
AGENT_WECHAT_IMAGE=$IMAGE_NAME
AGENT_WECHAT_BIND_IP=127.0.0.1
AGENT_WECHAT_PORT=$HOST_PORT
AGENT_WECHAT_CONTAINER_NAME=$CONTAINER_NAME
CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT
CF_E2E_BUILD_CONTEXT=$BUILD_CONTEXT
PROXY=
RUST_LOG=info
EOF
chmod 600 "$ENV_FILE"
COMPOSE_READY=1


wait_for_healthy_service() {
  local deadline=$((SECONDS + 90))
  local container_id="" state="" health=""

  while [ "$SECONDS" -lt "$deadline" ]; do
    container_id="$(compose ps --all --quiet "$SERVICE_NAME" 2>/dev/null || true)"
    if [ -n "$container_id" ]; then
      state="$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
        printf '%s' "$container_id"
        return 0
      fi
      case "$state" in
        exited|dead)
          printf 'Container entered terminal state: %s\n' "$state" >&2
          return 1
          ;;
      esac
    fi
    sleep 1
  done
  printf 'Timed out waiting for service (state=%s, health=%s)\n' \
    "${state:-missing}" "${health:-missing}" >&2
  return 1
}

wait_for_automatic_restart() {
  local container_id="$1" previous_count="$2"
  local deadline=$((SECONDS + 90))
  local state="" health="" restart_count=""

  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
    restart_count="$(docker inspect --format '{{.RestartCount}}' "$container_id" 2>/dev/null || true)"
    if [[ "$restart_count" =~ ^[0-9]+$ ]] &&
      [ "$restart_count" -gt "$previous_count" ] &&
      [ "$state" = "running" ] &&
      [ "$health" = "healthy" ]; then
      return 0
    fi
    sleep 1
  done
  printf 'Timed out waiting for automatic restart (state=%s, health=%s, restart_count=%s)\n' \
    "${state:-missing}" "${health:-missing}" "${restart_count:-missing}" >&2
  return 1
}

check_authenticated_api() {
  local response status

  response="$(
    printf 'Authorization: Bearer %s\nX-Session-Id: default\n' "$TOKEN" | \
      curl --disable --noproxy '*' --fail --silent --show-error \
        --connect-timeout 2 --max-time 4 --header @- \
        "http://127.0.0.1:${HOST_PORT}/api/status/auth"
  )" || return 1
  status="$(printf '%s' "$response" | python3 -c '
import json
import sys
payload = json.load(sys.stdin)
status = payload.get("status") if isinstance(payload, dict) else None
if not isinstance(status, str):
    raise SystemExit(1)
sys.stdout.write(status)
')" || return 1
  [ "$status" = "logged_in" ]
}

wait_for_authenticated_api() {
  local deadline=$((SECONDS + 30))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if check_authenticated_api >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

assert_mount() {
  local container_id="$1" destination="$2" expected_source="$3" expected_rw="$4"
  local actual

  actual="$(docker inspect --format \
    "{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{.Type}}|{{.Source}}|{{.RW}}{{end}}{{end}}" \
    "$container_id")"
  [ "$actual" = "bind|${expected_source}|${expected_rw}" ] || \
    fail "mount $destination mismatch: expected bind|${expected_source}|${expected_rw}, found ${actual:-missing}"
}

assert_runtime_contract() {
  local container_id="$1" stage="$2"
  local config_image container_name mount_count restart_policy
  local network_count network_attachment network_alias port_binding

  container_name="$(docker inspect --format '{{.Name}}' "$container_id")"
  [ "$container_name" = "/${CONTAINER_NAME}" ] || \
    fail "$stage container name is ${container_name:-missing}, expected /${CONTAINER_NAME}"
  config_image="$(docker inspect --format '{{.Config.Image}}' "$container_id")"
  [ "$config_image" = "$IMAGE_NAME" ] || \
    fail "$stage container image is ${config_image:-missing}, expected $IMAGE_NAME"


  [ "$(docker inspect --format '{{.State.Status}}' "$container_id")" = "running" ] || \
    fail "$stage container is not running"
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$container_id")" = "healthy" ] || \
    fail "$stage container is not healthy"

  restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_id")"
  [ "$restart_policy" = "unless-stopped" ] || \
    fail "$stage restart policy is ${restart_policy:-missing}, expected unless-stopped"
  mount_count="$(docker inspect --format '{{len .Mounts}}' "$container_id")"
  [ "$mount_count" = 3 ] || \
    fail "$stage container has ${mount_count:-unknown} mounts, expected exactly 3"

  assert_mount "$container_id" /data "$RUNTIME_ROOT/data" true
  assert_mount "$container_id" /home/wechat "$RUNTIME_ROOT/wechat-home" true
  assert_mount "$container_id" /data/auth-token "$RUNTIME_ROOT/secrets/auth-token" false
  network_count="$(docker inspect --format '{{len .NetworkSettings.Networks}}' "$container_id")"
  [ "$network_count" = 1 ] || \
    fail "$stage container has ${network_count:-unknown} networks, expected exactly 1"

  network_attachment="$(docker inspect --format \
    "{{if index .NetworkSettings.Networks \"${NETWORK_NAME}\"}}attached{{end}}" \
    "$container_id")"
  [ "$network_attachment" = attached ] || fail "$stage container is not attached to $NETWORK_NAME"
  network_alias="$(docker inspect --format \
    "{{range (index .NetworkSettings.Networks \"${NETWORK_NAME}\").Aliases}}{{if eq . \"cf-agent-wechat\"}}present{{end}}{{end}}" \
    "$container_id")"
  [ "$network_alias" = present ] || fail "$stage container is missing cf-agent-wechat network alias"

  port_binding="$(docker inspect --format \
    '{{with (index .NetworkSettings.Ports "6174/tcp")}}{{range .}}{{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}{{end}}' \
    "$container_id")"
  [ "$port_binding" = "127.0.0.1:${HOST_PORT}" ] || \
    fail "$stage port binding is ${port_binding:-missing}, expected 127.0.0.1:${HOST_PORT}"

  docker exec "$container_id" grep -Fxq "$RUNTIME_MARKER" /data/runtime.marker || \
    fail "$stage runtime marker is unavailable in /data"
  docker exec "$container_id" grep -Fxq logged_in /home/wechat/session.status || \
    fail "$stage logged_in session marker is unavailable in /home/wechat"
  docker exec "$container_id" grep -Fxq container-runtime-marker /data/container-runtime.marker || \
    fail "$stage container-written runtime marker did not persist"
  docker exec "$container_id" grep -Fxq container-session-marker /home/wechat/container-session.marker || \
    fail "$stage container-written session marker did not persist"
  if docker exec "$container_id" /bin/sh -c 'printf x >> /data/auth-token' >/dev/null 2>&1; then
    fail "$stage auth-token mount is writable inside the container"
  fi
  grep -Fxq "$TOKEN" "$RUNTIME_ROOT/secrets/auth-token" || \
    fail "$stage auth token changed on the host"
  wait_for_authenticated_api || fail "$stage authenticated API did not recover as logged_in"
  pass "$stage runtime, session, API, mounts, network, port, health, and restart policy"
}

compose config --quiet || fail "production Compose plus test override is invalid"
IMAGE_OWNED=1
compose up -d --build "$SERVICE_NAME" || fail "could not start production Compose recovery fixture"
INITIAL_CONTAINER_ID="$(wait_for_healthy_service)" || fail "initial service did not become running and healthy"
wait_for_authenticated_api || fail "initial authenticated API did not become logged_in"

docker exec "$INITIAL_CONTAINER_ID" /bin/sh -c \
  'printf "%s\n" container-runtime-marker > /data/container-runtime.marker; printf "%s\n" container-session-marker > /home/wechat/container-session.marker' || \
  fail "container could not write persistent runtime markers"
assert_runtime_contract "$INITIAL_CONTAINER_ID" initial

INITIAL_RESTART_COUNT="$(docker inspect --format '{{.RestartCount}}' "$INITIAL_CONTAINER_ID")"
[[ "$INITIAL_RESTART_COUNT" =~ ^[0-9]+$ ]] || fail "initial restart count is invalid"
# Docker activates a restart policy only after the container has stayed up
# successfully for at least ten seconds.
sleep 11
# Crash container init through the daemon instead of relying on namespace
# PID 1 signal semantics from an exec process inside the container.
docker kill --signal KILL "$INITIAL_CONTAINER_ID" >/dev/null || \
  fail "could not inject a daemon-side SIGKILL into the initial container"
wait_for_automatic_restart "$INITIAL_CONTAINER_ID" "$INITIAL_RESTART_COUNT" || \
  fail "unless-stopped did not recover the service after daemon-side SIGKILL"
AUTO_RESTARTED_CONTAINER_ID="$(compose ps --all --quiet "$SERVICE_NAME")"
[ "$AUTO_RESTARTED_CONTAINER_ID" = "$INITIAL_CONTAINER_ID" ] || \
  fail "automatic process recovery unexpectedly replaced the container"
assert_runtime_contract "$AUTO_RESTARTED_CONTAINER_ID" auto-restarted

docker restart "$INITIAL_CONTAINER_ID" >/dev/null || fail "docker restart failed"
RESTARTED_CONTAINER_ID="$(wait_for_healthy_service)" || fail "service did not recover after docker restart"
[ "$RESTARTED_CONTAINER_ID" = "$INITIAL_CONTAINER_ID" ] || \
  fail "docker restart unexpectedly replaced the container"
assert_runtime_contract "$RESTARTED_CONTAINER_ID" restarted

compose up -d --force-recreate --no-deps "$SERVICE_NAME" || fail "Compose force-recreate failed"
RECREATED_CONTAINER_ID="$(wait_for_healthy_service)" || fail "service did not recover after Compose recreation"
[ "$RECREATED_CONTAINER_ID" != "$INITIAL_CONTAINER_ID" ] || \
  fail "Compose force-recreate did not replace the container"
assert_runtime_contract "$RECREATED_CONTAINER_ID" recreated

printf '%s\n' 'All production Compose recovery E2E checks passed.'
