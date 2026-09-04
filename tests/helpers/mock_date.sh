#!/usr/bin/env bash
set -euo pipefail

if [ "${MOCK_FIXED_UTC:-0}" != "1" ]; then
  exec "${MOCK_REAL_DATE:-/bin/date}" "$@"
fi

case "${*: -1}" in
  +%Y%m%dT%H%M%SZ)
    printf '%s\n' '20300102T030405Z'
    ;;
  +%Y-%m-%dT%H:%M:%SZ)
    printf '%s\n' '2030-01-02T03:04:05Z'
    ;;
  *)
    exec "${MOCK_REAL_DATE:-/bin/date}" "$@"
    ;;
esac
