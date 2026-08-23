#!/usr/bin/env bash
set -euo pipefail

validate_contract_invocation() {
  local command="$1"
  shift
  local -a arguments=("$@")
  local index=-1 candidate mock_venv

  mock_venv="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"

  for candidate in "${!arguments[@]}"; do
    if [ "${arguments[$candidate]}" = "$command" ]; then
      index="$candidate"
      break
    fi
  done
  [ "$index" -ge 0 ] || return 1
  case "$command" in
    validate-lock)
      [ "${#arguments[@]}" -eq $((index + 2)) ] || return 1
      CONTRACT_REQUIREMENTS="${arguments[$((index + 1))]}"
      ;;
    verify-installed)
      [ "${#arguments[@]}" -eq $((index + 9)) ] || return 1
      CONTRACT_REQUIREMENTS="${arguments[$((index + 1))]}"
      [ "${arguments[$((index + 2))]}" = "$mock_venv" ] || return 1
      [ "${arguments[$((index + 3))]}" = --base-python ] || return 1
      [ -n "${arguments[$((index + 4))]}" ] || return 1
      [ "${arguments[$((index + 5))]}" = --expected-uid ] || return 1
      [[ "${arguments[$((index + 6))]}" =~ ^[0-9]+$ ]] || return 1
      [ "${arguments[$((index + 7))]}" = --expected-gid ] || return 1
      [[ "${arguments[$((index + 8))]}" =~ ^[0-9]+$ ]] || return 1
      ;;
    audit-tree)
      [ "${#arguments[@]}" -eq $((index + 8)) ] || return 1
      [ "${arguments[$((index + 1))]}" = "$mock_venv" ] || return 1
      [ "${arguments[$((index + 2))]}" = --base-python ] || return 1
      [ -n "${arguments[$((index + 3))]}" ] || return 1
      [ "${arguments[$((index + 4))]}" = --expected-uid ] || return 1
      [[ "${arguments[$((index + 5))]}" =~ ^[0-9]+$ ]] || return 1
      [ "${arguments[$((index + 6))]}" = --expected-gid ] || return 1
      [[ "${arguments[$((index + 7))]}" =~ ^[0-9]+$ ]] || return 1
      ;;
    *) return 1 ;;
  esac
}

CONTRACT_REQUIREMENTS=""
if printf '%s\n' "$@" | grep -qx -- validate-lock; then
  validate_contract_invocation validate-lock "$@" || exit 2
  sha256sum -- "$CONTRACT_REQUIREMENTS" | awk '{ print $1 }'
  exit 0
elif printf '%s\n' "$@" | grep -qx -- verify-installed; then
  validate_contract_invocation verify-installed "$@" || exit 2
  requirements_sha256="$(sha256sum -- "$CONTRACT_REQUIREMENTS" | awk '{ print $1 }')"
  printf '%s\n' \
    'schema=3' \
    "requirements_sha256=${requirements_sha256}" \
    'python_implementation=cpython' \
    'python_version=fixture' \
    'python_gil=enabled' \
    "records_sha256=$(printf 'd%.0s' {1..64})" \
    "tree_sha256=$(printf 'e%.0s' {1..64})"
  exit 0
elif printf '%s\n' "$@" | grep -qx -- audit-tree; then
  validate_contract_invocation audit-tree "$@" || exit 2
  exit 0
fi

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
