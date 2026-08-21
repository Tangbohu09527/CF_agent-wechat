#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CONTAINER_STATUS="unknown"
HEALTH_STATUS="unknown"
API_STATUS="unavailable"
SESSION_STATUS="unavailable"
STATUS_RESULT=1

usage() {
  cat <<'EOF'
Usage: ./scripts/status.sh [--wait]

  --wait  Poll for restart recovery using STATUS_WAIT_TIMEOUT as the budget.
EOF
}

print_status() {
  printf '%s\n' '================================'
  printf '%s\n' 'CF Agent WeChat Status'
  printf '%s\n' '================================'
  printf 'Container:\n  %s\n' "$CONTAINER_STATUS"
  printf 'Container Health:\n  %s\n' "$HEALTH_STATUS"
  printf 'API:\n  %s\n' "$API_STATUS"
  printf 'Auth:\n  %s\n' "${AUTH_STATUS:-unavailable}"
  printf 'Session:\n  %s\n' "$SESSION_STATUS"
  printf '%s\n' '================================'
}

bounded_http_timeout() {
  local deadline="$1"
  local remaining

  if [ "$deadline" -le 0 ]; then
    printf '%s' "$HTTP_TIMEOUT"
    return 0
  fi
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || return 1
  if [ "$remaining" -lt "$HTTP_TIMEOUT" ]; then
    printf '%s' "$remaining"
  else
    printf '%s' "$HTTP_TIMEOUT"
  fi
}

sample_status() {
  local deadline="${1:-0}"
  local detected request_timeout

  CONTAINER_STATUS="unknown"
  HEALTH_STATUS="unknown"
  API_STATUS="unavailable"
  AUTH_STATUS=""
  SESSION_STATUS="unavailable"
  STATUS_RESULT=1

  if detected="$(detect_container_status "$deadline")"; then
    CONTAINER_STATUS="$detected"
  fi
  if detected="$(detect_container_health "$deadline")"; then
    HEALTH_STATUS="$detected"
  fi
  if request_timeout="$(bounded_http_timeout "$deadline")" &&
    check_api_health "$request_timeout"; then
    API_STATUS="reachable"
  fi
  if [ "$API_STATUS" = "reachable" ] &&
    request_timeout="$(bounded_http_timeout "$deadline")"; then
    fetch_auth_status "$request_timeout" >/dev/null 2>&1 || AUTH_STATUS=""
  fi

  case "$AUTH_STATUS" in
    logged_in) SESSION_STATUS="active" ;;
    logged_out|qr_pending|waiting_for_qr|waiting_for_scan)
      SESSION_STATUS="login_required"
      ;;
  esac

  if [ "$CONTAINER_STATUS" = "unknown" ] ||
    [ "$HEALTH_STATUS" = "unknown" ]; then
    STATUS_RESULT=1
  elif [ "$CONTAINER_STATUS" != "running" ]; then
    STATUS_RESULT=3
  elif [ "$HEALTH_STATUS" != "healthy" ]; then
    STATUS_RESULT=3
  elif [ "$API_STATUS" != "reachable" ] || [ -z "$AUTH_STATUS" ]; then
    STATUS_RESULT=1
  elif [ "$AUTH_STATUS" = "logged_in" ]; then
    STATUS_RESULT=0
  elif auth_status_is_login_pending "$AUTH_STATUS"; then
    STATUS_RESULT=2
  else
    STATUS_RESULT=3
  fi
}

print_failure_guidance() {
  local timed_out="$1"

  if [ "$timed_out" -eq 1 ]; then
    error "等待恢复的 ${STATUS_WAIT_TIMEOUT} 秒轮询预算已耗尽。"
  fi
  if [ "$CONTAINER_STATUS" = "unknown" ]; then
    error "无法查询容器状态；请检查 Docker 权限和容器名 ${CONTAINER_NAME}。"
  elif [ "$CONTAINER_STATUS" != "running" ]; then
    error "agent-wechat 容器未运行。"
  elif [ "$HEALTH_STATUS" = "unknown" ]; then
    error "无法查询容器 health 状态。"
  elif [ "$HEALTH_STATUS" = "none" ]; then
    error "agent-wechat 容器缺少 healthcheck。"
  elif [ "$HEALTH_STATUS" != "healthy" ]; then
    error "agent-wechat 容器 health 状态为 ${HEALTH_STATUS}。"
  elif [ "$API_STATUS" != "reachable" ]; then
    error "agent-wechat health API 不可用：${HEALTH_URL}"
  else
    case "$AUTH_STATUS" in
      logged_out|qr_pending|waiting_for_qr|waiting_for_scan)
        printf '\n微信未登录，需要执行：\n\n  ./scripts/login.sh\n'
        ;;
      app_not_running)
        error "微信客户端未运行，请检查容器日志。"
        ;;
      "")
        error "认证状态 API 不可用或返回无效响应。"
        ;;
      *)
        error "未知的微信认证状态：${AUTH_STATUS}"
        ;;
    esac
  fi
}

main() {
  local wait_mode=0 timed_out=0 deadline sample_deadline=0
  local remaining sleep_seconds wait_notice_printed=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait) wait_mode=1 ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        error "未知参数：$1"
        usage >&2
        return 1
        ;;
    esac
    shift
  done

  if ! validate_configuration; then
    print_status
    error "$LAST_ERROR"
    return 1
  fi
  if ! resolve_python; then
    print_status
    error "$LAST_ERROR"
    return 1
  fi
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    print_status
    error "未找到 curl：${CURL_BIN}"
    return 1
  fi
  if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
    print_status
    error "未找到 docker：${DOCKER_BIN}"
    return 1
  fi
  if ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
    print_status
    error "未找到 GNU timeout：${TIMEOUT_BIN}"
    return 1
  fi
  if ! load_auth_token; then
    print_status
    error "$LAST_ERROR"
    return 1
  fi

  deadline=$((SECONDS + STATUS_WAIT_TIMEOUT))
  if [ "$wait_mode" -eq 1 ]; then
    sample_deadline="$deadline"
  fi
  while :; do
    sample_status "$sample_deadline"
    if [ "$STATUS_RESULT" -eq 0 ] || [ "$wait_mode" -eq 0 ]; then
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      timed_out=1
      break
    fi
    if [ "$wait_notice_printed" -eq 0 ]; then
      printf '正在等待容器、API 与持久化会话恢复（轮询预算 %s 秒）...\n' \
        "$STATUS_WAIT_TIMEOUT" >&2
      wait_notice_printed=1
    fi
    remaining=$((deadline - SECONDS))
    sleep_seconds="$STATUS_POLL_INTERVAL"
    if [ "$remaining" -lt "$sleep_seconds" ]; then
      sleep_seconds="$remaining"
    fi
    if [ "$sleep_seconds" -gt 0 ]; then
      sleep "$sleep_seconds"
    fi
  done

  print_status
  if [ "$STATUS_RESULT" -ne 0 ]; then
    print_failure_guidance "$timed_out"
  fi
  return "$STATUS_RESULT"
}

main "$@"
