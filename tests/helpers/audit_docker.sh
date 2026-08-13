#!/usr/bin/env bash
set -euo pipefail

: "${CF_AUDIT_LOG:?}"
: "${CF_AUDIT_REAL_DOCKER:?}"

if [ "${1:-}" = "inspect" ]; then
  printf 'docker\tinspect\n' >> "$CF_AUDIT_LOG"
  if [ "${CF_AUDIT_DOCKER_MODE:-}" = "nonpermission" ]; then
    printf 'Error: No such object\n' >&2
    exit 1
  fi
fi

exec "$CF_AUDIT_REAL_DOCKER" "$@"
