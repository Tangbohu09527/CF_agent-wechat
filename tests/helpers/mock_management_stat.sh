#!/usr/bin/env bash
set -euo pipefail

: "${CF_TEST_REAL_STAT:?}"
: "${CF_TEST_STAT_REPO_ROOT:?}"
: "${CF_TEST_STAT_DOCKER_DIR:?}"
: "${CF_TEST_STAT_ENV_FILE:?}"

format="${2:-}"
path="${4:-}"

if [ "$format" = '%a' ]; then
  if [ "$path" = "$CF_TEST_STAT_REPO_ROOT" ] ||
    [ "$path" = "$CF_TEST_STAT_DOCKER_DIR" ]; then
    printf '%s\n' '755'
    exit 0
  fi
  if [ "$path" = "$CF_TEST_STAT_ENV_FILE" ]; then
    printf '%s\n' '600'
    exit 0
  fi
fi

exec "$CF_TEST_REAL_STAT" "$@"
