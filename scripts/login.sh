#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

QR_LOGIN_SCRIPT="${SCRIPT_DIR}/qr_login.py"
LOGIN_LOCK_FD=""
LOGIN_LOCK_FILE=""

usage() {
  cat <<'EOF'
Usage: ./scripts/login.sh

Reuse an active persisted session. When login is required, request and display
a fresh device QR code in this terminal.
EOF
}

release_login_lock() {
  if [ -n "$LOGIN_LOCK_FD" ]; then
    flock --unlock "$LOGIN_LOCK_FD" >/dev/null 2>&1 || true
    exec {LOGIN_LOCK_FD}>&-
    LOGIN_LOCK_FD=""
  fi
}

acquire_login_lock() {
  local lock_base lock_dir current_uid metadata previous_umask open_status

  if ! command -v flock >/dev/null 2>&1; then
    LAST_ERROR="fresh QR 登录需要 flock；请先安装 util-linux。"
    return 1
  fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    lock_base="$XDG_RUNTIME_DIR"
  elif [ -n "$_DEFAULT_DATA_HOME" ]; then
    lock_base="${_DEFAULT_DATA_HOME}/cf-agent-wechat"
  else
    LAST_ERROR="无法确定登录锁目录；请设置 HOME 或 XDG_RUNTIME_DIR。"
    return 1
  fi
  case "$lock_base" in
    /*) ;;
    *)
      LAST_ERROR="登录锁目录必须位于绝对 XDG 路径：${lock_base}"
      return 1
      ;;
  esac
  case "$lock_base" in
    *[[:cntrl:]]*|*/../*|*/..)
      LAST_ERROR="登录锁目录包含不允许的路径或控制字符：${lock_base}"
      return 1
      ;;
  esac

  if [ -L "$lock_base" ]; then
    LAST_ERROR="登录锁父目录不能是符号链接：${lock_base}"
    return 1
  fi
  if ! (umask 077; mkdir -p -- "$lock_base"); then
    LAST_ERROR="无法创建登录锁父目录：${lock_base}"
    return 1
  fi
  if [ ! -d "$lock_base" ] || [ -L "$lock_base" ]; then
    LAST_ERROR="登录锁父路径必须是非符号链接目录：${lock_base}"
    return 1
  fi

  if [ "$(/usr/bin/uname -s)" = Linux ]; then
    if ! current_uid="$(/usr/bin/id -u)" ||
      ! metadata="$(/usr/bin/stat -c '%u:%a' -- "$lock_base")"; then
      LAST_ERROR="无法验证登录锁父目录权限：${lock_base}"
      return 1
    fi
    if [ "${metadata%%:*}" != "$current_uid" ]; then
      LAST_ERROR="登录锁父目录必须由当前用户持有：${lock_base}"
      return 1
    fi
    if (( (8#${metadata#*:} & 8#022) != 0 )); then
      LAST_ERROR="登录锁父目录不能被 group/other 写入：${lock_base}"
      return 1
    fi
  fi

  lock_dir="${lock_base}/login-lock"
  if [ -L "$lock_dir" ]; then
    LAST_ERROR="登录锁目录不能是符号链接：${lock_dir}"
    return 1
  fi
  if ! (umask 077; mkdir -m 700 -- "$lock_dir" 2>/dev/null || [ -d "$lock_dir" ]); then
    LAST_ERROR="无法创建登录锁目录：${lock_dir}"
    return 1
  fi
  if [ ! -d "$lock_dir" ] || [ -L "$lock_dir" ]; then
    LAST_ERROR="登录锁路径必须是非符号链接目录：${lock_dir}"
    return 1
  fi
  if [ "$(/usr/bin/uname -s)" = Linux ]; then
    if ! metadata="$(/usr/bin/stat -c '%u:%a' -- "$lock_dir")" ||
      [ "$metadata" != "$current_uid:700" ]; then
      LAST_ERROR="登录锁目录必须由当前用户持有且 mode 700：${lock_dir}"
      return 1
    fi
  fi

  LOGIN_LOCK_FILE="${lock_dir}/login.lock"
  if [ -L "$LOGIN_LOCK_FILE" ]; then
    LAST_ERROR="登录锁文件不能是符号链接：${LOGIN_LOCK_FILE}"
    return 1
  fi
  previous_umask="$(umask)"
  umask 077
  if exec {LOGIN_LOCK_FD}>"$LOGIN_LOCK_FILE"; then
    open_status=0
  else
    open_status=$?
  fi
  umask "$previous_umask"
  if [ "$open_status" -ne 0 ]; then
    LAST_ERROR="无法打开登录锁文件：${LOGIN_LOCK_FILE}"
    return 1
  fi
  if [ -L "$LOGIN_LOCK_FILE" ] || [ ! -f "$LOGIN_LOCK_FILE" ]; then
    release_login_lock
    LAST_ERROR="登录锁必须是非符号链接普通文件：${LOGIN_LOCK_FILE}"
    return 1
  fi
  if [ "$(/usr/bin/uname -s)" = Linux ]; then
    if ! metadata="$(/usr/bin/stat -Lc '%u:%a:%h' -- "/proc/self/fd/${LOGIN_LOCK_FD}")" ||
      [ "$metadata" != "$current_uid:600:1" ]; then
      release_login_lock
      LAST_ERROR="登录锁文件必须由当前用户持有、mode 600 且无硬链接：${LOGIN_LOCK_FILE}"
      return 1
    fi
  fi
  if ! flock --nonblock "$LOGIN_LOCK_FD"; then
    release_login_lock
    LAST_ERROR="已有登录流程正在运行；请保留一个交互终端完成扫码。"
    return 1
  fi
}

confirm_login_status() {
  local attempt last_status="unavailable"

  printf '正在确认登录状态...\n'
  for ((attempt = 1; attempt <= LOGIN_CONFIRM_RETRIES; attempt++)); do
    if fetch_auth_status; then
      last_status="$AUTH_STATUS"
      if [ "$AUTH_STATUS" = "logged_in" ]; then
        printf '登录状态已确认。\n'
        return 0
      fi
    fi

    if [ "$attempt" -lt "$LOGIN_CONFIRM_RETRIES" ]; then
      sleep "$LOGIN_CONFIRM_INTERVAL"
    fi
  done

  LAST_ERROR="已收到 login_success，但认证接口最终状态为 ${last_status}。"
  return 1
}


main() {
  local -a listener_args

  while [ "$#" -gt 0 ]; do
    case "$1" in
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
  done

  if ! validate_configuration; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! resolve_python; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    error "未找到 curl：${CURL_BIN}"
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
      printf '微信已经登录，当前持久化 session 可继续使用。\n'
      return 0
      ;;
    logged_out|qr_pending|waiting_for_qr|waiting_for_scan) ;;
    app_not_running)
      error "微信客户端未运行，请先检查容器 health 和日志。"
      return 1
      ;;
    *)
      error "当前登录状态为 ${AUTH_STATUS}，暂不启动扫码流程。"
      return 1
      ;;
  esac

  if [ ! -t 1 ]; then
    error "fresh QR 登录需要 stdout 连接交互式 TTY；请在 SSH/终端中直接运行。"
    return 1
  fi
  if ! acquire_login_lock; then
    error "$LAST_ERROR"
    return 1
  fi
  trap release_login_lock EXIT

  if ! fetch_auth_status; then
    error "获得登录锁后复核 auth 失败：${LAST_ERROR}"
    return 1
  fi
  case "$AUTH_STATUS" in
    logged_in)
      printf '微信已经登录，另一登录流程已恢复持久化 session。\n'
      return 0
      ;;
    logged_out|qr_pending|waiting_for_qr|waiting_for_scan) ;;
    app_not_running)
      error "微信客户端未运行，请先检查容器 health 和日志。"
      return 1
      ;;
    *)
      error "获得登录锁后状态变为 ${AUTH_STATUS}，拒绝启动扫码流程。"
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

  printf '正在启动 fresh QR 微信登录 WebSocket...\n'
  listener_args=(
    --listen
    --url "$WS_URL"
    --session-id "$SESSION_ID"
    --timeout-ms "$LOGIN_TIMEOUT_MS"
    --new-account
    --require-qr
  )

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
