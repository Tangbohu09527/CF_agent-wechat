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
PRODUCTION_ROOT=""
trap 'rm -rf -- "$TEST_ROOT" "${PRODUCTION_ROOT:-}"' EXIT

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

if ! { [ -n "${HOME:-}" ] && [ -d "$HOME" ]; }; then
  fail "a real home directory is required for production-path tests"
fi
PRODUCTION_ROOT="$(mktemp -d "${HOME%/}/.cf-agent-wechat-deps.XXXXXX")"
chmod 700 -- "$PRODUCTION_ROOT"

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
      case "${arguments[$((index + 2))]}" in
        "${root}/venv"|\
        "${root}/drift-path-marker-never-print/current/venv") ;;
        *) return 1 ;;
      esac
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
        "${root}/venv"|"${root}/venv.previous."*|"${root}/venv.failed."*|\
        "${root}/drift-path-marker-never-print/current/venv"|\
        "${root}/drift-path-marker-never-print/current/venv.previous."*|\
        "${root}/drift-path-marker-never-print/current/venv.failed."*) ;;
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

replace_venv_ancestor() {
  local target="$1" parent replacement attacker

  parent="$(dirname -- "$target")"
  replacement="${parent}.real"
  attacker="$(dirname -- "$parent")/attacker"
  [ -d "$parent" ] && [ ! -L "$parent" ] || exit 2
  [ ! -e "$replacement" ] && [ ! -L "$replacement" ] || exit 2
  mkdir -p -- "$attacker"
  : > "${attacker}/attacker-sentinel"
  mv -- "$parent" "$replacement"
  ln -s -- "$attacker" "$parent"
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
    printf '%s\n' "$target" > "${root}/drift-target"
    if [ "$mode" = ancestor-drift-after-venv ]; then
      replace_venv_ancestor "$target"
    fi
    exit 0
    ;;
  *" -m pip --version "*)
    [ "$mode" != ensurepip-fail ] || exit 2
    printf '%s\n' 'pip fixture'
    exit 0
    ;;
  *" -m pip install "*)
    case "$mode" in
      pip-install-fail) exit 2 ;;
      pip-timeout) sleep 20; exit 2 ;;
    esac
    : > "${root}/installed"
    if [ "$mode" = ancestor-drift-after-pip ]; then
      replace_venv_ancestor "$(<"${root}/drift-target")"
    fi
    exit 0
    ;;
esac
exit 2
EOF
chmod 700 -- "${TEST_ROOT}/fake-python"

cp -- "${TEST_ROOT}/fake-python" "${PRODUCTION_ROOT}/fake-python"
cp -- "${TEST_ROOT}/contract" "${PRODUCTION_ROOT}/contract"
cp -- "${TEST_ROOT}/lock-sha" "${PRODUCTION_ROOT}/lock-sha"
cp -- "$REQUIREMENTS" "${PRODUCTION_ROOT}/requirements.txt"
cp -- "$VERIFIER" "${PRODUCTION_ROOT}/verify_login_dependencies.py"
printf '%s\n' normal > "${PRODUCTION_ROOT}/mode"
: > "${PRODUCTION_ROOT}/audit"
chmod 700 -- "${PRODUCTION_ROOT}/fake-python"

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

make_valid_production_venv() {
  rm -rf -- "${PRODUCTION_ROOT}/venv"
  mkdir -p -- "${PRODUCTION_ROOT}/venv/bin"
  ln -s -- "${PRODUCTION_ROOT}/fake-python" \
    "${PRODUCTION_ROOT}/venv/bin/python"
  cp -- "${PRODUCTION_ROOT}/contract" \
    "${PRODUCTION_ROOT}/venv/.cf-agent-wechat-requirements"
  chmod 600 -- "${PRODUCTION_ROOT}/venv/.cf-agent-wechat-requirements"
  chmod 700 -- "${PRODUCTION_ROOT}/venv" "${PRODUCTION_ROOT}/venv/bin"
  : > "${PRODUCTION_ROOT}/installed"
}

make_valid_production_venv
: > "${PRODUCTION_ROOT}/audit"
production_result="$(
  HTTPS_PROXY='http://proxy-user:proxy-password@attacker.invalid:8080' \
  AUTH_TOKEN='production-reuse-token-never-print' \
  /bin/bash "$HELPER" \
    "${PRODUCTION_ROOT}/fake-python" \
    "${PRODUCTION_ROOT}/venv" \
    "${PRODUCTION_ROOT}/requirements.txt" \
    "${PRODUCTION_ROOT}/verify_login_dependencies.py" 5 2 1 5 0
)"
[ "$production_result" = "${PRODUCTION_ROOT}/venv/bin/python" ] ||
  fail "safe production-mode venv did not return its interpreter"
if grep -qE ' <-m> <(venv|pip)>' "${PRODUCTION_ROOT}/audit"; then
  fail "safe production-mode venv was rebuilt or reinstalled"
fi
if grep -qE 'proxy-(user|password)|production-reuse-token' \
  "${PRODUCTION_ROOT}/audit"; then
  fail "production-mode reuse passed a host credential to Python"
fi
printf '%s\n' \
  'PASS safe production-mode venv reuses the approved contract without pip'

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
make_valid_production_venv
chmod 755 -- "${PRODUCTION_ROOT}/venv"
if /bin/bash "$HELPER" "${PRODUCTION_ROOT}/fake-python" \
  "${PRODUCTION_ROOT}/venv" \
  "${PRODUCTION_ROOT}/requirements.txt" \
  "${PRODUCTION_ROOT}/verify_login_dependencies.py" 5 2 1 5 0 \
  > "${TEST_ROOT}/unsafe-mode.out" 2>&1; then
  fail "world-readable production venv unexpectedly passed"
fi
grep -q 'mode 0700' "${TEST_ROOT}/unsafe-mode.out" ||
  fail "unsafe venv mode did not return bounded remediation"
chmod 700 -- "${PRODUCTION_ROOT}/venv"
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
grep -q 'unsafe ancestor contract' "${TEST_ROOT}/ancestor-link.out" ||
  fail "ancestor symlink rejection did not return bounded guidance"
printf '%s\n' 'PASS venv path rejects every existing symbolic-link ancestor'

unsafe_parent="${PRODUCTION_ROOT}/ancestor-path-marker-never-print"
mkdir -m 0770 -- "$unsafe_parent"
: > "${PRODUCTION_ROOT}/audit"
if AUTH_TOKEN='writable-ancestor-token-never-print' \
  /bin/bash "$HELPER" "${PRODUCTION_ROOT}/fake-python" \
    "${unsafe_parent}/venv" \
    "${PRODUCTION_ROOT}/requirements.txt" \
    "${PRODUCTION_ROOT}/verify_login_dependencies.py" 5 2 1 5 0 \
    > "${TEST_ROOT}/writable-ancestor.out" 2>&1; then
  fail "group-writable production ancestor unexpectedly passed"
fi
[ ! -e "${unsafe_parent}/venv" ] ||
  fail "writable ancestor rejection created a venv"
[ ! -s "${PRODUCTION_ROOT}/audit" ] ||
  fail "writable ancestor rejection executed Python before failing"
grep -q 'unsafe ancestor contract' "${TEST_ROOT}/writable-ancestor.out" ||
  fail "writable ancestor rejection did not return bounded guidance"
if grep -qE 'ancestor-path-marker|writable-ancestor-token' \
  "${TEST_ROOT}/writable-ancestor.out"; then
  fail "writable ancestor rejection disclosed a path or secret"
fi
printf '%s\n' \
  'PASS production paths reject writable ancestors before execution'

assert_ancestor_drift_fails_closed() {
  local stage="$1" preserve_old="${2:-0}" drift_root current real output

  drift_root="${TEST_ROOT}/drift-path-marker-never-print"
  current="${drift_root}/current"
  real="${current}.real"
  output="${TEST_ROOT}/${stage}.out"
  rm -rf -- "$drift_root"
  mkdir -m 700 -- "$drift_root"
  mkdir -m 700 -- "$current"
  if [ "$preserve_old" -eq 1 ]; then
    mkdir -p -- "${current}/venv/bin"
    chmod 700 -- "${current}/venv" "${current}/venv/bin"
    ln -s -- "${TEST_ROOT}/fake-python" "${current}/venv/bin/python"
    cp -- "${TEST_ROOT}/contract" \
      "${current}/venv/.cf-agent-wechat-requirements"
    chmod 600 -- "${current}/venv/.cf-agent-wechat-requirements"
    : > "${current}/venv/old-sentinel"
  fi
  rm -f -- "${TEST_ROOT}/installed" "${TEST_ROOT}/drift-target"
  printf '%s\n' "$stage" > "${TEST_ROOT}/mode"
  : > "${TEST_ROOT}/audit"

  if AUTH_TOKEN='ancestor-drift-token-never-print' \
    /bin/bash "$HELPER" "${TEST_ROOT}/fake-python" \
      "${current}/venv" "$REQUIREMENTS" "$VERIFIER" 5 2 1 5 1 \
      > "$output" 2>&1; then
    fail "$stage unexpectedly succeeded"
  fi
  [ -L "$current" ] || fail "$stage did not install the attack symlink"
  [ -e "${current}/attacker-sentinel" ] ||
    fail "$stage rollback followed or replaced the attacker path"
  [ ! -e "${current}/venv" ] ||
    fail "$stage rollback wrote through the attacker path"
  [ -d "${real}/venv" ] ||
    fail "$stage did not preserve the isolated venv evidence"
  [ ! -e "${real}/venv/.cf-agent-wechat-requirements" ] ||
    fail "$stage committed a dependency stamp after ancestor drift"
  if [ "$preserve_old" -eq 1 ]; then
    local -a old_evidence=("${real}"/venv.previous.*)
    if ! { [ "${#old_evidence[@]}" -eq 1 ] &&
      [ -d "${old_evidence[0]}" ] &&
      [ -e "${old_evidence[0]}/old-sentinel" ]; }; then
      fail "$stage did not preserve the prior venv evidence"
    fi
    [ ! -e "${current}/old-sentinel" ] ||
      fail "$stage exposed prior evidence through the attacker path"
  fi
  grep -q 'ancestor contract changed' "$output" ||
    fail "$stage did not return the bounded drift error"
  if grep -qE 'drift-path-marker|ancestor-drift-token' "$output"; then
    fail "$stage output disclosed a path or secret"
  fi

  case "$stage" in
    ancestor-drift-after-venv)
      if grep -q ' <-m> <pip>' "${TEST_ROOT}/audit"; then
        fail "$stage reached pip after the ancestor changed"
      fi
      ;;
    ancestor-drift-after-pip)
      grep -q ' <-m> <pip> <install>' "${TEST_ROOT}/audit" ||
        fail "$stage did not reach the intended pip boundary"
      if grep -q ' <verify-installed>' "${TEST_ROOT}/audit"; then
        fail "$stage verified or stamped dependencies after ancestor drift"
      fi
      ;;
  esac
}

assert_ancestor_drift_fails_closed ancestor-drift-after-venv
printf '%s\n' 'PASS venv-stage ancestor drift fails closed before pip'
assert_ancestor_drift_fails_closed ancestor-drift-after-pip
printf '%s\n' 'PASS pip-stage ancestor drift fails closed before commit'
assert_ancestor_drift_fails_closed ancestor-drift-after-pip 1
printf '%s\n' \
  'PASS ancestor drift preserves the prior venv outside the attacker path'

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
assert_failure_restores_old pip-install-fail
printf '%s\n' 'PASS general pip installation failure restores the prior venv'
assert_failure_restores_old pip-timeout 1
grep -q 'hard timeout' "${TEST_ROOT}/pip-timeout.out" ||
  fail "pip timeout was not distinguished"
printf '%s\n' 'PASS pip installation hard timeout restores the prior venv'

hash_test_root="${TEST_ROOT}/real-pip-hash-mismatch"
hash_wheel_dir="${hash_test_root}/wheels"
hash_venv="${hash_test_root}/venv"
hash_requirements="${hash_test_root}/requirements.txt"
hash_output="${hash_test_root}/pip.out"
hash_package='cf-agent-wechat-hash-fixture'
hash_module='cf_agent_wechat_hash_fixture'
hash_wheel="${hash_wheel_dir}/${hash_module}-1.0-py3-none-any.whl"
mkdir -p -- "$hash_wheel_dir" "${hash_test_root}/home"

python3 -I -B - "$hash_wheel" <<'PY'
import base64
import hashlib
import sys
import zipfile

wheel_path = sys.argv[1]
module = "cf_agent_wechat_hash_fixture"
dist_info = f"{module}-1.0.dist-info"
files = {
    f"{module}/__init__.py": b"VERSION = '1.0'\n",
    f"{dist_info}/METADATA": (
        b"Metadata-Version: 2.1\n"
        b"Name: cf-agent-wechat-hash-fixture\n"
        b"Version: 1.0\n"
    ),
    f"{dist_info}/WHEEL": (
        b"Wheel-Version: 1.0\n"
        b"Generator: cf-agent-wechat-offline-test\n"
        b"Root-Is-Purelib: true\n"
        b"Tag: py3-none-any\n"
    ),
}
record_path = f"{dist_info}/RECORD"
records = []
for name, content in files.items():
    digest = base64.urlsafe_b64encode(hashlib.sha256(content).digest())
    records.append(f"{name},sha256={digest.rstrip(b'=').decode('ascii')},{len(content)}")
records.append(f"{record_path},,")
files[record_path] = ("\n".join(records) + "\n").encode("ascii")

with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as archive:
    for name, content in files.items():
        archive.writestr(name, content)
PY

{
  printf '%s\n' '--require-hashes'
  printf '%s\n' '--only-binary=:all:'
  printf '%s\n' '--no-index'
  printf '%s\n' "--find-links file://${hash_wheel_dir}"
  printf '%s\n' \
    "${hash_package}==1.0 --hash=sha256:$(printf '0%.0s' {1..64})"
} > "$hash_requirements"

python3 -I -B -m venv "$hash_venv"
if timeout --signal=TERM --kill-after=5s 30s \
  /usr/bin/env -i \
    HOME="${hash_test_root}/home" \
    LANG=C.UTF-8 \
    PATH=/usr/bin:/bin \
    PIP_CONFIG_FILE=/dev/null \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_NO_INPUT=1 \
    "${hash_venv}/bin/python" -I -B -m pip install \
      --require-hashes \
      --only-binary=:all: \
      --no-index \
      --find-links "file://${hash_wheel_dir}" \
      --no-deps \
      --requirement "$hash_requirements" \
      > "$hash_output" 2>&1; then
  fail "real pip accepted a wheel with an incorrect SHA-256"
fi
grep -q 'THESE PACKAGES DO NOT MATCH THE HASHES' "$hash_output" ||
  fail "real pip failure was not identified as a hash mismatch"
grep -q 'Expected sha256' "$hash_output" ||
  fail "real pip did not report the expected hash boundary"
grep -q 'Got' "$hash_output" ||
  fail "real pip did not report the observed hash boundary"
if find "$hash_venv" -type d -name "$hash_module" -print -quit | grep -q .; then
  fail "real pip installed the hash-mismatched fixture"
fi
printf '%s\n' \
  'PASS real pip rejects an offline wheel with an incorrect SHA-256'

cp -- "$REQUIREMENTS" "${PRODUCTION_ROOT}/invalid-requirements.txt"
sed -i '0,/sha256:[0-9a-f]\{64\}/s//sha256:abc/' \
  "${PRODUCTION_ROOT}/invalid-requirements.txt"
rm -rf -- "${PRODUCTION_ROOT}/invalid-venv"
if /bin/bash "$HELPER" "$(command -v python3)" \
  "${PRODUCTION_ROOT}/invalid-venv" \
  "${PRODUCTION_ROOT}/invalid-requirements.txt" \
  "${PRODUCTION_ROOT}/verify_login_dependencies.py" 5 2 1 5 0 \
  > "${TEST_ROOT}/invalid-lock.out" 2>&1; then
  fail "malformed dependency hash unexpectedly passed"
fi
[ ! -e "${PRODUCTION_ROOT}/invalid-venv" ] ||
  fail "invalid hash lock created a venv"
printf '%s\n' 'PASS malformed dependency hash fails before venv creation'
