#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
BOOTSTRAP="${REPO_ROOT}/scripts/bootstrap-cfserver.sh"
REAL_STAT="$(command -v stat)"
REAL_INSTALL="$(command -v install)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cf-agent-wechat-bootstrap.XXXXXX")"

cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/cf-agent-wechat-bootstrap.*)
      rm -rf -- "$TEST_ROOT"
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

assert_contains() {
  local file="$1"
  local expected="$2"

  grep -Fq -- "$expected" "$file" || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,200p' "$file" >&2
    fail "missing expected output: $expected"
  }
}

if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  TEST_PYTHON=python3
elif command -v python >/dev/null 2>&1 && python -c 'import json' >/dev/null 2>&1; then
  TEST_PYTHON=python
else
  fail "Python 3 is required for the deployment test"
fi

APP_ROOT="${TEST_ROOT}/custom-agent-root"
GATEWAY_ROOT="${TEST_ROOT}/custom-gateway-root"
RUNTIME_ROOT="${TEST_ROOT}/custom-runtime-root"
ENV_FILE="${APP_ROOT}/docker/.env"
MOCK_BIN="${TEST_ROOT}/bin"
STATE_DIR="${TEST_ROOT}/state"
AUDIT_LOG="${TEST_ROOT}/audit.log"
IMAGE="registry.example/cf-agent-wechat@sha256:$(printf 'a%.0s' {1..64})"
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"

install -d -- "${APP_ROOT}/docker" "$GATEWAY_ROOT" "$MOCK_BIN" "$STATE_DIR"
install -m 644 -- "${REPO_ROOT}/docker/compose.cfserver.yaml" \
  "${APP_ROOT}/docker/compose.cfserver.yaml"
install -m 755 -- "${REPO_ROOT}/tests/helpers/mock_bootstrap_docker.sh" \
  "${MOCK_BIN}/docker"
install -m 755 -- "${REPO_ROOT}/tests/helpers/mock_bootstrap_curl.sh" \
  "${MOCK_BIN}/curl"
install -m 755 -- "${REPO_ROOT}/tests/helpers/mock_bootstrap_install.sh" \
  "${MOCK_BIN}/install"
install -m 755 -- "${REPO_ROOT}/tests/helpers/mock_bootstrap_chown.sh" \
  "${MOCK_BIN}/chown"
install -m 755 -- "${REPO_ROOT}/tests/helpers/mock_bootstrap_systemctl.sh" \
  "${MOCK_BIN}/systemctl"
: > "$AUDIT_LOG"

ACTIVE_APP_ROOT="$APP_ROOT"
ACTIVE_GATEWAY_ROOT="$GATEWAY_ROOT"
ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"
ACTIVE_IMAGE="$IMAGE"
TEST_DOCKER_UNAVAILABLE=0
TEST_COMPOSE_INVALID=0
TEST_RESTART_POLICY=unless-stopped
TEST_BAD_MOUNT=0
TEST_DATA_MOUNT_RW=true
TEST_HOME_MOUNT_RW=true
TEST_TOKEN_MOUNT_RW=false
TEST_NETWORK_ATTACHED=1
TEST_NETWORK_ALIAS_PRESENT=1
TEST_PORT_BINDING=""
TEST_CONTAINER_STATE=running
TEST_HEALTH=healthy
TEST_API_MODE=ready
TEST_AUTH_STATUS=logged_out
TEST_AUTH_SEQUENCE=""
PASS_RUNTIME_ROOT=1
PASS_AGENT_RUNTIME_ROOT=0
PASS_PERMISSION_SETTINGS=1
AGENT_RUNTIME_ROOT_VALUE=""
TEST_INSECURE_ENV_PARENT=0
TEST_INSECURE_COMPOSE_FILE=0
TEST_INSECURE_APP_ROOT=0
TEST_BAD_RUNTIME_METADATA=0
TEST_ENV_FILE_MODE=600
TEST_NETWORK_OVERRIDE=""
TEST_RUNTIME_MODE=700
TEST_SECRETS_UID="$CURRENT_UID"
TEST_SECRETS_GID="$CURRENT_GID"
TEST_BOOTSTRAP_TIMEOUT=1
TEST_HTTP_CONNECT_TIMEOUT=1
TEST_HTTP_TIMEOUT=1
TEST_SYSTEMD_STATE=running
TEST_DOCKER_SERVICE_ENABLEMENT=enabled

run_bootstrap() {
  local -a runtime_root_env=()
  local -a permission_env=()
  local -a contract_env=()
  local alias_value
  local effective_app_root="$ACTIVE_APP_ROOT"
  local effective_env_file="$ACTIVE_ENV_FILE"
  local bootstrap_status

  if [ "$ACTIVE_ENV_FILE" != "$ENV_FILE" ]; then
    effective_app_root="${ACTIVE_ENV_FILE}.repo"
    effective_env_file="${effective_app_root}/docker/.env"
    case "$effective_app_root" in
      "$TEST_ROOT"/*) ;;
      *) fail "unsafe scenario repository path: $effective_app_root" ;;
    esac
    rm -rf -- "$effective_app_root"
    install -d -- "${effective_app_root}/docker"
    install -m 644 -- "${REPO_ROOT}/docker/compose.cfserver.yaml" "${effective_app_root}/docker/compose.cfserver.yaml"
    if [ -e "$ACTIVE_ENV_FILE" ] || [ -L "$ACTIVE_ENV_FILE" ]; then
      cp -p -- "$ACTIVE_ENV_FILE" "$effective_env_file"
    fi
  fi


  if [ "$PASS_RUNTIME_ROOT" -eq 1 ]; then
    runtime_root_env+=("CF_RUNTIME_ROOT=$ACTIVE_RUNTIME_ROOT")
  fi
  if [ "$PASS_AGENT_RUNTIME_ROOT" -eq 1 ]; then
    alias_value="${AGENT_RUNTIME_ROOT_VALUE:-$ACTIVE_RUNTIME_ROOT}"
    runtime_root_env+=("CF_AGENT_WECHAT_RUNTIME_ROOT=$alias_value")
  fi
  if [ -n "$TEST_NETWORK_OVERRIDE" ]; then
    contract_env+=("CF_AGENT_WECHAT_NETWORK=$TEST_NETWORK_OVERRIDE")
  fi
  if [ "$PASS_PERMISSION_SETTINGS" -eq 1 ]; then
    permission_env+=(
      "CF_RUNTIME_UID=$CURRENT_UID"
      "CF_RUNTIME_GID=$CURRENT_GID"
      "CF_RUNTIME_MODE=$TEST_RUNTIME_MODE"
      "CF_STORAGE_UID=$CURRENT_UID"
      "CF_STORAGE_GID=$CURRENT_GID"
      "CF_SECRETS_UID=$TEST_SECRETS_UID"
      "CF_SECRETS_GID=$TEST_SECRETS_GID"
    )
  fi

  rm -f -- "${STATE_DIR}/auth-sequence-index"
  if env -u CF_RUNTIME_ROOT -u CF_AGENT_WECHAT_RUNTIME_ROOT \
    -u CF_RUNTIME_UID -u CF_RUNTIME_GID -u CF_RUNTIME_MODE \
    -u CF_STORAGE_UID -u CF_STORAGE_GID -u CF_SECRETS_UID -u CF_SECRETS_GID \
    -u CF_AGENT_WECHAT_NETWORK -u CF_AGENT_WECHAT_SERVICE_NAME \
    -u CF_AGENT_WECHAT_STORAGE_ROOT -u PROXY -u RUST_LOG -u COMPOSE_PROJECT_NAME \
    CF_AGENT_WECHAT_STORAGE_ROOT="${TEST_ROOT}/stale-caller-runtime" \
    PROXY="http://stale-proxy.invalid:8080" \
    RUST_LOG=trace \
    COMPOSE_PROJECT_NAME=stale-caller-project \
    PATH="${MOCK_BIN}:$PATH" \
    PYTHON_BIN="$TEST_PYTHON" \
    STAT_BIN="${REPO_ROOT}/tests/helpers/mock_bootstrap_stat.sh" \
    CF_AGENT_WECHAT_ROOT="$effective_app_root" \
    CF_GATEWAY_ROOT="$ACTIVE_GATEWAY_ROOT" \
    "${runtime_root_env[@]}" \
    "${permission_env[@]}" \
    "${contract_env[@]}" \
    CF_BOOTSTRAP_TIMEOUT="$TEST_BOOTSTRAP_TIMEOUT" \
    CF_BOOTSTRAP_POLL_INTERVAL=1 \
    CF_BOOTSTRAP_HTTP_CONNECT_TIMEOUT="$TEST_HTTP_CONNECT_TIMEOUT" \
    CF_BOOTSTRAP_HTTP_TIMEOUT="$TEST_HTTP_TIMEOUT" \
    AGENT_WECHAT_IMAGE="$ACTIVE_IMAGE" \
    CF_BOOTSTRAP_TEST_LOG="$AUDIT_LOG" \
    CF_BOOTSTRAP_TEST_STATE_DIR="$STATE_DIR" \
    CF_BOOTSTRAP_TEST_RUNTIME_ROOT="$ACTIVE_RUNTIME_ROOT" \
    CF_BOOTSTRAP_TEST_ENV_FILE="$effective_env_file" \
    CF_BOOTSTRAP_REAL_STAT="$REAL_STAT" \
    CF_BOOTSTRAP_TEST_RUNTIME_UID="$CURRENT_UID" \
    CF_BOOTSTRAP_TEST_RUNTIME_GID="$CURRENT_GID" \
    CF_BOOTSTRAP_TEST_RUNTIME_MODE="$TEST_RUNTIME_MODE" \
    CF_BOOTSTRAP_TEST_STORAGE_UID="$CURRENT_UID" \
    CF_BOOTSTRAP_TEST_STORAGE_GID="$CURRENT_GID" \
    CF_BOOTSTRAP_TEST_SECRETS_UID="$TEST_SECRETS_UID" \
    CF_BOOTSTRAP_TEST_SECRETS_GID="$TEST_SECRETS_GID" \
    CF_BOOTSTRAP_REAL_INSTALL="$REAL_INSTALL" \
    CF_BOOTSTRAP_TEST_INSECURE_ENV_PARENT="$TEST_INSECURE_ENV_PARENT" \
    CF_BOOTSTRAP_TEST_INSECURE_COMPOSE_FILE="$TEST_INSECURE_COMPOSE_FILE" \
    CF_BOOTSTRAP_TEST_INSECURE_APP_ROOT="$TEST_INSECURE_APP_ROOT" \
    CF_BOOTSTRAP_TEST_APP_ROOT="$effective_app_root" \
    CF_BOOTSTRAP_TEST_COMPOSE_FILE="${effective_app_root}/docker/compose.cfserver.yaml" \
    CF_BOOTSTRAP_TEST_BAD_RUNTIME_METADATA="$TEST_BAD_RUNTIME_METADATA" \
    CF_BOOTSTRAP_TEST_ENV_FILE_MODE="$TEST_ENV_FILE_MODE" \
    CF_BOOTSTRAP_TEST_DOCKER_UNAVAILABLE="$TEST_DOCKER_UNAVAILABLE" \
    CF_BOOTSTRAP_TEST_COMPOSE_INVALID="$TEST_COMPOSE_INVALID" \
    CF_BOOTSTRAP_TEST_RESTART_POLICY="$TEST_RESTART_POLICY" \
    CF_BOOTSTRAP_TEST_BAD_MOUNT="$TEST_BAD_MOUNT" \
    CF_BOOTSTRAP_TEST_DATA_MOUNT_RW="$TEST_DATA_MOUNT_RW" \
    CF_BOOTSTRAP_TEST_HOME_MOUNT_RW="$TEST_HOME_MOUNT_RW" \
    CF_BOOTSTRAP_TEST_TOKEN_MOUNT_RW="$TEST_TOKEN_MOUNT_RW" \
    CF_BOOTSTRAP_TEST_NETWORK_ATTACHED="$TEST_NETWORK_ATTACHED" \
    CF_BOOTSTRAP_TEST_NETWORK_ALIAS_PRESENT="$TEST_NETWORK_ALIAS_PRESENT" \
    CF_BOOTSTRAP_TEST_PORT_BINDING="$TEST_PORT_BINDING" \
    CF_BOOTSTRAP_TEST_CONTAINER_STATE="$TEST_CONTAINER_STATE" \
    CF_BOOTSTRAP_TEST_HEALTH="$TEST_HEALTH" \
    CF_BOOTSTRAP_TEST_API_MODE="$TEST_API_MODE" \
    CF_BOOTSTRAP_TEST_AUTH_STATUS="$TEST_AUTH_STATUS" \
    CF_BOOTSTRAP_TEST_AUTH_SEQUENCE="$TEST_AUTH_SEQUENCE" \
    CF_BOOTSTRAP_TEST_SYSTEMD_STATE="$TEST_SYSTEMD_STATE" \
    CF_BOOTSTRAP_TEST_DOCKER_SERVICE_ENABLEMENT="$TEST_DOCKER_SERVICE_ENABLEMENT" \
    /bin/bash "$BOOTSTRAP"; then
    bootstrap_status=0
  else
    bootstrap_status=$?
  fi
  if [ "$ACTIVE_ENV_FILE" != "$ENV_FILE" ] && [ -f "$effective_env_file" ]; then
    install -d -- "$(dirname -- "$ACTIVE_ENV_FILE")"
    cp -p -- "$effective_env_file" "$ACTIVE_ENV_FILE"
  fi
  return "$bootstrap_status"
}

write_env_fixture() {
  local target="$1"
  local root_key="$2"
  local root_value="$3"
  local bootstrapped="${4:-0}"

  install -d -- "$(dirname -- "$target")"
  {
    printf '%s\n' \
      "AGENT_WECHAT_IMAGE=$IMAGE" \
      'AGENT_WECHAT_BIND_IP=127.0.0.1' \
      'AGENT_WECHAT_PORT=6174' \
      'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat'
    if [ "$root_key" != "none" ]; then
      printf '%s=%s\n' "$root_key" "$root_value"
    fi
    printf '%s\n' 'PROXY=' 'RUST_LOG=info'
    if [ "$bootstrapped" -eq 1 ]; then
      printf '%s\n' 'CF_AGENT_WECHAT_BOOTSTRAPPED=1'
    fi
  } > "$target"
  chmod 600 "$target"
}

create_complete_runtime_fixture() {
  local runtime_root="$1"

  mkdir -p -- "${runtime_root}/data" "${runtime_root}/wechat-home" \
    "${runtime_root}/secrets"
  printf '%s\n' "$(printf 'd%.0s' {1..64})" > "${runtime_root}/secrets/auth-token"
}

AUDIT_LINES_BEFORE="$(wc -l < "$AUDIT_LOG")"
for dangerous_root in / //// "${TEST_ROOT}/danger/.."; do
  ACTIVE_RUNTIME_ROOT="$dangerous_root"
  ACTIVE_ENV_FILE="${TEST_ROOT}/danger-${dangerous_root//\//_}.env"
  DANGEROUS_OUTPUT="${TEST_ROOT}/danger-${dangerous_root//\//_}.out"
  if run_bootstrap > "$DANGEROUS_OUTPUT" 2>&1; then
    fail "bootstrap accepted dangerous runtime root: $dangerous_root"
  fi
  case "$dangerous_root" in
    *..)
      assert_contains "$DANGEROUS_OUTPUT" "must not contain a '..' path segment"
      ;;
    *)
      assert_contains "$DANGEROUS_OUTPUT" 'must not resolve to the filesystem root'
      ;;
  esac
  [ ! -e "$ACTIVE_ENV_FILE" ] || \
    fail "dangerous runtime root created an environment file: $dangerous_root"
done
[ "$(wc -l < "$AUDIT_LOG")" -eq "$AUDIT_LINES_BEFORE" ] || \
  fail "dangerous runtime root invoked Docker before rejection"
ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"
pass "filesystem root, pure-slash, and traversal runtime roots are rejected without state changes"

CONTROL_AUDIT_BEFORE="$(wc -l < "$AUDIT_LOG")"
CONTROL_INDEX=0
for control_root in \
  "${TEST_ROOT}/runtime-tab"$'\t'path \
  "${TEST_ROOT}/runtime-escape"$'\033'path \
  "${TEST_ROOT}/runtime-delete"$'\177'path; do
  CONTROL_INDEX=$((CONTROL_INDEX + 1))
  ACTIVE_RUNTIME_ROOT="$control_root"
  ACTIVE_ENV_FILE="${TEST_ROOT}/control-${CONTROL_INDEX}.env"
  CONTROL_OUTPUT="${TEST_ROOT}/control-${CONTROL_INDEX}.out"
  if run_bootstrap > "$CONTROL_OUTPUT" 2>&1; then
    fail "bootstrap accepted a control character in CF_RUNTIME_ROOT"
  fi
  assert_contains "$CONTROL_OUTPUT" 'must not contain control characters'
  [ ! -e "$control_root" ] || fail "control-character runtime root was created"
  [ ! -e "$ACTIVE_ENV_FILE" ] || fail "control-character root created an environment file"
done
[ "$(wc -l < "$AUDIT_LOG")" -eq "$CONTROL_AUDIT_BEFORE" ] || \
  fail "control-character runtime root invoked Docker before rejection"
ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"
pass "tab, escape, and delete characters in runtime roots are rejected before Docker"

DOTENV_AUDIT_BEFORE="$(wc -l < "$AUDIT_LOG")"
DOTENV_INDEX=0
for unsafe_root in \
  "${TEST_ROOT}/literal-\$USER" \
  "${TEST_ROOT}/space #fragment" \
  "${TEST_ROOT}/single'quote" \
  "${TEST_ROOT}/double\"quote" \
  "${TEST_ROOT}/has;semicolon" \
  "${TEST_ROOT}/back\\slash"; do
  DOTENV_INDEX=$((DOTENV_INDEX + 1))
  ACTIVE_RUNTIME_ROOT="$unsafe_root"
  ACTIVE_ENV_FILE="${TEST_ROOT}/dotenv-${DOTENV_INDEX}.env"
  DOTENV_OUTPUT="${TEST_ROOT}/dotenv-${DOTENV_INDEX}.out"
  if run_bootstrap > "$DOTENV_OUTPUT" 2>&1; then
    fail "bootstrap accepted a dotenv-unsafe CF_RUNTIME_ROOT"
  fi
  assert_contains "$DOTENV_OUTPUT" 'must use only dotenv-safe ASCII absolute path characters'
  [ ! -e "$unsafe_root" ] || fail "dotenv-unsafe runtime root was created"
  [ ! -e "$ACTIVE_ENV_FILE" ] || \
    fail "dotenv-unsafe runtime root created an environment file"
done
[ "$(wc -l < "$AUDIT_LOG")" -eq "$DOTENV_AUDIT_BEFORE" ] || \
  fail "dotenv-unsafe runtime root invoked Docker before rejection"
ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"
pass "dollar, whitespace/hash, quotes, semicolon, and backslash are rejected in runtime roots"

INSECURE_APP_RUNTIME="${TEST_ROOT}/insecure-app-runtime"
INSECURE_APP_ENV="${TEST_ROOT}/insecure-app.env"
ACTIVE_RUNTIME_ROOT="$INSECURE_APP_RUNTIME"
ACTIVE_ENV_FILE="$INSECURE_APP_ENV"
TEST_INSECURE_APP_ROOT=1
INSECURE_APP_AUDIT_BEFORE="$(wc -l < "$AUDIT_LOG")"
INSECURE_APP_OUTPUT="${TEST_ROOT}/insecure-app.out"
if run_bootstrap > "$INSECURE_APP_OUTPUT" 2>&1; then
  fail "bootstrap accepted a group/other-writable application root"
fi
assert_contains "$INSECURE_APP_OUTPUT" 'CF_AGENT_WECHAT_ROOT must not be group/other writable'
[ ! -e "$INSECURE_APP_ENV" ] && [ ! -e "$INSECURE_APP_RUNTIME" ] || \
  fail "insecure application root rejection mutated deployment state"
[ "$(wc -l < "$AUDIT_LOG")" -eq "$INSECURE_APP_AUDIT_BEFORE" ] || \
  fail "insecure application root invoked Docker before rejection"
TEST_INSECURE_APP_ROOT=0
pass "group/other-writable application root is rejected before state changes"

INSECURE_COMPOSE_RUNTIME="${TEST_ROOT}/insecure-compose-runtime"
INSECURE_COMPOSE_ENV="${TEST_ROOT}/insecure-compose.env"
ACTIVE_RUNTIME_ROOT="$INSECURE_COMPOSE_RUNTIME"
ACTIVE_ENV_FILE="$INSECURE_COMPOSE_ENV"
TEST_INSECURE_COMPOSE_FILE=1
INSECURE_COMPOSE_AUDIT_BEFORE="$(wc -l < "$AUDIT_LOG")"
INSECURE_COMPOSE_OUTPUT="${TEST_ROOT}/insecure-compose.out"
if run_bootstrap > "$INSECURE_COMPOSE_OUTPUT" 2>&1; then
  fail "bootstrap accepted a group/other-writable Compose file"
fi
assert_contains "$INSECURE_COMPOSE_OUTPUT" 'production Compose file must not be group/other writable'
[ ! -e "$INSECURE_COMPOSE_ENV" ] && [ ! -e "$INSECURE_COMPOSE_RUNTIME" ] || \
  fail "insecure Compose rejection mutated deployment state"
[ "$(wc -l < "$AUDIT_LOG")" -eq "$INSECURE_COMPOSE_AUDIT_BEFORE" ] || \
  fail "insecure Compose file invoked Docker before rejection"
TEST_INSECURE_COMPOSE_FILE=0
pass "group/other-writable Compose file is rejected before state changes"

INVALID_MODE_RUNTIME="${TEST_ROOT}/invalid-mode-runtime"
INVALID_MODE_ENV="${TEST_ROOT}/invalid-mode.env"
ACTIVE_RUNTIME_ROOT="$INVALID_MODE_RUNTIME"
ACTIVE_ENV_FILE="$INVALID_MODE_ENV"
TEST_RUNTIME_MODE=750
INVALID_MODE_OUTPUT="${TEST_ROOT}/invalid-mode.out"
if run_bootstrap > "$INVALID_MODE_OUTPUT" 2>&1; then
  fail "bootstrap accepted CF_RUNTIME_MODE other than 700"
fi
assert_contains "$INVALID_MODE_OUTPUT" 'CF_RUNTIME_MODE must be 700'
[ ! -e "$INVALID_MODE_ENV" ] && [ ! -e "$INVALID_MODE_RUNTIME" ] || \
  fail "invalid runtime mode was persisted"
TEST_RUNTIME_MODE=700
pass "production runtime mode contract is validated before persistence"

INVALID_SECRETS_RUNTIME="${TEST_ROOT}/invalid-secrets-runtime"
INVALID_SECRETS_ENV="${TEST_ROOT}/invalid-secrets.env"
ACTIVE_RUNTIME_ROOT="$INVALID_SECRETS_RUNTIME"
ACTIVE_ENV_FILE="$INVALID_SECRETS_ENV"
TEST_SECRETS_UID=$((CURRENT_UID + 1))
INVALID_SECRETS_OUTPUT="${TEST_ROOT}/invalid-secrets.out"
if run_bootstrap > "$INVALID_SECRETS_OUTPUT" 2>&1; then
  fail "bootstrap accepted a custom runtime with an unreachable secrets owner"
fi
assert_contains "$INVALID_SECRETS_OUTPUT" 'custom runtime requires CF_SECRETS_UID to match'
[ ! -e "$INVALID_SECRETS_ENV" ] && [ ! -e "$INVALID_SECRETS_RUNTIME" ] || \
  fail "invalid custom secrets ownership was persisted"
TEST_SECRETS_UID="$CURRENT_UID"
pass "custom runtime secrets owner contract is validated before persistence"

DEFAULT_CONTRACT_ENV="${TEST_ROOT}/default-contract.env"
ACTIVE_RUNTIME_ROOT=/srv/storage/cf-agent-wechat
ACTIVE_ENV_FILE="$DEFAULT_CONTRACT_ENV"
PASS_RUNTIME_ROOT=0
TEST_SECRETS_UID=1
TEST_SECRETS_GID=1
DEFAULT_CONTRACT_OUTPUT="${TEST_ROOT}/default-contract.out"
if run_bootstrap > "$DEFAULT_CONTRACT_OUTPUT" 2>&1; then
  fail "bootstrap accepted non-root secrets ownership for the default runtime"
fi
assert_contains "$DEFAULT_CONTRACT_OUTPUT" 'default runtime requires CF_SECRETS_UID=0 and CF_SECRETS_GID=0'
[ ! -e "$DEFAULT_CONTRACT_ENV" ] || fail "invalid default ownership created an environment file"
PASS_RUNTIME_ROOT=1
TEST_SECRETS_UID="$CURRENT_UID"
TEST_SECRETS_GID="$CURRENT_GID"
pass "default runtime root enforces root-owned management secrets"

for enablement in enabled-runtime disabled; do
  RECOVERY_RUNTIME="${TEST_ROOT}/recovery-${enablement}-runtime"
  RECOVERY_ENV="${TEST_ROOT}/recovery-${enablement}.env"
  ACTIVE_RUNTIME_ROOT="$RECOVERY_RUNTIME"
  ACTIVE_ENV_FILE="$RECOVERY_ENV"
  TEST_DOCKER_SERVICE_ENABLEMENT="$enablement"
  RECOVERY_OUTPUT="${TEST_ROOT}/recovery-${enablement}.out"
  if run_bootstrap > "$RECOVERY_OUTPUT" 2>&1; then
    fail "bootstrap accepted non-persistent docker.service state: $enablement"
  fi
  assert_contains "$RECOVERY_OUTPUT" "docker.service is not enabled for boot recovery (state: $enablement)"
  [ ! -e "$RECOVERY_ENV" ] && [ ! -e "$RECOVERY_RUNTIME" ] || \
    fail "docker.service $enablement failure mutated deployment state"
done
TEST_DOCKER_SERVICE_ENABLEMENT=enabled
pass "transient and disabled Docker service states fail before deployment mutation"

ORPHAN_RUNTIME="${TEST_ROOT}/orphan-runtime"
ORPHAN_ENV="${TEST_ROOT}/orphan.env"
mkdir -p -- "${ORPHAN_RUNTIME}/data" "${ORPHAN_RUNTIME}/secrets"
printf '%s\n' "$(printf 'c%.0s' {1..64})" > "${ORPHAN_RUNTIME}/secrets/auth-token"
ACTIVE_RUNTIME_ROOT="$ORPHAN_RUNTIME"
ACTIVE_ENV_FILE="$ORPHAN_ENV"
ORPHAN_AUDIT_BEFORE="$(wc -l < "$AUDIT_LOG")"
ORPHAN_OUTPUT="${TEST_ROOT}/orphan.out"
if run_bootstrap > "$ORPHAN_OUTPUT" 2>&1; then
  fail "bootstrap accepted runtime state without its environment file"
fi
assert_contains "$ORPHAN_OUTPUT" 'docker/.env is absent but persistent runtime state already exists'
[ ! -e "$ORPHAN_ENV" ] || fail "orphan runtime rejection created an environment file"
[ ! -e "${ORPHAN_RUNTIME}/wechat-home" ] || fail "orphan runtime rejection filled a missing component"
grep -Eq '^[c]{64}$' "${ORPHAN_RUNTIME}/secrets/auth-token" || \
  fail "orphan runtime rejection changed the auth token"
[ "$(wc -l < "$AUDIT_LOG")" -eq "$ORPHAN_AUDIT_BEFORE" ] || \
  fail "orphan runtime invoked Docker before rejection"
pass "partial runtime without its paired environment file is rejected unchanged"

ORPHAN_COMPLETE_RUNTIME="${TEST_ROOT}/orphan-complete-runtime"
ORPHAN_COMPLETE_ENV="${TEST_ROOT}/orphan-complete.env"
create_complete_runtime_fixture "$ORPHAN_COMPLETE_RUNTIME"
ACTIVE_RUNTIME_ROOT="$ORPHAN_COMPLETE_RUNTIME"
ACTIVE_ENV_FILE="$ORPHAN_COMPLETE_ENV"
ORPHAN_COMPLETE_OUTPUT="${TEST_ROOT}/orphan-complete.out"
if run_bootstrap > "$ORPHAN_COMPLETE_OUTPUT" 2>&1; then
  fail "bootstrap silently adopted a complete runtime without its environment file"
fi
assert_contains "$ORPHAN_COMPLETE_OUTPUT" 'restore the matching environment file or select a fresh empty CF_RUNTIME_ROOT'
[ ! -e "$ORPHAN_COMPLETE_ENV" ] || fail "complete orphan runtime created an environment file"
pass "complete runtime also requires its paired authoritative environment file"

ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"

INSECURE_RUNTIME="${TEST_ROOT}/insecure-env-runtime"
INSECURE_ENV="${APP_ROOT}/docker/insecure.env"
ACTIVE_RUNTIME_ROOT="$INSECURE_RUNTIME"
ACTIVE_ENV_FILE="$INSECURE_ENV"
TEST_INSECURE_ENV_PARENT=1
INSECURE_AUDIT_BEFORE="$(wc -l < "$AUDIT_LOG")"
INSECURE_OUTPUT="${TEST_ROOT}/insecure-env.out"
if run_bootstrap > "$INSECURE_OUTPUT" 2>&1; then
  fail "bootstrap accepted a group/other-writable environment parent"
fi
assert_contains "$INSECURE_OUTPUT" 'parent directory must not be group/other writable'
[ ! -e "$INSECURE_ENV" ] && [ ! -e "$INSECURE_RUNTIME" ] || \
  fail "insecure environment parent rejection mutated state"
[ "$(wc -l < "$AUDIT_LOG")" -eq "$INSECURE_AUDIT_BEFORE" ] || \
  fail "insecure environment parent invoked Docker before rejection"
TEST_INSECURE_ENV_PARENT=0
ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"
pass "insecure environment parent is rejected before state changes"

PUBLIC_ENV_RUNTIME="${TEST_ROOT}/public-env-runtime"
PUBLIC_ENV="${TEST_ROOT}/public.env"
write_env_fixture "$PUBLIC_ENV" CF_AGENT_WECHAT_RUNTIME_ROOT "$PUBLIC_ENV_RUNTIME"
ACTIVE_RUNTIME_ROOT="$PUBLIC_ENV_RUNTIME"
ACTIVE_ENV_FILE="$PUBLIC_ENV"
TEST_ENV_FILE_MODE=644
PUBLIC_ENV_BEFORE="$(<"$PUBLIC_ENV")"
PUBLIC_ENV_OUTPUT="${TEST_ROOT}/public-env.out"
if run_bootstrap > "$PUBLIC_ENV_OUTPUT" 2>&1; then
  fail "bootstrap accepted a world-readable production environment file"
fi
assert_contains "$PUBLIC_ENV_OUTPUT" 'environment file must have mode 600 or 640'
[ "$(<"$PUBLIC_ENV")" = "$PUBLIC_ENV_BEFORE" ] || \
  fail "unsafe environment mode rejection mutated the environment file"
[ ! -e "$PUBLIC_ENV_RUNTIME" ] || \
  fail "unsafe environment mode rejection created runtime state"
TEST_ENV_FILE_MODE=600
ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"
pass "environment mode 0644 is rejected before runtime mutation"

CONTRACT_AUDIT_BEFORE="$(wc -l < "$AUDIT_LOG")"
ACTIVE_ENV_FILE="${TEST_ROOT}/contract.env"
TEST_NETWORK_OVERRIDE=other-network
NETWORK_OUTPUT="${TEST_ROOT}/network-override.out"
if run_bootstrap > "$NETWORK_OUTPUT" 2>&1; then
  fail "bootstrap accepted a network override that Compose cannot honor"
fi
assert_contains "$NETWORK_OUTPUT" 'cannot override the production Compose network cf-internal'
[ ! -e "$ACTIVE_ENV_FILE" ] || fail "network override created an environment file"
[ "$(wc -l < "$AUDIT_LOG")" -eq "$CONTRACT_AUDIT_BEFORE" ] || \
  fail "network override invoked Docker before rejection"
TEST_NETWORK_OVERRIDE=""
pass "unsupported production network override is rejected before state changes"

PASS_AGENT_RUNTIME_ROOT=1
AGENT_RUNTIME_ROOT_VALUE="${TEST_ROOT}/different-alias-root"
ALIAS_OUTPUT="${TEST_ROOT}/runtime-alias.out"
if run_bootstrap > "$ALIAS_OUTPUT" 2>&1; then
  fail "bootstrap accepted conflicting runtime root aliases"
fi
assert_contains "$ALIAS_OUTPUT" 'must identify the same directory'
[ ! -e "$ACTIVE_ENV_FILE" ] || fail "runtime alias conflict created an environment file"
[ "$(wc -l < "$AUDIT_LOG")" -eq "$CONTRACT_AUDIT_BEFORE" ] || \
  fail "runtime alias conflict invoked Docker before rejection"
PASS_AGENT_RUNTIME_ROOT=0
AGENT_RUNTIME_ROOT_VALUE=""
ACTIVE_ENV_FILE="$ENV_FILE"
pass "conflicting runtime root aliases are rejected before state changes"

FIRST_OUTPUT="${TEST_ROOT}/first.out"
run_bootstrap > "$FIRST_OUTPUT" 2>&1 || {
  sed -n '1,240p' "$FIRST_OUTPUT" >&2
  fail "first bootstrap failed"
}
assert_contains "$FIRST_OUTPUT" 'Gateway root validated:'
assert_contains "$FIRST_OUTPUT" 'created Docker network: cf-internal'
assert_contains "$FIRST_OUTPUT" 'container restart policy is unless-stopped'
assert_contains "$FIRST_OUTPUT" 'persistent mounts, network attachment, and loopback port binding are correct'
assert_contains "$FIRST_OUTPUT" 'authenticated API is ready (auth status: logged_out)'
assert_contains "$FIRST_OUTPUT" "application root: $APP_ROOT"
assert_contains "$FIRST_OUTPUT" "gateway root: $GATEWAY_ROOT"
assert_contains "$FIRST_OUTPUT" "persistent runtime root: $RUNTIME_ROOT"

[ -d "${RUNTIME_ROOT}/data" ] || fail "data directory was not created"
[ -d "${RUNTIME_ROOT}/wechat-home" ] || fail "wechat-home directory was not created"
[ -f "${RUNTIME_ROOT}/secrets/auth-token" ] || fail "auth token was not created"
[ -f "$ENV_FILE" ] || fail "environment file was not created"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    [ "$($REAL_STAT -c '%a' "$ENV_FILE")" = "600" ] || \
      fail "fresh environment file was not created with mode 0600"
    ;;
esac
grep -Fxq "AGENT_WECHAT_IMAGE=$IMAGE" "$ENV_FILE" || fail "image was not written to env file"
grep -Fxq 'AGENT_WECHAT_BIND_IP=127.0.0.1' "$ENV_FILE" || fail "secure bind default is missing"
grep -Fxq 'AGENT_WECHAT_PORT=6174' "$ENV_FILE" || fail "port default is missing"
grep -Fxq 'AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat' "$ENV_FILE" || \
  fail "container default is missing"
grep -Fxq "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" "$ENV_FILE" || \
  fail "custom runtime root was not persisted to the environment file"
grep -Fxq 'CF_AGENT_WECHAT_BOOTSTRAPPED=1' "$ENV_FILE" || \
  fail "successful bootstrap did not persist its completion sentinel"
grep -Fxq 'CF_AGENT_WECHAT_BOOTSTRAP_MANAGED=1' "$ENV_FILE" || \
  fail "fresh environment does not record bootstrap provenance"
for setting in \
  "CF_RUNTIME_UID=$CURRENT_UID" "CF_RUNTIME_GID=$CURRENT_GID" \
  'CF_RUNTIME_MODE=700' "CF_STORAGE_UID=$CURRENT_UID" \
  "CF_STORAGE_GID=$CURRENT_GID" "CF_SECRETS_UID=$CURRENT_UID" \
  "CF_SECRETS_GID=$CURRENT_GID"; do
  grep -Fxq "$setting" "$ENV_FILE" || fail "missing persisted setting: $setting"
done
[ "$(awk 'END { print NR }' "${RUNTIME_ROOT}/secrets/auth-token")" = "1" ] || \
  fail "generated token does not contain exactly one line"
grep -Eq '^[0-9a-f]{64}$' "${RUNTIME_ROOT}/secrets/auth-token" || \
  fail "generated token has an invalid format"
assert_contains "$AUDIT_LOG" "runtime=$RUNTIME_ROOT"
assert_contains "$AUDIT_LOG" $'--project-directory\t'"$APP_ROOT"
assert_contains "$AUDIT_LOG" $'--project-name\tcf-agent-wechat'
assert_contains "$AUDIT_LOG" $'docker\tcompose\t--env-file'
COMPOSE_ENV_AUDIT="$(grep -F $'docker\tcompose\t--env-file' "$AUDIT_LOG" | head -n 1)"
case "$COMPOSE_ENV_AUDIT" in
  *$'\tlegacy=unset\tproxy=unset\trust_log=unset\tproject_env=unset') ;;
  *)
    printf '%s\n' "$COMPOSE_ENV_AUDIT" >&2
    fail "caller environment leaked into the production Compose invocation"
    ;;
esac
assert_contains "$FIRST_OUTPUT" 'docker.service is persistently enabled for boot recovery'
pass "first-run roots, directories, token, network, startup, mounts, and API checks"

printf '%s\n' 'persisted-session-fixture' > "${RUNTIME_ROOT}/data/session.marker"
TOKEN_ID_BEFORE="$($REAL_STAT -c '%i:%Y:%s' "${RUNTIME_ROOT}/secrets/auth-token")"
SECOND_OUTPUT="${TEST_ROOT}/second.out"
PASS_RUNTIME_ROOT=0
PASS_PERMISSION_SETTINGS=0
run_bootstrap > "$SECOND_OUTPUT" 2>&1 || {
  sed -n '1,240p' "$SECOND_OUTPUT" >&2
  fail "second bootstrap failed"
}
PASS_RUNTIME_ROOT=1
PASS_PERMISSION_SETTINGS=1
TOKEN_ID_AFTER="$($REAL_STAT -c '%i:%Y:%s' "${RUNTIME_ROOT}/secrets/auth-token")"
[ "$TOKEN_ID_BEFORE" = "$TOKEN_ID_AFTER" ] || fail "second bootstrap replaced the auth token"
grep -Fxq 'persisted-session-fixture' "${RUNTIME_ROOT}/data/session.marker" || \
  fail "second bootstrap replaced the runtime"
[ "$(grep -Fc $'docker\tnetwork\tcreate' "$AUDIT_LOG")" -eq 1 ] || \
  fail "second bootstrap recreated the existing Docker network"
for unique_key in CF_AGENT_WECHAT_RUNTIME_ROOT CF_AGENT_WECHAT_BOOTSTRAP_MANAGED CF_AGENT_WECHAT_BOOTSTRAPPED CF_RUNTIME_UID CF_RUNTIME_GID CF_RUNTIME_MODE CF_STORAGE_UID CF_STORAGE_GID CF_SECRETS_UID CF_SECRETS_GID; do
  [ "$(grep -Ec "^[[:space:]]*${unique_key}=" "$ENV_FILE")" -eq 1 ] || \
    fail "rerun duplicated $unique_key"
done
assert_contains "$SECOND_OUTPUT" "persistent runtime root: $RUNTIME_ROOT"
assert_contains "$SECOND_OUTPUT" 'Docker network exists: cf-internal'
pass "second run loads persisted root/ownership and preserves token/session without bootstrap variables"

MISMATCH_OUTPUT="${TEST_ROOT}/env-mismatch.out"
ACTIVE_IMAGE="registry.example/other@sha256:$(printf 'b%.0s' {1..64})"
if run_bootstrap > "$MISMATCH_OUTPUT" 2>&1; then
  fail "bootstrap accepted an environment override that differed from .env"
fi
assert_contains "$MISMATCH_OUTPUT" 'differs from the authoritative environment file'
ACTIVE_IMAGE="$IMAGE"
pass "existing environment file is authoritative"

DUPLICATE_RUNTIME="${TEST_ROOT}/duplicate-runtime"
DUPLICATE_ENV="${TEST_ROOT}/duplicate.env"
write_env_fixture "$DUPLICATE_ENV" CF_AGENT_WECHAT_RUNTIME_ROOT "$DUPLICATE_RUNTIME"
printf '%s\n' "AGENT_WECHAT_IMAGE=$IMAGE" >> "$DUPLICATE_ENV"
ACTIVE_RUNTIME_ROOT="$DUPLICATE_RUNTIME"
ACTIVE_ENV_FILE="$DUPLICATE_ENV"
DUPLICATE_ENV_BEFORE="$(<"$DUPLICATE_ENV")"
DUPLICATE_OUTPUT="${TEST_ROOT}/duplicate.out"
if run_bootstrap > "$DUPLICATE_OUTPUT" 2>&1; then
  fail "bootstrap accepted a duplicate authoritative image assignment"
fi
assert_contains "$DUPLICATE_OUTPUT" 'duplicate AGENT_WECHAT_IMAGE assignments'
[ "$(<"$DUPLICATE_ENV")" = "$DUPLICATE_ENV_BEFORE" ] || \
  fail "duplicate-key rejection mutated the environment file"
[ ! -e "$DUPLICATE_RUNTIME" ] || fail "duplicate-key rejection created runtime state"
pass "duplicate authoritative Compose assignments are rejected"

TRACE_RUNTIME="${TEST_ROOT}/trace-runtime"
TRACE_ENV="${TEST_ROOT}/trace.env"
write_env_fixture "$TRACE_ENV" CF_AGENT_WECHAT_RUNTIME_ROOT "$TRACE_RUNTIME"
sed -i 's/^RUST_LOG=info$/RUST_LOG=trace/' "$TRACE_ENV"
ACTIVE_RUNTIME_ROOT="$TRACE_RUNTIME"
ACTIVE_ENV_FILE="$TRACE_ENV"
TRACE_ENV_BEFORE="$(<"$TRACE_ENV")"
TRACE_OUTPUT="${TEST_ROOT}/trace.out"
if run_bootstrap > "$TRACE_OUTPUT" 2>&1; then
  fail "bootstrap accepted a verbose production Rust log level"
fi
assert_contains "$TRACE_OUTPUT" 'RUST_LOG must be error, warn, or info for production'
[ "$(<"$TRACE_ENV")" = "$TRACE_ENV_BEFORE" ] || \
  fail "RUST_LOG rejection mutated the environment file"
[ ! -e "$TRACE_RUNTIME" ] || fail "RUST_LOG rejection created runtime state"
ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"
pass "debug and trace Rust logging are rejected in production"

MISSING_DOCKER_RUNTIME="${TEST_ROOT}/missing-docker-runtime"
MISSING_DOCKER_ENV="${TEST_ROOT}/missing-docker.env"
ACTIVE_RUNTIME_ROOT="$MISSING_DOCKER_RUNTIME"
ACTIVE_ENV_FILE="$MISSING_DOCKER_ENV"
TEST_DOCKER_UNAVAILABLE=1
MISSING_DOCKER_OUTPUT="${TEST_ROOT}/missing-docker.out"
if run_bootstrap > "$MISSING_DOCKER_OUTPUT" 2>&1; then
  fail "bootstrap accepted an unavailable Docker CLI"
fi
assert_contains "$MISSING_DOCKER_OUTPUT" 'Docker CLI is unavailable'
[ ! -e "$MISSING_DOCKER_RUNTIME" ] || fail "Docker failure created a runtime"
[ ! -e "$MISSING_DOCKER_ENV" ] || fail "Docker failure created an environment file"
TEST_DOCKER_UNAVAILABLE=0
pass "Docker failure leaves no environment, runtime, or token state"

MISSING_TOKEN_RUNTIME="${TEST_ROOT}/missing-token-runtime"
MISSING_TOKEN_ENV="${TEST_ROOT}/missing-token.env"
install -d -- "${MISSING_TOKEN_RUNTIME}/data"
write_env_fixture "$MISSING_TOKEN_ENV" CF_AGENT_WECHAT_RUNTIME_ROOT "$MISSING_TOKEN_RUNTIME"
ACTIVE_RUNTIME_ROOT="$MISSING_TOKEN_RUNTIME"
ACTIVE_ENV_FILE="$MISSING_TOKEN_ENV"
MISSING_TOKEN_ENV_BEFORE="$(<"$MISSING_TOKEN_ENV")"
MISSING_TOKEN_OUTPUT="${TEST_ROOT}/missing-token.out"
if run_bootstrap > "$MISSING_TOKEN_OUTPUT" 2>&1; then
  fail "bootstrap generated a replacement token for existing runtime data"
fi
assert_contains "$MISSING_TOKEN_OUTPUT" 'restore the original token instead of generating a replacement'
[ "$(<"$MISSING_TOKEN_ENV")" = "$MISSING_TOKEN_ENV_BEFORE" ] || \
  fail "missing-token rejection mutated the environment file"
[ ! -e "${MISSING_TOKEN_RUNTIME}/secrets/auth-token" ] || \
  fail "bootstrap created a replacement token for existing runtime data"
[ ! -e "${MISSING_TOKEN_RUNTIME}/secrets" ] || \
  fail "missing-token rejection created a secrets directory"
pass "existing data without its token is rejected"

LEGACY_MISSING_RUNTIME="${TEST_ROOT}/legacy-missing-runtime"
LEGACY_MISSING_ENV="${TEST_ROOT}/legacy-missing.env"
write_env_fixture "$LEGACY_MISSING_ENV" CF_AGENT_WECHAT_STORAGE_ROOT \
  "$LEGACY_MISSING_RUNTIME"
ACTIVE_RUNTIME_ROOT="$LEGACY_MISSING_RUNTIME"
ACTIVE_ENV_FILE="$LEGACY_MISSING_ENV"
PASS_RUNTIME_ROOT=0
LEGACY_MISSING_ENV_BEFORE="$(<"$LEGACY_MISSING_ENV")"
LEGACY_MISSING_OUTPUT="${TEST_ROOT}/legacy-missing.out"
if run_bootstrap > "$LEGACY_MISSING_OUTPUT" 2>&1; then
  fail "bootstrap accepted a legacy environment whose persistent runtime disappeared"
fi
PASS_RUNTIME_ROOT=1
assert_contains "$LEGACY_MISSING_OUTPUT" 'no bootstrap provenance and its runtime is incomplete'
[ ! -e "$LEGACY_MISSING_RUNTIME" ] || \
  fail "bootstrap created an empty runtime for an ambiguous legacy environment"
[ "$(<"$LEGACY_MISSING_ENV")" = "$LEGACY_MISSING_ENV_BEFORE" ] || \
  fail "ambiguous legacy runtime rejection mutated its environment"
pass "legacy environment with a missing runtime is rejected before migration"

LEGACY_PARTIAL_RUNTIME="${TEST_ROOT}/legacy-partial-runtime"
LEGACY_PARTIAL_ENV="${TEST_ROOT}/legacy-partial.env"
mkdir -p -- "${LEGACY_PARTIAL_RUNTIME}/data" "${LEGACY_PARTIAL_RUNTIME}/secrets"
printf '%s\n' "$(printf 'f%.0s' {1..64})" > \
  "${LEGACY_PARTIAL_RUNTIME}/secrets/auth-token"
write_env_fixture "$LEGACY_PARTIAL_ENV" CF_AGENT_WECHAT_STORAGE_ROOT \
  "$LEGACY_PARTIAL_RUNTIME"
ACTIVE_RUNTIME_ROOT="$LEGACY_PARTIAL_RUNTIME"
ACTIVE_ENV_FILE="$LEGACY_PARTIAL_ENV"
PASS_RUNTIME_ROOT=0
LEGACY_PARTIAL_ENV_BEFORE="$(<"$LEGACY_PARTIAL_ENV")"
LEGACY_PARTIAL_OUTPUT="${TEST_ROOT}/legacy-partial.out"
if run_bootstrap > "$LEGACY_PARTIAL_OUTPUT" 2>&1; then
  fail "bootstrap accepted a partially restored unmanaged legacy runtime"
fi
PASS_RUNTIME_ROOT=1
assert_contains "$LEGACY_PARTIAL_OUTPUT" 'no bootstrap provenance and its runtime is incomplete'
[ ! -e "${LEGACY_PARTIAL_RUNTIME}/wechat-home" ] || \
  fail "bootstrap filled a missing unmanaged legacy runtime component"
[ "$(<"$LEGACY_PARTIAL_ENV")" = "$LEGACY_PARTIAL_ENV_BEFORE" ] || \
  fail "partial unmanaged legacy runtime mutated its environment file"
pass "partial unmanaged legacy runtime is rejected before migration"

LEGACY_METADATA_RUNTIME="${TEST_ROOT}/legacy-metadata-runtime"
LEGACY_METADATA_ENV="${TEST_ROOT}/legacy-metadata.env"
create_complete_runtime_fixture "$LEGACY_METADATA_RUNTIME"
write_env_fixture "$LEGACY_METADATA_ENV" CF_AGENT_WECHAT_STORAGE_ROOT \
  "$LEGACY_METADATA_RUNTIME"
ACTIVE_RUNTIME_ROOT="$LEGACY_METADATA_RUNTIME"
ACTIVE_ENV_FILE="$LEGACY_METADATA_ENV"
PASS_RUNTIME_ROOT=0
TEST_BAD_RUNTIME_METADATA=1
LEGACY_METADATA_ENV_BEFORE="$(<"$LEGACY_METADATA_ENV")"
LEGACY_METADATA_OUTPUT="${TEST_ROOT}/legacy-metadata.out"
if run_bootstrap > "$LEGACY_METADATA_OUTPUT" 2>&1; then
  fail "bootstrap accepted invalid metadata while adopting a legacy runtime"
fi
TEST_BAD_RUNTIME_METADATA=0
PASS_RUNTIME_ROOT=1
assert_contains "$LEGACY_METADATA_OUTPUT" 'WeChat home directory must be owned by'
[ "$(<"$LEGACY_METADATA_ENV")" = "$LEGACY_METADATA_ENV_BEFORE" ] || \
  fail "legacy metadata failure mutated its authoritative environment"
for forbidden_key in CF_AGENT_WECHAT_RUNTIME_ROOT CF_AGENT_WECHAT_BOOTSTRAP_MANAGED \
  CF_RUNTIME_UID CF_RUNTIME_GID CF_RUNTIME_MODE CF_STORAGE_UID CF_STORAGE_GID \
  CF_SECRETS_UID CF_SECRETS_GID; do
  if grep -Eq "^[[:space:]]*${forbidden_key}=" "$LEGACY_METADATA_ENV"; then
    fail "legacy metadata failure persisted $forbidden_key"
  fi
done
pass "legacy runtime metadata is verified before any migration write"

LEGACY_API_RUNTIME="${TEST_ROOT}/legacy-api-runtime"
LEGACY_API_ENV="${TEST_ROOT}/legacy-api.env"
create_complete_runtime_fixture "$LEGACY_API_RUNTIME"
write_env_fixture "$LEGACY_API_ENV" CF_AGENT_WECHAT_STORAGE_ROOT "$LEGACY_API_RUNTIME"
ACTIVE_RUNTIME_ROOT="$LEGACY_API_RUNTIME"
ACTIVE_ENV_FILE="$LEGACY_API_ENV"
PASS_RUNTIME_ROOT=0
TEST_AUTH_STATUS=app_not_running
LEGACY_API_OUTPUT="${TEST_ROOT}/legacy-api.out"
if run_bootstrap > "$LEGACY_API_OUTPUT" 2>&1; then
  fail "bootstrap marked an unmanaged legacy runtime ready before API recovery"
fi
assert_contains "$LEGACY_API_OUTPUT" 'last status: app_not_running'
grep -Fxq "CF_AGENT_WECHAT_RUNTIME_ROOT=$LEGACY_API_RUNTIME" "$LEGACY_API_ENV" || \
  fail "validated legacy runtime root was not migrated before retry"
grep -Fxq 'CF_RUNTIME_MODE=700' "$LEGACY_API_ENV" || \
  fail "validated legacy permission settings were not persisted for retry"
if grep -Eq '^CF_AGENT_WECHAT_BOOTSTRAP_(MANAGED|BOOTSTRAPPED)=' "$LEGACY_API_ENV"; then
  fail "failed legacy API recovery wrote a success or provenance marker"
fi
rmdir -- "${LEGACY_API_RUNTIME}/wechat-home"
TEST_AUTH_STATUS=logged_out
LEGACY_API_RETRY_OUTPUT="${TEST_ROOT}/legacy-api-retry.out"
if run_bootstrap > "$LEGACY_API_RETRY_OUTPUT" 2>&1; then
  fail "failed legacy adoption later repaired an incomplete runtime as managed"
fi
PASS_RUNTIME_ROOT=1
assert_contains "$LEGACY_API_RETRY_OUTPUT" 'no bootstrap provenance and its runtime is incomplete'
[ ! -e "${LEGACY_API_RUNTIME}/wechat-home" ] || \
  fail "unmanaged legacy API retry recreated a missing runtime component"
if grep -Eq '^CF_AGENT_WECHAT_BOOTSTRAP_(MANAGED|BOOTSTRAPPED)=' "$LEGACY_API_ENV"; then
  fail "incomplete legacy retry wrote a success or provenance marker"
fi
pass "legacy provenance is written only after runtime metadata and API recovery succeed"

LEGACY_RUNTIME="${TEST_ROOT}/legacy-runtime"
LEGACY_ENV="${TEST_ROOT}/legacy.env"
create_complete_runtime_fixture "$LEGACY_RUNTIME"
write_env_fixture "$LEGACY_ENV" CF_AGENT_WECHAT_STORAGE_ROOT "${LEGACY_RUNTIME}/"
LEGACY_ENV_MODE_BEFORE="$($REAL_STAT -c '%a' "$LEGACY_ENV")"
ACTIVE_RUNTIME_ROOT="$LEGACY_RUNTIME"
ACTIVE_ENV_FILE="$LEGACY_ENV"
PASS_RUNTIME_ROOT=0
LEGACY_OUTPUT="${TEST_ROOT}/legacy.out"
run_bootstrap > "$LEGACY_OUTPUT" 2>&1 || {
  sed -n '1,240p' "$LEGACY_OUTPUT" >&2
  fail "legacy runtime root migration failed"
}
PASS_RUNTIME_ROOT=1
grep -Fxq "CF_AGENT_WECHAT_STORAGE_ROOT=${LEGACY_RUNTIME}/" "$LEGACY_ENV" || \
  fail "legacy runtime assignment was not preserved"
[ "$(grep -Fc "CF_AGENT_WECHAT_RUNTIME_ROOT=$LEGACY_RUNTIME" "$LEGACY_ENV")" -eq 1 ] || \
  fail "legacy runtime was not migrated exactly once"
[ "$(grep -Fc 'CF_AGENT_WECHAT_BOOTSTRAPPED=1' "$LEGACY_ENV")" -eq 1 ] || \
  fail "legacy migration did not record successful bootstrap"
[ "$($REAL_STAT -c '%a' "$LEGACY_ENV")" = "$LEGACY_ENV_MODE_BEFORE" ] || \
  fail "atomic legacy migration changed environment file mode"
pass "legacy runtime root is canonically adopted and atomically migrated"

CONFLICT_NEW_RUNTIME="${TEST_ROOT}/conflict-new-runtime"
CONFLICT_LEGACY_RUNTIME="${TEST_ROOT}/conflict-legacy-runtime"
CONFLICT_ENV="${TEST_ROOT}/conflict.env"
write_env_fixture "$CONFLICT_ENV" CF_AGENT_WECHAT_RUNTIME_ROOT "$CONFLICT_NEW_RUNTIME"
printf '%s\n' "CF_AGENT_WECHAT_STORAGE_ROOT=$CONFLICT_LEGACY_RUNTIME" >> "$CONFLICT_ENV"
ACTIVE_RUNTIME_ROOT="$CONFLICT_NEW_RUNTIME"
ACTIVE_ENV_FILE="$CONFLICT_ENV"
PASS_RUNTIME_ROOT=0
CONFLICT_OUTPUT="${TEST_ROOT}/conflict.out"
if run_bootstrap > "$CONFLICT_OUTPUT" 2>&1; then
  fail "bootstrap accepted conflicting new and legacy runtime roots"
fi
PASS_RUNTIME_ROOT=1
assert_contains "$CONFLICT_OUTPUT" 'legacy CF_AGENT_WECHAT_STORAGE_ROOT differ'
[ ! -e "$CONFLICT_NEW_RUNTIME" ] && [ ! -e "$CONFLICT_LEGACY_RUNTIME" ] || \
  fail "runtime-key conflict mutated runtime state"
pass "conflicting new and legacy runtime roots are rejected before runtime mutation"

SENTINEL_MISSING_RUNTIME="${TEST_ROOT}/sentinel-missing-runtime"
SENTINEL_MISSING_ENV="${TEST_ROOT}/sentinel-missing.env"
write_env_fixture "$SENTINEL_MISSING_ENV" CF_AGENT_WECHAT_RUNTIME_ROOT \
  "$SENTINEL_MISSING_RUNTIME" 1
ACTIVE_RUNTIME_ROOT="$SENTINEL_MISSING_RUNTIME"
ACTIVE_ENV_FILE="$SENTINEL_MISSING_ENV"
PASS_RUNTIME_ROOT=0
SENTINEL_MISSING_ENV_BEFORE="$(<"$SENTINEL_MISSING_ENV")"
SENTINEL_MISSING_OUTPUT="${TEST_ROOT}/sentinel-missing.out"
if run_bootstrap > "$SENTINEL_MISSING_OUTPUT" 2>&1; then
  fail "bootstrap accepted an initialized runtime that disappeared"
fi
PASS_RUNTIME_ROOT=1
assert_contains "$SENTINEL_MISSING_OUTPUT" 'persistent runtime is incomplete'
[ ! -e "$SENTINEL_MISSING_RUNTIME" ] || \
  fail "missing initialized runtime was recreated"
[ "$(<"$SENTINEL_MISSING_ENV")" = "$SENTINEL_MISSING_ENV_BEFORE" ] || \
  fail "missing initialized runtime mutated its environment file"
pass "initialized runtime disappearance is rejected without state mutation"

SENTINEL_PARTIAL_RUNTIME="${TEST_ROOT}/sentinel-partial-runtime"
SENTINEL_PARTIAL_ENV="${TEST_ROOT}/sentinel-partial.env"
mkdir -p -- "${SENTINEL_PARTIAL_RUNTIME}/data" \
  "${SENTINEL_PARTIAL_RUNTIME}/secrets"
printf '%s\n' "$(printf 'e%.0s' {1..64})" > \
  "${SENTINEL_PARTIAL_RUNTIME}/secrets/auth-token"
write_env_fixture "$SENTINEL_PARTIAL_ENV" CF_AGENT_WECHAT_RUNTIME_ROOT \
  "$SENTINEL_PARTIAL_RUNTIME" 1
ACTIVE_RUNTIME_ROOT="$SENTINEL_PARTIAL_RUNTIME"
ACTIVE_ENV_FILE="$SENTINEL_PARTIAL_ENV"
PASS_RUNTIME_ROOT=0
SENTINEL_PARTIAL_ENV_BEFORE="$(<"$SENTINEL_PARTIAL_ENV")"
SENTINEL_PARTIAL_OUTPUT="${TEST_ROOT}/sentinel-partial.out"
if run_bootstrap > "$SENTINEL_PARTIAL_OUTPUT" 2>&1; then
  fail "bootstrap accepted a partially restored initialized runtime"
fi
PASS_RUNTIME_ROOT=1
assert_contains "$SENTINEL_PARTIAL_OUTPUT" 'persistent runtime is incomplete'
[ ! -e "${SENTINEL_PARTIAL_RUNTIME}/wechat-home" ] || \
  fail "bootstrap recreated a missing initialized runtime component"
[ "$(<"$SENTINEL_PARTIAL_ENV")" = "$SENTINEL_PARTIAL_ENV_BEFORE" ] || \
  fail "partial initialized runtime mutated its environment file"
pass "partial initialized runtime restore is rejected without state mutation"

RETRY_RUNTIME="${TEST_ROOT}/retry-runtime"
RETRY_ENV="${TEST_ROOT}/retry.env"
ACTIVE_RUNTIME_ROOT="$RETRY_RUNTIME"
ACTIVE_ENV_FILE="$RETRY_ENV"
TEST_AUTH_STATUS=app_not_running
RETRY_FAILURE_OUTPUT="${TEST_ROOT}/retry-failure.out"
if run_bootstrap > "$RETRY_FAILURE_OUTPUT" 2>&1; then
  fail "bootstrap accepted app_not_running as production-ready"
fi
assert_contains "$RETRY_FAILURE_OUTPUT" 'last status: app_not_running'
if grep -Fq 'CF_AGENT_WECHAT_BOOTSTRAPPED=' "$RETRY_ENV"; then
  fail "failed fresh bootstrap wrote the completion sentinel"
fi
[ -f "${RETRY_RUNTIME}/secrets/auth-token" ] || \
  fail "failed fresh bootstrap did not retain resumable token state"
for setting in \
  "CF_RUNTIME_UID=$CURRENT_UID" "CF_RUNTIME_GID=$CURRENT_GID" \
  'CF_RUNTIME_MODE=700' "CF_STORAGE_UID=$CURRENT_UID" \
  "CF_STORAGE_GID=$CURRENT_GID" "CF_SECRETS_UID=$CURRENT_UID" \
  "CF_SECRETS_GID=$CURRENT_GID"; do
  grep -Fxq "$setting" "$RETRY_ENV" || \
    fail "failed fresh bootstrap did not atomically persist $setting"
done
TEST_AUTH_STATUS=logged_out
PASS_RUNTIME_ROOT=0
PASS_PERMISSION_SETTINGS=0
RETRY_SUCCESS_OUTPUT="${TEST_ROOT}/retry-success.out"
run_bootstrap > "$RETRY_SUCCESS_OUTPUT" 2>&1 || {
  sed -n '1,240p' "$RETRY_SUCCESS_OUTPUT" >&2
  fail "failed fresh bootstrap could not resume"
}
PASS_RUNTIME_ROOT=1
PASS_PERMISSION_SETTINGS=1
[ "$(grep -Fc 'CF_AGENT_WECHAT_BOOTSTRAPPED=1' "$RETRY_ENV")" -eq 1 ] || \
  fail "successful retry did not write exactly one completion sentinel"
pass "failed fresh bootstrap remains resumable and records success only after API verification"

ACTIVE_RUNTIME_ROOT="$RUNTIME_ROOT"
ACTIVE_ENV_FILE="$ENV_FILE"

TEST_AUTH_SEQUENCE=unknown,logged_out
TEST_BOOTSTRAP_TIMEOUT=3
SEQUENCE_CALLS_BEFORE="$(grep -Fc '/api/status/auth' "$AUDIT_LOG")"
SEQUENCE_OUTPUT="${TEST_ROOT}/auth-sequence.out"
run_bootstrap > "$SEQUENCE_OUTPUT" 2>&1 || {
  sed -n '1,240p' "$SEQUENCE_OUTPUT" >&2
  fail "bootstrap did not continue polling after an unknown auth status"
}
SEQUENCE_CALLS_AFTER="$(grep -Fc '/api/status/auth' "$AUDIT_LOG")"
[ "$((SEQUENCE_CALLS_AFTER - SEQUENCE_CALLS_BEFORE))" -eq 2 ] || \
  fail "unknown-to-ready auth sequence was not polled exactly twice"
assert_contains "$SEQUENCE_OUTPUT" 'authenticated API is ready (auth status: logged_out)'
TEST_AUTH_SEQUENCE=""
TEST_BOOTSTRAP_TIMEOUT=1
pass "unknown authenticated state is polled until a supported ready state"

TEST_AUTH_STATUS=unknown
UNKNOWN_OUTPUT="${TEST_ROOT}/auth-unknown.out"
if run_bootstrap > "$UNKNOWN_OUTPUT" 2>&1; then
  fail "bootstrap accepted an unknown authenticated API state"
fi
assert_contains "$UNKNOWN_OUTPUT" 'last status: unknown'
TEST_AUTH_STATUS=logged_out
pass "unknown authenticated state reports the last observation on timeout"

TEST_HTTP_CONNECT_TIMEOUT=99
TEST_HTTP_TIMEOUT=99
CLAMP_AUDIT_BEFORE="$(wc -l < "$AUDIT_LOG")"
CLAMP_OUTPUT="${TEST_ROOT}/curl-clamp.out"
run_bootstrap > "$CLAMP_OUTPUT" 2>&1 || {
  sed -n '1,240p' "$CLAMP_OUTPUT" >&2
  fail "bootstrap failed while testing bounded HTTP deadlines"
}
CLAMP_AUDIT="${TEST_ROOT}/curl-clamp.audit"
sed -n "$((CLAMP_AUDIT_BEFORE + 1)),\$p" "$AUDIT_LOG" > "$CLAMP_AUDIT"
assert_contains "$CLAMP_AUDIT" $'connect=1\tmax=1'
if grep -Eq 'connect=99|max=99' "$CLAMP_AUDIT"; then
  fail "curl exceeded the remaining bootstrap stage deadline"
fi
TEST_HTTP_CONNECT_TIMEOUT=1
TEST_HTTP_TIMEOUT=1
pass "curl connect and request timeouts are clamped to the stage deadline"

TEST_COMPOSE_INVALID=1
COMPOSE_OUTPUT="${TEST_ROOT}/compose.out"
if run_bootstrap > "$COMPOSE_OUTPUT" 2>&1; then
  fail "bootstrap accepted an invalid Compose configuration"
fi
assert_contains "$COMPOSE_OUTPUT" 'production Compose validation failed'
TEST_COMPOSE_INVALID=0
pass "Compose validation failure"

TEST_CONTAINER_STATE=exited
CONTAINER_OUTPUT="${TEST_ROOT}/container.out"
if run_bootstrap > "$CONTAINER_OUTPUT" 2>&1; then
  fail "bootstrap accepted an exited container"
fi
assert_contains "$CONTAINER_OUTPUT" 'container did not become running and healthy'
TEST_CONTAINER_STATE=running
pass "container state verification failure"

TEST_HEALTH=unhealthy
HEALTH_OUTPUT="${TEST_ROOT}/health.out"
if run_bootstrap > "$HEALTH_OUTPUT" 2>&1; then
  fail "bootstrap accepted an unhealthy container"
fi
assert_contains "$HEALTH_OUTPUT" 'container did not become running and healthy'
TEST_HEALTH=healthy
pass "container health verification failure"

TEST_RESTART_POLICY=always
RESTART_OUTPUT="${TEST_ROOT}/restart.out"
if run_bootstrap > "$RESTART_OUTPUT" 2>&1; then
  fail "bootstrap accepted an unsafe restart policy"
fi
assert_contains "$RESTART_OUTPUT" 'restart policy must be unless-stopped'
TEST_RESTART_POLICY=unless-stopped
pass "runtime restart-policy verification failure"

TEST_BAD_MOUNT=1
MOUNT_OUTPUT="${TEST_ROOT}/mount.out"
if run_bootstrap > "$MOUNT_OUTPUT" 2>&1; then
  fail "bootstrap accepted an incorrect persistent mount"
fi
assert_contains "$MOUNT_OUTPUT" 'container mount /home/wechat is not persistent'
TEST_BAD_MOUNT=0
pass "runtime mount verification failure"

TEST_DATA_MOUNT_RW=false
DATA_ACCESS_OUTPUT="${TEST_ROOT}/data-access.out"
if run_bootstrap > "$DATA_ACCESS_OUTPUT" 2>&1; then
  fail "bootstrap accepted a read-only data mount"
fi
assert_contains "$DATA_ACCESS_OUTPUT" 'container mount /data must be read-write'
TEST_DATA_MOUNT_RW=true
pass "runtime data mount access verification failure"

TEST_TOKEN_MOUNT_RW=true
TOKEN_ACCESS_OUTPUT="${TEST_ROOT}/token-access.out"
if run_bootstrap > "$TOKEN_ACCESS_OUTPUT" 2>&1; then
  fail "bootstrap accepted a writable auth-token mount"
fi
assert_contains "$TOKEN_ACCESS_OUTPUT" 'container mount /data/auth-token must be read-only'
TEST_TOKEN_MOUNT_RW=false
pass "runtime auth-token mount access verification failure"

TEST_NETWORK_ATTACHED=0
NETWORK_ATTACHMENT_OUTPUT="${TEST_ROOT}/network-attachment.out"
if run_bootstrap > "$NETWORK_ATTACHMENT_OUTPUT" 2>&1; then
  fail "bootstrap accepted a container detached from cf-internal"
fi
assert_contains "$NETWORK_ATTACHMENT_OUTPUT" 'container is not attached to required Docker network: cf-internal'
TEST_NETWORK_ATTACHED=1
pass "runtime network attachment verification failure"

TEST_NETWORK_ALIAS_PRESENT=0
NETWORK_ALIAS_OUTPUT="${TEST_ROOT}/network-alias.out"
if run_bootstrap > "$NETWORK_ALIAS_OUTPUT" 2>&1; then
  fail "bootstrap accepted a container missing its fixed cf-internal alias"
fi
assert_contains "$NETWORK_ALIAS_OUTPUT" \
  'container network cf-internal is missing required alias: cf-agent-wechat'
TEST_NETWORK_ALIAS_PRESENT=1
pass "runtime fixed network alias verification failure"

TEST_PORT_BINDING=0.0.0.0:6174
PORT_BINDING_OUTPUT="${TEST_ROOT}/port-binding.out"
if run_bootstrap > "$PORT_BINDING_OUTPUT" 2>&1; then
  fail "bootstrap accepted a non-loopback runtime port binding"
fi
assert_contains "$PORT_BINDING_OUTPUT" 'container port 6174/tcp must bind to 127.0.0.1:6174'
TEST_PORT_BINDING=""
pass "runtime loopback port binding verification failure"

TEST_API_MODE=invalid-json
API_OUTPUT="${TEST_ROOT}/api.out"
if run_bootstrap > "$API_OUTPUT" 2>&1; then
  fail "bootstrap accepted an invalid authenticated API response"
fi
assert_contains "$API_OUTPUT" 'last status: invalid_response'
TEST_API_MODE=ready
pass "authenticated API verification failure"

TOKEN_ID_FINAL="$($REAL_STAT -c '%i:%Y:%s' "${RUNTIME_ROOT}/secrets/auth-token")"
[ "$TOKEN_ID_BEFORE" = "$TOKEN_ID_FINAL" ] || fail "a failure path replaced the auth token"
grep -Fxq 'persisted-session-fixture' "${RUNTIME_ROOT}/data/session.marker" || \
  fail "a failure path replaced the runtime"
if grep -Fq 'Authorization: Bearer' "$AUDIT_LOG"; then
  fail "Docker/curl audit log contains an authorization header"
fi

grep -Eq '^[[:space:]]+restart: unless-stopped$' \
  "${REPO_ROOT}/docker/compose.cfserver.yaml" || fail "production restart policy is missing"
[ "$(grep -Fc 'CF_AGENT_WECHAT_RUNTIME_ROOT' \
  "${REPO_ROOT}/docker/compose.cfserver.yaml")" -eq 3 ] || \
  fail "production Compose does not use one persistent runtime root for all mounts"
[ "$(grep -Fc 'CF_AGENT_WECHAT_STORAGE_ROOT' "${REPO_ROOT}/docker/compose.cfserver.yaml")" -eq 3 ] || \
  fail "production Compose does not retain legacy runtime-root fallback"
for bind_target in /data /home/wechat /data/auth-token; do
  awk -v target="$bind_target" '
    $0 == ("        target: " target) {
      in_target = 1
      next
    }
    in_target && $0 == "          create_host_path: false" {
      disabled = 1
    }
    in_target && /^      - type:/ {
      exit
    }
    END {
      exit(disabled ? 0 : 1)
    }
  ' "${REPO_ROOT}/docker/compose.cfserver.yaml" || \
    fail "production bind $bind_target must explicitly disable create_host_path"
done
pass "production Compose persistence and restart policy"

printf '%s\n' 'All CFserver bootstrap deployment tests passed.'
