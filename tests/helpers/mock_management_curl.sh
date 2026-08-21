#!/usr/bin/env bash
set -euo pipefail

: "${CF_TEST_API_STATE_FILE:?}"
: "${CF_TEST_AUTH_STATE_FILE:?}"
: "${CF_TEST_TOKEN_FILE:?}"
: "${CF_TEST_REQUEST_LOG:?}"

url=""
read_headers=0
for argument in "$@"; do
  case "$argument" in
    http://*|https://*) url="$argument" ;;
    @-) read_headers=1 ;;
  esac
done

api_state="$(awk 'NR == 1 { print $1 }' "$CF_TEST_API_STATE_FILE")"
if [ "$api_state" != "reachable" ]; then
  exit 7
fi

case "$url" in
  */health)
    printf '%s\n' 'GET health' >> "$CF_TEST_REQUEST_LOG"
    printf '%s\n' '{"status":"ok"}'
    ;;
  */api/status/auth)
    [ "$read_headers" -eq 1 ] || exit 65
    headers="$(cat)"
    token="$(cat "$CF_TEST_TOKEN_FILE")"
    case "$headers" in
      *"Authorization: Bearer $token"*) ;;
      *) exit 66 ;;
    esac
    case "$headers" in
      *"X-Session-Id: default"*) ;;
      *) exit 66 ;;
    esac
    printf '%s\n' 'GET auth' >> "$CF_TEST_REQUEST_LOG"
    auth_state="$(awk 'NR == 1 { print $1 }' "$CF_TEST_AUTH_STATE_FILE")"
    case "$auth_state" in
      logged_in)
        printf '%s\n' '{"status":"logged_in","loggedInUser":"account-must-not-print"}'
        ;;
      logged_out|app_not_running|qr_pending|waiting_for_qr|waiting_for_scan)
        printf '{"status":"%s"}\n' "$auth_state"
        ;;
      invalid)
        printf '%s\n' 'not-json'
        ;;
      *)
        exit 65
        ;;
    esac
    ;;
  */api/status/login)
    printf '%s\n' 'POST login' >> "$CF_TEST_REQUEST_LOG"
    printf '%s\n' '{"state":{"qrData":"fixture://fresh"}}'
    ;;
  *)
    exit 64
    ;;
esac
