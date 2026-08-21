#!/usr/bin/env bash
set -euo pipefail

: "${CF_TEST_DOCKER_STATE_FILE:?}"

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
case "$arguments" in
  *State.Running*) printf '%s\n' "$running" ;;
  *State.Health*) printf '%s\n' "$health" ;;
  *)
    printf 'unexpected inspect format\n' >&2
    exit 64
    ;;
esac
