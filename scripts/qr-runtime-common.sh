#!/bin/bash -p

set +x

if [ "${CF_AGENT_WECHAT_TESTING:-0}" = "1" ]; then
  RUNTIME_SCRIPTS_DIR="$(
    CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
  )"
else
  if ! _runtime_scripts_dir_declaration="$(
    declare -p _CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR 2>/dev/null
  )"; then
    printf '%s\n' 'Production management scripts directory is unavailable.' >&2
    return 1
  fi
  case "$_runtime_scripts_dir_declaration" in
    'declare -r '*) ;;
    *)
      printf '%s\n' 'Production management scripts directory is not immutable.' >&2
      return 1
      ;;
  esac
  RUNTIME_SCRIPTS_DIR="$_CF_AGENT_WECHAT_INTERNAL_SCRIPTS_DIR"
  readonly RUNTIME_SCRIPTS_DIR
  unset _runtime_scripts_dir_declaration
fi
RUNTIME_REPO_ROOT="$(CDPATH='' cd -- "${RUNTIME_SCRIPTS_DIR}/.." && pwd -P)"

AGENT_COMPOSE_FILE="${CF_AGENT_WECHAT_COMPOSE_FILE:-${RUNTIME_REPO_ROOT}/docker/compose.cfserver.yaml}"
AGENT_ENV_FILE="${CF_AGENT_WECHAT_ENV_FILE:-${RUNTIME_REPO_ROOT}/docker/.env}"
STORAGE_ROOT="${CF_AGENT_WECHAT_STORAGE_ROOT:-/srv/storage/cf-agent-wechat}"
RUNTIME_ROOT="${CF_AGENT_WECHAT_RUNTIME_ROOT:-${STORAGE_ROOT}/runtime}"
ARCHIVE_ROOT="${CF_AGENT_WECHAT_ARCHIVE_ROOT:-${STORAGE_ROOT}/session-archive}"
LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"
LEGACY_WECHAT_HOME_ROOT="${STORAGE_ROOT}/wechat-home"
RUNTIME_LOCK_FILE="${CF_AGENT_WECHAT_LOCK_FILE:-/run/lock/cf-agent-wechat-qr-runtime.lock}"
GATEWAY_PROJECT_DIR="${CF_AGENT_GATEWAY_PROJECT_DIR:-/opt/cf-agent-gateway}"
GATEWAY_COMPOSE_FILE="${CF_AGENT_GATEWAY_COMPOSE_FILE:-${GATEWAY_PROJECT_DIR}/docker-compose.prod.yml}"
GATEWAY_ENV_FILE="${CF_AGENT_GATEWAY_ENV_FILE:-${GATEWAY_PROJECT_DIR}/.env}"
GATEWAY_HEARTBEAT_COMMAND="${GATEWAY_PROJECT_DIR}/deploy/check-wechat-worker-heartbeat"
GATEWAY_RELEASE_GATE_COMMAND="${GATEWAY_PROJECT_DIR}/deploy/wechat-runtime-release-gate"
GATEWAY_CONTRACT_FILE="${GATEWAY_PROJECT_DIR}/deploy/wechat-runtime-contract.json"
GATEWAY_PROJECT_NAME="cf-agent-gateway"
GATEWAY_HEARTBEAT_MAX_AGE="30"
GATEWAY_RUNTIME_COMMAND_TIMEOUT="10"
GATEWAY_PRODUCER_REPOSITORY="Tangbohu09527/CF_agent-gateway"
GATEWAY_COMPATIBLE_COMMIT=""
GATEWAY_CHECKER_SHA256=""
GATEWAY_RELEASE_GATE_SHA256=""
GATEWAY_CONTRACT_VERIFIER="${RUNTIME_SCRIPTS_DIR}/verify_gateway_contract.py"
RUNTIME_TREE_SCANNER="${RUNTIME_SCRIPTS_DIR}/scan_runtime_tree.py"
ARCHIVE_RUNTIME_TOOL="${RUNTIME_SCRIPTS_DIR}/archive-runtime.py"
MANAGEMENT_ENV_PARSER="${RUNTIME_SCRIPTS_DIR}/parse_management_env.py"
MANAGEMENT_SOURCE_SECRET_VERIFIER="${RUNTIME_SCRIPTS_DIR}/verify_management_source_secrets.py"
IFS= read -r -d '' GATEWAY_VERIFIER_SNAPSHOT_LOADER <<'PYTHON' || :
import hashlib
import hmac
import os
import stat
import sys

MAX_SOURCE_BYTES = 1024 * 1024
FAILURE = "Gateway verifier snapshot validation failed."


def fail():
    print(FAILURE, file=sys.stderr)
    raise SystemExit(126)


def metadata_signature(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


try:
    mode, path, expected_digest, approved_uid_raw = sys.argv[1:5]
    script_arguments = sys.argv[5:]
    approved_uid = int(approved_uid_raw)
    if (
        mode not in {"digest", "execute"}
        or not os.path.isabs(path)
        or approved_uid < 0
        or not hasattr(os, "O_NOFOLLOW")
    ):
        fail()

    before = os.lstat(path)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_IMODE(before.st_mode) != 0o755
        or before.st_uid not in {0, approved_uid}
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > MAX_SOURCE_BYTES
    ):
        fail()

    if (
        mode == "execute"
        and os.environ.get("CF_AGENT_WECHAT_TESTING") == "1"
    ):
        replacement = os.environ.get(
            "CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT",
            "",
        )
        if replacement:
            testing_root = os.environ.get("CF_AGENT_WECHAT_TEST_ROOT", "")
            if (
                os.getuid() == 0
                or os.geteuid() != os.getuid()
                or not os.path.isabs(testing_root)
                or os.path.commonpath((testing_root, path)) != testing_root
                or os.path.commonpath((testing_root, replacement)) != testing_root
            ):
                fail()
            os.replace(replacement, path)

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if metadata_signature(opened) != metadata_signature(before):
            fail()
        chunks = []
        total = 0
        while True:
            chunk = os.read(
                descriptor,
                min(65536, MAX_SOURCE_BYTES + 1 - total),
            )
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_SOURCE_BYTES:
                fail()
            chunks.append(chunk)
        final = os.fstat(descriptor)
    finally:
        os.close(descriptor)

    visible = os.lstat(path)
    if (
        metadata_signature(final) != metadata_signature(opened)
        or metadata_signature(visible) != metadata_signature(before)
    ):
        fail()
    source = b"".join(chunks)
    digest = hashlib.sha256(source).hexdigest()

    if mode == "digest":
        if expected_digest != "-":
            fail()
        sys.stdout.write(digest)
        raise SystemExit(0)
    if (
        len(expected_digest) != 64
        or any(character not in "0123456789abcdef" for character in expected_digest)
        or not hmac.compare_digest(digest, expected_digest)
    ):
        fail()
    code = compile(source, path, "exec")
except (OSError, OverflowError, SyntaxError, TypeError, ValueError):
    fail()

sys.argv = [path, *script_arguments]
namespace = {
    "__name__": "__main__",
    "__file__": path,
    "__package__": None,
    "__cached__": None,
    "__spec__": None,
}
exec(code, namespace, namespace)
PYTHON
readonly GATEWAY_VERIFIER_SNAPSHOT_LOADER
IFS= read -r -d '' GATEWAY_CHECKER_SNAPSHOT_LOADER <<'PYTHON' || :
import fcntl
import hashlib
import hmac
import json
import os
import selectors
import signal
import stat
import subprocess
import sys
import time

MAX_SOURCE_BYTES = 1024 * 1024


def fail():
    raise SystemExit(126)


def metadata_signature(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


descriptor = -1
directory_descriptor = -1
snapshot_descriptor = -1
executable_descriptor = -1
child = None
try:
    (
        mode,
        path,
        working_directory,
        expected_digest,
        approved_uid_raw,
        execution_timeout_raw,
        executable_kind,
        input_transport,
    ) = (
        sys.argv[1:9]
    )
    script_arguments = sys.argv[9:]
    approved_uid = int(approved_uid_raw)
    execution_timeout = int(execution_timeout_raw)
    if (
        mode not in {"digest", "execute"}
        or not os.path.isabs(path)
        or not os.path.isabs(working_directory)
        or approved_uid < 0
        or execution_timeout <= 0
        or executable_kind not in {"checker", "gate"}
        or input_transport not in {"none", "stdin-json"}
        or (mode == "digest" and input_transport != "none")
        or not hasattr(os, "O_NOFOLLOW")
        or not hasattr(os, "memfd_create")
        or not hasattr(fcntl, "F_ADD_SEALS")
        or not hasattr(fcntl, "F_SEAL_SEAL")
        or not hasattr(fcntl, "F_SEAL_SHRINK")
        or not hasattr(fcntl, "F_SEAL_GROW")
        or not hasattr(fcntl, "F_SEAL_WRITE")
    ):
        fail()

    before = os.lstat(path)
    directory_before = os.lstat(working_directory)
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_IMODE(before.st_mode) != 0o755
        or before.st_uid not in {0, approved_uid}
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > MAX_SOURCE_BYTES
    ):
        fail()
    if (
        not stat.S_ISDIR(directory_before.st_mode)
        or directory_before.st_uid not in {0, approved_uid}
        or stat.S_IMODE(directory_before.st_mode) & 0o022
    ):
        fail()

    directory_flags = (
        os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    )
    directory_descriptor = os.open(working_directory, directory_flags)
    directory_opened = os.fstat(directory_descriptor)
    directory_visible = os.lstat(working_directory)
    if (
        metadata_signature(directory_opened)
        != metadata_signature(directory_before)
        or metadata_signature(directory_visible)
        != metadata_signature(directory_before)
    ):
        fail()

    if (
        mode == "execute"
        and os.environ.get("CF_AGENT_WECHAT_TESTING") == "1"
    ):
        replacement_variable = {
            "checker": "CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT",
            "gate": "CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT",
        }[executable_kind]
        replacement = os.environ.get(replacement_variable, "")
        if replacement:
            testing_root = os.environ.get("CF_AGENT_WECHAT_TEST_ROOT", "")
            if (
                os.getuid() == 0
                or os.geteuid() != os.getuid()
                or not os.path.isabs(testing_root)
                or os.path.commonpath((testing_root, path)) != testing_root
                or os.path.commonpath((testing_root, replacement)) != testing_root
            ):
                fail()
            os.replace(replacement, path)

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    opened = os.fstat(descriptor)
    if metadata_signature(opened) != metadata_signature(before):
        fail()
    chunks = []
    total = 0
    while True:
        chunk = os.read(
            descriptor,
            min(65536, MAX_SOURCE_BYTES + 1 - total),
        )
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_SOURCE_BYTES:
            fail()
        chunks.append(chunk)
    final = os.fstat(descriptor)
    visible = os.lstat(path)
    if (
        metadata_signature(final) != metadata_signature(opened)
        or metadata_signature(visible) != metadata_signature(before)
    ):
        fail()
    source = b"".join(chunks)
    digest = hashlib.sha256(source).hexdigest()

    if mode == "digest":
        if expected_digest != "-":
            fail()
        sys.stdout.write(digest)
        raise SystemExit(0)
    if (
        len(expected_digest) != 64
        or any(character not in "0123456789abcdef" for character in expected_digest)
        or not hmac.compare_digest(digest, expected_digest)
    ):
        fail()

    request_data = b""
    if input_transport == "stdin-json":
        request_data = sys.stdin.buffer.read(4097)
        if not request_data or len(request_data) > 4096:
            fail()
        try:
            request_payload = json.loads(request_data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            fail()
        if not isinstance(request_payload, dict):
            fail()

    snapshot_descriptor = os.memfd_create(
        f"cf-agent-wechat-gateway-{executable_kind}",
        os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING,
    )
    offset = 0
    while offset < len(source):
        written = os.write(snapshot_descriptor, source[offset:])
        if written <= 0:
            fail()
        offset += written
    os.fchmod(snapshot_descriptor, 0o700)
    seals = (
        fcntl.F_SEAL_SEAL
        | fcntl.F_SEAL_SHRINK
        | fcntl.F_SEAL_GROW
        | fcntl.F_SEAL_WRITE
    )
    fcntl.fcntl(snapshot_descriptor, fcntl.F_ADD_SEALS, seals)
    executable_descriptor = os.open(
        f"/proc/self/fd/{snapshot_descriptor}",
        os.O_RDONLY | os.O_CLOEXEC,
    )
    os.close(snapshot_descriptor)
    snapshot_descriptor = -1
    os.set_inheritable(executable_descriptor, True)
    os.fchdir(directory_descriptor)
    executable_path = f"/proc/self/fd/{executable_descriptor}"
    child = subprocess.Popen(
        [path, *script_arguments],
        executable=executable_path,
        stdin=(
            subprocess.PIPE
            if input_transport == "stdin-json"
            else subprocess.DEVNULL
        ),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        close_fds=True,
        pass_fds=(executable_descriptor,),
        start_new_session=True,
        env=os.environ.copy(),
    )
    if child.stdout is None:
        fail()

    def terminate_process_group():
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass

    def forward_termination(_signum, _frame):
        terminate_process_group()
        raise SystemExit(124)

    if request_data:
        if child.stdin is None:
            fail()
        try:
            child.stdin.write(request_data)
            child.stdin.close()
        except (BrokenPipeError, OSError):
            terminate_process_group()
            raise SystemExit(1)

    signal.signal(signal.SIGTERM, forward_termination)
    signal.signal(signal.SIGINT, forward_termination)
    signal.signal(signal.SIGHUP, forward_termination)

    output_descriptor = child.stdout.fileno()
    os.set_blocking(output_descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(output_descriptor, selectors.EVENT_READ)
    deadline = time.monotonic() + execution_timeout
    saw_output = False
    timed_out = False
    pipe_closed = False
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                terminate_process_group()
                break
            events = selector.select(min(remaining, 0.1))
            if events:
                try:
                    byte = os.read(output_descriptor, 1)
                except BlockingIOError:
                    byte = None
                if byte:
                    saw_output = True
                    terminate_process_group()
                    break
                if byte == b"":
                    pipe_closed = True
            return_code = child.poll()
            if return_code is not None:
                if not pipe_closed:
                    try:
                        byte = os.read(output_descriptor, 1)
                    except BlockingIOError:
                        byte = None
                    if byte:
                        saw_output = True
                    elif byte is None:
                        terminate_process_group()
                        return_code = 1
                    else:
                        pipe_closed = True
                break
    finally:
        selector.close()
        child.stdout.close()

    if timed_out:
        raise SystemExit(124)
    if saw_output:
        raise SystemExit(125)
    if return_code != 0 or not pipe_closed:
        terminate_process_group()
        raise SystemExit(1)
    raise SystemExit(0)
except (AttributeError, OSError, OverflowError, TypeError, ValueError):
    fail()
finally:
    if child is not None and child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except (AttributeError, OSError):
            pass
        try:
            child.wait(timeout=1)
        except (AttributeError, subprocess.TimeoutExpired):
            pass
    for open_descriptor in (
        descriptor,
        directory_descriptor,
        snapshot_descriptor,
        executable_descriptor,
    ):
        if open_descriptor >= 0:
            try:
                os.close(open_descriptor)
            except OSError:
                pass
PYTHON
readonly GATEWAY_CHECKER_SNAPSHOT_LOADER

RUNTIME_INT64_MAX="9223372036854775807"
RUNTIME_UID_GID_MAX="4294967294"
RUNTIME_MAX_KIB_FOR_BYTE_CONVERSION="9007199254740991"
readonly RUNTIME_INT64_MAX RUNTIME_UID_GID_MAX
readonly RUNTIME_MAX_KIB_FOR_BYTE_CONVERSION

RUNTIME_DEFAULT_UID="${CF_AGENT_WECHAT_RUNTIME_UID:-1000}"
RUNTIME_DEFAULT_GID="${CF_AGENT_WECHAT_RUNTIME_GID:-1000}"
RUNTIME_DEFAULT_MODE="${CF_AGENT_WECHAT_RUNTIME_MODE:-700}"
RUNTIME_MANAGEMENT_GID="${CF_AGENT_WECHAT_MANAGEMENT_GID:-$(id -g)}"
MIN_FREE_BYTES="1073741824"
MIN_FREE_PERCENT="10"
MIN_FREE_INODES="1024"
TOKEN_SCAN_MAX_FILES="200000"
TOKEN_SCAN_MAX_BYTES="21474836480"
APPROVED_AGENT_IMAGE=""
APPROVED_AGENT_CONTAINER=""
APPROVED_AGENT_PROJECT=""
APPROVED_PROXY=""
APPROVED_RUST_LOG=""
AGENT_ENV_APPROVED_UID=""
AGENT_ENV_APPROVED_GID=""
AGENT_ENV_APPROVED_MODE=""
if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
  SERVER_READY_TIMEOUT="${SERVER_READY_TIMEOUT:-120}"
  WECHAT_READY_TIMEOUT="${WECHAT_READY_TIMEOUT:-120}"
  WECHAT_STABLE_SECONDS="${WECHAT_STABLE_SECONDS:-10}"
  POST_LOGIN_READY_TIMEOUT="${POST_LOGIN_READY_TIMEOUT:-120}"
  RUNTIME_POLL_INTERVAL="${RUNTIME_POLL_INTERVAL:-2}"
  DOCKER_COMMAND_TIMEOUT="${DOCKER_COMMAND_TIMEOUT:-20}"
  COMPOSE_COMMAND_TIMEOUT="${COMPOSE_COMMAND_TIMEOUT:-60}"
  WORKER_READY_TIMEOUT="${WORKER_READY_TIMEOUT:-60}"
  WORKER_STABLE_SECONDS="${WORKER_STABLE_SECONDS:-5}"
  WORKER_HEARTBEAT_TIMEOUT="${WORKER_HEARTBEAT_TIMEOUT:-10}"
  TOKEN_SCAN_TIMEOUT="${TOKEN_SCAN_TIMEOUT:-120}"
  ARCHIVE_TOOL_TIMEOUT="${CF_AGENT_WECHAT_TEST_ARCHIVE_TOOL_TIMEOUT:-120}"
  DOCKER_BIN="${CF_AGENT_WECHAT_DOCKER_BIN:-docker}"
  SYSTEMCTL_BIN="${CF_AGENT_WECHAT_SYSTEMCTL_BIN:-systemctl}"
  DOCKER_SOCKET_PATH="${CF_AGENT_WECHAT_DOCKER_SOCKET_PATH:-/var/run/docker.sock}"
  DF_BIN="${CF_AGENT_WECHAT_DF_BIN:-df}"
else
  SERVER_READY_TIMEOUT=120
  WECHAT_READY_TIMEOUT=120
  WECHAT_STABLE_SECONDS=10
  POST_LOGIN_READY_TIMEOUT=120
  RUNTIME_POLL_INTERVAL=2
  DOCKER_COMMAND_TIMEOUT=20
  COMPOSE_COMMAND_TIMEOUT=60
  WORKER_READY_TIMEOUT=60
  WORKER_STABLE_SECONDS=5
  WORKER_HEARTBEAT_TIMEOUT=10
  TOKEN_SCAN_TIMEOUT=120
  ARCHIVE_TOOL_TIMEOUT=120
  DOCKER_BIN="/usr/bin/docker"
  SYSTEMCTL_BIN="/usr/bin/systemctl"
  DOCKER_SOCKET_PATH="/var/run/docker.sock"
  DF_BIN="/usr/bin/df"
fi
TIMEOUT_BIN="/usr/bin/timeout"

GATEWAY_SERVICE="worker"
RUNTIME_LOCK_FD=""
AGENT_COMPOSE_SNAPSHOT=""
GATEWAY_COMPOSE_SNAPSHOT=""
ATTESTED_AGENT_CONTAINER_ID=""
GATEWAY_WORKER_CONTAINER_ID=""
GATEWAY_GENERATION_ID=""
GATEWAY_GATE_BEGUN=0
GATEWAY_GATE_RELEASED=0
RUNTIME_DOCKER_USES_SUDO=0
RUNTIME_COMPOSE_USES_SUDO=0
RUNTIME_SUDO_AUTHORIZED=0
STABLE_WECHAT_IDENTITY=""
AGENT_IMAGE_DIGEST=""
AGENT_WECHAT_BIND_IP="127.0.0.1"
AGENT_WECHAT_PUBLISHED_PORT="6174"
RUNTIME_MANAGEMENT_ENV_ERROR=""
LAST_ERROR="${LAST_ERROR:-}"
RUNTIME_PERCENT_REQUIRED_UNITS=""

runtime_decimal_is_at_most() {
  local value="$1" maximum="$2"
  local value_length maximum_length
  local LC_ALL=C

  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [[ "$maximum" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  value_length="${#value}"
  maximum_length="${#maximum}"
  [ "$value_length" -lt "$maximum_length" ] && return 0
  [ "$value_length" -gt "$maximum_length" ] && return 1
  [[ "$value" == "$maximum" || "$value" < "$maximum" ]]
}

runtime_positive_decimal_is_at_most() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] &&
    runtime_decimal_is_at_most "$1" "$2"
}

runtime_percent_required_units() {
  local total="$1" percent="$2"
  local quotient remainder scaled_remainder

  quotient=$((total / 100))
  remainder=$((total % 100))
  scaled_remainder=$((remainder * percent))
  RUNTIME_PERCENT_REQUIRED_UNITS=$((
    quotient * percent +
    scaled_remainder / 100 +
    (scaled_remainder % 100 != 0)
  ))
}

runtime_proxy_is_safe() {
  local value="$1"
  local remainder host port

  [ -z "$value" ] && return 0
  case "$value" in
    http://*) remainder="${value#http://}" ;;
    https://*) remainder="${value#https://}" ;;
    socks5://*) remainder="${value#socks5://}" ;;
    socks5h://*) remainder="${value#socks5h://}" ;;
    *) return 1 ;;
  esac
  case "$remainder" in
    *"@"*|*"/"*|*"?"*|*"#"*) return 1 ;;
  esac
  host="${remainder%:*}"
  port="${remainder##*:}"
  [ "$host" != "$remainder" ] && [ -n "$host" ] ||
    return 1
  if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$port" -gt 65535 ]; then
    return 1
  fi
  case "$host" in
    \[*\])
      host="${host#[}"
      host="${host%]}"
      [[ "$host" =~ ^[0-9A-Fa-f:]+$ ]]
      ;;
    *)
      [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
        [[ "$host" != *..* ]]
      ;;
  esac
}

runtime_validate_testing_path_isolation() {
  local path="$1"
  local label="$2"
  local confinement="${3:-confined}"

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  validate_testing_asset_isolation "$path" "$label" "$confinement"
}

runtime_validate_testing_storage_isolation() {
  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  runtime_validate_testing_path_isolation \
    "$STORAGE_ROOT" "storage root" || return 1
  runtime_validate_testing_path_isolation \
    "$RUNTIME_ROOT" "runtime root" || return 1
  runtime_validate_testing_path_isolation \
    "$ARCHIVE_ROOT" "archive root" || return 1
  runtime_validate_testing_path_isolation \
    "$LEGACY_DATA_ROOT" "legacy data root" || return 1
  runtime_validate_testing_path_isolation \
    "$LEGACY_WECHAT_HOME_ROOT" "legacy WeChat HOME root" || return 1
}

runtime_validate_testing_gateway_isolation() {
  local path label project_canonical path_canonical index
  local -a paths labels

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  runtime_validate_testing_path_isolation \
    "$GATEWAY_PROJECT_DIR" "Gateway project" || return 1
  project_canonical="$(testing_canonical_path "$GATEWAY_PROJECT_DIR")" ||
    return 1
  paths=(
    "$GATEWAY_COMPOSE_FILE"
    "$GATEWAY_ENV_FILE"
    "$GATEWAY_HEARTBEAT_COMMAND"
    "$GATEWAY_RELEASE_GATE_COMMAND"
    "$GATEWAY_CONTRACT_FILE"
  )
  labels=(
    "Gateway Compose file"
    "Gateway environment file"
    "Gateway heartbeat checker"
    "Gateway runtime release gate"
    "Gateway runtime contract"
  )
  for index in "${!paths[@]}"; do
    path="${paths[$index]}"
    label="${labels[$index]}"
    runtime_validate_testing_path_isolation "$path" "$label" || return 1
    path_canonical="$(testing_canonical_path "$path")" || return 1
    case "${path_canonical}/" in
      "${project_canonical}/"?*) ;;
      *)
        LAST_ERROR="Testing ${label} must remain within the isolated Gateway project."
        return 1
        ;;
    esac
  done
}

runtime_validate_testing_lock_isolation() {
  local lock_canonical production_lock

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  lock_canonical="$(testing_canonical_path "$RUNTIME_LOCK_FILE")" || return 1
  production_lock="$(testing_canonical_path \
    /run/lock/cf-agent-wechat-qr-runtime.lock)" || return 1
  if [ "$lock_canonical" = "$production_lock" ]; then
    LAST_ERROR="Testing runtime lock must not use the production lock file."
    return 1
  fi
  runtime_validate_testing_path_isolation \
    "$RUNTIME_LOCK_FILE" "runtime lock" || return 1
}

runtime_validate_testing_code_isolation() {
  local path label index
  local -a paths labels

  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  for path in "$RUNTIME_REPO_ROOT" "$RUNTIME_SCRIPTS_DIR" "$SCRIPTS_DIR"; do
    runtime_validate_testing_path_isolation \
      "$path" "repository scripts" external || return 1
  done
  paths=(
    "$AGENT_COMPOSE_FILE"
    "$AGENT_ENV_FILE"
  )
  labels=(
    "agent Compose file"
    "agent environment file"
  )
  for index in "${!paths[@]}"; do
    runtime_validate_testing_path_isolation \
      "${paths[$index]}" "${labels[$index]}" confined || return 1
  done
  for path in \
    "$GATEWAY_CONTRACT_VERIFIER" "$RUNTIME_TREE_SCANNER" \
    "$ARCHIVE_RUNTIME_TOOL" "$MANAGEMENT_ENV_PARSER" \
    "$MANAGEMENT_SOURCE_SECRET_VERIFIER"; do
    runtime_validate_testing_path_isolation \
      "$path" "management helper" external || return 1
  done
}

runtime_validate_testing_replacement_file() {
  local path="$1" label="$2" metadata owner mode links

  [ -n "$path" ] || return 0
  testing_validate_unprivileged_identity || return 1
  runtime_validate_testing_path_isolation \
    "$path" "$label replacement" confined || return 1
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    LAST_ERROR="Testing ${label} replacement must be a non-symlink regular file."
    return 1
  fi
  metadata="$(/usr/bin/stat -Lc '%u:%a:%h' -- "$path" 2>/dev/null)" || {
    LAST_ERROR="Testing ${label} replacement metadata could not be verified."
    return 1
  }
  owner="${metadata%%:*}"
  mode="${metadata#*:}"; mode="${mode%%:*}"
  links="${metadata##*:}"
  if [ "$owner" != "$(/usr/bin/id -u)" ] || [ "$links" != 1 ] ||
    (( (8#$mode & 8#022) != 0 )); then
    LAST_ERROR="Testing ${label} replacement has unsafe owner, mode, or link count."
    return 1
  fi
}

runtime_validate_testing_replacement_isolation() {
  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  if [ -n "${CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT:-}" ]; then
    runtime_validate_testing_path_isolation \
      "$GATEWAY_CONTRACT_VERIFIER" "Gateway verifier replacement target" \
      confined || return 1
  fi
  runtime_validate_testing_replacement_file \
    "${CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT:-}" \
    "Gateway verifier" || return 1
  if [ -n "${CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT:-}" ]; then
    runtime_validate_testing_path_isolation \
      "$GATEWAY_HEARTBEAT_COMMAND" "Gateway checker replacement target" \
      confined || return 1
  fi
  runtime_validate_testing_replacement_file \
    "${CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT:-}" \
    "Gateway checker" || return 1
  if [ -n "${CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT:-}" ]; then
    runtime_validate_testing_path_isolation \
      "$GATEWAY_RELEASE_GATE_COMMAND" "Gateway gate replacement target" \
      confined || return 1
  fi
  runtime_validate_testing_replacement_file \
    "${CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT:-}" \
    "Gateway gate" || return 1
}

runtime_validate_testing_tool_isolation() {
  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  validate_testing_login_asset_isolation || return 1
  validate_testing_executable_isolation \
    "$DOCKER_BIN" "Docker" confined || return 1
  validate_testing_executable_isolation \
    "$SYSTEMCTL_BIN" "systemctl" confined || return 1
  validate_testing_executable_isolation \
    "$DF_BIN" "df" system-or-confined || return 1
  [ "$TIMEOUT_BIN" = /usr/bin/timeout ] || {
    LAST_ERROR="Testing timeout executable must remain the fixed system binary."
    return 1
  }
  validate_testing_executable_isolation \
    "$TIMEOUT_BIN" "timeout" system-or-confined || return 1
}

runtime_validate_testing_isolation() {
  [ "$CF_AGENT_WECHAT_TESTING" = "1" ] || return 0
  testing_validate_root_contract || return 1
  validate_testing_token_isolation || return 1
  validate_testing_endpoint_isolation || return 1
  runtime_validate_testing_storage_isolation || return 1
  runtime_validate_testing_gateway_isolation || return 1
  runtime_validate_testing_lock_isolation || return 1
  runtime_validate_testing_code_isolation || return 1
  runtime_validate_testing_replacement_isolation || return 1
  runtime_validate_testing_tool_isolation || return 1
  validate_testing_docker_isolation || return 1
}

runtime_load_management_environment() {
  local line key value env_contents parser_snapshot parser_fd
  local pair_count=0
  local -a parser_args
  declare -A seen=()

  RUNTIME_MANAGEMENT_ENV_ERROR=""
  APPROVED_AGENT_IMAGE=""
  APPROVED_AGENT_CONTAINER=""
  APPROVED_AGENT_PROJECT=""
  APPROVED_PROXY=""
  APPROVED_RUST_LOG=""
  AGENT_WECHAT_BIND_IP=""
  AGENT_WECHAT_PUBLISHED_PORT=""
  RUNTIME_DEFAULT_UID=""
  RUNTIME_DEFAULT_GID=""
  RUNTIME_DEFAULT_MODE=""
  RUNTIME_MANAGEMENT_GID=""
  MIN_FREE_BYTES=""
  MIN_FREE_PERCENT=""
  MIN_FREE_INODES=""
  TOKEN_SCAN_MAX_FILES=""
  TOKEN_SCAN_MAX_BYTES=""
  runtime_validate_trusted_tmp_root || {
    RUNTIME_MANAGEMENT_ENV_ERROR="$LAST_ERROR"
    return 1
  }
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    parser_snapshot="$(mktemp)" || {
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env parser snapshot could not be isolated."
      return 1
    }
  else
    parser_snapshot="$(/usr/bin/mktemp \
      /tmp/cf-agent-wechat-management-env.XXXXXXXXXX)" || {
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env parser snapshot could not be isolated."
      return 1
    }
  fi
  /bin/chmod 600 "$parser_snapshot" || {
    /bin/rm -f -- "$parser_snapshot"
    RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env parser snapshot could not be protected."
    return 1
  }
  parser_args=("$MANAGEMENT_ENV_PARSER" --env-file "$AGENT_ENV_FILE" --format nul)
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    parser_args+=(--path-contract portable)
  fi
  if ! runtime_privileged_isolated_python "$DOCKER_COMMAND_TIMEOUT" \
    "${parser_args[@]}" >"$parser_snapshot" 2>/dev/null; then
    /bin/rm -f -- "$parser_snapshot"
    RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env failed byte-safe validation."
    return 1
  fi
  if ! { exec {parser_fd}<"$parser_snapshot"; } 2>/dev/null; then
    /bin/rm -f -- "$parser_snapshot"
    RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env parser snapshot could not be opened."
    return 1
  fi
  /bin/rm -f -- "$parser_snapshot"
  env_contents=""
  while IFS= read -r -d '' key <&"$parser_fd"; do
    if ! IFS= read -r -d '' value <&"$parser_fd"; then
      exec {parser_fd}<&-
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env parser output was incomplete."
      return 1
    fi
    env_contents+="${key}=${value}"$'\n'
    pair_count=$((pair_count + 1))
  done
  exec {parser_fd}<&-
  if [ "$pair_count" -ne 19 ]; then
    RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env parser output was incomplete."
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if ! [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env contains unsupported syntax."
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ -v seen[$key] ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env contains a duplicate ${key} assignment."
      return 1
    fi
    seen[$key]=1
    if { [ -z "$value" ] && [ "$key" != "PROXY" ]; } ||
      [[ "$value" =~ [[:cntrl:]] ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} is empty or contains control characters."
      return 1
    fi
    case "$value" in
      *'$'*|*'"'*|*"'"*|*\\*|*[[:space:]]*)
        RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} must be an unquoted literal without whitespace."
        return 1
        ;;
    esac
    if [[ "$value" == *$'\x60'* ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} must be an unquoted literal without whitespace."
      return 1
    fi
    case "$key" in
      COMPOSE_PROJECT_NAME|CF_AGENT_WECHAT_STORAGE_ROOT|CF_AGENT_WECHAT_RUNTIME_ROOT|CF_AGENT_WECHAT_ARCHIVE_ROOT|AGENT_WECHAT_BIND_IP|AGENT_WECHAT_PORT|AGENT_WECHAT_CONTAINER_NAME|AGENT_WECHAT_IMAGE|PROXY|RUST_LOG) ;;
      CF_AGENT_WECHAT_RUNTIME_UID|CF_AGENT_WECHAT_RUNTIME_GID|CF_AGENT_WECHAT_RUNTIME_MODE|CF_AGENT_WECHAT_MANAGEMENT_GID) ;;
      CF_AGENT_WECHAT_MIN_FREE_BYTES|CF_AGENT_WECHAT_MIN_FREE_PERCENT|CF_AGENT_WECHAT_MIN_FREE_INODES) ;;
      CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES|CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES) ;;
      *)
        RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env contains unsupported key: ${key}."
        return 1
        ;;
    esac
    case "$key" in
      CF_AGENT_WECHAT_STORAGE_ROOT|CF_AGENT_WECHAT_RUNTIME_ROOT|CF_AGENT_WECHAT_ARCHIVE_ROOT)
        if ! [[ "$value" =~ ^/[-A-Za-z0-9._/@%+,=:~]+$ ]] ||
          [[ "$value" == *'/../'* ]] || [[ "$value" == */.. ]]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} is not a safe absolute path."
          return 1
        fi
        ;;
      AGENT_WECHAT_BIND_IP)
        if [ "$value" != "127.0.0.1" ]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env AGENT_WECHAT_BIND_IP must be 127.0.0.1."
          return 1
        fi
        AGENT_WECHAT_BIND_IP="$value"
        ;;
      AGENT_WECHAT_PORT)
        if ! runtime_positive_decimal_is_at_most "$value" 65535; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env AGENT_WECHAT_PORT is invalid."
          return 1
        fi
        ;;
      AGENT_WECHAT_CONTAINER_NAME)
        if ! [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env container name is invalid."
          return 1
        fi
        ;;
      AGENT_WECHAT_IMAGE)
        if ! [[ "$value" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env AGENT_WECHAT_IMAGE must be digest pinned."
          return 1
        fi
        ;;
      COMPOSE_PROJECT_NAME)
        if [ "$value" != "cf-agent-wechat" ]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env COMPOSE_PROJECT_NAME must be cf-agent-wechat."
          return 1
        fi
        ;;
      PROXY)
        if ! runtime_proxy_is_safe "$value"; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env PROXY must be empty or an approved credential-free scheme, host, and port."
          return 1
        fi
        ;;
      RUST_LOG)
        case "$value" in
          error|warn|info) ;;
          *)
            RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env RUST_LOG must be error, warn, or info."
            return 1
            ;;
        esac
        ;;
    esac
    case "$key" in
      CF_AGENT_WECHAT_STORAGE_ROOT) STORAGE_ROOT="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_ROOT) RUNTIME_ROOT="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_UID|CF_AGENT_WECHAT_RUNTIME_GID|CF_AGENT_WECHAT_MANAGEMENT_GID)
        if ! runtime_positive_decimal_is_at_most \
          "$value" "$RUNTIME_UID_GID_MAX"; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} must be a non-root numeric ID in the approved range."
          return 1
        fi
        ;;
      CF_AGENT_WECHAT_RUNTIME_MODE)
        if [ "$value" != "700" ]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env CF_AGENT_WECHAT_RUNTIME_MODE must be 700."
          return 1
        fi
        ;;
      CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES)
        if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} must be a positive integer."
          return 1
        fi
        if ! runtime_decimal_is_at_most "$value" 200000; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES must not exceed the compiled scanner limit."
          return 1
        fi
        ;;
      CF_AGENT_WECHAT_MIN_FREE_BYTES|CF_AGENT_WECHAT_MIN_FREE_INODES|CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES)
        if ! runtime_positive_decimal_is_at_most \
          "$value" "$RUNTIME_INT64_MAX"; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env ${key} must be a positive integer in the approved range."
          return 1
        fi
        ;;
      CF_AGENT_WECHAT_MIN_FREE_PERCENT)
        if ! runtime_decimal_is_at_most "$value" 100; then
          RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env CF_AGENT_WECHAT_MIN_FREE_PERCENT must be between 0 and 100."
          return 1
        fi
        ;;
    esac
    # Apply only after the independent validation pass has accepted the value.
    case "$key" in
      CF_AGENT_WECHAT_ARCHIVE_ROOT) ARCHIVE_ROOT="$value" ;;
      AGENT_WECHAT_CONTAINER_NAME) APPROVED_AGENT_CONTAINER="$value"; CONTAINER_NAME="$value" ;;
      AGENT_WECHAT_PORT) AGENT_WECHAT_PUBLISHED_PORT="$value" ;;
      AGENT_WECHAT_IMAGE) APPROVED_AGENT_IMAGE="$value" ;;
      COMPOSE_PROJECT_NAME) APPROVED_AGENT_PROJECT="$value" ;;
      PROXY) APPROVED_PROXY="$value" ;;
      RUST_LOG) APPROVED_RUST_LOG="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_UID) RUNTIME_DEFAULT_UID="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_GID) RUNTIME_DEFAULT_GID="$value" ;;
      CF_AGENT_WECHAT_RUNTIME_MODE) RUNTIME_DEFAULT_MODE="$value" ;;
      CF_AGENT_WECHAT_MANAGEMENT_GID) RUNTIME_MANAGEMENT_GID="$value" ;;
      CF_AGENT_WECHAT_MIN_FREE_BYTES) MIN_FREE_BYTES="$value" ;;
      CF_AGENT_WECHAT_MIN_FREE_PERCENT) MIN_FREE_PERCENT="$value" ;;
      CF_AGENT_WECHAT_MIN_FREE_INODES) MIN_FREE_INODES="$value" ;;
      CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES) TOKEN_SCAN_MAX_FILES="$value" ;;
      CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES) TOKEN_SCAN_MAX_BYTES="$value" ;;
    esac
  done <<< "$env_contents"

  local required_key
  for required_key in \
    COMPOSE_PROJECT_NAME CF_AGENT_WECHAT_STORAGE_ROOT \
    CF_AGENT_WECHAT_RUNTIME_ROOT CF_AGENT_WECHAT_ARCHIVE_ROOT \
    AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT AGENT_WECHAT_CONTAINER_NAME \
    AGENT_WECHAT_IMAGE PROXY RUST_LOG CF_AGENT_WECHAT_RUNTIME_UID \
    CF_AGENT_WECHAT_RUNTIME_GID CF_AGENT_WECHAT_RUNTIME_MODE \
    CF_AGENT_WECHAT_MANAGEMENT_GID CF_AGENT_WECHAT_MIN_FREE_BYTES \
    CF_AGENT_WECHAT_MIN_FREE_PERCENT CF_AGENT_WECHAT_MIN_FREE_INODES \
    CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES; do
    if [[ ! -v seen[$required_key] ]]; then
      RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env is missing required key: ${required_key}."
      return 1
    fi
  done

  if [ "$CF_AGENT_WECHAT_TESTING" != "1" ] &&
    { [ "$STORAGE_ROOT" != "/srv/storage/cf-agent-wechat" ] ||
      [ "$RUNTIME_ROOT" != "/srv/storage/cf-agent-wechat/runtime" ] ||
      [ "$ARCHIVE_ROOT" != "/srv/storage/cf-agent-wechat/session-archive" ]; }; then
    RUNTIME_MANAGEMENT_ENV_ERROR="docker/.env production storage paths differ from the approved fixed paths."
    return 1
  fi
  LEGACY_DATA_ROOT="${STORAGE_ROOT}/data"
  LEGACY_WECHAT_HOME_ROOT="${STORAGE_ROOT}/wechat-home"
  configure_agent_endpoints "$AGENT_WECHAT_BIND_IP" "$AGENT_WECHAT_PUBLISHED_PORT"
  if ! runtime_validate_testing_storage_isolation; then
    RUNTIME_MANAGEMENT_ENV_ERROR="$LAST_ERROR"
    return 1
  fi
  if ! runtime_validate_agent_environment_metadata_contract; then
    RUNTIME_MANAGEMENT_ENV_ERROR="$LAST_ERROR"
    return 1
  fi
}

runtime_require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    LAST_ERROR="Required command is missing: $1"
    return 1
  fi
}

runtime_validate_uint() {
  local name="$1"
  local value="$2"

  if ! runtime_decimal_is_at_most "$value" "$RUNTIME_INT64_MAX"; then
    LAST_ERROR="${name} must be a non-negative integer in the approved range."
    return 1
  fi
}

runtime_validate_mode() {
  [[ "$1" =~ ^[0-7]{3,4}$ ]]
}

runtime_authorize_sudo() {
  if [ "$(id -u)" -eq 0 ] || [ "$RUNTIME_SUDO_AUTHORIZED" -eq 1 ]; then
    return 0
  fi
  if ! authorize_management_sudo "执行 forced-QR 生产管理操作"; then
    return 1
  fi
  RUNTIME_SUDO_AUTHORIZED=1
}

runtime_with_timeout() {
  local duration="$1"
  shift

  "$TIMEOUT_BIN" --signal=TERM --kill-after=2s "${duration}s" "$@"
}

runtime_canonical_path() {
  readlink -m -- "$1"
}

runtime_validate_no_symlink_ancestors() {
  local path="$1" label="$2" current
  current="$(dirname -- "$path")"
  while [ "$current" != / ]; do
    if runtime_privileged test -L "$current"; then
      LAST_ERROR="${label} must not contain symbolic link ancestors."
      return 1
    fi
    current="$(dirname -- "$current")"
  done
}

runtime_path_is_within() {
  local candidate="$1"
  local parent="$2"

  case "${candidate}/" in
    "${parent}/"*) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_path_exists() {
  runtime_privileged test -e "$1" || runtime_privileged test -L "$1"
}

runtime_validate_directory_or_missing() {
  local path="$1"
  local label="$2"

  if runtime_privileged test -L "$path"; then
    LAST_ERROR="${label} must not be a symlink."
    return 1
  fi
  if runtime_privileged test -e "$path" &&
    ! runtime_privileged test -d "$path"; then
    LAST_ERROR="${label} must be a directory when it exists."
    return 1
  fi
}

runtime_validate_empty_token_mountpoint() {
  local path="$1"
  local label="$2"
  local size

  if runtime_privileged test -L "$path"; then
    LAST_ERROR="${label} contains an unsafe auth-token symlink."
    return 1
  fi
  if ! runtime_privileged test -e "$path"; then
    return 0
  fi
  if ! runtime_privileged test -f "$path"; then
    LAST_ERROR="${label} contains a non-file auth-token mountpoint."
    return 1
  fi
  if ! size="$(runtime_privileged stat -c '%s' -- "$path")"; then
    LAST_ERROR="${label} auth-token mountpoint could not be inspected."
    return 1
  fi
  if [ "$size" != "0" ]; then
    LAST_ERROR="${label} contains auth-token data; refusing to archive it."
    return 1
  fi
}

runtime_assert_tree_has_no_auth_token() {
  local root="$1"
  local label="$2"
  local move_to="${3:-}"
  local reserved_top_level_name="${4:-}"
  local require_empty_runtime_layout="${5:-0}"
  local -a scanner_arguments=(
    --root "$root"
    --token-file "$TOKEN_FILE"
    --max-files "$TOKEN_SCAN_MAX_FILES"
    --max-bytes "$TOKEN_SCAN_MAX_BYTES"
    --timeout-seconds "$TOKEN_SCAN_TIMEOUT"
  )

  if ! runtime_privileged test -d "$root"; then
    if [ -n "$move_to" ]; then
      LAST_ERROR="${label} disappeared before its attested archive move."
      return 1
    fi
    return 0
  fi
  [ -z "$move_to" ] ||
    scanner_arguments+=(--move-to "$move_to")
  [ -z "$reserved_top_level_name" ] ||
    scanner_arguments+=(--reserved-top-level-name "$reserved_top_level_name")
  if [ "$require_empty_runtime_layout" = "1" ]; then
    scanner_arguments+=(--require-empty-runtime-layout)
  elif [ "$require_empty_runtime_layout" != "0" ]; then
    LAST_ERROR="${label} requested an invalid runtime tree contract."
    return 1
  fi
  if runtime_privileged "$TIMEOUT_BIN" --signal=TERM --kill-after=2s \
    "${TOKEN_SCAN_TIMEOUT}s" /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    /usr/bin/python3 -I "$RUNTIME_TREE_SCANNER" \
    "${scanner_arguments[@]}" >/dev/null 2>&1; then
    return 0
  fi
  LAST_ERROR="${label} failed the bounded no-follow runtime tree and Token scan."
  return 1
}

runtime_assert_fresh_runtime_tree() {
  runtime_assert_tree_has_no_auth_token "$1" "$2" "" "" 1
}

runtime_assert_management_sources_have_no_auth_token() {
  if ! runtime_privileged_isolated_python "$DOCKER_COMMAND_TIMEOUT" \
    "$MANAGEMENT_SOURCE_SECRET_VERIFIER" \
    --token-file "$TOKEN_FILE" \
    --source "$AGENT_COMPOSE_FILE" \
    --source "$AGENT_ENV_FILE" \
    --source "$GATEWAY_COMPOSE_FILE" \
    --source "$GATEWAY_ENV_FILE" >/dev/null 2>&1; then
    LAST_ERROR="Management source files failed the bounded stable auth-token absence scan."
    return 1
  fi
}

runtime_validate_management_file() {
  local path="$1"
  local label="$2"
  local allowed_modes="${3:-}"
  local metadata owner mode links current_uid

  if runtime_privileged test -L "$path" ||
    ! runtime_privileged test -f "$path"; then
    LAST_ERROR="${label} must be a non-symlink regular file."
    return 1
  fi
  if ! metadata="$(runtime_privileged stat -Lc '%u:%a:%h' -- "$path")"; then
    LAST_ERROR="${label} metadata could not be read."
    return 1
  fi
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  mode="${mode%%:*}"
  links="${metadata##*:}"
  current_uid="$(id -u)"
  if [ "$owner" != "0" ] && [ "$owner" != "$current_uid" ]; then
    LAST_ERROR="${label} must be owned by root or the current management user."
    return 1
  fi
  if [ "$links" != "1" ]; then
    LAST_ERROR="${label} must not have additional hard links."
    return 1
  fi
  if [ -n "$allowed_modes" ]; then
    case " ${allowed_modes} " in
      *" ${mode} "*) ;;
      *)
        LAST_ERROR="${label} has an unsafe mode."
        return 1
        ;;
    esac
  elif (( (8#$mode & 8#022) != 0 )); then
    LAST_ERROR="${label} must not be writable by group or other."
    return 1
  fi
}

runtime_validate_agent_environment_metadata_contract() {
  local metadata owner group mode links current_uid current_gid

  if ! metadata="$(runtime_privileged stat -Lc '%u:%g:%a:%h' -- "$AGENT_ENV_FILE")"; then
    LAST_ERROR="agent-wechat environment file metadata could not be read."
    return 1
  fi
  owner="${metadata%%:*}"
  metadata="${metadata#*:}"
  group="${metadata%%:*}"
  metadata="${metadata#*:}"
  mode="${metadata%%:*}"
  links="${metadata##*:}"
  current_uid="$(id -u)"
  current_gid="$(id -g)"
  if [ "$links" != "1" ]; then
    LAST_ERROR="agent-wechat environment file must not have additional hard links."
    return 1
  fi

  case "$mode" in
    600)
      if ! { { [ "$owner" = "0" ] && [ "$group" = "0" ]; } ||
        { [ "$owner" = "$current_uid" ] && [ "$group" = "$current_gid" ]; }; }; then
        LAST_ERROR="agent-wechat environment file owner, group, and mode do not match the approved management contract."
        return 1
      fi
      ;;
    640)
      if ! { { [ "$owner" = "0" ] || [ "$owner" = "$current_uid" ]; } &&
        [ "$group" = "$RUNTIME_MANAGEMENT_GID" ]; }; then
        LAST_ERROR="agent-wechat environment file owner, group, and mode do not match the approved management contract."
        return 1
      fi
      ;;
    *)
      LAST_ERROR="agent-wechat environment file mode must be exactly 600 or 640."
      return 1
      ;;
  esac
  # Read by start-qr-login.sh after this shared validator returns.
  # shellcheck disable=SC2034
  AGENT_ENV_APPROVED_UID="$owner"
  # Read by start-qr-login.sh after this shared validator returns.
  # shellcheck disable=SC2034
  AGENT_ENV_APPROVED_GID="$group"
  # Read by start-qr-login.sh after this shared validator returns.
  # shellcheck disable=SC2034
  AGENT_ENV_APPROVED_MODE="$mode"
}

runtime_validate_management_directory() {
  local path="$1"
  local label="$2"
  local privileged="${3:-0}"
  local metadata owner mode current_uid
  local -a command=(stat -Lc '%u:%a' -- "$path")

  if [ "$privileged" -eq 1 ]; then
    if runtime_privileged test -L "$path" ||
      ! runtime_privileged test -d "$path" ||
      ! metadata="$(runtime_privileged "${command[@]}")"; then
      LAST_ERROR="${label} must be an existing non-symlink directory."
      return 1
    fi
  elif [ -L "$path" ] || [ ! -d "$path" ] ||
    ! metadata="$("${command[@]}")"; then
    LAST_ERROR="${label} must be an existing non-symlink directory."
    return 1
  fi
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  current_uid="$(id -u)"
  if [ "$owner" != "0" ] && [ "$owner" != "$current_uid" ]; then
    LAST_ERROR="${label} must be owned by root or the current management user."
    return 1
  fi
  if (( (8#$mode & 8#022) != 0 )); then
    LAST_ERROR="${label} must not be writable by group or other."
    return 1
  fi
}

runtime_validate_directory_without_extended_attributes() {
  local path="$1"
  local label="$2"

  if runtime_privileged_isolated_python "$TOKEN_SCAN_TIMEOUT" - "$path" >/dev/null 2>&1 <<'PY'
import os
import stat
import sys

path = sys.argv[1]
required_flags = ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC")
if any(not hasattr(os, name) for name in required_flags):
    raise SystemExit(1)

def identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_ctime_ns,
    )

descriptor = -1
try:
    before = os.lstat(path)
    if not stat.S_ISDIR(before.st_mode):
        raise OSError
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(path, flags)
    opened = os.fstat(descriptor)
    if identity(opened) != identity(before):
        raise OSError
    attributes = os.listxattr(descriptor)
    after = os.fstat(descriptor)
    final = os.lstat(path)
    if (
        attributes
        or identity(after) != identity(opened)
        or identity(final) != identity(opened)
    ):
        raise OSError
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if descriptor >= 0:
        os.close(descriptor)
PY
  then
    return 0
  fi
  LAST_ERROR="${label} must be a stable no-follow directory without extended attributes or ACLs."
  return 1
}

runtime_validate_approved_runtime_directory() {
  local path="$1"
  local label="$2"
  local required="${3:-0}"
  local metadata expected

  if runtime_privileged test -L "$path"; then
    LAST_ERROR="${label} must not be a symlink."
    return 1
  fi
  if ! runtime_privileged test -d "$path"; then
    if runtime_path_exists "$path" || [ "$required" -eq 1 ]; then
      LAST_ERROR="${label} must be an existing directory."
      return 1
    fi
    return 0
  fi
  expected="${RUNTIME_DEFAULT_UID}:${RUNTIME_DEFAULT_GID}:${RUNTIME_DEFAULT_MODE}"
  if ! metadata="$(runtime_privileged stat -Lc '%u:%g:%a' -- "$path")" ||
    [ "$metadata" != "$expected" ]; then
    LAST_ERROR="${label} must exactly match approved UID:GID:mode ${expected}; repair it before retrying."
    return 1
  fi
  runtime_validate_directory_without_extended_attributes "$path" "$label" ||
    return 1
}
runtime_validate_restricted_archive_root() {
  local metadata expected current

  if ! runtime_path_exists "$ARCHIVE_ROOT"; then
    return 0
  fi
  if runtime_privileged test -L "$ARCHIVE_ROOT" ||
    ! runtime_privileged test -d "$ARCHIVE_ROOT" ||
    ! metadata="$(runtime_privileged stat -Lc '%u:%g:%a' -- "$ARCHIVE_ROOT")"; then
    LAST_ERROR="Archive root must be a non-symlink directory."
    return 1
  fi
  expected="0:0:700"
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    current="$(id -u):$(id -g):700"
    if [ "$metadata" = "$expected" ] || [ "$metadata" = "$current" ]; then
      runtime_validate_directory_without_extended_attributes "$ARCHIVE_ROOT" "Archive root" ||
        return 1
      return 0
    fi
  elif [ "$metadata" = "$expected" ]; then
    runtime_validate_directory_without_extended_attributes "$ARCHIVE_ROOT" "Archive root" ||
      return 1
    return 0
  fi
  LAST_ERROR="Archive root must be root:root mode 700."
  return 1
}



runtime_validate_lock_parent() {
  local path="$1"
  local metadata owner group mode current_uid

  if runtime_privileged test -L "$path" ||
    ! runtime_privileged test -d "$path" ||
    ! metadata="$(runtime_privileged stat -Lc '%u:%g:%a' -- "$path")"; then
    LAST_ERROR="Runtime lock parent must be an existing non-symlink directory."
    return 1
  fi
  owner="${metadata%%:*}"
  metadata="${metadata#*:}"
  group="${metadata%%:*}"
  mode="${metadata##*:}"
  current_uid="$(id -u)"
  if [ "$owner" != "0" ] &&
    { [ "$CF_AGENT_WECHAT_TESTING" != "1" ] || [ "$owner" != "$current_uid" ]; }; then
    LAST_ERROR="Runtime lock parent has an unapproved owner."
    return 1
  fi
  if (( (8#$mode & 8#002) != 0 )); then
    LAST_ERROR="Runtime lock parent must not be writable by other users."
    return 1
  fi
  if (( (8#$mode & 8#020) != 0 )) &&
    [ "$group" != "0" ] && [ "$group" != "$RUNTIME_MANAGEMENT_GID" ]; then
    LAST_ERROR="Runtime lock parent has an unapproved writable group."
    return 1
  fi
}

runtime_validate_root_file() {
  local path="$1"
  local label="$2"
  local expected_mode="$3"
  local metadata

  if runtime_privileged test -L "$path" ||
    ! runtime_privileged test -f "$path"; then
    LAST_ERROR="${label} must be a non-symlink regular file."
    return 1
  fi
  if ! metadata="$(runtime_privileged stat -Lc '%u:%g:%a:%h' -- "$path")" ||
    [ "$metadata" != "0:0:${expected_mode}:1" ]; then
    LAST_ERROR="${label} must be root:root ${expected_mode} with one hard link."
    return 1
  fi
}

runtime_validate_root_directory() {
  local path="$1"
  local label="$2"
  local expected_mode="$3"
  local metadata

  if runtime_privileged test -L "$path" ||
    ! runtime_privileged test -d "$path"; then
    LAST_ERROR="${label} must be a non-symlink directory."
    return 1
  fi
  if ! metadata="$(runtime_privileged stat -Lc '%u:%g:%a' -- "$path")" ||
    [ "$metadata" != "0:0:${expected_mode}" ]; then
    LAST_ERROR="${label} must be root:root ${expected_mode}."
    return 1

  fi
}

runtime_validate_trusted_tmp_root() {
  local metadata

  [ "$CF_AGENT_WECHAT_TESTING" != "1" ] || return 0
  if runtime_privileged test -L /tmp ||
    ! runtime_privileged test -d /tmp ||
    ! metadata="$(runtime_privileged stat -Lc '%u:%g:%a' -- /tmp)"; then
    LAST_ERROR="Production /tmp must be an existing non-symlink directory."
    return 1
  fi
  if [ "$metadata" != "0:0:1777" ]; then
    LAST_ERROR="Production /tmp must be root:root mode 1777."
    return 1
  fi
}

runtime_gateway_git() {
  local git_bin="/usr/bin/git"

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ] && [ ! -x "$git_bin" ]; then
    git_bin="$(command -v git)" || return 127
  fi
  runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
    GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 \
    GIT_LITERAL_PATHSPECS=1 GIT_TERMINAL_PROMPT=0 \
    "$git_bin" \
    -c "safe.directory=$GATEWAY_PROJECT_DIR" \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -c core.hooksPath=/dev/null \
    -c core.fileMode=true \
    -c core.symlinks=true \
    -c diff.ignoreSubmodules=none \
    -C "$GATEWAY_PROJECT_DIR" "$@"
}

runtime_attest_gateway_checkout() {
  local expected_commit="$1"
  local actual_commit actual_git_dir actual_origin actual_top config_status
  local index_entry index_inventory untracked_inventory

  if [ -L "${GATEWAY_PROJECT_DIR}/.git" ] ||
    [ ! -d "${GATEWAY_PROJECT_DIR}/.git" ]; then
    LAST_ERROR="The deployed Gateway checkout must use its exact non-symlink Git directory."
    return 1
  fi
  if ! actual_top="$(runtime_gateway_git rev-parse --show-toplevel 2>/dev/null)" ||
    [ "$actual_top" != "$GATEWAY_PROJECT_DIR" ]; then
    LAST_ERROR="The deployed Gateway checkout root is not the approved project directory."
    return 1
  fi
  if ! actual_git_dir="$(runtime_gateway_git rev-parse --absolute-git-dir 2>/dev/null)" ||
    [ "$actual_git_dir" != "${GATEWAY_PROJECT_DIR}/.git" ]; then
    LAST_ERROR="The deployed Gateway Git directory is not the approved checkout metadata."
    return 1
  fi
  if ! actual_commit="$(runtime_gateway_git rev-parse --verify HEAD 2>/dev/null)" ||
    [ "$actual_commit" != "$expected_commit" ]; then
    LAST_ERROR="The deployed Gateway checkout does not match the approved compatible commit."
    return 1
  fi

  if runtime_gateway_git config --local --no-includes --name-only \
    --get-regexp '^(include|includeif|url)\.' >/dev/null 2>&1; then
    LAST_ERROR="The deployed Gateway repository contains forbidden local Git configuration."
    return 1
  else
    config_status=$?
    if [ "$config_status" -ne 1 ]; then
      LAST_ERROR="The deployed Gateway local Git configuration could not be verified."
      return 1
    fi
  fi
  if ! actual_origin="$(runtime_gateway_git config --local --no-includes \
    --get-all remote.origin.url 2>/dev/null)"; then
    LAST_ERROR="The deployed Gateway repository origin could not be verified."
    return 1
  fi
  case "$actual_origin" in
    "https://github.com/${GATEWAY_PRODUCER_REPOSITORY}"|"https://github.com/${GATEWAY_PRODUCER_REPOSITORY}.git"|"git@github.com:${GATEWAY_PRODUCER_REPOSITORY}.git") ;;
    *)
      LAST_ERROR="The deployed Gateway repository origin is not approved."
      return 1
      ;;
  esac

  if ! index_inventory="$(runtime_gateway_git ls-files -v -- 2>/dev/null)"; then
    LAST_ERROR="The deployed Gateway index flags could not be verified."
    return 1
  fi
  while IFS= read -r index_entry; do
    case "${index_entry:0:1}" in
      [a-z]|S)
        LAST_ERROR="The deployed Gateway index contains hidden worktree state."
        return 1
        ;;
    esac
  done <<< "$index_inventory"

  if ! runtime_gateway_git diff-index --cached --quiet \
    --ignore-submodules=none \
    "$expected_commit" -- 2>/dev/null ||
    ! runtime_gateway_git diff-files --quiet \
    --ignore-submodules=none -- 2>/dev/null; then
    LAST_ERROR="The deployed Gateway tracked worktree is not clean."
    return 1
  fi
  if [ "$GATEWAY_ENV_FILE" != "${GATEWAY_PROJECT_DIR}/.env" ]; then
    LAST_ERROR="The deployed Gateway environment is outside its fixed checkout path."
    return 1
  fi
  if ! untracked_inventory="$(runtime_gateway_git ls-files --others \
    --directory --no-empty-directory -- 2>/dev/null)"; then
    LAST_ERROR="The deployed Gateway untracked inventory could not be verified."
    return 1
  fi
  if [ "$untracked_inventory" != ".env" ]; then
    LAST_ERROR="The deployed Gateway checkout has files outside the validated environment allowlist."
    return 1
  fi
  return 0
}

runtime_verify_gateway_provenance() {
  local actual_checker_sha actual_gate_sha
  local actual_blob expected_blob relative_path absolute_path

  [ "$CF_AGENT_WECHAT_TESTING" != "1" ] || return 0
  if ! [[ "$GATEWAY_COMPATIBLE_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    ! [[ "$GATEWAY_CHECKER_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    ! [[ "$GATEWAY_RELEASE_GATE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    LAST_ERROR="No compatible Gateway commit, checker digest, and release-gate digest have been published for this contract."
    return 1
  fi
  runtime_attest_gateway_checkout "$GATEWAY_COMPATIBLE_COMMIT" || return 1

  for relative_path in \
    docker-compose.prod.yml \
    deploy/wechat-runtime-contract.json \
    deploy/check-wechat-worker-heartbeat \
    deploy/wechat-runtime-release-gate; do
    absolute_path="${GATEWAY_PROJECT_DIR}/${relative_path}"
    if ! runtime_gateway_git ls-files --error-unmatch -- "$relative_path" \
      >/dev/null 2>&1 ||
      ! expected_blob="$(runtime_gateway_git rev-parse \
        "${GATEWAY_COMPATIBLE_COMMIT}:${relative_path}" 2>/dev/null)" ||
      ! actual_blob="$(runtime_gateway_git hash-object -- "$absolute_path" 2>/dev/null)" ||
      [ "$actual_blob" != "$expected_blob" ]; then
      LAST_ERROR="Gateway contract artifacts are not the tracked files from the approved commit."
      return 1
    fi
  done
  if ! actual_checker_sha="$(runtime_capture_gateway_checker_digest)"; then
    return 1
  fi
  if [ "$actual_checker_sha" != "$GATEWAY_CHECKER_SHA256" ]; then
    LAST_ERROR="Gateway checker digest does not match the approved compatible commit."
    return 1
  fi
  if ! actual_gate_sha="$(runtime_capture_gateway_gate_digest)"; then
    return 1
  fi
  if [ "$actual_gate_sha" != "$GATEWAY_RELEASE_GATE_SHA256" ]; then
    LAST_ERROR="Gateway release-gate digest does not match the approved compatible commit."
    return 1
  fi
}

runtime_gateway_verifier_snapshot() {
  local mode="$1"
  local expected_digest="$2"
  local approved_uid replacement=""
  local -a clean_env
  shift 2

  case "$mode" in
    digest|execute) ;;
    *) return 1 ;;
  esac
  if ! approved_uid="$(/usr/bin/id -u)"; then
    return 1
  fi
  clean_env=(
    -i
    HOME=/nonexistent
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    LANG=C.UTF-8
    LC_ALL=C.UTF-8
  )
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    runtime_validate_testing_replacement_isolation || return 1
    clean_env+=(CF_AGENT_WECHAT_TESTING=1)
    clean_env+=("CF_AGENT_WECHAT_TEST_ROOT=$CF_AGENT_WECHAT_TEST_ROOT")
    if [ "$mode" = "execute" ]; then
      replacement="${CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT:-}"
      if [ -n "$replacement" ]; then
        clean_env+=(
          "CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT=${replacement}"
        )
      fi
    fi
  fi

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" \
      /usr/bin/env "${clean_env[@]}" \
      "$PYTHON_BIN" -I -c "$GATEWAY_VERIFIER_SNAPSHOT_LOADER" \
      gateway-verifier-snapshot "$mode" "$GATEWAY_CONTRACT_VERIFIER" \
      "$expected_digest" "$approved_uid" "$@"
  else
    runtime_privileged "$TIMEOUT_BIN" --signal=TERM --kill-after=2s \
      "${DOCKER_COMMAND_TIMEOUT}s" /usr/bin/env "${clean_env[@]}" \
      /usr/bin/python3 -I -c "$GATEWAY_VERIFIER_SNAPSHOT_LOADER" \
      gateway-verifier-snapshot "$mode" "$GATEWAY_CONTRACT_VERIFIER" \
      "$expected_digest" "$approved_uid" "$@"
  fi
}

runtime_capture_gateway_verifier_digest() {
  local digest

  if ! digest="$(
    runtime_gateway_verifier_snapshot digest - 2>/dev/null
  )" || ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    LAST_ERROR="Gateway contract verifier snapshot could not be validated."
    return 1
  fi
  printf '%s' "$digest"
}

runtime_execute_gateway_contract_verifier() {
  local checker_sha="$1"
  local gate_sha="$2"
  local attestation_kind="$3"
  local verifier_digest

  if ! verifier_digest="$(runtime_capture_gateway_verifier_digest)"; then
    return 1
  fi
  runtime_gateway_verifier_snapshot execute "$verifier_digest" \
    --contract-file "$GATEWAY_CONTRACT_FILE" \
    --gateway-env "$GATEWAY_ENV_FILE" \
    --token-file "$TOKEN_FILE" \
    --checker "$GATEWAY_HEARTBEAT_COMMAND" \
    --gate "$GATEWAY_RELEASE_GATE_COMMAND" \
    --service "$GATEWAY_SERVICE" \
    --project "$GATEWAY_PROJECT_NAME" \
    --alias cf-agent-wechat \
    --port 6174 \
    --max-age "$GATEWAY_HEARTBEAT_MAX_AGE" \
    --producer-repository "$GATEWAY_PRODUCER_REPOSITORY" \
    --checker-sha256 "$checker_sha" \
    --gate-sha256 "$gate_sha" \
    --attestation-kind "$attestation_kind" >/dev/null 2>&1
}

runtime_gateway_executable_snapshot() {
  local timeout_seconds="$1"
  local executable_kind="$2"
  local executable_path="$3"
  local mode="$4"
  local expected_digest="$5"
  local input_transport="$6"
  local approved_uid
  shift 6

  case "$mode" in
    digest|execute) ;;
    *) return 1 ;;
  esac
  case "$executable_kind:$input_transport" in
    checker:none|checker:stdin-json|gate:none|gate:stdin-json) ;;
    *) return 1 ;;
  esac
  if ! approved_uid="$(/usr/bin/id -u)"; then
    return 1
  fi

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    runtime_validate_testing_replacement_isolation || return 1
    runtime_with_timeout "$timeout_seconds" /usr/bin/env \
      "CF_AGENT_WECHAT_TEST_ROOT=$CF_AGENT_WECHAT_TEST_ROOT" \
      "CF_AGENT_WECHAT_TESTING=1" \
      "CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT=${CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT:-}" \
      "CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT=${CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT:-}" \
      "$PYTHON_BIN" -I -c "$GATEWAY_CHECKER_SNAPSHOT_LOADER" \
      gateway-executable-snapshot "$mode" "$executable_path" \
      "$GATEWAY_PROJECT_DIR" "$expected_digest" "$approved_uid" \
      "$timeout_seconds" "$executable_kind" "$input_transport" "$@"
  else
    runtime_with_timeout "$timeout_seconds" \
      /usr/bin/env -i \
      HOME=/nonexistent \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      "$PYTHON_BIN" -I -c "$GATEWAY_CHECKER_SNAPSHOT_LOADER" \
      gateway-executable-snapshot "$mode" "$executable_path" \
      "$GATEWAY_PROJECT_DIR" "$expected_digest" "$approved_uid" \
      "$timeout_seconds" "$executable_kind" "$input_transport" "$@"
  fi
}

runtime_gateway_checker_snapshot() {
  runtime_gateway_executable_snapshot \
    "$1" checker "$GATEWAY_HEARTBEAT_COMMAND" \
    "$2" "$3" "$4" "${@:5}"
}

runtime_gateway_gate_snapshot() {
  runtime_gateway_executable_snapshot \
    "$1" gate "$GATEWAY_RELEASE_GATE_COMMAND" \
    "$2" "$3" "$4" "${@:5}"
}

runtime_capture_gateway_checker_digest() {
  local digest

  if ! digest="$(
    runtime_gateway_checker_snapshot \
      "$GATEWAY_RUNTIME_COMMAND_TIMEOUT" digest - none 2>/dev/null
  )" || ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    LAST_ERROR="Gateway heartbeat checker snapshot could not be validated."
    return 1
  fi
  printf '%s' "$digest"
}

runtime_capture_gateway_gate_digest() {
  local digest

  if ! digest="$(
    runtime_gateway_gate_snapshot \
      "$GATEWAY_RUNTIME_COMMAND_TIMEOUT" digest - none 2>/dev/null
  )" || ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    LAST_ERROR="Gateway release-gate snapshot could not be validated."
    return 1
  fi
  printf '%s' "$digest"
}

runtime_gateway_generation_id_is_valid() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

runtime_gateway_write_request() {
  local operation="$1"
  local generation_id="$2"
  local agent_container_id="${3:-}"
  local worker_container_id="${4:-}"

  runtime_gateway_generation_id_is_valid "$generation_id" || return 1
  case "$operation" in
    begin|assert-pending|abort)
      [ -z "$agent_container_id" ] && [ -z "$worker_container_id" ] ||
        return 1
      printf '{"schemaVersion":1,"operation":"%s","generationId":"%s"}\n' \
        "$operation" "$generation_id"
      ;;
    release)
      runtime_gateway_generation_id_is_valid "$agent_container_id" &&
        runtime_gateway_generation_id_is_valid "$worker_container_id" ||
        return 1
      printf '{"schemaVersion":1,"operation":"release","generationId":"%s","agentContainerId":"%s","workerContainerId":"%s"}\n' \
        "$generation_id" "$agent_container_id" "$worker_container_id"
      ;;
    checker)
      runtime_gateway_generation_id_is_valid "$agent_container_id" &&
        runtime_gateway_generation_id_is_valid "$worker_container_id" ||
        return 1
      printf '{"schemaVersion":1,"generationId":"%s","agentContainerId":"%s","workerContainerId":"%s"}\n' \
        "$generation_id" "$agent_container_id" "$worker_container_id"
      ;;
    *) return 1 ;;
  esac
}

runtime_effective_gateway_gate_digest() {
  local digest="$GATEWAY_RELEASE_GATE_SHA256"

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    digest="$(runtime_capture_gateway_gate_digest)" || return 1
  fi
  if ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    LAST_ERROR="Gateway release-gate digest is not an approved SHA-256 value."
    return 1
  fi
  printf '%s' "$digest"
}

runtime_invoke_gateway_gate() {
  local operation="$1"
  local agent_container_id="${2:-}"
  local worker_container_id="${3:-}"
  local gate_sha gate_status

  if ! gate_sha="$(runtime_effective_gateway_gate_digest)"; then
    return 1
  fi
  if runtime_gateway_write_request "$operation" "$GATEWAY_GENERATION_ID" \
      "$agent_container_id" "$worker_container_id" |
    runtime_gateway_gate_snapshot "$GATEWAY_RUNTIME_COMMAND_TIMEOUT" \
      execute "$gate_sha" stdin-json >/dev/null 2>&1; then
    return 0
  else
    gate_status=$?
  fi
  case "$gate_status" in
    125)
      LAST_ERROR="Gateway runtime release gate violated the silent-output contract."
      ;;
    124)
      LAST_ERROR="Gateway runtime release gate exceeded its hard timeout."
      ;;
    126)
      LAST_ERROR="Gateway runtime release-gate snapshot validation failed."
      ;;
    *)
      LAST_ERROR="Gateway runtime release gate rejected the lifecycle transition."
      ;;
  esac
  return 1
}

runtime_gateway_gate_begin() {
  local generation_id

  GATEWAY_GENERATION_ID=""
  GATEWAY_GATE_BEGUN=0
  GATEWAY_GATE_RELEASED=0
  if ! generation_id="$(
    runtime_with_timeout "$GATEWAY_RUNTIME_COMMAND_TIMEOUT" \
      /usr/bin/env -i \
      HOME=/nonexistent \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      "$PYTHON_BIN" -I -c 'import secrets; print(secrets.token_hex(32))' \
      2>/dev/null
  )" || ! runtime_gateway_generation_id_is_valid "$generation_id"; then
    LAST_ERROR="A fresh Gateway runtime generation identifier could not be created."
    return 1
  fi
  GATEWAY_GENERATION_ID="$generation_id"
  generation_id=""
  if ! runtime_invoke_gateway_gate begin; then
    GATEWAY_GENERATION_ID=""
    return 1
  fi
  GATEWAY_GATE_BEGUN=1
}

runtime_gateway_gate_assert_pending() {
  if [ "$GATEWAY_GATE_BEGUN" -ne 1 ] ||
    [ "$GATEWAY_GATE_RELEASED" -ne 0 ] ||
    ! runtime_gateway_generation_id_is_valid "$GATEWAY_GENERATION_ID"; then
    LAST_ERROR="Gateway runtime generation is not in an approved pending state."
    return 1
  fi
  runtime_invoke_gateway_gate assert-pending
}

runtime_gateway_gate_release() {
  if [ "$GATEWAY_GATE_BEGUN" -ne 1 ] ||
    [ "$GATEWAY_GATE_RELEASED" -ne 0 ] ||
    ! runtime_gateway_generation_id_is_valid "$ATTESTED_AGENT_CONTAINER_ID" ||
    ! runtime_gateway_generation_id_is_valid "$GATEWAY_WORKER_CONTAINER_ID"; then
    LAST_ERROR="Gateway runtime release identities are unavailable or invalid."
    return 1
  fi
  if ! runtime_invoke_gateway_gate release \
    "$ATTESTED_AGENT_CONTAINER_ID" "$GATEWAY_WORKER_CONTAINER_ID"; then
    return 1
  fi
  GATEWAY_GATE_RELEASED=1
}

runtime_gateway_gate_abort() {
  [ "$GATEWAY_GATE_BEGUN" -eq 1 ] || return 0
  if ! runtime_invoke_gateway_gate abort; then
    return 1
  fi
  GATEWAY_GATE_BEGUN=0
  GATEWAY_GATE_RELEASED=0
  GATEWAY_GENERATION_ID=""
}

runtime_verify_gateway_contract() {
  local protected_path checker_sha gate_sha

  for protected_path in "$TOKEN_FILE" "$GATEWAY_PROJECT_DIR" \
    "$GATEWAY_COMPOSE_FILE" "$GATEWAY_ENV_FILE" \
    "$GATEWAY_CONTRACT_FILE" "$GATEWAY_HEARTBEAT_COMMAND" \
    "$GATEWAY_RELEASE_GATE_COMMAND" \
    "$GATEWAY_CONTRACT_VERIFIER"; do
    runtime_validate_no_symlink_ancestors "$protected_path" \
      "Gateway runtime contract input" || return 1
  done
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    runtime_validate_management_file \
      "$TOKEN_FILE" "Agent Token" "600 0600" || return 1
    runtime_validate_management_file "$GATEWAY_ENV_FILE" "Gateway environment" "600 0600" || return 1
    runtime_validate_management_file "$GATEWAY_CONTRACT_FILE" "Gateway runtime contract" "600 0600 644 0644" || return 1
    runtime_validate_management_file "$GATEWAY_HEARTBEAT_COMMAND" "Gateway heartbeat checker" || return 1
    runtime_validate_management_file "$GATEWAY_RELEASE_GATE_COMMAND" "Gateway runtime release gate" || return 1
    runtime_validate_management_file \
      "$GATEWAY_CONTRACT_VERIFIER" "Gateway contract verifier" \
      "755 0755" || return 1
  else
    runtime_validate_root_file "$TOKEN_FILE" "Agent Token" 600 || return 1
    runtime_validate_root_file "$GATEWAY_ENV_FILE" "Gateway environment" 600 || return 1
    runtime_validate_root_file "$GATEWAY_CONTRACT_FILE" "Gateway runtime contract" 644 || return 1
    runtime_validate_root_file "$GATEWAY_HEARTBEAT_COMMAND" "Gateway heartbeat checker" 755 || return 1
    runtime_validate_root_file "$GATEWAY_RELEASE_GATE_COMMAND" "Gateway runtime release gate" 755 || return 1
    runtime_validate_management_file \
      "$GATEWAY_CONTRACT_VERIFIER" "Gateway contract verifier" \
      "755 0755" || return 1
  fi
  if [ ! -x "$GATEWAY_HEARTBEAT_COMMAND" ] ||
    [ ! -x "$GATEWAY_RELEASE_GATE_COMMAND" ]; then
    LAST_ERROR="Gateway heartbeat checker and runtime release gate must be executable."
    return 1
  fi
  runtime_verify_gateway_provenance || return 1
  checker_sha="$GATEWAY_CHECKER_SHA256"
  gate_sha="$GATEWAY_RELEASE_GATE_SHA256"
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    if ! checker_sha="$(runtime_capture_gateway_checker_digest)"; then
      return 1
    fi
    if ! gate_sha="$(runtime_capture_gateway_gate_digest)"; then
      return 1
    fi
  fi
  if ! [[ "$checker_sha" =~ ^[0-9a-f]{64}$ ]] ||
    ! [[ "$gate_sha" =~ ^[0-9a-f]{64}$ ]]; then
    LAST_ERROR="Gateway checker or release-gate digest is not an approved SHA-256 value."
    return 1
  fi
  if ! gateway_compose config --format json 2>/dev/null |
    runtime_execute_gateway_contract_verifier \
      "$checker_sha" "$gate_sha" compose; then
    LAST_ERROR="Gateway runtime contract or Agent Token agreement could not be verified."
    return 1
  fi
}

runtime_attest_gateway_worker_container() {
  local expected_state="${1:-running}"
  local expected_id="${2:-}"
  local checker_sha gate_sha container_id running_ids state_contract
  local expected_running

  case "$expected_state" in
    created)
      expected_running=false
      if ! container_id="$(gateway_compose ps --all --quiet \
        "$GATEWAY_SERVICE" 2>/dev/null)" ||
        ! running_ids="$(gateway_compose ps --status running --quiet \
          "$GATEWAY_SERVICE" 2>/dev/null)" ||
        [ -n "$running_ids" ]; then
        LAST_ERROR="Gateway wechat-worker stopped candidate identity could not be attested."
        return 1
      fi
      ;;
    running)
      expected_running=true
      if ! container_id="$(gateway_compose ps --status running --quiet \
        "$GATEWAY_SERVICE" 2>/dev/null)"; then
        LAST_ERROR="Gateway wechat-worker running identity could not be attested."
        return 1
      fi
      ;;
    *)
      LAST_ERROR="Gateway wechat-worker attestation state is invalid."
      return 1
      ;;
  esac
  if
    [ -z "$container_id" ] ||
    [ "${container_id//$'\n'/}" != "$container_id" ] ||
    ! [[ "$container_id" =~ ^[0-9a-f]{64}$ ]]
  then
    LAST_ERROR="Gateway wechat-worker instance identity could not be attested."
    return 1
  fi
  if [ -n "$expected_id" ] && [ "$container_id" != "$expected_id" ]; then
    LAST_ERROR="Gateway wechat-worker instance identity changed during verification."
    return 1
  fi
  if ! state_contract="$(runtime_docker inspect --format \
    '{{.Id}}|{{.State.Status}}|{{.State.Running}}|{{.State.Restarting}}|{{.State.Paused}}|{{.State.Dead}}' \
    "$container_id" 2>/dev/null)" ||
    [ "$state_contract" != \
      "${container_id}|${expected_state}|${expected_running}|false|false|false" ]; then
    LAST_ERROR="Gateway wechat-worker container state is not the exact approved candidate state."
    return 1
  fi
  checker_sha="$GATEWAY_CHECKER_SHA256"
  gate_sha="$GATEWAY_RELEASE_GATE_SHA256"
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    if ! checker_sha="$(runtime_capture_gateway_checker_digest)"; then
      return 1
    fi
    if ! gate_sha="$(runtime_capture_gateway_gate_digest)"; then
      return 1
    fi
  fi
  if ! [[ "$checker_sha" =~ ^[0-9a-f]{64}$ ]] ||
    ! [[ "$gate_sha" =~ ^[0-9a-f]{64}$ ]]; then
    LAST_ERROR="Gateway checker or release-gate digest is not an approved SHA-256 value."
    return 1
  fi
  if ! runtime_docker inspect "$container_id" 2>/dev/null |
    runtime_execute_gateway_contract_verifier \
      "$checker_sha" "$gate_sha" worker-inspect; then
    LAST_ERROR="Gateway wechat-worker violates the file credential contract."
    return 1
  fi
  GATEWAY_WORKER_CONTAINER_ID="$container_id"
}

runtime_check_archive_capacity() {
  local probe block_output inode_output block_stats inode_stats
  local total_blocks available_blocks total_inodes available_inodes
  local available_bytes free_percent required_percent_blocks
  local candidate_percent

  if runtime_privileged test -d "$ARCHIVE_ROOT"; then
    probe="$ARCHIVE_ROOT"
  else
    probe="$(dirname -- "$ARCHIVE_ROOT")"
  fi
  if runtime_privileged test -L "$probe" ||
    ! runtime_privileged test -d "$probe"; then
    LAST_ERROR="Archive filesystem probe path is unavailable or is a symlink."
    return 1
  fi
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    validate_testing_executable_isolation \
      "$DF_BIN" "df" system-or-confined || return 1
    block_output="$(runtime_with_timeout "$ARCHIVE_TOOL_TIMEOUT" \
      "$DF_BIN" -Pk -- "$probe" 2>/dev/null)" || {
      LAST_ERROR="Archive filesystem free space could not be measured."
      return 1
    }
  elif ! block_output="$(runtime_privileged "$TIMEOUT_BIN" \
    --signal=TERM --kill-after=2s "${ARCHIVE_TOOL_TIMEOUT}s" \
    /usr/bin/df -Pk -- "$probe" 2>/dev/null)"; then
    LAST_ERROR="Archive filesystem free space could not be measured."
    return 1
  fi
  if ! block_stats="$(awk 'NR > 1 { total = $2; available = $4 } END {
      if (total ~ /^[0-9]+$/ && available ~ /^[0-9]+$/) {
        print total, available
      } else {
        exit 1
      }
    }' <<< "$block_output")" ||
    ! read -r total_blocks available_blocks <<< "$block_stats"; then
    LAST_ERROR="Archive filesystem free space could not be measured."
    return 1
  fi
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    inode_output="$(runtime_with_timeout "$ARCHIVE_TOOL_TIMEOUT" \
      "$DF_BIN" -Pi -- "$probe" 2>/dev/null)" || {
      LAST_ERROR="Archive filesystem free inodes could not be measured."
      return 1
    }
  elif ! inode_output="$(runtime_privileged "$TIMEOUT_BIN" \
    --signal=TERM --kill-after=2s "${ARCHIVE_TOOL_TIMEOUT}s" \
    /usr/bin/df -Pi -- "$probe" 2>/dev/null)"; then
    LAST_ERROR="Archive filesystem free inodes could not be measured."
    return 1
  fi
  if ! inode_stats="$(awk 'NR > 1 { total = $2; available = $4 } END {
      if (total ~ /^[0-9]+$/ && available ~ /^[0-9]+$/) {
        print total, available
      } else {
        exit 1
      }
    }' <<< "$inode_output")" ||
    ! read -r total_inodes available_inodes <<< "$inode_stats"; then
    LAST_ERROR="Archive filesystem free inodes could not be measured."
    return 1
  fi
  if ! runtime_positive_decimal_is_at_most \
      "$total_blocks" "$RUNTIME_INT64_MAX" ||
    ! runtime_decimal_is_at_most \
      "$available_blocks" "$RUNTIME_MAX_KIB_FOR_BYTE_CONVERSION" ||
    ! runtime_decimal_is_at_most "$available_blocks" "$total_blocks" ||
    ! runtime_positive_decimal_is_at_most \
      "$total_inodes" "$RUNTIME_INT64_MAX" ||
    ! runtime_decimal_is_at_most \
      "$available_inodes" "$RUNTIME_INT64_MAX" ||
    ! runtime_decimal_is_at_most "$available_inodes" "$total_inodes"; then
    LAST_ERROR="Archive filesystem reported an invalid capacity."
    return 1
  fi
  available_bytes=$((available_blocks * 1024))
  runtime_percent_required_units "$total_blocks" "$MIN_FREE_PERCENT"
  required_percent_blocks="$RUNTIME_PERCENT_REQUIRED_UNITS"
  if [ "$available_bytes" -lt "$MIN_FREE_BYTES" ] ||
    [ "$available_blocks" -lt "$required_percent_blocks" ] ||
    [ "$available_inodes" -lt "$MIN_FREE_INODES" ]; then
    LAST_ERROR="Archive filesystem is below the approved free space or inode threshold."
    return 1
  fi
  free_percent=0
  for ((candidate_percent = 1; candidate_percent <= 100; candidate_percent++)); do
    runtime_percent_required_units "$total_blocks" "$candidate_percent"
    [ "$available_blocks" -ge "$RUNTIME_PERCENT_REQUIRED_UNITS" ] || break
    free_percent="$candidate_percent"
  done
  printf 'Archive capacity: %s bytes free (%s%%), %s inodes free.\n' \
    "$available_bytes" "$free_percent" "$available_inodes"
}

runtime_select_docker() {
  local override context endpoint expected_endpoint security_options live_restore

  validate_testing_docker_isolation || return 1
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    expected_endpoint="unix://${DOCKER_SOCKET_PATH}"
  else
    expected_endpoint="unix:///var/run/docker.sock"
  fi

  for override in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
    if [[ -v $override ]]; then
      LAST_ERROR="${override} must be unset for production local Docker."
      return 1
    fi
  done

  RUNTIME_DOCKER_USES_SUDO=0
  if runtime_docker info >/dev/null 2>&1; then
    :
  elif [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    LAST_ERROR="Testing Docker fake failed without privilege; sudo fallback is forbidden."
    return 1
  elif [ "$(id -u)" -ne 0 ] && runtime_authorize_sudo; then
    RUNTIME_DOCKER_USES_SUDO=1
    runtime_docker info >/dev/null 2>&1 || {
      RUNTIME_DOCKER_USES_SUDO=0
      LAST_ERROR="Docker daemon is unavailable, timed out, or permission was denied."
      return 1
    }
  else
    LAST_ERROR="Docker daemon is unavailable, timed out, or permission was denied."
    return 1
  fi

  if ! context="$(runtime_docker context show 2>/dev/null)" ||
    [ "$context" != "default" ]; then
    LAST_ERROR="Production Docker context must be default."
    return 1
  fi
  if ! endpoint="$(runtime_docker context inspect default \
    --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" ||
    [ "$endpoint" != "$expected_endpoint" ]; then
    if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
      LAST_ERROR="Testing Docker endpoint must match the isolated Unix socket."
    else
      LAST_ERROR="Production Docker endpoint must be unix:///var/run/docker.sock."
    fi
    return 1
  fi
  if ! security_options="$(runtime_docker info \
    --format '{{json .SecurityOptions}}' 2>/dev/null)"; then
    LAST_ERROR="Docker security options could not be inspected."
    return 1
  fi
  case "${security_options,,}" in
    *rootless*)
      LAST_ERROR="Rootless Docker is not supported for this production deployment."
      return 1
      ;;
  esac
  if ! live_restore="$(runtime_docker info \
    --format '{{json .LiveRestoreEnabled}}' 2>/dev/null)"; then
    LAST_ERROR="Docker live-restore state could not be inspected."
    return 1
  fi
  if [ "$live_restore" != "false" ]; then
    LAST_ERROR="Docker live-restore must be disabled for the forced fresh QR lifecycle."
    return 1
  fi
}

runtime_unit_definition_starts_agent() {
  local definition="$1"

  case "$definition" in
    *"$AGENT_COMPOSE_FILE"*|*"$RUNTIME_REPO_ROOT/scripts/start-qr-login.sh"*|\
    *"start-qr-login.sh"*|*"$APPROVED_AGENT_PROJECT"*|\
    *"$APPROVED_AGENT_CONTAINER"*)
      return 0
      ;;
  esac
  if [[ "$definition" == *"WorkingDirectory=$RUNTIME_REPO_ROOT"* ]] &&
    { [[ "$definition" == *"docker compose"* ]] ||
      [[ "$definition" == *"docker-compose"* ]]; }; then
    return 0
  fi
  return 1
}

runtime_systemd_unit_name_is_valid() {
  local unit="$1" remainder

  [ -n "$unit" ] && [ "${#unit}" -le 255 ] || return 1
  case "$unit" in
    *.service|*.timer|*.path|*.socket|*.target|*.device|*.mount|\
    *.automount|*.swap|*.slice|*.scope) ;;
    *) return 1 ;;
  esac
  remainder="${unit%.*}"
  [ -n "$remainder" ] || return 1
  while [ -n "$remainder" ]; do
    case "$remainder" in
      \\x[0-9A-Fa-f][0-9A-Fa-f]*) remainder="${remainder:4}" ;;
      [A-Za-z0-9_.@:-]*) remainder="${remainder:1}" ;;
      *) return 1 ;;
    esac
  done
}

runtime_systemd_unit_name_references_agent_runtime() {
  case "${1,,}" in
    *agent-wechat*|*agent_wechat*|*wechat-agent*|*wechat_agent*) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_systemctl() {
  local -a clean_env

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    clean_env=(
      -u SYSTEMD_COLORS -u SYSTEMD_URLIFY -u SYSTEMD_PAGER
      -u SYSTEMD_PAGERSECURE -u SYSTEMD_LESS -u SYSTEMD_LOG_LEVEL
      -u SYSTEMD_LOG_TARGET -u SYSTEMD_LOG_TIME -u SYSTEMD_LOG_LOCATION
      -u SYSTEMD_LOG_TID -u SYSTEMD_UNIT_PATH
    )
  else
    clean_env=(
      -i HOME=/nonexistent
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      LANG=C.UTF-8 LC_ALL=C.UTF-8 SYSTEMD_PAGER=
    )
  fi
  runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" /usr/bin/env \
    "${clean_env[@]}" "$SYSTEMCTL_BIN" "$@"
}

runtime_capture_systemctl_probe() {
  local captured probe_status

  if captured="$(runtime_systemctl "$@" 2>/dev/null)"; then
    probe_status=0
  else
    probe_status=$?
  fi
  RUNTIME_SYSTEMCTL_PROBE_OUTPUT="$captured"
  RUNTIME_SYSTEMCTL_PROBE_STATUS="$probe_status"
  return 0
}

runtime_systemd_read_unit_definition() {
  local unit="$1"

  RUNTIME_SYSTEMD_UNIT_DEFINITION="$(
    runtime_systemctl cat "$unit" --no-pager 2>/dev/null
  )" || return 1
  [ -n "$RUNTIME_SYSTEMD_UNIT_DEFINITION" ]
}

runtime_systemd_show_unit_property() {
  local unit="$1" property="$2"

  RUNTIME_SYSTEMD_PROPERTY_VALUE="$(
    runtime_systemctl show "$unit" --property="$property" --value --no-pager 2>/dev/null
  )" || return 1
  case "$RUNTIME_SYSTEMD_PROPERTY_VALUE" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
}

runtime_systemd_set_agent_activation_error() {
  local activation_kind="$1"

  case "$activation_kind" in
    timer) LAST_ERROR="An enabled systemd timer could automatically start agent-wechat." ;;
    path) LAST_ERROR="An enabled systemd path unit could automatically start agent-wechat." ;;
    socket) LAST_ERROR="An enabled systemd socket could automatically start agent-wechat." ;;
    target) LAST_ERROR="An enabled systemd target could automatically start agent-wechat." ;;
    *) LAST_ERROR="An enabled or linked systemd unit could automatically start agent-wechat." ;;
  esac
  return 1
}

runtime_systemd_inspect_activation_target() {
  local activation_kind="$1" target="$2" expected_type="$3"

  if [ "$expected_type" = service ]; then
    case "$target" in
      *.service) ;;
      *)
        LAST_ERROR="Enabled systemd $activation_kind target must resolve to a service unit."
        return 1
        ;;
    esac
  fi
  case "$target" in
    *@.service|*%*)
      LAST_ERROR="Enabled systemd $activation_kind target uses unsupported templated activation."
      return 1
      ;;
  esac
  if ! runtime_systemd_unit_name_is_valid "$target"; then
    LAST_ERROR="Enabled systemd $activation_kind target is not a valid inspectable unit."
    return 1
  fi
  if runtime_systemd_unit_name_references_agent_runtime "$target"; then
    runtime_systemd_set_agent_activation_error "$activation_kind"
    return 1
  fi
  if ! runtime_systemd_read_unit_definition "$target"; then
    LAST_ERROR="Enabled systemd $activation_kind target definitions could not be inspected."
    return 1
  fi
  if runtime_unit_definition_starts_agent "$RUNTIME_SYSTEMD_UNIT_DEFINITION"; then
    runtime_systemd_set_agent_activation_error "$activation_kind"
    return 1
  fi
}

runtime_systemd_inspect_single_activation() {
  local unit="$1" property="$2" activation_kind="$3"
  local -a targets=()

  if ! runtime_systemd_show_unit_property "$unit" "$property"; then
    LAST_ERROR="Enabled systemd $activation_kind target could not be resolved safely."
    return 1
  fi
  read -r -a targets <<< "$RUNTIME_SYSTEMD_PROPERTY_VALUE"
  if [ "${#targets[@]}" -ne 1 ]; then
    LAST_ERROR="Enabled systemd $activation_kind target is missing or ambiguous."
    return 1
  fi
  runtime_systemd_inspect_activation_target \
    "$activation_kind" "${targets[0]}" service
}

runtime_systemd_inspect_target_dependencies() {
  local unit="$1" property dependency
  local -a dependencies=()

  for property in Wants Requires; do
    if ! runtime_systemd_show_unit_property "$unit" "$property"; then
      LAST_ERROR="Enabled systemd target dependencies could not be resolved safely."
      return 1
    fi
    [ -n "$RUNTIME_SYSTEMD_PROPERTY_VALUE" ] || continue
    read -r -a dependencies <<< "$RUNTIME_SYSTEMD_PROPERTY_VALUE"
    if [ "${#dependencies[@]}" -eq 0 ]; then
      LAST_ERROR="Enabled systemd target dependencies are malformed."
      return 1
    fi
    for dependency in "${dependencies[@]}"; do
      runtime_systemd_inspect_activation_target \
        target "$dependency" any || return 1
    done
    dependencies=()
  done
}

runtime_validate_startup_policy() {
  local state activity agent_activity enablement enabled_units active_units probe_status
  local socket_metadata unit unit_state loaded_state active_state sub_state
  local network_contract compose_version

  if [ "$CF_AGENT_WECHAT_TESTING" != "1" ]; then
    runtime_validate_management_file "$DOCKER_BIN" "Docker CLI" || return 1
    runtime_validate_management_file "$SYSTEMCTL_BIN" "systemctl" || return 1
  fi
  if runtime_privileged test -L "$DOCKER_SOCKET_PATH" ||
    ! runtime_privileged test -S "$DOCKER_SOCKET_PATH"; then
    LAST_ERROR="Docker socket must be the approved non-symlink Unix socket."
    return 1
  fi
  if ! socket_metadata="$(runtime_privileged stat -Lc '%u:%a' -- "$DOCKER_SOCKET_PATH")"; then
    LAST_ERROR="Docker socket metadata could not be inspected."
    return 1
  fi
  case "$socket_metadata" in
    0:600|0:660) ;;
    *)
      LAST_ERROR="Docker socket must be root-owned with mode 600 or 660."
      return 1
      ;;
  esac

  runtime_capture_systemctl_probe is-system-running
  state="$RUNTIME_SYSTEMCTL_PROBE_OUTPUT"
  probe_status="$RUNTIME_SYSTEMCTL_PROBE_STATUS"
  case "${state}:${probe_status}" in
    running:0|degraded:1) ;;
    *)
      LAST_ERROR="systemd state probe failed or systemd is not running or degraded before fresh QR."
      return 1
      ;;
  esac
  runtime_capture_systemctl_probe is-active docker.service
  activity="$RUNTIME_SYSTEMCTL_PROBE_OUTPUT"
  probe_status="$RUNTIME_SYSTEMCTL_PROBE_STATUS"
  if [ "$activity" != "active" ] || [ "$probe_status" -ne 0 ]; then
    LAST_ERROR="docker.service must be active before fresh QR."
    return 1
  fi
  runtime_capture_systemctl_probe is-active cf-agent-wechat.service
  agent_activity="$RUNTIME_SYSTEMCTL_PROBE_OUTPUT"
  probe_status="$RUNTIME_SYSTEMCTL_PROBE_STATUS"
  case "${agent_activity}:${probe_status}" in
    inactive:3|failed:3) ;;
    active:0|activating:0|reloading:0|deactivating:0)
      LAST_ERROR="cf-agent-wechat.service must be inactive before fresh QR."
      return 1
      ;;
    *)
      LAST_ERROR="cf-agent-wechat.service activity probe failed or returned an unsafe state."
      return 1
      ;;
  esac
  runtime_capture_systemctl_probe is-enabled cf-agent-wechat.service
  enablement="$RUNTIME_SYSTEMCTL_PROBE_OUTPUT"
  probe_status="$RUNTIME_SYSTEMCTL_PROBE_STATUS"
  case "$enablement" in
    enabled|enabled-runtime|linked|linked-runtime|alias)
      if [ "$probe_status" -ne 0 ]; then
        LAST_ERROR="cf-agent-wechat.service enablement probe failed."
        return 1
      fi
      LAST_ERROR="cf-agent-wechat.service must not be enabled."
      return 1
      ;;
    disabled|static|masked|indirect|generated|transient)
      if [ "$probe_status" -ne 1 ]; then
        LAST_ERROR="cf-agent-wechat.service enablement probe failed."
        return 1
      fi
      ;;
    not-found)
      if [ "$probe_status" -ne 1 ] && [ "$probe_status" -ne 4 ]; then
        LAST_ERROR="cf-agent-wechat.service enablement probe failed."
        return 1
      fi
      ;;
    *)
      LAST_ERROR="cf-agent-wechat.service enablement could not be determined safely."
      return 1
      ;;
  esac
  if ! enabled_units="$(runtime_systemctl list-unit-files \
    --type=service,timer,path,socket,target \
    --state=enabled,enabled-runtime,linked,linked-runtime,alias \
    --no-legend --no-pager 2>/dev/null)"; then
    LAST_ERROR="Enabled or linked systemd units could not be inspected."
    return 1
  fi
  while read -r unit unit_state _; do
    [ -n "$unit" ] || continue
    case "$unit_state" in
      enabled|enabled-runtime|linked|linked-runtime|alias) ;;
      *)
        LAST_ERROR="Enabled systemd unit inventory returned an unexpected state."
        return 1
        ;;
    esac
    case "$unit" in
      *.service|*.timer|*.path|*.socket|*.target) ;;
      *)
        LAST_ERROR="Enabled systemd unit inventory returned an unsupported unit type."
        return 1
        ;;
    esac
    if ! runtime_systemd_unit_name_is_valid "$unit"; then
      LAST_ERROR="Enabled systemd unit inventory returned an invalid unit name."
      return 1
    fi
    if runtime_systemd_unit_name_references_agent_runtime "$unit"; then
      LAST_ERROR="An unapproved enabled or linked agent-wechat unit was detected."
      return 1
    fi
    if ! runtime_systemd_read_unit_definition "$unit"; then
      LAST_ERROR="Enabled or linked systemd unit definitions could not be inspected."
      return 1
    fi
    if runtime_unit_definition_starts_agent "$RUNTIME_SYSTEMD_UNIT_DEFINITION"; then
      LAST_ERROR="An enabled or linked systemd unit could automatically start agent-wechat."
      return 1
    fi
    case "$unit" in
      *.timer)
        runtime_systemd_inspect_single_activation "$unit" Unit timer || return 1
        ;;
      *.path)
        runtime_systemd_inspect_single_activation "$unit" Unit path || return 1
        ;;
      *.socket)
        runtime_systemd_inspect_single_activation "$unit" Service socket || return 1
        ;;
      *.target)
        runtime_systemd_inspect_target_dependencies "$unit" || return 1
        ;;
    esac
  done <<< "$enabled_units"

  if ! active_units="$(runtime_systemctl list-units \
    --type=service,timer,path,socket,target \
    --state=active,activating,reloading \
    --plain --no-legend --no-pager 2>/dev/null)"; then
    LAST_ERROR="Active systemd units could not be inspected."
    return 1
  fi
  while read -r unit loaded_state active_state sub_state _; do
    [ -n "$unit" ] || continue
    if [ "$loaded_state" != "loaded" ]; then
      LAST_ERROR="Active systemd unit inventory returned an unexpected load state."
      return 1
    fi
    case "$active_state" in
      active|activating|reloading) ;;
      *)
        LAST_ERROR="Active systemd unit inventory returned an unexpected activity state."
        return 1
        ;;
    esac
    [ -n "$sub_state" ] || {
      LAST_ERROR="Active systemd unit inventory returned an incomplete state."
      return 1
    }
    case "$unit" in
      *.service|*.timer|*.path|*.socket|*.target) ;;
      *)
        LAST_ERROR="Active systemd unit inventory returned an unsupported unit type."
        return 1
        ;;
    esac
    if ! runtime_systemd_unit_name_is_valid "$unit"; then
      LAST_ERROR="Active systemd unit inventory returned an invalid unit name."
      return 1
    fi
    if runtime_systemd_unit_name_references_agent_runtime "$unit"; then
      LAST_ERROR="An unapproved active agent-wechat unit was detected."
      return 1
    fi
    if ! runtime_systemd_read_unit_definition "$unit"; then
      LAST_ERROR="Active systemd unit definitions could not be inspected."
      return 1
    fi
    if runtime_unit_definition_starts_agent "$RUNTIME_SYSTEMD_UNIT_DEFINITION"; then
      LAST_ERROR="An active systemd unit could supervise agent-wechat."
      return 1
    fi
    case "$unit" in
      *.timer)
        runtime_systemd_inspect_single_activation "$unit" Unit timer || return 1
        ;;
      *.path)
        runtime_systemd_inspect_single_activation "$unit" Unit path || return 1
        ;;
      *.socket)
        runtime_systemd_inspect_single_activation "$unit" Service socket || return 1
        ;;
      *.target)
        runtime_systemd_inspect_target_dependencies "$unit" || return 1
        ;;
    esac
  done <<< "$active_units"

  if ! compose_version="$(runtime_docker compose version --short 2>/dev/null)" ||
    ! [[ "$compose_version" =~ ^v?2[.] ]]; then
    LAST_ERROR="Docker Compose v2 is required."
    return 1
  fi
  if ! network_contract="$(runtime_docker network inspect --format '{{.Name}}|{{.Driver}}|{{.Scope}}' cf-internal 2>/dev/null)" ||
    [ "$network_contract" != "cf-internal|bridge|local" ]; then
    LAST_ERROR="cf-internal must remain the approved local bridge network."
    return 1
  fi
}

runtime_docker() {
  local -a clean_env

  validate_testing_docker_isolation || return 1
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    mapfile -t clean_env < <(runtime_compose_clean_env)
  else
    clean_env=(
      -i HOME=/nonexistent
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      LANG=C.UTF-8 LC_ALL=C.UTF-8 DOCKER_CONFIG=/nonexistent
    )
  fi
  if [ "$RUNTIME_DOCKER_USES_SUDO" -eq 1 ]; then
    if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
      LAST_ERROR="Testing Docker fake must never execute through sudo."
      return 1
    fi
    runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" \
      sudo -n -- /usr/bin/env "${clean_env[@]}" "$DOCKER_BIN" "$@"
  else
    runtime_with_timeout "$DOCKER_COMMAND_TIMEOUT" \
      /usr/bin/env "${clean_env[@]}" "$DOCKER_BIN" "$@"
  fi
}

runtime_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n -- "$@"
  fi
}

runtime_privileged_isolated_python() {
  local seconds="$1"
  shift
  runtime_privileged "$TIMEOUT_BIN" \
    --signal=TERM --kill-after=2s "${seconds}s" \
    /usr/bin/env -i \
    HOME=/nonexistent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    CF_AGENT_WECHAT_TESTING="$CF_AGENT_WECHAT_TESTING" \
    /usr/bin/python3 -I "$@"
}

runtime_capture_compose_snapshot() {
  local path="$1"
  local label="$2"
  local output_name="$3"
  local encoded

  if ! encoded="$(runtime_privileged_isolated_python \
    "$DOCKER_COMMAND_TIMEOUT" -c '
import base64
import os
import stat
import sys

path = sys.argv[1]
limit = 1024 * 1024
before = os.lstat(path)
if (
    not stat.S_ISREG(before.st_mode)
    or before.st_nlink != 1
    or before.st_size <= 0
    or before.st_size > limit
):
    raise SystemExit(2)
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
flags |= getattr(os, "O_NONBLOCK", 0)
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or (opened.st_dev, opened.st_ino)
        != (before.st_dev, before.st_ino)
        or opened.st_size != before.st_size
    ):
        raise SystemExit(2)
    chunks = []
    total = 0
    while True:
        chunk = os.read(descriptor, min(65536, limit + 1 - total))
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise SystemExit(2)
        chunks.append(chunk)
    final = os.fstat(descriptor)
    if (
        total != opened.st_size
        or final.st_size != opened.st_size
        or final.st_mtime_ns != opened.st_mtime_ns
        or final.st_ctime_ns != opened.st_ctime_ns
    ):
        raise SystemExit(2)
    sys.stdout.write(base64.b64encode(b"".join(chunks)).decode("ascii"))
finally:
    os.close(descriptor)
' "$path" 2>/dev/null)" || [ -z "$encoded" ]; then
    LAST_ERROR="${label} could not be bound to a stable no-follow snapshot."
    return 1
  fi
  printf -v "$output_name" '%s' "$encoded"
}

runtime_prepare_compose_snapshots() {
  runtime_capture_compose_snapshot \
    "$AGENT_COMPOSE_FILE" "agent-wechat Compose" \
    AGENT_COMPOSE_SNAPSHOT || return 1
  runtime_capture_compose_snapshot \
    "$GATEWAY_COMPOSE_FILE" "Gateway Compose" \
    GATEWAY_COMPOSE_SNAPSHOT || return 1
}

runtime_verify_compose_snapshots_unchanged() {
  local current_agent_snapshot current_gateway_snapshot

  runtime_capture_compose_snapshot \
    "$AGENT_COMPOSE_FILE" "agent-wechat Compose" \
    current_agent_snapshot || return 1
  if [ "$current_agent_snapshot" != "$AGENT_COMPOSE_SNAPSHOT" ]; then
    current_agent_snapshot=""
    LAST_ERROR="agent-wechat Compose changed during the fresh QR operation."
    return 1
  fi
  current_agent_snapshot=""

  runtime_capture_compose_snapshot \
    "$GATEWAY_COMPOSE_FILE" "Gateway Compose" \
    current_gateway_snapshot || return 1
  if [ "$current_gateway_snapshot" != "$GATEWAY_COMPOSE_SNAPSHOT" ]; then
    current_gateway_snapshot=""
    LAST_ERROR="Gateway Compose changed during the fresh QR operation."
    return 1
  fi
  current_gateway_snapshot=""
}

runtime_revalidate_start_gate() {
  runtime_verify_compose_snapshots_unchanged || return 1
  runtime_select_docker || return 1
  runtime_validate_startup_policy || return 1
  runtime_attest_agent_compose || return 1
}

runtime_select_compose_access() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if [ -r "$AGENT_COMPOSE_FILE" ] && [ -r "$AGENT_ENV_FILE" ] &&
    [ -r "$GATEWAY_COMPOSE_FILE" ] && [ -r "$GATEWAY_ENV_FILE" ]; then
    return 0
  fi
  runtime_authorize_sudo || return 1
  RUNTIME_COMPOSE_USES_SUDO=1
}



runtime_compose_clean_env() {
  local name
  local -a names=(
    DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
    AGENT_WECHAT_IMAGE AGENT_WECHAT_BIND_IP AGENT_WECHAT_PORT
    COMPOSE_FILE COMPOSE_PROFILES COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR
    COMPOSE_PROJECT_DIR COMPOSE_PARALLEL_LIMIT COMPOSE_IGNORE_ORPHANS
    COMPOSE_REMOVE_ORPHANS COMPOSE_STATUS_STDOUT COMPOSE_ANSI
    COMPOSE_PROGRESS COMPOSE_EXPERIMENTAL COMPOSE_MENU DOCKER_CONFIG
    BUILDX_BUILDER
    AGENT_WECHAT_CONTAINER_NAME COMPOSE_PROJECT_NAME
    CF_AGENT_WECHAT_STORAGE_ROOT CF_AGENT_WECHAT_RUNTIME_ROOT
    CF_AGENT_WECHAT_ARCHIVE_ROOT CF_AGENT_WECHAT_TOKEN_FILE
    CF_AGENT_WECHAT_TOKEN TOKEN_FILE API_URL WS_URL SESSION_ID
    CONTAINER_NAME AUTH_TOKEN PROXY RUST_LOG
    CF_GATEWAY_CONFIG CF_AGENT_GATEWAY_DATABASE_URL
    CF_GATEWAY_STARTUP_MIGRATION_MODE CF_GATEWAY_LOG_LEVEL
    CF_GATEWAY_API_TOKEN CF_AGENT_GATEWAY_ADMIN_TOKEN
    CF_GATEWAY_WORKER_CONCURRENCY CF_GATEWAY_WORKER_LEASE_SECONDS
    CF_GATEWAY_WORKER_RETRY_LIMIT
    CF_GATEWAY_WORKER_HEARTBEAT_INTERVAL_SECONDS
    CF_GATEWAY_WORKER_HEARTBEAT_MAX_AGE_SECONDS
    CF_GATEWAY_RUNTIME_HEARTBEAT_MAX_AGE_SECONDS
    CF_AGENT_WECHAT_TOKEN HERMES_API_KEY CF_GATEWAY_IMAGE
    CF_GATEWAY_ENV_FILE CF_GATEWAY_CONFIG_FILE CF_GATEWAY_BIND_ADDRESS
    CF_GATEWAY_PORT CF_GATEWAY_STOP_GRACE_PERIOD
    CF_GATEWAY_LOG_MAX_SIZE CF_GATEWAY_LOG_MAX_FILES
    CF_GATEWAY_DATABASE_URL CF_GATEWAY_BIND_IP
    CF_GATEWAY_WORKER_HEARTBEAT_FILE CF_GATEWAY_WORKER_HEARTBEAT_MAX_AGE
    HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
    NO_PROXY no_proxy
  )
  for name in "${names[@]}"; do
    printf '%s\n' -u "$name"
  done
}

agent_compose() {
  local -a clean_env=()
  local -a compose_command=(
    "$DOCKER_BIN" compose --env-file /dev/null
    --project-directory "$RUNTIME_REPO_ROOT"
    --project-name "$APPROVED_AGENT_PROJECT" -f -
  )
  if [ -z "$AGENT_COMPOSE_SNAPSHOT" ]; then
    LAST_ERROR="agent-wechat Compose snapshot is unavailable."
    return 1
  fi
  runtime_validate_testing_storage_isolation || return 1
  validate_testing_docker_isolation || return 1

  mapfile -t clean_env < <(runtime_compose_clean_env)
  if [ "$CF_AGENT_WECHAT_TESTING" != "1" ]; then
    clean_env=(
      -i HOME=/nonexistent
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      LANG=C.UTF-8 LC_ALL=C.UTF-8
      DOCKER_CONFIG=/nonexistent
    )
  fi
  clean_env+=(
    "AGENT_WECHAT_IMAGE=$APPROVED_AGENT_IMAGE"
    "AGENT_WECHAT_BIND_IP=$AGENT_WECHAT_BIND_IP"
    "AGENT_WECHAT_PORT=$AGENT_WECHAT_PUBLISHED_PORT"
    "AGENT_WECHAT_CONTAINER_NAME=$APPROVED_AGENT_CONTAINER"
    "COMPOSE_PROJECT_NAME=$APPROVED_AGENT_PROJECT"
    "CF_AGENT_WECHAT_STORAGE_ROOT=$STORAGE_ROOT"
    "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT"
    "CF_AGENT_WECHAT_ARCHIVE_ROOT=$ARCHIVE_ROOT"
    "PROXY=$APPROVED_PROXY"
    "RUST_LOG=$APPROVED_RUST_LOG"
  )
  if [ "$RUNTIME_DOCKER_USES_SUDO" -eq 1 ] ||
    [ "$RUNTIME_COMPOSE_USES_SUDO" -eq 1 ]; then
    printf '%s' "$AGENT_COMPOSE_SNAPSHOT" | /usr/bin/base64 --decode |
      runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" sudo -n -- /usr/bin/env \
      "${clean_env[@]}" "${compose_command[@]}" "$@"
  else
    printf '%s' "$AGENT_COMPOSE_SNAPSHOT" | /usr/bin/base64 --decode |
      runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" /usr/bin/env \
      "${clean_env[@]}" "${compose_command[@]}" "$@"
  fi
}

gateway_compose() {
  local -a clean_env=()
  local -a compose_command=(
    "$DOCKER_BIN" compose --env-file "$GATEWAY_ENV_FILE"
    --project-directory "$GATEWAY_PROJECT_DIR"
    --project-name "$GATEWAY_PROJECT_NAME" --profile worker
    -f -
  )
  if [ -z "$GATEWAY_COMPOSE_SNAPSHOT" ]; then
    LAST_ERROR="Gateway Compose snapshot is unavailable."
    return 1
  fi
  runtime_validate_testing_gateway_isolation || return 1
  validate_testing_docker_isolation || return 1

  mapfile -t clean_env < <(runtime_compose_clean_env)
  if [ "$CF_AGENT_WECHAT_TESTING" != "1" ]; then
    clean_env=(
      -i HOME=/nonexistent
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      LANG=C.UTF-8 LC_ALL=C.UTF-8
      DOCKER_CONFIG=/nonexistent
    )
  fi
  clean_env+=("CF_GATEWAY_ENV_FILE=$GATEWAY_ENV_FILE")
  if [ "$RUNTIME_DOCKER_USES_SUDO" -eq 1 ] ||
    [ "$RUNTIME_COMPOSE_USES_SUDO" -eq 1 ]; then
    printf '%s' "$GATEWAY_COMPOSE_SNAPSHOT" | /usr/bin/base64 --decode |
      runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" sudo -n -- /usr/bin/env \
      "${clean_env[@]}" "${compose_command[@]}" "$@"
  else
    printf '%s' "$GATEWAY_COMPOSE_SNAPSHOT" | /usr/bin/base64 --decode |
      runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" /usr/bin/env \
      "${clean_env[@]}" "${compose_command[@]}" "$@"
  fi
}

runtime_attest_agent_compose() {
  local config_json runtime_canonical token_canonical

  if ! config_json="$(agent_compose config --format json 2>/dev/null)"; then
    LAST_ERROR="agent-wechat Compose JSON configuration could not be inspected."
    return 1
  fi
  if ! runtime_canonical="$(runtime_canonical_path "$RUNTIME_ROOT")" ||
    ! token_canonical="$(runtime_canonical_path "$TOKEN_FILE")"; then
    LAST_ERROR="Runtime or Token paths could not be canonicalized."
    return 1
  fi
  if ! printf '%s' "$config_json" | run_isolated_python -c '
import json
import os
import sys

try:
    payload = json.load(sys.stdin)
    service = payload["services"]["agent-wechat"]
except (json.JSONDecodeError, KeyError, TypeError):
    raise SystemExit(2)
if not isinstance(payload.get("services"), dict) or set(payload["services"]) != {"agent-wechat"}:
    raise SystemExit(2)


expected_runtime = os.path.normpath(sys.argv[1])
expected_token = os.path.normpath(sys.argv[2])
expected_port = sys.argv[3]
expected_image = sys.argv[4]
expected_container = sys.argv[5]
expected_project = sys.argv[6]
expected_bind_ip = sys.argv[7]
expected_proxy = sys.argv[8]
expected_rust_log = sys.argv[9]
expected_service_keys = {
    "cap_add",
    "container_name",
    "environment",
    "healthcheck",
    "image",
    "logging",
    "networks",
    "ports",
    "restart",
    "security_opt",
    "stop_grace_period",
    "volumes",
}
if set(service) != expected_service_keys:
    raise SystemExit(2)
image = service.get("image")
if payload.get("name") != expected_project:
    raise SystemExit(2)
if image != expected_image or service.get("container_name") != expected_container:
    raise SystemExit(2)
if service.get("restart") != "no":
    raise SystemExit(2)

volumes = service.get("volumes")
if not isinstance(volumes, list) or len(volumes) != 3:
    raise SystemExit(2)
by_target = {
    volume.get("target"): volume
    for volume in volumes
    if isinstance(volume, dict) and isinstance(volume.get("target"), str)
}
if set(by_target) != {"/data", "/home/wechat", "/data/auth-token"}:
    raise SystemExit(2)
for target, source, read_only in (
    ("/data", os.path.join(expected_runtime, "data"), False),
    ("/home/wechat", os.path.join(expected_runtime, "wechat-home"), False),
    ("/data/auth-token", expected_token, True),
):
    mount = by_target[target]
    bind_options = mount.get("bind")
    if not isinstance(bind_options, dict) or bind_options != {"create_host_path": False}:
        raise SystemExit(2)

    if (
        mount.get("type") != "bind"
        or os.path.normpath(str(mount.get("source", ""))) != source
        or bool(mount.get("read_only", False)) is not read_only
        or bind_options.get("create_host_path") is not False
    ):
        raise SystemExit(2)

ports = service.get("ports")
if not isinstance(ports, list) or len(ports) != 1:
    raise SystemExit(2)
port = ports[0]
if not isinstance(port, dict) or (
    str(port.get("target")) != "6174"
    or str(port.get("published")) != expected_port
    or port.get("host_ip") != expected_bind_ip
    or port.get("protocol") != "tcp"
):
    raise SystemExit(2)

environment = service.get("environment")
expected_environment = {
    "AGENT_HOST": "0.0.0.0",
    "AGENT_PORT": "6174",
    "AGENT_DB_PATH": "/data/agent.db",
    "ENABLE_VNC": "0",
    "PROXY": expected_proxy,
    "RUST_LOG": expected_rust_log,
}
if (
    not isinstance(environment, dict)
    or {str(key): str(value) for key, value in environment.items()}
    != expected_environment
):
    raise SystemExit(2)

networks = service.get("networks")
network = networks.get("cf-internal") if isinstance(networks, dict) else None
if not isinstance(networks, dict) or set(networks) != {"cf-internal"}:
    raise SystemExit(2)
if not isinstance(network, dict) or set(network.get("aliases", [])) != {"cf-agent-wechat"}:
    raise SystemExit(2)
top_networks = payload.get("networks")
top_network = top_networks.get("cf-internal") if isinstance(top_networks, dict) else None
if not isinstance(top_networks, dict) or set(top_networks) != {"cf-internal"}:
    raise SystemExit(2)
if not isinstance(top_network, dict) or top_network.get("external") is not True or top_network.get("name") != "cf-internal":
    raise SystemExit(2)

health = service.get("healthcheck")
if not isinstance(health, dict):
    raise SystemExit(2)
if health.get("test") != ["CMD", "curl", "--fail", "--silent", "--show-error", "http://127.0.0.1:6174/health"]:
    raise SystemExit(2)
if health.get("interval") != "30s" or health.get("timeout") != "5s" or health.get("retries") != 5 or health.get("start_period") != "1m30s":
    raise SystemExit(2)
if service.get("security_opt") != ["seccomp=unconfined"]:
    raise SystemExit(2)
if service.get("cap_add") != ["SYS_PTRACE"]:
    raise SystemExit(2)
if service.get("privileged") not in (None, False):
    raise SystemExit(2)
for forbidden_key in (
    "devices",
    "device_cgroup_rules",
    "pid",
    "ipc",
    "uts",
    "userns_mode",
):
    if service.get(forbidden_key) not in (None, "", [], {}):
        raise SystemExit(2)
if service.get("stop_grace_period") != "30s":
    raise SystemExit(2)
logging = service.get("logging")
if not isinstance(logging, dict) or logging.get("driver") != "json-file":
    raise SystemExit(2)
options = logging.get("options")
if not isinstance(options, dict) or (
    str(options.get("max-size")) != "20m"
    or str(options.get("max-file")) != "3"
):
    raise SystemExit(2)
' "$runtime_canonical" "$token_canonical" "$AGENT_WECHAT_PUBLISHED_PORT" \
    "$APPROVED_AGENT_IMAGE" "$APPROVED_AGENT_CONTAINER" \
    "$APPROVED_AGENT_PROJECT" "$AGENT_WECHAT_BIND_IP" \
    "$APPROVED_PROXY" "$APPROVED_RUST_LOG" >/dev/null; then
    LAST_ERROR="Rendered agent-wechat Compose violates the production attestation contract."
    return 1
  fi
  # Consumed by start-qr-login.sh after this helper is sourced.
  # shellcheck disable=SC2034
  AGENT_IMAGE_DIGEST="$APPROVED_AGENT_IMAGE"
}

runtime_attest_actual_agent_container() {
  local expected_state="${1:-running}"
  local expected_id="${2:-}"
  local container_ids container_id inspect_json image_inspect_json
  local runtime_canonical token_canonical

  case "$expected_state" in
    created|running) ;;
    *)
      LAST_ERROR="Agent container attestation state is invalid."
      return 1
      ;;
  esac
  if [ -z "${AUTH_TOKEN:-}" ]; then
    LAST_ERROR="Agent Token is unavailable for exact container attestation."
    return 1
  fi
  if ! container_ids="$(agent_compose ps --all --quiet agent-wechat 2>/dev/null)" ||
    [ -z "$container_ids" ] ||
    [ "${container_ids//$'\n'/}" != "$container_ids" ]; then
    LAST_ERROR="Exactly one agent-wechat container must exist for attestation."
    return 1
  fi
  container_id="$container_ids"
  if ! [[ "$container_id" =~ ^[0-9a-f]{12,64}$ ]]; then
    LAST_ERROR="The agent-wechat container identity is malformed."
    return 1
  fi
  if [ -n "$expected_id" ] && [ "$container_id" != "$expected_id" ]; then
    LAST_ERROR="The attested agent-wechat container identity changed."
    return 1
  fi
  if ! inspect_json="$(runtime_docker inspect "$container_id" 2>/dev/null)"; then
    LAST_ERROR="The created agent-wechat container could not be inspected."
    return 1
  fi
  if [[ "$inspect_json" == *"$AUTH_TOKEN"* ]]; then
    inspect_json=""
    image_inspect_json=""
    LAST_ERROR="Created agent-wechat container violates the exact production runtime contract."
    return 1
  fi
  if ! image_inspect_json="$(runtime_docker image inspect \
    "$APPROVED_AGENT_IMAGE" 2>/dev/null)"; then
    inspect_json=""
    LAST_ERROR="The approved agent-wechat image baseline could not be inspected."
    return 1
  fi
  if [[ "$image_inspect_json" == *"$AUTH_TOKEN"* ]]; then
    inspect_json=""
    image_inspect_json=""
    LAST_ERROR="Created agent-wechat container violates the exact production runtime contract."
    return 1
  fi
  if ! runtime_canonical="$(runtime_canonical_path "$RUNTIME_ROOT")" ||
    ! token_canonical="$(runtime_canonical_path "$TOKEN_FILE")"; then
    inspect_json=""
    image_inspect_json=""
    LAST_ERROR="Runtime or Token paths could not be canonicalized for container attestation."
    return 1
  fi
  if ! printf '{"container":%s,"image":%s}' "$inspect_json" "$image_inspect_json" | run_isolated_python -c '
import json
import os
import sys

try:
    envelope = json.load(sys.stdin)
    payload = envelope["container"]
    image_payload = envelope["image"]
    item = payload[0]
    config = item["Config"]
    host = item["HostConfig"]
    state = item["State"]
    network_settings = item["NetworkSettings"]
    image_item = image_payload[0]
    image_config = image_item["Config"]
except (json.JSONDecodeError, KeyError, IndexError, TypeError):
    raise SystemExit(2)

expected_runtime = os.path.normpath(sys.argv[1])
expected_token = os.path.normpath(sys.argv[2])
expected_image = sys.argv[3]
expected_container = sys.argv[4]
expected_project = sys.argv[5]
expected_bind_ip = sys.argv[6]
expected_port = sys.argv[7]
expected_proxy = sys.argv[8]
expected_rust_log = sys.argv[9]
expected_state = sys.argv[10]
expected_container_id = sys.argv[11]

if expected_state not in {"created", "running"}:
    raise SystemExit(2)
if not isinstance(state, dict) or state.get("Running") is not (
    expected_state == "running"
):
    raise SystemExit(2)
if state.get("Status") != expected_state:
    raise SystemExit(2)
for boolean_key in ("Restarting", "Paused", "Dead", "OOMKilled"):
    if state.get(boolean_key) is not False:
        raise SystemExit(2)
exit_code = state.get("ExitCode")
if isinstance(exit_code, bool) or exit_code != 0:
    raise SystemExit(2)
restart_count = item.get("RestartCount")
if isinstance(restart_count, bool) or restart_count != 0:
    raise SystemExit(2)
if item.get("Id") != expected_container_id:
    raise SystemExit(2)
if item.get("Name") != "/" + expected_container:
    raise SystemExit(2)
if config.get("Image") != expected_image:
    raise SystemExit(2)
if item.get("Image") != image_item.get("Id"):
    raise SystemExit(2)
repo_digests = image_item.get("RepoDigests")
if not isinstance(repo_digests, list) or expected_image not in repo_digests:
    raise SystemExit(2)
for process_field in ("Entrypoint", "Cmd", "User", "WorkingDir", "StopSignal"):
    if config.get(process_field) != image_config.get(process_field):
        raise SystemExit(2)
if config.get("StopTimeout") != 30:
    raise SystemExit(2)
healthcheck = config.get("Healthcheck")
expected_healthcheck = {
    "Test": [
        "CMD",
        "curl",
        "--fail",
        "--silent",
        "--show-error",
        "http://127.0.0.1:6174/health",
    ],
    "Interval": 30_000_000_000,
    "Timeout": 5_000_000_000,
    "Retries": 5,
    "StartPeriod": 90_000_000_000,
}
if not isinstance(healthcheck, dict):
    raise SystemExit(2)
if healthcheck.get("StartInterval", 0) != 0:
    raise SystemExit(2)
healthcheck.pop("StartInterval", None)
if healthcheck != expected_healthcheck:
    raise SystemExit(2)
labels = config.get("Labels")
if not isinstance(labels, dict) or (
    labels.get("com.docker.compose.project") != expected_project
    or labels.get("com.docker.compose.service") != "agent-wechat"
):
    raise SystemExit(2)
restart = host.get("RestartPolicy")
if not isinstance(restart, dict) or (
    restart.get("Name") != "no"
    or int(restart.get("MaximumRetryCount", 0)) != 0
):
    raise SystemExit(2)
if host.get("Privileged") is not False:
    raise SystemExit(2)
if host.get("CapAdd") != ["SYS_PTRACE"]:
    raise SystemExit(2)
if host.get("SecurityOpt") != ["seccomp=unconfined"]:
    raise SystemExit(2)
for list_field in ("Devices", "DeviceRequests"):
    if host.get(list_field) not in (None, []):
        raise SystemExit(2)
for mode_field in ("PidMode", "UTSMode", "UsernsMode"):
    if host.get(mode_field) not in (None, ""):
        raise SystemExit(2)
if host.get("IpcMode") not in (None, "", "private"):
    raise SystemExit(2)
if host.get("CgroupnsMode") not in (None, "", "private"):
    raise SystemExit(2)
if host.get("NetworkMode") != "cf-internal":
    raise SystemExit(2)
if host.get("ReadonlyRootfs") is not False or host.get("AutoRemove") is not False:
    raise SystemExit(2)
expected_binds = {
    os.path.join(expected_runtime, "data") + ":/data:rw",
    os.path.join(expected_runtime, "wechat-home") + ":/home/wechat:rw",
    expected_token + ":/data/auth-token:ro",
}
binds = host.get("Binds")
if (
    not isinstance(binds, list)
    or len(binds) != len(expected_binds)
    or set(binds) != expected_binds
):
    raise SystemExit(2)
log_config = host.get("LogConfig")
if (
    not isinstance(log_config, dict)
    or log_config.get("Type") != "json-file"
    or log_config.get("Config")
    != {"max-size": "20m", "max-file": "3"}
):
    raise SystemExit(2)

mounts = item.get("Mounts")
if not isinstance(mounts, list) or len(mounts) != 3:
    raise SystemExit(2)
by_destination = {
    mount.get("Destination"): mount
    for mount in mounts
    if isinstance(mount, dict) and isinstance(mount.get("Destination"), str)
}
if set(by_destination) != {"/data", "/home/wechat", "/data/auth-token"}:
    raise SystemExit(2)
for destination, source, writable in (
    ("/data", os.path.join(expected_runtime, "data"), True),
    ("/home/wechat", os.path.join(expected_runtime, "wechat-home"), True),
    ("/data/auth-token", expected_token, False),
):
    mount = by_destination[destination]
    if (
        mount.get("Type") != "bind"
        or os.path.normpath(str(mount.get("Source", ""))) != source
        or bool(mount.get("RW")) is not writable
        or mount.get("Propagation") != "rprivate"
    ):
        raise SystemExit(2)

port_key = "6174/tcp"
network_ports = network_settings.get("Ports")
host_port_bindings = host.get("PortBindings")
if not isinstance(host_port_bindings, dict) or set(host_port_bindings) != {port_key}:
    raise SystemExit(2)
host_bindings = host_port_bindings[port_key]
if not isinstance(host_bindings, list) or len(host_bindings) != 1:
    raise SystemExit(2)
host_binding = host_bindings[0]
if not isinstance(host_binding, dict) or (
    host_binding.get("HostIp") != expected_bind_ip
    or str(host_binding.get("HostPort")) != expected_port
):
    raise SystemExit(2)
if expected_state == "created":
    if network_ports not in (None, {}, {port_key: None}):
        raise SystemExit(2)
else:
    if not isinstance(network_ports, dict):
        raise SystemExit(2)
    published_ports = {
        key: values
        for key, values in network_ports.items()
        if values is not None
    }
    if set(published_ports) != {port_key}:
        raise SystemExit(2)
    bindings = published_ports[port_key]
    if not isinstance(bindings, list) or len(bindings) != 1:
        raise SystemExit(2)
    binding = bindings[0]
    if not isinstance(binding, dict) or (
        binding.get("HostIp") != expected_bind_ip
        or str(binding.get("HostPort")) != expected_port
    ):
        raise SystemExit(2)

networks = network_settings.get("Networks")
if not isinstance(networks, dict) or set(networks) != {"cf-internal"}:
    raise SystemExit(2)
network = networks["cf-internal"]
aliases = network.get("Aliases") if isinstance(network, dict) else None
container_identity = item.get("Id")
if (
    not isinstance(network, dict)
    or not isinstance(aliases, list)
    or not isinstance(container_identity, str)
):
    raise SystemExit(2)
allowed_aliases = {
    "cf-agent-wechat",
    expected_container,
    "agent-wechat",
    container_identity,
    container_identity[:12],
}
if (
    "cf-agent-wechat" not in aliases
    or len(set(aliases)) != len(aliases)
    or any(
        not isinstance(alias, str) or alias not in allowed_aliases
        for alias in aliases
    )
):
    raise SystemExit(2)

def parse_environment(entries):
    if not isinstance(entries, list):
        raise SystemExit(2)
    parsed = {}
    for entry in entries:
        if not isinstance(entry, str) or "=" not in entry:
            raise SystemExit(2)
        key, value = entry.split("=", 1)
        if key in parsed:
            raise SystemExit(2)
        parsed[key] = value
    return parsed

image_environment = parse_environment(image_config.get("Env") or [])
expected_environment = dict(image_environment)
expected_environment.update(
    {
        "AGENT_HOST": "0.0.0.0",
        "AGENT_PORT": "6174",
        "AGENT_DB_PATH": "/data/agent.db",
        "ENABLE_VNC": "0",
        "PROXY": expected_proxy,
        "RUST_LOG": expected_rust_log,
    }
)
parsed_environment = parse_environment(config.get("Env"))
if (
    parsed_environment != expected_environment
    or any("TOKEN" in key.upper() for key in parsed_environment)
):
    raise SystemExit(2)
' "$runtime_canonical" "$token_canonical" "$APPROVED_AGENT_IMAGE" \
    "$APPROVED_AGENT_CONTAINER" "$APPROVED_AGENT_PROJECT" \
    "$AGENT_WECHAT_BIND_IP" "$AGENT_WECHAT_PUBLISHED_PORT" \
    "$APPROVED_PROXY" "$APPROVED_RUST_LOG" \
    "$expected_state" "$container_id" >/dev/null; then
    inspect_json=""
    image_inspect_json=""
    LAST_ERROR="Created agent-wechat container violates the exact production runtime contract."
    return 1
  fi
  inspect_json=""
  image_inspect_json=""
  # Bound across candidate creation, fresh QR verification, and final release.
  ATTESTED_AGENT_CONTAINER_ID="$container_id"
}

runtime_validate_configuration() {
  local command_name services
  local storage_canonical runtime_canonical archive_canonical token_canonical
  local lock_canonical
  local archive_parent runtime_parent lock_parent
  local archive_parent_device runtime_parent_device
  local required_file required_path value_name helper helper_mode
  local runtime_present=0 legacy_present=0

  reject_production_management_overrides || return 1
  runtime_validate_testing_isolation || return 1

  if [ -n "$RUNTIME_MANAGEMENT_ENV_ERROR" ]; then
    LAST_ERROR="$RUNTIME_MANAGEMENT_ENV_ERROR"
    return 1
  fi

  for command_name in \
    docker flock stat date mv install readlink awk "$CURL_BIN" mktemp mkdir chmod \
    chown rm sleep cksum sh dirname env id grep /bin/cat "$TIMEOUT_BIN"; do
    runtime_require_command "$command_name" || return 1
  done
  runtime_authorize_sudo || return 1
  runtime_validate_trusted_tmp_root || return 1

  for value_name in \
    RUNTIME_DEFAULT_UID RUNTIME_DEFAULT_GID SERVER_READY_TIMEOUT \
    WECHAT_READY_TIMEOUT WECHAT_STABLE_SECONDS POST_LOGIN_READY_TIMEOUT \
    RUNTIME_POLL_INTERVAL DOCKER_COMMAND_TIMEOUT COMPOSE_COMMAND_TIMEOUT \
    WORKER_READY_TIMEOUT WORKER_STABLE_SECONDS WORKER_HEARTBEAT_TIMEOUT TOKEN_SCAN_TIMEOUT ARCHIVE_TOOL_TIMEOUT; do
    runtime_validate_uint "$value_name" "${!value_name}" || return 1
  done
  if ! runtime_validate_mode "$RUNTIME_DEFAULT_MODE"; then
    LAST_ERROR="CF_AGENT_WECHAT_RUNTIME_MODE must be an octal mode."
    return 1
  fi
  if [ "$RUNTIME_POLL_INTERVAL" -eq 0 ]; then
    LAST_ERROR="RUNTIME_POLL_INTERVAL must be greater than zero."
    return 1
  fi
  if [ "$SERVER_READY_TIMEOUT" -eq 0 ] || [ "$WECHAT_READY_TIMEOUT" -eq 0 ] ||
    [ "$WECHAT_STABLE_SECONDS" -eq 0 ] ||
    [ "$POST_LOGIN_READY_TIMEOUT" -eq 0 ] ||
    [ "$DOCKER_COMMAND_TIMEOUT" -eq 0 ] ||
    [ "$COMPOSE_COMMAND_TIMEOUT" -eq 0 ] ||
    [ "$WORKER_READY_TIMEOUT" -eq 0 ] ||
    [ "$TOKEN_SCAN_TIMEOUT" -eq 0 ] ||
    [ "$ARCHIVE_TOOL_TIMEOUT" -eq 0 ] ||
    [ "$WORKER_HEARTBEAT_TIMEOUT" -eq 0 ]; then
    LAST_ERROR="Runtime readiness timeouts must be greater than zero."
    return 1
  fi

  case "$AGENT_ENV_FILE" in
    /*) ;;
    *)
      LAST_ERROR="agent-wechat environment file path must be absolute: $AGENT_ENV_FILE"
      return 1
      ;;
  esac
  for required_path in "$RUNTIME_REPO_ROOT" "$RUNTIME_SCRIPTS_DIR" \
    "${RUNTIME_REPO_ROOT}/docker" "$AGENT_COMPOSE_FILE" \
    "$AGENT_ENV_FILE"; do
    runtime_validate_no_symlink_ancestors \
      "$required_path" "Production management path" || return 1
  done
  if runtime_privileged test -L "$AGENT_ENV_FILE" ||
    ! runtime_privileged test -f "$AGENT_ENV_FILE"; then
    LAST_ERROR="agent-wechat environment file must be an existing non-symlink regular file: $AGENT_ENV_FILE"
    return 1
  fi
  runtime_validate_management_directory \
    "$RUNTIME_REPO_ROOT" "Repository root" || return 1
  runtime_validate_management_directory \
    "$RUNTIME_SCRIPTS_DIR" "Management scripts directory" || return 1
  runtime_validate_management_directory \
    "${RUNTIME_REPO_ROOT}/docker" "Production configuration directory" || return 1
  runtime_validate_management_file \
    "$AGENT_COMPOSE_FILE" "agent-wechat Compose" "644 0644" || return 1
  runtime_validate_management_file \
    "$AGENT_ENV_FILE" "agent-wechat environment file" "600 0600 640 0640" || return 1
  for helper in \
    bootstrap-cfserver.sh common.sh qr-runtime-common.sh start-qr-login.sh \
    stop-qr-runtime.sh status.sh login.sh qr_login.py \
    ensure-login-environment.sh verify_login_dependencies.py \
    archive-runtime.py scan_runtime_tree.py verify_gateway_contract.py \
    verify_management_source_secrets.py parse_management_env.py \
    requirements.txt; do
    runtime_validate_no_symlink_ancestors \
      "${RUNTIME_SCRIPTS_DIR}/${helper}" "Management helper" || return 1
    case "$helper" in
      requirements.txt) helper_mode="644 0644" ;;
      *) helper_mode="755 0755" ;;
    esac
    runtime_validate_management_file \
      "${RUNTIME_SCRIPTS_DIR}/${helper}" "Management helper ${helper}" \
      "$helper_mode" || return 1
  done
  if ! runtime_load_management_environment; then
    LAST_ERROR="${RUNTIME_MANAGEMENT_ENV_ERROR:-docker/.env could not be loaded.}"
    return 1
  fi
  runtime_validate_testing_isolation || return 1


  for required_path in \
    "$AGENT_COMPOSE_FILE" "$AGENT_ENV_FILE" "$STORAGE_ROOT" "$RUNTIME_ROOT" "$ARCHIVE_ROOT" \
    "$GATEWAY_COMPOSE_FILE" "$GATEWAY_PROJECT_DIR" "$GATEWAY_ENV_FILE" \
    "$GATEWAY_HEARTBEAT_COMMAND" "$GATEWAY_RELEASE_GATE_COMMAND" "$GATEWAY_CONTRACT_FILE" \
    "$GATEWAY_CONTRACT_VERIFIER" "$RUNTIME_TREE_SCANNER" "$ARCHIVE_RUNTIME_TOOL" "$MANAGEMENT_ENV_PARSER" "$TOKEN_FILE" \
    "$RUNTIME_LOCK_FILE"; do
    case "$required_path" in
      /*) ;;
      *)
        LAST_ERROR="Production paths must be absolute."
        return 1
        ;;
    esac
    runtime_validate_no_symlink_ancestors \
      "$required_path" "Production path" || return 1
  done

  for required_file in "$AGENT_COMPOSE_FILE" "$GATEWAY_COMPOSE_FILE"; do
    if runtime_privileged test -L "$required_file" ||
      ! runtime_privileged test -f "$required_file"; then
      LAST_ERROR="Required Compose file is missing or is a symlink."
      return 1
    fi
  done
  runtime_validate_management_directory \
    "$GATEWAY_PROJECT_DIR" "Gateway project directory" 1 || return 1
  runtime_validate_management_file \
    "$GATEWAY_COMPOSE_FILE" "Gateway Compose" || return 1
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    runtime_validate_management_file \
      "$GATEWAY_ENV_FILE" "Gateway environment" "600 0600" || return 1
  else
    runtime_validate_root_file \
      "$GATEWAY_ENV_FILE" "Gateway environment" 600 || return 1
  fi
  runtime_validate_management_file \
    "$GATEWAY_CONTRACT_VERIFIER" "Gateway contract verifier" || return 1
  runtime_validate_management_file \
    "$RUNTIME_TREE_SCANNER" "Runtime tree scanner" || return 1

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    runtime_validate_management_directory \
      "$STORAGE_ROOT" "Storage root" 1 || return 1
    runtime_validate_management_directory \
      "${STORAGE_ROOT}/secrets" "Secrets root" 1 || return 1
  else
    runtime_validate_root_directory "$STORAGE_ROOT" "Storage root" 755 || return 1
    runtime_validate_root_directory "${STORAGE_ROOT}/secrets" "Secrets root" 700 || return 1
  fi
  runtime_validate_directory_without_extended_attributes "$STORAGE_ROOT" "Storage root" ||
    return 1
  runtime_validate_directory_without_extended_attributes "${STORAGE_ROOT}/secrets" "Secrets root" ||
    return 1
  runtime_validate_directory_or_missing "$RUNTIME_ROOT" "Runtime path" || return 1
  runtime_validate_directory_or_missing "$ARCHIVE_ROOT" "Archive path" || return 1
  runtime_validate_directory_or_missing \
    "${RUNTIME_ROOT}/data" "Runtime data path" || return 1
  runtime_validate_directory_or_missing \
    "${RUNTIME_ROOT}/wechat-home" "Runtime WeChat HOME path" || return 1
  runtime_validate_directory_or_missing "$LEGACY_DATA_ROOT" "Legacy data path" || return 1
  runtime_validate_directory_or_missing \
    "$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME path" || return 1
  if ! storage_canonical="$(runtime_canonical_path "$STORAGE_ROOT")" ||
    ! runtime_canonical="$(runtime_canonical_path "$RUNTIME_ROOT")" ||
    ! archive_canonical="$(runtime_canonical_path "$ARCHIVE_ROOT")" ||
    ! token_canonical="$(runtime_canonical_path "$TOKEN_FILE")" ||
    ! lock_canonical="$(runtime_canonical_path "$RUNTIME_LOCK_FILE")"; then
    LAST_ERROR="Production paths could not be canonicalized."
    return 1
  fi
  if [ "$runtime_canonical" = "/" ] || [ "$archive_canonical" = "/" ] ||
    [ "$runtime_canonical" = "$archive_canonical" ] ||
    runtime_path_is_within "$runtime_canonical" "$archive_canonical" ||
    runtime_path_is_within "$archive_canonical" "$runtime_canonical"; then
    LAST_ERROR="Runtime and archive paths must be separate, non-nested directories."
    return 1
  fi
  if ! runtime_path_is_within "$runtime_canonical" "$storage_canonical" ||
    ! runtime_path_is_within "$archive_canonical" "$storage_canonical"; then
    LAST_ERROR="Runtime and archive paths must remain within the storage root."
    return 1
  fi
  if runtime_path_is_within "$lock_canonical" "$runtime_canonical" ||
    runtime_path_is_within "$lock_canonical" "$archive_canonical"; then
    LAST_ERROR="Runtime lock file must remain outside runtime and archive directories."
    return 1
  fi
  if runtime_path_is_within "$token_canonical" "$runtime_canonical" ||
    runtime_path_is_within "$token_canonical" "$archive_canonical"; then
    LAST_ERROR="Token path must remain outside runtime and archive directories."
    return 1
  fi
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    runtime_validate_management_file \
      "$TOKEN_FILE" "Agent Token" "600 0600" || return 1
  else
    runtime_validate_root_file "$TOKEN_FILE" "Agent Token" 600 || return 1
  fi
  runtime_assert_management_sources_have_no_auth_token || return 1
  runtime_validate_empty_token_mountpoint \
    "${RUNTIME_ROOT}/data/auth-token" "Runtime" || return 1
  runtime_validate_empty_token_mountpoint \
    "${LEGACY_DATA_ROOT}/auth-token" "Legacy data" || return 1

  if runtime_privileged test -d "$RUNTIME_ROOT"; then
    runtime_present=1
  fi
  if runtime_privileged test -d "$LEGACY_DATA_ROOT" ||
    runtime_privileged test -d "$LEGACY_WECHAT_HOME_ROOT"; then
    legacy_present=1
  fi
  if [ "$runtime_present" -eq 1 ] && [ "$legacy_present" -eq 1 ]; then
    LAST_ERROR="Both runtime and legacy data/wechat-home layouts exist; refusing to modify either layout."
    return 1
  fi
  runtime_validate_restricted_archive_root || return 1
  if [ "$runtime_present" -eq 1 ]; then
    runtime_validate_approved_runtime_directory \
      "$RUNTIME_ROOT" "Runtime root" 1 || return 1
    runtime_validate_approved_runtime_directory \
      "${RUNTIME_ROOT}/data" "Runtime data" 1 || return 1
    runtime_validate_approved_runtime_directory \
      "${RUNTIME_ROOT}/wechat-home" "Runtime WeChat HOME" 1 || return 1
  else
    runtime_validate_approved_runtime_directory \
      "$LEGACY_DATA_ROOT" "Legacy data" || return 1
    runtime_validate_approved_runtime_directory \
      "$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME" || return 1
  fi


  if ! runtime_parent="$(dirname -- "$RUNTIME_ROOT")" ||
    ! archive_parent="$(dirname -- "$ARCHIVE_ROOT")" ||
    ! lock_parent="$(dirname -- "$RUNTIME_LOCK_FILE")"; then
    LAST_ERROR="Production path parents could not be resolved."
    return 1
  fi
  if ! runtime_privileged test -d "$runtime_parent" ||
    ! runtime_privileged test -d "$archive_parent"; then
    LAST_ERROR="Runtime and archive parent directories must already exist."
    return 1
  fi
  runtime_validate_directory_without_extended_attributes "$runtime_parent" "Runtime parent" ||
    return 1
  runtime_validate_directory_without_extended_attributes "$archive_parent" "Archive parent" ||
    return 1
  runtime_validate_lock_parent "$lock_parent" || return 1
  if runtime_privileged test -L "$RUNTIME_LOCK_FILE" ||
    { runtime_privileged test -e "$RUNTIME_LOCK_FILE" &&
      ! runtime_privileged test -f "$RUNTIME_LOCK_FILE"; }; then
    LAST_ERROR="Runtime lock path must be a regular non-symlink file."
    return 1
  fi
  if ! runtime_parent_device="$(runtime_privileged stat -c '%d' -- "$runtime_parent")" ||
    ! archive_parent_device="$(runtime_privileged stat -c '%d' -- "$archive_parent")"; then
    LAST_ERROR="Runtime and archive filesystems could not be inspected."
    return 1
  fi
  if [ "$runtime_parent_device" != "$archive_parent_device" ]; then
    LAST_ERROR="Runtime and archive must be on the same filesystem."
    return 1
  fi

  runtime_select_compose_access || return 1
  runtime_prepare_compose_snapshots || return 1
  runtime_select_docker || return 1
  runtime_validate_startup_policy || return 1
  if ! agent_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="agent-wechat Compose configuration is invalid."
    return 1
  fi
  runtime_attest_agent_compose || return 1
  if ! gateway_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="Gateway Compose configuration is invalid."
    return 1
  fi
  if ! services="$(gateway_compose config --services 2>/dev/null)"; then
    LAST_ERROR="Gateway services could not be inspected."
    return 1
  fi
  if ! printf '%s\n' "$services" | awk -v service="$GATEWAY_SERVICE" '
    $0 == service { found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
    LAST_ERROR="Gateway Compose does not define the required wechat-worker service."
    return 1
  fi
}

runtime_validate_stop_configuration() {
  local command_name required_path required_file services lock_parent

  reject_production_management_overrides || return 1
  runtime_validate_testing_isolation || return 1

  if [ -n "$RUNTIME_MANAGEMENT_ENV_ERROR" ]; then
    LAST_ERROR="$RUNTIME_MANAGEMENT_ENV_ERROR"
    return 1
  fi

  for command_name in \
    docker flock readlink install stat awk chmod sh dirname env id \
    /bin/cat "$TIMEOUT_BIN"; do
    runtime_require_command "$command_name" || return 1
  done
  runtime_authorize_sudo || return 1
  runtime_validate_uint DOCKER_COMMAND_TIMEOUT "$DOCKER_COMMAND_TIMEOUT" || return 1
  runtime_validate_uint COMPOSE_COMMAND_TIMEOUT "$COMPOSE_COMMAND_TIMEOUT" || return 1
  if [ "$DOCKER_COMMAND_TIMEOUT" -eq 0 ] ||
    [ "$COMPOSE_COMMAND_TIMEOUT" -eq 0 ]; then
    LAST_ERROR="Docker and Compose timeouts must be greater than zero."
    return 1
  fi
  case "$AGENT_ENV_FILE" in
    /*) ;;
    *)
      LAST_ERROR="agent-wechat environment file path must be absolute: $AGENT_ENV_FILE"
      return 1
      ;;
  esac
  for required_path in "$RUNTIME_REPO_ROOT" "${RUNTIME_REPO_ROOT}/docker" \
    "$AGENT_COMPOSE_FILE" "$AGENT_ENV_FILE"; do
    runtime_validate_no_symlink_ancestors \
      "$required_path" "Production management path" || return 1
  done
  if runtime_privileged test -L "$AGENT_ENV_FILE" ||
    ! runtime_privileged test -f "$AGENT_ENV_FILE"; then
    LAST_ERROR="agent-wechat environment file must be an existing non-symlink regular file: $AGENT_ENV_FILE"
    return 1
  fi
  runtime_validate_management_directory \
    "$RUNTIME_REPO_ROOT" "Repository root" || return 1
  runtime_validate_management_directory \
    "${RUNTIME_REPO_ROOT}/docker" "Production configuration directory" || return 1
  runtime_validate_management_file \
    "$AGENT_COMPOSE_FILE" "agent-wechat Compose" "644 0644" || return 1
  runtime_validate_management_file \
    "$AGENT_ENV_FILE" "agent-wechat environment file" "600 0600 640 0640" || return 1
  if ! runtime_load_management_environment; then
    LAST_ERROR="${RUNTIME_MANAGEMENT_ENV_ERROR:-docker/.env could not be loaded.}"
    return 1
  fi
  runtime_validate_testing_isolation || return 1


  for required_path in \
    "$AGENT_COMPOSE_FILE" "$AGENT_ENV_FILE" "$STORAGE_ROOT" \
    "$RUNTIME_ROOT" "$ARCHIVE_ROOT" "$TOKEN_FILE" \
    "$GATEWAY_COMPOSE_FILE" "$GATEWAY_PROJECT_DIR" \
    "$GATEWAY_ENV_FILE" "$MANAGEMENT_SOURCE_SECRET_VERIFIER" \
    "$RUNTIME_LOCK_FILE"; do
    case "$required_path" in
      /*) ;;
      *)
        LAST_ERROR="Production control paths must be absolute."
        return 1
        ;;
    esac
    runtime_validate_no_symlink_ancestors \
      "$required_path" "Production control path" || return 1
  done
  for required_file in "$AGENT_COMPOSE_FILE" "$GATEWAY_COMPOSE_FILE"; do
    if runtime_privileged test -L "$required_file" ||
      ! runtime_privileged test -f "$required_file"; then
      LAST_ERROR="Required Compose file is missing or is a symlink."
      return 1
    fi
  done
  if runtime_privileged test -L "$GATEWAY_ENV_FILE" ||
    ! runtime_privileged test -f "$GATEWAY_ENV_FILE"; then
    LAST_ERROR="Gateway environment file must be an existing non-symlink regular file: $GATEWAY_ENV_FILE"
    return 1
  fi
  runtime_validate_management_file \
    "$GATEWAY_COMPOSE_FILE" "Gateway Compose" || return 1
  runtime_validate_management_file \
    "$GATEWAY_ENV_FILE" "Gateway environment file" "600 0600 640 0640" || return 1
  runtime_validate_management_file \
    "$MANAGEMENT_SOURCE_SECRET_VERIFIER" \
    "Management source Token verifier" "755 0755" || return 1
  runtime_assert_management_sources_have_no_auth_token || return 1
  if runtime_privileged test -L "$STORAGE_ROOT" ||
    ! runtime_privileged test -d "$STORAGE_ROOT"; then
    LAST_ERROR="Storage root must be an existing non-symlink directory."
    return 1
  fi
  runtime_validate_management_directory \
    "$STORAGE_ROOT" "Storage root" 1 || return 1
  runtime_validate_management_directory \
    "$GATEWAY_PROJECT_DIR" "Gateway project directory" 1 || return 1
  if ! lock_parent="$(dirname -- "$RUNTIME_LOCK_FILE")"; then
    LAST_ERROR="Runtime lock parent could not be resolved."
    return 1
  fi
  runtime_validate_lock_parent "$lock_parent" || return 1
  if runtime_privileged test -L "$RUNTIME_LOCK_FILE" ||
    { runtime_privileged test -e "$RUNTIME_LOCK_FILE" &&
      ! runtime_privileged test -f "$RUNTIME_LOCK_FILE"; }; then
    LAST_ERROR="Runtime lock path must be a regular non-symlink file."
    return 1
  fi

  runtime_select_docker || return 1
  runtime_select_compose_access || return 1
  runtime_prepare_compose_snapshots || return 1
  if ! agent_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="agent-wechat Compose configuration is invalid."
    return 1
  fi
  runtime_attest_agent_compose || return 1
  if ! gateway_compose config --quiet >/dev/null 2>&1; then
    LAST_ERROR="Gateway Compose configuration is invalid."
    return 1
  fi
  if ! services="$(gateway_compose config --services 2>/dev/null)"; then
    LAST_ERROR="Gateway services could not be inspected."
    return 1
  fi
  if ! printf '%s\n' "$services" | awk -v service="$GATEWAY_SERVICE" '
    $0 == service { found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
    LAST_ERROR="Gateway Compose does not define the required wechat-worker service."
    return 1
  fi
}

runtime_acquire_lock() {
  local lock_mode="${1:-exclusive}"
  local lock_owner=0 path_metadata path_metadata_after fd_metadata identity
  local flock_args=(-n)

  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ] && [ "$(id -u)" -ne 0 ]; then
    lock_owner="$(id -u)"
  fi
  case "$lock_mode" in
    exclusive) ;;
    shared) flock_args+=(-s) ;;
    *)
      LAST_ERROR="Runtime lock mode is invalid."
      return 1
      ;;
  esac
  if [ "$(id -u)" -ne 0 ]; then
    identity=" $(id -G) "
    case "$identity" in
      *" ${RUNTIME_MANAGEMENT_GID} "*) ;;
      *)
        LAST_ERROR="Current user is not a member of the approved runtime management group."
        return 1
        ;;
    esac
  fi

  if ! runtime_path_exists "$RUNTIME_LOCK_FILE"; then
    # Positional parameters are expanded by the privileged child shell.
    # shellcheck disable=SC2016
    if ! runtime_privileged sh -c '
      umask 137
      set -C
      : > "$1" || exit 1
      chown "$2:$3" "$1" &&
        chmod 640 "$1"
    ' cf-agent-wechat-lock "$RUNTIME_LOCK_FILE" \
      "$lock_owner" "$RUNTIME_MANAGEMENT_GID" &&
      ! runtime_path_exists "$RUNTIME_LOCK_FILE"; then
      LAST_ERROR="Runtime lock file could not be created."
      return 1
    fi
  fi
  if runtime_privileged test -L "$RUNTIME_LOCK_FILE" ||
    ! runtime_privileged test -f "$RUNTIME_LOCK_FILE"; then
    LAST_ERROR="Runtime lock path is not a safe regular file."
    return 1
  fi
  if ! path_metadata="$(runtime_privileged stat -Lc \
    '%d:%i:%u:%g:%a:%h:%s:%F' -- "$RUNTIME_LOCK_FILE")" ||
    [ "${path_metadata#*:*:}" != \
      "${lock_owner}:${RUNTIME_MANAGEMENT_GID}:640:1:0:regular empty file" ]; then
    LAST_ERROR="Runtime lock must use the approved owner, group, mode, link count, and empty content."
    return 1
  fi
  if ! { exec {RUNTIME_LOCK_FD}<"$RUNTIME_LOCK_FILE"; } 2>/dev/null; then
    LAST_ERROR="Runtime lock file could not be opened by the management identity."
    return 1
  fi
  if runtime_privileged test -L "$RUNTIME_LOCK_FILE" ||
    ! path_metadata_after="$(runtime_privileged stat -Lc \
      '%d:%i:%u:%g:%a:%h:%s:%F' -- "$RUNTIME_LOCK_FILE")" ||
    ! fd_metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h:%s:%F' \
      -- "/proc/self/fd/${RUNTIME_LOCK_FD}")" ||
    [ "$path_metadata_after" != "$path_metadata" ] ||
    [ "$fd_metadata" != "$path_metadata" ]; then
    exec {RUNTIME_LOCK_FD}<&-
    RUNTIME_LOCK_FD=""
    LAST_ERROR="Runtime lock changed while it was being opened."
    return 1
  fi
  if ! flock "${flock_args[@]}" "$RUNTIME_LOCK_FD"; then
    exec {RUNTIME_LOCK_FD}<&-
    RUNTIME_LOCK_FD=""
    LAST_ERROR="Another QR runtime operation is already in progress."
    return 1
  fi
  if runtime_privileged test -L "$RUNTIME_LOCK_FILE" ||
    ! path_metadata_after="$(runtime_privileged stat -Lc \
      '%d:%i:%u:%g:%a:%h:%s:%F' -- "$RUNTIME_LOCK_FILE")" ||
    ! fd_metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h:%s:%F' \
      -- "/proc/self/fd/${RUNTIME_LOCK_FD}")" ||
    [ "$path_metadata_after" != "$path_metadata" ] ||
    [ "$fd_metadata" != "$path_metadata" ]; then
    exec {RUNTIME_LOCK_FD}<&-
    RUNTIME_LOCK_FD=""
    LAST_ERROR="Runtime lock path changed after the lock was acquired."
    return 1
  fi
}

gateway_worker_state() {
  local container_ids

  if ! container_ids="$(gateway_compose ps --status running --quiet \
    "$GATEWAY_SERVICE" 2>/dev/null)"; then
    LAST_ERROR="Gateway wechat-worker state could not be queried."
    return 2
  fi
  if [ -n "$container_ids" ]; then
    printf 'running'
  else
    printf 'stopped'
  fi
}

gateway_worker_is_running() {
  local state

  if ! state="$(gateway_worker_state)"; then
    LAST_ERROR="Gateway wechat-worker state could not be queried."
    return 2
  fi
  [ "$state" = "running" ]
}

runtime_gateway_worker_running_ids_by_label() {
  local ids id count=0

  if ! ids="$(runtime_docker ps \
    --filter "label=com.docker.compose.project=${GATEWAY_PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=${GATEWAY_SERVICE}" \
    --format '{{.ID}}' 2>/dev/null)"; then
    LAST_ERROR="Gateway wechat-worker labelled container inventory failed."
    return 1
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! [[ "$id" =~ ^[0-9a-f]{12,64}$ ]]; then
      LAST_ERROR="Gateway wechat-worker labelled container inventory was malformed."
      return 1
    fi
    count=$((count + 1))
    if [ "$count" -gt 32 ]; then
      LAST_ERROR="Gateway wechat-worker labelled container inventory exceeded its safety limit."
      return 1
    fi
    printf '%s\n' "$id"
  done <<< "$ids"
}

runtime_gateway_worker_is_strictly_stopped() {
  local state labelled_ids

  if ! state="$(gateway_worker_state)"; then
    LAST_ERROR="Gateway wechat-worker stopped state could not be proved through Compose."
    return 1
  fi
  if [ "$state" != "stopped" ]; then
    LAST_ERROR="Gateway wechat-worker became active before authorized fresh-runtime release."
    return 1
  fi
  if ! labelled_ids="$(runtime_gateway_worker_running_ids_by_label)"; then
    return 1
  fi
  if [ -n "$labelled_ids" ]; then
    LAST_ERROR="A labelled Gateway wechat-worker became active before authorized fresh-runtime release."
    return 1
  fi
  # Read by start-qr-login.sh after this shared lifecycle operation returns.
  # shellcheck disable=SC2034
  WORKER_STOP_CONFIRMED=1
}

runtime_gateway_worker_stop_target_is_exact() {
  local container_id="$1" expected_running="$2" metadata

  if ! metadata="$(runtime_docker inspect --format \
    '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Running}}' \
    "$container_id" 2>/dev/null)"; then
    LAST_ERROR="Gateway wechat-worker direct-stop target could not be inspected."
    return 1
  fi
  if [ "$metadata" != \
    "${GATEWAY_PROJECT_NAME}|${GATEWAY_SERVICE}|${expected_running}" ]; then
    LAST_ERROR="Gateway wechat-worker direct-stop target labels or state were not exact."
    return 1
  fi
}

runtime_stop_gateway_worker_direct() {
  local ids_output remaining container_id
  local -a container_ids=()

  if ! ids_output="$(runtime_gateway_worker_running_ids_by_label)"; then
    return 1
  fi
  if [ -n "$ids_output" ]; then
    mapfile -t container_ids <<< "$ids_output"
  fi
  ids_output=""
  for container_id in "${container_ids[@]}"; do
    runtime_gateway_worker_stop_target_is_exact \
      "$container_id" true || return 1
  done
  if [ "${#container_ids[@]}" -gt 0 ] &&
    ! runtime_docker stop --time 10 "${container_ids[@]}" >/dev/null 2>&1; then
    LAST_ERROR="Direct Docker stop of labelled Gateway wechat-worker containers failed."
    return 1
  fi
  for container_id in "${container_ids[@]}"; do
    runtime_gateway_worker_stop_target_is_exact \
      "$container_id" false || return 1
  done
  if ! remaining="$(runtime_gateway_worker_running_ids_by_label)"; then
    return 1
  fi
  if [ -n "$remaining" ]; then
    LAST_ERROR="Labelled Gateway wechat-worker containers remain running after direct stop."
    return 1
  fi
}

stop_gateway_worker() {
  local state remaining

  if gateway_compose stop "$GATEWAY_SERVICE" >/dev/null 2>&1 &&
    state="$(gateway_worker_state)" && [ "$state" = "stopped" ] &&
    remaining="$(runtime_gateway_worker_running_ids_by_label)" &&
    [ -z "$remaining" ]; then
    return 0
  fi
  if runtime_stop_gateway_worker_direct; then
    return 0
  fi
  LAST_ERROR="Gateway wechat-worker stop could not be confirmed by Compose or exact-label Docker fallback."
  return 1
}

guard_gateway_worker_stopped() {
  local observed_error

  if runtime_gateway_worker_is_strictly_stopped; then
    return 0
  fi
  observed_error="$LAST_ERROR"
  if stop_gateway_worker; then
    # Read by start-qr-login.sh after this shared lifecycle operation returns.
    # shellcheck disable=SC2034
    WORKER_STOP_CONFIRMED=1
    LAST_ERROR="$observed_error It was stopped, and the fresh QR flow was aborted."
  else
    # shellcheck disable=SC2034
    WORKER_STOP_CONFIRMED=0
    LAST_ERROR="$observed_error Immediate Gateway wechat-worker stop could not be confirmed."
  fi
  return 1
}

rollback_gateway_worker_after_start_failure() {
  local original_error="$1"

  if stop_gateway_worker; then
    WORKER_STOP_CONFIRMED=1
    LAST_ERROR="$original_error"
  else
    WORKER_STOP_CONFIRMED=0
    LAST_ERROR="$original_error Immediate Gateway wechat-worker rollback could not be confirmed."
  fi
  return 0
}

prepare_gateway_worker_candidate() {
  local original_error

  GATEWAY_WORKER_CONTAINER_ID=""
  if ! guard_gateway_worker_stopped; then
    return 1
  fi
  if ! runtime_gateway_gate_assert_pending; then
    return 1
  fi
  if ! gateway_compose create --force-recreate --no-deps \
    "$GATEWAY_SERVICE" >/dev/null 2>&1; then
    original_error="Gateway wechat-worker stopped candidate could not be created."
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  if ! runtime_attest_gateway_worker_container created; then
    original_error="$LAST_ERROR"
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  WORKER_STOP_CONFIRMED=1
}

start_gateway_worker() {
  local state original_error
  local expected_id="$GATEWAY_WORKER_CONTAINER_ID"

  if [ "$GATEWAY_GATE_BEGUN" -ne 1 ] ||
    [ "$GATEWAY_GATE_RELEASED" -ne 1 ] ||
    ! runtime_gateway_generation_id_is_valid "$GATEWAY_GENERATION_ID" ||
    ! runtime_gateway_generation_id_is_valid "$ATTESTED_AGENT_CONTAINER_ID" ||
    ! runtime_gateway_generation_id_is_valid "$expected_id"; then
    LAST_ERROR="Gateway worker cannot start without an exact released runtime generation."
    return 1
  fi
  if ! runtime_attest_gateway_worker_container created "$expected_id"; then
    return 1
  fi

  # Read by start-qr-login.sh after this shared lifecycle operation returns.
  # shellcheck disable=SC2034
  WORKER_STOP_CONFIRMED=0
  if ! gateway_compose start "$GATEWAY_SERVICE" \
    >/dev/null 2>&1; then
    original_error="Gateway wechat-worker start command failed."
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  if ! state="$(gateway_worker_state)"; then
    original_error="Gateway wechat-worker state could not be queried after start."
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  if [ "$state" != "running" ]; then
    original_error="Gateway wechat-worker did not reach running state."
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  if ! runtime_verify_gateway_contract; then
    original_error="$LAST_ERROR"
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  if ! runtime_attest_gateway_worker_container running "$expected_id"; then
    original_error="$LAST_ERROR"
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  if ! wait_for_gateway_worker_health "$expected_id"; then
    original_error="$LAST_ERROR"
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  if ! runtime_verify_gateway_contract; then
    original_error="$LAST_ERROR"
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
  if ! runtime_attest_gateway_worker_container \
    running "$expected_id"; then
    original_error="$LAST_ERROR"
    rollback_gateway_worker_after_start_failure "$original_error"
    return 1
  fi
}

container_health_status() {
  local container_id="$1"

  runtime_docker inspect --format \
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
    "$container_id" 2>/dev/null
}

gateway_worker_heartbeat_is_healthy() {
  local expected_worker_id="${1:-}"
  local checker_status checker_sha

  if [ "$GATEWAY_GATE_BEGUN" -ne 1 ] ||
    [ "$GATEWAY_GATE_RELEASED" -ne 1 ] ||
    ! runtime_gateway_generation_id_is_valid "$GATEWAY_GENERATION_ID" ||
    ! runtime_gateway_generation_id_is_valid "$ATTESTED_AGENT_CONTAINER_ID" ||
    ! runtime_gateway_generation_id_is_valid "$expected_worker_id"; then
    LAST_ERROR="Gateway heartbeat checker requires an exact released runtime-generation binding."
    return 1
  fi

  checker_sha="$GATEWAY_CHECKER_SHA256"
  if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then
    if ! checker_sha="$(runtime_capture_gateway_checker_digest)"; then
      return 1
    fi
  fi
  if ! [[ "$checker_sha" =~ ^[0-9a-f]{64}$ ]]; then
    LAST_ERROR="Gateway checker digest is not an approved SHA-256 value."
    return 1
  fi

  if runtime_gateway_write_request checker "$GATEWAY_GENERATION_ID" \
      "$ATTESTED_AGENT_CONTAINER_ID" "$expected_worker_id" |
    runtime_gateway_checker_snapshot \
      "$GATEWAY_RUNTIME_COMMAND_TIMEOUT" execute \
      "$checker_sha" stdin-json >/dev/null 2>&1; then
    return 0
  else
    checker_status=$?
  fi
  case "$checker_status" in
    125)
      LAST_ERROR="Gateway heartbeat checker violated the silent-output contract."
      ;;
    124)
      LAST_ERROR="Gateway heartbeat checker exceeded its hard timeout."
      ;;
    126)
      LAST_ERROR="Gateway heartbeat checker snapshot validation failed."
      ;;
    *)
      LAST_ERROR="Gateway heartbeat checker failed or reported stale runtime health."
      ;;
  esac
  return 1
}

wait_for_gateway_worker_health() {
  local expected_id="${1:-}"
  local started_at=$SECONDS container_id health

  [ -n "$expected_id" ] || {
    LAST_ERROR="Gateway wechat-worker attested identity is unavailable."
    return 1
  }

  while [ "$((SECONDS - started_at))" -lt "$WORKER_READY_TIMEOUT" ]; do
    container_id=""
    if container_id="$(gateway_compose ps --status running --quiet \
      "$GATEWAY_SERVICE" 2>/dev/null)"; then
      if [ -n "$container_id" ] && [ "$container_id" != "$expected_id" ]; then
        LAST_ERROR="Gateway wechat-worker instance identity changed during stability verification."
        return 1
      fi
    fi
    if [ "$container_id" = "$expected_id" ] &&
      health="$(container_health_status "$container_id")" &&
      [ "$health" = "healthy" ] &&
      gateway_worker_heartbeat_is_healthy "$expected_id"; then
      sleep "$WORKER_STABLE_SECONDS"
      if container_id="$(gateway_compose ps --status running --quiet \
        "$GATEWAY_SERVICE" 2>/dev/null)"; then
        if [ -n "$container_id" ] && [ "$container_id" != "$expected_id" ]; then
          LAST_ERROR="Gateway wechat-worker instance identity changed during stability verification."
          return 1
        fi
      else
        container_id=""
      fi
      if [ "$container_id" = "$expected_id" ] &&
        health="$(container_health_status "$container_id")" &&
        [ "$health" = "healthy" ] &&
        gateway_worker_heartbeat_is_healthy "$expected_id"; then
        return 0
      fi
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="Gateway wechat-worker did not reach stable Docker health with a verified application heartbeat."
  return 1
}

agent_container_state() {
  local all_ids running_ids

  if ! all_ids="$(agent_compose ps --all --quiet agent-wechat 2>/dev/null)"; then
    LAST_ERROR="agent-wechat container state could not be queried."
    return 2
  fi
  if [ -z "$all_ids" ]; then
    printf 'absent'
    return 0
  fi
  if ! running_ids="$(agent_compose ps --status running --quiet \
    agent-wechat 2>/dev/null)"; then
    LAST_ERROR="agent-wechat running state could not be queried."
    return 2
  fi
  if [ -n "$running_ids" ]; then
    printf 'running'
  else
    printf 'stopped'
  fi
}

agent_container_exists() {
  local state

  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried."
    return 2
  fi
  [ "$state" != "absent" ]
}

agent_container_is_running() {
  local state

  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried."
    return 2
  fi
  [ "$state" = "running" ]
}

stop_agent_container() {
  local state

  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried before stop."
    return 1
  fi
  if [ "$state" = "running" ]; then
    if ! agent_compose stop agent-wechat >/dev/null 2>&1; then
      LAST_ERROR="agent-wechat stop command failed."
      return 1
    fi
    if ! state="$(agent_container_state)"; then
      LAST_ERROR="agent-wechat container state could not be queried after stop."
      return 1
    fi
    if [ "$state" = "running" ]; then
      LAST_ERROR="agent-wechat did not stop."
      return 1
    fi
  fi
}

remove_agent_container() {
  local state

  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried before removal."
    return 1
  fi
  if [ "$state" != "absent" ]; then
    if ! agent_compose rm --force agent-wechat >/dev/null 2>&1; then
      LAST_ERROR="agent-wechat remove command failed."
      return 1
    fi
    if ! state="$(agent_container_state)"; then
      LAST_ERROR="agent-wechat container state could not be queried after removal."
      return 1
    fi
    if [ "$state" != "absent" ]; then
      LAST_ERROR="agent-wechat container still exists after removal."
      return 1
    fi
  fi
}

cleanup_failed_agent_container() {
  local cleanup_failed=0

  # These result globals are written to the lifecycle manifest by the caller.
  # shellcheck disable=SC2034
  AGENT_FAILURE_CLEANUP_ATTEMPTED=true
  if stop_agent_container; then
    # shellcheck disable=SC2034
    AGENT_FAILURE_CLEANUP_STOP_RESULT="succeeded"
  else
    # shellcheck disable=SC2034
    AGENT_FAILURE_CLEANUP_STOP_RESULT="failed"
    cleanup_failed=1
  fi
  if remove_agent_container; then
    # shellcheck disable=SC2034
    AGENT_FAILURE_CLEANUP_REMOVE_RESULT="succeeded"
  else
    # shellcheck disable=SC2034
    AGENT_FAILURE_CLEANUP_REMOVE_RESULT="failed"
    cleanup_failed=1
  fi
  return "$cleanup_failed"
}

create_agent_container_candidate() {
  local state

  ATTESTED_AGENT_CONTAINER_ID=""
  if ! agent_compose up --no-start --force-recreate --no-deps agent-wechat \
    >/dev/null 2>&1; then
    LAST_ERROR="agent-wechat stopped candidate creation failed."
    return 1
  fi
  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat candidate state could not be queried."
    return 1
  fi
  if [ "$state" != "stopped" ]; then
    LAST_ERROR="agent-wechat candidate must remain stopped before Archive mutation."
    return 1
  fi
  runtime_attest_actual_agent_container created || return 1
}

start_agent_container() {
  local state

  if [ -z "$ATTESTED_AGENT_CONTAINER_ID" ]; then
    LAST_ERROR="A stopped attested agent-wechat candidate is required before start."
    return 1
  fi
  runtime_attest_actual_agent_container \
    created "$ATTESTED_AGENT_CONTAINER_ID" || return 1
  if ! runtime_docker start "$ATTESTED_AGENT_CONTAINER_ID" \
    >/dev/null 2>&1; then
    LAST_ERROR="The attested agent-wechat candidate start command failed."
    return 1
  fi
  if ! state="$(agent_container_state)"; then
    LAST_ERROR="agent-wechat container state could not be queried after start."
    return 1
  fi
  if [ "$state" != "running" ]; then
    LAST_ERROR="agent-wechat did not reach running state."
    return 1
  fi
  runtime_attest_actual_agent_container \
    running "$ATTESTED_AGENT_CONTAINER_ID" || return 1
}

wait_for_agent_health() {
  local started_at=$SECONDS state health

  while [ "$((SECONDS - started_at))" -lt "$SERVER_READY_TIMEOUT" ]; do
    if state="$(agent_container_state)" && [ "$state" = "running" ] &&
      health="$(container_health_status "$CONTAINER_NAME")" &&
      [ "$health" = "healthy" ]; then
      return 0
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="agent-wechat did not reach Docker healthy state before timeout."
  return 1
}

runtime_wechat_process_identity() {
  # Variables in this snippet are expanded by the shell inside the container.
  # shellcheck disable=SC2016
  runtime_docker exec "$CONTAINER_NAME" sh -c '
launcher_real="$(readlink -f /usr/bin/wechat 2>/dev/null || true)"
case "$launcher_real" in
  /*) ;;
  *) exit 1 ;;
esac

for process_dir in /proc/[0-9]*; do
  proc_exe="$(readlink "$process_dir/exe" 2>/dev/null || true)"
  [ "$proc_exe" = "$launcher_real" ] || continue
  process_id="${process_dir##*/}"
  start_time="$(awk "{ print \$22 }" "$process_dir/stat" 2>/dev/null || true)"
  [ -n "$start_time" ] || continue
  printf "%s:%s\n" "$process_id" "$start_time"
  exit 0
done
exit 1
' 2>/dev/null
}

wait_for_agent_server() {
  local started_at=$SECONDS

  while [ "$((SECONDS - started_at))" -lt "$SERVER_READY_TIMEOUT" ]; do
    if check_agent_server; then
      return 0
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="Agent Server did not become reachable before timeout."
  return 1
}

wait_for_stable_wechat_process() {
  local started_at=$SECONDS
  local first_identity second_identity

  while [ "$((SECONDS - started_at))" -lt "$WECHAT_READY_TIMEOUT" ]; do
    if first_identity="$(runtime_wechat_process_identity)" &&
      [ -n "$first_identity" ]; then
      sleep "$WECHAT_STABLE_SECONDS"
      if second_identity="$(runtime_wechat_process_identity)" &&
        [ "$second_identity" = "$first_identity" ]; then
        # Read by start-qr-login.sh after this shared function returns.
        # shellcheck disable=SC2034
        STABLE_WECHAT_IDENTITY="$second_identity"
        return 0
      fi
    fi
    sleep "$RUNTIME_POLL_INTERVAL"
  done
  LAST_ERROR="/usr/bin/wechat did not remain stable before timeout."
  return 1
}

CF_AGENT_WECHAT_RUNTIME_COMMON_LOADED=1
# Read by scripts that source this shared library.
# shellcheck disable=SC2034
readonly CF_AGENT_WECHAT_RUNTIME_COMMON_LOADED
