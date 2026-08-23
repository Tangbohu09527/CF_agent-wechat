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

path_ancestors_have_no_symlinks() {
  local path="$1"
  local current

  current="$(/usr/bin/dirname -- "$path")"
  while [ "$current" != / ]; do
    if [ -L "$current" ]; then
      return 1
    fi
    if [ -e "$current" ] && [ ! -d "$current" ]; then
      return 1
    fi
    current="$(/usr/bin/dirname -- "$current")"
  done
}

managed_directory_is_safe() {
  local path="$1"
  local metadata
  [ ! -L "$path" ] && [ -d "$path" ] || return 1
  metadata="$(/usr/bin/stat -Lc '%u:%g:%a:%F' -- "$path" 2>/dev/null)" ||
    return 1
  [ "$metadata" = "${current_uid}:${current_gid}:700:directory" ]
}

verify_with_approved_base() {
  bounded_clean_python "$python_bin" -I -B "$verifier" \
    verify-installed "$requirements_file" "$venv_dir" \
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
      verify-installed "$requirements_file" "$venv_dir" \
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
  metadata="$(/usr/bin/stat -Lc '%u:%g:%a:%h:%F' -- "$path" 2>/dev/null)" ||
    return 1
  [ "$metadata" = "${current_uid}:${current_gid}:600:1:regular file" ] ||
    return 1
  size="$(/usr/bin/stat -Lc '%s' -- "$path" 2>/dev/null)" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le 4096 ] || return 1
  /bin/cat -- "$path"
}

remove_managed_tree() {
  local candidate="$1"
  case "$candidate" in
    "${venv_dir}.previous."*|"${venv_dir}.failed."*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$candidate" ] && [ -d "$candidate" ] && [ -O "$candidate" ] ||
    return 1
  audit_managed_candidate "$candidate" || return 1
  /bin/rm -rf --one-file-system -- "$candidate"
}

previous_venv=""
failed_venv=""
committed=0
transaction_started=0
restore_on_exit() {
  local status=$?
  if [ "$transaction_started" -eq 1 ] && [ "$committed" -eq 0 ] &&
    { [ -z "$previous_venv" ] || [ -e "$previous_venv" ] ||
      [ -L "$previous_venv" ]; }; then
    if [ -e "$venv_dir" ] || [ -L "$venv_dir" ]; then
      failed_venv="${venv_dir}.failed.$$"
      if [ ! -e "$failed_venv" ] && [ ! -L "$failed_venv" ]; then
        /bin/mv -- "$venv_dir" "$failed_venv" 2>/dev/null || true
      fi
    fi
    if [ -n "$previous_venv" ] && [ -d "$previous_venv" ] &&
      [ ! -e "$venv_dir" ]; then
      /bin/mv -- "$previous_venv" "$venv_dir" 2>/dev/null || true
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

[ ! -L "$requirements_file" ] && [ -f "$requirements_file" ] &&
  [ -r "$requirements_file" ] || {
    printf '%s\n' 'requirements hash lock is not a readable regular file' >&2
    exit 66
  }
[ ! -L "$verifier" ] && [ -f "$verifier" ] && [ -r "$verifier" ] || {
  printf '%s\n' 'dependency contract verifier is not a readable regular file' >&2
  exit 66
}
[ -x /usr/bin/timeout ] || {
  printf '%s\n' 'timeout is required for dependency setup' >&2
  exit 69
}

for managed_path in \
  "$python_bin" "$venv_dir" "$requirements_file" "$verifier"; do
  path_ancestors_have_no_symlinks "$managed_path" || {
    printf '%s\n' \
      'dependency management paths must not contain symbolic link ancestors' >&2
    exit 73
  }
done

bounded_clean_python "$python_bin" -I -B "$verifier" \
  validate-runtime >/dev/null || exit 65
lock_sha="$(bounded_clean_python "$python_bin" -I -B "$verifier" \
  validate-lock "$requirements_file")" || exit 65
[[ "$lock_sha" =~ ^[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'dependency lock verifier returned an invalid digest' >&2
  exit 65
}

if [ ! -e "$venv_parent" ] && [ ! -L "$venv_parent" ]; then
  /bin/mkdir -p -- "$venv_parent"
  /bin/chmod 700 -- "$venv_parent"
fi
path_ancestors_have_no_symlinks "$venv_dir" || {
  printf '%s\n' \
    'venv path gained a symbolic link ancestor during preparation' >&2
  exit 73
}
if [ "$testing_mode" = "1" ]; then
  [ ! -L "$venv_parent" ] && [ -d "$venv_parent" ] &&
    [ -O "$venv_parent" ] || {
      printf '%s\n' 'venv parent is not a safe test-owned directory' >&2
      exit 73
    }
else
  managed_directory_is_safe "$venv_parent" || {
    printf '%s\n' 'venv parent must have the approved owner and mode 0700' >&2
    exit 73
  }
fi
if [ -e "$venv_dir" ] || [ -L "$venv_dir" ]; then
  if [ "$testing_mode" = "1" ]; then
    [ ! -L "$venv_dir" ] && [ -d "$venv_dir" ] && [ -O "$venv_dir" ] || {
      printf '%s\n' 'existing test venv path is unsafe' >&2
      exit 73
    }
  else
    managed_directory_is_safe "$venv_dir" || {
      printf '%s\n' 'existing venv must have the approved owner and mode 0700' >&2
      exit 73
    }
  fi
fi

stamp_file="${venv_dir}/.cf-agent-wechat-requirements"
venv_python="$(select_venv_python 2>/dev/null || true)"
if [ -n "$venv_python" ]; then
  expected_contract="$(verify_candidate_contract "$venv_python" \
    2>/dev/null || true)"
  current_contract="$(read_stamp "$stamp_file" 2>/dev/null || true)"
  if [ -n "$expected_contract" ] &&
    [ "$expected_contract" = "$current_contract" ]; then
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
  previous_venv="${venv_dir}.previous.$$"
  [ ! -e "$previous_venv" ] && [ ! -L "$previous_venv" ] || exit 73
  transaction_started=1
  /bin/mv -- "$venv_dir" "$previous_venv"
else
  transaction_started=1
fi

printf 'Creating isolated QR dependency environment: %s\n' "$venv_dir" >&2
/usr/bin/timeout --signal=TERM --kill-after=2s "${venv_timeout}s" \
  /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
    PYTHONNOUSERSITE=1 \
    "$python_bin" -I -B -m venv "$venv_dir" >&2 || {
      printf '%s\n' 'could not create a working Python venv' >&2
      exit 70
    }
/bin/chmod 700 -- "$venv_dir"
venv_python="$(select_venv_python)" || {
  printf '%s\n' 'new venv has no Python interpreter' >&2
  exit 70
}
/usr/bin/timeout --signal=TERM --kill-after=2s 30s \
  /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
    PYTHONNOUSERSITE=1 \
    "$venv_python" -I -B -m pip --version >/dev/null 2>&1 || {
      printf '%s\n' 'new venv has no working pip/ensurepip' >&2
      exit 70
    }

printf '%s\n' 'Installing SHA-256 locked QR dependencies...' >&2
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
      --requirement "$requirements_file" >&2; then
  pip_status=0
else
  pip_status=$?
fi
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

if [ "$testing_mode" = "0" ]; then
  if ! /usr/bin/timeout --signal=TERM --kill-after=2s 60s \
    /usr/bin/env -i \
      HOME=/nonexistent \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
      PYTHONNOUSERSITE=1 PIP_NO_INPUT=1 \
      PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_CONFIG_FILE=/dev/null \
      PIP_NO_CACHE_DIR=1 \
      "$venv_python" -I -B -m pip uninstall --yes \
        pip setuptools wheel >&2; then
    printf '%s\n' 'could not remove dependency build tools from the venv' >&2
    exit 65
  fi
fi

expected_contract="$(verify_candidate_contract "$venv_python")" || exit 65
case "$expected_contract" in
  *"requirements_sha256=${lock_sha}"*) ;;
  *)
    printf '%s\n' 'installed dependency contract has the wrong lock digest' >&2
    exit 65
    ;;
esac
if [ "$testing_mode" = "0" ] &&
  ! bounded_clean_python "$venv_python" -I -B -c \
    'import PIL, qrcode, websocket' >/dev/null 2>&1; then
  printf '%s\n' \
    'installed QR dependencies failed their isolated import check' >&2
  exit 65
fi

temporary_stamp="${stamp_file}.tmp.$$"
[ ! -e "$temporary_stamp" ] && [ ! -L "$temporary_stamp" ] || exit 73
umask 077
printf '%s\n' "$expected_contract" > "$temporary_stamp"
/bin/chmod 600 -- "$temporary_stamp"
/bin/mv -- "$temporary_stamp" "$stamp_file"

committed=1
if [ -n "$previous_venv" ]; then
  if ! remove_managed_tree "$previous_venv"; then
    printf '%s\n' \
      'new dependency environment is committed, but the restricted previous environment could not be removed; isolate the previous path manually' >&2
    exit 73
  fi
fi
printf '%s\n' "$venv_python"
