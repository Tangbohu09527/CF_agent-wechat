#!/usr/bin/env bash

# Shared configuration for the host-side agent-wechat management scripts.
set +x
set +a

SCRIPTS_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

API_URL="${API_URL:-http://127.0.0.1:6174}"
API_URL="${API_URL%/}"
DEFAULT_TOKEN_FILE="/srv/storage/cf-agent-wechat/secrets/auth-token"
TOKEN_FILE="${TOKEN_FILE:-$DEFAULT_TOKEN_FILE}"
SESSION_ID="${SESSION_ID:-default}"
CONTAINER_NAME="${CONTAINER_NAME:-${AGENT_WECHAT_CONTAINER_NAME:-cf-agent-wechat}}"

HTTP_CONNECT_TIMEOUT="${HTTP_CONNECT_TIMEOUT:-5}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-45}"
LOGIN_TIMEOUT_MS="${LOGIN_TIMEOUT_MS:-300000}"
LOGIN_CONFIRM_RETRIES="${LOGIN_CONFIRM_RETRIES:-5}"
LOGIN_CONFIRM_INTERVAL="${LOGIN_CONFIRM_INTERVAL:-2}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${SCRIPTS_DIR}/requirements.txt}"
if [ -n "${XDG_DATA_HOME:-}" ]; then
  _DEFAULT_DATA_HOME="$XDG_DATA_HOME"
elif [ -n "${HOME:-}" ]; then
  _DEFAULT_DATA_HOME="${HOME}/.local/share"
else
  _DEFAULT_DATA_HOME=""
fi
VENV_DIR="${CF_AGENT_WECHAT_VENV:-${_DEFAULT_DATA_HOME:+${_DEFAULT_DATA_HOME}/cf-agent-wechat/venv}}"

case "$API_URL" in
  http://*) _DEFAULT_WS_URL="ws://${API_URL#http://}/api/ws/login" ;;
  https://*) _DEFAULT_WS_URL="wss://${API_URL#https://}/api/ws/login" ;;
  *) _DEFAULT_WS_URL="" ;;
esac
WS_URL="${WS_URL:-${_DEFAULT_WS_URL}}"

unset AUTH_TOKEN
AUTH_TOKEN=""
export -n AUTH_TOKEN
AUTH_STATUS=""
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
  local token_value token_status

  AUTH_TOKEN=""
  export -n AUTH_TOKEN
  if [ -r "$TOKEN_FILE" ]; then
    if [ -L "$TOKEN_FILE" ]; then
      LAST_ERROR="token 文件不能是符号链接：${TOKEN_FILE}"
      return 1
    fi
    if [ ! -f "$TOKEN_FILE" ]; then
      LAST_ERROR="token 路径不是普通文件：${TOKEN_FILE}"
      return 1
    fi
    if ! token_value="$(/bin/cat -- "$TOKEN_FILE")"; then
      LAST_ERROR="无法读取 token 文件：${TOKEN_FILE}"
      return 1
    fi
  else
    if [ "$TOKEN_FILE" != "$DEFAULT_TOKEN_FILE" ]; then
      LAST_ERROR="当前用户无法读取自定义 token 路径；sudo 读取仅允许默认路径：${DEFAULT_TOKEN_FILE}"
      return 1
    fi
    if ! command -v sudo >/dev/null 2>&1; then
      LAST_ERROR="当前用户无法读取 token，且未安装 sudo：${TOKEN_FILE}"
      return 1
    fi

    if token_value="$(
      sudo -- /bin/sh -c '
token_file=/srv/storage/cf-agent-wechat/secrets/auth-token
secrets_dir=/srv/storage/cf-agent-wechat/secrets
if [ ! -e "$secrets_dir" ]; then
  exit 41
fi
if [ -L "$secrets_dir" ] || [ ! -d "$secrets_dir" ]; then
  exit 47
fi
if [ -L "$token_file" ]; then
  exit 42
fi
if [ ! -e "$token_file" ]; then
  exit 41
fi
if [ ! -f "$token_file" ]; then
  exit 43
fi
if [ ! -r "$token_file" ]; then
  exit 44
fi
if [ "$(/usr/bin/stat -c "%u:%g:%a" "$secrets_dir")" != "0:0:700" ]; then
  exit 45
fi
if [ "$(/usr/bin/stat -c "%u:%g:%a" "$token_file")" != "0:0:600" ]; then
  exit 46
fi
exec /bin/cat -- "$token_file"
' cf-agent-wechat-token-reader
    )"; then
      token_status=0
    else
      token_status=$?
    fi
    case "$token_status" in
      0) ;;
      41) LAST_ERROR="token 文件不存在：${TOKEN_FILE}" ;;
      42) LAST_ERROR="token 文件不能是符号链接：${TOKEN_FILE}" ;;
      43) LAST_ERROR="token 路径不是普通文件：${TOKEN_FILE}" ;;
      44) LAST_ERROR="sudo 无法读取 token 文件：${TOKEN_FILE}" ;;
      45) LAST_ERROR="secrets 目录必须保持 root:root 700：/srv/storage/cf-agent-wechat/secrets" ;;
      46) LAST_ERROR="auth-token 必须保持 root:root 600：${TOKEN_FILE}" ;;
      47) LAST_ERROR="secrets 路径必须是非符号链接目录：/srv/storage/cf-agent-wechat/secrets" ;;
      *) LAST_ERROR="当前用户无法读取 token，且没有可用的 sudo 权限：${TOKEN_FILE}" ;;
    esac
    if [ "$token_status" -ne 0 ]; then
      return 1
    fi
  fi

  AUTH_TOKEN="$token_value"
  export -n AUTH_TOKEN
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
    --disable \
    --noproxy '*' \
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

if any(character in status for character in ("\n", "\r", "\t")):
    print("status contains an invalid control character.", file=sys.stderr)
    raise SystemExit(2)

sys.stdout.write(status)
')"; then
    LAST_ERROR="无法解析 agent-wechat 认证状态。"
    return 1
  fi

  # Read by the scripts that source this shared library.
  # shellcheck disable=SC2034
  AUTH_STATUS="$parsed"
}

fetch_auth_status() {
  local response

  if ! response="$(api_request GET /api/status/auth 2>/dev/null)"; then
    LAST_ERROR="认证状态接口调用失败。"
    return 1
  fi
  parse_auth_response "$response"
}

auth_status_is_qr_ready() {
  case "$1" in
    logged_out|qr_pending|waiting_for_qr|waiting_for_scan) return 0 ;;
    *) return 1 ;;
  esac
}

check_agent_server() {
  curl \
    --disable \
    --noproxy '*' \
    --request GET \
    --fail \
    --silent \
    --show-error \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
    --max-time "$HTTP_TIMEOUT" \
    "${API_URL}/health" >/dev/null
}

parse_chats_response() {
  local response="$1"
  local mode="${2:-validate}"

  printf '%s' "$response" | "$PYTHON_BIN" -c '
import json
import sys
from urllib.parse import quote

mode = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(2)

def chat_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        if value.get("success") is False or "error" in value:
            return None
        for key in ("chats", "data", "items", "results", "list"):
            if key in value:
                candidate = chat_list(value[key])
                if candidate is not None:
                    return candidate
    return None

chats = chat_list(payload)
if chats is None:
    raise SystemExit(2)
if mode == "validate":
    raise SystemExit(0)
if mode != "first":
    raise SystemExit(2)

for chat in chats:
    if not isinstance(chat, dict):
        continue
    for key in ("chatId", "chat_id", "id", "userName", "username"):
        value = chat.get(key)
        if isinstance(value, (str, int)) and str(value):
            sys.stdout.write(quote(str(value), safe=""))
            raise SystemExit(0)
raise SystemExit(3)
' "$mode"
}

check_chats_api() {
  local response

  if ! response="$(api_request GET /api/chats 2>/dev/null)"; then
    LAST_ERROR="聊天接口不可读。"
    return 1
  fi
  if ! parse_chats_response "$response" validate >/dev/null 2>&1; then
    LAST_ERROR="聊天接口未返回可识别的 JSON 列表。"
    return 1
  fi
}

fetch_first_chat_path() {
  local response encoded_chat

  if ! response="$(api_request GET /api/chats 2>/dev/null)"; then
    LAST_ERROR="聊天接口不可读。"
    return 1
  fi
  if ! encoded_chat="$(parse_chats_response "$response" first 2>/dev/null)"; then
    LAST_ERROR="聊天接口没有返回可用于验证的聊天。"
    return 1
  fi
  printf '%s' "$encoded_chat"
}

check_messages_api() {
  local encoded_chat="$1"
  local response

  if ! response="$(api_request GET "/api/messages/${encoded_chat}" 2>/dev/null)"; then
    LAST_ERROR="消息接口不可读。"
    return 1
  fi
  if ! printf '%s' "$response" | "$PYTHON_BIN" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(2)

def message_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        if value.get("success") is False or "error" in value:
            return None
        for key in ("messages", "data", "items", "results", "list"):
            if key in value:
                candidate = message_list(value[key])
                if candidate is not None:
                    return candidate
    return None

if message_list(payload) is None:
    raise SystemExit(2)
' >/dev/null 2>&1; then
    LAST_ERROR="消息接口未返回可识别的消息列表。"
    return 1
  fi
}

docker_readonly_capture() {
  local output status output_lower

  if output="$(LC_ALL=C docker "$@" 2>&1)"; then
    printf '%s' "$output"
    return 0
  else
    status=$?
  fi

  output_lower="${output,,}"
  case "$output_lower" in
    *permission\ denied*|*access\ denied*|*operation\ not\ permitted*) ;;
    *) return "$status" ;;
  esac
  case "$output_lower" in
    *docker.sock*|*docker\ daemon\ socket*|*docker\ socket*|*connect\ to\ the\ docker\ daemon*) ;;
    *) return "$status" ;;
  esac
  command -v sudo >/dev/null 2>&1 || return "$status"
  sudo -- docker "$@"
}

get_wechat_process_identity() {
  # Variables in this snippet are expanded by the shell inside the container.
  # shellcheck disable=SC2016
  docker_readonly_capture exec "$CONTAINER_NAME" sh -c '
launcher_real="$(readlink -f /usr/bin/wechat 2>/dev/null || true)"
case "$launcher_real" in
  /*) ;;
  *) exit 1 ;;
esac

for process_dir in /proc/[0-9]*; do
  proc_exe="$(readlink "$process_dir/exe" 2>/dev/null || true)"
  [ "$proc_exe" = "$launcher_real" ] || continue
  process_id="${process_dir##*/}"
  start_time="$(awk "{ print \$22 }" "$process_dir/stat" 2>/dev/null || true)"
  [ -n "$start_time" ] || continue
  printf "%s:%s\n" "$process_id" "$start_time"
  exit 0
done
exit 1
' 2>/dev/null
}

wechat_process_is_running() {
  local identity

  identity="$(get_wechat_process_identity)" && [ -n "$identity" ]
}

detect_container_status() {
  local inspect_output inspect_status inspect_state error_lower line

  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  if inspect_output="$(
    LC_ALL=C docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>&1
  )"; then
    inspect_status=0
  else
    inspect_status=$?
  fi
  if [ "$inspect_status" -ne 0 ]; then
    error_lower="${inspect_output,,}"
    case "$error_lower" in
      *permission\ denied*|*access\ denied*|*operation\ not\ permitted*) ;;
      *) return 1 ;;
    esac
    case "$error_lower" in
      *docker.sock*|*docker\ daemon\ socket*|*docker\ socket*|*connect\ to\ the\ docker\ daemon*) ;;
      *) return 1 ;;
    esac

    if ! command -v sudo >/dev/null 2>&1; then
      return 1
    fi
    if ! inspect_output="$(
      sudo -- docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null
    )"; then
      return 1
    fi
  fi

  inspect_state=""
  while IFS= read -r line; do
    case "$line" in
      true|false)
        if [ -n "$inspect_state" ] && [ "$inspect_state" != "$line" ]; then
          return 1
        fi
        inspect_state="$line"
        ;;
    esac
  done <<< "$inspect_output"

  case "$inspect_state" in
    true)
      printf 'running'
      return 0
      ;;
    false)
      printf 'stopped'
      return 0
      ;;
    *) return 1 ;;
  esac
}

validate_venv_location() {
  if [ -z "$VENV_DIR" ]; then
    LAST_ERROR="无法确定普通用户 venv 路径；请设置 HOME 或 CF_AGENT_WECHAT_VENV。"
    return 1
  fi
  if [ -e "$VENV_DIR" ] && [ ! -d "$VENV_DIR" ]; then
    LAST_ERROR="venv 路径不是目录：${VENV_DIR}"
    return 1
  fi
  if [ -d "$VENV_DIR" ] && [ ! -O "$VENV_DIR" ]; then
    LAST_ERROR="venv 目录不属于当前用户；请修复其所有权：${VENV_DIR}"
    return 1
  fi
  if [ -d "$VENV_DIR" ] && [ ! -w "$VENV_DIR" ]; then
    LAST_ERROR="venv 目录不可写；请以普通用户修复其所有权：${VENV_DIR}"
    return 1
  fi
}

ensure_login_environment() {
  local requirements_checksum stamp_file current_checksum

  if ! resolve_python; then
    return 1
  fi
  if ! validate_venv_location; then
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
      # Read by the scripts that call this shared function.
      # shellcheck disable=SC2034
      LAST_ERROR="登录工具依赖安装失败。"
      return 1
    fi
    printf '%s\n' "$requirements_checksum" > "$stamp_file"
  fi
}
