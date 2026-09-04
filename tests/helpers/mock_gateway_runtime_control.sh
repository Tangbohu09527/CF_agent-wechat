#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STATE_DIR="${MOCK_GATEWAY_STATE_DIR:-${SCRIPT_DIR}/.wechat-runtime-control-test-state}"
LOG_FILE="${MOCK_GATEWAY_LOG:-${STATE_DIR}/controller.log}"
MUTATION_LOG="${MOCK_GATEWAY_MUTATION_LOG:-${STATE_DIR}/mutations.log}"

[ -d "$STATE_DIR" ] || exit 72
[ -f "$LOG_FILE" ] || exit 72
[ -f "$MUTATION_LOG" ] || exit 72

state_get() {
  local name="$1" default_value="$2"
  if [ -f "${STATE_DIR}/${name}" ]; then
    /bin/cat -- "${STATE_DIR}/${name}"
  else
    printf '%s' "$default_value"
  fi
}

state_set() {
  printf '%s\n' "$2" > "${STATE_DIR}/${1}"
}

record() {
  printf '%s\n' "$1" >> "$LOG_FILE"
}

mutate() {
  record "$1"
  printf '%s\n' "$1" >> "$MUTATION_LOG"
}

emit_mode() {
  local operation="$1" mode
  mode="$(state_get "${operation}_mode" valid)"
  case "$mode" in
    valid) return 0 ;;
    malformed)
      printf '%s\n' '{not-json'
      exit 0
      ;;
    timeout)
      sleep 300
      exit 0
      ;;
    nonzero) exit 70 ;;
    *) exit 71 ;;
  esac
}

operation="${1:-}"
case "$operation" in
  contract)
    record "gateway controller contract"
    emit_mode contract
    printf '%s\n' \
      '{"contract_version":1,"poll_worker_service":"worker","delivery_worker_service":"delivery-worker","dispatch_worker_service":"dispatch-worker","token_mode":"file","token_container_path":"/run/secrets/cf-agent-wechat-auth-token"}'
    ;;
  stop)
    record "gateway controller stop"
    emit_mode stop
    mutate "gateway worker stop"
    state_set gateway_running 0
    printf '%s\n' '{"stopped":true}'
    ;;
  start)
    record "gateway controller start"
    emit_mode start
    mutate "gateway worker start"
    state_set gateway_running 1
    printf '%s\n' '{"started":true}'
    ;;
  status)
    record "gateway controller status"
    emit_mode status
    running="$(state_get gateway_running 1)"
    if [ "$running" = 1 ]; then
      default_health=healthy
    else
      default_health=stopped
    fi
    worker_health="$(state_get worker_health "$default_health")"
    delivery_health="$(state_get delivery_health "$default_health")"
    token_valid="$(state_get token_contract_valid true)"
    default_ready=false
    if [ "$token_valid" = true ] && [ "$worker_health" = healthy ] && \
      [ "$delivery_health" = healthy ]; then
      default_ready=true
    fi
    ready="$(state_get gateway_ready "$default_ready")"
    printf '{"ready":%s,"token_contract_valid":%s,' "$ready" "$token_valid"
    printf '"worker_health":"%s","delivery_health":"%s"}\n' \
      "$worker_health" "$delivery_health"
    ;;
  *) exit 64 ;;
esac