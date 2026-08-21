#!/usr/bin/env bash

# Shared configuration for the host-side agent-wechat management scripts.
set +x
set +a

SCRIPTS_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPTS_DIR}/.." && pwd -P)"
MANAGEMENT_ENV_FILE="${REPO_ROOT}/docker/.env"
_MANAGEMENT_ENV_ERROR=""
_ENV_RUNTIME_ROOT=""
_ENV_BIND_IP=""
_ENV_PORT=""
_ENV_CONTAINER_NAME=""

set_management_env_error() {
  if [ -z "$_MANAGEMENT_ENV_ERROR" ]; then
    _MANAGEMENT_ENV_ERROR="$1"
  fi
}

normalize_management_path() {
  local value="$1"
  local normalized

  case "$value" in
    /)
      return 1
      ;;
    /*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    *[[:cntrl:]]*|*/../*|*/..) return 1 ;;
  esac
  command -v realpath >/dev/null 2>&1 || return 1
  normalized="$(realpath -m -- "$value" 2>/dev/null)" || return 1
  [ "$normalized" != "/" ] || return 1
  printf '%s' "$normalized"
}

management_env_path_is_dotenv_safe() {
  local LC_ALL=C
  local dotenv_path_pattern='^/[-A-Za-z0-9._/@%+,=:~]*$'

  [[ "$1" =~ $dotenv_path_pattern ]]
}

load_management_environment() {
  local docker_dir directory_mode line key value seen_keys="|"
  local mode repo_mode normalized_runtime normalized_legacy
  local legacy_runtime_root=""

  if [ -L "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
    set_management_env_error "仓库根目录必须是非符号链接目录：${REPO_ROOT}"
    return
  fi
  if ! repo_mode="$(stat -c '%a' -- "$REPO_ROOT" 2>/dev/null)" ||
    ! [[ "$repo_mode" =~ ^[0-7]{3,4}$ ]]; then
    set_management_env_error "无法验证仓库根目录权限：${REPO_ROOT}"
    return
  fi
  if (( (8#$repo_mode & 8#022) != 0 )); then
    set_management_env_error "仓库根目录不能被 group/other 写入：${REPO_ROOT}"
    return
  fi

  docker_dir="${REPO_ROOT}/docker"
  if [ -L "$docker_dir" ] || [ ! -d "$docker_dir" ]; then
    set_management_env_error "生产配置目录必须是非符号链接目录：${docker_dir}"
    return
  fi
  if ! directory_mode="$(stat -c '%a' -- "$docker_dir" 2>/dev/null)" ||
    ! [[ "$directory_mode" =~ ^[0-7]{3,4}$ ]]; then
    set_management_env_error "无法验证生产配置目录权限：${docker_dir}"
    return
  fi
  if (( (8#$directory_mode & 8#022) != 0 )); then
    set_management_env_error "生产配置目录不能被 group/other 写入：${docker_dir}"
    return
  fi
  if [ ! -e "$MANAGEMENT_ENV_FILE" ] && [ ! -L "$MANAGEMENT_ENV_FILE" ]; then
    return
  fi
  if [ -L "$MANAGEMENT_ENV_FILE" ] || [ ! -f "$MANAGEMENT_ENV_FILE" ]; then
    set_management_env_error "生产环境文件必须是非符号链接普通文件：${MANAGEMENT_ENV_FILE}"
    return
  fi
  if [ ! -r "$MANAGEMENT_ENV_FILE" ]; then
    set_management_env_error "当前管理用户无法读取生产环境文件：${MANAGEMENT_ENV_FILE}"
    return
  fi
  if ! mode="$(stat -c '%a' -- "$MANAGEMENT_ENV_FILE" 2>/dev/null)" ||
    ! [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    set_management_env_error "无法验证生产环境文件权限：${MANAGEMENT_ENV_FILE}"
    return
  fi
  case "$mode" in
    600|0600|640|0640) ;;
    *)
      set_management_env_error "生产环境文件权限必须是 0600 或 0640：${MANAGEMENT_ENV_FILE}"
      return
      ;;
  esac

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    if ! [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      CF_AGENT_WECHAT_RUNTIME_ROOT|CF_AGENT_WECHAT_STORAGE_ROOT|AGENT_WECHAT_BIND_IP|AGENT_WECHAT_PORT|AGENT_WECHAT_CONTAINER_NAME) ;;
      *) continue ;;
    esac
    case "$seen_keys" in
      *"|${key}|"*)
        set_management_env_error "生产环境文件包含重复配置键：${key}"
        return
        ;;
    esac
    seen_keys="${seen_keys}${key}|"
    if [ -z "$value" ] || [[ "$value" =~ [[:cntrl:]] ]]; then
      set_management_env_error "生产环境文件中的 ${key} 为空或包含控制字符"
      return
    fi
    case "$key" in
      CF_AGENT_WECHAT_RUNTIME_ROOT) _ENV_RUNTIME_ROOT="$value" ;;
      CF_AGENT_WECHAT_STORAGE_ROOT) legacy_runtime_root="$value" ;;
      AGENT_WECHAT_BIND_IP) _ENV_BIND_IP="$value" ;;
      AGENT_WECHAT_PORT) _ENV_PORT="$value" ;;
      AGENT_WECHAT_CONTAINER_NAME) _ENV_CONTAINER_NAME="$value" ;;
    esac
  done < "$MANAGEMENT_ENV_FILE"

  if [ -n "$_ENV_RUNTIME_ROOT" ]; then
    if ! management_env_path_is_dotenv_safe "$_ENV_RUNTIME_ROOT"; then
      set_management_env_error "生产环境文件中的 CF_AGENT_WECHAT_RUNTIME_ROOT 包含 dotenv 不安全字符"
      return
    fi
    if ! normalized_runtime="$(normalize_management_path "$_ENV_RUNTIME_ROOT")"; then
      set_management_env_error "生产环境文件中的 CF_AGENT_WECHAT_RUNTIME_ROOT 无效"
      return
    fi
    _ENV_RUNTIME_ROOT="$normalized_runtime"
  fi
  if [ -n "$legacy_runtime_root" ]; then
    if ! management_env_path_is_dotenv_safe "$legacy_runtime_root"; then
      set_management_env_error "生产环境文件中的 legacy runtime root 包含 dotenv 不安全字符"
      return
    fi
    if ! normalized_legacy="$(normalize_management_path "$legacy_runtime_root")"; then
      set_management_env_error "生产环境文件中的 legacy runtime root 无效"
      return
    fi
    if [ -n "$_ENV_RUNTIME_ROOT" ] &&
      [ "$_ENV_RUNTIME_ROOT" != "$normalized_legacy" ]; then
      set_management_env_error "生产环境文件中的新旧 runtime root 配置冲突"
      return
    fi
    _ENV_RUNTIME_ROOT="${_ENV_RUNTIME_ROOT:-$normalized_legacy}"
  fi
  if [ -n "$_ENV_BIND_IP" ] && [ "$_ENV_BIND_IP" != "127.0.0.1" ]; then
    set_management_env_error "生产环境文件中的 AGENT_WECHAT_BIND_IP 必须是 127.0.0.1"
    return
  fi
  if [ -n "$_ENV_PORT" ] &&
    { ! [[ "$_ENV_PORT" =~ ^[1-9][0-9]*$ ]] || [ "$_ENV_PORT" -gt 65535 ]; }; then
    set_management_env_error "生产环境文件中的 AGENT_WECHAT_PORT 无效"
    return
  fi
  if [ -n "$_ENV_CONTAINER_NAME" ] &&
    ! [[ "$_ENV_CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    set_management_env_error "生产环境文件中的 AGENT_WECHAT_CONTAINER_NAME 无效"
    return
  fi
}

load_management_environment

_PROCESS_API_URL_SET="${API_URL+x}"
_PROCESS_HEALTH_URL_SET="${HEALTH_URL+x}"
_PROCESS_HEALTH_URL="${HEALTH_URL-}"
_PROCESS_WS_URL_SET="${WS_URL+x}"
_PROCESS_WS_URL="${WS_URL-}"
_PROCESS_CONTAINER_NAME_SET="${CONTAINER_NAME+x}"
_PROCESS_CONTAINER_NAME="${CONTAINER_NAME-}"
_PROCESS_TOKEN_FILE_SET="${TOKEN_FILE+x}"
_PROCESS_TOKEN_FILE="${TOKEN_FILE-}"

MANAGEMENT_BIND_IP="${_ENV_BIND_IP:-${AGENT_WECHAT_BIND_IP:-127.0.0.1}}"
MANAGEMENT_PORT="${_ENV_PORT:-${AGENT_WECHAT_PORT:-6174}}"
API_URL="${API_URL:-http://127.0.0.1:${MANAGEMENT_PORT}}"
API_URL="${API_URL%/}"
HEALTH_URL="${API_URL}/health"
case "$API_URL" in
  http://*) WS_URL="ws://${API_URL#http://}/api/ws/login" ;;
  https://*) WS_URL="wss://${API_URL#https://}/api/ws/login" ;;
  *) WS_URL="" ;;
esac

PRIVILEGED_SECRETS_DIR="/srv/storage/cf-agent-wechat/secrets"
PRIVILEGED_TOKEN_FILE="/srv/storage/cf-agent-wechat/secrets/auth-token"
RUNTIME_ROOT="${_ENV_RUNTIME_ROOT:-${CF_RUNTIME_ROOT:-${CF_AGENT_WECHAT_RUNTIME_ROOT:-/srv/storage/cf-agent-wechat}}}"
while [ "$RUNTIME_ROOT" != "/" ] && [[ "$RUNTIME_ROOT" == */ ]]; do
  RUNTIME_ROOT="${RUNTIME_ROOT%/}"
done
if [ "$RUNTIME_ROOT" = "/" ]; then
  DEFAULT_TOKEN_FILE="/secrets/auth-token"
else
  DEFAULT_TOKEN_FILE="${RUNTIME_ROOT}/secrets/auth-token"
fi
TOKEN_FILE="${TOKEN_FILE:-$DEFAULT_TOKEN_FILE}"
SESSION_ID="${SESSION_ID:-default}"
CONTAINER_NAME="${_ENV_CONTAINER_NAME:-${CONTAINER_NAME:-${AGENT_WECHAT_CONTAINER_NAME:-cf-agent-wechat}}}"

HTTP_CONNECT_TIMEOUT="${HTTP_CONNECT_TIMEOUT:-5}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-45}"
LOGIN_TIMEOUT_MS="${LOGIN_TIMEOUT_MS:-300000}"
LOGIN_CONFIRM_RETRIES="${LOGIN_CONFIRM_RETRIES:-5}"
LOGIN_CONFIRM_INTERVAL="${LOGIN_CONFIRM_INTERVAL:-2}"
STATUS_WAIT_TIMEOUT="${STATUS_WAIT_TIMEOUT:-180}"
STATUS_POLL_INTERVAL="${STATUS_POLL_INTERVAL:-2}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
CURL_BIN="${CURL_BIN:-curl}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${SCRIPTS_DIR}/requirements.txt}"
if [ -n "${XDG_DATA_HOME:-}" ]; then
  _DEFAULT_DATA_HOME="$XDG_DATA_HOME"
elif [ -n "${HOME:-}" ]; then
  _DEFAULT_DATA_HOME="${HOME}/.local/share"
else
  _DEFAULT_DATA_HOME=""
fi
VENV_DIR="${CF_AGENT_WECHAT_VENV:-${_DEFAULT_DATA_HOME:+${_DEFAULT_DATA_HOME}/cf-agent-wechat/venv}}"

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
  local normalized_runtime_a normalized_runtime_b

  if [ -n "$_MANAGEMENT_ENV_ERROR" ]; then
    LAST_ERROR="$_MANAGEMENT_ENV_ERROR"
    return 1
  fi

  if [ -n "$_ENV_RUNTIME_ROOT" ]; then
    if [ "${CF_RUNTIME_ROOT+x}" = x ]; then
      if ! normalized_runtime_a="$(normalize_management_path "$CF_RUNTIME_ROOT")" ||
        [ "$normalized_runtime_a" != "$_ENV_RUNTIME_ROOT" ]; then
        LAST_ERROR="CF_RUNTIME_ROOT 与 docker/.env 中持久化的 runtime root 冲突。"
        return 1
      fi
    fi
    if [ "${CF_AGENT_WECHAT_RUNTIME_ROOT+x}" = x ]; then
      if ! normalized_runtime_a="$(normalize_management_path "$CF_AGENT_WECHAT_RUNTIME_ROOT")" ||
        [ "$normalized_runtime_a" != "$_ENV_RUNTIME_ROOT" ]; then
        LAST_ERROR="CF_AGENT_WECHAT_RUNTIME_ROOT 与 docker/.env 中持久化的 runtime root 冲突。"
        return 1
      fi
    fi
    if [ "${CF_AGENT_WECHAT_STORAGE_ROOT+x}" = x ]; then
      if ! normalized_runtime_a="$(normalize_management_path "$CF_AGENT_WECHAT_STORAGE_ROOT")" ||
        [ "$normalized_runtime_a" != "$_ENV_RUNTIME_ROOT" ]; then
        LAST_ERROR="CF_AGENT_WECHAT_STORAGE_ROOT 与 docker/.env 中持久化的 runtime root 冲突。"
        return 1
      fi
    fi
    if [ "$_PROCESS_TOKEN_FILE_SET" = x ] &&
      [ "$_PROCESS_TOKEN_FILE" != "$DEFAULT_TOKEN_FILE" ]; then
      LAST_ERROR="TOKEN_FILE 必须精确匹配 docker/.env runtime 派生路径 ${DEFAULT_TOKEN_FILE}。"
      return 1
    fi
  fi

  if [ "${CF_RUNTIME_ROOT+x}" = x ] &&
    [ "${CF_AGENT_WECHAT_RUNTIME_ROOT+x}" = x ]; then
    if ! normalized_runtime_a="$(normalize_management_path "$CF_RUNTIME_ROOT")" ||
      ! normalized_runtime_b="$(normalize_management_path "$CF_AGENT_WECHAT_RUNTIME_ROOT")" ||
      [ "$normalized_runtime_a" != "$normalized_runtime_b" ]; then
      LAST_ERROR="CF_RUNTIME_ROOT 与 CF_AGENT_WECHAT_RUNTIME_ROOT 必须指向同一目录。"
      return 1
    fi
  fi

  if [ -n "$_ENV_BIND_IP" ] &&
    [ "${AGENT_WECHAT_BIND_IP+x}" = x ] &&
    [ "$AGENT_WECHAT_BIND_IP" != "$_ENV_BIND_IP" ]; then
    LAST_ERROR="AGENT_WECHAT_BIND_IP 与 docker/.env 中持久化的 bind IP 冲突。"
    return 1
  fi
  if [ -n "$_ENV_PORT" ] &&
    [ "${AGENT_WECHAT_PORT+x}" = x ] &&
    [ "$AGENT_WECHAT_PORT" != "$_ENV_PORT" ]; then
    LAST_ERROR="AGENT_WECHAT_PORT 与 docker/.env 中持久化的端口冲突。"
    return 1
  fi
  if [ -n "$_ENV_CONTAINER_NAME" ]; then
    if [ "${AGENT_WECHAT_CONTAINER_NAME+x}" = x ] &&
      [ "$AGENT_WECHAT_CONTAINER_NAME" != "$_ENV_CONTAINER_NAME" ]; then
      LAST_ERROR="AGENT_WECHAT_CONTAINER_NAME 与 docker/.env 中持久化的容器名冲突。"
      return 1
    fi
    if [ "$_PROCESS_CONTAINER_NAME_SET" = x ] &&
      [ "$_PROCESS_CONTAINER_NAME" != "$_ENV_CONTAINER_NAME" ]; then
      LAST_ERROR="CONTAINER_NAME 与 docker/.env 中持久化的容器名冲突。"
      return 1
    fi
  fi
  case "$RUNTIME_ROOT" in
    /)
      LAST_ERROR="CF_RUNTIME_ROOT 不能是文件系统根目录 /。"
      return 1
      ;;
    /*) ;;
    *)
      LAST_ERROR="CF_RUNTIME_ROOT 必须是绝对路径：${RUNTIME_ROOT}"
      return 1
      ;;
  esac
  case "$RUNTIME_ROOT" in
    *[[:cntrl:]]*|*/../*|*/..)
      LAST_ERROR="CF_RUNTIME_ROOT 包含不允许的路径或控制字符：${RUNTIME_ROOT}"
      return 1
      ;;
  esac
  if [ "$MANAGEMENT_BIND_IP" != "127.0.0.1" ]; then
    LAST_ERROR="AGENT_WECHAT_BIND_IP 必须是 127.0.0.1。"
    return 1
  fi
  if ! [[ "$MANAGEMENT_PORT" =~ ^[1-9][0-9]*$ ]] ||
    [ "$MANAGEMENT_PORT" -gt 65535 ]; then
    LAST_ERROR="AGENT_WECHAT_PORT 必须是 1 到 65535 的整数。"
    return 1
  fi
  if ! [[ "$HTTP_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="HTTP_CONNECT_TIMEOUT 必须是正整数秒。"
    return 1
  fi
  if ! [[ "$HTTP_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="HTTP_TIMEOUT 必须是正整数秒。"
    return 1
  fi
  if ! [[ "$CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    LAST_ERROR="agent-wechat 容器名无效。"
    return 1
  fi

  case "$TOKEN_FILE" in
    /*) ;;
    *)
      LAST_ERROR="TOKEN_FILE 必须是绝对路径：${TOKEN_FILE}"
      return 1
      ;;
  esac
  case "$TOKEN_FILE" in
    *[[:cntrl:]]*|*/../*|*/..)
      LAST_ERROR="TOKEN_FILE 包含不允许的路径或控制字符：${TOKEN_FILE}"
      return 1
      ;;
  esac

  if [ "$API_URL" != "http://127.0.0.1:${MANAGEMENT_PORT}" ]; then
    LAST_ERROR="API_URL 必须精确匹配本机生产端点 http://127.0.0.1:${MANAGEMENT_PORT}。"
    return 1
  fi
  if [ "$_PROCESS_HEALTH_URL_SET" = x ] &&
    [ "$_PROCESS_HEALTH_URL" != "$HEALTH_URL" ]; then
    LAST_ERROR="HEALTH_URL 不能独立覆盖；它必须由 API_URL 推导。"
    return 1
  fi
  if [ "$_PROCESS_WS_URL_SET" = x ] &&
    [ "$_PROCESS_WS_URL" != "$WS_URL" ]; then
    LAST_ERROR="WS_URL 不能独立覆盖；它必须由 API_URL 推导。"
    return 1
  fi

  if [ "$SESSION_ID" != default ]; then
    LAST_ERROR="生产 SESSION_ID 必须是 default。"
    return 1
  fi
  if ! [[ "$LOGIN_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="LOGIN_TIMEOUT_MS 必须是正整数。"
    return 1
  fi
  if ! [[ "$LOGIN_CONFIRM_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="LOGIN_CONFIRM_RETRIES 必须是正整数。"
    return 1
  fi
  if ! [[ "$LOGIN_CONFIRM_INTERVAL" =~ ^[0-9]+$ ]]; then
    LAST_ERROR="LOGIN_CONFIRM_INTERVAL 必须是非负整数秒。"
    return 1
  fi
  if ! [[ "$STATUS_WAIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="STATUS_WAIT_TIMEOUT 必须是正整数秒。"
    return 1
  fi
  if ! [[ "$STATUS_POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    LAST_ERROR="STATUS_POLL_INTERVAL 必须是正整数秒。"
    return 1
  fi

}

validate_token_file_content() {
  local token_path="$1"

  /usr/bin/od -An -v -t u1 -- "$token_path" | /usr/bin/awk '
    BEGIN {
      content_bytes = 0
      line_ended = 0
      bad_format = 0
      too_long = 0
      bad_control = 0
    }
    {
      for (field = 1; field <= NF; field++) {
        byte = $field + 0
        if (byte == 10) {
          if (content_bytes == 0 || line_ended) {
            bad_format = 1
          }
          line_ended = 1
        } else {
          if (line_ended) {
            bad_format = 1
          }
          content_bytes++
          if (content_bytes > 8192) {
            too_long = 1
          }
          if (byte < 32 || byte == 127) {
            bad_control = 1
          }
        }
      }
    }
    END {
      if (content_bytes == 0 || bad_format) {
        exit 48
      }
      if (too_long) {
        exit 49
      }
      if (bad_control) {
        exit 50
      }
    }
  '
}

set_token_content_error() {
  case "$1" in
    48) LAST_ERROR="token 文件必须只包含一行非空 token：${TOKEN_FILE}" ;;
    49) LAST_ERROR="token 内容不能超过 8192 字节：${TOKEN_FILE}" ;;
    50) LAST_ERROR="token 不能包含 C0 或 DEL 控制字符：${TOKEN_FILE}" ;;
    *) LAST_ERROR="无法验证 token 文件内容：${TOKEN_FILE}" ;;
  esac
}

load_auth_token() {
  local token_value token_status metadata token_dir current_uid

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
    if [ "$TOKEN_FILE" = "$PRIVILEGED_TOKEN_FILE" ]; then
      if [ -L "$PRIVILEGED_SECRETS_DIR" ] || [ ! -d "$PRIVILEGED_SECRETS_DIR" ]; then
        LAST_ERROR="secrets 路径必须是非符号链接目录：$PRIVILEGED_SECRETS_DIR"
        return 1
      fi
      if ! metadata="$(/usr/bin/stat -c '%u:%g:%a' -- "$PRIVILEGED_SECRETS_DIR")" ||
        [ "$metadata" != "0:0:700" ]; then
        LAST_ERROR="secrets 目录必须保持 root:root 700：$PRIVILEGED_SECRETS_DIR"
        return 1
      fi
      if ! metadata="$(/usr/bin/stat -c '%u:%g:%a' -- "$TOKEN_FILE")" ||
        [ "$metadata" != "0:0:600" ]; then
        LAST_ERROR="auth-token 必须保持 root:root 600：$TOKEN_FILE"
        return 1
      fi
    elif [ "$(/usr/bin/uname -s)" = "Linux" ]; then
      token_dir="$(/usr/bin/dirname -- "$TOKEN_FILE")"
      if [ -L "$token_dir" ] || [ ! -d "$token_dir" ]; then
        LAST_ERROR="自定义 secrets 路径必须是非符号链接目录：$token_dir"
        return 1
      fi
      if ! current_uid="$(/usr/bin/id -u)"; then
        LAST_ERROR="无法确定当前管理用户 UID。"
        return 1
      fi
      if ! metadata="$(/usr/bin/stat -c '%u:%a' -- "$token_dir")" ||
        [ "$metadata" != "$current_uid:700" ]; then
        LAST_ERROR="自定义 secrets 目录必须由当前管理用户持有且 mode 700：$token_dir"
        return 1
      fi
      if ! metadata="$(/usr/bin/stat -c '%u:%a' -- "$TOKEN_FILE")" ||
        [ "$metadata" != "$current_uid:600" ]; then
        LAST_ERROR="自定义 auth-token 必须由当前管理用户持有且 mode 600：$TOKEN_FILE"
        return 1
      fi
    fi
    if validate_token_file_content "$TOKEN_FILE"; then
      token_status=0
    else
      token_status=$?
    fi
    if [ "$token_status" -ne 0 ]; then
      set_token_content_error "$token_status"
      return 1
    fi
    if ! token_value="$(/bin/cat -- "$TOKEN_FILE")"; then
      LAST_ERROR="无法读取 token 文件：${TOKEN_FILE}"
      return 1
    fi
  else
    if [ "$TOKEN_FILE" != "$PRIVILEGED_TOKEN_FILE" ]; then
      if [ "$TOKEN_FILE" = "$DEFAULT_TOKEN_FILE" ]; then
        LAST_ERROR="当前用户无法读取自定义 runtime 的 token：${TOKEN_FILE}；sudo 自动读取仅允许批准路径 ${PRIVILEGED_TOKEN_FILE}"
      else
        LAST_ERROR="当前用户无法读取自定义 token 路径：${TOKEN_FILE}；sudo 自动读取仅允许批准路径 ${PRIVILEGED_TOKEN_FILE}"
      fi
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
/usr/bin/od -An -v -t u1 -- "$token_file" | /usr/bin/awk "
  BEGIN {
    content_bytes = 0
    line_ended = 0
    bad_format = 0
    too_long = 0
    bad_control = 0
  }
  {
    for (field = 1; field <= NF; field++) {
      byte = \$field + 0
      if (byte == 10) {
        if (content_bytes == 0 || line_ended) {
          bad_format = 1
        }
        line_ended = 1
      } else {
        if (line_ended) {
          bad_format = 1
        }
        content_bytes++
        if (content_bytes > 8192) {
          too_long = 1
        }
        if (byte < 32 || byte == 127) {
          bad_control = 1
        }
      }
    }
  }
  END {
    if (content_bytes == 0 || bad_format) {
      exit 48
    }
    if (too_long) {
      exit 49
    }
    if (bad_control) {
      exit 50
    }
  }
"
token_status=$?
if [ "$token_status" -ne 0 ]; then
  exit "$token_status"
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
      48) LAST_ERROR="token 文件必须只包含一行非空 token：${TOKEN_FILE}" ;;
      49) LAST_ERROR="token 内容不能超过 8192 字节：${TOKEN_FILE}" ;;
      50) LAST_ERROR="token 不能包含 C0 或 DEL 控制字符：${TOKEN_FILE}" ;;
      *) LAST_ERROR="当前用户无法读取 token，且没有可用的 sudo 权限：${TOKEN_FILE}" ;;
    esac
    if [ "$token_status" -ne 0 ]; then
      return 1
    fi
  fi

  AUTH_TOKEN="$token_value"
  export -n AUTH_TOKEN
}

api_request() {
  local method="$1"
  local path="$2"
  local request_timeout="${3:-$HTTP_TIMEOUT}"

  printf 'Authorization: Bearer %s\nX-Session-Id: %s\n' \
    "$AUTH_TOKEN" "$SESSION_ID" | "$CURL_BIN" \
    --disable \
    --noproxy '*' \
    --request "$method" \
    --fail \
    --silent \
    --show-error \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
    --max-time "$request_timeout" \
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

if any(ord(character) < 0x20 or ord(character) == 0x7F for character in status):
    print("status contains an invalid control character.", file=sys.stderr)
    raise SystemExit(2)

sys.stdout.write(status)
')"; then
    LAST_ERROR="无法解析 agent-wechat 认证状态。"
    return 1
  fi

  AUTH_STATUS="$parsed"
}

fetch_auth_status() {
  local response
  local request_timeout="${1:-$HTTP_TIMEOUT}"

  if ! response="$(api_request GET /api/status/auth "$request_timeout" 2>&1)"; then
    LAST_ERROR="认证状态接口调用失败：${response}"
    return 1
  fi
  parse_auth_response "$response"
}

auth_status_is_login_pending() {
  case "$1" in
    logged_out|qr_pending|waiting_for_qr|waiting_for_scan) return 0 ;;
    *) return 1 ;;
  esac
}

check_api_health() {
  local request_timeout="${1:-$HTTP_TIMEOUT}"

  if ! "$CURL_BIN" \
    --disable \
    --noproxy '*' \
    --request GET \
    --fail \
    --silent \
    --show-error \
    --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
    --max-time "$request_timeout" \
    "$HEALTH_URL" >/dev/null 2>&1; then
    LAST_ERROR="agent-wechat health API 不可用：${HEALTH_URL}"
    return 1
  fi
}

detect_container_status() {
  local inspect_output inspect_status inspect_state error_lower line

  if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
    return 1
  fi

  if inspect_output="$(
    LC_ALL=C "$DOCKER_BIN" inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>&1
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
      sudo -- "$DOCKER_BIN" inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null
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

detect_container_health() {
  local inspect_output inspect_status health_status error_lower line

  if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
    return 1
  fi

  if inspect_output="$(
    LC_ALL=C "$DOCKER_BIN" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>&1
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
      sudo -- "$DOCKER_BIN" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null
    )"; then
      return 1
    fi
  fi

  health_status=""
  while IFS= read -r line; do
    case "$line" in
      healthy|starting|unhealthy|none)
        if [ -n "$health_status" ] && [ "$health_status" != "$line" ]; then
          return 1
        fi
        health_status="$line"
        ;;
    esac
  done <<< "$inspect_output"

  [ -n "$health_status" ] || return 1
  printf '%s' "$health_status"
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
      LAST_ERROR="登录工具依赖安装失败。"
      return 1
    fi
    printf '%s\n' "$requirements_checksum" > "$stamp_file"
  fi
}
