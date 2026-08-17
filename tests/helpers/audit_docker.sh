#!/usr/bin/env bash
set -euo pipefail

: "${CF_AUDIT_LOG:?}"
: "${CF_AUDIT_REAL_DOCKER:?}"

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
      for argument in "$@"; do
        if [ "$argument" = "ps" ]; then
          compose_command="ps"
          break
        fi
      done
      if [ "$compose_command" != "ps" ]; then
        printf '%s\n' 'unexpected runtime Compose command' >&2
        exit 64
      fi
      service="${*: -1}"
      case "$service" in
        agent-wechat|wechat-worker)
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
