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

exec "$@"
