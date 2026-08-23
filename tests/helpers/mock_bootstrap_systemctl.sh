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
        printf '%s\n' not-found
        exit 4
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
