#!/usr/bin/env bash
set -euo pipefail

: "${CF_TEST_REAL_STAT:?}"
: "${CF_TEST_STAT_REPO_ROOT:?}"
: "${CF_TEST_STAT_DOCKER_DIR:?}"
: "${CF_TEST_STAT_COMPOSE_FILE:?}"
: "${CF_TEST_STAT_ENV_FILE:?}"
: "${CF_TEST_CURRENT_UID:?}"

format="${2:-}"
path="${4:-}"
bad_uid=1
if [ "$CF_TEST_CURRENT_UID" = 1 ]; then
  bad_uid=2
fi

fixture_mode() {
  case "$1" in
    "$CF_TEST_STAT_REPO_ROOT"|"$CF_TEST_STAT_DOCKER_DIR") printf '%s' 755 ;;
    "$CF_TEST_STAT_COMPOSE_FILE") printf '%s' 644 ;;
    "$CF_TEST_STAT_ENV_FILE") printf '%s' 600 ;;
    *) printf '%s' 755 ;;
  esac
}

if [ -n "${CF_TEST_STAT_UNAPPROVED_OWNER_TARGET:-}" ] &&
  [ "$path" = "$CF_TEST_STAT_UNAPPROVED_OWNER_TARGET" ]; then
  mode="$(fixture_mode "$path")"
  case "$format" in
    '%u:%a') printf '%s:%s\n' "$bad_uid" "$mode" ;;
    '%u:%a:%h') printf '%s:%s:1\n' "$bad_uid" "$mode" ;;
    *) exec "$CF_TEST_REAL_STAT" "$@" ;;
  esac
  exit 0
fi

if [ -n "${CF_TEST_STAT_HARDLINK_TARGET:-}" ] &&
  [ "$path" = "$CF_TEST_STAT_HARDLINK_TARGET" ] &&
  [ "$format" = '%u:%a:%h' ]; then
  printf '%s:%s:2\n' "$CF_TEST_CURRENT_UID" "$(fixture_mode "$path")"
  exit 0
fi

if [ "${CF_TEST_FORCE_STAT_FIXTURE_METADATA:-0}" = 1 ]; then
  case "$path:$format" in
    "$CF_TEST_STAT_REPO_ROOT:%u:%a"|"$CF_TEST_STAT_DOCKER_DIR:%u:%a")
      printf '%s:755\n' "$CF_TEST_CURRENT_UID"
      exit 0
      ;;
    "$CF_TEST_STAT_COMPOSE_FILE:%u:%a:%h")
      printf '%s:644:1\n' "$CF_TEST_CURRENT_UID"
      exit 0
      ;;
    "$CF_TEST_STAT_ENV_FILE:%u:%a:%h")
      printf '%s:600:1\n' "$CF_TEST_CURRENT_UID"
      exit 0
      ;;
  esac
fi

exec "$CF_TEST_REAL_STAT" "$@"
