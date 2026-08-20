#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--" ]; then
  shift
fi

if [ -n "${MOCK_SUDO_FAIL_MV_SOURCE:-}" ] &&
  [ -n "${MOCK_SUDO_FAIL_MV_MARKER:-}" ] &&
  [ "${1:-}" = "mv" ] && [ "$#" -ge 3 ]; then
  mv_source="${@: -2:1}"
  if [ "$mv_source" = "$MOCK_SUDO_FAIL_MV_SOURCE" ] &&
    [ ! -e "$MOCK_SUDO_FAIL_MV_MARKER" ]; then
    : > "$MOCK_SUDO_FAIL_MV_MARKER"
    exit 73
  fi
fi

if [ -n "${MOCK_SUDO_FAIL_MV_DESTINATION:-}" ] &&
  [ -n "${MOCK_SUDO_FAIL_MV_ON_CALL:-}" ] &&
  [ -n "${MOCK_SUDO_MV_COUNT_FILE:-}" ] &&
  [ "${1:-}" = "mv" ] && [ "$#" -ge 3 ] &&
  [ "${@: -1}" = "$MOCK_SUDO_FAIL_MV_DESTINATION" ]; then
  mv_count=0
  if [ -f "$MOCK_SUDO_MV_COUNT_FILE" ]; then
    mv_count="$(cat -- "$MOCK_SUDO_MV_COUNT_FILE")"
  fi
  mv_count=$((mv_count + 1))
  printf '%s\n' "$mv_count" > "$MOCK_SUDO_MV_COUNT_FILE"
  if [ "$mv_count" -eq "$MOCK_SUDO_FAIL_MV_ON_CALL" ]; then
    exit 74
  fi
fi

exec "$@"
