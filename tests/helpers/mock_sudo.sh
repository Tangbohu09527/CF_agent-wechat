#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-v" ]; then
  exit 0
fi
while [ "${1:-}" = "-n" ] || [ "${1:-}" = "--" ]; do
  shift
done
sudo_command=("$@")
sudo_command_count="${#sudo_command[@]}"
last_argument=""
if [ "$sudo_command_count" -gt 0 ]; then
  last_argument="${sudo_command[sudo_command_count - 1]}"
fi

if [ -n "${MOCK_APPROVED_DOCKER_SOCKET:-}" ] &&
  [ "${1:-}" = stat ] &&
  [ "$last_argument" = "$MOCK_APPROVED_DOCKER_SOCKET" ]; then
  case " $* " in
    *" -Lc %u:%a "*)
      printf '%s\n' '0:600'
      exit 0
      ;;
  esac
fi

if [ -n "${MOCK_SUDO_FAIL_MV_SOURCE:-}" ] &&
  [ -n "${MOCK_SUDO_FAIL_MV_MARKER:-}" ] &&
  [ "${1:-}" = "mv" ] && [ "$#" -ge 3 ]; then
  mv_source="${sudo_command[sudo_command_count - 2]}"
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
  [ "$last_argument" = "$MOCK_SUDO_FAIL_MV_DESTINATION" ]; then
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
