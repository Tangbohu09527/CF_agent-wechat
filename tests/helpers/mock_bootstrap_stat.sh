#!/usr/bin/env bash
set -euo pipefail

: "${CF_BOOTSTRAP_TEST_RUNTIME_ROOT:?}"
: "${CF_BOOTSTRAP_TEST_ENV_FILE:?}"
: "${CF_BOOTSTRAP_REAL_STAT:?}"
: "${CF_BOOTSTRAP_TEST_RUNTIME_UID:?}"
: "${CF_BOOTSTRAP_TEST_RUNTIME_GID:?}"
: "${CF_BOOTSTRAP_TEST_RUNTIME_MODE:?}"
: "${CF_BOOTSTRAP_TEST_STORAGE_UID:?}"
: "${CF_BOOTSTRAP_TEST_STORAGE_GID:?}"
: "${CF_BOOTSTRAP_TEST_SECRETS_UID:?}"
: "${CF_BOOTSTRAP_TEST_SECRETS_GID:?}"

format="${2:-}"
path="${4:-}"

if [ "$path" = "${CF_BOOTSTRAP_TEST_APP_ROOT:-}" ] && \
  [ "$format" = '%a' ] && [ "${CF_BOOTSTRAP_TEST_INSECURE_APP_ROOT:-0}" = "1" ]; then
  printf '%s\n' '777'
  exit 0
fi

if [ "$path" = "$(dirname -- "$CF_BOOTSTRAP_TEST_ENV_FILE")" ] && \
  [ "$format" = '%a' ] && [ "${CF_BOOTSTRAP_TEST_INSECURE_ENV_PARENT:-0}" = "1" ]; then
  printf '%s\n' '777'
  exit 0
fi

if [ "$path" = "${CF_BOOTSTRAP_TEST_COMPOSE_FILE:-}" ] && \
  [ "$format" = '%a' ] && [ "${CF_BOOTSTRAP_TEST_INSECURE_COMPOSE_FILE:-0}" = "1" ]; then
  printf '%s\n' '666'
  exit 0
fi

if [ "$path" = "$CF_BOOTSTRAP_TEST_ENV_FILE" ] && [ "$format" = '%a' ]; then
  printf '%s\n' "${CF_BOOTSTRAP_TEST_ENV_FILE_MODE:-600}"
  exit 0
fi

if [ "$format" = '%u:%g:%a' ]; then
  if [ "$path" = "$CF_BOOTSTRAP_TEST_RUNTIME_ROOT/wechat-home" ] && \
    [ "${CF_BOOTSTRAP_TEST_BAD_RUNTIME_METADATA:-0}" = "1" ]; then
    printf '%s:%s:755\n' "$CF_BOOTSTRAP_TEST_RUNTIME_UID" "$CF_BOOTSTRAP_TEST_RUNTIME_GID"
    exit 0
  fi
  case "$path" in
    "$CF_BOOTSTRAP_TEST_RUNTIME_ROOT")
      printf '%s:%s:755\n' "$CF_BOOTSTRAP_TEST_STORAGE_UID" "$CF_BOOTSTRAP_TEST_STORAGE_GID"
      exit 0
      ;;
    "$CF_BOOTSTRAP_TEST_RUNTIME_ROOT/secrets")
      printf '%s:%s:700\n' "$CF_BOOTSTRAP_TEST_SECRETS_UID" "$CF_BOOTSTRAP_TEST_SECRETS_GID"
      exit 0
      ;;
    "$CF_BOOTSTRAP_TEST_RUNTIME_ROOT/secrets/auth-token")
      printf '%s:%s:600\n' "$CF_BOOTSTRAP_TEST_SECRETS_UID" "$CF_BOOTSTRAP_TEST_SECRETS_GID"
      exit 0
      ;;
    "$CF_BOOTSTRAP_TEST_RUNTIME_ROOT/data"|"$CF_BOOTSTRAP_TEST_RUNTIME_ROOT/wechat-home")
      printf '%s:%s:%s\n' "$CF_BOOTSTRAP_TEST_RUNTIME_UID" "$CF_BOOTSTRAP_TEST_RUNTIME_GID" "$CF_BOOTSTRAP_TEST_RUNTIME_MODE"
      exit 0
      ;;
  esac
fi

exec "$CF_BOOTSTRAP_REAL_STAT" "$@"
