#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
STATE_DIR="${SCRIPT_DIR}/state"
LOG_FILE="${STATE_DIR}/docker.log"
mkdir -p -- "$STATE_DIR"
touch "$LOG_FILE"

via_sudo="${CF_BOOTSTRAP_DOCKER_VIA_SUDO:-0}"
{
  printf 'docker\tvia_sudo=%s' "$via_sudo"
  printf '\t%s' "$@"
  printf '\n'
} >> "$LOG_FILE"

hang_forever() {
  printf '%s\n' "$BASHPID" > "${STATE_DIR}/hang.pid"
  trap '' TERM
  while :; do sleep 1; done
}

read_env_value() {
  local file="$1" key="$2"
  awk -F= -v expected="$key" '$1 == expected { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

if [ "${1:-}" = --version ]; then
  printf '%s\n' 'Docker version 28.0.0, build bootstrap-test'
  exit 0
fi

case "${1:-}" in
  info)
    if [ -e "${STATE_DIR}/hang-info-once" ] && [ "$via_sudo" = 0 ]; then
      rm -f -- "${STATE_DIR}/hang-info-once"
      hang_forever
    fi
    [ ! -e "${STATE_DIR}/hang-info" ] || hang_forever
    if [ -e "${STATE_DIR}/deny-direct" ] && [ "$via_sudo" != 1 ]; then
      printf '%s\n' 'permission denied while connecting to docker.sock' >&2
      exit 1
    fi
    if [[ " $* " == *LiveRestoreEnabled* ]]; then
      if [ -e "${STATE_DIR}/live-restore" ]; then
        printf '%s\n' true
      else
        printf '%s\n' false
      fi
    elif [[ " $* " == *SecurityOptions* ]]; then
      if [ -e "${STATE_DIR}/rootless" ]; then
        printf '%s\n' '["name=rootless"]'
      else
        printf '%s\n' '["name=seccomp"]'
      fi
    else
      printf '%s\n' 'mock Docker daemon'
    fi
    ;;
  context)
    case "${2:-}" in
      show)
        if [ -e "${STATE_DIR}/remote-context" ]; then
          printf '%s\n' remote
        else
          printf '%s\n' default
        fi
        ;;
      inspect)
        if [ -e "${STATE_DIR}/remote-context" ]; then
          printf '%s\n' 'tcp://remote.example:2376'
        else
          printf '%s\n' 'unix:///var/run/docker.sock'
        fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  network)
    case "${2:-}" in
      inspect)
        [ -e "${STATE_DIR}/network" ] || exit 1
        if [[ " $* " == *'--format'* ]]; then
          printf '%s\n' 'cf-internal|bridge|local'
        else
          printf '%s\n' '[]'
        fi
        ;;
      create)
        : > "${STATE_DIR}/network"
        printf '%s\n' cf-internal
        ;;
      *) exit 2 ;;
    esac
    ;;
  inspect)
    if [[ " $* " == *RestartPolicy.Name* ]]; then
      if [ -e "${STATE_DIR}/agent-bad-restart" ]; then
        printf '%s\n' unless-stopped
      else
        printf '%s\n' no
      fi
      exit 0
    fi
    exit 2
    ;;
  compose)
    shift
    compose_file=""
    env_file=""
    command_name=""
    command_args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --env-file)
          env_file="${2:-}"
          shift 2
          ;;
        --project-directory|--project-name|-f)
          if [ "$1" = -f ]; then compose_file="${2:-}"; fi
          shift 2
          ;;
        version|config|ps|up|start|stop|restart|rm|down)
          command_name="$1"
          shift
          command_args=("$@")
          break
          ;;
        *) shift ;;
      esac
    done

    is_gateway=0
    case "$compose_file" in */gateway/*|*/deploy/compose.yaml) is_gateway=1 ;; esac
    case "$command_name" in
      version)
        printf '%s\n' '2.35.1'
        ;;
      config)
        if [ "$is_gateway" -eq 0 ] && [ -e "${STATE_DIR}/hang-compose" ]; then
          hang_forever
        fi
        if [ "$is_gateway" -eq 0 ] && [ -e "${STATE_DIR}/fail-agent-compose" ]; then
          exit 1
        fi
        arguments=" ${command_args[*]} "
        if [[ "$arguments" == *' --services '* ]]; then
          if [ "$is_gateway" -eq 1 ]; then
            printf '%s\n' wechat-worker dispatch-worker delivery-worker
          else
            printf '%s\n' agent-wechat
          fi
          exit 0
        fi
        if [[ "$arguments" == *' --format json '* ]] && [ "$is_gateway" -eq 0 ]; then
          image="$(read_env_value "$env_file" AGENT_WECHAT_IMAGE)"
          port="$(read_env_value "$env_file" AGENT_WECHAT_PORT)"
          runtime="${CF_AGENT_WECHAT_RUNTIME_ROOT:?}"
          token="${CF_AGENT_WECHAT_TOKEN_FILE:?}"
          restart_policy=no
          [ ! -e "${STATE_DIR}/bad-compose-restart" ] ||
            restart_policy=unless-stopped
          python3 - "$image" "$port" "$runtime" "$token" "$restart_policy" <<'PY'
import json
import sys

image, port, runtime, token, restart_policy = sys.argv[1:]
print(json.dumps({
    "name": "cf-agent-wechat",
    "services": {
        "agent-wechat": {
            "image": image,
            "container_name": "cf-agent-wechat",
            "restart": restart_policy,
            "security_opt": ["seccomp=unconfined"],
            "cap_add": ["SYS_PTRACE"],
            "ports": [{
                "host_ip": "127.0.0.1",
                "published": port,
                "target": 6174,
                "protocol": "tcp",
            }],
            "volumes": [
                {"type": "bind", "source": runtime + "/data", "target": "/data", "bind": {"create_host_path": False}},
                {"type": "bind", "source": runtime + "/wechat-home", "target": "/home/wechat", "bind": {"create_host_path": False}},
                {"type": "bind", "source": token, "target": "/data/auth-token", "read_only": True, "bind": {"create_host_path": False}},
            ],
            "environment": {"ENABLE_VNC": "0"},
            "healthcheck": {
                "test": ["CMD", "curl", "--fail", "--silent", "--show-error", "http://127.0.0.1:6174/health"],
                "timeout": "5s",
                "retries": 5,
            },
            "logging": {"driver": "json-file", "options": {"max-size": "20m", "max-file": "3"}},
            "networks": {"cf-internal": {"aliases": ["cf-agent-wechat"]}},
        }
    },
    "networks": {"cf-internal": {"name": "cf-internal", "external": True}},
}))
PY
        fi
        ;;
      ps)
        arguments=" ${command_args[*]} "
        service="${command_args[${#command_args[@]}-1]:-}"
        if [ "$service" = agent-wechat ]; then
          if [[ "$arguments" == *' --status running '* ]]; then
            [ ! -e "${STATE_DIR}/agent-running" ] || printf '%s\n' agent-test-id
          elif [[ "$arguments" == *' --all '* ]]; then
            if [ -e "${STATE_DIR}/agent-running" ] || [ -e "${STATE_DIR}/agent-existing" ]; then
              printf '%s\n' agent-test-id
            fi
          fi
        elif [ "$service" = wechat-worker ]; then
          if [[ "$arguments" == *' --status running '* ]] && [ -e "${STATE_DIR}/worker-running" ]; then
            printf '%s\n' worker-test-id
          fi
        fi
        ;;
      up|start|stop|restart|rm|down)
        printf '%s\n' "forbidden lifecycle command: $command_name" >&2
        exit 90
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
