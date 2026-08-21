#!/usr/bin/env bash
set -euo pipefail

: "${CF_BOOTSTRAP_TEST_LOG:?}"

url="${!#}"
connect_timeout=""
request_timeout=""
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  case "${args[index]}" in
    --connect-timeout)
      connect_timeout="${args[index + 1]:-}"
      ;;
    --max-time)
      request_timeout="${args[index + 1]:-}"
      ;;
  esac
done
printf 'curl\t%s\tconnect=%s\tmax=%s\n' \
  "$url" "$connect_timeout" "$request_timeout" >> "$CF_BOOTSTRAP_TEST_LOG"

case "$url" in
  */health)
    [ "${CF_BOOTSTRAP_TEST_API_MODE:-ready}" != "health-fail" ] || exit 22
    printf '%s\n' 'ok'
    ;;
  */api/status/auth)
    : "${CF_BOOTSTRAP_TEST_RUNTIME_ROOT:?}"
    headers="$(/bin/cat)"
    token="$(/bin/cat -- "${CF_BOOTSTRAP_TEST_RUNTIME_ROOT}/secrets/auth-token")"
    expected_headers="$(printf 'Authorization: Bearer %s\nX-Session-Id: default\n' "$token")"
    if [ "$headers" != "$expected_headers" ]; then
      headers=""
      expected_headers=""
      token=""
      exit 22
    fi
    headers=""
    expected_headers=""
    token=""
    [ "${CF_BOOTSTRAP_TEST_API_MODE:-ready}" != "auth-fail" ] || exit 22
    if [ "${CF_BOOTSTRAP_TEST_API_MODE:-ready}" = "invalid-json" ]; then
      printf '%s\n' 'not-json'
    else
      status="${CF_BOOTSTRAP_TEST_AUTH_STATUS:-logged_out}"
      if [ -n "${CF_BOOTSTRAP_TEST_AUTH_SEQUENCE:-}" ]; then
        : "${CF_BOOTSTRAP_TEST_STATE_DIR:?}"
        sequence_index_file="${CF_BOOTSTRAP_TEST_STATE_DIR}/auth-sequence-index"
        sequence_index=0
        if [ -f "$sequence_index_file" ]; then
          sequence_index="$(/bin/cat -- "$sequence_index_file")"
        fi
        IFS=',' read -r -a statuses <<< "$CF_BOOTSTRAP_TEST_AUTH_SEQUENCE"
        [ "${#statuses[@]}" -gt 0 ]
        if [ "$sequence_index" -ge "${#statuses[@]}" ]; then
          sequence_index=$((${#statuses[@]} - 1))
        fi
        status="${statuses[sequence_index]}"
        printf '%s\n' "$((sequence_index + 1))" > "$sequence_index_file"
      fi
      printf '{"status":"%s"}\n' "$status"
    fi
    ;;
  *)
    exit 22
    ;;
esac
