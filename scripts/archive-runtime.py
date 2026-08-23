#!/usr/bin/env python3
"""Inventory restricted runtime archives and explicitly retire one archive."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import json
import functools
import os
import re
import stat
import sys
import signal
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

if os.name == "posix":
    import fcntl


CONTRACT_VERSION = 1
AUDIT_FILE_NAME = ".retention-audit.jsonl"
DEFAULT_MAX_FILES = 1_000_000
DEFAULT_TIMEOUT_SECONDS = 300
FAILURE_AUDIT_TIMEOUT_SECONDS = 5
RUNTIME_LOCK_FILE = Path("/run/lock/cf-agent-wechat-qr-runtime.lock")
MOUNTINFO_FILE = Path("/proc/self/mountinfo")
MAX_MOUNTINFO_BYTES = 16 * 1024 * 1024
MAX_ENV_BYTES = 64 * 1024
MAX_MANIFEST_BYTES = 128 * 1024
MANIFEST_FILE_NAME = "manifest.json"
MANIFEST_TEMP_PREFIX = ".manifest.json."
PRODUCTION_STORAGE_ROOT = Path("/srv/storage/cf-agent-wechat")
PRODUCTION_RUNTIME_ROOT = PRODUCTION_STORAGE_ROOT / "runtime"
PRODUCTION_ARCHIVE_ROOT = PRODUCTION_STORAGE_ROOT / "session-archive"
PRODUCTION_TOKEN_FILE = PRODUCTION_STORAGE_ROOT / "secrets" / "auth-token"
ARCHIVE_NAME_RE = re.compile(
    r"^(?P<timestamp>[0-9]{8}T[0-9]{6}Z)(?:-[0-9]{2})?$",
    re.ASCII,
)
MOUNTINFO_ESCAPE_RE = re.compile(rb"\\([0-7]{3})")
ENV_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
REQUIRED_ENV_KEYS = (
    "CF_AGENT_WECHAT_STORAGE_ROOT",
    "CF_AGENT_WECHAT_RUNTIME_ROOT",
    "CF_AGENT_WECHAT_ARCHIVE_ROOT",
    "CF_AGENT_WECHAT_MANAGEMENT_GID",
)


class ArchiveError(Exception):
    """A non-sensitive archive management failure."""


class InvalidArchiveNamesError(ArchiveError):
    """Archive root entries violated the production naming contract."""

    def __init__(self, count: int) -> None:
        self.count = count
        super().__init__(
            f"archive inventory rejected {count} non-production archive name(s)"
        )


@dataclass(frozen=True)
class ArchiveContract:
    storage_root: Path
    runtime_root: Path
    archive_root: Path
    token_file: Path
    management_gid: int


@dataclass(frozen=True)
class ManagementIdentity:
    uid: int
    gid: int


@dataclass(frozen=True)
class ArchiveRecord:
    name: str
    apparentBytes: int
    regularFiles: int
    directories: int
    modifiedUtc: str
    device: int
    inode: int


@dataclass(frozen=True)
class Inventory:
    schemaVersion: int
    archiveCount: int
    totalApparentBytes: int
    totalRegularFiles: int
    oldest: dict[str, str] | None
    newest: dict[str, str] | None
    archives: tuple[ArchiveRecord, ...]


def validate_management_env_metadata(
    owner_uid: int,
    owner_gid: int,
    mode: int,
    operator: ManagementIdentity,
    management_gid: int,
) -> None:
    """Require one exact approved owner/group/mode tuple for docker/.env."""
    values = (owner_uid, owner_gid, mode, operator.uid, operator.gid, management_gid)
    if any(not isinstance(value, int) or value < 0 for value in values):
        raise ArchiveError("the management environment metadata is invalid")
    approved = {
        (0, 0, 0o600),
        (operator.uid, operator.gid, 0o600),
        (0, management_gid, 0o640),
        (operator.uid, management_gid, 0o640),
    }
    if (owner_uid, owner_gid, mode) not in approved:
        raise ArchiveError(
            "the management environment owner, group, and mode are not approved"
        )


@contextlib.contextmanager
def posix_hard_timeout(seconds: int):
    """Enforce a process-level deadline around potentially blocking syscalls."""
    if os.name != "posix" or not hasattr(signal, "setitimer"):
        yield
        return
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    previous_handler = signal.getsignal(signal.SIGALRM)
    started = time.monotonic()
    timed_out = False
    previous_delay = previous_timer[0]
    previous_was_limiting = previous_delay > 0 and previous_delay <= seconds
    effective_seconds = min(previous_delay, seconds) if previous_delay > 0 else seconds

    def handle_timeout(_signum, _frame) -> None:
        nonlocal timed_out
        timed_out = True
        raise ArchiveError("archive operation exceeded its hard time limit")

    try:
        signal.signal(signal.SIGALRM, handle_timeout)
    except ValueError:
        yield
        return
    signal.setitimer(signal.ITIMER_REAL, effective_seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_delay > 0 and not (timed_out and previous_was_limiting):
            remaining = previous_delay - (time.monotonic() - started)
            if remaining > 0:
                signal.setitimer(
                    signal.ITIMER_REAL,
                    remaining,
                    previous_timer[1],
                )


def enforce_posix_hard_timeout(function):
    """Decorate an archive phase with the configured hard deadline."""

    @functools.wraps(function)
    def wrapped(*args, **kwargs):
        seconds = kwargs.get("timeout_seconds", DEFAULT_TIMEOUT_SECONDS)
        if not isinstance(seconds, int) or seconds <= 0:
            raise ArchiveError("archive timeout must be a positive integer")
        with posix_hard_timeout(seconds):
            return function(*args, **kwargs)

    return wrapped


@dataclass
class ScanBudget:
    max_files: int
    deadline: float
    files: int = 0

    def check_time(self) -> None:
        if time.monotonic() > self.deadline:
            raise ArchiveError("archive inventory exceeded its time limit")

    def count_entry(self) -> None:
        self.files += 1
        if self.files > self.max_files:
            raise ArchiveError("archive inventory exceeded its entry-count limit")


def utc_timestamp(timestamp: float | None = None) -> str:
    moment = dt.datetime.fromtimestamp(
        time.time() if timestamp is None else timestamp,
        tz=dt.timezone.utc,
    )
    return moment.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def normalize_absolute(path: Path, label: str) -> Path:
    raw = os.fspath(path)
    if not path.is_absolute() or "\x00" in raw or ".." in path.parts:
        raise ArchiveError(f"{label} must be an absolute normalized path")
    normalized = Path(os.path.normpath(raw))
    if normalized == Path(normalized.anchor):
        raise ArchiveError(f"{label} must not be a filesystem root")
    return normalized


def path_is_within(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def parse_mountinfo(data: bytes) -> tuple[Path, ...]:
    """Parse kernel-escaped mount points from one mountinfo snapshot."""
    if not data or len(data) > MAX_MOUNTINFO_BYTES:
        raise ArchiveError("the process mount table is unavailable or too large")
    mount_points: list[Path] = []
    for line in data.splitlines():
        fields = line.split()
        if len(fields) < 10 or b"-" not in fields[6:]:
            raise ArchiveError("the process mount table is malformed")
        encoded = fields[4]
        try:
            decoded = MOUNTINFO_ESCAPE_RE.sub(
                lambda match: bytes((int(match.group(1), 8),)), encoded
            )
        except ValueError as exc:
            raise ArchiveError("the process mount table is malformed") from exc
        if b"\x00" in decoded:
            raise ArchiveError("the process mount table contains an invalid path")
        mount_point = Path(os.path.normpath(os.fsdecode(decoded)))
        if not mount_point.is_absolute():
            raise ArchiveError("the process mount table contains a relative path")
        mount_points.append(mount_point)
    if not mount_points:
        raise ArchiveError("the process mount table contains no mount points")
    return tuple(mount_points)


def read_mount_points(path: Path = MOUNTINFO_FILE) -> tuple[Path, ...]:
    """Read a bounded mountinfo snapshot from the current mount namespace."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    try:
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(descriptor, min(65536, MAX_MOUNTINFO_BYTES + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > MAX_MOUNTINFO_BYTES:
                raise ArchiveError("the process mount table is too large")
        return parse_mountinfo(b"".join(chunks))
    finally:
        os.close(descriptor)


def assert_no_archive_submounts(
    archive_root: Path,
    *,
    mount_points: tuple[Path, ...] | None = None,
) -> None:
    """Reject every mount strictly below the protected Archive root."""
    archive = normalize_absolute(archive_root, "archive root")
    points = read_mount_points() if mount_points is None else mount_points
    for mount_point in points:
        normalized = Path(os.path.normpath(os.fspath(mount_point)))
        if normalized != archive and path_is_within(normalized, archive):
            raise ArchiveError("the archive root contains a mounted subtree")


def validate_no_symlink_ancestors(path: Path, require_leaf: bool) -> None:
    current = Path(path.anchor)
    missing = False
    for part in path.parts[1:]:
        current /= part
        if missing:
            continue
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            missing = True
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise ArchiveError("managed paths must not contain symbolic links")
        if current != path and not stat.S_ISDIR(metadata.st_mode):
            raise ArchiveError("a managed path ancestor is not a directory")
    if require_leaf and missing:
        raise ArchiveError("the archive root does not exist")


def _read_regular_file(
    path: Path,
    *,
    max_bytes: int,
    expected_uid: int | None,
    expected_mode: int | None,
    expected_gid: int | None,
) -> bytes:
    validate_no_symlink_ancestors(path, require_leaf=True)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ArchiveError(
            "the management environment is not a single-link regular file"
        )
    if expected_uid is not None and before.st_uid != expected_uid:
        raise ArchiveError("the management environment has an unexpected owner")
    if expected_gid is not None and before.st_gid != expected_gid:
        raise ArchiveError("the management environment has an unexpected group")
    if expected_mode is not None and stat.S_IMODE(before.st_mode) != expected_mode:
        raise ArchiveError("the management environment has an unexpected mode")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if _stable_regular_file_identity(opened) != _stable_regular_file_identity(
            before
        ):
            raise ArchiveError("the management environment changed during inspection")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(descriptor, min(8192, max_bytes + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > max_bytes:
                raise ArchiveError("the management environment is too large")
        after_open = os.fstat(descriptor)
        try:
            visible = path.lstat()
        except OSError as exc:
            raise ArchiveError(
                "the management environment changed during inspection"
            ) from exc
        identity = _stable_regular_file_identity(opened)
        if (
            _stable_regular_file_identity(after_open) != identity
            or _stable_regular_file_identity(visible) != identity
        ):
            raise ArchiveError("the management environment changed during inspection")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _stable_regular_file_identity(metadata: os.stat_result) -> tuple[int, ...]:
    """Return metadata that must remain stable across a protected file read."""
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_ctime_ns,
    )


def parse_management_env(data: bytes) -> dict[str, str]:
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ArchiveError("docker/.env is not valid UTF-8") from exc
    if any(
        (ord(character) < 0x20 and character != "\n")
        or 0x7F <= ord(character) <= 0x9F
        for character in text
    ):
        raise ArchiveError("docker/.env contains a control character")

    values: dict[str, str] = {}
    for line in text.split("\n"):
        if not line or line.startswith("#"):
            continue
        if line != line.strip() or "=" not in line:
            raise ArchiveError("docker/.env contains unsupported syntax")
        key, value = line.split("=", 1)
        if not ENV_KEY_RE.fullmatch(key) or key in values:
            raise ArchiveError("docker/.env contains an invalid or duplicate key")
        if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
            raise ArchiveError("docker/.env contains a control character")
        values[key] = value
    for key in REQUIRED_ENV_KEYS:
        if not values.get(key):
            raise ArchiveError(f"docker/.env must define {key}")
    return values


def load_contract(
    env_file: Path,
    *,
    expected_uid: int | None = 0,
    expected_mode: int | None = 0o600,
    expected_gid: int | None = 0,
) -> ArchiveContract:
    data = _read_regular_file(
        env_file,
        max_bytes=MAX_ENV_BYTES,
        expected_uid=expected_uid,
        expected_mode=expected_mode,
        expected_gid=expected_gid,
    )
    values = parse_management_env(data)
    storage = normalize_absolute(
        Path(values["CF_AGENT_WECHAT_STORAGE_ROOT"]), "storage root"
    )
    runtime = normalize_absolute(
        Path(values["CF_AGENT_WECHAT_RUNTIME_ROOT"]), "runtime root"
    )
    archive = normalize_absolute(
        Path(values["CF_AGENT_WECHAT_ARCHIVE_ROOT"]), "archive root"
    )
    management_gid_text = values["CF_AGENT_WECHAT_MANAGEMENT_GID"]
    if not management_gid_text.isdecimal():
        raise ArchiveError("docker/.env contains an invalid management group")
    management_gid = int(management_gid_text, 10)
    if management_gid < 0 or management_gid > 2**31 - 1:
        raise ArchiveError("docker/.env contains an invalid management group")
    return ArchiveContract(
        storage_root=storage,
        runtime_root=runtime,
        archive_root=archive,
        token_file=storage / "secrets" / "auth-token",
        management_gid=management_gid,
    )


def validate_production_contract_paths(contract: ArchiveContract) -> None:
    approved = (
        PRODUCTION_STORAGE_ROOT,
        PRODUCTION_RUNTIME_ROOT,
        PRODUCTION_ARCHIVE_ROOT,
        PRODUCTION_TOKEN_FILE,
    )
    actual = (
        contract.storage_root,
        contract.runtime_root,
        contract.archive_root,
        contract.token_file,
    )
    if actual != approved:
        raise ArchiveError("archive production paths differ from the approved contract")


def validate_contract(
    contract: ArchiveContract,
    *,
    expected_uid: int,
    expected_gid: int | None = None,
    require_root_mode: bool = True,
) -> os.stat_result:
    if expected_gid is None:
        expected_gid = os.getgid() if hasattr(os, "getgid") else expected_uid
    storage = normalize_absolute(contract.storage_root, "storage root")
    runtime = normalize_absolute(contract.runtime_root, "runtime root")
    archive = normalize_absolute(contract.archive_root, "archive root")
    token = normalize_absolute(contract.token_file, "Token file")
    if not path_is_within(runtime, storage) or not path_is_within(archive, storage):
        raise ArchiveError("runtime and archive roots must remain within storage")
    if (
        runtime == archive
        or path_is_within(runtime, archive)
        or path_is_within(archive, runtime)
    ):
        raise ArchiveError("runtime and archive roots must be separate and non-nested")
    approved_token = storage / "secrets" / "auth-token"
    if (
        token != approved_token
        or path_is_within(token, runtime)
        or path_is_within(token, archive)
    ):
        raise ArchiveError("the approved Token path must remain outside managed data")
    validate_no_symlink_ancestors(storage, require_leaf=True)
    validate_no_symlink_ancestors(runtime, require_leaf=False)
    validate_no_symlink_ancestors(archive, require_leaf=True)
    validate_no_symlink_ancestors(token, require_leaf=False)
    metadata = archive.lstat()
    storage_metadata = storage.lstat()
    if not stat.S_ISDIR(storage_metadata.st_mode):
        raise ArchiveError("the storage root is not a directory")
    if (storage_metadata.st_uid, storage_metadata.st_gid) != (expected_uid, expected_gid):
        raise ArchiveError("the storage root has an unexpected owner or group")
    if require_root_mode and stat.S_IMODE(storage_metadata.st_mode) != 0o755:
        raise ArchiveError("the storage root must have mode 0755")
    if not stat.S_ISDIR(metadata.st_mode):
        raise ArchiveError("the archive root is not a directory")
    if (metadata.st_uid, metadata.st_gid) != (expected_uid, expected_gid):
        raise ArchiveError("the archive root has an unexpected owner")
    if require_root_mode and stat.S_IMODE(metadata.st_mode) != 0o700:
        raise ArchiveError("the archive root must have mode 0700")
    if runtime.exists():
        runtime_metadata = runtime.lstat()
        if (runtime_metadata.st_dev, runtime_metadata.st_ino) == (
            metadata.st_dev,
            metadata.st_ino,
        ):
            raise ArchiveError("the archive root resolves to the current runtime")
    return metadata


def acquire_management_lock(contract: ArchiveContract, *, expected_uid: int = 0) -> int:
    if os.name != "posix":
        raise ArchiveError("archive deletion requires POSIX lock semantics")
    validate_no_symlink_ancestors(RUNTIME_LOCK_FILE, require_leaf=True)
    before = RUNTIME_LOCK_FILE.lstat()
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != expected_uid
        or before.st_gid != contract.management_gid
        or stat.S_IMODE(before.st_mode) != 0o640
        or before.st_size != 0
    ):
        raise ArchiveError("the runtime management lock contract is invalid")
    descriptor = os.open(
        RUNTIME_LOCK_FILE,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ArchiveError("the runtime management lock changed while opening")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ArchiveError(
                "another runtime management operation is in progress"
            ) from exc
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def release_management_lock(descriptor: int) -> None:
    if os.name == "posix":
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    os.close(descriptor)


def _archive_name_is_valid(name: str) -> bool:
    match = ARCHIVE_NAME_RE.fullmatch(name)
    if match is None:
        return False
    try:
        dt.datetime.strptime(match.group("timestamp"), "%Y%m%dT%H%M%S%z")
    except ValueError:
        return False
    return True


def _validate_archive_name(name: str) -> None:
    if not _archive_name_is_valid(name):
        raise ArchiveError("archive selection must use an approved UTC timestamp name")


def _validate_entry(
    metadata: os.stat_result,
    *,
    root_device: int,
    protected_identities: set[tuple[int, int]],
) -> str:
    mode = metadata.st_mode
    if stat.S_ISLNK(mode):
        raise ArchiveError("an archive contains a symbolic link")
    if root_device >= 0 and metadata.st_dev != root_device:
        raise ArchiveError("an archive crosses a filesystem boundary")
    if (metadata.st_dev, metadata.st_ino) in protected_identities:
        raise ArchiveError("an archive references protected live state")
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISREG(mode):
        if root_device >= 0 and metadata.st_nlink != 1:
            raise ArchiveError("an archive contains a hard-linked file")
        return "file"
    raise ArchiveError("an archive contains a special file")


def _protected_identities(contract: ArchiveContract) -> set[tuple[int, int]]:
    identities: set[tuple[int, int]] = set()
    protected = (
        contract.runtime_root,
        contract.runtime_root / "data",
        contract.runtime_root / "wechat-home",
        contract.storage_root / "data",
        contract.storage_root / "wechat-home",
        contract.token_file,
    )
    for path in protected:
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise ArchiveError("a protected live path is a symbolic link")
        identities.add((metadata.st_dev, metadata.st_ino))
    return identities


def _directory_flags() -> int:
    return os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)


def _open_verified_directory(path: Path, expected: os.stat_result) -> int:
    descriptor = os.open(path, _directory_flags())
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
        os.close(descriptor)
        raise ArchiveError("a managed directory changed during inspection")
    return descriptor


def _scan_directory_fd(
    descriptor: int,
    *,
    root_device: int,
    protected_identities: set[tuple[int, int]],
    budget: ScanBudget,
) -> tuple[int, int, int]:
    apparent_bytes = 0
    regular_files = 0
    directories = 0
    budget.check_time()
    with os.scandir(descriptor) as iterator:
        for entry in iterator:
            budget.check_time()
            metadata = entry.stat(follow_symlinks=False)
            budget.count_entry()
            kind = _validate_entry(
                metadata,
                root_device=root_device,
                protected_identities=protected_identities,
            )
            if kind == "file":
                regular_files += 1
                apparent_bytes += metadata.st_size
                continue
            child_fd = os.open(entry.name, _directory_flags(), dir_fd=descriptor)
            try:
                opened = os.fstat(child_fd)
                if (opened.st_dev, opened.st_ino) != (
                    metadata.st_dev,
                    metadata.st_ino,
                ):
                    raise ArchiveError("an archive directory changed during inspection")
                child_size, child_files, child_directories = _scan_directory_fd(
                    child_fd,
                    root_device=root_device,
                    protected_identities=protected_identities,
                    budget=budget,
                )
            finally:
                os.close(child_fd)
            apparent_bytes += child_size
            regular_files += child_files
            directories += child_directories + 1
    return apparent_bytes, regular_files, directories


def _scan_directory_portable(
    path: Path,
    *,
    root_device: int,
    protected_identities: set[tuple[int, int]],
    budget: ScanBudget,
) -> tuple[int, int, int]:
    apparent_bytes = 0
    regular_files = 0
    directories = 0
    budget.check_time()
    with os.scandir(path) as iterator:
        for entry in iterator:
            budget.check_time()
            metadata = entry.stat(follow_symlinks=False)
            budget.count_entry()
            kind = _validate_entry(
                metadata,
                root_device=root_device,
                protected_identities=protected_identities,
            )
            if kind == "file":
                regular_files += 1
                apparent_bytes += metadata.st_size
                continue
            child_size, child_files, child_directories = _scan_directory_portable(
                Path(entry.path),
                root_device=root_device,
                protected_identities=protected_identities,
                budget=budget,
            )
            apparent_bytes += child_size
            regular_files += child_files
            directories += child_directories + 1
    return apparent_bytes, regular_files, directories


def _validate_audit_metadata(
    metadata: os.stat_result, expected_uid: int, expected_gid: int
) -> None:
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or (metadata.st_uid, metadata.st_gid) != (expected_uid, expected_gid)
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise ArchiveError("the retention audit file is not a protected regular file")


def _validate_manifest_metadata(
    metadata: os.stat_result,
    *,
    expected_uid: int,
    expected_gid: int,
    enforce_identity: bool,
) -> None:
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or (
            enforce_identity
            and (
                (metadata.st_uid, metadata.st_gid)
                != (expected_uid, expected_gid)
                or stat.S_IMODE(metadata.st_mode) != 0o600
            )
        )
    ):
        raise ArchiveError("archive manifest metadata is unsafe")


def _validate_manifest_payload(payload: object) -> None:
    if not isinstance(payload, dict):
        raise ArchiveError("archive manifest must contain a JSON object")
    schema_version = payload.get("schemaVersion")
    if type(schema_version) is not int or schema_version not in {1, 2}:
        raise ArchiveError("archive manifest schema is unsupported")
    if payload.get("runtimeMode") != "forced_qr":
        raise ArchiveError("archive manifest runtime mode is invalid")
    result = payload.get("result")
    if result == "in_progress":
        raise ArchiveError("archive manifest records an incomplete transaction")
    if result not in {"success", "failed"}:
        raise ArchiveError("archive manifest result is not terminal")
    if payload.get("archiveResult") != "succeeded":
        raise ArchiveError("archive manifest does not record a completed archive")
    ended_at = payload.get("endedAtUtc")
    if not isinstance(ended_at, str) or not ended_at:
        raise ArchiveError("archive manifest has no completion timestamp")

    if schema_version == 1:
        # Historical v1 is accepted only as restricted evidence. Its old
        # sensitiveData fields never prove that the payload was sanitized.
        return

    manifest_data = payload.get("manifestData")
    if not isinstance(manifest_data, dict):
        raise ArchiveError("archive manifest metadata classification is incomplete")
    for key in (
        "tokenIncluded",
        "accountIdentifiersIncluded",
        "chatIdentifiersIncluded",
        "messageContentIncluded",
    ):
        if manifest_data.get(key) is not False:
            raise ArchiveError(
                "archive manifest metadata classification is incomplete"
            )

    classification = payload.get("archivePayloadClassification")
    if not isinstance(classification, dict):
        raise ArchiveError("archive payload classification is incomplete")
    expected_values = {
        "mayContainWechatSession": True,
        "mayContainAccountIdentifiers": True,
        "mayContainChatIdentifiers": True,
        "mayContainMessageMetadata": True,
        "mayContainMessageContent": True,
        "containsIndependentAgentApiToken": False,
        "independentAgentApiTokenScan": "verified",
        "accessClassification": "restricted",
        "productionSessionRecoveryAllowed": False,
    }
    for key, expected in expected_values.items():
        if key not in classification:
            raise ArchiveError("archive payload classification is incomplete")
        actual = classification[key]
        if (
            (type(expected) is bool and actual is not expected)
            or (type(expected) is not bool and actual != expected)
        ):
            raise ArchiveError("archive payload classification is incomplete")


def _manifest_identity(
    metadata: os.stat_result,
    *,
    enforce_identity: bool,
) -> tuple[int, ...]:
    identity = _stable_regular_file_identity(metadata)
    # Windows portable tests can update ctime when a file handle is opened.
    # POSIX production keeps the complete identity, including ctime.
    return identity if enforce_identity else identity[:-1]


def _read_and_validate_manifest(
    archive_path: Path,
    *,
    directory_fd: int | None,
    metadata: os.stat_result,
    expected_uid: int,
    expected_gid: int,
    enforce_identity: bool,
) -> tuple[int, ...]:
    _validate_manifest_metadata(
        metadata,
        expected_uid=expected_uid,
        expected_gid=expected_gid,
        enforce_identity=enforce_identity,
    )
    target: str | Path = (
        MANIFEST_FILE_NAME
        if directory_fd is not None
        else archive_path / MANIFEST_FILE_NAME
    )
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = (
        os.open(target, flags)
        if directory_fd is None
        else os.open(target, flags, dir_fd=directory_fd)
    )
    try:
        opened = os.fstat(descriptor)
        expected_identity = _manifest_identity(
            metadata, enforce_identity=enforce_identity
        )
        if _manifest_identity(
            opened, enforce_identity=enforce_identity
        ) != expected_identity:
            raise ArchiveError("archive manifest changed during inspection")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(
                descriptor,
                min(8192, MAX_MANIFEST_BYTES + 1 - size),
            )
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_MANIFEST_BYTES:
                raise ArchiveError("archive manifest exceeds its size limit")
            chunks.append(chunk)
        after_open = os.fstat(descriptor)
        visible = (
            os.stat(
                MANIFEST_FILE_NAME,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
            if directory_fd is not None
            else (archive_path / MANIFEST_FILE_NAME).lstat()
        )
        if (
            _manifest_identity(
                after_open, enforce_identity=enforce_identity
            )
            != expected_identity
            or _manifest_identity(
                visible, enforce_identity=enforce_identity
            )
            != expected_identity
        ):
            raise ArchiveError("archive manifest changed during inspection")
    finally:
        os.close(descriptor)

    try:
        payload = json.loads(b"".join(chunks).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ArchiveError("archive manifest is malformed") from exc
    _validate_manifest_payload(payload)
    return expected_identity


def _validated_manifest_identity(
    archive_path: Path,
    *,
    directory_fd: int | None,
    expected_uid: int,
    expected_gid: int,
    enforce_identity: bool,
    budget: ScanBudget,
) -> tuple[int, ...]:
    manifest_metadata: os.stat_result | None = None
    scan_target: int | Path = (
        directory_fd if directory_fd is not None else archive_path
    )
    with os.scandir(scan_target) as iterator:
        for entry in iterator:
            budget.check_time()
            if entry.name.startswith(MANIFEST_TEMP_PREFIX):
                raise ArchiveError(
                    "archive contains an unfinished manifest installation"
                )
            if entry.name == MANIFEST_FILE_NAME:
                if manifest_metadata is not None:
                    raise ArchiveError("archive contains duplicate manifests")
                manifest_metadata = (
                    entry.stat(follow_symlinks=False)
                    if directory_fd is not None
                    else (archive_path / entry.name).lstat()
                )
    if manifest_metadata is None:
        raise ArchiveError("archive manifest is missing")
    return _read_and_validate_manifest(
        archive_path,
        directory_fd=directory_fd,
        metadata=manifest_metadata,
        expected_uid=expected_uid,
        expected_gid=expected_gid,
        enforce_identity=enforce_identity,
    )


@enforce_posix_hard_timeout
def inventory_archives(
    contract: ArchiveContract,
    *,
    expected_uid: int,
    expected_gid: int | None = None,
    max_files: int = DEFAULT_MAX_FILES,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
    allow_portable_testing: bool = False,
) -> Inventory:
    if max_files <= 0 or timeout_seconds <= 0:
        raise ArchiveError("inventory limits must be positive")
    if expected_gid is None:
        expected_gid = os.getgid() if hasattr(os, "getgid") else expected_uid
    root_metadata = validate_contract(
        contract,
        expected_uid=expected_uid,
        require_root_mode=os.name == "posix" or not allow_portable_testing,
        expected_gid=expected_gid,
    )
    if os.name == "posix":
        assert_no_archive_submounts(contract.archive_root)
    protected = _protected_identities(contract)
    budget = ScanBudget(max_files, time.monotonic() + timeout_seconds)
    records_with_time: list[tuple[int, ArchiveRecord]] = []

    if os.name != "posix" and not allow_portable_testing:
        raise ArchiveError("archive management requires POSIX descriptor semantics")

    root_fd: int | None = None
    try:
        if os.name == "posix":
            root_fd = _open_verified_directory(contract.archive_root, root_metadata)
            with os.scandir(root_fd) as iterator:
                root_entries = []
                for entry in iterator:
                    budget.check_time()
                    budget.count_entry()
                    root_entries.append((entry.name, entry.stat(follow_symlinks=False)))
        else:
            with os.scandir(contract.archive_root) as iterator:
                root_entries = []
                for entry in iterator:
                    budget.check_time()
                    budget.count_entry()
                    root_entries.append((entry.name, entry.stat(follow_symlinks=False)))

        invalid_name_count = sum(
            entry_name != AUDIT_FILE_NAME
            and not _archive_name_is_valid(entry_name)
            for entry_name, _metadata in root_entries
        )
        if invalid_name_count:
            raise InvalidArchiveNamesError(invalid_name_count)

        for entry_name, metadata in root_entries:
            budget.check_time()
            if entry_name == AUDIT_FILE_NAME:
                _validate_audit_metadata(metadata, expected_uid, expected_gid)
                continue
            _validate_archive_name(entry_name)
            kind = _validate_entry(
                metadata,
                root_device=root_metadata.st_dev if os.name == "posix" else -1,
                protected_identities=protected,
            )
            if kind != "directory":
                raise ArchiveError(
                    "archive root contains an unknown non-directory entry"
                )
            if (os.name == "posix" or not allow_portable_testing) and (
                (metadata.st_uid, metadata.st_gid) != (expected_uid, expected_gid)
                or stat.S_IMODE(metadata.st_mode) != 0o700
            ):
                raise ArchiveError("an archive directory violates owner or mode")

            if os.name == "posix":
                assert root_fd is not None
                child_fd = os.open(entry_name, _directory_flags(), dir_fd=root_fd)
                try:
                    opened = os.fstat(child_fd)
                    if (opened.st_dev, opened.st_ino) != (
                        metadata.st_dev,
                        metadata.st_ino,
                    ):
                        raise ArchiveError("an archive changed during inspection")
                    manifest_identity = _validated_manifest_identity(
                        contract.archive_root / entry_name,
                        directory_fd=child_fd,
                        expected_uid=expected_uid,
                        expected_gid=expected_gid,
                        enforce_identity=True,
                        budget=budget,
                    )
                    size, files, directories = _scan_directory_fd(
                        child_fd,
                        root_device=root_metadata.st_dev,
                        protected_identities=protected,
                        budget=budget,
                    )
                    if _validated_manifest_identity(
                        contract.archive_root / entry_name,
                        directory_fd=child_fd,
                        expected_uid=expected_uid,
                        expected_gid=expected_gid,
                        enforce_identity=True,
                        budget=budget,
                    ) != manifest_identity:
                        raise ArchiveError(
                            "archive manifest changed during inventory"
                        )
                finally:
                    os.close(child_fd)
            else:
                archive_path = contract.archive_root / entry_name
                manifest_identity = _validated_manifest_identity(
                    archive_path,
                    directory_fd=None,
                    expected_uid=expected_uid,
                    expected_gid=expected_gid,
                    enforce_identity=not allow_portable_testing,
                    budget=budget,
                )
                size, files, directories = _scan_directory_portable(
                    archive_path,
                    root_device=-1,
                    protected_identities=protected,
                    budget=budget,
                )
                if _validated_manifest_identity(
                    archive_path,
                    directory_fd=None,
                    expected_uid=expected_uid,
                    expected_gid=expected_gid,
                    enforce_identity=not allow_portable_testing,
                    budget=budget,
                ) != manifest_identity:
                    raise ArchiveError(
                        "archive manifest changed during inventory"
                    )

            record = ArchiveRecord(
                name=entry_name,
                apparentBytes=size,
                regularFiles=files,
                directories=directories + 1,
                modifiedUtc=utc_timestamp(metadata.st_mtime),
                device=metadata.st_dev,
                inode=metadata.st_ino,
            )
            records_with_time.append((metadata.st_mtime_ns, record))
    finally:
        if root_fd is not None:
            os.close(root_fd)

    records_with_time.sort(key=lambda item: (item[0], item[1].name))
    records = tuple(record for _, record in records_with_time)
    edge = lambda record: {"name": record.name, "modifiedUtc": record.modifiedUtc}
    return Inventory(
        schemaVersion=CONTRACT_VERSION,
        archiveCount=len(records),
        totalApparentBytes=sum(record.apparentBytes for record in records),
        totalRegularFiles=sum(record.regularFiles for record in records),
        oldest=edge(records[0]) if records else None,
        newest=edge(records[-1]) if records else None,
        archives=records,
    )


def retention_plan(inventory: Inventory, archive_name: str) -> dict[str, object]:
    _validate_archive_name(archive_name)
    matches = [record for record in inventory.archives if record.name == archive_name]
    if len(matches) != 1:
        raise ArchiveError("the explicitly selected archive was not found")
    record = matches[0]
    return {
        "schemaVersion": CONTRACT_VERSION,
        "mode": "dry-run",
        "archive": record.name,
        "apparentBytes": record.apparentBytes,
        "regularFiles": record.regularFiles,
        "willDelete": False,
    }


def validate_execute_confirmation(
    archive_name: str,
    flag_value: str | None,
    typed_value: str | None,
    *,
    is_tty: bool,
) -> str:
    phrase = f"DELETE:{archive_name}"
    if flag_value != phrase:
        raise ArchiveError("execute mode requires the exact confirmation flag")
    if not is_tty or typed_value != phrase:
        raise ArchiveError("execute mode requires an interactive second confirmation")
    return phrase


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise ArchiveError("the retention audit record could not be written")
        offset += written
    os.fsync(descriptor)


def _append_audit(
    descriptor: int,
    *,
    request_id: str,
    archive_name: str,
    event: str,
) -> None:
    record = {
        "contractVersion": CONTRACT_VERSION,
        "timestampUtc": utc_timestamp(),
        "requestId": request_id,
        "action": "delete_archive",
        "archive": archive_name,
        "event": event,
    }
    _write_all(
        descriptor,
        (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode(
            "utf-8"
        ),
    )


def _open_audit(root_fd: int, expected_uid: int, expected_gid: int) -> int:
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(AUDIT_FILE_NAME, flags, 0o600, dir_fd=root_fd)
    metadata = os.fstat(descriptor)
    try:
        visible = os.stat(AUDIT_FILE_NAME, dir_fd=root_fd, follow_symlinks=False)
    except OSError:
        os.close(descriptor)
        raise
    if (visible.st_dev, visible.st_ino) != (metadata.st_dev, metadata.st_ino):
        os.close(descriptor)
        raise ArchiveError("the retention audit file changed during inspection")
    try:
        _validate_audit_metadata(metadata, expected_uid, expected_gid)
    except ArchiveError:
        os.close(descriptor)
        raise
    return descriptor


def _delete_directory_contents(
    descriptor: int,
    *,
    root_device: int,
    protected_identities: set[tuple[int, int]],
    budget: ScanBudget,
) -> None:
    budget.check_time()
    with os.scandir(descriptor) as iterator:
        entries = []
        for entry in iterator:
            budget.check_time()
            budget.count_entry()
            entries.append((entry.name, entry.stat(follow_symlinks=False)))
    for entry_name, metadata in entries:
        budget.check_time()
        kind = _validate_entry(
            metadata,
            root_device=root_device,
            protected_identities=protected_identities,
        )
        if kind == "file":
            current = os.stat(entry_name, dir_fd=descriptor, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino):
                raise ArchiveError("an archive entry changed before deletion")
            os.unlink(entry_name, dir_fd=descriptor)
            continue
        child_fd = os.open(entry_name, _directory_flags(), dir_fd=descriptor)
        try:
            opened = os.fstat(child_fd)
            if (opened.st_dev, opened.st_ino) != (
                metadata.st_dev,
                metadata.st_ino,
            ):
                raise ArchiveError("an archive directory changed before deletion")
            _delete_directory_contents(
                child_fd,
                root_device=root_device,
                protected_identities=protected_identities,
                budget=budget,
            )
        finally:
            os.close(child_fd)
        current = os.stat(entry_name, dir_fd=descriptor, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise ArchiveError("an archive directory changed before removal")
        os.rmdir(entry_name, dir_fd=descriptor)


@enforce_posix_hard_timeout
def execute_retention(
    contract: ArchiveContract,
    record: ArchiveRecord,
    *,
    expected_uid: int,
    expected_gid: int | None = None,
    max_files: int = DEFAULT_MAX_FILES,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
) -> None:
    if os.name != "posix":
        raise ArchiveError("archive deletion requires POSIX descriptor semantics")
    _validate_archive_name(record.name)
    if expected_gid is None:
        expected_gid = os.getgid() if hasattr(os, "getgid") else expected_uid
    root_metadata = validate_contract(contract, expected_uid=expected_uid, expected_gid=expected_gid)
    assert_no_archive_submounts(contract.archive_root)
    protected = _protected_identities(contract)
    root_fd = _open_verified_directory(contract.archive_root, root_metadata)
    audit_fd: int | None = None
    request_id = str(uuid.uuid4())
    started = False
    try:
        selected = os.stat(record.name, dir_fd=root_fd, follow_symlinks=False)
        if not stat.S_ISDIR(selected.st_mode) or (
            selected.st_dev,
            selected.st_ino,
        ) != (record.device, record.inode):
            raise ArchiveError("the selected archive changed after dry-run")
        if (
            (selected.st_uid, selected.st_gid) != (expected_uid, expected_gid)
            or stat.S_IMODE(selected.st_mode) != 0o700
        ):
            raise ArchiveError("the selected archive violates owner or mode")
        selected_fd = os.open(record.name, _directory_flags(), dir_fd=root_fd)
        try:
            opened = os.fstat(selected_fd)
            if (opened.st_dev, opened.st_ino) != (
                selected.st_dev,
                selected.st_ino,
            ):
                raise ArchiveError("the selected archive changed before deletion")
            verification_budget = ScanBudget(
                max_files, time.monotonic() + timeout_seconds
            )
            _scan_directory_fd(
                selected_fd,
                root_device=root_metadata.st_dev,
                protected_identities=protected,
                budget=verification_budget,
            )
            assert_no_archive_submounts(contract.archive_root)
            audit_fd = _open_audit(root_fd, expected_uid, expected_gid)
            _append_audit(
                audit_fd,
                request_id=request_id,
                archive_name=record.name,
                event="started",
            )
            started = True
            os.fsync(root_fd)
            deletion_budget = ScanBudget(max_files, time.monotonic() + timeout_seconds)
            _delete_directory_contents(
                selected_fd,
                root_device=root_metadata.st_dev,
                protected_identities=protected,
                budget=deletion_budget,
            )
        finally:
            os.close(selected_fd)
        current = os.stat(record.name, dir_fd=root_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (selected.st_dev, selected.st_ino):
            raise ArchiveError("the selected archive changed before final removal")
        os.rmdir(record.name, dir_fd=root_fd)
        os.fsync(root_fd)
        assert audit_fd is not None
        _append_audit(
            audit_fd,
            request_id=request_id,
            archive_name=record.name,
            event="completed",
        )
    except Exception:
        if started and audit_fd is not None:
            try:
                with posix_hard_timeout(
                    min(timeout_seconds, FAILURE_AUDIT_TIMEOUT_SECONDS)
                ):
                    _append_audit(
                        audit_fd,
                        request_id=request_id,
                        archive_name=record.name,
                        event="failed",
                    )
            except (ArchiveError, OSError) as audit_error:
                raise ArchiveError(
                    "archive deletion failed and its failure audit could not be completed"
                ) from audit_error
        raise
    finally:
        if audit_fd is not None:
            os.close(audit_fd)
        os.close(root_fd)


def inventory_to_dict(inventory: Inventory) -> dict[str, object]:
    return {
        "schemaVersion": inventory.schemaVersion,
        "archiveCount": inventory.archiveCount,
        "totalApparentBytes": inventory.totalApparentBytes,
        "totalRegularFiles": inventory.totalRegularFiles,
        "oldest": inventory.oldest,
        "newest": inventory.newest,
        "archives": [
            {
                "name": record.name,
                "apparentBytes": record.apparentBytes,
                "regularFiles": record.regularFiles,
                "directories": record.directories,
                "modifiedUtc": record.modifiedUtc,
            }
            for record in inventory.archives
        ],
    }


def print_inventory(inventory: Inventory, *, as_json: bool, output: TextIO) -> None:
    if as_json:
        print(json.dumps(inventory_to_dict(inventory), sort_keys=True), file=output)
        return
    print(f"Archives: {inventory.archiveCount}", file=output)
    print(f"Total apparent bytes: {inventory.totalApparentBytes}", file=output)
    print(f"Total regular files: {inventory.totalRegularFiles}", file=output)
    oldest = inventory.oldest or {"name": "none", "modifiedUtc": "none"}
    newest = inventory.newest or {"name": "none", "modifiedUtc": "none"}
    print(f"Oldest: {oldest['name']} ({oldest['modifiedUtc']})", file=output)
    print(f"Newest: {newest['name']} ({newest['modifiedUtc']})", file=output)
    for record in inventory.archives:
        print(
            f"- {record.name}: {record.apparentBytes} bytes, "
            f"{record.regularFiles} files, modified {record.modifiedUtc}",
            file=output,
        )


def _bounded_identity(value: int, label: str) -> int:
    if value < 0 or value > 2**31 - 1:
        raise ArchiveError(f"{label} is outside the supported identity range")
    return value


def _parse_octal_mode(value: str) -> int:
    if not re.fullmatch(r"[0-7]{3,4}", value):
        raise argparse.ArgumentTypeError("mode must contain three or four octal digits")
    return int(value, 8)


def _operator_identity(arguments: argparse.Namespace) -> ManagementIdentity:
    explicit = (arguments.operator_uid, arguments.operator_gid)
    if any(value is not None for value in explicit):
        if any(value is None for value in explicit):
            raise ArchiveError("operator identity arguments must be provided together")
        return ManagementIdentity(
            _bounded_identity(arguments.operator_uid, "operator uid"),
            _bounded_identity(arguments.operator_gid, "operator gid"),
        )

    sudo_uid = os.environ.get("SUDO_UID")
    sudo_gid = os.environ.get("SUDO_GID")
    if sudo_uid is not None or sudo_gid is not None:
        if (
            sudo_uid is None
            or sudo_gid is None
            or not sudo_uid.isdecimal()
            or not sudo_gid.isdecimal()
        ):
            raise ArchiveError("sudo operator identity is incomplete or invalid")
        return ManagementIdentity(
            _bounded_identity(int(sudo_uid, 10), "sudo operator uid"),
            _bounded_identity(int(sudo_gid, 10), "sudo operator gid"),
        )

    if not hasattr(os, "geteuid") or not hasattr(os, "getegid"):
        raise ArchiveError("the operator identity is unavailable")
    return ManagementIdentity(os.geteuid(), os.getegid())


def _management_env_metadata(
    arguments: argparse.Namespace,
    env_file: Path,
) -> tuple[int, int, int]:
    explicit = (
        arguments.env_owner_uid,
        arguments.env_owner_gid,
        arguments.env_mode,
    )
    if any(value is not None for value in explicit):
        if any(value is None for value in explicit):
            raise ArchiveError(
                "management environment metadata arguments must be provided together"
            )
        owner_uid, owner_gid, mode = explicit
        return (
            _bounded_identity(owner_uid, "environment owner uid"),
            _bounded_identity(owner_gid, "environment owner gid"),
            mode,
        )
    try:
        metadata = env_file.lstat()
    except OSError as exc:
        raise ArchiveError("the management environment metadata is unavailable") from exc
    return metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inventory archives or explicitly retire exactly one archive."
    )
    parser.add_argument("--env-owner-uid", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--env-owner-gid", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--env-mode", type=_parse_octal_mode, help=argparse.SUPPRESS)
    parser.add_argument("--operator-uid", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--operator-gid", type=int, help=argparse.SUPPRESS)
    parser.add_argument(
        "--testing-env-file",
        type=Path,
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--max-files",
        type=int,
        default=DEFAULT_MAX_FILES,
        help="maximum filesystem entries inspected in one phase",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="hard limit for each inventory or deletion phase",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    inventory_parser = subparsers.add_parser("inventory")
    inventory_parser.add_argument("--json", action="store_true")
    retention_parser = subparsers.add_parser("retention")
    retention_parser.add_argument("--archive", required=True)
    retention_parser.add_argument("--execute", action="store_true")
    retention_parser.add_argument("--confirm")
    retention_parser.add_argument("--json", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.max_files <= 0 or arguments.timeout_seconds <= 0:
            raise ArchiveError("archive limits must be positive")
        testing = os.environ.get("CF_AGENT_WECHAT_TESTING") == "1"
        if arguments.testing_env_file is not None:
            if not testing or arguments.command != "inventory":
                raise ArchiveError(
                    "the test environment override is limited to read-only inventory"
                )
            if not hasattr(os, "geteuid"):
                raise ArchiveError("the testing identity is unavailable")
            env_file = arguments.testing_env_file
            expected_uid = os.geteuid()
            expected_gid = os.getegid() if hasattr(os, "getegid") else expected_uid
            allow_portable_testing = os.name != "posix"
        else:
            if (
                os.name != "posix"
                or not hasattr(os, "geteuid")
                or os.geteuid() != 0
            ):
                raise ArchiveError(
                    "archive management must run as root on a POSIX host"
                )
            env_file = Path(__file__).resolve().parents[1] / "docker" / ".env"
            expected_uid = 0
            expected_gid = 0
            allow_portable_testing = False
        env_owner_uid, env_owner_gid, env_mode = _management_env_metadata(
            arguments,
            env_file,
        )
        operator = _operator_identity(arguments)
        with posix_hard_timeout(arguments.timeout_seconds):
            contract = load_contract(
                env_file,
                expected_uid=env_owner_uid,
                expected_gid=env_owner_gid,
                expected_mode=env_mode,
            )
            validate_management_env_metadata(
                env_owner_uid,
                env_owner_gid,
                env_mode,
                operator,
                contract.management_gid,
            )
            if arguments.testing_env_file is None:
                validate_production_contract_paths(contract)
            inventory = inventory_archives(
                contract,
                expected_uid=expected_uid,
                expected_gid=expected_gid,
                max_files=arguments.max_files,
                timeout_seconds=arguments.timeout_seconds,
                allow_portable_testing=allow_portable_testing,
            )
        if arguments.command == "inventory":
            print_inventory(inventory, as_json=arguments.json, output=sys.stdout)
            return 0

        plan = retention_plan(inventory, arguments.archive)
        if not arguments.execute:
            if arguments.json:
                print(json.dumps(plan, sort_keys=True))
            else:
                print(
                    f"Dry run only: {arguments.archive} would be deleted; "
                    "no archive was changed."
                )
            return 0

        phrase = f"DELETE:{arguments.archive}"
        if arguments.confirm != phrase or not sys.stdin.isatty():
            raise ArchiveError(
                "execute mode requires --confirm DELETE:<archive> and a TTY"
            )
        typed = input(f"Retype {phrase} to confirm permanent deletion: ")
        validate_execute_confirmation(
            arguments.archive,
            arguments.confirm,
            typed,
            is_tty=True,
        )
        record = next(
            record for record in inventory.archives if record.name == arguments.archive
        )
        lock_fd = acquire_management_lock(contract)
        try:
            execute_retention(
                contract,
                record,
                expected_uid=0,
                expected_gid=0,
                max_files=arguments.max_files,
                timeout_seconds=arguments.timeout_seconds,
            )
        finally:
            release_management_lock(lock_fd)
        print(f"Deleted archive {arguments.archive}; audit record written.")
        return 0
    except InvalidArchiveNamesError as exc:
        print(
            f"[FAIL] archive inventory rejected {exc.count} "
            "non-production archive name(s); names were redacted",
            file=sys.stderr,
        )
        return 1
    except Exception:  # noqa: BLE001 - production CLI errors are always redacted.
        print(
            "[FAIL] archive request failed closed; no unverified path was selected",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
