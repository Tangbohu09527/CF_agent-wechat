#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  printf '%s\n' 'SKIP dependency environment integration test requires Linux'
  exit 0
fi

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HELPER="${REPO_ROOT}/scripts/ensure-login-environment.sh"
VERIFIER="${REPO_ROOT}/scripts/verify_login_dependencies.py"
REQUIREMENTS="${REPO_ROOT}/scripts/requirements.txt"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

LOCK_SHA="$(python3 "$VERIFIER" validate-lock "$REQUIREMENTS")"
printf '%s\n' "$LOCK_SHA" > "${TEST_ROOT}/lock-sha"
cat > "${TEST_ROOT}/contract" <<EOF
schema=3
requirements_sha256=${LOCK_SHA}
python_implementation=cpython
python_version=3.11.fixture
python_gil=enabled
records_sha256=$(printf 'd%.0s' {1..64})
tree_sha256=$(printf 'e%.0s' {1..64})
EOF
printf '%s\n' normal > "${TEST_ROOT}/mode"
: > "${TEST_ROOT}/audit"

cat > "${TEST_ROOT}/fake-python" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
self="$(readlink -f -- "$0")"
root="$(dirname -- "$self")"
mode="$(<"${root}/mode")"
{
  printf 'ARGV'
  printf ' <%s>' "$@"
  printf '\nENV'
  env | LC_ALL=C sort | tr '\n' ' '
  printf '\n'
} >> "${root}/audit"

validate_contract_invocation() {
  local command="$1"
  shift
  local -a arguments=("$@")
  local index=-1 candidate

  for candidate in "${!arguments[@]}"; do
    if [ "${arguments[$candidate]}" = "$command" ]; then
      index="$candidate"
      break
    fi
  done
  [ "$index" -ge 0 ] || return 1
  case "$command" in
    validate-runtime)
      [ "${#arguments[@]}" -eq $((index + 1)) ] || return 1
      ;;
    verify-installed)
      [ "${#arguments[@]}" -eq $((index + 9)) ] || return 1
      [ "${arguments[$((index + 1))]}" = "${root}/requirements.txt" ] ||
        [ -f "${arguments[$((index + 1))]}" ] || return 1
      [ "${arguments[$((index + 2))]}" = "${root}/venv" ] || return 1
      [ "${arguments[$((index + 3))]}" = --base-python ] || return 1
      [ "${arguments[$((index + 4))]}" = "$self" ] || return 1
      [ "${arguments[$((index + 5))]}" = --expected-uid ] || return 1
      [[ "${arguments[$((index + 6))]}" =~ ^[0-9]+$ ]] || return 1
      [ "${arguments[$((index + 7))]}" = --expected-gid ] || return 1
      [[ "${arguments[$((index + 8))]}" =~ ^[0-9]+$ ]] || return 1
      ;;
    audit-tree)
      [ "${#arguments[@]}" -eq $((index + 8)) ] || return 1
      case "${arguments[$((index + 1))]}" in
        "${root}/venv"|"${root}/venv.previous."*|"${root}/venv.failed."*) ;;
        *) return 1 ;;
      esac
      [ "${arguments[$((index + 2))]}" = --base-python ] || return 1
      [ "${arguments[$((index + 3))]}" = "$self" ] || return 1
      [ "${arguments[$((index + 4))]}" = --expected-uid ] || return 1
      [[ "${arguments[$((index + 5))]}" =~ ^[0-9]+$ ]] || return 1
      [ "${arguments[$((index + 6))]}" = --expected-gid ] || return 1
      [[ "${arguments[$((index + 7))]}" =~ ^[0-9]+$ ]] || return 1
      ;;
    *) return 1 ;;
  esac
}

case " $* " in
  *" validate-runtime "*)
    validate_contract_invocation validate-runtime "$@" || exit 2
    [ "$mode" != runtime-fail ] || exit 2
    exit 0
    ;;
  *" validate-lock "*)
    cat "${root}/lock-sha"
    exit 0
    ;;
  *" verify-installed "*)
    validate_contract_invocation verify-installed "$@" || exit 2
    if [ "$mode" = stale-minor ]; then
      for stale_link in "${root}/venv/bin"/python3.*; do
        [ ! -L "$stale_link" ] || exit 2
      done
    fi
    [ -e "${root}/installed" ] || exit 2
    cat "${root}/contract"
    exit 0
    ;;
  *" audit-tree "*)
    validate_contract_invocation audit-tree "$@" || exit 2
    [ "$mode" != audit-fail ] || exit 2
    if [ "$mode" = cleanup-fail ]; then
      case " $* " in
        *" audit-tree ${root}/venv.previous."*) exit 2 ;;
      esac
    fi
    exit 0
    ;;
  *" -m venv "*)
    [ "$mode" != venv-fail ] || exit 2
    target="${!#}"
    mkdir -p -- "${target}/bin"
    ln -s -- "$self" "${target}/bin/python"
    exit 0
    ;;
  *" -m pip --version "*)
    [ "$mode" != ensurepip-fail ] || exit 2
    printf '%s\n' 'pip fixture'
    exit 0
    ;;
  *" -m pip install "*)
    case "$mode" in
      pip-fail) exit 2 ;;
      pip-timeout) sleep 20; exit 2 ;;
    esac
    : > "${root}/installed"
    exit 0
    ;;
esac
exit 2
EOF
chmod 700 -- "${TEST_ROOT}/fake-python"

invoke_helper() {
  HTTPS_PROXY='http://proxy-user:proxy-password@attacker.invalid:8080' \
  AUTH_TOKEN='dependency-token-fixture-sensitive-never-print' \
  HTTP_PROXY='http://proxy-user:proxy-password@attacker.invalid:8080' \
    /bin/bash "$HELPER" \
      "${TEST_ROOT}/fake-python" \
      "${TEST_ROOT}/venv" \
      "$REQUIREMENTS" \
      "$VERIFIER" \
      "${1:-5}" 2 1 5 1
}

make_valid_venv() {
  rm -rf -- "${TEST_ROOT}/venv"
  mkdir -p -- "${TEST_ROOT}/venv/bin"
  ln -s -- "${TEST_ROOT}/fake-python" "${TEST_ROOT}/venv/bin/python"
  cp -- "${TEST_ROOT}/contract" \
    "${TEST_ROOT}/venv/.cf-agent-wechat-requirements"
  chmod 600 -- "${TEST_ROOT}/venv/.cf-agent-wechat-requirements"
  : > "${TEST_ROOT}/installed"
}

make_valid_venv
: > "${TEST_ROOT}/audit"
result="$(invoke_helper)"
[ "$result" = "${TEST_ROOT}/venv/bin/python" ] ||
  fail "valid venv did not return its interpreter"
if grep -qE ' <-m> <(venv|pip)>' "${TEST_ROOT}/audit"; then
  fail "valid venv was rebuilt or reinstalled"
fi
printf '%s\n' 'PASS matching venv reuses the SHA-256 contract without pip'

rm -rf -- "${TEST_ROOT}/venv"
printf '%s\n' runtime-fail > "${TEST_ROOT}/mode"
: > "${TEST_ROOT}/audit"
if invoke_helper > "${TEST_ROOT}/runtime-fail.out" 2>&1; then
  fail "unsupported Python runtime unexpectedly passed"
fi
[ ! -e "${TEST_ROOT}/venv" ] ||
  fail "unsupported Python runtime created a venv before rejection"
grep -q ' <validate-runtime>' "${TEST_ROOT}/audit" ||
  fail "standalone Python runtime gate was not called"
if grep -qE ' <validate-lock>| <-m> <(venv|pip)>' "${TEST_ROOT}/audit"; then
  fail "unsupported Python runtime reached lock, venv, or pip work"
fi
printf '%s\n' \
  'PASS unsupported Python runtime fails before filesystem mutation or pip'

printf '%s\n' normal > "${TEST_ROOT}/mode"
make_valid_venv
chmod 755 -- "${TEST_ROOT}/venv"
if /bin/bash "$HELPER" "${TEST_ROOT}/fake-python" \
  "${TEST_ROOT}/venv" "$REQUIREMENTS" "$VERIFIER" 5 2 1 5 0 \
  > "${TEST_ROOT}/unsafe-mode.out" 2>&1; then
  fail "world-readable production venv unexpectedly passed"
fi
grep -q 'mode 0700' "${TEST_ROOT}/unsafe-mode.out" ||
  fail "unsafe venv mode did not return bounded remediation"
chmod 700 -- "${TEST_ROOT}/venv"
printf '%s\n' \
  'PASS production mode rejects a world-readable venv before execution'



make_valid_venv
ln -s -- "${TEST_ROOT}/fake-python" "${TEST_ROOT}/venv/bin/python3.9"
printf '%s\n' stale-minor > "${TEST_ROOT}/mode"
: > "${TEST_ROOT}/audit"
result="$(invoke_helper)"
[ "$result" = "${TEST_ROOT}/venv/bin/python" ] ||
  fail "stale minor venv rebuild returned an unexpected interpreter"
[ ! -e "${TEST_ROOT}/venv/bin/python3.9" ] ||
  fail "stale minor interpreter link survived the controlled rebuild"
grep -q ' <audit-tree> <' "${TEST_ROOT}/audit" ||
  fail "stale minor venv was not safely audited before replacement"
grep -q ' <-m> <venv>' "${TEST_ROOT}/audit" ||
  fail "stale minor venv was not rebuilt"
printf '%s\n' 'PASS stale Python minor venv is audited then rebuilt'

printf '%s\n' normal > "${TEST_ROOT}/mode"
rm -f -- "${TEST_ROOT}/installed"
: > "${TEST_ROOT}/venv/old-sentinel"
: > "${TEST_ROOT}/audit"
caller_umask="$(umask)"
umask 000
result="$(invoke_helper)"
umask "$caller_umask"
[ "$result" = "${TEST_ROOT}/venv/bin/python" ] ||
  fail "rebuilt venv returned an unexpected interpreter"
[ ! -e "${TEST_ROOT}/venv/old-sentinel" ] ||
  fail "invalid old venv contents survived a controlled rebuild"
grep -q ' <-m> <venv>' "${TEST_ROOT}/audit" || fail "venv was not rebuilt"
grep -q ' <-m> <pip> <install>' "${TEST_ROOT}/audit" ||
  fail "locked dependencies were not installed"
for flag in --require-hashes --only-binary=:all: --no-input --no-compile \
  --disable-pip-version-check --no-cache-dir --retries --timeout; do
  grep -q " <$flag>" "${TEST_ROOT}/audit" || fail "pip flag missing: $flag"
done
if grep -qE 'proxy-(user|password)|HTTPS?_PROXY=' "${TEST_ROOT}/audit"; then
  fail "host proxy credentials reached Python argv or environment"
fi
printf '%s\n' 'PASS drifted venv is atomically rebuilt with bounded hash-only pip'
for setting in PIP_NO_INPUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
  PIP_CONFIG_FILE=/dev/null PIP_NO_CACHE_DIR=1; do
  grep -q "$setting" "${TEST_ROOT}/audit" ||
    fail "clean pip environment setting missing: $setting"
done
if grep -q 'dependency-token-fixture-sensitive' "${TEST_ROOT}/audit"; then
  fail "host Token reached Python argv or environment"
fi
printf '%s\n' 'PASS proxy credentials are absent from pip argv and environment'

[ "$(stat -c '%a' -- "${TEST_ROOT}/venv")" = 700 ] ||
  fail "helper did not force the rebuilt venv to mode 0700"
[ "$(stat -c '%a' -- "${TEST_ROOT}/venv/bin")" = 700 ] ||
  fail "hostile caller umask affected the venv tree"
[ "$(stat -c '%a' -- "${TEST_ROOT}/venv/.cf-agent-wechat-requirements")" = 600 ] ||
  fail "dependency stamp mode is not 0600"
printf '%s\n' 'PASS helper-owned files ignore a hostile caller umask'

make_valid_venv
rm -f -- "${TEST_ROOT}/installed"
: > "${TEST_ROOT}/venv/old-sentinel"
printf '%s\n' cleanup-fail > "${TEST_ROOT}/mode"
if invoke_helper > "${TEST_ROOT}/cleanup-fail.out" 2>&1; then
  fail "post-commit previous-tree cleanup failure unexpectedly succeeded"
fi
[ -e "${TEST_ROOT}/venv/.cf-agent-wechat-requirements" ] ||
  fail "cleanup failure removed the committed dependency stamp"
[ -e "${TEST_ROOT}/installed" ] ||
  fail "cleanup failure rolled back the committed dependency environment"
[ ! -e "${TEST_ROOT}/venv/old-sentinel" ] ||
  fail "cleanup failure restored the obsolete environment over the new one"
shopt -s nullglob
previous_candidates=("${TEST_ROOT}"/venv.previous.*)
failed_candidates=("${TEST_ROOT}"/venv.failed.*)
shopt -u nullglob
[ "${#previous_candidates[@]}" -eq 1 ] ||
  fail "cleanup failure did not preserve exactly one restricted previous tree"
[ -e "${previous_candidates[0]}/old-sentinel" ] ||
  fail "cleanup failure lost the previous environment evidence"
[ "${#failed_candidates[@]}" -eq 0 ] ||
  fail "cleanup failure incorrectly isolated the committed environment"
grep -q 'new dependency environment is committed' \
  "${TEST_ROOT}/cleanup-fail.out" ||
  fail "cleanup failure did not return bounded manual-isolation guidance"
printf '%s\n' \
  'PASS post-commit cleanup failure preserves both new venv and old evidence'
rm -rf -- "${previous_candidates[0]}"

printf '%s\n' normal > "${TEST_ROOT}/mode"
make_valid_venv
rm -f -- "${TEST_ROOT}/installed"
: > "${TEST_ROOT}/venv/unsafe-sentinel"
printf '%s\n' audit-fail > "${TEST_ROOT}/mode"
if invoke_helper > "${TEST_ROOT}/unsafe-audit.out" 2>&1; then
  fail "unsafe venv audit unexpectedly passed"
fi
[ -e "${TEST_ROOT}/venv/unsafe-sentinel" ] ||
  fail "unsafe venv audit moved the original tree"
if find "$TEST_ROOT" -maxdepth 1 \( -name 'venv.previous.*' -o -name 'venv.failed.*' \) |
  grep -q .; then
  fail "unsafe venv audit created a transaction directory"
fi
grep -q 'left in place' "${TEST_ROOT}/unsafe-audit.out" ||
  fail "unsafe venv audit did not return bounded isolation guidance"
printf '%s\n' 'PASS structurally unsafe venv remains in place for manual isolation'

rm -rf -- "${TEST_ROOT}/venv"
actual_parent="${TEST_ROOT}/actual-parent"
linked_parent="${TEST_ROOT}/linked-parent"
mkdir -m 700 -- "$actual_parent"
ln -s -- "$actual_parent" "$linked_parent"
if /bin/bash "$HELPER" "${TEST_ROOT}/fake-python" \
  "${linked_parent}/venv" "$REQUIREMENTS" "$VERIFIER" 5 2 1 5 1 \
  > "${TEST_ROOT}/ancestor-link.out" 2>&1; then
  fail "venv path with a symbolic-link ancestor unexpectedly passed"
fi
[ ! -e "${actual_parent}/venv" ] ||
  fail "venv path followed a symbolic-link ancestor before rejection"
grep -q 'symbolic link ancestors' "${TEST_ROOT}/ancestor-link.out" ||
  fail "ancestor symlink rejection did not return bounded guidance"
printf '%s\n' 'PASS venv path rejects every existing symbolic-link ancestor'

assert_failure_restores_old() {
  local mode="$1"
  local timeout_value="${2:-5}"
  make_valid_venv
  rm -f -- "${TEST_ROOT}/installed"
  : > "${TEST_ROOT}/venv/old-sentinel"
  printf '%s\n' "$mode" > "${TEST_ROOT}/mode"
  : > "${TEST_ROOT}/audit"
  if invoke_helper "$timeout_value" > "${TEST_ROOT}/${mode}.out" 2>&1; then
    fail "$mode unexpectedly succeeded"
  fi
  [ -e "${TEST_ROOT}/venv/old-sentinel" ] ||
    fail "$mode did not restore the prior venv"
  [ ! -e "${TEST_ROOT}/installed" ] ||
    fail "$mode left a falsely initialized dependency marker"
  if grep -qE 'proxy-(user|password)' "${TEST_ROOT}/${mode}.out"; then
    fail "$mode output leaked a proxy credential"
  fi
}

assert_failure_restores_old venv-fail
printf '%s\n' 'PASS unavailable python3-venv restores the prior venv'
assert_failure_restores_old ensurepip-fail
printf '%s\n' 'PASS unavailable ensurepip restores the prior venv'
assert_failure_restores_old pip-fail
printf '%s\n' 'PASS pip/hash failure restores the prior venv'
assert_failure_restores_old pip-timeout 1
grep -q 'hard timeout' "${TEST_ROOT}/pip-timeout.out" ||
  fail "pip timeout was not distinguished"
printf '%s\n' 'PASS pip installation hard timeout restores the prior venv'

cp -- "$REQUIREMENTS" "${TEST_ROOT}/invalid-requirements.txt"
sed -i '0,/sha256:[0-9a-f]\{64\}/s//sha256:abc/' \
  "${TEST_ROOT}/invalid-requirements.txt"
rm -rf -- "${TEST_ROOT}/invalid-venv"
if /bin/bash "$HELPER" "$(command -v python3)" "${TEST_ROOT}/invalid-venv" \
  "${TEST_ROOT}/invalid-requirements.txt" "$VERIFIER" 5 2 1 5 0 \
  > "${TEST_ROOT}/invalid-lock.out" 2>&1; then
  fail "malformed dependency hash unexpectedly passed"
fi
[ ! -e "${TEST_ROOT}/invalid-venv" ] ||
  fail "invalid hash lock created a venv"
printf '%s\n' 'PASS malformed dependency hash fails before venv creation'
