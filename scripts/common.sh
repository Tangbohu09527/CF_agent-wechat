#!/usr/bin/env bash

# Shared configuration for the host-side agent-wechat management scripts.
SCRIPTS_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

API_URL="${API_URL:-http://127.0.0.1:6174}"
API_URL="${API_URL%/}"
TOKEN_FILE="${TOKEN_FILE:-/srv/storage/cf-agent-wechat/secrets/auth-token}"
SESSION_ID="${SESSION_ID:-default}"
CONTAINER_NAME="${CONTAINER_NAME:-${AGENT_WECHAT_CONTAINER_NAME:-cf-agent-wechat-lab}}"

HTTP_CONNECT_TIMEOUT="${HTTP_CONNECT_TIMEOUT:-5}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-45}"
LOGIN_TIMEOUT_MS="${LOGIN_TIMEOUT_MS:-300000}"
LOGIN_CONFIRM_RETRIES="${LOGIN_CONFIRM_RETRIES:-5}"
LOGIN_CONFIRM_INTERVAL="${LOGIN_CONFIRM_INTERVAL:-2}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${SCRIPTS_DIR}/requirements.txt}"
_DEFAULT_DATA_HOME="${XDG_DATA_HOME:-${HOME:-/tmp}/.local/share}"
VENV_DIR="${CF_AGENT_WECHAT_VENV:-${_DEFAULT_DATA_HOME}/cf-agent-wechat/venv}"

case "$API_URL" in
  http://*) _DEFAULT_WS_URL="ws://${API_URL#http://}/api/ws/login" ;;
  https://*) _DEFAULT_WS_URL="wss://${API_URL#https://}/api/ws/login" ;;
  *) _DEFAULT_WS_URL="" ;;
esac
WS_URL="${WS_URL:-${_DEFAULT_WS_URL}}"

AUTH_TOKEN=""
AUTH_STATUS=""
AUTH_ACCOUNT=""
LAST_ERROR=""
LOGIN_PYTHON=""

error() {
  printf '错误：%s\n' "$*" >&2
}

resolve_python() {
  local candidate

  for candidate in "$PYTHON_BIN" python3 python; do
    [ -n "$candidate" ] || continue
    if command -v "$candidate" >/dev/null 2>&1 && \
      "$candidate" -c 'import json' >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done

  LAST_ERROR="未找到可用的 Python 3，请先安装 python3。"
  return 1
}

validate_configuration() {
  case "$API_URL" in
    http://*|https://*) ;;
    *)
      LAST_ERROR="API_URL 必须以 http:// 或 https:// 开头：${API_URL}"
      return 1
      ;;
  esac

  case "$WS_URL" in
    ws://*|wss://*) ;;
    *)
      LAST_ERROR="WS_URL 必须以 ws:// 或 wss:// 开头：${WS_URL}"
      return 1
      ;;
  esac

  case "$SESSION_ID" in
    *$'\r'*|*$'\n'*)
      LAST_ERROR="SESSION_ID 不能包含换行符。"
      return 1
      ;;
  esac
  if ! [[ "$LOGIN_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="LOGIN_TIMEOUT_MS must be positive."
    return 1
  fi
  if ! [[ "$LOGIN_CONFIRM_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="LOGIN_CONFIRM_RETRIES must be positive."
    return 1
  fi

}

load_auth_token() {
  if [ -L "$TOKEN_FILE" ]; then
    LAST_ERROR="token 文件不能是符号链接：${TOKEN_FILE}"
    return 1
  fi
  if [ ! -f "$TOKEN_FILE" ]; then
    LAST_ERROR="token 文件不存在：${TOKEN_FILE}"
    return 1
  fi
  if [ ! -r "$TOKEN_FILE" ]; then
    LAST_ERROR="token 文件不可读：${TOKEN_FILE}"
    return 1
  fi

  AUTH_TOKEN="$(<"$TOKEN_FILE")"
  if [ -z "$AUTH_TOKEN" ]; then
    LAST_ERROR="token 文件为空：${TOKEN_FILE}"
    return 1
  fi
  case "$AUTH_TOKEN" in
    *$'\r'*|*$'\n'*)
      LAST_ERROR="token 文件必须只包含一行 token：${TOKEN_FILE}"
      AUTH_TOKEN=""
      return 1
      ;;
  esac
}

api_request() {
  local method="$1"
  local path="$2"

  printf 'Authorization: Bearer %s\nX-Session-Id: %s\n' \
    "$AUTH_TOKEN" "$SESSION_ID" | curl \
    --request "$method" \
    --fail \
    --silent \
    --show-error \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
    --max-time "$HTTP_TIMEOUT" \
    --header @- \
    "${API_URL}${path}"
}

parse_auth_response() {
  local response="$1"
  local parsed

  if ! parsed="$(printf '%s' "$response" | "$PYTHON_BIN" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError) as exc:
    print(f"认证状态响应不是有效 JSON：{exc}", file=sys.stderr)
    raise SystemExit(2)

if not isinstance(payload, dict):
    print("认证状态响应必须是 JSON 对象。", file=sys.stderr)
    raise SystemExit(2)

status = payload.get("status")
if not isinstance(status, str) or not status:
    print("认证状态响应缺少 status 字段。", file=sys.stderr)
    raise SystemExit(2)

account = payload.get("loggedInUser") or ""
if not isinstance(account, str):
    account = str(account)
if any(character in account for character in ("\n", "\r", "\t")):
    print("loggedInUser 字段包含非法换行符。", file=sys.stderr)
    raise SystemExit(2)

if any(character in status for character in ("\n", "\r", "\t")):
    print("status contains an invalid control character.", file=sys.stderr)
    raise SystemExit(2)

sys.stdout.write(status + "\t" + account)
')"; then
    LAST_ERROR="无法解析 agent-wechat 认证状态。"
    return 1
  fi

  AUTH_STATUS="${parsed%%$'\t'*}"
  if [[ "$parsed" == *$'\t'* ]]; then
    AUTH_ACCOUNT="${parsed#*$'\t'}"
  else
    AUTH_ACCOUNT=""
  fi
}

fetch_auth_status() {
  local response

  if ! response="$(api_request GET /api/status/auth 2>&1)"; then
    LAST_ERROR="认证状态接口调用失败：${response}"
    return 1
  fi
  parse_auth_response "$response"
}

detect_container_status() {
  local running

  if command -v docker >/dev/null 2>&1; then
    if running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)"; then
      if [ "$running" = "true" ]; then
        printf 'running'
      else
        printf 'stopped'
      fi
      return 0
    fi
  fi

  return 1
}

ensure_login_environment() {
  local requirements_checksum stamp_file current_checksum

  if ! resolve_python; then
    return 1
  fi
  if [ ! -f "$REQUIREMENTS_FILE" ]; then
    LAST_ERROR="Python 依赖清单不存在：${REQUIREMENTS_FILE}"
    return 1
  fi
  if ! command -v cksum >/dev/null 2>&1; then
    LAST_ERROR="cksum is required to verify dependencies."
    return 1
  fi

  if [ -x "${VENV_DIR}/bin/python" ]; then
    LOGIN_PYTHON="${VENV_DIR}/bin/python"
  elif [ -x "${VENV_DIR}/Scripts/python.exe" ]; then
    LOGIN_PYTHON="${VENV_DIR}/Scripts/python.exe"
  else
    printf '正在创建隔离的登录工具环境：%s\n' "$VENV_DIR"
    if ! "$PYTHON_BIN" -m venv "$VENV_DIR"; then
      LAST_ERROR="无法创建 Python venv；请确认已安装 python3-venv。"
      return 1
    fi

    if [ -x "${VENV_DIR}/bin/python" ]; then
      LOGIN_PYTHON="${VENV_DIR}/bin/python"
    elif [ -x "${VENV_DIR}/Scripts/python.exe" ]; then
      LOGIN_PYTHON="${VENV_DIR}/Scripts/python.exe"
    else
      LAST_ERROR="venv 已创建，但找不到其中的 Python 解释器：${VENV_DIR}"
      return 1
    fi
  fi

  requirements_checksum="$(cksum < "$REQUIREMENTS_FILE")"
  stamp_file="${VENV_DIR}/.cf-agent-wechat-requirements"
  current_checksum=""
  if [ -f "$stamp_file" ]; then
    current_checksum="$(<"$stamp_file")"
  fi

  if [ "$requirements_checksum" != "$current_checksum" ] || \
    ! "$LOGIN_PYTHON" -c 'import PIL, qrcode, websocket' >/dev/null 2>&1; then
    printf '正在安装登录工具依赖...\n'
    if ! "$LOGIN_PYTHON" -m pip install \
      --disable-pip-version-check \
      --requirement "$REQUIREMENTS_FILE"; then
      LAST_ERROR="登录工具依赖安装失败。"
      return 1
    fi
    printf '%s\n' "$requirements_checksum" > "$stamp_file"
  fi
}
