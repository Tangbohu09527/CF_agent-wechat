#!/usr/bin/env bash
umask 077
set -euo pipefail
set +x

usage() {
  printf '%s\n' \
    'usage: ensure-login-environment.sh PYTHON VENV REQUIREMENTS VERIFIER INSTALL_TIMEOUT NETWORK_TIMEOUT RETRIES VENV_TIMEOUT TESTING' >&2
  exit 64
}

[ "$#" -eq 9 ] || usage
python_bin="$1"
venv_dir="$2"
requirements_file="$3"
verifier="$4"
install_timeout="$5"
network_timeout="$6"
retries="$7"
venv_timeout="$8"
testing_mode="$9"

case "$python_bin$venv_dir$requirements_file$verifier" in
  *$'\r'*|*$'\n'*)
    printf '%s\n' 'dependency paths contain a control character' >&2
    exit 65
    ;;
esac
for absolute_path in "$python_bin" "$venv_dir" "$requirements_file" "$verifier"; do
  case "$absolute_path" in
    /*) ;;
    *)
      printf '%s\n' 'dependency management paths must be absolute' >&2
      exit 65
      ;;
  esac
done
[[ "$install_timeout" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$network_timeout" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$retries" =~ ^[0-5]$ ]] || usage
[[ "$venv_timeout" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$testing_mode" =~ ^[01]$ ]] || usage

bounded_clean_python() {
  local executable="$1"
  shift
  /usr/bin/timeout --signal=TERM --kill-after=2s 30s /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
    "$executable" "$@"
}

requirements_snapshot_base64=""
requirements_source_identity=""
REQUIREMENTS_READ_BASE64=""
REQUIREMENTS_READ_IDENTITY=""

read_requirements_source() {
  local metadata opened visible final encoded
  local device inode owner group mode links size mtime ctime file_type
  local requirements_fd

  REQUIREMENTS_READ_BASE64=""
  REQUIREMENTS_READ_IDENTITY=""
  if [ -L "$requirements_file" ] || [ ! -f "$requirements_file" ] ||
    [ ! -r "$requirements_file" ]; then
    return 1
  fi
  metadata="$(LC_ALL=C /usr/bin/stat -Lc \
    $'%d\t%i\t%u\t%g\t%a\t%h\t%s\t%y\t%z\t%F' -- \
    "$requirements_file" 2>/dev/null)" || return 1
  IFS=$'\t' read -r device inode owner group mode links size mtime ctime \
    file_type <<< "$metadata"
  [[ "$device" =~ ^[0-9]+$ ]] && [[ "$inode" =~ ^[0-9]+$ ]] &&
    [[ "$owner" =~ ^[0-9]+$ ]] && [[ "$group" =~ ^[0-9]+$ ]] &&
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [ "$links" = 1 ] &&
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le 1048576 ] &&
    [ -n "$mtime" ] && [ -n "$ctime" ] &&
    [ "$file_type" = 'regular file' ] || return 1
  if [ "$testing_mode" = "0" ]; then
    case "$owner:$mode" in
      0:644|"${current_uid}:644") ;;
      *) return 1 ;;
    esac
  fi
  if ! { exec {requirements_fd}<"$requirements_file"; } 2>/dev/null; then
    return 1
  fi
  if [ -L "$requirements_file" ] ||
    ! opened="$(LC_ALL=C /usr/bin/stat -Lc \
      $'%d\t%i\t%u\t%g\t%a\t%h\t%s\t%y\t%z\t%F' -- \
      "/proc/self/fd/${requirements_fd}" 2>/dev/null)" ||
    ! visible="$(LC_ALL=C /usr/bin/stat -Lc \
      $'%d\t%i\t%u\t%g\t%a\t%h\t%s\t%y\t%z\t%F' -- \
      "$requirements_file" 2>/dev/null)" ||
    [ "$opened" != "$metadata" ] || [ "$visible" != "$metadata" ]; then
    exec {requirements_fd}<&-
    return 1
  fi
  if ! encoded="$(
    /usr/bin/timeout --signal=TERM --kill-after=2s 30s \
      /usr/bin/base64 --wrap=0 -- "/proc/self/fd/${requirements_fd}"
  )"; then
    exec {requirements_fd}<&-
    return 1
  fi
  if [ -L "$requirements_file" ] ||
    ! final="$(LC_ALL=C /usr/bin/stat -Lc \
      $'%d\t%i\t%u\t%g\t%a\t%h\t%s\t%y\t%z\t%F' -- \
      "/proc/self/fd/${requirements_fd}" 2>/dev/null)" ||
    ! visible="$(LC_ALL=C /usr/bin/stat -Lc \
      $'%d\t%i\t%u\t%g\t%a\t%h\t%s\t%y\t%z\t%F' -- \
      "$requirements_file" 2>/dev/null)" ||
    [ "$final" != "$metadata" ] || [ "$visible" != "$metadata" ]; then
    exec {requirements_fd}<&-
    return 1
  fi
  exec {requirements_fd}<&-
  REQUIREMENTS_READ_BASE64="$encoded"
  REQUIREMENTS_READ_IDENTITY="$metadata"
}

capture_requirements_snapshot() {
  read_requirements_source || return 1
  requirements_snapshot_base64="$REQUIREMENTS_READ_BASE64"
  requirements_source_identity="$REQUIREMENTS_READ_IDENTITY"
  REQUIREMENTS_READ_BASE64=""
  REQUIREMENTS_READ_IDENTITY=""
}

emit_requirements_snapshot() {
  printf '%s' "$requirements_snapshot_base64" | /usr/bin/base64 --decode
}

validate_requirements_snapshot() {
  bounded_clean_python "$python_bin" -I -B "$verifier" \
    validate-lock <(emit_requirements_snapshot)
}

require_unchanged_requirements_source() {
  if ! read_requirements_source ||
    [ "$REQUIREMENTS_READ_IDENTITY" != "$requirements_source_identity" ] ||
    [ "$REQUIREMENTS_READ_BASE64" != "$requirements_snapshot_base64" ]; then
    REQUIREMENTS_READ_BASE64=""
    REQUIREMENTS_READ_IDENTITY=""
    printf '%s\n' \
      'requirements hash lock changed during dependency setup' >&2
    return 1
  fi
  REQUIREMENTS_READ_BASE64=""
  REQUIREMENTS_READ_IDENTITY=""
}

select_venv_python() {
  if [ -x "${venv_dir}/bin/python" ]; then
    printf '%s' "${venv_dir}/bin/python"
  elif [ -x "${venv_dir}/Scripts/python.exe" ]; then
    printf '%s' "${venv_dir}/Scripts/python.exe"
  else
    return 1
  fi
}

current_uid="$(/usr/bin/id -u)"
current_gid="$(/usr/bin/id -g)"
venv_parent="$(/usr/bin/dirname -- "$venv_dir")"

dependency_ancestor_snapshot() {
  local managed_path current metadata device inode owner group mode file_type

  for managed_path in \
    "$python_bin" "$venv_dir" "$requirements_file" "$verifier"; do
    current="$(/usr/bin/dirname -- "$managed_path")"
    while :; do
      [ ! -L "$current" ] || return 1
      if [ -e "$current" ]; then
        metadata="$(LC_ALL=C /usr/bin/stat -c '%d:%i:%u:%g:%a:%F' -- \
          "$current" 2>/dev/null)" || return 1
        IFS=: read -r device inode owner group mode file_type \
          <<< "$metadata"
        [[ "$device" =~ ^[0-9]+$ ]] && [[ "$inode" =~ ^[0-9]+$ ]] &&
          [[ "$owner" =~ ^[0-9]+$ ]] && [[ "$group" =~ ^[0-9]+$ ]] ||
          return 1
        [ "$file_type" = directory ] || return 1
        if [ "$testing_mode" = "0" ]; then
          case "$owner" in
            0|"$current_uid") ;;
            *) return 1 ;;
          esac
          [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
          (( (8#$mode & 8#022) == 0 )) || return 1
        fi
      else
        metadata=missing
      fi
      printf '%s\t%s\n' "$current" "$metadata"
      [ "$current" != / ] || break
      current="$(/usr/bin/dirname -- "$current")"
    done
  done
}

capture_dependency_ancestor_snapshot() {
  local output_name="$1" snapshot

  if ! snapshot="$(dependency_ancestor_snapshot)"; then
    printf '%s\n' \
      'dependency management paths have an unsafe ancestor contract' >&2
    return 1
  fi
  printf -v "$output_name" '%s' "$snapshot"
}

require_unchanged_dependency_ancestors() {
  local expected="$1" current

  if ! current="$(dependency_ancestor_snapshot)" ||
    [ "$current" != "$expected" ]; then
    printf '%s\n' \
      'dependency management ancestor contract changed during setup' >&2
    return 1
  fi
}

managed_directory_is_safe() {
  local path="$1"
  local metadata
  [ ! -L "$path" ] && [ -d "$path" ] || return 1
  metadata="$(LC_ALL=C /usr/bin/stat -Lc '%u:%g:%a:%F' -- "$path" 2>/dev/null)" ||
    return 1
  [ "$metadata" = "${current_uid}:${current_gid}:700:directory" ]
}

verify_with_approved_base() {
  bounded_clean_python "$python_bin" -I -B "$verifier" \
    verify-installed <(emit_requirements_snapshot) "$venv_dir" \
    --base-python "$python_bin" \
    --expected-uid "$current_uid" \
    --expected-gid "$current_gid"
}

audit_managed_candidate() {
  local candidate="$1"
  local verifier_python="$python_bin"

  if [ "$testing_mode" = "1" ]; then
    verifier_python="$(select_venv_python)" || return 1
  fi
  bounded_clean_python "$verifier_python" -I -B "$verifier" \
    audit-tree "$candidate" \
    --base-python "$python_bin" \
    --expected-uid "$current_uid" \
    --expected-gid "$current_gid" >/dev/null
}

verify_candidate_contract() {
  local candidate_python="$1"

  if [ "$testing_mode" = "1" ]; then
    bounded_clean_python "$candidate_python" -I -B "$verifier" \
      verify-installed <(emit_requirements_snapshot) "$venv_dir" \
      --base-python "$python_bin" \
      --expected-uid "$current_uid" \
      --expected-gid "$current_gid"
  else
    verify_with_approved_base
  fi
}

read_stamp() {
  local path="$1"
  local metadata size
  [ -e "$path" ] || return 1
  [ ! -L "$path" ] && [ -f "$path" ] || return 1
  metadata="$(LC_ALL=C /usr/bin/stat -Lc '%u:%g:%a:%h:%F' -- "$path" 2>/dev/null)" ||
    return 1
  [ "$metadata" = "${current_uid}:${current_gid}:600:1:regular file" ] ||
    return 1
  size="$(/usr/bin/stat -Lc '%s' -- "$path" 2>/dev/null)" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le 4096 ] || return 1
  /bin/cat -- "$path"
}

remove_managed_tree() {
  local candidate="$1"
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || return 1
  case "$candidate" in
    "${venv_dir}.previous."*|"${venv_dir}.failed."*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$candidate" ] && [ -d "$candidate" ] && [ -O "$candidate" ] ||
    return 1
  audit_managed_candidate "$candidate" || return 1
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || return 1
  /bin/rm -rf --one-file-system -- "$candidate" || return 1
  require_unchanged_dependency_ancestors "$ancestor_snapshot"
}

previous_venv=""
failed_venv=""
ancestor_snapshot=""
committed=0
transaction_started=0
restore_on_exit() {
  local status=$? rollback_snapshot
  if [ "$transaction_started" -eq 1 ] && [ "$committed" -eq 0 ] &&
    { [ -z "$previous_venv" ] || [ -e "$previous_venv" ] ||
      [ -L "$previous_venv" ]; }; then
    if ! rollback_snapshot="$(dependency_ancestor_snapshot)" ||
      [ "$rollback_snapshot" != "$ancestor_snapshot" ]; then
      exit "$status"
    fi
    if [ -e "$venv_dir" ] || [ -L "$venv_dir" ]; then
      failed_venv="${venv_dir}.failed.$$"
      if [ ! -e "$failed_venv" ] && [ ! -L "$failed_venv" ]; then
        /bin/mv -- "$venv_dir" "$failed_venv" 2>/dev/null || true
        if ! rollback_snapshot="$(dependency_ancestor_snapshot)" ||
          [ "$rollback_snapshot" != "$ancestor_snapshot" ]; then
          exit "$status"
        fi
      fi
    fi
    if [ -n "$previous_venv" ] && [ -d "$previous_venv" ] &&
      [ ! -e "$venv_dir" ]; then
      /bin/mv -- "$previous_venv" "$venv_dir" 2>/dev/null || true
      if ! rollback_snapshot="$(dependency_ancestor_snapshot)" ||
        [ "$rollback_snapshot" != "$ancestor_snapshot" ]; then
        exit "$status"
      fi
    fi
    if [ -n "$failed_venv" ] && [ -d "$failed_venv" ]; then
      remove_managed_tree "$failed_venv" 2>/dev/null || true
    fi
  fi
  exit "$status"
}
trap restore_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! { [ ! -L "$requirements_file" ] && [ -f "$requirements_file" ] &&
  [ -r "$requirements_file" ]; }; then
    printf '%s\n' 'requirements hash lock is not a readable regular file' >&2
    exit 66
fi
if ! { [ ! -L "$verifier" ] && [ -f "$verifier" ] &&
  [ -r "$verifier" ]; }; then
  printf '%s\n' 'dependency contract verifier is not a readable regular file' >&2
  exit 66
fi
[ -x /usr/bin/timeout ] || {
  printf '%s\n' 'timeout is required for dependency setup' >&2
  exit 69
}
[ -x /usr/bin/base64 ] || {
  printf '%s\n' 'base64 is required for dependency setup' >&2
  exit 69
}

capture_dependency_ancestor_snapshot ancestor_snapshot || exit 73

if bounded_clean_python "$python_bin" -I -B "$verifier" \
  validate-runtime >/dev/null; then
  runtime_status=0
else
  runtime_status=$?
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
[ "$runtime_status" -eq 0 ] || exit 65
capture_requirements_snapshot || {
  printf '%s\n' 'requirements hash lock could not be snapshotted safely' >&2
  exit 66
}
readonly requirements_snapshot_base64 requirements_source_identity
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73

if lock_sha="$(validate_requirements_snapshot)"; then
  lock_status=0
else
  lock_status=$?
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
require_unchanged_requirements_source || exit 73
[ "$lock_status" -eq 0 ] || exit 65
[[ "$lock_sha" =~ ^[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'dependency lock verifier returned an invalid digest' >&2
  exit 65
}

require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
if [ ! -e "$venv_parent" ] && [ ! -L "$venv_parent" ]; then
  /bin/mkdir -p -- "$venv_parent"
  /bin/chmod 700 -- "$venv_parent"
fi
capture_dependency_ancestor_snapshot ancestor_snapshot || exit 73
if [ "$testing_mode" = "1" ]; then
  if ! { [ ! -L "$venv_parent" ] && [ -d "$venv_parent" ] &&
    [ -O "$venv_parent" ]; }; then
      printf '%s\n' 'venv parent is not a safe test-owned directory' >&2
      exit 73
  fi
else
  managed_directory_is_safe "$venv_parent" || {
    printf '%s\n' 'venv parent must have the approved owner and mode 0700' >&2
    exit 73
  }
fi
if [ -e "$venv_dir" ] || [ -L "$venv_dir" ]; then
  if [ "$testing_mode" = "1" ]; then
    if ! { [ ! -L "$venv_dir" ] && [ -d "$venv_dir" ] &&
      [ -O "$venv_dir" ]; }; then
      printf '%s\n' 'existing test venv path is unsafe' >&2
      exit 73
    fi
  else
    managed_directory_is_safe "$venv_dir" || {
      printf '%s\n' 'existing venv must have the approved owner and mode 0700' >&2
      exit 73
    }
  fi
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73

stamp_file="${venv_dir}/.cf-agent-wechat-requirements"
venv_python="$(select_venv_python 2>/dev/null || true)"
if [ -n "$venv_python" ]; then
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  expected_contract="$(verify_candidate_contract "$venv_python" \
    2>/dev/null || true)"
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  current_contract="$(read_stamp "$stamp_file" 2>/dev/null || true)"
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  require_unchanged_requirements_source || exit 73
  if [ -n "$expected_contract" ] &&
    [ "$expected_contract" = "$current_contract" ]; then
    require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
    require_unchanged_requirements_source || exit 73
    committed=1
    printf '%s\n' "$venv_python"
    exit 0
  fi
fi

if [ -e "$venv_dir" ] || [ -L "$venv_dir" ]; then
  if ! audit_managed_candidate "$venv_dir"; then
    printf '%s\n' \
      'existing venv tree could not be proven structurally safe; it was left in place and must be isolated manually' >&2
    exit 73
  fi
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  previous_venv="${venv_dir}.previous.$$"
  [ ! -e "$previous_venv" ] && [ ! -L "$previous_venv" ] || exit 73
  transaction_started=1
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  /bin/mv -- "$venv_dir" "$previous_venv"
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
else
  transaction_started=1
fi

printf '%s\n' 'Creating isolated QR dependency environment...' >&2
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
if /usr/bin/timeout --signal=TERM --kill-after=2s "${venv_timeout}s" \
  /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
    PYTHONNOUSERSITE=1 \
    "$python_bin" -I -B -m venv "$venv_dir" >&2; then
  venv_status=0
else
  venv_status=$?
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
if [ "$venv_status" -ne 0 ]; then
  printf '%s\n' 'could not create a working Python venv' >&2
  exit 70
fi
/bin/chmod 700 -- "$venv_dir"
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
venv_python="$(select_venv_python)" || {
  printf '%s\n' 'new venv has no Python interpreter' >&2
  exit 70
}
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
if /usr/bin/timeout --signal=TERM --kill-after=2s 30s \
  /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
    PYTHONNOUSERSITE=1 \
    "$venv_python" -I -B -m pip --version >/dev/null 2>&1; then
  pip_probe_status=0
else
  pip_probe_status=$?
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
if [ "$pip_probe_status" -ne 0 ]; then
  printf '%s\n' 'new venv has no working pip/ensurepip' >&2
  exit 70
fi

printf '%s\n' 'Installing SHA-256 locked QR dependencies...' >&2
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
require_unchanged_requirements_source || exit 73
if /usr/bin/timeout --signal=TERM --kill-after=5s "${install_timeout}s" \
  /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
    PYTHONNOUSERSITE=1 PIP_NO_INPUT=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_CONFIG_FILE=/dev/null \
    PIP_NO_CACHE_DIR=1 \
    "$venv_python" -I -B -m pip install \
      --require-hashes \
      --only-binary=:all: \
      --no-compile \
      --no-input \
      --disable-pip-version-check \
      --no-cache-dir \
      --retries "$retries" \
      --timeout "$network_timeout" \
      --requirement <(emit_requirements_snapshot) >&2; then
  pip_status=0
else
  pip_status=$?
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
require_unchanged_requirements_source || exit 73
case "$pip_status" in
  0) ;;
  124|137)
    printf '%s\n' 'dependency installation exceeded its hard timeout' >&2
    exit 75
    ;;
  *)
    printf '%s\n' 'dependency installation failed its hash/download contract' >&2
    exit 65
    ;;
esac
if post_install_lock_sha="$(validate_requirements_snapshot)"; then
  post_install_lock_status=0
else
  post_install_lock_status=$?
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
require_unchanged_requirements_source || exit 73
if [ "$post_install_lock_status" -ne 0 ] ||
  [ "$post_install_lock_sha" != "$lock_sha" ]; then
  printf '%s\n' \
    'dependency lock snapshot changed during dependency setup' >&2
  exit 65
fi

if [ "$testing_mode" = "0" ]; then
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  if /usr/bin/timeout --signal=TERM --kill-after=2s 60s \
    /usr/bin/env -i \
      HOME=/nonexistent \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
      PYTHONNOUSERSITE=1 PIP_NO_INPUT=1 \
      PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_CONFIG_FILE=/dev/null \
      PIP_NO_CACHE_DIR=1 \
      "$venv_python" -I -B -m pip uninstall --yes \
        pip setuptools wheel >&2; then
    uninstall_status=0
  else
    uninstall_status=$?
  fi
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  require_unchanged_requirements_source || exit 73
  if [ "$uninstall_status" -ne 0 ]; then
    printf '%s\n' 'could not remove dependency build tools from the venv' >&2
    exit 65
  fi
fi

require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
require_unchanged_requirements_source || exit 73
if expected_contract="$(verify_candidate_contract "$venv_python")"; then
  verify_status=0
else
  verify_status=$?
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
require_unchanged_requirements_source || exit 73
[ "$verify_status" -eq 0 ] || exit 65
case "$expected_contract" in
  *"requirements_sha256=${lock_sha}"*) ;;
  *)
    printf '%s\n' 'installed dependency contract has the wrong lock digest' >&2
    exit 65
    ;;
esac
if [ "$testing_mode" = "0" ]; then
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  if bounded_clean_python "$venv_python" -I -B -c \
    'import PIL, qrcode, websocket' >/dev/null 2>&1; then
    import_status=0
  else
    import_status=$?
  fi
  require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
  if [ "$import_status" -ne 0 ]; then
    printf '%s\n' \
      'installed QR dependencies failed their isolated import check' >&2
    exit 65
  fi
fi

temporary_stamp="${stamp_file}.tmp.$$"
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
require_unchanged_requirements_source || exit 73
[ ! -e "$temporary_stamp" ] && [ ! -L "$temporary_stamp" ] || exit 73
umask 077
printf '%s\n' "$expected_contract" > "$temporary_stamp"
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
/bin/chmod 600 -- "$temporary_stamp"
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
/bin/mv -- "$temporary_stamp" "$stamp_file"
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
require_unchanged_requirements_source || exit 73

committed=1
if [ -n "$previous_venv" ]; then
  if ! remove_managed_tree "$previous_venv"; then
    printf '%s\n' \
      'new dependency environment is committed, but the restricted previous environment could not be removed; isolate the previous path manually' >&2
    exit 73
  fi
fi
require_unchanged_dependency_ancestors "$ancestor_snapshot" || exit 73
printf '%s\n' "$venv_python"
