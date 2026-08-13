#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

QR_LOGIN_SCRIPT="${SCRIPT_DIR}/qr_login.py"

confirm_login_status() {
  local attempt

  printf '正在确认登录状态...\n'
  for ((attempt = 1; attempt <= LOGIN_CONFIRM_RETRIES; attempt++)); do
    if fetch_auth_status && [ "$AUTH_STATUS" = "logged_in" ]; then
      if [ -n "$AUTH_ACCOUNT" ]; then
        printf '登录状态已确认，账号：%s\n' "$AUTH_ACCOUNT"
      else
        printf '登录状态已确认。\n'
      fi
      return 0
    fi

    if [ "$attempt" -lt "$LOGIN_CONFIRM_RETRIES" ]; then
      sleep "$LOGIN_CONFIRM_INTERVAL"
    fi
  done

  LAST_ERROR="已收到 login_success，但认证接口未返回 logged_in。"
  return 1
}

render_login_response_qr() {
  local response="$1"
  local render_status

  printf '%s' "$response" | "$LOGIN_PYTHON" "$QR_LOGIN_SCRIPT" --render-json
  render_status=$?
  case "$render_status" in
    0|4) return 0 ;;
    *)
      printf '警告：登录接口返回的二维码无法显示，将继续监听登录事件。\n' >&2
      return 0
      ;;
  esac
}

main() {
  local login_response

  if ! validate_configuration; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! resolve_python; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    error "未找到 curl。"
    return 1
  fi
  if ! load_auth_token; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! fetch_auth_status; then
    error "$LAST_ERROR"
    return 1
  fi

  case "$AUTH_STATUS" in
    logged_in)
      printf '微信已经登录。\n'
      return 0
      ;;
    logged_out)
      ;;
    app_not_running)
      error "微信客户端未运行，请先检查容器日志。"
      return 1
      ;;
    *)
      error "当前登录状态为 ${AUTH_STATUS}，暂不启动扫码流程。"
      return 1
      ;;
  esac

  if ! ensure_login_environment; then
    error "$LAST_ERROR"
    return 1
  fi
  if [ ! -f "$QR_LOGIN_SCRIPT" ]; then
    error "二维码登录工具不存在：${QR_LOGIN_SCRIPT}"
    return 1
  fi

  printf '正在触发微信登录...\n'
  if ! login_response="$(api_request POST /api/status/login 2>&1)"; then
    error "登录接口调用失败：${login_response}"
    return 1
  fi
  render_login_response_qr "$login_response"

  if ! printf '%s' "$AUTH_TOKEN" | "$LOGIN_PYTHON" "$QR_LOGIN_SCRIPT" \
    --listen \
    --url "$WS_URL" \
    --session-id "$SESSION_ID" \
    --timeout-ms "$LOGIN_TIMEOUT_MS"; then
    return 1
  fi

  if ! confirm_login_status; then
    error "$LAST_ERROR"
    return 1
  fi
}

main "$@"
