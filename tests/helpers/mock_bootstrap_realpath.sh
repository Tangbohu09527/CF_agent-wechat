#!/usr/bin/env bash
set -euo pipefail

: "${CF_BOOTSTRAP_REAL_REALPATH:?}"

if [ "${1:-}" = "-m" ] && [ "${2:-}" = "--" ] &&
  [ "${3:-}" = "/srv/storage/cf-agent-wechat" ] &&
  [ -n "${CF_BOOTSTRAP_TEST_DEFAULT_RUNTIME_RESOLVED:-}" ]; then
  printf '%s\n' "$CF_BOOTSTRAP_TEST_DEFAULT_RUNTIME_RESOLVED"
  exit 0
fi
exec "$CF_BOOTSTRAP_REAL_REALPATH" "$@"
