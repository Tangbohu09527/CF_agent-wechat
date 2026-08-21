#!/usr/bin/env bash
set -euo pipefail

: "${CF_BOOTSTRAP_REAL_INSTALL:?}"

directory_mode=0
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      directory_mode=1
      shift
      ;;
    -o|-g|-m)
      shift 2
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [ "$directory_mode" -eq 1 ]; then
  exec mkdir -p -- "${args[@]}"
fi
exec "$CF_BOOTSTRAP_REAL_INSTALL" "${args[@]}"
