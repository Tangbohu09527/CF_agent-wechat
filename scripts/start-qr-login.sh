#!/bin/bash -p
set -euo pipefail

set +x
set +a
unset _CF_AGENT_WECHAT_TEST_CALLER_PATH
_CF_AGENT_WECHAT_TEST_CALLER_PATH="${PATH:-}"
readonly _CF_AGENT_WECHAT_TEST_CALLER_PATH
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LANG=C.UTF-8
LC_ALL=C.UTF-8
export PATH LANG LC_ALL
if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
  case "$-" in
    *p*) ;;
    *) printf '%s\n' 'Production management requires direct protected-mode script execution.' >&2; exit 1 ;;
  esac
fi
unset BASH_ENV ENV CDPATH

unset _CF_AGENT_WECHAT_EARLY_OVERRIDES
_CF_AGENT_WECHAT_EARLY_OVERRIDES=""
for _management_env_name in \
    API_URL WS_URL TOKEN_FILE SESSION_ID CONTAINER_NAME PYTHON_BIN \
    REQUIREMENTS_FILE VENV_DIR CF_AGENT_WECHAT_VENV AGENT_WECHAT_IMAGE \
    CF_AGENT_WECHAT_CURL_BIN \
    AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT AGENT_WECHAT_CONTAINER_NAME \
    COMPOSE_PROJECT_NAME PROXY RUST_LOG CF_AGENT_WECHAT_STORAGE_ROOT \
    CF_AGENT_WECHAT_RUNTIME_ROOT CF_AGENT_WECHAT_ARCHIVE_ROOT \
    CF_AGENT_WECHAT_MIN_FREE_BYTES CF_AGENT_WECHAT_MIN_FREE_PERCENT \
    CF_AGENT_WECHAT_MIN_FREE_INODES CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES \
    CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES \
    CF_AGENT_WECHAT_COMPOSE_FILE CF_AGENT_WECHAT_ENV_FILE \
    CF_AGENT_WECHAT_LOCK_FILE CF_AGENT_WECHAT_RUNTIME_UID \
    CF_AGENT_WECHAT_RUNTIME_GID CF_AGENT_WECHAT_RUNTIME_MODE \
    CF_AGENT_WECHAT_MANAGEMENT_GID CF_AGENT_GATEWAY_COMPOSE_FILE \
    CF_AGENT_GATEWAY_PROJECT_DIR CF_AGENT_GATEWAY_ENV_FILE \
    CF_AGENT_GATEWAY_HEARTBEAT_COMMAND \
    CF_AGENT_WECHAT_DOCKER_BIN CF_AGENT_WECHAT_SYSTEMCTL_BIN \
    CF_AGENT_WECHAT_DOCKER_SOCKET_PATH CF_AGENT_WECHAT_DF_BIN \
    CF_AGENT_WECHAT_TEST_ROOT \
    CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT \
    CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT \
    CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT \
    CF_AGENT_WECHAT_TOKEN CF_AGENT_WECHAT_TOKEN_FILE AUTH_TOKEN \
    CF_AGENT_WECHAT_TEST_PIP_INSTALL_TIMEOUT \
    CF_AGENT_WECHAT_TEST_PIP_NETWORK_TIMEOUT \
    CF_AGENT_WECHAT_TEST_PIP_RETRIES \
    CF_AGENT_WECHAT_TEST_VENV_CREATE_TIMEOUT \
    HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy \
    NO_PROXY no_proxy TMPDIR \
    HTTP_CONNECT_TIMEOUT HTTP_TIMEOUT DOCKER_READ_TIMEOUT LOGIN_TIMEOUT_MS \
    LOGIN_CONFIRM_RETRIES LOGIN_CONFIRM_INTERVAL SERVER_READY_TIMEOUT \
    WECHAT_READY_TIMEOUT WECHAT_STABLE_SECONDS POST_LOGIN_READY_TIMEOUT \
    RUNTIME_POLL_INTERVAL DOCKER_COMMAND_TIMEOUT COMPOSE_COMMAND_TIMEOUT \
    WORKER_READY_TIMEOUT WORKER_STABLE_SECONDS WORKER_HEARTBEAT_TIMEOUT \
    TOKEN_SCAN_TIMEOUT ARCHIVE_TOOL_TIMEOUT \
    CF_AGENT_WECHAT_TEST_ARCHIVE_TOOL_TIMEOUT; do
    if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ] &&
      [[ -v $_management_env_name ]]; then
      _CF_AGENT_WECHAT_EARLY_OVERRIDES+="${_CF_AGENT_WECHAT_EARLY_OVERRIDES:+,}${_management_env_name}"
    fi
    if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
      unset "$_management_env_name"
    else
      export -n "${_management_env_name?}" 2>/dev/null || :
      case "$_management_env_name" in
        AUTH_TOKEN|CF_AGENT_WECHAT_TOKEN|PROXY|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|NO_PROXY|no_proxy)
          unset "$_management_env_name"
          ;;
      esac
    fi
  done
for _management_sensitive_name in \
  CF_GATEWAY_API_TOKEN CF_AGENT_GATEWAY_ADMIN_TOKEN HERMES_API_KEY; do
  unset "$_management_sensitive_name"
done
unset _management_sensitive_name
readonly _CF_AGENT_WECHAT_EARLY_OVERRIDES
unset _management_env_name

unset _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR
_management_entry_source="${BASH_SOURCE[0]}"
_management_entry_resolved="$_management_entry_source"
_management_entry_via_fd=0
if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
  case "$_management_entry_source" in
    /proc/self/fd/[0-9]*)
      if ! _management_entry_resolved="$(
        /usr/bin/readlink -f -- "$_management_entry_source" 2>/dev/null
      )"; then
        printf '%s\n' 'Production management entry descriptor is unavailable.' >&2
        exit 1
      fi
      _management_entry_via_fd=1
      ;;
  esac
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$_management_entry_resolved")" && pwd -P)"
if [ "${CF_AGENT_WECHAT_TESTING:-0}" != "1" ]; then
  _management_uid="$(/usr/bin/id -u)"

  _management_validate_node() {
    local path="$1"
    local expected_kind="$2"
    local metadata owner mode links file_type _dev _inode _gid

    if [ -L "$path" ]; then
      printf '%s\n' 'Production management path is a symlink.' >&2
      return 1
    fi
    if ! metadata="$(
      /usr/bin/stat -c '%d:%i:%u:%g:%a:%h:%F' -- "$path" 2>/dev/null
    )"; then
      printf '%s\n' 'Production management path metadata is unavailable.' >&2
      return 1
    fi
    IFS=: read -r _dev _inode owner _gid mode links file_type <<< "$metadata"
    case "$owner" in
      0|"$_management_uid") ;;
      *)
        printf '%s\n' 'Production management path owner is not approved.' >&2
        return 1
        ;;
    esac
    case "$expected_kind" in
      directory)
        if [ "$file_type" != directory ] || [ "$mode" != 755 ]; then
          printf '%s\n' 'Production management directory metadata is unsafe.' >&2
          return 1
        fi
        ;;
      file)
        if [ "$file_type" != 'regular file' ] ||
          [ "$mode" != 755 ] || [ "$links" != 1 ]; then
          printf '%s\n' 'Production management file metadata is unsafe.' >&2
          return 1
        fi
        ;;
      *) return 1 ;;
    esac
    MANAGEMENT_NODE_METADATA="$metadata"
  }

  _management_source_library() {
    local library_path="$1"
    local path_before path_after fd_metadata library_fd
    local content_before content_after fd_content_before fd_content_after
    local library_source="" source_status=0

    _management_validate_node "$library_path" file || return 1
    path_before="$MANAGEMENT_NODE_METADATA"
    if ! exec {library_fd}<"$library_path"; then
      printf '%s\n' 'Production management library could not be opened.' >&2
      return 1
    fi
    if ! fd_metadata="$(
      /usr/bin/stat -Lc '%d:%i:%u:%g:%a:%h:%F' -- \
        "/proc/self/fd/${library_fd}" 2>/dev/null
    )" ||
      [ -L "$library_path" ] ||
      ! path_after="$(
        /usr/bin/stat -c '%d:%i:%u:%g:%a:%h:%F' -- \
          "$library_path" 2>/dev/null
      )" ||
      [ "$path_before" != "$fd_metadata" ] ||
      [ "$path_before" != "$path_after" ] ||
      ! content_before="$(
        /usr/bin/stat -c '%d:%i:%s:%y:%z' -- \
          "$library_path" 2>/dev/null
      )" ||
      ! fd_content_before="$(
        /usr/bin/stat -Lc '%d:%i:%s:%y:%z' -- \
          "/proc/self/fd/${library_fd}" 2>/dev/null
      )" ||
      [ "$content_before" != "$fd_content_before" ]; then
      exec {library_fd}<&-
      printf '%s\n' 'Production management library changed while loading.' >&2
      return 1
    fi
    if IFS= read -r -d '' library_source <&"$library_fd"; then
      library_source=""
      exec {library_fd}<&-
      printf '%s\n' 'Production management library contains a NUL byte.' >&2
      return 1
    fi
    if [ -L "$library_path" ] ||
      ! content_after="$(
        /usr/bin/stat -c '%d:%i:%s:%y:%z' -- \
          "$library_path" 2>/dev/null
      )" ||
      ! fd_content_after="$(
        /usr/bin/stat -Lc '%d:%i:%s:%y:%z' -- \
          "/proc/self/fd/${library_fd}" 2>/dev/null
      )" ||
      [ "$content_after" != "$content_before" ] ||
      [ "$fd_content_after" != "$content_before" ]; then
      library_source=""
      exec {library_fd}<&-
      printf '%s\n' 'Production management library changed while loading.' >&2
      return 1
    fi
    # shellcheck disable=SC1091
    source /dev/stdin <<< "$library_source" || source_status=$?
    if [ -L "$library_path" ] ||
      ! content_after="$(
        /usr/bin/stat -c '%d:%i:%s:%y:%z' -- \
          "$library_path" 2>/dev/null
      )" ||
      ! fd_content_after="$(
        /usr/bin/stat -Lc '%d:%i:%s:%y:%z' -- \
          "/proc/self/fd/${library_fd}" 2>/dev/null
      )" ||
      [ "$content_after" != "$content_before" ] ||
      [ "$fd_content_after" != "$content_before" ]; then
      library_source=""
      exec {library_fd}<&-
      printf '%s\n' 'Production management library changed while loading.' >&2
      return 1
    fi
    library_source=""
    exec {library_fd}<&-
    [ "$source_status" -eq 0 ] || return "$source_status"
  }

  if [ "${_management_entry_resolved##*/}" != start-qr-login.sh ] ||
    ! _management_validate_node "$SCRIPT_DIR" directory ||
    ! _management_validate_node "${SCRIPT_DIR}/start-qr-login.sh" file; then
    exit 1
  fi
  _management_entry_path_metadata="$MANAGEMENT_NODE_METADATA"
  if [ "$_management_entry_via_fd" -eq 1 ]; then
    if ! _management_entry_fd_metadata="$(
      /usr/bin/stat -Lc '%d:%i:%u:%g:%a:%h:%F' -- \
        "$_management_entry_source" 2>/dev/null
    )" ||
      [ "$_management_entry_path_metadata" != \
        "$_management_entry_fd_metadata" ]; then
      printf '%s\n' 'Production management entry descriptor is unsafe.' >&2
      exit 1
    fi
  elif [ -L "$_management_entry_source" ]; then
    printf '%s\n' 'Production management entry is a symlink.' >&2
    exit 1
  fi
  _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR="$SCRIPT_DIR"
  readonly _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR

  _management_source_library "${SCRIPT_DIR}/common.sh" || exit 1
  _management_source_library "${SCRIPT_DIR}/qr-runtime-common.sh" || exit 1
  unset -f _management_validate_node _management_source_library
  unset _management_uid MANAGEMENT_NODE_METADATA \
    _management_entry_fd_metadata _management_entry_path_metadata
else
  # shellcheck source=common.sh
  source "${SCRIPT_DIR}/common.sh" || exit 1
  # shellcheck source=qr-runtime-common.sh
  source "${SCRIPT_DIR}/qr-runtime-common.sh" || exit 1
fi
if [ "${CF_AGENT_WECHAT_COMMON_LOADED:-0}" != 1 ] ||
  [ "${CF_AGENT_WECHAT_RUNTIME_COMMON_LOADED:-0}" != 1 ]; then
  printf '%s\n' 'Management libraries did not load completely.' >&2
  exit 1
fi
if ! restore_testing_management_path "$_CF_AGENT_WECHAT_TEST_CALLER_PATH"; then
  error "${LAST_ERROR:-Testing command path is not isolated.}"
  exit 1
fi
if ! runtime_validate_testing_isolation; then
  error "${LAST_ERROR:-Testing management assets are not isolated.}"
  exit 1
fi
unset _management_entry_resolved _management_entry_source \
  _management_entry_via_fd

DRY_RUN=0
FLOW_COMPLETE=0
WORKER_GUARD=0
WORKER_STOP_CONFIRMED=0
QR_LOGIN_HELPER_PID=""
AGENT_CLEANUP_GUARD=0
CANDIDATE_TEMP_RUNTIME=0
AGENT_FAILURE_CLEANUP_ATTEMPTED=false
AGENT_FAILURE_CLEANUP_STOP_RESULT="not_attempted"
AGENT_FAILURE_CLEANUP_REMOVE_RESULT="not_attempted"
FLOW_PHASE="initializing"
FLOW_STARTED_AT=""
ARCHIVE_PATH=""
ARCHIVE_STAGING_PATH=""
ARCHIVE_RESULT="not_attempted"
MANIFEST_AVAILABLE=0
SOURCE_LAYOUT="none"
ARCHIVE_TOKEN_SCAN_STATUS="not_applicable"

RUNTIME_EXISTS=false
RUNTIME_UID="$RUNTIME_DEFAULT_UID"
RUNTIME_GID="$RUNTIME_DEFAULT_GID"
RUNTIME_MODE="$RUNTIME_DEFAULT_MODE"
DATA_EXISTS=false
DATA_UID="$RUNTIME_DEFAULT_UID"
DATA_GID="$RUNTIME_DEFAULT_GID"
DATA_MODE="$RUNTIME_DEFAULT_MODE"
HOME_EXISTS=false
HOME_UID="$RUNTIME_DEFAULT_UID"
HOME_GID="$RUNTIME_DEFAULT_GID"
HOME_MODE="$RUNTIME_DEFAULT_MODE"
ARCHIVE_OWNER_UID=0
ARCHIVE_OWNER_GID=0
if [ "$CF_AGENT_WECHAT_TESTING" = "1" ] && [ "$(id -u)" -ne 0 ]; then
  ARCHIVE_OWNER_UID="$(id -u)"
  ARCHIVE_OWNER_GID="$(id -g)"
fi

usage() {
  cat <<'EOF'
Usage: ./scripts/start-qr-login.sh [--dry-run]

Create a fresh production runtime, require a new QR login, validate the
WeChat runtime and message APIs, then start Gateway wechat-worker.
EOF
}

directory_metadata() {
  local path="$1"
  local default_uid="$2"
  local default_gid="$3"
  local default_mode="$4"

  if runtime_privileged test -L "$path"; then
    LAST_ERROR="Runtime source path must not be a symlink."
    return 1
  elif runtime_privileged test -d "$path"; then
    if ! runtime_privileged stat -c $'true\t%u\t%g\t%a' -- "$path"; then
      LAST_ERROR="Directory metadata could not be read."
      return 1
    fi
  elif runtime_path_exists "$path"; then
    LAST_ERROR="Runtime source path is not a directory."
    return 1
  else
    printf 'false\t%s\t%s\t%s\n' \
      "$default_uid" "$default_gid" "$default_mode"
  fi
}

capture_runtime_metadata() {
  local metadata

  SOURCE_LAYOUT="none"
  if runtime_privileged test -d "$RUNTIME_ROOT"; then
    SOURCE_LAYOUT="runtime"
  elif runtime_privileged test -d "$LEGACY_DATA_ROOT" ||
    runtime_privileged test -d "$LEGACY_WECHAT_HOME_ROOT"; then
    SOURCE_LAYOUT="legacy"
  fi

  if ! metadata="$(directory_metadata "$RUNTIME_ROOT" \
    "$RUNTIME_DEFAULT_UID" "$RUNTIME_DEFAULT_GID" "$RUNTIME_DEFAULT_MODE")"; then
    return 1
  fi
  IFS=$'\t' read -r RUNTIME_EXISTS RUNTIME_UID RUNTIME_GID RUNTIME_MODE \
    <<< "$metadata"

  if [ "$SOURCE_LAYOUT" = "legacy" ]; then
    if ! metadata="$(directory_metadata "$LEGACY_DATA_ROOT" \
      "$RUNTIME_DEFAULT_UID" "$RUNTIME_DEFAULT_GID" "$RUNTIME_DEFAULT_MODE")"; then
      return 1
    fi
    IFS=$'\t' read -r DATA_EXISTS DATA_UID DATA_GID DATA_MODE <<< "$metadata"
    if ! metadata="$(directory_metadata "$LEGACY_WECHAT_HOME_ROOT" \
      "$RUNTIME_DEFAULT_UID" "$RUNTIME_DEFAULT_GID" "$RUNTIME_DEFAULT_MODE")"; then
      return 1
    fi
    IFS=$'\t' read -r HOME_EXISTS HOME_UID HOME_GID HOME_MODE <<< "$metadata"
  else
    if ! metadata="$(directory_metadata "${RUNTIME_ROOT}/data" \
      "$RUNTIME_DEFAULT_UID" "$RUNTIME_DEFAULT_GID" "$RUNTIME_DEFAULT_MODE")"; then
      return 1
    fi
    IFS=$'\t' read -r DATA_EXISTS DATA_UID DATA_GID DATA_MODE <<< "$metadata"
    if ! metadata="$(directory_metadata "${RUNTIME_ROOT}/wechat-home" \
      "$RUNTIME_DEFAULT_UID" "$RUNTIME_DEFAULT_GID" "$RUNTIME_DEFAULT_MODE")"; then
      return 1
    fi
    IFS=$'\t' read -r HOME_EXISTS HOME_UID HOME_GID HOME_MODE <<< "$metadata"
  fi
}

write_manifest() {
  local result="$1"
  local ended_at="$2"
  local temp_file manifest_dir

  [ "$MANIFEST_AVAILABLE" -eq 1 ] || return 0
  manifest_dir="${ARCHIVE_STAGING_PATH:-$ARCHIVE_PATH}"
  if ! runtime_privileged test -d "$manifest_dir"; then
    LAST_ERROR="Archive manifest directory is unavailable."
    return 1
  fi
  if ! temp_file="$(mktemp)"; then
    LAST_ERROR="Temporary manifest file could not be created."
    return 1
  fi
  if ! run_isolated_python - \
    "$temp_file" "$result" "$FLOW_PHASE" "$FLOW_STARTED_AT" "$ended_at" \
    "$ARCHIVE_RESULT" "$SOURCE_LAYOUT" "$RUNTIME_ROOT" "$LEGACY_DATA_ROOT" \
    "$LEGACY_WECHAT_HOME_ROOT" "$ARCHIVE_PATH" "$AGENT_IMAGE_DIGEST" \
    "$RUNTIME_EXISTS" "$RUNTIME_UID" "$RUNTIME_GID" "$RUNTIME_MODE" \
    "$DATA_EXISTS" "$DATA_UID" "$DATA_GID" "$DATA_MODE" \
    "$HOME_EXISTS" "$HOME_UID" "$HOME_GID" "$HOME_MODE" \
    "$AGENT_FAILURE_CLEANUP_ATTEMPTED" \
    "$AGENT_FAILURE_CLEANUP_STOP_RESULT" \
    "$AGENT_FAILURE_CLEANUP_REMOVE_RESULT" \
    "$ARCHIVE_OWNER_UID" "$ARCHIVE_OWNER_GID" "$ARCHIVE_TOKEN_SCAN_STATUS" <<'PY'
import json
import sys
from pathlib import Path

(
    output,
    result,
    phase,
    started,
    ended,
    archive_result,
    source_layout,
    source_runtime,
    legacy_data,
    legacy_wechat_home,
    archive_path,
    image_reference,
    runtime_exists,
    runtime_uid,
    runtime_gid,
    runtime_mode,
    data_exists,
    data_uid,
    data_gid,
    data_mode,
    home_exists,
    home_uid,
    home_gid,
    home_mode,
    cleanup_attempted,
    cleanup_stop,
    cleanup_remove,
    archive_owner_uid,
    archive_owner_gid,
    archive_token_scan_status,
) = sys.argv[1:]

def metadata(exists, uid, gid, mode):
    return {
        "exists": exists == "true",
        "uid": int(uid),
        "gid": int(gid),
        "mode": mode,
    }

if "@sha256:" not in image_reference:
    raise SystemExit(2)
image_digest = image_reference.rsplit("@", 1)[1]

if archive_token_scan_status not in {
    "not_applicable", "preflight_passed", "verified", "failed"
}:
    raise SystemExit(2)

payload = {
    "schemaVersion": 2,
    "runtimeMode": "forced_qr",
    "result": result,
    "archiveResult": archive_result,
    "phase": phase,
    "startedAtUtc": started,
    "endedAtUtc": ended or None,
    "sourceLayout": source_layout,
    "sourcePaths": (
        [source_runtime]
        if source_layout == "runtime"
        else [
            path
            for path, exists in (
                (legacy_data, data_exists == "true"),
                (legacy_wechat_home, home_exists == "true"),
            )
            if exists
        ]
    ),
    "archivePath": archive_path,
    "imageReference": image_reference,
    "imageDigest": image_digest,
    "originalPermissions": {
        "runtime": metadata(
            runtime_exists, runtime_uid, runtime_gid, runtime_mode
        ),
        "data": metadata(data_exists, data_uid, data_gid, data_mode),
        "wechatHome": metadata(home_exists, home_uid, home_gid, home_mode),
    },
    "manifestData": {
        "tokenIncluded": False,
        "accountIdentifiersIncluded": False,
        "chatIdentifiersIncluded": False,
        "messageContentIncluded": False,
    },
    "archivePayloadClassification": {
        "mayContainWechatSession": True,
        "mayContainAccountIdentifiers": True,
        "mayContainChatIdentifiers": True,
        "mayContainMessageMetadata": True,
        "mayContainMessageContent": True,
        "containsIndependentAgentApiToken": (
            False if archive_token_scan_status == "verified" else None
        ),
        "independentAgentApiTokenScan": archive_token_scan_status,
        "accessClassification": "restricted",
        "productionSessionRecoveryAllowed": False,
    },
    "archiveProtection": {
        "archiveRootOwnerUid": int(archive_owner_uid),
        "archiveRootOwnerGid": int(archive_owner_gid),
        "archiveRootMode": "700",
        "archiveTopLevelMode": "700",
        "manifestMode": "600",
        "automaticUploadAllowed": False,
        "automaticDeletionAllowed": False,
    },
    "failureCleanup": {
        "attempted": cleanup_attempted == "true",
        "agentContainerStop": cleanup_stop,
        "agentContainerRemove": cleanup_remove,
        "volumesRemoved": False,
    },
}
Path(output).write_text(
    json.dumps(payload, ensure_ascii=True, indent=2) + "\n",
    encoding="utf-8",
)
PY
  then
    rm -f -- "$temp_file"
    return 1
  fi

  if ! runtime_privileged_isolated_python "$ARCHIVE_TOOL_TIMEOUT" - \
    "$manifest_dir" "$temp_file" "$ARCHIVE_OWNER_UID" "$ARCHIVE_OWNER_GID" <<'PY'
import json
import os
import stat
import sys

archive_path, source_path, expected_uid, expected_gid = sys.argv[1:]
expected = (int(expected_uid), int(expected_gid))
limit = 128 * 1024
directory_fd = -1
source_fd = -1
temporary_fd = -1
temporary_name = f".manifest.json.{os.getpid()}"

try:
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory_fd = os.open(archive_path, directory_flags)
    directory_metadata = os.fstat(directory_fd)
    if (
        not stat.S_ISDIR(directory_metadata.st_mode)
        or (directory_metadata.st_uid, directory_metadata.st_gid) != expected
        or stat.S_IMODE(directory_metadata.st_mode) != 0o700
    ):
        raise ValueError

    source_before = os.lstat(source_path)
    if (
        not stat.S_ISREG(source_before.st_mode)
        or source_before.st_nlink != 1
        or source_before.st_size <= 0
        or source_before.st_size > limit
    ):
        raise ValueError
    source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    source_flags |= getattr(os, "O_NONBLOCK", 0)
    source_fd = os.open(source_path, source_flags)
    source_opened = os.fstat(source_fd)
    if (source_opened.st_dev, source_opened.st_ino, source_opened.st_size) != (
        source_before.st_dev,
        source_before.st_ino,
        source_before.st_size,
    ):
        raise ValueError
    chunks = []
    size = 0
    while True:
        chunk = os.read(source_fd, min(65536, limit + 1 - size))
        if not chunk:
            break
        size += len(chunk)
        if size > limit:
            raise ValueError
        chunks.append(chunk)
    source_after = os.fstat(source_fd)
    if (
        size != source_opened.st_size
        or source_after.st_size != source_opened.st_size
        or source_after.st_ctime_ns != source_opened.st_ctime_ns
    ):
        raise ValueError
    payload = b"".join(chunks)
    parsed = json.loads(payload.decode("utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError

    temporary_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    temporary_flags |= getattr(os, "O_NOFOLLOW", 0)
    temporary_fd = os.open(
        temporary_name, temporary_flags, 0o600, dir_fd=directory_fd
    )
    os.fchmod(temporary_fd, 0o600)
    os.fchown(temporary_fd, expected[0], expected[1])
    offset = 0
    while offset < len(payload):
        written = os.write(temporary_fd, payload[offset:])
        if written <= 0:
            raise OSError
        offset += written
    os.fsync(temporary_fd)
    os.close(temporary_fd)
    temporary_fd = -1
    os.replace(
        temporary_name, "manifest.json",
        src_dir_fd=directory_fd, dst_dir_fd=directory_fd,
    )
    os.fsync(directory_fd)
except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
    if temporary_fd >= 0:
        os.close(temporary_fd)
    if directory_fd >= 0:
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except OSError:
            pass
    raise SystemExit(1)
finally:
    if source_fd >= 0:
        os.close(source_fd)
    if directory_fd >= 0:
        os.close(directory_fd)
PY
  then
    rm -f -- "$temp_file"
    LAST_ERROR="Archive manifest could not be installed durably."
    return 1
  fi
  rm -f -- "$temp_file"
}

on_exit() {
  local exit_status=$?
  local ended_at original_last_error preserved_archive=""
  local agent_cleanup_failed=0 manifest_write_failed=0 temp_runtime_cleanup_failed=0
  local gate_abort_failed=0

  trap - EXIT
  set +e
  original_last_error="${LAST_ERROR:-}"
  if [ -n "$QR_LOGIN_HELPER_PID" ]; then
    kill "$QR_LOGIN_HELPER_PID" 2>/dev/null || :
    wait "$QR_LOGIN_HELPER_PID" 2>/dev/null || :
    QR_LOGIN_HELPER_PID=""
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ "$FLOW_COMPLETE" -eq 0 ] &&
    [ "$GATEWAY_GATE_BEGUN" -eq 1 ]; then
    if ! runtime_gateway_gate_abort >/dev/null 2>&1; then
      gate_abort_failed=1
    fi
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ "$FLOW_COMPLETE" -eq 0 ] &&
    [ "$WORKER_GUARD" -eq 1 ]; then
    if stop_gateway_worker >/dev/null 2>&1; then
      WORKER_STOP_CONFIRMED=1
    else
      WORKER_STOP_CONFIRMED=0
    fi
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ "$FLOW_COMPLETE" -eq 0 ] &&
    [ "$AGENT_CLEANUP_GUARD" -eq 1 ]; then
    if ! cleanup_failed_agent_container; then
      agent_cleanup_failed=1
    fi
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ "$FLOW_COMPLETE" -eq 0 ] &&
    [ "$CANDIDATE_TEMP_RUNTIME" -eq 1 ]; then
    if ! remove_temporary_candidate_runtime; then
      temp_runtime_cleanup_failed=1
    fi
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ "$FLOW_COMPLETE" -eq 0 ] &&
    [ "$MANIFEST_AVAILABLE" -eq 1 ]; then
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! write_manifest failed "$ended_at" >/dev/null 2>&1; then
      manifest_write_failed=1
    fi
  fi
  LAST_ERROR="$original_last_error"
  if [ -n "$ARCHIVE_STAGING_PATH" ] &&
    runtime_path_exists "$ARCHIVE_STAGING_PATH"; then
    preserved_archive="$ARCHIVE_STAGING_PATH"
  elif [ -n "$ARCHIVE_PATH" ] && runtime_path_exists "$ARCHIVE_PATH"; then
    preserved_archive="$ARCHIVE_PATH"
  fi
  if [ "$exit_status" -ne 0 ]; then
    error "Fresh QR runtime failed during phase: $FLOW_PHASE"
    if [ -n "$preserved_archive" ]; then
      error "Archive preserved at: $preserved_archive"
    else
      error "Archive path: not created"
    fi
    if [ "$WORKER_GUARD" -eq 1 ] && [ "$WORKER_STOP_CONFIRMED" -eq 1 ]; then
      error "Gateway wechat-worker remains stopped; AI scheduling was not started."
    elif [ "$WORKER_GUARD" -eq 1 ]; then
      error "Gateway wechat-worker stop could not be confirmed; its state is unknown. Treat AI scheduling as active and stop it manually before retrying."
    fi
    if [ "$AGENT_FAILURE_CLEANUP_ATTEMPTED" = true ]; then
      if [ "$agent_cleanup_failed" -eq 0 ]; then
        error "Failed-flow cleanup stopped and removed the agent-wechat container; persistent runtime evidence was preserved."
      else
        error "Failed-flow agent-wechat cleanup encountered errors (stop: ${AGENT_FAILURE_CLEANUP_STOP_RESULT}; remove: ${AGENT_FAILURE_CLEANUP_REMOVE_RESULT})."
      fi
    fi
    if [ "$temp_runtime_cleanup_failed" -eq 1 ]; then
      error "Temporary candidate Runtime cleanup failed; inspect it before retrying."
    fi
    if [ "$manifest_write_failed" -eq 1 ]; then
      error "The failed-flow manifest could not be updated with cleanup results."
    fi
    if [ "$gate_abort_failed" -eq 1 ]; then
      error "Gateway runtime generation revocation could not be confirmed; keep the Worker stopped and repair the published release gate before retrying."
    fi
  fi
  exit "$exit_status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

validate_operator_terminal() {
  local operator_uid operator_gid

  if ! operator_uid="$(id -u)" || ! [[ "$operator_uid" =~ ^[0-9]+$ ]] ||
    ! operator_gid="$(id -g)" || ! [[ "$operator_gid" =~ ^[0-9]+$ ]]; then
    LAST_ERROR="The current production operator identity could not be verified."
    return 1
  fi
  if [ "$DRY_RUN" -eq 0 ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
    LAST_ERROR="Fresh QR login requires an interactive controlled terminal on stdin and stdout."
    return 1
  fi
  if [ "$operator_uid" -eq 0 ]; then
    printf '%s\n' \
      'Warning: running as root; prefer the fixed management user with sudo.' >&2
  fi
}

choose_archive_path() {
  local timestamp candidate counter=0

  if ! timestamp="$(date -u +%Y%m%dT%H%M%SZ)"; then
    LAST_ERROR="UTC archive timestamp could not be generated."
    return 1
  fi
  candidate="${ARCHIVE_ROOT}/$timestamp"
  while runtime_path_exists "$candidate"; do
    counter=$((counter + 1))
    if [ "$counter" -gt 99 ]; then
      LAST_ERROR="Archive timestamp collision limit was reached; retry in a new UTC second."
      return 1
    fi
    candidate="${ARCHIVE_ROOT}/${timestamp}-$(printf '%02d' "$counter")"
  done
  ARCHIVE_PATH="$candidate"
}

choose_archive_staging_path() {
  local final_name

  final_name="${ARCHIVE_PATH##*/}"
  ARCHIVE_STAGING_PATH="${ARCHIVE_ROOT}/.incomplete-${final_name}-$$"
  if runtime_path_exists "$ARCHIVE_STAGING_PATH"; then
    LAST_ERROR="Archive staging path already exists; interrupted archive evidence must be inspected before retrying."
    return 1
  fi
}

fsync_archive_directory() {
  local path="$1"

  if ! runtime_privileged_isolated_python "$ARCHIVE_TOOL_TIMEOUT" - \
    "$path" "$ARCHIVE_OWNER_UID" "$ARCHIVE_OWNER_GID" <<'PY'
import os
import stat
import sys

path, expected_uid, expected_gid = sys.argv[1:]
expected = (int(expected_uid), int(expected_gid))
descriptor = -1
try:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or (metadata.st_uid, metadata.st_gid) != expected
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise OSError
    os.fsync(descriptor)
except OSError:
    raise SystemExit(1)
finally:
    if descriptor >= 0:
        os.close(descriptor)
PY
  then
    LAST_ERROR="Archive directory metadata could not be synchronized durably."
    return 1
  fi
}

restrict_archive_staging() {
  MANIFEST_AVAILABLE=1
  if ! runtime_privileged test -d "$ARCHIVE_STAGING_PATH" ||
    ! runtime_privileged chown \
      "${ARCHIVE_OWNER_UID}:${ARCHIVE_OWNER_GID}" "$ARCHIVE_STAGING_PATH" ||
    ! runtime_privileged chmod 700 "$ARCHIVE_STAGING_PATH" ||
    ! fsync_archive_directory "$ARCHIVE_STAGING_PATH" ||
    ! fsync_archive_directory "$ARCHIVE_ROOT"; then
    LAST_ERROR="Archive staging directory could not be restricted and synchronized."
    return 1
  fi
}

remove_empty_archive_staging() {
  if runtime_path_exists "$ARCHIVE_STAGING_PATH"; then
    if ! runtime_privileged rmdir -- "$ARCHIVE_STAGING_PATH" ||
      ! fsync_archive_directory "$ARCHIVE_ROOT"; then
      LAST_ERROR="Empty Archive staging directory could not be removed durably."
      return 1
    fi
  fi
  ARCHIVE_STAGING_PATH=""
  ARCHIVE_PATH=""
  MANIFEST_AVAILABLE=0
}

publish_archive_staging() {
  local staging_name final_name

  staging_name="${ARCHIVE_STAGING_PATH##*/}"
  final_name="${ARCHIVE_PATH##*/}"
  if ! runtime_privileged_isolated_python "$ARCHIVE_TOOL_TIMEOUT" - \
    "$ARCHIVE_ROOT" "$staging_name" "$final_name" \
    "$ARCHIVE_OWNER_UID" "$ARCHIVE_OWNER_GID" <<'PY'
import os
import re
import stat
import sys

root, staging_name, final_name, expected_uid, expected_gid = sys.argv[1:]
expected = (int(expected_uid), int(expected_gid))
final_pattern = re.compile(r"^[0-9]{8}T[0-9]{6}Z(?:-[0-9]{2})?$", re.ASCII)
staging_pattern = re.compile(
    r"^[.]incomplete-[0-9]{8}T[0-9]{6}Z(?:-[0-9]{2})?-[0-9]+$",
    re.ASCII,
)
root_fd = -1
staging_fd = -1
moved = False
try:
    if not final_pattern.fullmatch(final_name):
        raise OSError
    if not staging_pattern.fullmatch(staging_name):
        raise OSError
    required_flags = ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC")
    if any(not hasattr(os, name) for name in required_flags):
        raise OSError
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    root_fd = os.open(root, flags)
    root_metadata = os.fstat(root_fd)
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or (root_metadata.st_uid, root_metadata.st_gid) != expected
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
    ):
        raise OSError
    if os.listxattr(root_fd):
        raise OSError
    root_after_xattrs = os.fstat(root_fd)
    if (
        root_after_xattrs.st_dev,
        root_after_xattrs.st_ino,
        root_after_xattrs.st_ctime_ns,
    ) != (
        root_metadata.st_dev,
        root_metadata.st_ino,
        root_metadata.st_ctime_ns,
    ):
        raise OSError
    staging = os.stat(staging_name, dir_fd=root_fd, follow_symlinks=False)
    if (
        not stat.S_ISDIR(staging.st_mode)
        or (staging.st_uid, staging.st_gid) != expected
        or stat.S_IMODE(staging.st_mode) != 0o700
    ):
        raise OSError
    staging_fd = os.open(staging_name, flags, dir_fd=root_fd)
    opened_staging = os.fstat(staging_fd)
    if (
        opened_staging.st_dev,
        opened_staging.st_ino,
        opened_staging.st_ctime_ns,
    ) != (
        staging.st_dev,
        staging.st_ino,
        staging.st_ctime_ns,
    ):
        raise OSError
    if os.listxattr(staging_fd):
        raise OSError
    staging_after_xattrs = os.fstat(staging_fd)
    if (
        staging_after_xattrs.st_dev,
        staging_after_xattrs.st_ino,
        staging_after_xattrs.st_ctime_ns,
    ) != (
        opened_staging.st_dev,
        opened_staging.st_ino,
        opened_staging.st_ctime_ns,
    ):
        raise OSError
    try:
        os.stat(final_name, dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise OSError
    os.rename(staging_name, final_name, src_dir_fd=root_fd, dst_dir_fd=root_fd)
    moved = True
    archived = os.stat(final_name, dir_fd=root_fd, follow_symlinks=False)
    if (archived.st_dev, archived.st_ino) != (
        opened_staging.st_dev,
        opened_staging.st_ino,
    ):
        raise OSError
    os.fsync(root_fd)
except OSError:
    if moved and root_fd >= 0:
        try:
            archived = os.stat(
                final_name, dir_fd=root_fd, follow_symlinks=False
            )
            if (archived.st_dev, archived.st_ino) != (
                staging.st_dev, staging.st_ino
            ):
                raise OSError
            os.rename(
                final_name, staging_name, src_dir_fd=root_fd, dst_dir_fd=root_fd
            )
            os.fsync(root_fd)
        except OSError:
            pass
    raise SystemExit(1)
finally:
    if staging_fd >= 0:
        os.close(staging_fd)
    if root_fd >= 0:
        os.close(root_fd)
PY
  then
    LAST_ERROR="Archive staging directory could not be published durably."
    return 1
  fi
  ARCHIVE_STAGING_PATH=""
}

revalidate_archive_directory_contract() {
  local runtime_parent archive_parent

  if ! runtime_parent="$(dirname -- "$RUNTIME_ROOT")" ||
    ! archive_parent="$(dirname -- "$ARCHIVE_ROOT")"; then
    LAST_ERROR="Runtime and Archive parents could not be resolved."
    return 1
  fi
  runtime_validate_directory_without_extended_attributes "$STORAGE_ROOT" "Storage root" ||
    return 1
  runtime_validate_directory_without_extended_attributes "${STORAGE_ROOT}/secrets" "Secrets root" ||
    return 1
  runtime_validate_directory_without_extended_attributes "$runtime_parent" "Runtime parent" ||
    return 1
  runtime_validate_directory_without_extended_attributes "$archive_parent" "Archive parent" ||
    return 1
  runtime_validate_restricted_archive_root || return 1
}

archive_current_runtime() {
  local legacy_data_moved=0 published_staging_path=""

  revalidate_archive_directory_contract || return 1
  if ! capture_runtime_metadata; then
    LAST_ERROR="Previous runtime metadata could not be captured."
    return 1
  fi
  case "$SOURCE_LAYOUT" in
    runtime)
      runtime_validate_approved_runtime_directory \
        "$RUNTIME_ROOT" "Runtime root" 1 || return 1
      runtime_validate_approved_runtime_directory \
        "${RUNTIME_ROOT}/data" "Runtime data" 1 || return 1
      runtime_validate_approved_runtime_directory \
        "${RUNTIME_ROOT}/wechat-home" "Runtime WeChat HOME" 1 || return 1
      ;;
    legacy)
      [ "$DATA_EXISTS" != true ] ||
        runtime_validate_approved_runtime_directory \
          "$LEGACY_DATA_ROOT" "Legacy data" 1 || return 1
      [ "$HOME_EXISTS" != true ] ||
        runtime_validate_approved_runtime_directory \
          "$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME" 1 || return 1
      ;;
  esac
  if ! runtime_privileged install -d \
    -o "$ARCHIVE_OWNER_UID" -g "$ARCHIVE_OWNER_GID" -m 700 "$ARCHIVE_ROOT"; then
    LAST_ERROR="Archive root could not be created."
    return 1
  fi
  revalidate_archive_directory_contract || return 1

  if [ "$SOURCE_LAYOUT" = "none" ]; then
    ARCHIVE_RESULT="not_required"
    return 0
  fi

  ARCHIVE_RESULT="failed"
  if ! choose_archive_path || ! choose_archive_staging_path; then
    return 1
  fi
  revalidate_archive_directory_contract || return 1

  if [ "$SOURCE_LAYOUT" = "runtime" ]; then
    if ! runtime_assert_tree_has_no_auth_token \
      "$RUNTIME_ROOT" "Current runtime" "$ARCHIVE_STAGING_PATH" \
      "manifest.json"; then
      ARCHIVE_TOKEN_SCAN_STATUS="failed"
      return 1
    fi
    ARCHIVE_TOKEN_SCAN_STATUS="preflight_passed"
    if runtime_path_exists "$RUNTIME_ROOT" ||
      ! runtime_privileged test -d "$ARCHIVE_STAGING_PATH"; then
      LAST_ERROR="Attested runtime move did not reach its required staging state."
      return 1
    fi
    if ! restrict_archive_staging; then
      return 1
    fi
  else
    if ! runtime_privileged mkdir -- "$ARCHIVE_STAGING_PATH"; then
      LAST_ERROR="Legacy Archive staging directory could not be reserved."
      return 1
    fi
    if ! restrict_archive_staging; then
      return 1
    fi

    if [ "$DATA_EXISTS" = true ]; then
      if ! runtime_assert_tree_has_no_auth_token \
        "$LEGACY_DATA_ROOT" "Legacy data" \
        "${ARCHIVE_STAGING_PATH}/data" ||
        runtime_path_exists "$LEGACY_DATA_ROOT"; then
        ARCHIVE_TOKEN_SCAN_STATUS="failed"
        if runtime_path_exists "$LEGACY_DATA_ROOT" &&
          ! runtime_path_exists "${ARCHIVE_STAGING_PATH}/data"; then
          remove_empty_archive_staging || :
        fi
        LAST_ERROR="Legacy data could not be safely moved into Archive staging."
        return 1
      fi
      legacy_data_moved=1
    fi

    if [ "$HOME_EXISTS" = true ]; then
      if ! runtime_assert_tree_has_no_auth_token \
        "$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME" \
        "${ARCHIVE_STAGING_PATH}/wechat-home" ||
        runtime_path_exists "$LEGACY_WECHAT_HOME_ROOT"; then
        ARCHIVE_TOKEN_SCAN_STATUS="failed"
        if [ "$legacy_data_moved" -eq 1 ]; then
          if ! runtime_assert_tree_has_no_auth_token \
            "${ARCHIVE_STAGING_PATH}/data" "Staged legacy data rollback" \
            "$LEGACY_DATA_ROOT" ||
            runtime_path_exists "${ARCHIVE_STAGING_PATH}/data" ||
            ! runtime_path_exists "$LEGACY_DATA_ROOT"; then
            LAST_ERROR="Legacy Archive staging failed and data rollback was incomplete; inspect the preserved staging directory before retrying."
            return 1
          fi
        fi
        if runtime_path_exists "$LEGACY_WECHAT_HOME_ROOT" &&
          ! runtime_path_exists "${ARCHIVE_STAGING_PATH}/wechat-home"; then
          if ! remove_empty_archive_staging; then
            return 1
          fi
        fi
        LAST_ERROR="Legacy WeChat HOME could not be moved into Archive staging; legacy data was rolled back."
        return 1
      fi
    fi
    ARCHIVE_TOKEN_SCAN_STATUS="preflight_passed"
  fi

  if ! runtime_assert_tree_has_no_auth_token \
    "$ARCHIVE_STAGING_PATH" "Isolated Archive staging payload"; then
    ARCHIVE_TOKEN_SCAN_STATUS="failed"
    return 1
  fi
  ARCHIVE_TOKEN_SCAN_STATUS="verified"
  ARCHIVE_RESULT="succeeded"
  MANIFEST_AVAILABLE=1
  if ! write_manifest in_progress ""; then
    LAST_ERROR="Archive staging manifest could not be initialized durably."
    return 1
  fi

  published_staging_path="$ARCHIVE_STAGING_PATH"
  revalidate_archive_directory_contract || return 1
  if ! publish_archive_staging; then
    return 1
  fi
  if ! runtime_privileged test -d "$ARCHIVE_PATH" ||
    runtime_path_exists "$published_staging_path"; then
    LAST_ERROR="Published Archive did not reach its required final state."
    return 1
  fi
}

create_fresh_runtime() {
  local runtime_parent

  if ! runtime_parent="$(dirname -- "$RUNTIME_ROOT")"; then
    LAST_ERROR="Fresh runtime parent could not be resolved."
    return 1
  fi
  runtime_validate_directory_without_extended_attributes "$runtime_parent" "Runtime parent" ||
    return 1
  if runtime_path_exists "$RUNTIME_ROOT"; then
    LAST_ERROR="Fresh runtime root must not exist before creation."
    return 1
  fi
  if ! runtime_privileged install -d \
    -o "$RUNTIME_DEFAULT_UID" -g "$RUNTIME_DEFAULT_GID" -m "$RUNTIME_DEFAULT_MODE" \
    "$RUNTIME_ROOT"; then
    LAST_ERROR="Fresh runtime root could not be created."
    return 1
  fi
  if ! runtime_privileged install -d \
    -o "$RUNTIME_DEFAULT_UID" -g "$RUNTIME_DEFAULT_GID" -m "$RUNTIME_DEFAULT_MODE" \
    "${RUNTIME_ROOT}/data"; then
    LAST_ERROR="Fresh runtime data directory could not be created."
    return 1
  fi
  if ! runtime_privileged install -d \
    -o "$RUNTIME_DEFAULT_UID" -g "$RUNTIME_DEFAULT_GID" -m "$RUNTIME_DEFAULT_MODE" \
    "${RUNTIME_ROOT}/wechat-home"; then
    LAST_ERROR="Fresh WeChat HOME directory could not be created."
    return 1
  fi
  runtime_validate_approved_runtime_directory \
    "$RUNTIME_ROOT" "Fresh runtime root" 1 || return 1
  runtime_validate_approved_runtime_directory \
    "${RUNTIME_ROOT}/data" "Fresh runtime data" 1 || return 1
  runtime_validate_approved_runtime_directory \
    "${RUNTIME_ROOT}/wechat-home" "Fresh Runtime WeChat HOME" 1 || return 1
  runtime_assert_fresh_runtime_tree "$RUNTIME_ROOT" "Fresh runtime" ||
    return 1
}

remove_temporary_candidate_runtime() {
  local path

  [ "$CANDIDATE_TEMP_RUNTIME" -eq 1 ] || return 0
  for path in "$RUNTIME_ROOT" "${RUNTIME_ROOT}/data" \
    "${RUNTIME_ROOT}/wechat-home"; do
    runtime_validate_approved_runtime_directory \
      "$path" "Temporary candidate Runtime" 1 || return 1
  done
  for path in "${RUNTIME_ROOT}/data" "${RUNTIME_ROOT}/wechat-home" \
    "$RUNTIME_ROOT"; do
    if ! runtime_privileged rmdir -- "$path"; then
      LAST_ERROR="Temporary candidate Runtime is not empty or could not be removed safely."
      return 1
    fi
  done
  CANDIDATE_TEMP_RUNTIME=0
}

prepare_agent_candidate_before_archive() {
  local runtime_parent

  if ! runtime_parent="$(dirname -- "$RUNTIME_ROOT")"; then
    LAST_ERROR="Runtime parent could not be resolved before container preflight."
    return 1
  fi
  runtime_validate_directory_without_extended_attributes "$runtime_parent" "Runtime parent" ||
    return 1
  if ! capture_runtime_metadata; then
    LAST_ERROR="Previous runtime metadata could not be captured before container preflight."
    return 1
  fi
  case "$SOURCE_LAYOUT" in
    runtime)
      runtime_validate_approved_runtime_directory \
        "$RUNTIME_ROOT" "Runtime root" 1 || return 1
      runtime_validate_approved_runtime_directory \
        "${RUNTIME_ROOT}/data" "Runtime data" 1 || return 1
      runtime_validate_approved_runtime_directory \
        "${RUNTIME_ROOT}/wechat-home" "Runtime WeChat HOME" 1 || return 1
      ;;
    legacy)
      [ "$DATA_EXISTS" != true ] ||
        runtime_validate_approved_runtime_directory \
          "$LEGACY_DATA_ROOT" "Legacy data" 1 || return 1
      [ "$HOME_EXISTS" != true ] ||
        runtime_validate_approved_runtime_directory \
          "$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME" 1 || return 1
      ;;
    none) ;;
    *)
      LAST_ERROR="Runtime source layout is invalid before container preflight."
      return 1
      ;;
  esac

  if [ "$SOURCE_LAYOUT" != "runtime" ]; then
    if runtime_path_exists "$RUNTIME_ROOT"; then
      LAST_ERROR="Temporary candidate Runtime path is unexpectedly occupied."
      return 1
    fi
    CANDIDATE_TEMP_RUNTIME=1
    if ! create_fresh_runtime; then
      return 1
    fi
  fi

  runtime_revalidate_start_gate || return 1
  create_agent_container_candidate || return 1

  if [ "$CANDIDATE_TEMP_RUNTIME" -eq 1 ]; then
    remove_temporary_candidate_runtime || return 1
  fi
  # This is the last live policy check before Archive mutation. The candidate
  # remains stopped and the exact same container ID is started afterwards.
  runtime_revalidate_start_gate || return 1
  runtime_attest_actual_agent_container \
    created "$ATTESTED_AGENT_CONTAINER_ID" || return 1
}

wait_for_clean_auth() {
  local started_at=$SECONDS

  while [ "$((SECONDS - started_at))" -lt "$SERVER_READY_TIMEOUT" ]; do
    if fetch_auth_status; then
      if auth_status_is_qr_ready "$AUTH_STATUS"; then
        return 0
      fi
      if [ "$AUTH_STATUS" = "logged_in" ]; then
        LAST_ERROR="runtime is not clean; use start-qr-login.sh"
        return 1
      fi
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="Fresh runtime did not reach a logged-out QR-ready state before timeout."
  return 1
}

wait_for_verified_runtime() {
  local expected_identity="$1"
  local started_at=$SECONDS current_identity encoded_chat

  while [ "$((SECONDS - started_at))" -lt "$POST_LOGIN_READY_TIMEOUT" ]; do
    if ! current_identity="$(runtime_wechat_process_identity)" ||
      [ "$current_identity" != "$expected_identity" ]; then
      LAST_ERROR="The verified /usr/bin/wechat process exited or was replaced."
      return 1
    fi
    if fetch_auth_status && [ "$AUTH_STATUS" = "logged_in" ] &&
      encoded_chat="$(fetch_first_chat_path)" &&
      check_messages_api "$encoded_chat"; then
      unset encoded_chat
      return 0
    fi
    unset encoded_chat
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="Auth, chats, and messages did not become ready before timeout."
  return 1
}

validate_login_start_response() {
  local response="$1"

  printf '%s' "$response" | run_isolated_python -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(2)
if not isinstance(payload, dict):
    raise SystemExit(2)
for key in ("error", "errors"):
    if payload.get(key) not in (None, False, "", [], {}):
        raise SystemExit(2)
success = payload.get("success")
state = payload.get("state")
status = state.get("status") if isinstance(state, dict) else payload.get("status")
pending = {"logged_out", "qr_pending", "waiting_for_qr", "waiting_for_scan"}
if success is True or status in pending:
    raise SystemExit(0)
raise SystemExit(2)
'
}


guard_gateway_worker_and_generation_pending() {
  guard_gateway_worker_stopped &&
    runtime_gateway_gate_assert_pending
}

run_forced_login() {
  local attempt login_response login_pid login_status=0
  local worker_guard_error="" worker_guard_poll_interval=1
  local -a login_arguments=(
    "${SCRIPT_DIR}/qr_login.py"
    --listen
    --url "$WS_URL"
    --session-id "$SESSION_ID"
    --timeout-ms "$LOGIN_TIMEOUT_MS"
    --new-account
    --require-qr
  )

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    worker_guard_poll_interval=0.1
  fi
  if ! guard_gateway_worker_and_generation_pending; then
    return 1
  fi

  if ! login_response="$(api_request POST '/api/status/login?newAccount=true' 2>/dev/null)"; then
    LAST_ERROR="Fresh QR login API request failed."
    return 1
  fi
  if ! validate_login_start_response "$login_response"; then
    unset login_response
    LAST_ERROR="Fresh QR login API returned an invalid or explicit error response."
    return 1
  fi
  unset login_response
  if ! guard_gateway_worker_and_generation_pending; then
    return 1
  fi
  if ! prepare_login_python_command; then
    LAST_ERROR="Fresh QR login helper command could not be isolated."
    return 1
  fi

  printf '%s' "$AUTH_TOKEN" | \
    "${LOGIN_PYTHON_COMMAND[@]}" "${login_arguments[@]}" &
  login_pid=$!
  QR_LOGIN_HELPER_PID="$login_pid"
  while kill -0 "$login_pid" 2>/dev/null; do
    if ! guard_gateway_worker_and_generation_pending; then
      worker_guard_error="$LAST_ERROR"
      kill "$login_pid" 2>/dev/null || :
      wait "$login_pid" 2>/dev/null || :
      QR_LOGIN_HELPER_PID=""
      LAST_ERROR="$worker_guard_error"
      return 1
    fi
    sleep "$worker_guard_poll_interval"
  done
  wait "$login_pid" || login_status=$?
  QR_LOGIN_HELPER_PID=""
  if [ "$login_status" -ne 0 ]; then
    LAST_ERROR="Fresh QR WebSocket login did not complete."
    return 1
  fi
  if ! guard_gateway_worker_and_generation_pending; then
    return 1
  fi

  printf '%s\n' 'Confirming authenticated state...'
  for ((attempt = 1; attempt <= LOGIN_CONFIRM_RETRIES; attempt++)); do
    if ! guard_gateway_worker_and_generation_pending; then
      return 1
    fi
    if fetch_auth_status && [ "$AUTH_STATUS" = "logged_in" ]; then
      printf '%s\n' 'Authenticated state confirmed.'
      return 0
    fi
    if [ "$attempt" -lt "$LOGIN_CONFIRM_RETRIES" ]; then
      sleep "$LOGIN_CONFIRM_INTERVAL"
    fi
  done
  LAST_ERROR="login_success was received but auth did not become logged_in."
  return 1
}

print_dry_run() {
  printf '%s\n' 'Dry run: no containers, workers, or directories were modified.'
  printf '%s\n' 'Planned flow:'
  printf '%s\n' '  1. Stop Gateway wechat-worker.'
  printf '%s\n' '  2. Stop and remove only the agent-wechat container.'
  printf '%s\n' '  3. Atomically archive the current runtime when present.'
  printf '%s\n' '  4. Create an empty runtime and force a terminal QR login.'
  printf '%s\n' '  5. Validate process, auth, chats, and messages before worker start.'
}

print_final_status() {
  printf '%s\n' '================================'
  printf '%s\n' 'Fresh QR Runtime Status'
  printf '%s\n' '================================'
  printf 'Container:\n  running\n'
  printf 'Agent Server:\n  reachable\n'
  printf 'WeChat Process:\n  running and stable\n'
  printf 'Auth:\n  logged_in\n'
  printf 'QR Runtime Mode:\n  fresh\n'
  printf 'Message API:\n  chats and messages readable\n'
  printf 'Gateway WeChat Worker:\n  running, healthy, heartbeat verified\n'
  if [ -n "$ARCHIVE_PATH" ]; then
    printf 'Archive:\n  %s\n' "$ARCHIVE_PATH"
  else
    printf 'Archive:\n  no previous runtime\n'
  fi
  printf '%s\n' '================================'
}

main() {
  local ended_at verified_wechat_identity current_wechat_identity

  parse_args "$@"
  if ! validate_operator_terminal; then
    error "$LAST_ERROR"
    return 1
  fi
  FLOW_PHASE="validation"
  if ! validate_configuration; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! resolve_python; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! runtime_validate_configuration; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! validate_configuration; then
    error "$LAST_ERROR"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    print_dry_run
    return 0
  fi
  if ! runtime_acquire_lock; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  FLOW_PHASE="stop_gateway_worker"
  WORKER_GUARD=1
  if ! stop_gateway_worker; then
    error "$LAST_ERROR"
    return 1
  fi
  WORKER_STOP_CONFIRMED=1

  FLOW_PHASE="verify_gateway_contract"
  if ! runtime_verify_gateway_contract; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="begin_gateway_generation"
  if ! runtime_gateway_gate_begin; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="archive_preflight"
  if ! runtime_check_archive_capacity; then
    error "$LAST_ERROR"
    return 1
  fi
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    if ! runtime_privileged_isolated_python "$ARCHIVE_TOOL_TIMEOUT" "$ARCHIVE_RUNTIME_TOOL" \
      --env-owner-uid "$AGENT_ENV_APPROVED_UID" \
      --env-owner-gid "$AGENT_ENV_APPROVED_GID" \
      --env-mode "$AGENT_ENV_APPROVED_MODE" \
      --operator-uid "$(id -u)" \
      --operator-gid "$(id -g)" \
      --testing-env-file "$AGENT_ENV_FILE" inventory; then
      LAST_ERROR="Archive inventory could not be completed safely."
      error "$LAST_ERROR"
      return 1
    fi
  elif ! runtime_privileged_isolated_python "$ARCHIVE_TOOL_TIMEOUT" "$ARCHIVE_RUNTIME_TOOL" \
    --env-owner-uid "$AGENT_ENV_APPROVED_UID" \
    --env-owner-gid "$AGENT_ENV_APPROVED_GID" \
    --env-mode "$AGENT_ENV_APPROVED_MODE" \
    --operator-uid "$(id -u)" \
    --operator-gid "$(id -g)" \
    inventory; then
    LAST_ERROR="Archive inventory could not be completed safely."
    error "$LAST_ERROR"
    return 1
  fi

  if [ ! -f "${SCRIPT_DIR}/qr_login.py" ]; then
    error "QR login helper is missing."
    return 1
  fi
  FLOW_PHASE="prepare_login_environment"
  if ! ensure_login_environment; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="load_auth_token"
  if ! load_auth_token; then
    error "$LAST_ERROR"
    return 1
  fi

  AGENT_CLEANUP_GUARD=1
  FLOW_PHASE="remove_agent_container"
  if ! stop_agent_container; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! remove_agent_container; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="attest_stopped_agent_candidate"
  if ! prepare_agent_candidate_before_archive; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="guard_worker_before_archive"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="archive_capacity_commit_gate"
  if ! runtime_check_archive_capacity; then
    error "$LAST_ERROR"
    return 1
  fi
  FLOW_PHASE="gateway_generation_archive_commit_gate"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="archive_runtime"
  if ! archive_current_runtime; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="create_runtime"
  if ! create_fresh_runtime; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="guard_worker_before_agent_start"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="start_agent_container"
  if ! start_agent_container; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="wait_docker_health"
  if ! wait_for_agent_health; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="wait_agent_server"
  if ! wait_for_agent_server; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="wait_wechat_process"
  if ! wait_for_stable_wechat_process; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="wait_clean_auth"
  if ! wait_for_clean_auth; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="guard_worker_before_qr"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="force_qr_login"
  if ! run_forced_login; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="guard_worker_before_runtime_validation"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="verify_wechat_process"
  if ! wait_for_stable_wechat_process; then
    error "$LAST_ERROR"
    return 1
  fi
  verified_wechat_identity="$STABLE_WECHAT_IDENTITY"

  FLOW_PHASE="verify_runtime_apis"
  if ! wait_for_verified_runtime "$verified_wechat_identity"; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="guard_worker_before_final_attestation"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="verify_final_wechat_process"
  if ! current_wechat_identity="$(runtime_wechat_process_identity)" ||
    [ "$current_wechat_identity" != "$verified_wechat_identity" ]; then
    error "The verified /usr/bin/wechat process exited or was replaced."
    return 1
  fi

  FLOW_PHASE="revalidate_final_runtime_contract"
  if ! runtime_revalidate_start_gate; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! wait_for_verified_runtime "$verified_wechat_identity"; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! runtime_attest_actual_agent_container \
    running "$ATTESTED_AGENT_CONTAINER_ID"; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="guard_worker_before_gateway_release"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi

  # From this point, a Gateway checker failure preserves the verified fresh
  # Agent runtime as evidence while the EXIT guard revokes the Worker.
  AGENT_CLEANUP_GUARD=0
  FLOW_PHASE="revalidate_gateway_contract"
  if ! runtime_verify_gateway_contract; then
    error "$LAST_ERROR"
    return 1
  fi
  FLOW_PHASE="guard_worker_at_release"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="create_gateway_worker_candidate"
  if ! prepare_gateway_worker_candidate; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="revalidate_gateway_release_bindings"
  if ! guard_gateway_worker_and_generation_pending; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! runtime_attest_actual_agent_container running "$ATTESTED_AGENT_CONTAINER_ID"; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! runtime_attest_gateway_worker_container created "$GATEWAY_WORKER_CONTAINER_ID"; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="release_gateway_generation"
  if ! runtime_gateway_gate_release; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="start_gateway_worker"
  if ! start_gateway_worker; then
    error "$LAST_ERROR"
    return 1
  fi

  FLOW_PHASE="complete"
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! write_manifest success "$ended_at"; then
    error "Could not finalize the archive manifest."
    return 1
  fi
  FLOW_COMPLETE=1
  print_final_status
}

main "$@"
