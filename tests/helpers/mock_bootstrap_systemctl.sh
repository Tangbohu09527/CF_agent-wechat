#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
STATE_DIR="${SCRIPT_DIR}/state"
mkdir -p -- "$STATE_DIR"
printf 'systemctl\t%s\n' "$*" >> "${STATE_DIR}/systemctl.log"

case "${1:-}" in
  is-system-running)
    if [ -e "${STATE_DIR}/systemd-offline" ]; then
      printf '%s\n' offline
      exit 1
    fi
    printf '%s\n' running
    ;;
  is-active)
    [ "${2:-}" = docker.service ] || exit 2
    if [ -e "${STATE_DIR}/docker-inactive" ]; then
      printf '%s\n' inactive
      exit 3
    fi
    printf '%s\n' active
    ;;
  is-enabled)
    case "${2:-}" in
      docker.service)
        if [ -e "${STATE_DIR}/docker-disabled" ]; then
          printf '%s\n' disabled
          exit 1
        fi
        printf '%s\n' enabled
        ;;
      cf-agent-wechat.service)
        if [ -e "${STATE_DIR}/agent-unit-enabled" ]; then
          printf '%s\n' enabled
          exit 0
        fi
        if [ -e "${STATE_DIR}/agent-unit-enable-unknown" ]; then
          printf '%s\n' unknown
          exit 1
        fi
        if [ -e "${STATE_DIR}/agent-unit-enable-error" ]; then
          exit 1
        fi
        printf '%s\n' not-found
        exit 4
        ;;
      *) exit 2 ;;
    esac
    ;;
  list-unit-files)
    printf '%s\n' 'docker.service enabled'
    [ ! -e "${STATE_DIR}/alternate-agent-unit-enabled" ] ||
      printf '%s\n' 'custom-agent-wechat-restore.timer enabled'
    [ ! -e "${STATE_DIR}/hidden-agent-unit-enabled" ] ||
      printf '%s\n' 'restore-runtime.service enabled'
    [ ! -e "${STATE_DIR}/unreadable-agent-unit-enabled" ] ||
      printf '%s\n' 'runtime-maintenance.service enabled'
    [ ! -e "${STATE_DIR}/generic-agent-service-enabled" ] ||
      printf '%s\n' 'nightly-maintenance.service linked-runtime'
    [ ! -e "${STATE_DIR}/generic-agent-timer-enabled" ] ||
      printf '%s\n' 'nightly-maintenance.timer enabled-runtime'
    [ ! -e "${STATE_DIR}/default-agent-timer-enabled" ] ||
      printf '%s\n' 'scheduled-maintenance.timer enabled'
    [ ! -e "${STATE_DIR}/generic-agent-path-enabled" ] ||
      printf '%s\n' 'watched-maintenance.path enabled'
    [ ! -e "${STATE_DIR}/default-agent-path-enabled" ] ||
      printf '%s\n' 'default-maintenance.path linked'
    [ ! -e "${STATE_DIR}/generic-agent-socket-enabled" ] ||
      printf '%s\n' 'wakeup-gateway.socket enabled-runtime'
    [ ! -e "${STATE_DIR}/default-agent-socket-enabled" ] ||
      printf '%s\n' 'default-wakeup.socket enabled'
    [ ! -e "${STATE_DIR}/generic-agent-target-wants-enabled" ] ||
      printf '%s\n' 'boot-maintenance.target enabled'
    [ ! -e "${STATE_DIR}/generic-agent-target-requires-enabled" ] ||
      printf '%s\n' 'required-maintenance.target alias'
    [ ! -e "${STATE_DIR}/malformed-activation-target" ] ||
      printf '%s\n' 'malformed-maintenance.timer enabled'
    [ ! -e "${STATE_DIR}/unknown-activation-target" ] ||
      printf '%s\n' 'unknown-maintenance.path enabled'
    [ ! -e "${STATE_DIR}/activation-show-failure" ] ||
      printf '%s\n' 'opaque-maintenance.socket enabled'
    [ ! -e "${STATE_DIR}/templated-socket-enabled" ] ||
      printf '%s\n' 'templated-maintenance.socket enabled'
    [ ! -e "${STATE_DIR}/generic-unit-cat-failure" ] ||
      printf '%s\n' 'opaque-maintenance.service linked'
    ;;
  cat)
    case "${2:-}" in
      docker.service)
        [ ! -e "${STATE_DIR}/docker-unit-cat-failure" ] || exit 1
        printf '%s\n' '[Service]' 'ExecStart=/usr/bin/dockerd'
        ;;
      restore-runtime.service|nightly-maintenance.service|runtime-wakeup.service|\
      scheduled-maintenance.service|watched-runtime.service|\
      default-maintenance.service|wakeup-runtime.service|\
      default-wakeup.service)
        printf '%s\n' \
          '[Service]' \
          'ExecStart=/usr/bin/docker container start cf-agent-wechat'
        ;;
      nightly-maintenance.timer)
        printf '%s\n' \
          '[Timer]' \
          'OnCalendar=hourly' \
          'Unit=runtime-wakeup.service'
        ;;
      scheduled-maintenance.timer|malformed-maintenance.timer)
        printf '%s\n' '[Timer]' 'OnCalendar=hourly'
        ;;
      watched-maintenance.path)
        printf '%s\n' \
          '[Path]' \
          'PathChanged=/srv/storage' \
          'Unit=watched-runtime.service'
        ;;
      default-maintenance.path|unknown-maintenance.path)
        printf '%s\n' '[Path]' 'PathChanged=/srv/storage'
        ;;
      wakeup-gateway.socket)
        printf '%s\n' \
          '[Socket]' \
          'ListenStream=127.0.0.1:16174' \
          'Service=wakeup-runtime.service'
        ;;
      default-wakeup.socket|opaque-maintenance.socket|templated-maintenance.socket)
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
      safe-helper.service)
        printf '%s\n' '[Service]' 'ExecStart=/usr/bin/true'
        ;;
      *) exit 2 ;;
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
      nightly-maintenance.timer:Unit) printf '%s\n' runtime-wakeup.service ;;
      scheduled-maintenance.timer:Unit) printf '%s\n' scheduled-maintenance.service ;;
      watched-maintenance.path:Unit) printf '%s\n' watched-runtime.service ;;
      default-maintenance.path:Unit) printf '%s\n' default-maintenance.service ;;
      wakeup-gateway.socket:Service) printf '%s\n' wakeup-runtime.service ;;
      default-wakeup.socket:Service) printf '%s\n' default-wakeup.service ;;
      boot-maintenance.target:Wants)
        printf '%s\n' 'safe-helper.service runtime-wakeup.service'
        ;;
      boot-maintenance.target:Requires) printf '\n' ;;
      required-maintenance.target:Wants) printf '\n' ;;
      required-maintenance.target:Requires) printf '%s\n' runtime-wakeup.service ;;
      malformed-maintenance.timer:Unit)
        printf '%s\n' 'first.service second.service'
        ;;
      unknown-maintenance.path:Unit) printf '%s\n' unsupported.mount ;;
      opaque-maintenance.socket:Service) exit 1 ;;
      templated-maintenance.socket:Service)
        printf '%s\n' 'templated-maintenance@.service'
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
