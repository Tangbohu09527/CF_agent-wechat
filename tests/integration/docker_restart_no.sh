#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DEPLOYMENT_ROOT="/srv/storage/cf-agent-wechat"
COMPOSE_FILE="${REPO_ROOT}/docker/compose.cfserver.yaml"
ENV_FILE=""
NETWORK_CREATED=0
CONTAINERS=()

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local container

  set +e
  for container in "${CONTAINERS[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1
  done
  if [ "$NETWORK_CREATED" -eq 1 ]; then
    docker network rm cf-internal >/dev/null 2>&1
  fi
  if [ -n "$ENV_FILE" ]; then
    rm -f -- "$ENV_FILE"
  fi
  if [ -d "$DEPLOYMENT_ROOT" ]; then
    rm -rf -- "${DEPLOYMENT_ROOT:?}"
  fi
}
trap cleanup EXIT

if [ "${GITHUB_ACTIONS:-}" != "true" ] || \
  [ "${CF_AGENT_WECHAT_RESTART_NO_TEST:-}" != "1" ]; then
  fail "refusing to run outside the disposable restart=no CI job"
fi
if [ "$(id -u)" -ne 0 ]; then
  fail "restart=no Docker integration test must run as root"
fi
if [ -e "$DEPLOYMENT_ROOT" ]; then
  fail "refusing to touch an existing deployment root: ${DEPLOYMENT_ROOT}"
fi
for command_name in docker python3 systemctl timeout; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail "missing required command: ${command_name}"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
systemctl is-active --quiet docker || fail "systemd Docker service is not active"
LIVE_RESTORE="$(docker info --format '{{json .LiveRestoreEnabled}}')" ||
  fail "Docker live-restore state could not be inspected"
[ "$LIVE_RESTORE" = false ] ||
  fail "restart=no lifecycle E2E requires Docker live-restore=false"
printf '%s\n' 'PASS Docker live-restore is disabled'


install -d -o root -g root -m 755 "$DEPLOYMENT_ROOT"
install -d -o root -g root -m 700 \
  "$DEPLOYMENT_ROOT/runtime" \
  "$DEPLOYMENT_ROOT/runtime/data" \
  "$DEPLOYMENT_ROOT/runtime/wechat-home" \
  "$DEPLOYMENT_ROOT/secrets"
printf '%s\n' 'restart-no-test-token-must-not-be-printed' \
  > "$DEPLOYMENT_ROOT/secrets/auth-token"
chmod 600 "$DEPLOYMENT_ROOT/secrets/auth-token"

if ! docker network inspect cf-internal >/dev/null 2>&1; then
  docker network create cf-internal >/dev/null
  NETWORK_CREATED=1
fi

docker pull alpine:3.20 >/dev/null
docker pull nginx:1.27-alpine >/dev/null
ALPINE_DIGEST="$(docker image inspect alpine:3.20 \
  --format '{{index .RepoDigests 0}}')"
NGINX_DIGEST="$(docker image inspect nginx:1.27-alpine \
  --format '{{index .RepoDigests 0}}')"
case "$ALPINE_DIGEST" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) fail "could not resolve the digest-pinned normal-exit image" ;;
esac
case "$NGINX_DIGEST" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) fail "could not resolve the digest-pinned long-running image" ;;
esac

ENV_FILE="$(mktemp)"
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=cf-agent-wechat
AGENT_WECHAT_IMAGE=${ALPINE_DIGEST}
AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat-restart-no-service
CF_AGENT_WECHAT_STORAGE_ROOT=${DEPLOYMENT_ROOT}
CF_AGENT_WECHAT_RUNTIME_ROOT=${DEPLOYMENT_ROOT}/runtime
CF_AGENT_WECHAT_ARCHIVE_ROOT=${DEPLOYMENT_ROOT}/session-archive
AGENT_WECHAT_BIND_IP=127.0.0.1
AGENT_WECHAT_PORT=6174
EOF

compose() {
  timeout --signal=TERM --kill-after=5s 90s docker compose \
    --env-file "$ENV_FILE" \
    --project-directory "$REPO_ROOT" \
    -f "$COMPOSE_FILE" "$@"
}

set_compose_image() {
  local image="$1"

  sed -i "s|^AGENT_WECHAT_IMAGE=.*|AGENT_WECHAT_IMAGE=${image}|" "$ENV_FILE"
}

assert_stopped_without_restart() {
  local container="$1"
  local state restart_count restart_policy

  state="$(docker inspect --format '{{.State.Running}}' "$container")"
  restart_count="$(docker inspect --format '{{.RestartCount}}' "$container")"
  restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container")"
  [ "$state" = "false" ] || fail "$container unexpectedly restarted"
  [ "$restart_count" = "0" ] || fail "$container has a nonzero restart count"
  [ "$restart_policy" = "no" ] || fail "$container restart policy is not no"
}

rendered_restart="$(compose config --format json | python3 -c '
import json
import sys
print(json.load(sys.stdin)["services"]["agent-wechat"]["restart"])
')"
[ "$rendered_restart" = "no" ] || fail "rendered Compose restart policy is not no"
printf '%s\n' 'PASS rendered production Compose uses restart=no'

SERVICE_CONTAINER="cf-agent-wechat-restart-no-service"
CONTAINERS+=("$SERVICE_CONTAINER")
compose up -d --force-recreate --no-deps agent-wechat >/dev/null
[ "$(timeout 30s docker wait "$SERVICE_CONTAINER")" = "0" ] || \
  fail "normal-exit fixture did not exit zero"
sleep 2
assert_stopped_without_restart "$SERVICE_CONTAINER"
printf '%s\n' 'PASS normal container exit is not restarted'

compose rm --force --stop agent-wechat >/dev/null
set_compose_image "$NGINX_DIGEST"
compose up -d --force-recreate --no-deps agent-wechat >/dev/null
[ "$(docker inspect --format '{{.State.Running}}' "$SERVICE_CONTAINER")" = "true" ] || \
  fail "crash fixture did not start"
docker kill --signal KILL "$SERVICE_CONTAINER" >/dev/null
[ "$(timeout 30s docker wait "$SERVICE_CONTAINER")" = "137" ] || \
  fail "crash fixture did not exit after SIGKILL"
sleep 2
assert_stopped_without_restart "$SERVICE_CONTAINER"
printf '%s\n' 'PASS abnormal container exit is not restarted'

compose rm --force --stop agent-wechat >/dev/null
compose up -d --force-recreate --no-deps agent-wechat >/dev/null
[ "$(docker inspect --format '{{.State.Running}}' "$SERVICE_CONTAINER")" = "true" ] || \
  fail "daemon-restart fixture did not start"
[ "$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$SERVICE_CONTAINER")" = "no" ] || \
  fail "running fixture did not inherit restart=no"

timeout 60s systemctl restart docker
for _attempt in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
docker info >/dev/null 2>&1 || fail "Docker daemon did not return after restart"
assert_stopped_without_restart "$SERVICE_CONTAINER"
printf '%s\n' 'PASS Docker daemon restart does not restore agent-wechat'

if systemctl is-enabled --quiet cf-agent-wechat.service 2>/dev/null; then
  fail "a boot-enabled cf-agent-wechat service would violate the manual QR gate"
fi
timeout 60s systemctl restart docker
for _attempt in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
docker info >/dev/null 2>&1 || fail "Docker daemon did not return after second initialization"
assert_stopped_without_restart "$SERVICE_CONTAINER"
printf '%s\n' 'PASS boot-unit contract is disabled and a second daemon initialization leaves Agent stopped'

printf '%s\n' 'All real Docker restart=no lifecycle tests passed.'
