#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

QR_LOGIN_SCRIPT="${SCRIPT_DIR}/qr_login.py"

confirm_login_status() {
  local attempt

  printf '正在确认登录状态...\n'
  for ((attempt = 1; attempt <= LOGIN_CONFIRM_RETRIES; attempt++)); do
    if fetch_auth_status && [ "$AUTH_STATUS" = "logged_in" ]; then
      printf '登录状态已确认。\n'
      return 0
    fi

    if [ "$attempt" -lt "$LOGIN_CONFIRM_RETRIES" ]; then
      sleep "$LOGIN_CONFIRM_INTERVAL"
    fi
  done

  LAST_ERROR="已收到 login_success，但认证接口未返回 logged_in。"
  return 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/login.sh [--force-qr]

  --force-qr  Require a clean runtime and use newAccount=true.
EOF
}

render_login_response_qr() {
  local response="$1"
  local render_status

  printf '%s' "$response" | "$LOGIN_PYTHON" "$QR_LOGIN_SCRIPT" --render-json
  render_status=$?
  case "$render_status" in
    0) return 0 ;;
    4) return 4 ;;
    *)
      printf '警告：登录接口返回的二维码无法显示，将继续监听登录事件。\n' >&2
      return 4
      ;;
  esac
}

main() {
  local force_qr=0 login_response qr_rendered=0 render_status
  local -a listener_args

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force-qr)
        force_qr=1
        ;;
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
      if [ "$force_qr" -eq 1 ]; then
        error "runtime is not clean; use start-qr-login.sh"
        return 1
      fi
      printf '微信已经登录。\n'
      return 0
      ;;
    logged_out|qr_pending|waiting_for_qr|waiting_for_scan) ;;
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
    error "登录接口调用失败。"
    return 1
  fi
  if render_login_response_qr "$login_response"; then
    qr_rendered=1
  else
    render_status=$?
    if [ "$render_status" -ne 4 ]; then
      error "登录接口二维码处理失败。"
      return 1
    fi
  fi

  listener_args=(
    --listen
    --url "$WS_URL"
    --session-id "$SESSION_ID"
    --timeout-ms "$LOGIN_TIMEOUT_MS"
  )
  if [ "$force_qr" -eq 1 ]; then
    listener_args+=(--new-account)
    if [ "$qr_rendered" -eq 1 ]; then
      listener_args+=(--qr-already-rendered)
    fi
  fi
  if ! printf '%s' "$AUTH_TOKEN" | "$LOGIN_PYTHON" "$QR_LOGIN_SCRIPT" \
    "${listener_args[@]}"; then
    return 1
  fi

  if ! confirm_login_status; then
    error "$LAST_ERROR"
    return 1
  fi
}

main "$@"
