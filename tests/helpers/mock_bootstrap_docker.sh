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
  /usr/bin/python3 -I - "$BASHPID" "${STATE_DIR}/hang.process" <<'PY'
import pathlib
import sys


def process_identity(pid: int) -> tuple[int, int]:
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    fields = raw[raw.rfind(")") + 2 :].split()
    return int(fields[2]), int(fields[19])


pid = int(sys.argv[1])
pgid, pid_start = process_identity(pid)
leader_pgid, pgid_start = process_identity(pgid)
if leader_pgid != pgid:
    raise SystemExit(1)
pathlib.Path(sys.argv[2]).write_text(
    f"{pid} {pid_start} {pgid} {pgid_start}\n",
    encoding="ascii",
)
PY
  /usr/bin/python3 -c 'import time; print(time.monotonic_ns())' \
    > "${STATE_DIR}/hang.started"
  trap '' TERM
  exec /usr/bin/sleep 300
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
    project_name=""
    command_name=""
    command_args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --env-file)
          env_file="${2:-}"
          shift 2
          ;;
        --project-directory)
          shift 2
          ;;
        --project-name)
          project_name="${2:-}"
          shift 2
          ;;
        -f)
          compose_file="${2:-}"
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
    if [ "$is_gateway" -eq 1 ] && [ -e "${STATE_DIR}/assert-gateway-clean-env" ]; then
      gateway_forbidden_variables=(
        DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
        COMPOSE_FILE COMPOSE_PROFILES COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR
        COMPOSE_PROJECT_DIR COMPOSE_PARALLEL_LIMIT COMPOSE_IGNORE_ORPHANS
        COMPOSE_REMOVE_ORPHANS COMPOSE_STATUS_STDOUT COMPOSE_ANSI COMPOSE_PROGRESS
        COMPOSE_EXPERIMENTAL COMPOSE_MENU COMPOSE_PROJECT_NAME DOCKER_CONFIG
        BUILDX_BUILDER HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy
        https_proxy all_proxy no_proxy AGENT_WECHAT_IMAGE AGENT_WECHAT_BIND_IP
        AGENT_WECHAT_PORT AGENT_WECHAT_CONTAINER_NAME CF_AGENT_WECHAT_STORAGE_ROOT
        CF_AGENT_WECHAT_RUNTIME_ROOT CF_AGENT_WECHAT_ARCHIVE_ROOT
        CF_AGENT_WECHAT_TOKEN_FILE PROXY RUST_LOG CF_GATEWAY_IMAGE
        CF_GATEWAY_CONFIG_FILE CF_GATEWAY_DATABASE_URL CF_GATEWAY_BIND_IP
        CF_GATEWAY_PORT CF_GATEWAY_STOP_GRACE_PERIOD CF_GATEWAY_LOG_LEVEL
        CF_GATEWAY_WORKER_HEARTBEAT_FILE CF_GATEWAY_WORKER_HEARTBEAT_MAX_AGE
        CF_GATEWAY_CONFIG CF_AGENT_GATEWAY_DATABASE_URL
        CF_GATEWAY_STARTUP_MIGRATION_MODE CF_GATEWAY_API_TOKEN
        CF_AGENT_GATEWAY_ADMIN_TOKEN CF_AGENT_WECHAT_TOKEN HERMES_API_KEY
        CF_GATEWAY_WORKER_CONCURRENCY CF_GATEWAY_WORKER_LEASE_SECONDS
        CF_GATEWAY_WORKER_RETRY_LIMIT CF_GATEWAY_WORKER_HEARTBEAT_INTERVAL_SECONDS
        CF_GATEWAY_WORKER_HEARTBEAT_MAX_AGE_SECONDS
        CF_GATEWAY_RUNTIME_HEARTBEAT_MAX_AGE_SECONDS CF_GATEWAY_BIND_ADDRESS
        CF_GATEWAY_LOG_MAX_SIZE CF_GATEWAY_LOG_MAX_FILES
      )
      for variable in "${gateway_forbidden_variables[@]}"; do
        if [[ -v $variable ]]; then
          printf '%s\n' "$variable" > "${STATE_DIR}/gateway-env-not-clean"
          exit 88
        fi
      done
      if [ "${CF_GATEWAY_ENV_FILE-}" != "$env_file" ]; then
        printf '%s\n' CF_GATEWAY_ENV_FILE > "${STATE_DIR}/gateway-env-not-clean"
        exit 88
      fi
      : > "${STATE_DIR}/gateway-env-clean"
    fi
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
            printf '%s\n' worker dispatch-worker delivery-worker
          else
            printf '%s\n' agent-wechat
          fi
          exit 0
        fi
        if [[ "$arguments" == *' --format json '* ]] && [ "$is_gateway" -eq 1 ]; then
          gateway_root="${compose_file%/*}"
          scenario_root="${gateway_root%/*}"
          token_host_path="${scenario_root}/storage/secrets/auth-token"
          token_worker_path="$(read_env_value "$env_file" CF_AGENT_WECHAT_TOKEN_FILE)"
          token_mount_source="$token_host_path"
          [ ! -e "${STATE_DIR}/gateway-token-mount-drift" ] ||
            token_mount_source="${token_host_path}.drift"
          python3 - "$project_name" "$token_host_path" "$token_worker_path" \
            "$token_mount_source" <<'PY'
import json
import sys

project_name, token_host_path, token_worker_path, token_mount_source = sys.argv[1:]
print(json.dumps({
    "name": project_name,
    "services": {
        "worker": {
            "restart": "no",
            "environment": {
                "CF_AGENT_WECHAT_TOKEN_FILE": token_worker_path,
            },
            "volumes": [{
                "type": "bind",
                "source": token_mount_source,
                "target": token_worker_path,
                "read_only": True,
                "bind": {"create_host_path": False},
            }],
        },
    },
}))
PY
          exit 0
        fi
        if [[ "$arguments" == *' --format json '* ]] && [ "$is_gateway" -eq 0 ]; then
          image="${AGENT_WECHAT_IMAGE:?}"
          container_name="${AGENT_WECHAT_CONTAINER_NAME:?}"
          proxy="${PROXY-}"
          rust_log="${RUST_LOG:?}"
          port="$(read_env_value "$env_file" AGENT_WECHAT_PORT)"
          runtime="${CF_AGENT_WECHAT_RUNTIME_ROOT:?}"
          token="${CF_AGENT_WECHAT_TOKEN_FILE:?}"
          restart_policy=no
          agent_host=0.0.0.0
          agent_port=6174
          agent_db_path=/data/agent.db
          health_interval=30s
          health_start_period=1m30s
          stop_grace_period=30s
          bad_bind_options=0
          process_override=0
          lifecycle_override=0
          [ ! -e "${STATE_DIR}/bad-compose-restart" ] ||
            restart_policy=unless-stopped
          [ ! -e "${STATE_DIR}/bad-compose-image" ] ||
            image="registry.example/attacker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          [ ! -e "${STATE_DIR}/bad-compose-container" ] ||
            container_name=wrong-agent-container
          [ ! -e "${STATE_DIR}/bad-compose-project" ] ||
            project_name=wrong-compose-project
          [ ! -e "${STATE_DIR}/bad-compose-proxy" ] ||
            proxy=http://wrong-proxy.invalid:8080
          [ ! -e "${STATE_DIR}/bad-compose-rust-log" ] ||
            rust_log=debug
          [ ! -e "${STATE_DIR}/bad-compose-environment" ] ||
            agent_host=127.0.0.1
          [ ! -e "${STATE_DIR}/bad-compose-health-interval" ] ||
            health_interval=5m
          [ ! -e "${STATE_DIR}/bad-compose-health-start-period" ] ||
            health_start_period=0s
          [ ! -e "${STATE_DIR}/bad-compose-stop-grace-period" ] ||
            stop_grace_period=5s
          [ ! -e "${STATE_DIR}/bad-compose-bind-options" ] ||
            bad_bind_options=1
          [ ! -e "${STATE_DIR}/bad-compose-process-override" ] ||
            process_override=1
          [ ! -e "${STATE_DIR}/bad-compose-lifecycle-override" ] ||
            lifecycle_override=1
          python3 - "$image" "$container_name" "$project_name" "$proxy" \
            "$rust_log" "$port" "$runtime" "$token" "$restart_policy" \
            "$agent_host" "$agent_port" "$agent_db_path" "$health_interval" \
            "$health_start_period" "$stop_grace_period" "$bad_bind_options" \
            "$process_override" "$lifecycle_override" <<'PY'
import json
import sys

(
    image,
    container_name,
    project_name,
    proxy,
    rust_log,
    port,
    runtime,
    token,
    restart_policy,
    agent_host,
    agent_port,
    agent_db_path,
    health_interval,
    health_start_period,
    stop_grace_period,
    bad_bind_options,
    process_override,
    lifecycle_override,
) = sys.argv[1:]

data_bind = {"create_host_path": False}
if bad_bind_options == "1":
    data_bind["propagation"] = "rshared"

service = {
    "image": image,
    "container_name": container_name,
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
        {
            "type": "bind",
            "source": runtime + "/data",
            "target": "/data",
            "bind": data_bind,
        },
        {
            "type": "bind",
            "source": runtime + "/wechat-home",
            "target": "/home/wechat",
            "bind": {"create_host_path": False},
        },
        {
            "type": "bind",
            "source": token,
            "target": "/data/auth-token",
            "read_only": True,
            "bind": {"create_host_path": False},
        },
    ],
    "environment": {
        "AGENT_HOST": agent_host,
        "AGENT_PORT": agent_port,
        "AGENT_DB_PATH": agent_db_path,
        "ENABLE_VNC": "0",
        "PROXY": proxy,
        "RUST_LOG": rust_log,
    },
    "healthcheck": {
        "test": [
            "CMD",
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "http://127.0.0.1:6174/health",
        ],
        "interval": health_interval,
        "timeout": "5s",
        "retries": 5,
        "start_period": health_start_period,
    },
    "logging": {
        "driver": "json-file",
        "options": {"max-size": "20m", "max-file": "3"},
    },
    "stop_grace_period": stop_grace_period,
    "networks": {"cf-internal": {"aliases": ["cf-agent-wechat"]}},
}
if process_override == "1":
    service["command"] = ["/bin/false"]
if lifecycle_override == "1":
    service["profiles"] = ["automatic"]

print(json.dumps({
    "name": project_name,
    "services": {"agent-wechat": service},
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
        elif [ "$service" = worker ]; then
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
