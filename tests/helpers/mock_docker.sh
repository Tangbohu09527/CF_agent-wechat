#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_DOCKER_STATE_DIR:?}"
: "${MOCK_DOCKER_LOG:?}"
: "${MOCK_DOCKER_MUTATION_LOG:?}"
: "${MOCK_APPROVED_AGENT_IMAGE:?}"
: "${MOCK_APPROVED_AGENT_CONTAINER:?}"
: "${MOCK_APPROVED_AGENT_PROJECT:?}"
: "${MOCK_APPROVED_STORAGE_ROOT:?}"
: "${MOCK_APPROVED_RUNTIME_ROOT:?}"
: "${MOCK_APPROVED_ARCHIVE_ROOT:?}"
: "${MOCK_APPROVED_TOKEN_FILE:?}"
: "${MOCK_APPROVED_BIND_IP:?}"
: "${MOCK_APPROVED_PORT:?}"

if [ -n "${MOCK_DOCKER_TRANSPORT_LOG:-}" ]; then
  {
    printf 'argv\0'
    printf '%s\0' "$@"
    printf 'environment\0'
    /usr/bin/env -0
  } >> "$MOCK_DOCKER_TRANSPORT_LOG"
fi

state_get() {
  local name="$1"
  local default_value="$2"
  if [ -f "${MOCK_DOCKER_STATE_DIR}/${name}" ]; then
    cat -- "${MOCK_DOCKER_STATE_DIR}/${name}"
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

require_agent_compose_environment() {
  [ "${AGENT_WECHAT_IMAGE:-}" = "$MOCK_APPROVED_AGENT_IMAGE" ] &&
    [ "${AGENT_WECHAT_BIND_IP:-}" = "$MOCK_APPROVED_BIND_IP" ] &&
    [ "${AGENT_WECHAT_PORT:-}" = "$MOCK_APPROVED_PORT" ] &&
    [ "${AGENT_WECHAT_CONTAINER_NAME:-}" = "$MOCK_APPROVED_AGENT_CONTAINER" ] &&
    [ "${COMPOSE_PROJECT_NAME:-}" = "$MOCK_APPROVED_AGENT_PROJECT" ] &&
    [ "${CF_AGENT_WECHAT_STORAGE_ROOT:-}" = "$MOCK_APPROVED_STORAGE_ROOT" ] &&
    [ "${CF_AGENT_WECHAT_RUNTIME_ROOT:-}" = "$MOCK_APPROVED_RUNTIME_ROOT" ] &&
    [ "${CF_AGENT_WECHAT_ARCHIVE_ROOT:-}" = "$MOCK_APPROVED_ARCHIVE_ROOT" ] &&
    [ "${PROXY+x}:${PROXY:-}" = "x:${MOCK_APPROVED_PROXY:-}" ] &&
    [ "${RUST_LOG:-}" = "${MOCK_APPROVED_RUST_LOG:-}" ] || {
      record 'agent compose clean environment invalid'
      exit 68
    }
  record 'agent compose clean environment verified'
}

print_container_inspect() {
  local identity actual_container actual_image actual_project actual_restart
  local actual_bind_ip actual_port actual_proxy actual_rust alias actual_image_id
  local actual_privileged actual_cap_add actual_security_opt actual_devices
  local actual_device_requests actual_pid_mode actual_ipc_mode actual_uts_mode
  local actual_userns_mode actual_cgroupns_mode actual_network_mode
  local actual_readonly_rootfs actual_auto_remove actual_propagation
  local actual_entrypoint actual_command actual_user actual_working_dir
  local actual_stop_signal actual_stop_timeout actual_healthcheck_test
  local actual_healthcheck_interval actual_healthcheck_timeout
  local actual_healthcheck_retries actual_healthcheck_start_period
  local actual_healthcheck_start_interval actual_restart_retry
  local actual_data_bind_source actual_home_bind_source actual_token_bind_source
  local actual_data_bind_mode actual_home_bind_mode actual_token_bind_mode
  local actual_log_driver actual_log_max_size actual_log_max_file
  local actual_data_mount_source actual_home_mount_source
  local actual_token_mount_source actual_data_mount_rw actual_home_mount_rw
  local actual_token_mount_rw

  identity="$(state_get actual_container_id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
  actual_container="$(state_get actual_container "$MOCK_APPROVED_AGENT_CONTAINER")"
  actual_image="$(state_get actual_image "$MOCK_APPROVED_AGENT_IMAGE")"
  actual_image_id="$(state_get actual_container_image_id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
  actual_project="$(state_get actual_project "$MOCK_APPROVED_AGENT_PROJECT")"
  actual_restart="$(state_get actual_restart no)"
  actual_bind_ip="$(state_get actual_bind_ip "$MOCK_APPROVED_BIND_IP")"
  actual_port="$(state_get actual_port "$MOCK_APPROVED_PORT")"
  actual_proxy="$(state_get actual_proxy "${MOCK_APPROVED_PROXY:-}")"
  actual_rust="$(state_get actual_rust "${MOCK_APPROVED_RUST_LOG:-}")"
  alias="$(state_get actual_network_alias cf-agent-wechat)"
  actual_privileged="$(state_get actual_privileged false)"
  actual_cap_add="$(state_get actual_cap_add '["SYS_PTRACE"]')"
  actual_security_opt="$(state_get actual_security_opt '["seccomp=unconfined"]')"
  actual_devices="$(state_get actual_devices '[]')"
  actual_pid_mode="$(state_get actual_pid_mode '')"
  actual_propagation="$(state_get actual_propagation rprivate)"
  actual_restart_retry="$(state_get actual_restart_retry 0)"
  actual_device_requests="$(state_get actual_device_requests '[]')"
  actual_ipc_mode="$(state_get actual_ipc_mode private)"
  actual_uts_mode="$(state_get actual_uts_mode '')"
  actual_userns_mode="$(state_get actual_userns_mode '')"
  actual_cgroupns_mode="$(state_get actual_cgroupns_mode private)"
  actual_network_mode="$(state_get actual_network_mode cf-internal)"
  actual_readonly_rootfs="$(state_get actual_readonly_rootfs false)"
  actual_auto_remove="$(state_get actual_auto_remove false)"
  actual_entrypoint="$(state_get actual_entrypoint '["/usr/bin/dumb-init","--"]')"
  actual_command="$(state_get actual_command '["/usr/bin/agent-wechat"]')"
  actual_user="$(state_get actual_user wechat)"
  actual_working_dir="$(state_get actual_working_dir /opt/agent-wechat)"
  actual_stop_signal="$(state_get actual_stop_signal SIGTERM)"
  actual_stop_timeout="$(state_get actual_stop_timeout 30)"
  actual_healthcheck_test="$(state_get actual_healthcheck_test '["CMD","curl","--fail","--silent","--show-error","http://127.0.0.1:6174/health"]')"
  actual_healthcheck_interval="$(state_get actual_healthcheck_interval 30000000000)"
  actual_healthcheck_timeout="$(state_get actual_healthcheck_timeout 5000000000)"
  actual_healthcheck_retries="$(state_get actual_healthcheck_retries 5)"
  actual_healthcheck_start_period="$(state_get actual_healthcheck_start_period 90000000000)"
  actual_healthcheck_start_interval="$(state_get actual_healthcheck_start_interval 0)"
  actual_data_bind_source="$(state_get actual_data_bind_source "$MOCK_APPROVED_RUNTIME_ROOT/data")"
  actual_home_bind_source="$(state_get actual_home_bind_source "$MOCK_APPROVED_RUNTIME_ROOT/wechat-home")"
  actual_token_bind_source="$(state_get actual_token_bind_source "$MOCK_APPROVED_TOKEN_FILE")"
  actual_data_bind_mode="$(state_get actual_data_bind_mode rw)"
  actual_home_bind_mode="$(state_get actual_home_bind_mode rw)"
  actual_token_bind_mode="$(state_get actual_token_bind_mode ro)"
  actual_log_driver="$(state_get actual_log_driver json-file)"
  actual_log_max_size="$(state_get actual_log_max_size 20m)"
  actual_log_max_file="$(state_get actual_log_max_file 3)"
  actual_data_mount_source="$(state_get actual_data_mount_source "$MOCK_APPROVED_RUNTIME_ROOT/data")"
  actual_home_mount_source="$(state_get actual_home_mount_source "$MOCK_APPROVED_RUNTIME_ROOT/wechat-home")"
  actual_token_mount_source="$(state_get actual_token_mount_source "$MOCK_APPROVED_TOKEN_FILE")"
  actual_data_mount_rw="$(state_get actual_data_mount_rw true)"
  actual_home_mount_rw="$(state_get actual_home_mount_rw true)"
  actual_token_mount_rw="$(state_get actual_token_mount_rw false)"

  printf '[{"Id":"%s","Image":"%s","Name":"/%s",' \
    "$identity" "$actual_image_id" "$actual_container"
  if [ "$(state_get actual_inspect_contains_token 0)" = 1 ]; then
    printf '"FixtureOpaque":"'
    tr -d '\n' < "$MOCK_APPROVED_TOKEN_FILE"
    printf '",'
  fi
  printf '"Config":{"Image":"%s",' "$actual_image"
  printf '"Entrypoint":%s,"Cmd":%s,"User":"%s",' \
    "$actual_entrypoint" "$actual_command" "$actual_user"
  printf '"WorkingDir":"%s","StopSignal":"%s","StopTimeout":%s,' \
    "$actual_working_dir" "$actual_stop_signal" "$actual_stop_timeout"
  printf '"Healthcheck":{"Test":%s,"Interval":%s,"Timeout":%s,' \
    "$actual_healthcheck_test" "$actual_healthcheck_interval" \
    "$actual_healthcheck_timeout"
  printf '"Retries":%s,"StartPeriod":%s,"StartInterval":%s},' \
    "$actual_healthcheck_retries" "$actual_healthcheck_start_period" \
    "$actual_healthcheck_start_interval"
  printf '"Labels":{"com.docker.compose.project":"%s","com.docker.compose.service":"agent-wechat"},' "$actual_project"
  printf '"Env":["PATH=/usr/local/bin:/usr/bin","AGENT_HOST=0.0.0.0","AGENT_PORT=6174","AGENT_DB_PATH=/data/agent.db","ENABLE_VNC=0","PROXY=%s","RUST_LOG=%s"' "$actual_proxy" "$actual_rust"
  if [ "$(state_get actual_extra_environment 0)" = 1 ]; then
    printf ',"UNAPPROVED=1"'
  fi
  printf ']},'
  printf '"HostConfig":{"Privileged":%s,"CapAdd":%s,"SecurityOpt":%s,' \
    "$actual_privileged" "$actual_cap_add" "$actual_security_opt"
  printf '"Devices":%s,"DeviceRequests":%s,"PidMode":"%s",' \
    "$actual_devices" "$actual_device_requests" "$actual_pid_mode"
  printf '"IpcMode":"%s","UTSMode":"%s","UsernsMode":"%s","CgroupnsMode":"%s",' \
    "$actual_ipc_mode" "$actual_uts_mode" "$actual_userns_mode" \
    "$actual_cgroupns_mode"
  printf '"NetworkMode":"%s","ReadonlyRootfs":%s,"AutoRemove":%s,' \
    "$actual_network_mode" "$actual_readonly_rootfs" "$actual_auto_remove"
  printf '"RestartPolicy":{"Name":"%s","MaximumRetryCount":%s},' \
    "$actual_restart" "$actual_restart_retry"
  printf '"Binds":["%s:/data:%s","%s:/home/wechat:%s","%s:/data/auth-token:%s"' \
    "$actual_data_bind_source" "$actual_data_bind_mode" \
    "$actual_home_bind_source" "$actual_home_bind_mode" \
    "$actual_token_bind_source" "$actual_token_bind_mode"
  if [ "$(state_get actual_extra_bind 0)" = 1 ]; then
    printf ',"/tmp/attacker:/escape:rw"'
  fi
  printf '],"LogConfig":{"Type":"%s","Config":{"max-size":"%s","max-file":"%s"}},' \
    "$actual_log_driver" "$actual_log_max_size" "$actual_log_max_file"
  printf '"PortBindings":{"6174/tcp":[{"HostIp":"%s","HostPort":"%s"}]' "$actual_bind_ip" "$actual_port"
  if [ "$(state_get actual_extra_port 0)" = 1 ]; then
    printf ',"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]'
  fi
  printf '}},'
  printf '"NetworkSettings":{"Ports":{"6174/tcp":[{"HostIp":"%s","HostPort":"%s"}]' "$actual_bind_ip" "$actual_port"
  if [ "$(state_get actual_extra_port 0)" = 1 ]; then
    printf ',"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]'
  fi
  printf '},"Networks":{"cf-internal":{"Aliases":["%s","%s","agent-wechat","%s","%s"]}' "$alias" "$actual_container" "$identity" "${identity:0:12}"
  if [ "$(state_get actual_extra_network 0)" = 1 ]; then
    printf ',"attacker-network":{"Aliases":["attacker"]}'
  fi
  printf '}},'
  printf '"Mounts":['
  printf '{"Type":"bind","Source":"%s","Destination":"/data","RW":%s,"Propagation":"%s"},' "$actual_data_mount_source" "$actual_data_mount_rw" "$actual_propagation"
  printf '{"Type":"bind","Source":"%s","Destination":"/home/wechat","RW":%s,"Propagation":"%s"},' "$actual_home_mount_source" "$actual_home_mount_rw" "$actual_propagation"
  printf '{"Type":"bind","Source":"%s","Destination":"/data/auth-token","RW":%s,"Propagation":"%s"}' "$actual_token_mount_source" "$actual_token_mount_rw" "$actual_propagation"
  printf ']}]\n'
}

print_image_inspect() {
  local image_id repo_digest image_entrypoint image_command image_user
  local image_working_dir image_stop_signal

  image_id="$(state_get actual_image_id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)"
  repo_digest="$(state_get actual_repo_digest "$MOCK_APPROVED_AGENT_IMAGE")"
  image_entrypoint="$(state_get image_entrypoint '["/usr/bin/dumb-init","--"]')"
  image_command="$(state_get image_command '["/usr/bin/agent-wechat"]')"
  image_user="$(state_get image_user wechat)"
  image_working_dir="$(state_get image_working_dir /opt/agent-wechat)"
  image_stop_signal="$(state_get image_stop_signal SIGTERM)"

  printf '[{"Id":"%s","RepoDigests":["%s"],"Config":{' \
    "$image_id" "$repo_digest"
  if [ "$(state_get image_inspect_contains_token 0)" = 1 ]; then
    printf '"FixtureOpaque":"'
    tr -d '\n' < "$MOCK_APPROVED_TOKEN_FILE"
    printf '",'
  fi
  printf '"Entrypoint":%s,"Cmd":%s,"User":"%s",' \
    "$image_entrypoint" "$image_command" "$image_user"
  printf '"WorkingDir":"%s","StopSignal":"%s",' \
    "$image_working_dir" "$image_stop_signal"
  printf '"Env":["PATH=/usr/local/bin:/usr/bin"]}}]\n'
}

print_gateway_worker_inspect() {
  local project service pointer source destination read_write

  project="$(state_get gateway_actual_project cf-agent-gateway)"
  service="$(state_get gateway_actual_service worker)"
  pointer="$(state_get gateway_actual_token_pointer /run/secrets/cf-agent-wechat-auth-token)"
  source="$(state_get gateway_actual_token_source "$MOCK_APPROVED_TOKEN_FILE")"
  destination="$(state_get gateway_actual_token_destination /run/secrets/cf-agent-wechat-auth-token)"
  read_write="$(state_get gateway_actual_token_rw false)"

  printf '[{"Config":{"Labels":{'
  printf '"com.docker.compose.project":"%s",' "$project"
  printf '"com.docker.compose.service":"%s"},' "$service"
  printf '"Env":["PATH=/usr/local/bin:/usr/bin"'
  printf ',"CF_AGENT_WECHAT_TOKEN_FILE=%s"' "$pointer"
  if [ "$(state_get gateway_actual_plaintext_token 0)" = 1 ]; then
    printf ',"CF_AGENT_WECHAT_TOKEN='
    tr -d '\n' < "$MOCK_APPROVED_TOKEN_FILE"
    printf '"'
  fi
  printf ']},'
  printf '"HostConfig":{"Tmpfs":{},"Devices":[]},'
  printf '"Mounts":[{"Type":"bind","Source":"%s",' "$source"
  printf '"Destination":"%s","RW":%s}]}]\n' "$destination" "$read_write"
}

case "${1:-}" in
  info)
    record 'docker info'
    case "$*" in
      *LiveRestoreEnabled*) state_get live_restore false; printf '\n' ;;
      *SecurityOptions*)
        if [ "$(state_get docker_rootless 0)" = 1 ]; then
          printf '%s\n' '["name=rootless"]'
        else
          printf '%s\n' '["name=seccomp,profile=default","name=cgroupns"]'
        fi
        ;;
    esac
    exit 0
    ;;
  context)
    record 'docker context'
    case "${2:-}" in
      show) state_get docker_context default; printf '\n' ;;
      inspect) state_get docker_endpoint "unix://${MOCK_APPROVED_DOCKER_SOCKET:-/var/run/docker.sock}"; printf '\n' ;;
      *) exit 64 ;;
    esac
    exit 0
    ;;
  network)
    record 'docker network inspect'
    [ "${2:-}" = inspect ] || exit 64
    printf '%s\n' "$(state_get network_contract 'cf-internal|bridge|local')"
    exit 0
    ;;
  image)
    record 'docker image inspect'
    [ "${2:-}" = inspect ] || exit 64
    [ "${3:-}" = "$MOCK_APPROVED_AGENT_IMAGE" ] || exit 65
    print_image_inspect
    exit 0
    ;;
  exec)
    record 'docker exec wechat-process-check'
    process_script="${5:-}"
    require_process_contract_fragment "$process_script" 'readlink -f /usr/bin/wechat'
    require_process_contract_fragment "$process_script" 'case "$launcher_real" in'
    require_process_contract_fragment "$process_script" 'proc_exe="$(readlink "$process_dir/exe"'
    require_process_contract_fragment "$process_script" '[ "$proc_exe" = "$launcher_real" ] || continue'
    require_process_contract_fragment "$process_script" 'printf "%s:%s\n" "$process_id" "$start_time"'
    [ "$(state_get wechat_launcher_resolves 1)" = 1 ] || exit 1
    launcher_real="$(state_get wechat_launcher_real /opt/wechat/wechat)"
    case "$launcher_real" in /*) ;; *) exit 1 ;; esac
    proc_exe="$(state_get wechat_proc_exe /opt/wechat/wechat)"
    [ "$proc_exe" = "$launcher_real" ] || exit 1
    calls="$(state_get wechat_calls 0)"
    calls=$((calls + 1))
    state_set wechat_calls "$calls"
    case "$(state_get wechat_mode stable)" in
      stable) printf '%s\n' '4242:9001' ;;
      missing) exit 1 ;;
      disappear)
        [ "$calls" -eq 1 ] || exit 1
        printf '%s\n' '4242:9001'
        ;;
      unstable) printf '4242:%s\n' "$calls" ;;
      change_on_final_check)
        if [ "$calls" -le 5 ]; then printf '%s\n' '4242:9001'; else printf '%s\n' '5252:9002'; fi
        ;;
      same_pid_new_start_on_final_check)
        if [ "$calls" -le 5 ]; then printf '%s\n' '4242:9001'; else printf '%s\n' '4242:9002'; fi
        ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
  inspect)
    record 'docker inspect'
    case "$*" in
      *'.State.Health'*)
        target="${*: -1}"
        if [ "$target" = gateway-worker-fixture ]; then
          state_get worker_health healthy
        else
          state_get container_health healthy
        fi
        printf '\n'
        ;;
      *'{{.State.Running}}'*)
        if [ "$(state_get agent_running 1)" = 1 ]; then printf '%s\n' true; else printf '%s\n' false; fi
        ;;
      *)
        target="${*: -1}"
        if [ "$target" = gateway-worker-fixture ]; then
          print_gateway_worker_inspect
        else
          print_container_inspect
        fi
        ;;
    esac
    exit 0
    ;;
  compose) ;;
  *)
    record 'docker unsupported'
    exit 64
    ;;
esac

shift
if [ "${1:-}" = version ]; then
  record 'docker compose version'
  [ "${2:-}" = --short ] || exit 64
  printf '%s\n' "$(state_get compose_version v2.29.0)"
  exit 0
fi

compose_file=''
compose_env_file=''
compose_project_directory=''
compose_project_name=''
compose_profile=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file) compose_env_file="$2"; shift 2 ;;
    --project-directory) compose_project_directory="$2"; shift 2 ;;
    --project-name) compose_project_name="$2"; shift 2 ;;
    --profile) compose_profile="$2"; shift 2 ;;
    -f) compose_file="$2"; shift 2 ;;
    *) break ;;
  esac
done

command_name="${1:-}"
[ -n "$command_name" ] || exit 64
shift
snapshot_file="${MOCK_DOCKER_STATE_DIR}/compose-stdin.$$"
[ "$compose_file" = - ] || {
  record 'compose invocation did not use a bound stdin snapshot'
  exit 67
}
cat > "$snapshot_file"
case "$compose_project_name" in
  cf-agent-gateway)
    compose_kind=gateway
    approved_snapshot="${MOCK_DOCKER_STATE_DIR}/approved-gateway-compose"
    if [ ! -f "$approved_snapshot" ]; then
      cp -- "${MOCK_GATEWAY_COMPOSE_FILE:?}" "$approved_snapshot"
    fi
    cmp -s -- "$snapshot_file" "$approved_snapshot" &&
      [ "$compose_env_file" = "${MOCK_GATEWAY_ENV_FILE:?}" ] &&
      [ "$compose_project_directory" = "${MOCK_GATEWAY_PROJECT_DIR:?}" ] &&
      [ "$compose_profile" = worker ] || {
        rm -f -- "$snapshot_file"
        record 'gateway compose invocation invalid'
        exit 67
      }
    record 'gateway compose env-file verified'
    record 'gateway compose invocation verified'
    ;;
  "$MOCK_APPROVED_AGENT_PROJECT")
    compose_kind=agent
    approved_snapshot="${MOCK_DOCKER_STATE_DIR}/approved-agent-compose"
    if [ ! -f "$approved_snapshot" ]; then
      cp -- "${MOCK_AGENT_COMPOSE_FILE:?}" "$approved_snapshot"
    fi
    cmp -s -- "$snapshot_file" "$approved_snapshot" &&
      [ "$compose_env_file" = /dev/null ] &&
      [ "$compose_project_directory" = "${MOCK_AGENT_PROJECT_DIR:?}" ] &&
      [ -z "$compose_profile" ] || {
        rm -f -- "$snapshot_file"
        record 'agent compose invocation invalid'
        exit 67
      }
    require_agent_compose_environment
    record 'agent compose env-file verified'
    record 'agent compose invocation verified'
    ;;
  *) rm -f -- "$snapshot_file"; exit 67 ;;
esac
rm -f -- "$snapshot_file"

case "$command_name" in
  config)
    record "$compose_kind compose config"
    if [ "$compose_kind" = agent ] &&
      [ "$(state_get mutate_agent_compose_after_config 0)" = 1 ] &&
      [ "$(state_get agent_compose_mutated 0)" = 0 ]; then
      printf '%s\n' \
        'services: {attacker: {image: attacker.invalid/latest}}' \
        > "${MOCK_AGENT_COMPOSE_FILE:?}"
      state_set agent_compose_mutated 1
    fi
    if [ "$compose_kind" = agent ] && [ "$*" = '--format json' ]; then
      rendered_project="$(state_get rendered_project "$MOCK_APPROVED_AGENT_PROJECT")"
      rendered_container="$(state_get rendered_container "$MOCK_APPROVED_AGENT_CONTAINER")"
      rendered_image="$(state_get rendered_image "$MOCK_APPROVED_AGENT_IMAGE")"
      rendered_restart="$(state_get rendered_restart no)"
      rendered_proxy="$(state_get rendered_proxy "${MOCK_APPROVED_PROXY:-}")"
      rendered_rust="$(state_get rendered_rust "${MOCK_APPROVED_RUST_LOG:-}")"
      rendered_stop_grace_period="$(state_get rendered_stop_grace_period 30s)"
      rendered_create_host_path="$(state_get rendered_create_host_path false)"
      printf '{"name":"%s","services":{"agent-wechat":{' "$rendered_project"
      printf '"image":"%s","container_name":"%s","restart":"%s",' "$rendered_image" "$rendered_container" "$rendered_restart"
      if [ "$(state_get rendered_entrypoint 0)" = 1 ]; then
        printf '"entrypoint":["/bin/sh"],'
      fi
      if [ "$(state_get rendered_command 0)" = 1 ]; then
        printf '"command":["sleep","infinity"],'
      fi
      if [ "$(state_get rendered_user 0)" = 1 ]; then
        printf '"user":"root",'
      fi
      if [ "$(state_get rendered_working_dir 0)" = 1 ]; then
        printf '"working_dir":"/tmp",'
      fi
      if [ "$(state_get rendered_post_start 0)" = 1 ]; then
        printf '"post_start":[{"command":"/bin/true"}],'
      fi
      if [ "$(state_get rendered_pre_stop 0)" = 1 ]; then
        printf '"pre_stop":[{"command":"/bin/true"}],'
      fi
      printf '"ports":[{"target":6174,"published":"%s","host_ip":"%s","protocol":"tcp"}],' "$MOCK_APPROVED_PORT" "$MOCK_APPROVED_BIND_IP"
      printf '"networks":{"cf-internal":{"aliases":["cf-agent-wechat"]}},'
      printf '"environment":{"AGENT_HOST":"0.0.0.0","AGENT_PORT":"6174","AGENT_DB_PATH":"/data/agent.db","ENABLE_VNC":"0","PROXY":"%s","RUST_LOG":"%s"},' "$rendered_proxy" "$rendered_rust"
      printf '"healthcheck":{"test":["CMD","curl","--fail","--silent","--show-error","http://127.0.0.1:6174/health"],"interval":"30s","timeout":"5s","retries":5,"start_period":"1m30s"},'
      printf '"security_opt":["seccomp=unconfined"],"cap_add":["SYS_PTRACE"],'
      printf '"logging":{"driver":"json-file","options":{"max-size":"20m","max-file":"3"}},'
      printf '"stop_grace_period":"%s",' "$rendered_stop_grace_period"
      printf '"volumes":['
      printf '{"type":"bind","source":"%s/data","target":"/data","read_only":false,"bind":{"create_host_path":%s}},' "$MOCK_APPROVED_RUNTIME_ROOT" "$rendered_create_host_path"
      printf '{"type":"bind","source":"%s/wechat-home","target":"/home/wechat","read_only":false,"bind":{"create_host_path":%s}},' "$MOCK_APPROVED_RUNTIME_ROOT" "$rendered_create_host_path"
      printf '{"type":"bind","source":"%s","target":"/data/auth-token","read_only":true,"bind":{"create_host_path":%s}}' "$MOCK_APPROVED_TOKEN_FILE" "$rendered_create_host_path"
      printf ']}} ,"networks":{"cf-internal":{"external":true,"name":"cf-internal"}}}\n'
    elif [ "$compose_kind" = gateway ] && [ "$*" = '--format json' ]; then
      gateway_project="$(state_get gateway_rendered_project cf-agent-gateway)"
      gateway_service="$(state_get gateway_rendered_service worker)"
      gateway_pointer="$(state_get gateway_rendered_token_pointer /run/secrets/cf-agent-wechat-auth-token)"
      gateway_source="$(state_get gateway_rendered_token_source "$MOCK_APPROVED_TOKEN_FILE")"
      gateway_target="$(state_get gateway_rendered_token_target /run/secrets/cf-agent-wechat-auth-token)"
      gateway_read_only="$(state_get gateway_rendered_token_read_only true)"

      printf '{"name":"%s","services":{"%s":{"environment":{' \
        "$gateway_project" "$gateway_service"
      printf '"CF_AGENT_WECHAT_TOKEN_FILE":"%s"' "$gateway_pointer"
      if [ "$(state_get gateway_rendered_plaintext_token 0)" = 1 ]; then
        printf ',"CF_AGENT_WECHAT_TOKEN":"'
        tr -d '\n' < "$MOCK_APPROVED_TOKEN_FILE"
        printf '"'
      fi
      printf '},"volumes":[{"type":"bind","source":"%s",' "$gateway_source"
      printf '"target":"%s","read_only":%s}]}}}\n' \
        "$gateway_target" "$gateway_read_only"
    elif [ "$compose_kind" = gateway ] && printf '%s\n' "$@" | grep -qx -- '--services'; then
      printf '%s\n' worker
    fi
    ;;
  ps)
    record "$compose_kind compose ps"
    service="${*: -1}"
    if [ "$compose_kind" = gateway ]; then
      [ "$service" = worker ] || exit 65
      if [ "$(state_get gateway_ps_error 0)" = 1 ]; then record 'gateway compose ps error'; exit 70; fi
      if [ "$(state_get gateway_running 1)" = 1 ]; then
        printf '%s\n' gateway-worker-fixture
      fi
    else
      [ "$service" = agent-wechat ] || exit 65
      if [ "$(state_get agent_ps_error 0)" = 1 ]; then record 'agent compose ps error'; exit 70; fi
      case " $* " in
        *' --all '*)
          if [ "$(state_get agent_exists 1)" = 1 ]; then
            printf '%s\n' agent-container-fixture
          fi
          ;;
        *)
          if [ "$(state_get agent_running 1)" = 1 ]; then
            printf '%s\n' agent-container-fixture
          fi
          ;;
      esac
    fi
    ;;
  stop)
    if [ "$compose_kind" = gateway ]; then
      [ "${*: -1}" = worker ] || exit 65
      if [ "$(state_get gateway_started_once 0)" = 1 ]; then
        remaining_failures="$(
          state_get gateway_cleanup_stop_failures 0
        )"
        if [ "$remaining_failures" -gt 0 ]; then
          state_set gateway_cleanup_stop_failures +            "$((remaining_failures - 1))"
          mutate 'gateway worker stop failed'
          exit 76
        fi
      fi
      mutate 'gateway worker stop'
      state_set gateway_running 0
    else
      [ "${*: -1}" = agent-wechat ] || exit 65
      if [ "$(state_get agent_started_once 0)" = 1 ] && [ "$(state_get agent_cleanup_stop_error 0)" = 1 ]; then
        state_set agent_running 0
        record 'agent container cleanup stop failed'
        exit 73
      fi
      mutate 'agent container stop'
      state_set agent_running 0
    fi
    ;;
  rm)
    [ "$compose_kind" = agent ] && [ "${*: -1}" = agent-wechat ] || exit 65
    if [ "$(state_get agent_started_once 0)" = 1 ] && [ "$(state_get agent_cleanup_remove_error 0)" = 1 ]; then
      record 'agent container cleanup remove failed'
      exit 74
    fi
    mutate 'agent container remove'
    state_set agent_exists 0
    state_set agent_running 0
    ;;
  up)
    if [ "$compose_kind" = gateway ]; then
      [ "${*: -1}" = worker ] || exit 65
      if [ "$(state_get gateway_start_error 0)" = 1 ]; then record 'gateway worker start failed'; exit 75; fi
      mutate 'gateway worker start'
      state_set gateway_running 1
      state_set gateway_started_once 1
    else
      [ "${*: -1}" = agent-wechat ] || exit 65
      mutate 'agent container start'
      state_set agent_exists 1
      state_set agent_running 1
      state_set agent_started_once 1
      state_set wechat_calls 0
      printf '%s\n' logged_out > "${MOCK_AUTH_STATE_FILE:?}"
      printf '%s\n' 'agent runtime evidence' > "$MOCK_APPROVED_RUNTIME_ROOT/data/agent-runtime.log"
    fi
    ;;
  down)
    mutate 'forbidden compose down'
    exit 66
    ;;
  *)
    record "$compose_kind compose unsupported"
    exit 64
    ;;
esac
