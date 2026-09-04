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

require_process_contract_fragment() {
  case "$1" in
    *"$2"*) ;;
    *)
      printf '%s\n' 'wechat process identity contract mismatch' >&2
      exit 65
      ;;
  esac
}

case "${1:-}" in
  info)
    record "docker info"
    if [[ " $* " == *LiveRestoreEnabled* ]]; then
      state_get live_restore false
      printf '\n'
    elif printf '%s\n' "$@" | grep -q -- '--format'; then
      printf '%s\n' '["name=seccomp,profile=default","name=cgroupns"]'
    fi
    exit 0
    ;;
  context)
    record "docker context"
    case "${2:-}" in
      show) printf '%s\n' 'default' ;;
      inspect) printf '%s\n' 'unix:///var/run/docker.sock' ;;
      *) exit 64 ;;
    esac
    exit 0
    ;;
  exec)
    record "docker exec wechat-process-check"
    process_script="${5:-}"
    require_process_contract_fragment "$process_script" 'readlink -f /usr/bin/wechat'
    require_process_contract_fragment "$process_script" 'case "$launcher_real" in'
    require_process_contract_fragment "$process_script" 'proc_exe="$(readlink "$process_dir/exe"'
    require_process_contract_fragment "$process_script" '[ "$proc_exe" = "$launcher_real" ] || continue'
    require_process_contract_fragment "$process_script" 'printf "%s:%s\n" "$process_id" "$start_time"'
    if [ "$(state_get wechat_launcher_resolves 1)" != "1" ]; then
      exit 1
    fi
    launcher_real="$(state_get wechat_launcher_real /opt/wechat/wechat)"
    case "$launcher_real" in
      /*) ;;
      *) exit 1 ;;
    esac
    proc_exe="$(state_get wechat_proc_exe /opt/wechat/wechat)"
    [ "$proc_exe" = "$launcher_real" ] || exit 1
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
      same_pid_new_start_on_final_check)
        if [ "$calls" -le 5 ]; then
          printf '%s\n' '4242:9001'
        else
          printf '%s\n' '4242:9002'
        fi
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  image)
    record "docker image inspect"
    [ "${2:-}" = inspect ] || exit 64
    printf 'sha256:%064d\n' 1
    exit 0
    ;;
  inspect)
    record "docker inspect"
    if printf '%s\n' "$@" | grep -q 'HostConfig.RestartPolicy.Name'; then
      printf '/agent-wechat-fixture|ghcr.io/example/agent-wechat@sha256:%064d|' 0
      printf 'sha256:%064d|no\n' 1
      exit 0
    fi
    if printf '%s\n' "$@" | grep -q '.State.Health'; then
      if [ "$(state_get container_health healthy)" = "healthy" ]; then
        printf '%s\n' 'healthy'
      else
        printf '%s\n' "$(state_get container_health unhealthy)"
      fi
      exit 0
    fi
    if printf '%s\n' "$@" | grep -q '{{.State.Running}}'; then
      if [ "$(state_get agent_running 1)" = "1" ]; then
        printf '%s\n' 'true'
      else
        printf '%s\n' 'false'
      fi
      exit 0
    fi
    runtime_root="${CF_AGENT_WECHAT_RUNTIME_ROOT:-${MOCK_RUNTIME_ROOT:?}}"
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
    --project-directory|--project-name)
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
compose_kind="agent"
if [ "$compose_file" != "${MOCK_AGENT_COMPOSE_FILE:?}" ] ||
  [ "$compose_env_file" != "${MOCK_AGENT_ENV_FILE:?}" ]; then
  record "agent compose inputs invalid"
  exit 67
fi
record "agent compose env-file verified"
case "$command_name" in
  config)
    record "$compose_kind compose config"
    if [ "$compose_kind" = "agent" ] &&
      [ "$*" = "--format json" ]; then
      published_port="$(awk -F= '
        $1 == "AGENT_WECHAT_PORT" { print substr($0, index($0, "=") + 1) }
      ' "$compose_env_file")"
      [ -n "$published_port" ] || exit 68
      printf '{"name":"cf-agent-wechat","services":{"agent-wechat":{'
      printf '"image":"ghcr.io/example/agent-wechat@sha256:%064d",' 0
      printf '"container_name":"agent-wechat-fixture",'
      printf '"restart":"no",'
      printf '"ports":[{"target":6174,"published":"%s","host_ip":"127.0.0.1","protocol":"tcp"}],' \
        "$published_port"
      printf '"networks":{"cf-internal":{"aliases":["cf-agent-wechat"]}},'
      printf '"environment":{"ENABLE_VNC":"0"},'
      printf '"healthcheck":{'
      printf '"test":["CMD","curl","--fail","--silent","--show-error","http://127.0.0.1:6174/health"],'
      printf '"interval":"30s","timeout":"5s","retries":5,"start_period":"1m30s"},'
      printf '"security_opt":["seccomp=unconfined"],'
      printf '"cap_add":["SYS_PTRACE"],'
      printf '"logging":{"driver":"json-file","options":{"max-size":"20m","max-file":"3"}},'
      printf '"volumes":['
      printf '{"type":"bind","source":"%s/data","target":"/data","read_only":false},' \
        "${CF_AGENT_WECHAT_RUNTIME_ROOT:?}"
      printf '{"type":"bind","source":"%s/wechat-home","target":"/home/wechat","read_only":false},' \
        "${CF_AGENT_WECHAT_RUNTIME_ROOT:?}"
      printf '{"type":"bind","source":"%s","target":"/data/auth-token","read_only":true}' \
        "${TOKEN_FILE:?}"
      printf '%s\n' ']}},"networks":{"cf-internal":{"external":true,"name":"cf-internal"}}}'
    fi
    ;;
  ps)
    record "$compose_kind compose ps"
    service="${*: -1}"
    [ "$service" = "agent-wechat" ] || exit 65
    if [ "$(state_get agent_ps_error 0)" = "1" ]; then
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
    [ "${*: -1}" = "agent-wechat" ] || exit 65
    if [ "$(state_get agent_started_once 0)" = "1" ] &&
      [ "$(state_get agent_cleanup_stop_error 0)" = "1" ]; then
      state_set agent_running 0
      record "agent container cleanup stop failed"
      exit 73
    fi
    mutate "agent container stop"
    state_set agent_running 0
    ;;
  rm)
    [ "$compose_kind" = "agent" ] || exit 65
    [ "${*: -1}" = "agent-wechat" ] || exit 65
    if [ "$(state_get agent_started_once 0)" = "1" ] &&
      [ "$(state_get agent_cleanup_remove_error 0)" = "1" ]; then
      record "agent container cleanup remove failed"
      exit 74
    fi
    mutate "agent container remove"
    state_set agent_exists 0
    state_set agent_running 0
    ;;
  up)
    [ "${*: -1}" = "agent-wechat" ] || exit 65
    mutate "agent container start"
    state_set agent_exists 1
    state_set agent_running 1
    state_set agent_started_once 1
    state_set wechat_calls 0
    printf '%s\n' 'logged_out' > "${MOCK_AUTH_STATE_FILE:?}"
    printf '%s\n' 'agent runtime evidence' > \
      "${CF_AGENT_WECHAT_RUNTIME_ROOT:?}/data/agent-runtime.log"
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
