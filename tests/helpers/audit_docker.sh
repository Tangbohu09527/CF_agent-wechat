#!/usr/bin/env bash
set -euo pipefail

: "${CF_AUDIT_LOG:?}"
: "${CF_AUDIT_REAL_DOCKER:?}"

require_process_contract_fragment() {
  case "$1" in
    *"$2"*) ;;
    *)
      printf '%s\n' 'wechat process identity contract mismatch' >&2
      exit 65
      ;;
  esac
}

if [ "${1:-}" = "inspect" ]; then
  printf 'docker\tinspect\n' >> "$CF_AUDIT_LOG"
  if [ "${CF_AUDIT_DOCKER_MODE:-}" = "nonpermission" ]; then
    printf 'Error: No such object\n' >&2
    exit 1
  fi
fi

if [ "${CF_AUDIT_DOCKER_RUNTIME_MOCK:-}" = "1" ]; then
  case "${1:-}" in
    info|compose|exec|inspect)
      if [ "${CF_AUDIT_DOCKER_VIA_SUDO:-0}" != "1" ]; then
        printf '%s\n' \
          'permission denied while connecting to docker.sock' >&2
        exit 1
      fi
      ;;
  esac

  case "${1:-}" in
    info)
      exit 0
      ;;
    compose)
      compose_command=""
      compose_env_file=""
      expect_env_file=0
      for argument in "$@"; do
        if [ "$expect_env_file" -eq 1 ]; then
          compose_env_file="$argument"
          expect_env_file=0
          continue
        fi
        if [ "$argument" = "--env-file" ]; then
          expect_env_file=1
          continue
        fi
        case "$argument" in
          ps|stop|rm) compose_command="$argument" ;;
        esac
      done
      if [ -z "$compose_command" ]; then
        printf '%s\n' 'unexpected runtime Compose command' >&2
        exit 64
      fi
      service="${*: -1}"
      case "$service" in
        agent-wechat)
          if [ "$compose_env_file" != "${CF_AUDIT_AGENT_ENV_FILE:?}" ]; then
            printf '%s\n' 'agent-wechat env-file argument mismatch' >&2
            exit 67
          fi
          agent_state="running"
          if [ -n "${CF_AUDIT_AGENT_STATE_FILE:-}" ] &&
            [ -f "$CF_AUDIT_AGENT_STATE_FILE" ]; then
            agent_state="$(cat -- "$CF_AUDIT_AGENT_STATE_FILE")"
          fi
          case "$compose_command" in
            ps)
              if printf '%s\n' "$@" | grep -qx -- '--all'; then
                [ "$agent_state" = "absent" ] ||
                  printf 'runtime-fixture-%s\n' "$service"
              elif [ "$agent_state" = "running" ]; then
                printf 'runtime-fixture-%s\n' "$service"
              fi
              ;;
            stop)
              printf 'docker\tcompose-agent-stop\n' >> "$CF_AUDIT_LOG"
              [ -n "${CF_AUDIT_AGENT_STATE_FILE:-}" ] ||
                exit 68
              printf '%s\n' 'stopped' > "$CF_AUDIT_AGENT_STATE_FILE"
              ;;
            rm)
              if printf '%s\n' "$@" |
                grep -Eqx -- '-v|--volumes'; then
                printf '%s\n' 'volume removal is forbidden' >&2
                exit 69
              fi
              printf 'docker\tcompose-agent-remove\n' >> "$CF_AUDIT_LOG"
              [ -n "${CF_AUDIT_AGENT_STATE_FILE:-}" ] ||
                exit 68
              printf '%s\n' 'absent' > "$CF_AUDIT_AGENT_STATE_FILE"
              ;;
          esac
          exit 0
          ;;
        wechat-worker)
          [ "$compose_command" = "ps" ] || exit 64
          if [ "$compose_env_file" != "${CF_AUDIT_GATEWAY_ENV_FILE:?}" ]; then
            printf '%s\n' 'Gateway env-file argument mismatch' >&2
            exit 67
          fi
          printf 'runtime-fixture-%s\n' "$service"
          exit 0
          ;;
        *)
          printf '%s\n' 'unexpected runtime Compose service' >&2
          exit 65
          ;;
      esac
      ;;
    exec)
      process_script="${5:-}"
      require_process_contract_fragment "$process_script" 'readlink -f /usr/bin/wechat'
      require_process_contract_fragment "$process_script" 'case "$launcher_real" in'
      require_process_contract_fragment "$process_script" 'proc_exe="$(readlink "$process_dir/exe"'
      require_process_contract_fragment "$process_script" '[ "$proc_exe" = "$launcher_real" ] || continue'
      require_process_contract_fragment "$process_script" 'printf "%s:%s\n" "$process_id" "$start_time"'
      printf '%s\n' '4242:9001'
      exit 0
      ;;
    inspect)
      if printf '%s\n' "$@" | grep -q '{{.State.Running}}'; then
        printf '%s\n' 'true'
      else
        runtime_root="${CF_AGENT_WECHAT_RUNTIME_ROOT:-/srv/storage/cf-agent-wechat/runtime}"
        printf '[{"Mounts":['
        printf '{"Source":"%s/data","Destination":"/data","RW":true},' \
          "$runtime_root"
        printf '{"Source":"%s/wechat-home","Destination":"/home/wechat","RW":true},' \
          "$runtime_root"
        token_source="${TOKEN_FILE:-/srv/storage/cf-agent-wechat/secrets/auth-token}"
        printf '{"Source":"%s",' "$token_source"
        printf '%s\n' '"Destination":"/data/auth-token","RW":false}]}]'
      fi
      exit 0
      ;;
  esac
fi

exec "$CF_AUDIT_REAL_DOCKER" "$@"
