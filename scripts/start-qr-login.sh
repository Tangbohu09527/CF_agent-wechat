#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=qr-runtime-common.sh
source "${SCRIPT_DIR}/qr-runtime-common.sh"

DRY_RUN=0
FLOW_COMPLETE=0
WORKER_GUARD=0
WORKER_STOP_CONFIRMED=0
AGENT_CLEANUP_GUARD=0
AGENT_FAILURE_CLEANUP_ATTEMPTED=false
AGENT_FAILURE_CLEANUP_STOP_RESULT="not_attempted"
AGENT_FAILURE_CLEANUP_REMOVE_RESULT="not_attempted"
FLOW_PHASE="initializing"
FLOW_STARTED_AT=""
ARCHIVE_PATH=""
ARCHIVE_RESULT="not_attempted"
MANIFEST_AVAILABLE=0
SOURCE_LAYOUT="none"

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
    if [ "$DATA_EXISTS" = true ]; then
      RUNTIME_UID="$DATA_UID"
      RUNTIME_GID="$DATA_GID"
    elif [ "$HOME_EXISTS" = true ]; then
      RUNTIME_UID="$HOME_UID"
      RUNTIME_GID="$HOME_GID"
    fi
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
  local temp_file archive_temp

  [ "$MANIFEST_AVAILABLE" -eq 1 ] || return 0
  if ! temp_file="$(mktemp)"; then
    LAST_ERROR="Temporary manifest file could not be created."
    return 1
  fi
  archive_temp="${ARCHIVE_PATH}/.manifest.json.$$"
  if ! "$PYTHON_BIN" - \
    "$temp_file" "$result" "$FLOW_PHASE" "$FLOW_STARTED_AT" "$ended_at" \
    "$ARCHIVE_RESULT" "$SOURCE_LAYOUT" "$RUNTIME_ROOT" "$LEGACY_DATA_ROOT" \
    "$LEGACY_WECHAT_HOME_ROOT" "$ARCHIVE_PATH" "$AGENT_IMAGE_DIGEST" \
    "$RUNTIME_EXISTS" "$RUNTIME_UID" "$RUNTIME_GID" "$RUNTIME_MODE" \
    "$DATA_EXISTS" "$DATA_UID" "$DATA_GID" "$DATA_MODE" \
    "$HOME_EXISTS" "$HOME_UID" "$HOME_GID" "$HOME_MODE" \
    "$AGENT_FAILURE_CLEANUP_ATTEMPTED" \
    "$AGENT_FAILURE_CLEANUP_STOP_RESULT" \
    "$AGENT_FAILURE_CLEANUP_REMOVE_RESULT" <<'PY'
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
    image_digest,
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
) = sys.argv[1:]

def metadata(exists, uid, gid, mode):
    return {
        "exists": exists == "true",
        "uid": int(uid),
        "gid": int(gid),
        "mode": mode,
    }

payload = {
    "schemaVersion": 1,
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
    "imageDigest": image_digest,
    "originalPermissions": {
        "runtime": metadata(
            runtime_exists, runtime_uid, runtime_gid, runtime_mode
        ),
        "data": metadata(data_exists, data_uid, data_gid, data_mode),
        "wechatHome": metadata(home_exists, home_uid, home_gid, home_mode),
    },
    "sensitiveData": {
        "tokenIncluded": False,
        "accountIdentifiersIncluded": False,
        "chatIdentifiersIncluded": False,
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

  if ! runtime_privileged install \
    -o "$RUNTIME_UID" -g "$RUNTIME_GID" -m 600 \
    "$temp_file" "$archive_temp"; then
    rm -f -- "$temp_file"
    return 1
  fi
  rm -f -- "$temp_file"
  if ! runtime_privileged mv -fT -- \
    "$archive_temp" "${ARCHIVE_PATH}/manifest.json"; then
    LAST_ERROR="Archive manifest could not be installed."
    return 1
  fi
}

on_exit() {
  local exit_status=$?
  local ended_at original_last_error
  local agent_cleanup_failed=0 manifest_write_failed=0

  trap - EXIT
  set +e
  original_last_error="${LAST_ERROR:-}"
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
    [ "$MANIFEST_AVAILABLE" -eq 1 ]; then
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! write_manifest failed "$ended_at" >/dev/null 2>&1; then
      manifest_write_failed=1
    fi
  fi
  LAST_ERROR="$original_last_error"
  if [ "$exit_status" -ne 0 ]; then
    error "Fresh QR runtime failed during phase: $FLOW_PHASE"
    if [ -n "$ARCHIVE_PATH" ]; then
      error "Archive preserved at: $ARCHIVE_PATH"
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
    if [ "$manifest_write_failed" -eq 1 ]; then
      error "The failed-flow manifest could not be updated with cleanup results."
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
    candidate="${ARCHIVE_ROOT}/${timestamp}-$(printf '%02d' "$counter")"
  done
  ARCHIVE_PATH="$candidate"
}

archive_current_runtime() {
  local storage_uid storage_gid archive_device source_device
  local legacy_data_moved=0

  if ! capture_runtime_metadata; then
    LAST_ERROR="Previous runtime metadata could not be captured."
    return 1
  fi
  if ! storage_uid="$(runtime_privileged stat -c '%u' -- "$STORAGE_ROOT")" ||
    ! storage_gid="$(runtime_privileged stat -c '%g' -- "$STORAGE_ROOT")"; then
    LAST_ERROR="Storage root ownership could not be read."
    return 1
  fi
  if ! runtime_privileged install -d \
    -o "$storage_uid" -g "$storage_gid" -m 700 "$ARCHIVE_ROOT"; then
    LAST_ERROR="Archive root could not be created."
    return 1
  fi

  if [ "$SOURCE_LAYOUT" = "none" ]; then
    ARCHIVE_RESULT="not_required"
    return 0
  fi

  ARCHIVE_RESULT="failed"
  case "$SOURCE_LAYOUT" in
    runtime)
      runtime_assert_tree_has_no_auth_token "$RUNTIME_ROOT" "Current runtime" ||
        return 1
      ;;
    legacy)
      if [ "$DATA_EXISTS" = true ]; then
        runtime_assert_tree_has_no_auth_token "$LEGACY_DATA_ROOT" "Legacy data" ||
          return 1
      fi
      if [ "$HOME_EXISTS" = true ]; then
        runtime_assert_tree_has_no_auth_token "$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME" ||
          return 1
      fi
      ;;
  esac

  if ! archive_device="$(runtime_privileged stat -c '%d' -- "$ARCHIVE_ROOT")"; then
    LAST_ERROR="Archive filesystem could not be inspected."
    return 1
  fi
  if [ "$SOURCE_LAYOUT" = "runtime" ]; then
    if ! source_device="$(runtime_privileged stat -c '%d' -- "$RUNTIME_ROOT")" ||
      [ "$source_device" != "$archive_device" ]; then
      LAST_ERROR="Current runtime and archive must be on the same filesystem."
      return 1
    fi
  else
    if [ "$DATA_EXISTS" = true ]; then
      if ! source_device="$(runtime_privileged stat -c '%d' -- "$LEGACY_DATA_ROOT")" ||
        [ "$source_device" != "$archive_device" ]; then
        LAST_ERROR="Legacy data and archive must be on the same filesystem."
        return 1
      fi
    fi
    if [ "$HOME_EXISTS" = true ]; then
      if ! source_device="$(runtime_privileged stat -c '%d' -- "$LEGACY_WECHAT_HOME_ROOT")" ||
        [ "$source_device" != "$archive_device" ]; then
        LAST_ERROR="Legacy WeChat HOME and archive must be on the same filesystem."
        return 1
      fi
    fi
  fi

  if ! choose_archive_path; then
    return 1
  fi
  if [ "$SOURCE_LAYOUT" = "runtime" ]; then
    if ! runtime_privileged mv --no-clobber -T -- \
      "$RUNTIME_ROOT" "$ARCHIVE_PATH"; then
      LAST_ERROR="Current runtime could not be atomically archived."
      return 1
    fi
    if runtime_path_exists "$RUNTIME_ROOT" ||
      ! runtime_privileged test -d "$ARCHIVE_PATH"; then
      LAST_ERROR="Archive destination was claimed concurrently; runtime was not moved."
      return 1
    fi
  else
    if ! runtime_privileged mkdir -- "$ARCHIVE_PATH"; then
      LAST_ERROR="Legacy archive destination could not be reserved."
      return 1
    fi
    MANIFEST_AVAILABLE=1
    if ! runtime_privileged chown \
      "${RUNTIME_UID}:${RUNTIME_GID}" "$ARCHIVE_PATH" ||
      ! runtime_privileged chmod 700 "$ARCHIVE_PATH"; then
      LAST_ERROR="Legacy archive permissions could not be set."
      return 1
    fi
    if [ "$DATA_EXISTS" = true ]; then
      if ! runtime_privileged mv --no-clobber -T -- \
        "$LEGACY_DATA_ROOT" "${ARCHIVE_PATH}/data" ||
        runtime_path_exists "$LEGACY_DATA_ROOT"; then
        LAST_ERROR="Legacy data directory could not be atomically archived."
        return 1
      fi
      legacy_data_moved=1
    fi
    if [ "$HOME_EXISTS" = true ]; then
      if ! runtime_privileged mv --no-clobber -T -- \
        "$LEGACY_WECHAT_HOME_ROOT" "${ARCHIVE_PATH}/wechat-home" ||
        runtime_path_exists "$LEGACY_WECHAT_HOME_ROOT"; then
        if [ "$legacy_data_moved" -eq 1 ]; then
          if ! runtime_privileged mv --no-clobber -T -- \
            "${ARCHIVE_PATH}/data" "$LEGACY_DATA_ROOT" ||
            runtime_path_exists "${ARCHIVE_PATH}/data"; then
            LAST_ERROR="Legacy archive failed and data rollback also failed; inspect the preserved archive before retrying."
            return 1
          fi
        fi
        LAST_ERROR="Legacy WeChat HOME could not be atomically archived; legacy data was rolled back."
        return 1
      fi
    fi
  fi
  ARCHIVE_RESULT="succeeded"
  MANIFEST_AVAILABLE=1
  if ! write_manifest in_progress ""; then
    LAST_ERROR="Archive manifest could not be initialized."
    return 1
  fi
}

create_fresh_runtime() {
  if ! runtime_privileged install -d \
    -o "$RUNTIME_UID" -g "$RUNTIME_GID" -m "$RUNTIME_MODE" \
    "$RUNTIME_ROOT"; then
    LAST_ERROR="Fresh runtime root could not be created."
    return 1
  fi
  if ! runtime_privileged install -d \
    -o "$DATA_UID" -g "$DATA_GID" -m "$DATA_MODE" \
    "${RUNTIME_ROOT}/data"; then
    LAST_ERROR="Fresh runtime data directory could not be created."
    return 1
  fi
  if ! runtime_privileged install -d \
    -o "$HOME_UID" -g "$HOME_GID" -m "$HOME_MODE" \
    "${RUNTIME_ROOT}/wechat-home"; then
    LAST_ERROR="Fresh WeChat HOME directory could not be created."
    return 1
  fi
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

  printf '%s' "$response" | "$PYTHON_BIN" -c '
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


run_forced_login() {
  local attempt login_response

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
  if ! printf '%s' "$AUTH_TOKEN" | "$LOGIN_PYTHON" \
    "${SCRIPT_DIR}/qr_login.py" \
    --listen \
    --url "$WS_URL" \
    --session-id "$SESSION_ID" \
    --timeout-ms "$LOGIN_TIMEOUT_MS" \
    --new-account \
    --require-qr; then
    LAST_ERROR="Fresh QR WebSocket login did not complete."
    return 1
  fi

  printf '%s\n' 'Confirming authenticated state...'
  for ((attempt = 1; attempt <= LOGIN_CONFIRM_RETRIES; attempt++)); do
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
  if [ "$DRY_RUN" -eq 1 ]; then
    print_dry_run
    return 0
  fi
  if ! runtime_acquire_lock; then
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

  FLOW_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  FLOW_PHASE="stop_gateway_worker"
  WORKER_GUARD=1
  if ! stop_gateway_worker; then
    error "$LAST_ERROR"
    return 1
  fi
  WORKER_STOP_CONFIRMED=1

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

  FLOW_PHASE="force_qr_login"
  if ! run_forced_login; then
    error "Forced QR login did not complete."
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

  FLOW_PHASE="verify_final_wechat_process"
  if ! current_wechat_identity="$(runtime_wechat_process_identity)" ||
    [ "$current_wechat_identity" != "$verified_wechat_identity" ]; then
    error "The verified /usr/bin/wechat process exited or was replaced."
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
