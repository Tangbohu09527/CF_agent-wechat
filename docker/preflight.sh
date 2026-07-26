#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MIN_FREE_KB=$((10 * 1024 * 1024))
PASS_COUNT=0
FAIL_COUNT=0
DOCKER_READY=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$1"
}

check_directory() {
  local name="$1"
  local path="$2"
  local current_uid="$3"
  local owner_uid mode

  if [ -L "$path" ]; then
    fail "$name path must not be a symbolic link: $path"
    return
  fi

  if [ ! -d "$path" ]; then
    fail "$name directory is missing: $path"
    return
  fi
  pass "$name directory exists: $path"

  if [ -r "$path" ] && [ -w "$path" ] && [ -x "$path" ]; then
    pass "$name directory is accessible to the current user"
  else
    fail "$name directory must be readable, writable, and searchable by the current user"
  fi

  if owner_uid="$(stat -c '%u' -- "$path" 2>/dev/null)" && [ "$owner_uid" = "$current_uid" ]; then
    pass "$name directory is owned by UID $current_uid"
  else
    fail "$name directory must be owned by UID $current_uid"
  fi

  if mode="$(stat -c '%a' -- "$path" 2>/dev/null)" && [ "$mode" = "700" ]; then
    pass "$name directory permissions are 700"
  else
    fail "$name directory permissions must be 700"
  fi
}

read_env_value() {
  local key="$1"
  local env_file="$2"

  awk -F= -v key="$key" '
    $0 ~ "^[[:space:]]*" key "=" {
      sub(/^[^=]*=/, "")
      value = $0
    }
    END { print value }
  ' "$env_file"
}

if command -v docker >/dev/null 2>&1; then
  if DOCKER_VERSION="$(docker --version 2>/dev/null)"; then
    pass "Docker CLI is installed: $DOCKER_VERSION"
  else
    fail "Docker CLI was found but its version could not be read"
  fi

  if docker info >/dev/null 2>&1; then
    pass "Docker daemon is reachable by the current user"
    DOCKER_READY=1
  else
    fail "Docker daemon is unavailable or the current user lacks permission"
  fi

  COMPOSE_VERSION="$(docker compose version 2>/dev/null || true)"
  if [[ "$COMPOSE_VERSION" =~ (^|[[:space:]])v?2\. ]]; then
    pass "Docker Compose v2 is available: $COMPOSE_VERSION"
  else
    fail "Docker Compose v2 is unavailable or its version could not be verified"
  fi
else
  fail "Docker CLI is not installed"
  fail "Docker daemon access cannot be checked without Docker CLI"
  fail "Docker Compose v2 cannot be checked without Docker CLI"
fi

CURRENT_UID="$(id -u 2>/dev/null || true)"
CURRENT_GID="$(id -g 2>/dev/null || true)"

if [[ "$CURRENT_UID" =~ ^[0-9]+$ ]]; then
  pass "Current user UID: $CURRENT_UID"
else
  fail "Current user UID could not be determined"
fi

if [[ "$CURRENT_GID" =~ ^[0-9]+$ ]]; then
  pass "Current user GID: $CURRENT_GID"
else
  fail "Current user GID could not be determined"
fi

if [ "$CURRENT_UID" = "0" ]; then
  fail "Do not run preflight as root; use the deployment user"
elif [ "$CURRENT_UID" = "1000" ]; then
  pass "Current UID matches the container wechat user (1000)"
else
  fail "Current UID must be 1000 unless bind-mount ownership is reviewed separately"
fi

check_directory "data" "$SCRIPT_DIR/data" "$CURRENT_UID"
check_directory "wechat-home" "$SCRIPT_DIR/wechat-home" "$CURRENT_UID"
check_directory "secrets" "$SCRIPT_DIR/secrets" "$CURRENT_UID"

TOKEN_FILE="$SCRIPT_DIR/secrets/auth-token"
if [ -L "$TOKEN_FILE" ]; then
  fail "auth-token must not be a symbolic link: $TOKEN_FILE"
elif [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
  pass "auth-token exists and is not empty"

  if [ -r "$TOKEN_FILE" ]; then
    pass "auth-token is readable by the current user"
  else
    fail "auth-token must be readable by the current user"
  fi

  TOKEN_OWNER_UID="$(stat -c '%u' -- "$TOKEN_FILE" 2>/dev/null || true)"
  if [ "$TOKEN_OWNER_UID" = "$CURRENT_UID" ]; then
    pass "auth-token is owned by UID $CURRENT_UID"
  else
    fail "auth-token must be owned by UID $CURRENT_UID"
  fi

  TOKEN_MODE="$(stat -c '%a' -- "$TOKEN_FILE" 2>/dev/null || true)"
  if [ "$TOKEN_MODE" = "600" ]; then
    pass "auth-token permissions are 600"
  else
    fail "auth-token permissions must be 600"
  fi

  TOKEN_LINE_COUNT="$(awk 'END { print NR }' "$TOKEN_FILE" 2>/dev/null || true)"
  if [ "$TOKEN_LINE_COUNT" = "1" ] && grep -Eq '^[[:xdigit:]]{64}$' "$TOKEN_FILE"; then
    pass "auth-token is a single 64-character hexadecimal value"
  else
    fail "auth-token must be generated with openssl rand -hex 32"
  fi
else
  fail "auth-token is missing or empty: $TOKEN_FILE"
fi

ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  pass ".env exists"

  IMAGE_REF="$(read_env_value AGENT_WECHAT_IMAGE "$ENV_FILE")"
  if [[ "$IMAGE_REF" =~ ^ghcr\.io/thisnick/agent-wechat@sha256:[0-9a-fA-F]{64}$ ]]; then
    pass "AGENT_WECHAT_IMAGE is pinned to a sha256 digest"
  else
    fail "AGENT_WECHAT_IMAGE must use a verified ghcr.io/thisnick/agent-wechat@sha256 digest"
  fi

  BIND_IP="$(read_env_value AGENT_WECHAT_BIND_IP "$ENV_FILE")"
  if [ "$BIND_IP" = "127.0.0.1" ]; then
    pass "AGENT_WECHAT_BIND_IP is restricted to 127.0.0.1"
  else
    fail "AGENT_WECHAT_BIND_IP must remain 127.0.0.1 for the V1 lab"
  fi

  HOST_PORT="$(read_env_value AGENT_WECHAT_PORT "$ENV_FILE")"
  if [ "$HOST_PORT" = "6174" ]; then
    pass "AGENT_WECHAT_PORT is 6174"
  else
    fail "AGENT_WECHAT_PORT must be 6174 for the V1 lab"
  fi

  PROXY_VALUE="$(read_env_value PROXY "$ENV_FILE")"
  if [ -z "$PROXY_VALUE" ]; then
    pass "PROXY is empty for the V1 lab"
  else
    fail "PROXY must remain empty because NET_ADMIN is not granted"
  fi
else
  fail ".env is missing: copy .env.example and replace the image digest placeholder"
fi

if command -v ss >/dev/null 2>&1; then
  if PORT_LISTENERS="$(ss -H -ltn 'sport = :6174' 2>/dev/null)"; then
    if [ -z "$PORT_LISTENERS" ]; then
      pass "TCP port 6174 is available"
    else
      fail "TCP port 6174 is already in use"
    fi
  else
    fail "TCP port 6174 could not be checked with ss"
  fi
else
  fail "TCP port 6174 cannot be checked because ss is unavailable"
fi

if [ "$DOCKER_READY" -eq 1 ]; then
  if RUNNING_CONTAINER_IDS="$(docker ps -q 2>/dev/null)"; then
    DOCKER_PORT_CONFLICT=0
    DOCKER_PORT_CHECK_FAILED=0
    HOST_PORT_PATTERN='"HostPort":"6174"'

    if [ -n "$RUNNING_CONTAINER_IDS" ]; then
      while IFS= read -r container_id; do
        if CONTAINER_PORTS="$(docker inspect --format '{{.Name}} {{json .HostConfig.PortBindings}}' "$container_id" 2>/dev/null)"; then
          if [[ "$CONTAINER_PORTS" == *"$HOST_PORT_PATTERN"* ]]; then
            CONTAINER_NAME="${CONTAINER_PORTS%% *}"
            fail "Running container ${CONTAINER_NAME#/} already publishes host port 6174"
            DOCKER_PORT_CONFLICT=1
          fi
        else
          fail "Published ports could not be inspected for container $container_id"
          DOCKER_PORT_CHECK_FAILED=1
        fi
      done <<< "$RUNNING_CONTAINER_IDS"
    fi

    if [ "$DOCKER_PORT_CONFLICT" -eq 0 ] && [ "$DOCKER_PORT_CHECK_FAILED" -eq 0 ]; then
      pass "No running Docker container publishes host port 6174"
    fi
  else
    fail "Running Docker containers could not be listed"
  fi
fi

check_disk_space() {
  local label="$1"
  local path="$2"
  local available_kb available_gib

  available_kb="$(LC_ALL=C df -Pk -- "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$available_kb" =~ ^[0-9]+$ ]]; then
    available_gib="$(awk -v kb="$available_kb" 'BEGIN { printf "%.1f", kb / 1048576 }')"
    if [ "$available_kb" -ge "$MIN_FREE_KB" ]; then
      pass "$label has ${available_gib} GiB available (minimum 10 GiB)"
    else
      fail "$label has ${available_gib} GiB available; at least 10 GiB is required"
    fi
  else
    fail "$label available disk space could not be determined"
  fi
}

check_disk_space "Deployment filesystem" "$SCRIPT_DIR"
check_disk_space "data filesystem" "$SCRIPT_DIR/data"
check_disk_space "wechat-home filesystem" "$SCRIPT_DIR/wechat-home"

if [ "$DOCKER_READY" -eq 1 ]; then
  DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [ -n "$DOCKER_ROOT" ] && [ -d "$DOCKER_ROOT" ]; then
    check_disk_space "Docker root filesystem" "$DOCKER_ROOT"
  else
    fail "Docker root directory could not be determined"
  fi
fi

printf '\n'
if [ "$FAIL_COUNT" -eq 0 ]; then
  printf '[PASS] Preflight completed successfully (%d checks)\n' "$PASS_COUNT"
  exit 0
fi

printf '[FAIL] Preflight found %d problem(s); %d check(s) passed\n' "$FAIL_COUNT" "$PASS_COUNT"
exit 1
