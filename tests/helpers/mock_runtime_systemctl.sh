#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_DOCKER_STATE_DIR:?}"

state_get() {
  local name="$1"
  local default_value="$2"

  if [ -f "${MOCK_DOCKER_STATE_DIR}/${name}" ]; then
    cat -- "${MOCK_DOCKER_STATE_DIR}/${name}"
  else
    printf '%s' "$default_value"
  fi
}

case "${1:-}" in
  is-system-running)
    if [ "$(state_get systemd_partial_timeout 0)" = 1 ]; then
      printf '%s\n' running
      sleep 30
    fi
    value="$(state_get systemd_state running)"
    printf '%s\n' "$value"
    case "$value" in
      running) exit 0 ;;
      degraded) exit 1 ;;
      *) exit 2 ;;
    esac
    ;;
  is-active)
    case "${2:-}" in
      docker.service)
        value="$(state_get docker_service_state active)"
        printf '%s\n' "$value"
        [ "$value" = active ]
        ;;
      cf-agent-wechat.service)
        if [ "$(state_get agent_activity_partial_timeout 0)" = 1 ]; then
          printf '%s\n' inactive
          sleep 30
        fi
        value="$(state_get agent_unit_activity inactive)"
        printf '%s\n' "$value"
        case "$value" in
          active|activating|reloading|deactivating) exit 0 ;;
          inactive|failed) exit 3 ;;
          *) exit 4 ;;
        esac
        ;;
      *) exit 2 ;;
    esac
    ;;
  list-units)
    printf '%s\n' 'docker.service loaded active running Docker'
    [ "$(state_get agent_unit_active 0)" != 1 ] ||
      printf '%s\n' 'cf-agent-wechat.service loaded active running Agent'
    [ "$(state_get indirect_agent_unit_active 0)" != 1 ] ||
      printf '%s\n' 'custom-maintenance.service loaded active running Maintenance'
    [ "$(state_get generic_timer_active 0)" != 1 ] ||
      printf '%s\n' 'nightly.timer loaded active waiting Timer'
    [ "$(state_get explicit_path_active 0)" != 1 ] ||
      printf '%s\n' 'watched.path loaded active waiting Path'
    [ "$(state_get explicit_socket_active 0)" != 1 ] ||
      printf '%s\n' 'wakeup.socket loaded active listening Socket'
    [ "$(state_get target_wants_active 0)" != 1 ] ||
      printf '%s\n' 'boot-maintenance.target loaded active active Target'
    ;;
  is-enabled)
    [ "${2:-}" = cf-agent-wechat.service ] || exit 2
    if [ "$(state_get agent_enablement_partial_timeout 0)" = 1 ]; then
      printf '%s\n' disabled
      sleep 30
    fi
    if [ "$(state_get agent_unit_enablement_error 0)" = 1 ]; then
      exit 2
    fi
    if [ "$(state_get agent_unit_enabled 0)" = 1 ]; then
      printf '%s\n' enabled
      exit 0
    fi
    printf '%s\n' disabled
    exit 1
    ;;
  list-unit-files)
    printf '%s\n' 'docker.service enabled'
    [ "$(state_get alternate_agent_unit_enabled 0)" != 1 ] ||
      printf '%s\n' 'custom-agent-wechat-restore.service enabled'
    [ "$(state_get indirect_agent_unit_enabled 0)" != 1 ] ||
      printf '%s\n' 'custom-maintenance.service enabled'
    [ "$(state_get generic_timer_enabled 0)" != 1 ] ||
      printf '%s\n' 'nightly.timer enabled'
    [ "$(state_get explicit_timer_enabled 0)" != 1 ] ||
      printf '%s\n' 'scheduled.timer enabled-runtime'
    [ "$(state_get explicit_path_enabled 0)" != 1 ] ||
      printf '%s\n' 'watched.path enabled'
    [ "$(state_get default_path_enabled 0)" != 1 ] ||
      printf '%s\n' 'default-watch.path linked'
    [ "$(state_get explicit_socket_enabled 0)" != 1 ] ||
      printf '%s\n' 'wakeup.socket enabled'
    [ "$(state_get default_socket_enabled 0)" != 1 ] ||
      printf '%s\n' 'default-wakeup.socket enabled'
    [ "$(state_get target_wants_enabled 0)" != 1 ] ||
      printf '%s\n' 'boot-maintenance.target enabled'
    [ "$(state_get target_requires_enabled 0)" != 1 ] ||
      printf '%s\n' 'required-maintenance.target alias'
    [ "$(state_get malformed_activation_target 0)" != 1 ] ||
      printf '%s\n' 'malformed.timer enabled'
    [ "$(state_get unknown_activation_target 0)" != 1 ] ||
      printf '%s\n' 'unknown.path enabled'
    [ "$(state_get activation_show_failure 0)" != 1 ] ||
      printf '%s\n' 'opaque.socket enabled'
    [ "$(state_get templated_socket_enabled 0)" != 1 ] ||
      printf '%s\n' 'templated.socket enabled'
    ;;
  cat)
    unit="${2:-}"
    if [ "$(state_get unreadable_unit_definition 0)" = 1 ]; then
      exit 1
    fi
    case "$unit" in
      docker.service)
        printf '%s\n' '[Service]' 'ExecStart=/usr/bin/dockerd'
        ;;
      custom-maintenance.service|nightly.service|runtime-wakeup.service|\
      default-watch.service|default-wakeup.service)
        printf '%s\n' \
          '[Service]' \
          "ExecStart=/usr/bin/docker compose -f ${MOCK_AGENT_COMPOSE_FILE:?} up -d"
        ;;
      safe-helper.service)
        printf '%s\n' '[Service]' 'ExecStart=/usr/bin/true'
        ;;
      nightly.timer)
        printf '%s\n' \
          '[Timer]' \
          'OnCalendar=*-*-* 01:00:00'
        ;;
      scheduled.timer)
        printf '%s\n' \
          '[Timer]' \
          'OnCalendar=*-*-* 01:00:00' \
          'Unit=runtime-wakeup.service'
        ;;
      malformed.timer)
        printf '%s\n' '[Timer]' 'OnCalendar=*-*-* 01:00:00'
        ;;
      watched.path)
        printf '%s\n' \
          '[Path]' \
          'PathChanged=/srv/storage' \
          'Unit=runtime-wakeup.service'
        ;;
      default-watch.path|unknown.path)
        printf '%s\n' '[Path]' 'PathChanged=/srv/storage'
        ;;
      wakeup.socket)
        printf '%s\n' \
          '[Socket]' \
          'ListenStream=127.0.0.1:16174' \
          'Service=runtime-wakeup.service'
        ;;
      default-wakeup.socket|opaque.socket|templated.socket)
        printf '%s\n' '[Socket]' 'ListenStream=127.0.0.1:16174'
        ;;
      boot-maintenance.target)
        printf '%s\n' \
          '[Unit]' \
          'Description=Maintenance activation target' \
          'Wants=safe-helper.service runtime-wakeup.service'
        ;;
      required-maintenance.target)
        printf '%s\n' \
          '[Unit]' \
          'Description=Maintenance activation target' \
          'Requires=runtime-wakeup.service'
        ;;
      *)
        printf '%s\n' '[Service]' 'ExecStart=/usr/bin/true'
        ;;
    esac
    ;;
  show)
    unit="${2:-}"
    property=""
    for argument in "$@"; do
      case "$argument" in
        --property=*) property="${argument#--property=}" ;;
      esac
    done
    case "$unit:$property" in
      nightly.timer:Unit) printf '%s\n' nightly.service ;;
      scheduled.timer:Unit) printf '%s\n' runtime-wakeup.service ;;
      watched.path:Unit) printf '%s\n' runtime-wakeup.service ;;
      default-watch.path:Unit) printf '%s\n' default-watch.service ;;
      wakeup.socket:Service) printf '%s\n' runtime-wakeup.service ;;
      default-wakeup.socket:Service) printf '%s\n' default-wakeup.service ;;
      boot-maintenance.target:Wants)
        printf '%s\n' 'safe-helper.service runtime-wakeup.service'
        ;;
      boot-maintenance.target:Requires) printf '\n' ;;
      required-maintenance.target:Wants) printf '\n' ;;
      required-maintenance.target:Requires) printf '%s\n' runtime-wakeup.service ;;
      malformed.timer:Unit) printf '%s\n' 'first.service second.service' ;;
      unknown.path:Unit) printf '%s\n' unsupported.mount ;;
      opaque.socket:Service) exit 1 ;;
      templated.socket:Service) printf '%s\n' 'templated@.service' ;;
      *) exit 2 ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
