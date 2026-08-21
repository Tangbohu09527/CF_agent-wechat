#!/usr/bin/env bash
set -euo pipefail

: "${CF_BOOTSTRAP_TEST_LOG:?}"

printf 'systemctl\t%s\n' "$*" >> "$CF_BOOTSTRAP_TEST_LOG"

case "${1:-}" in
  is-system-running)
    printf '%s\n' "${CF_BOOTSTRAP_TEST_SYSTEMD_STATE:-running}"
    case "${CF_BOOTSTRAP_TEST_SYSTEMD_STATE:-running}" in
      running) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  is-active)
    [ "${2:-}" = "docker.service" ] || exit 2
    printf '%s\n' "${CF_BOOTSTRAP_TEST_DOCKER_SERVICE_ACTIVITY:-active}"
    case "${CF_BOOTSTRAP_TEST_DOCKER_SERVICE_ACTIVITY:-active}" in
      active)
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  is-enabled)
    [ "${2:-}" = "docker.service" ] || exit 2
    printf '%s\n' "${CF_BOOTSTRAP_TEST_DOCKER_SERVICE_ENABLEMENT:-enabled}"
    case "${CF_BOOTSTRAP_TEST_DOCKER_SERVICE_ENABLEMENT:-enabled}" in
      enabled)
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
