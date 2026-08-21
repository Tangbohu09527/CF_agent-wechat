#!/usr/bin/env bash
set -euo pipefail

: "${CF_AUDIT_LOG:?}"
: "${CF_AUDIT_REAL_DOCKER:?}"

docker_host="default"
docker_command="${1:-}"
if [ "${1:-}" = "--host" ]; then
  docker_host="${2:-missing}"
  docker_command="${3:-}"
fi

if [ "$docker_command" = "inspect" ]; then
  printf 'docker\tinspect\thost=%s\n' "$docker_host" >> "$CF_AUDIT_LOG"
  if [ "${CF_AUDIT_DOCKER_MODE:-}" = "nonpermission" ]; then
    printf 'Error: No such object\n' >&2
    exit 1
  fi
fi

exec "$CF_AUDIT_REAL_DOCKER" "$@"
