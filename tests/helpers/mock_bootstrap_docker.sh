#!/usr/bin/env bash
set -euo pipefail

: "${CF_BOOTSTRAP_TEST_LOG:?}"
: "${CF_BOOTSTRAP_TEST_STATE_DIR:?}"

{
  printf 'docker'
  printf '\t%s' "$@"
  printf '\truntime=%s' "${CF_AGENT_WECHAT_RUNTIME_ROOT:-unset}"
  printf '\tlegacy=%s' "${CF_AGENT_WECHAT_STORAGE_ROOT-unset}"
  printf '\tproxy=%s' "${PROXY-unset}"
  printf '\trust_log=%s' "${RUST_LOG-unset}"
  printf '\tproject_env=%s\n' "${COMPOSE_PROJECT_NAME-unset}"
} >> "$CF_BOOTSTRAP_TEST_LOG"

if [ "${CF_BOOTSTRAP_TEST_DOCKER_UNAVAILABLE:-0}" = "1" ]; then
  exit 127
fi

case "${1:-}" in
  --version)
    printf '%s\n' 'Docker version 28.0.0, build bootstrap-test'
    ;;
  info)
    printf '%s\n' 'mock Docker daemon'
    ;;
  network)
    case "${2:-}" in
      inspect)
        [ -f "${CF_BOOTSTRAP_TEST_STATE_DIR}/network" ]
        ;;
      create)
        : > "${CF_BOOTSTRAP_TEST_STATE_DIR}/network"
        printf '%s\n' "${3:-cf-internal}"
        ;;
      *) exit 2 ;;
    esac
    ;;
  compose)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --env-file|--project-directory|--project-name|-f)
          shift 2
          ;;
        version)
          printf '%s\n' '2.35.1'
          exit 0
          ;;
        config)
          if [ "${CF_BOOTSTRAP_TEST_COMPOSE_INVALID:-0}" = "1" ]; then
            exit 1
          fi
          if [ "${2:-}" = "--services" ]; then
            printf '%s\n' 'agent-wechat'
          fi
          exit 0
          ;;
        up)
          : > "${CF_BOOTSTRAP_TEST_STATE_DIR}/started"
          exit 0
          ;;
        ps)
          if [ -f "${CF_BOOTSTRAP_TEST_STATE_DIR}/started" ]; then
            printf '%s\n' 'cf-agent-wechat-test-id'
          fi
          exit 0
          ;;
        *)
          exit 2
          ;;
      esac
    done
    ;;
  inspect)
    format="${3:-}"
    case "$format" in
      '{{.State.Status}}')
        printf '%s\n' "${CF_BOOTSTRAP_TEST_CONTAINER_STATE:-running}"
        ;;
      '{{if .State.Health}}{{.State.Health.Status}}{{end}}')
        printf '%s\n' "${CF_BOOTSTRAP_TEST_HEALTH:-healthy}"
        ;;
      '{{.HostConfig.RestartPolicy.Name}}')
        printf '%s\n' "${CF_BOOTSTRAP_TEST_RESTART_POLICY:-unless-stopped}"
        ;;
      *'.Destination "/data/auth-token"'*)
        printf '%s|%s\n' \
          "${CF_AGENT_WECHAT_RUNTIME_ROOT}/secrets/auth-token" \
          "${CF_BOOTSTRAP_TEST_TOKEN_MOUNT_RW:-false}"
        ;;
      *'.Destination "/home/wechat"'*)
        if [ "${CF_BOOTSTRAP_TEST_BAD_MOUNT:-0}" = "1" ]; then
          printf '%s|%s\n' '/wrong/wechat-home' \
            "${CF_BOOTSTRAP_TEST_HOME_MOUNT_RW:-true}"
        else
          printf '%s|%s\n' "${CF_AGENT_WECHAT_RUNTIME_ROOT}/wechat-home" \
            "${CF_BOOTSTRAP_TEST_HOME_MOUNT_RW:-true}"
        fi
        ;;
      *'.Destination "/data"'*)
        printf '%s|%s\n' "${CF_AGENT_WECHAT_RUNTIME_ROOT}/data" \
          "${CF_BOOTSTRAP_TEST_DATA_MOUNT_RW:-true}"
        ;;
      *'.NetworkSettings.Networks'*'.Aliases'*)
        if [ "${CF_BOOTSTRAP_TEST_NETWORK_ALIAS_PRESENT:-1}" = "1" ]; then
          printf '%s\n' 'present'
        fi
        ;;
      *'.NetworkSettings.Networks'*)
        if [ "${CF_BOOTSTRAP_TEST_NETWORK_ATTACHED:-1}" = "1" ]; then
          printf '%s\n' 'attached'
        fi
        ;;
      *'.NetworkSettings.Ports'*)
        if [ -n "${CF_BOOTSTRAP_TEST_PORT_BINDING:-}" ]; then
          printf '%s\n' "$CF_BOOTSTRAP_TEST_PORT_BINDING"
        else
          printf '%s:%s\n' "$AGENT_WECHAT_BIND_IP" "$AGENT_WECHAT_PORT"
        fi
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
