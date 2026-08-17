#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_DOCKER_STATE_DIR:?}"
: "${MOCK_DOCKER_LOG:?}"
: "${MOCK_DOCKER_MUTATION_LOG:?}"

state_get() {
  local name="$1"
  local default_value="$2"
  if [ -f "${MOCK_DOCKER_STATE_DIR}/$name" ]; then
    cat -- "${MOCK_DOCKER_STATE_DIR}/$name"
  else
    printf '%s' "$default_value"
  fi
}

state_set() {
  printf '%s\n' "$2" > "${MOCK_DOCKER_STATE_DIR}/$1"
}

record() {
  printf '%s\n' "$1" >> "$MOCK_DOCKER_LOG"
}

mutate() {
  record "$1"
  printf '%s\n' "$1" >> "$MOCK_DOCKER_MUTATION_LOG"
}

case "${1:-}" in
  info)
    record "docker info"
    exit 0
    ;;
  exec)
    record "docker exec wechat-process-check"
    calls="$(state_get wechat_calls 0)"
    calls=$((calls + 1))
    state_set wechat_calls "$calls"
    mode="$(state_get wechat_mode stable)"
    case "$mode" in
      stable)
        printf '%s\n' '4242:9001'
        exit 0
        ;;
      missing)
        exit 1
        ;;
      disappear)
        if [ "$calls" -eq 1 ]; then
          printf '%s\n' '4242:9001'
          exit 0
        fi
        exit 1
        ;;
      unstable)
        printf '4242:%s\n' "$calls"
        exit 0
        ;;
      change_on_final_check)
        if [ "$calls" -le 5 ]; then
          printf '%s\n' '4242:9001'
        else
          printf '%s\n' '5252:9002'
        fi
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  inspect)
    record "docker inspect"
    if printf '%s\n' "$@" | grep -q '{{.State.Running}}'; then
      if [ "$(state_get agent_running 1)" = "1" ]; then
        printf '%s\n' 'true'
      else
        printf '%s\n' 'false'
      fi
      exit 0
    fi
    runtime_root="${CF_AGENT_WECHAT_RUNTIME_ROOT:?}"
    printf '[{"Mounts":['
    printf '{"Source":"%s/data","Destination":"/data","RW":true},' \
      "$runtime_root"
    printf '{"Source":"%s/wechat-home","Destination":"/home/wechat","RW":true},' \
      "$runtime_root"
    printf '{"Source":"%s",' "${TOKEN_FILE:?}"
    printf '%s\n' '"Destination":"/data/auth-token","RW":false}]}]'
    exit 0
    ;;
  compose)
    ;;
  *)
    record "docker unsupported"
    exit 64
    ;;
esac

shift
compose_file=""
compose_env_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      compose_env_file="$2"
      shift 2
      ;;
    --project-directory)
      shift 2
      ;;
    -f)
      compose_file="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

command_name="${1:-}"
[ -n "$command_name" ] || exit 64
shift
if [ "$compose_file" = "${MOCK_GATEWAY_COMPOSE_FILE:?}" ]; then
  compose_kind="gateway"
  if [ "$compose_env_file" != "${MOCK_GATEWAY_ENV_FILE:?}" ]; then
    record "gateway compose env-file invalid"
    exit 67
  fi
  record "gateway compose env-file verified"
else
  compose_kind="agent"
  if [ -n "$compose_env_file" ]; then
    record "agent compose unexpected env-file"
    exit 67
  fi
fi

case "$command_name" in
  config)
    record "$compose_kind compose config"
    if [ "$compose_kind" = "agent" ] &&
      [ "$*" = "--format json" ]; then
      printf '{"services":{"agent-wechat":{"volumes":['
      printf '{"type":"bind","source":"%s/data","target":"/data","read_only":false},' \
        "${CF_AGENT_WECHAT_RUNTIME_ROOT:?}"
      printf '{"type":"bind","source":"%s/wechat-home","target":"/home/wechat","read_only":false},' \
        "${CF_AGENT_WECHAT_RUNTIME_ROOT:?}"
      printf '{"type":"bind","source":"%s","target":"/data/auth-token","read_only":true}' \
        "${TOKEN_FILE:?}"
      printf '%s\n' ']}}}'
    elif printf '%s\n' "$@" | grep -qx -- '--services'; then
      printf '%s\n' 'wechat-worker'
    fi
    ;;
  ps)
    record "$compose_kind compose ps"
    service="${*: -1}"
    if [ "$compose_kind" = "gateway" ]; then
      [ "$service" = "wechat-worker" ] || exit 65
      if [ "$(state_get gateway_ps_error 0)" = "1" ]; then
        record "gateway compose ps error"
        exit 70
      fi
      if [ "$(state_get gateway_running 1)" = "1" ]; then
        printf '%s\n' 'gateway-worker-fixture'
      fi
    elif [ "$service" != "agent-wechat" ]; then
      exit 65
    elif [ "$(state_get agent_ps_error 0)" = "1" ]; then
      record "agent compose ps error"
      exit 70
    elif printf '%s\n' "$@" | grep -qx -- '--all'; then
      if [ "$(state_get agent_exists 1)" = "1" ]; then
        printf '%s\n' 'agent-container-fixture'
      fi
    elif [ "$(state_get agent_running 1)" = "1" ]; then
      printf '%s\n' 'agent-container-fixture'
    fi
    ;;
  stop)
    if [ "$compose_kind" = "gateway" ]; then
      [ "${*: -1}" = "wechat-worker" ] || exit 65
      mutate "gateway worker stop"
      state_set gateway_running 0
    else
      [ "${*: -1}" = "agent-wechat" ] || exit 65
      mutate "agent container stop"
      state_set agent_running 0
    fi
    ;;
  rm)
    [ "$compose_kind" = "agent" ] || exit 65
    [ "${*: -1}" = "agent-wechat" ] || exit 65
    mutate "agent container remove"
    state_set agent_exists 0
    state_set agent_running 0
    ;;
  up)
    if [ "$compose_kind" = "gateway" ]; then
      [ "${*: -1}" = "wechat-worker" ] || exit 65
      mutate "gateway worker start"
      state_set gateway_running 1
    else
      [ "${*: -1}" = "agent-wechat" ] || exit 65
      mutate "agent container start"
      state_set agent_exists 1
      state_set agent_running 1
      state_set wechat_calls 0
    fi
    ;;
  down)
    mutate "forbidden compose down"
    exit 66
    ;;
  *)
    record "$compose_kind compose unsupported"
    exit 64
    ;;
esac
