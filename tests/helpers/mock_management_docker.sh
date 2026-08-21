#!/usr/bin/env bash
set -euo pipefail

: "${CF_TEST_DOCKER_STATE_FILE:?}"

if [ "${1:-}" != "--host" ] || [ "${2:-}" != "unix:///var/run/docker.sock" ]; then
  printf 'mock docker requires the production local socket\n' >&2
  exit 63
fi
shift 2

if [ "${1:-}" != "inspect" ]; then
  printf 'mock docker only supports inspect\n' >&2
  exit 64
fi

state="$(awk 'NR == 1 { print $1 }' "$CF_TEST_DOCKER_STATE_FILE")"
health="$(awk 'NR == 1 { print $2 }' "$CF_TEST_DOCKER_STATE_FILE")"
case "$state" in
  running) running=true ;;
  stopped) running=false ;;
  missing)
    printf 'Error: No such object\n' >&2
    exit 1
    ;;
  *)
    printf 'invalid mock container state\n' >&2
    exit 65
    ;;
esac
case "$health" in
  healthy|starting|unhealthy|none) ;;
  *)
    printf 'invalid mock health state\n' >&2
    exit 65
    ;;
esac

arguments="$*"
hang_forever() {
  if [ -n "${CF_TEST_DOCKER_HANG_PID_FILE:-}" ]; then
    printf '%s\n' "$$" > "$CF_TEST_DOCKER_HANG_PID_FILE"
  fi
  trap '' TERM
  while :; do
    sleep 1
  done
}

case "${CF_TEST_DOCKER_HANG_ON:-}" in
  state)
    [[ "$arguments" != *State.Running* ]] || hang_forever
    ;;
  health)
    [[ "$arguments" != *State.Health* ]] || hang_forever
    ;;
  all)
    hang_forever
    ;;
esac

case "$arguments" in
  *State.Running*) printf '%s\n' "$running" ;;
  *State.Health*) printf '%s\n' "$health" ;;
  *)
    printf 'unexpected inspect format\n' >&2
    exit 64
    ;;
esac
