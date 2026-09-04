#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=qr-runtime-common.sh
source "${SCRIPT_DIR}/qr-runtime-common.sh"

DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ./scripts/stop-qr-runtime.sh [--dry-run]

Stop Gateway poll/delivery workers and agent-wechat without deleting the
runtime, Token, container, or any session archive.
EOF
}

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

print_status() {
  local container_status="$1"

  printf '%s\n' '================================'
  printf '%s\n' 'QR Runtime Stop Status'
  printf '%s\n' '================================'
  printf 'Container:\n  %s\n' "$container_status"
  printf 'Gateway Poll/Delivery Workers:\n  stopped\n'
  printf 'Runtime:\n  preserved\n'
  printf 'Token:\n  preserved\n'
  printf 'Session Archives:\n  preserved\n'
  printf '%s\n' '================================'
}

main() {
  local container_status

  parse_args "$@"

  if ! resolve_python; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! runtime_validate_stop_configuration; then
    error "$LAST_ERROR"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' 'Dry run: workers, container, runtime, Token, and archives are unchanged.'
    return 0
  fi
  if ! runtime_acquire_lock; then
    error "$LAST_ERROR"
    return 1
  fi

  if ! stop_gateway_workers; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! stop_agent_container; then
    error "$LAST_ERROR"
    return 1
  fi
  if ! container_status="$(agent_container_state)"; then
    error "agent-wechat container state could not be queried after stop."
    return 1
  fi
  if [ "$container_status" = "running" ]; then
    error "agent-wechat did not stop."
    return 1
  fi
  print_status "$container_status"
}

main "$@"
