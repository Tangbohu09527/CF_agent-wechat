#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -c)
    exit 0
    ;;
esac

case " $* " in
  *" --render-json "*)
    cat >/dev/null
    exit 4
    ;;
  *" --listen "*)
    cat >/dev/null
    if printf '%s\n' "$@" | grep -qx -- '--new-account'; then
      printf '%s\n' 'QR login new-account=true' >> "${MOCK_LOGIN_LOG:?}"
    else
      printf '%s\n' 'QR login new-account=false' >> "${MOCK_LOGIN_LOG:?}"
    fi
    if [ "${MOCK_LOGIN_MODE:-success}" = "block" ]; then
      : > "${MOCK_LOGIN_PAUSE_FILE:?}"
      while [ ! -e "${MOCK_LOGIN_CONTINUE_FILE:?}" ]; do
        sleep 0.05
      done
    fi
    if [ "${MOCK_LOGIN_MODE:-success}" = "fail" ]; then
      printf '%s\n' 'fixture login failed' >&2
      exit 1
    fi
    printf '%s\n' '请使用手机微信扫描二维码：'
    printf '%s\n' '[fixture QR rendered in terminal]'
    printf '%s\n' '登录成功。'
    printf '%s\n' 'logged_in' > "${MOCK_AUTH_STATE_FILE:?}"
    if [ -n "${MOCK_WECHAT_AFTER_LOGIN:-}" ]; then
      printf '%s\n' "$MOCK_WECHAT_AFTER_LOGIN" > \
        "${MOCK_DOCKER_STATE_DIR:?}/wechat_mode"
      printf '%s\n' '0' > "${MOCK_DOCKER_STATE_DIR}/wechat_calls"
    fi
    exit 0
    ;;
esac

exec "${MOCK_REAL_PYTHON:?}" "$@"
