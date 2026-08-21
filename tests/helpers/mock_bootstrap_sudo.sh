#!/usr/bin/env bash
set -euo pipefail

: "${CF_BOOTSTRAP_TEST_LOG:?}"
: "${CF_BOOTSTRAP_TEST_SUDO_STATE_FILE:?}"

{
  printf 'sudo'
  printf '\t%s' "$@"
  printf '\n'
} >> "$CF_BOOTSTRAP_TEST_LOG"

if [ "$#" -eq 1 ] && [ "$1" = "-v" ]; then
  : > "$CF_BOOTSTRAP_TEST_SUDO_STATE_FILE"
  exit 0
fi

noninteractive=0
if [ "${1:-}" = "-n" ]; then
  noninteractive=1
  shift
fi
if [ "${1:-}" = "--" ]; then
  shift
fi

if [ "$noninteractive" -ne 1 ]; then
  printf 'mock sudo rejected a timed command without -n\n' >&2
  exit 91
fi
if [ ! -f "$CF_BOOTSTRAP_TEST_SUDO_STATE_FILE" ]; then
  printf 'mock sudo rejected a command before foreground authorization\n' >&2
  exit 92
fi
[ "$#" -gt 0 ] || exit 93

export CF_BOOTSTRAP_TEST_UNDER_SUDO=1
exec "$@"
