#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_REAL_MV:?}"

arguments=("$@")
argument_count="${#arguments[@]}"
source_path=""
destination=""
if [ "$argument_count" -ge 2 ]; then
  source_path="${arguments[argument_count - 2]}"
  destination="${arguments[argument_count - 1]}"
fi

if [ -n "${MOCK_SUDO_FAIL_MV_SOURCE:-}" ] &&
  [ -n "${MOCK_SUDO_FAIL_MV_MARKER:-}" ] &&
  [ "$source_path" = "$MOCK_SUDO_FAIL_MV_SOURCE" ] &&
  [ ! -e "$MOCK_SUDO_FAIL_MV_MARKER" ]; then
  : > "$MOCK_SUDO_FAIL_MV_MARKER"
  exit 73
fi

if [ -n "${MOCK_SUDO_FAIL_MV_DESTINATION:-}" ] &&
  [ -n "${MOCK_SUDO_FAIL_MV_ON_CALL:-}" ] &&
  [ -n "${MOCK_SUDO_MV_COUNT_FILE:-}" ] &&
  [ "$destination" = "$MOCK_SUDO_FAIL_MV_DESTINATION" ]; then
  move_count=0
  if [ -f "$MOCK_SUDO_MV_COUNT_FILE" ]; then
    move_count="$(cat -- "$MOCK_SUDO_MV_COUNT_FILE")"
  fi
  move_count=$((move_count + 1))
  printf '%s\n' "$move_count" > "$MOCK_SUDO_MV_COUNT_FILE"
  if [ "$move_count" -eq "$MOCK_SUDO_FAIL_MV_ON_CALL" ]; then
    exit 74
  fi
fi

exec "$MOCK_REAL_MV" "$@"