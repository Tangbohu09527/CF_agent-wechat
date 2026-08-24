#!/usr/bin/env python3
"""Bounded, no-follow scan for unsafe runtime entries and Token bytes."""

from __future__ import annotations

import argparse
import os
import re
import stat
import time
from pathlib import Path, PurePosixPath
from typing import NamedTuple


READ_CHUNK_BYTES = 1024 * 1024
MAX_DIRECTORY_DEPTH = 128
MAX_MOUNTINFO_BYTES = 4 * 1024 * 1024
MAX_ATTESTATION_PATH_BYTES = 64 * 1024 * 1024
MAX_ATTESTATION_ENTRIES = 200_000
MOUNTINFO_PATH = Path("/proc/self/mountinfo")
TOKEN_PATTERN = re.compile(rb"[0-9a-f]{64}")
MOUNTINFO_ESCAPE = re.compile(rb"\x5c([0-7]{3})")


class ScanError(Exception):
    """A non-sensitive runtime scan failure."""


class EntryAttestation(NamedTuple):
    relative_path: str
    identity: tuple[int, ...]


class TreeAttestation(NamedTuple):
    root_identity: tuple[int, ...]
    entries: tuple[EntryAttestation, ...]


def validate_empty_runtime_layout(attestation: TreeAttestation) -> None:
    """Require exactly the two empty directories used by a fresh runtime."""
    expected_paths = {"data", "wechat-home"}
    observed_paths = {
        entry.relative_path for entry in attestation.entries
    }
    if observed_paths != expected_paths or len(attestation.entries) != 2:
        raise ScanError("fresh runtime layout is not empty and exact")
    if any(
        not stat.S_ISDIR(entry.identity[2])
        for entry in attestation.entries
    ):
        raise ScanError("fresh runtime layout is not empty and exact")


def stable_identity(metadata: os.stat_result) -> tuple[int, ...]:
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


def reject_extended_attributes(descriptor: int) -> None:
    """Reject xattrs, including POSIX ACLs, without exposing their contents."""
    try:
        attributes = os.listxattr(descriptor)
    except OSError as exc:
        raise ScanError(
            "runtime entry extended attributes could not be inspected"
        ) from exc
    if attributes:
        raise ScanError("runtime tree contains extended attributes or ACLs")


def reject_token_in_entry_name(name: str, token: bytes) -> None:
    try:
        encoded_name = os.fsencode(name)
    except (UnicodeError, ValueError) as exc:
        raise ScanError("runtime entry name could not be inspected") from exc
    if token in encoded_name:
        raise ScanError("runtime entry name contains protected Token bytes")


def attestation_path_size(relative_path: str) -> int:
    try:
        return len(os.fsencode(relative_path))
    except (UnicodeError, ValueError) as exc:
        raise ScanError("runtime attestation path could not be inspected") from exc


def read_mountinfo() -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(MOUNTINFO_PATH, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ScanError("mount table source is not a regular file")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(
                descriptor,
                min(65536, MAX_MOUNTINFO_BYTES + 1 - total),
            )
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_MOUNTINFO_BYTES:
                raise ScanError("mount table exceeds its size limit")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def decode_mountinfo_path(value: bytes) -> PurePosixPath:
    def replace_escape(match: re.Match[bytes]) -> bytes:
        return bytes((int(match.group(1), 8),))

    decoded = MOUNTINFO_ESCAPE.sub(replace_escape, value)
    if b"\\" in decoded or b"\x00" in decoded:
        raise ScanError("mount table contains an invalid escaped path")
    path = PurePosixPath(os.fsdecode(decoded))
    if not path.is_absolute():
        raise ScanError("mount table contains a non-absolute mount point")
    return path


def parse_mountinfo(contents: bytes) -> frozenset[PurePosixPath]:
    if not contents or len(contents) > MAX_MOUNTINFO_BYTES:
        raise ScanError("mount table is empty or exceeds its size limit")
    mount_points: set[PurePosixPath] = set()
    for line in contents.splitlines():
        fields = line.split(b" ")
        try:
            separator = fields.index(b"-")
        except ValueError as exc:
            raise ScanError("mount table contains an invalid record") from exc
        if separator < 6 or len(fields) < separator + 4:
            raise ScanError("mount table contains an invalid record")
        mount_points.add(decode_mountinfo_path(fields[4]))
    if not mount_points:
        raise ScanError("mount table does not contain any mount points")
    return frozenset(mount_points)


def reject_nested_mountpoints(
    canonical_root: PurePosixPath,
    mount_points: frozenset[PurePosixPath],
) -> None:
    if not canonical_root.is_absolute():
        raise ScanError("runtime root could not be canonicalized")
    for mount_point in mount_points:
        try:
            relative = mount_point.relative_to(canonical_root)
        except ValueError:
            continue
        if relative != PurePosixPath("."):
            raise ScanError("runtime tree contains a nested mount point")


def validate_mount_boundaries(root: Path) -> None:
    canonical_root = PurePosixPath(os.path.realpath(root))
    reject_nested_mountpoints(
        canonical_root,
        parse_mountinfo(read_mountinfo()),
    )


def directory_changed(
    opened: os.stat_result,
    current: os.stat_result,
    root_device: int,
) -> bool:
    return (
        (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
        or current.st_dev != root_device
        or not stat.S_ISDIR(current.st_mode)
        or current.st_ctime_ns != opened.st_ctime_ns
    )


def read_token(path: Path) -> bytes:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ScanError("token source is not a single-link regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino)
            != (metadata.st_dev, metadata.st_ino)
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
        ):
            raise ScanError("token source changed during inspection")
        value = b""
        while len(value) <= 8192:
            chunk = os.read(descriptor, 8193 - len(value))
            if not chunk:
                break
            value += chunk
        final = os.fstat(descriptor)
        if (
            final.st_size != opened.st_size
            or final.st_ctime_ns != opened.st_ctime_ns
        ):
            raise ScanError("token source changed during inspection")
    finally:
        os.close(descriptor)
    if value.endswith(b"\n"):
        value = value[:-1]
    if TOKEN_PATTERN.fullmatch(value) is None:
        raise ScanError("token source has invalid content")
    return value


def scan_file(
    directory_fd: int,
    name: str,
    metadata: os.stat_result,
    token: bytes,
    max_bytes: int,
    deadline: float,
) -> tuple[int, tuple[int, ...]]:
    if metadata.st_size > max_bytes:
        raise ScanError("runtime scan exceeded its byte limit")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_BINARY", 0)
    flags |= getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(name, flags, dir_fd=directory_fd)
    try:
        opened = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino)
            != (metadata.st_dev, metadata.st_ino)
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
        ):
            raise ScanError("runtime entry changed during inspection")
        reject_extended_attributes(descriptor)
        if opened.st_size > max_bytes:
            raise ScanError("runtime scan exceeded its byte limit")
        overlap = b""
        overlap_size = len(token) - 1
        scanned = 0
        while True:
            if time.monotonic() > deadline:
                raise ScanError("runtime scan exceeded its time limit")
            chunk = os.read(
                descriptor,
                min(READ_CHUNK_BYTES, max_bytes - scanned + 1),
            )
            if not chunk:
                break
            scanned += len(chunk)
            if scanned > max_bytes:
                raise ScanError("runtime scan exceeded its byte limit")
            candidate = overlap + chunk
            if token in candidate:
                raise ScanError("runtime payload contains protected Token bytes")
            overlap = candidate[-overlap_size:] if overlap_size else b""
        reject_extended_attributes(descriptor)
        final = os.fstat(descriptor)
        if stable_identity(final) != stable_identity(opened):
            raise ScanError("runtime entry changed during inspection")
        return scanned, stable_identity(final)
    finally:
        os.close(descriptor)


def scan_tree(
    root: Path,
    token: bytes,
    max_files: int,
    max_bytes: int,
    deadline: float,
) -> TreeAttestation:
    if max_files <= 0 or max_files > MAX_ATTESTATION_ENTRIES:
        raise ScanError("runtime scan file-count limit is invalid")
    if max_bytes <= 0:
        raise ScanError("runtime scan limits are invalid")
    validate_mount_boundaries(root)
    root_metadata = root.lstat()
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise ScanError("runtime root is not a directory")
    root_device = root_metadata.st_dev
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    root_fd = os.open(root, directory_flags)
    opened_root = os.fstat(root_fd)
    if directory_changed(root_metadata, opened_root, root_device):
        os.close(root_fd)
        raise ScanError("runtime root changed during inspection")
    try:
        reject_extended_attributes(root_fd)
        root_entries = os.scandir(root_fd)
    except BaseException:
        os.close(root_fd)
        raise
    stack = [(root_fd, root_entries, 0, opened_root, "")]
    seen_directories = {(opened_root.st_dev, opened_root.st_ino)}
    attestations: list[EntryAttestation] = []
    entries_seen = 0
    total_bytes = 0
    total_path_bytes = 0
    final_root_identity: tuple[int, ...] | None = None

    try:
        while stack:
            if time.monotonic() > deadline:
                raise ScanError("runtime scan exceeded its time limit")
            (
                directory_fd,
                entries,
                depth,
                opened_directory,
                directory_path,
            ) = stack[-1]
            try:
                entry = next(entries)
            except StopIteration:
                entries.close()
                final_directory = os.fstat(directory_fd)
                if directory_changed(
                    opened_directory,
                    final_directory,
                    root_device,
                ):
                    raise ScanError(
                        "runtime directory changed during inspection"
                    )
                directory_identity = stable_identity(final_directory)
                if stable_identity(opened_directory) != directory_identity:
                    raise ScanError(
                        "runtime directory changed during inspection"
                    )
                if directory_path:
                    attestations.append(
                        EntryAttestation(directory_path, directory_identity)
                    )
                else:
                    final_root_identity = directory_identity
                os.close(directory_fd)
                stack.pop()
                continue

            if time.monotonic() > deadline:
                raise ScanError("runtime scan exceeded its time limit")
            entries_seen += 1
            if entries_seen > max_files:
                raise ScanError("runtime scan exceeded its file-count limit")
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise ScanError(
                    "runtime entry metadata could not be read"
                ) from exc
            mode = metadata.st_mode
            relative_path = (
                entry.name
                if not directory_path
                else f"{directory_path}/{entry.name}"
            )
            total_path_bytes += attestation_path_size(relative_path)
            if total_path_bytes > MAX_ATTESTATION_PATH_BYTES:
                raise ScanError("runtime scan exceeded its path-byte limit")
            reject_token_in_entry_name(entry.name, token)
            if stat.S_ISLNK(mode):
                raise ScanError("runtime tree contains a symbolic link")
            if metadata.st_dev != root_device:
                raise ScanError("runtime tree crosses a filesystem boundary")
            if stat.S_ISDIR(mode):
                if depth >= MAX_DIRECTORY_DEPTH:
                    raise ScanError(
                        "runtime tree exceeds its directory-depth limit"
                    )
                directory_key = (metadata.st_dev, metadata.st_ino)
                if directory_key in seen_directories:
                    raise ScanError("runtime tree contains a repeated directory")
                child_fd = os.open(
                    entry.name,
                    directory_flags,
                    dir_fd=directory_fd,
                )
                try:
                    child = os.fstat(child_fd)
                    if directory_changed(metadata, child, root_device):
                        raise ScanError(
                            "runtime directory changed during inspection"
                        )
                    reject_extended_attributes(child_fd)
                    child_entries = os.scandir(child_fd)
                except BaseException:
                    os.close(child_fd)
                    raise
                seen_directories.add(directory_key)
                stack.append(
                    (
                        child_fd,
                        child_entries,
                        depth + 1,
                        child,
                        relative_path,
                    )
                )
                continue
            if not stat.S_ISREG(mode):
                raise ScanError("runtime tree contains a special file")
            if metadata.st_nlink != 1:
                raise ScanError("runtime tree contains a hard-linked file")
            scanned, file_identity = scan_file(
                directory_fd,
                entry.name,
                metadata,
                token,
                max_bytes - total_bytes,
                deadline,
            )
            total_bytes += scanned
            attestations.append(
                EntryAttestation(relative_path, file_identity)
            )
    finally:
        for directory_fd, entries, _depth, _opened, _path in reversed(stack):
            entries.close()
            os.close(directory_fd)
    if final_root_identity is None:
        raise ScanError("runtime root identity was not captured")
    try:
        final_root_path = root.lstat()
    except OSError as exc:
        raise ScanError("runtime root changed during inspection") from exc
    if stable_identity(final_root_path) != final_root_identity:
        raise ScanError("runtime root changed during inspection")
    validate_mount_boundaries(root)
    return TreeAttestation(
        final_root_identity,
        tuple(sorted(attestations, key=lambda item: item.relative_path)),
    )


def validate_attestation_path(relative_path: str) -> None:
    components = relative_path.split("/")
    if (
        not relative_path
        or relative_path.startswith("/")
        or any(component in {"", ".", ".."} for component in components)
    ):
        raise ScanError("runtime attestation contains an invalid path")


def verify_tree_attestation(
    root: Path,
    attestation: TreeAttestation,
    max_files: int,
    deadline: float,
) -> None:
    if max_files <= 0 or max_files > MAX_ATTESTATION_ENTRIES:
        raise ScanError("runtime attestation file-count limit is invalid")
    if (
        len(attestation.entries) > max_files
        or len(attestation.entries) > MAX_ATTESTATION_ENTRIES
    ):
        raise ScanError("runtime attestation exceeds its file-count limit")
    expected: dict[str, tuple[int, ...]] = {}
    expected_path_bytes = 0
    for entry in attestation.entries:
        validate_attestation_path(entry.relative_path)
        expected_path_bytes += attestation_path_size(entry.relative_path)
        if expected_path_bytes > MAX_ATTESTATION_PATH_BYTES:
            raise ScanError("runtime attestation exceeds its path-byte limit")
        if entry.relative_path in expected:
            raise ScanError("runtime attestation contains a duplicate path")
        expected[entry.relative_path] = entry.identity

    validate_mount_boundaries(root)
    try:
        root_metadata = root.lstat()
    except OSError as exc:
        raise ScanError("runtime root changed after inspection") from exc
    if stable_identity(root_metadata) != attestation.root_identity:
        raise ScanError("runtime root changed after inspection")
    root_device = root_metadata.st_dev
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    file_flags |= getattr(os, "O_BINARY", 0)
    file_flags |= getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)
    root_fd = os.open(root, directory_flags)
    opened_root = os.fstat(root_fd)
    if stable_identity(opened_root) != attestation.root_identity:
        os.close(root_fd)
        raise ScanError("runtime root changed after inspection")
    try:
        reject_extended_attributes(root_fd)
        root_entries = os.scandir(root_fd)
    except BaseException:
        os.close(root_fd)
        raise
    stack = [(root_fd, root_entries, 0, opened_root, "")]
    observed: set[str] = set()
    observed_path_bytes = 0

    try:
        while stack:
            if time.monotonic() > deadline:
                raise ScanError("runtime scan exceeded its time limit")
            (
                directory_fd,
                entries,
                depth,
                _opened_directory,
                directory_path,
            ) = stack[-1]
            try:
                entry = next(entries)
            except StopIteration:
                entries.close()
                final_directory = os.fstat(directory_fd)
                expected_identity = (
                    attestation.root_identity
                    if not directory_path
                    else expected[directory_path]
                )
                if stable_identity(final_directory) != expected_identity:
                    raise ScanError("runtime tree changed after inspection")
                os.close(directory_fd)
                stack.pop()
                continue

            relative_path = (
                entry.name
                if not directory_path
                else f"{directory_path}/{entry.name}"
            )
            observed_path_bytes += attestation_path_size(relative_path)
            if observed_path_bytes > MAX_ATTESTATION_PATH_BYTES:
                raise ScanError("runtime tree exceeds its path-byte limit")
            expected_identity = expected.get(relative_path)
            if expected_identity is None or relative_path in observed:
                raise ScanError("runtime tree changed after inspection")
            observed.add(relative_path)
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise ScanError("runtime tree changed after inspection") from exc
            if stable_identity(metadata) != expected_identity:
                raise ScanError("runtime tree changed after inspection")
            mode = metadata.st_mode
            if metadata.st_dev != root_device:
                raise ScanError("runtime tree crosses a filesystem boundary")
            if stat.S_ISDIR(mode):
                if depth >= MAX_DIRECTORY_DEPTH:
                    raise ScanError(
                        "runtime tree exceeds its directory-depth limit"
                    )
                child_fd = os.open(
                    entry.name,
                    directory_flags,
                    dir_fd=directory_fd,
                )
                try:
                    child = os.fstat(child_fd)
                    if stable_identity(child) != expected_identity:
                        raise ScanError("runtime tree changed after inspection")
                    reject_extended_attributes(child_fd)
                    child_entries = os.scandir(child_fd)
                except BaseException:
                    os.close(child_fd)
                    raise
                stack.append(
                    (
                        child_fd,
                        child_entries,
                        depth + 1,
                        child,
                        relative_path,
                    )
                )
                continue
            if not stat.S_ISREG(mode) or metadata.st_nlink != 1:
                raise ScanError("runtime tree changed after inspection")
            descriptor = os.open(
                entry.name,
                file_flags,
                dir_fd=directory_fd,
            )
            try:
                opened_file = os.fstat(descriptor)
                if stable_identity(opened_file) != expected_identity:
                    raise ScanError("runtime tree changed after inspection")
                reject_extended_attributes(descriptor)
                after_xattrs = os.fstat(descriptor)
                if stable_identity(after_xattrs) != expected_identity:
                    raise ScanError("runtime tree changed after inspection")
            finally:
                os.close(descriptor)
    finally:
        for directory_fd, entries, _depth, _opened, _path in reversed(stack):
            entries.close()
            os.close(directory_fd)

    if observed != set(expected):
        raise ScanError("runtime tree changed after inspection")
    try:
        final_root_path = root.lstat()
    except OSError as exc:
        raise ScanError("runtime root changed after inspection") from exc
    if stable_identity(final_root_path) != attestation.root_identity:
        raise ScanError("runtime root changed after inspection")
    validate_mount_boundaries(root)


def open_protected_parent(path: Path) -> tuple[int, os.stat_result]:
    if (
        not path.is_absolute()
        or path.parent == path
        or any(part in {".", ".."} for part in path.parts)
    ):
        raise ScanError("runtime move path is invalid")
    parent = path.parent
    try:
        metadata = parent.lstat()
    except OSError as exc:
        raise ScanError("runtime move parent could not be inspected") from exc
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid not in {0, os.geteuid()}
        or stat.S_IMODE(metadata.st_mode) & 0o022
    ):
        raise ScanError("runtime move parent is not protected")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(parent, flags)
    opened = os.fstat(descriptor)
    if stable_identity(opened) != stable_identity(metadata):
        os.close(descriptor)
        raise ScanError("runtime move parent changed during inspection")
    try:
        reject_extended_attributes(descriptor)
        after_xattrs = os.fstat(descriptor)
        if stable_identity(after_xattrs) != stable_identity(opened):
            raise ScanError("runtime move parent changed during inspection")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor, after_xattrs


def assert_destination_absent(directory_fd: int, name: str) -> None:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise ScanError("archive destination could not be inspected") from exc
    raise ScanError("archive destination already exists")


def same_object_after_rename(
    before: tuple[int, ...],
    after: tuple[int, ...],
) -> bool:
    return before[:-1] == after[:-1]


def validate_reserved_top_level_names(
    attestation: TreeAttestation,
    reserved_names: tuple[str, ...],
) -> None:
    reserved = set()
    for name in reserved_names:
        if not name or "/" in name or name in {".", ".."}:
            raise ScanError("archive reserved name is invalid")
        reserved.add(name)
    if any(entry.relative_path in reserved for entry in attestation.entries):
        raise ScanError("runtime contains a reserved archive metadata path")


def testing_move_barrier(
    configuration: tuple[Path, Path] | None,
) -> None:
    """Pause after durable rename only for direct, explicit test execution."""
    if configuration is None:
        return
    marker, release = configuration
    if (
        not marker.is_absolute()
        or not release.is_absolute()
        or marker == release
    ):
        raise ScanError("testing move barrier configuration is invalid")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(marker, flags, 0o600)
    try:
        payload = b"rename-and-parent-fsync-complete\n"
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

    while True:
        try:
            metadata = release.lstat()
        except FileNotFoundError:
            time.sleep(0.01)
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise ScanError("testing move barrier release is invalid")
        return

def move_attested_tree(
    root: Path,
    destination: Path,
    attestation: TreeAttestation,
    max_files: int,
    deadline: float,
    testing_barrier_paths: tuple[Path, Path] | None = None,
) -> None:
    source_parent_fd = -1
    destination_parent_fd = -1
    moved = False
    try:
        source_parent_fd, source_parent = open_protected_parent(root)
        destination_parent_fd, destination_parent = open_protected_parent(
            destination
        )
        if (
            source_parent.st_dev != destination_parent.st_dev
            or attestation.root_identity[0] != source_parent.st_dev
        ):
            raise ScanError(
                "runtime source and archive destination are on different filesystems"
            )
        try:
            source = os.stat(
                root.name,
                dir_fd=source_parent_fd,
                follow_symlinks=False,
            )
        except OSError as exc:
            raise ScanError("runtime root changed after inspection") from exc
        if stable_identity(source) != attestation.root_identity:
            raise ScanError("runtime root changed after inspection")
        assert_destination_absent(destination_parent_fd, destination.name)
        verify_tree_attestation(root, attestation, max_files, deadline)
        source = os.stat(
            root.name,
            dir_fd=source_parent_fd,
            follow_symlinks=False,
        )
        if stable_identity(source) != attestation.root_identity:
            raise ScanError("runtime root changed after inspection")
        assert_destination_absent(destination_parent_fd, destination.name)
        os.rename(
            root.name,
            destination.name,
            src_dir_fd=source_parent_fd,
            dst_dir_fd=destination_parent_fd,
        )
        moved = True
        os.fsync(source_parent_fd)
        os.fsync(destination_parent_fd)
        testing_move_barrier(testing_barrier_paths)
        try:
            os.stat(
                root.name,
                dir_fd=source_parent_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise ScanError("runtime source still exists after archive move")
        archived = os.stat(
            destination.name,
            dir_fd=destination_parent_fd,
            follow_symlinks=False,
        )
        archived_identity = stable_identity(archived)
        if not same_object_after_rename(
            attestation.root_identity,
            archived_identity,
        ):
            raise ScanError("archive destination identity is invalid")
        moved_attestation = TreeAttestation(
            archived_identity,
            attestation.entries,
        )
        verify_tree_attestation(
            destination,
            moved_attestation,
            max_files,
            deadline,
        )
    except BaseException:
        if moved:
            try:
                assert_destination_absent(source_parent_fd, root.name)
                archived = os.stat(
                    destination.name,
                    dir_fd=destination_parent_fd,
                    follow_symlinks=False,
                )
                archived_identity = stable_identity(archived)
                if (
                    archived_identity[:2] != attestation.root_identity[:2]
                    or not stat.S_ISDIR(archived.st_mode)
                ):
                    raise ScanError("archive rollback identity is invalid")
                os.rename(
                    destination.name,
                    root.name,
                    src_dir_fd=destination_parent_fd,
                    dst_dir_fd=source_parent_fd,
                )
                os.fsync(source_parent_fd)
                os.fsync(destination_parent_fd)
                moved = False
            except BaseException as exc:
                raise ScanError(
                    "archive verification failed and rollback was incomplete"
                ) from exc
        raise
    finally:
        if destination_parent_fd >= 0:
            os.close(destination_parent_fd)
        if source_parent_fd >= 0:
            os.close(source_parent_fd)


def scan_and_move_tree(
    root: Path,
    destination: Path,
    token: bytes,
    max_files: int,
    max_bytes: int,
    deadline: float,
    reserved_top_level_names: tuple[str, ...] = (),
    testing_barrier_paths: tuple[Path, Path] | None = None,
) -> None:
    if root == destination:
        raise ScanError("runtime source and archive destination must differ")
    attestation = scan_tree(root, token, max_files, max_bytes, deadline)
    validate_reserved_top_level_names(
        attestation,
        reserved_top_level_names,
    )
    move_attested_tree(
        root,
        destination,
        attestation,
        max_files,
        deadline,
        testing_barrier_paths,
    )


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--root", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--max-files", type=int, required=True)
    parser.add_argument("--max-bytes", type=int, required=True)
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--move-to")
    parser.add_argument("--require-empty-runtime-layout", action="store_true")
    parser.add_argument("--testing", action="store_true")
    parser.add_argument("--testing-move-barrier-marker")
    parser.add_argument("--testing-move-barrier-release")
    parser.add_argument(
        "--reserved-top-level-name",
        action="append",
        default=[],
    )
    arguments = parser.parse_args()
    if min(arguments.max_files, arguments.max_bytes, arguments.timeout_seconds) <= 0:
        return 2
    if arguments.move_to is None and arguments.reserved_top_level_name:
        return 2
    if arguments.move_to is not None and arguments.require_empty_runtime_layout:
        return 2
    barrier_values = (
        arguments.testing_move_barrier_marker,
        arguments.testing_move_barrier_release,
    )
    if any(barrier_values):
        if (
            not arguments.testing
            or not all(barrier_values)
            or arguments.move_to is None
        ):
            return 2
        testing_barrier_paths = (
            Path(arguments.testing_move_barrier_marker),
            Path(arguments.testing_move_barrier_release),
        )
        if (
            not testing_barrier_paths[0].is_absolute()
            or not testing_barrier_paths[1].is_absolute()
            or testing_barrier_paths[0] == testing_barrier_paths[1]
        ):
            return 2
    else:
        testing_barrier_paths = None
    try:
        token = read_token(Path(arguments.token_file))
        deadline = time.monotonic() + arguments.timeout_seconds
        root = Path(arguments.root)
        if arguments.move_to is None:
            attestation = scan_tree(
                root,
                token,
                arguments.max_files,
                arguments.max_bytes,
                deadline,
            )
            if arguments.require_empty_runtime_layout:
                validate_empty_runtime_layout(attestation)
        else:
            scan_and_move_tree(
                root,
                Path(arguments.move_to),
                token,
                arguments.max_files,
                arguments.max_bytes,
                deadline,
                tuple(arguments.reserved_top_level_name),
                testing_barrier_paths,
            )
    except (OSError, ScanError):
        return 1
    finally:
        if "token" in locals():
            token = b""
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
