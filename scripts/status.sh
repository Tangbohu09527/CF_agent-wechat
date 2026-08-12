#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

print_status() {
  local container_status="$1"
  local wechat_status="$2"
  local account="$3"

  printf '%s\n' '================================'
  printf '%s\n' 'CF Agent WeChat Status'
  printf '%s\n\n' '================================'
  printf 'Container:\n  %s\n\n' "$container_status"
  printf 'WeChat:\n  %s\n\n' "$wechat_status"
  printf 'Account:\n  %s\n\n' "${account:--}"
  printf '%s\n' '================================'
}

main() {
  local container_status="unknown"
  local detected_status

  if ! validate_configuration; then
    print_status "$container_status" "unavailable" ""
    error "$LAST_ERROR"
    return 1
  fi
  if ! resolve_python; then
    print_status "$container_status" "unavailable" ""
    error "$LAST_ERROR"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    print_status "$container_status" "unavailable" ""
    error "未找到 curl。"
    return 1
  fi
  if ! load_auth_token; then
    if detected_status="$(detect_container_status)"; then
      container_status="$detected_status"
    fi
    print_status "$container_status" "unavailable" ""
    error "$LAST_ERROR"
    return 1
  fi

  if fetch_auth_status; then
    container_status="running"
  else
    if detected_status="$(detect_container_status)"; then
      container_status="$detected_status"
    fi
    print_status "$container_status" "unavailable" ""
    error "$LAST_ERROR"
    return 1
  fi

  print_status "$container_status" "$AUTH_STATUS" "$AUTH_ACCOUNT"

  case "$AUTH_STATUS" in
    logged_in)
      return 0
      ;;
    logged_out)
      printf '\n微信未登录，需要执行：\n\n  ./scripts/login.sh\n'
      return 2
      ;;
    app_not_running)
      error "微信客户端未运行，请先检查容器日志。"
      return 3
      ;;
    *)
      error "未知的微信登录状态：${AUTH_STATUS}"
      return 3
      ;;
  esac
}

main "$@"
