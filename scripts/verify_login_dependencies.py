#!/usr/bin/env python3
"""Validate the QR dependency lock and a venv without executing that venv."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import os
import platform
import re
import shlex
import stat
import sys
import sysconfig
from dataclasses import dataclass
from email.parser import BytesParser
from pathlib import Path, PurePosixPath


CONTRACT_SCHEMA_VERSION = 3
EXPECTED_PACKAGES = {
    "pillow": "PIL",
    "qrcode": "qrcode",
    "websocket-client": "websocket",
}
NAME_NORMALIZER = re.compile(r"[-_.]+")
PIN_PATTERN = re.compile(
    r"(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)=="
    r"(?P<version>[A-Za-z0-9][A-Za-z0-9._+!-]*)"
)
HASH_PATTERN = re.compile(r"--hash=sha256:(?P<digest>[0-9a-f]{64})")
MAX_TREE_ENTRIES = 50_000
MAX_TREE_BYTES = 1 << 30
STAMP_NAME = ".cf-agent-wechat-requirements"



class ContractError(ValueError):
    """The dependency contract is malformed or is not satisfied."""


@dataclass(frozen=True)
class LockedRequirement:
    name: str
    version: str
    hashes: tuple[str, ...]


@dataclass(frozen=True)
class LockContract:
    sha256: str
    requirements: tuple[LockedRequirement, ...]


def normalize_name(value: str) -> str:
    return NAME_NORMALIZER.sub("-", value).lower()


def validate_python_runtime() -> None:
    if platform.python_implementation() != "CPython":
        raise ContractError("the QR dependency contract requires CPython")
    if not (3, 10) <= sys.version_info[:2] <= (3, 14):
        raise ContractError("the QR dependency contract requires CPython 3.10-3.14")
    gil_disabled = sysconfig.get_config_var("Py_GIL_DISABLED")
    if gil_disabled not in (None, 0, "", "0"):
        raise ContractError("the QR dependency contract requires GIL-enabled CPython")


def logical_lines(text: str) -> list[str]:
    result: list[str] = []
    pending = ""
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        continued = stripped.endswith("\\")
        if continued:
            stripped = stripped[:-1].rstrip()
        pending = f"{pending} {stripped}".strip()
        if not continued:
            result.append(pending)
            pending = ""
    if pending:
        raise ContractError("requirements lock ends with an incomplete continuation")
    return result


def load_lock(path: Path) -> LockContract:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ContractError("requirements lock is not readable") from exc
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ContractError("requirements lock must be ASCII") from exc

    binary_only = False
    requirements: dict[str, LockedRequirement] = {}
    for line in logical_lines(text):
        if line == "--only-binary=:all:":
            if binary_only:
                raise ContractError("--only-binary may only appear once")
            binary_only = True
            continue
        try:
            fields = shlex.split(line, posix=True)
        except ValueError as exc:
            raise ContractError("requirements lock contains invalid quoting") from exc
        if not fields or PIN_PATTERN.fullmatch(fields[0]) is None:
            raise ContractError("every dependency must use an exact name==version pin")
        pin = PIN_PATTERN.fullmatch(fields[0])
        assert pin is not None
        normalized_name = normalize_name(pin.group("name"))
        if normalized_name in requirements:
            raise ContractError(f"duplicate dependency: {normalized_name}")

        hashes: list[str] = []
        for field in fields[1:]:
            match = HASH_PATTERN.fullmatch(field)
            if match is None:
                raise ContractError(
                    f"unsupported requirement option for {normalized_name}"
                )
            digest = match.group("digest")
            if digest in hashes:
                raise ContractError(f"duplicate hash for {normalized_name}")
            hashes.append(digest)
        if not hashes:
            raise ContractError(f"dependency has no sha256 hash: {normalized_name}")
        requirements[normalized_name] = LockedRequirement(
            name=normalized_name,
            version=pin.group("version"),
            hashes=tuple(hashes),
        )

    if not binary_only:
        raise ContractError("requirements lock must enforce --only-binary=:all:")
    actual_names = set(requirements)
    expected_names = set(EXPECTED_PACKAGES)
    if actual_names != expected_names:
        raise ContractError(
            "requirements lock package set does not match the QR contract"
        )
    return LockContract(
        sha256=hashlib.sha256(raw).hexdigest(),
        requirements=tuple(requirements[name] for name in sorted(requirements)),
    )



def _safe_lstat(path: Path) -> os.stat_result:
    try:
        return path.lstat()
    except OSError as exc:
        raise ContractError("managed venv tree is not readable") from exc


def _assert_managed_directory(
    path: Path, expected_uid: int, expected_gid: int, expected_mode: int
) -> None:
    metadata = _safe_lstat(path)
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        raise ContractError("managed venv path is not a real directory")
    if metadata.st_uid != expected_uid or metadata.st_gid != expected_gid:
        raise ContractError("managed venv owner differs from the approved user")
    if stat.S_IMODE(metadata.st_mode) != expected_mode:
        raise ContractError("managed venv mode differs from the approved mode")


def _decode_mount_path(value: str) -> str:
    for escaped, replacement in (
        (chr(92) + "040", " "),
        (chr(92) + "011", "\t"),
        (chr(92) + "012", "\n"),
        (chr(92) + "134", chr(92)),
    ):
        value = value.replace(escaped, replacement)
    return value


def _reject_nested_mounts(root: Path) -> None:
    mountinfo = Path("/proc/self/mountinfo")
    if not mountinfo.is_file():
        if platform.system() == "Linux":
            raise ContractError("could not inspect venv mount boundaries")
        return
    root_text = os.path.abspath(os.fspath(root))
    try:
        lines = mountinfo.read_text(encoding="ascii").splitlines()
    except OSError as exc:
        raise ContractError("could not inspect venv mount boundaries") from exc
    for line in lines:
        fields = line.split()
        if len(fields) < 6:
            raise ContractError("mount boundary data is malformed")
        target = os.path.abspath(_decode_mount_path(fields[4]))
        try:
            common = os.path.commonpath((root_text, target))
        except ValueError:
            continue
        if common == root_text:
            raise ContractError("managed venv contains a mount boundary")


def _approved_symlink(
    path: Path,
    root: Path,
    base_python: Path,
    python_version: str,
    *,
    allow_stale_python_links: bool,
) -> bool:
    relative = path.relative_to(root).as_posix()
    interpreter_links = {
        "bin/python",
        "bin/python3",
        f"bin/python{python_version}",
    }
    stale_python_link = re.fullmatch(r"bin/python3\.[0-9]+", relative)
    if relative in interpreter_links or (
        allow_stale_python_links and stale_python_link is not None
    ):
        try:
            return path.resolve(strict=True) == base_python.resolve(strict=True)
        except OSError:
            return False
    if relative == "lib64":
        try:
            return os.readlink(path) == "lib" and path.resolve(strict=True) == (
                root / "lib"
            ).resolve(strict=True)
        except OSError:
            return False
    return False


def _hash_regular_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_TREE_BYTES:
                    raise ContractError("managed venv file exceeds the scan limit")
                digest.update(chunk)
    except OSError as exc:
        raise ContractError("managed venv file could not be hashed") from exc
    return digest.hexdigest(), total


def audit_managed_tree(
    root: Path,
    base_python: Path,
    expected_uid: int,
    expected_gid: int,
    *,
    allow_stale_python_links: bool = False,
) -> str:
    root = Path(os.path.abspath(root))
    _assert_managed_directory(root.parent, expected_uid, expected_gid, 0o700)
    _assert_managed_directory(root, expected_uid, expected_gid, 0o700)
    _reject_nested_mounts(root)

    validate_python_runtime()
    python_version = f"{sys.version_info.major}.{sys.version_info.minor}"

    digest = hashlib.sha256()
    entries = 0
    total_bytes = 0
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            children = sorted(directory.iterdir(), key=lambda item: item.name)
        except OSError as exc:
            raise ContractError("managed venv directory is not readable") from exc
        for path in children:
            relative = path.relative_to(root).as_posix()
            metadata = _safe_lstat(path)
            entries += 1
            if entries > MAX_TREE_ENTRIES:
                raise ContractError("managed venv exceeds the file-count limit")
            if metadata.st_uid != expected_uid or metadata.st_gid != expected_gid:
                raise ContractError("managed venv contains an unapproved owner")
            mode = stat.S_IMODE(metadata.st_mode)
            if not stat.S_ISLNK(metadata.st_mode) and mode & 0o077:
                raise ContractError(
                    "managed venv contains group/other permissions"
                )
            if not stat.S_ISLNK(metadata.st_mode) and metadata.st_mode & (
                stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX
            ):
                raise ContractError("managed venv contains special permission bits")

            if stat.S_ISLNK(metadata.st_mode):
                if not _approved_symlink(
                    path,
                    root,
                    base_python,
                    python_version,
                    allow_stale_python_links=allow_stale_python_links,
                ):
                    raise ContractError("managed venv contains an unapproved symlink")
                target = os.readlink(path)
                digest.update(
                    f"L\0{relative}\0{mode:o}\0{target}\0".encode("utf-8")
                )
            elif stat.S_ISDIR(metadata.st_mode):
                digest.update(f"D\0{relative}\0{mode:o}\0".encode("utf-8"))
                stack.append(path)
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_nlink != 1:
                    raise ContractError("managed venv contains a hard-linked file")
                if relative == STAMP_NAME:
                    continue
                file_sha, size = _hash_regular_file(path)
                total_bytes += size
                if total_bytes > MAX_TREE_BYTES:
                    raise ContractError("managed venv exceeds the byte scan limit")
                digest.update(
                    f"F\0{relative}\0{mode:o}\0{size}\0{file_sha}\0".encode(
                        "ascii"
                    )
                )
            else:
                raise ContractError("managed venv contains a special file")
    return digest.hexdigest()

def _site_packages(venv: Path) -> Path:
    version = f"python{sys.version_info.major}.{sys.version_info.minor}"
    expected = venv / "lib" / version / "site-packages"
    metadata = _safe_lstat(expected)
    if not stat.S_ISDIR(metadata.st_mode) or expected.is_symlink():
        raise ContractError("venv site-packages path is missing or unsafe")
    candidates = sorted(venv.glob("lib/python*/site-packages"))
    if candidates != [expected]:
        raise ContractError("venv has an unexpected site-packages layout")
    return expected


def _validate_venv_configuration(venv: Path, base_python: Path) -> None:
    config = venv / "pyvenv.cfg"
    metadata = _safe_lstat(config)
    if not stat.S_ISREG(metadata.st_mode) or config.is_symlink():
        raise ContractError("venv configuration is missing or unsafe")
    try:
        values = {
            key.strip().lower(): value.strip()
            for line in config.read_text(encoding="utf-8").splitlines()
            if "=" in line
            for key, value in (line.split("=", 1),)
        }
    except (OSError, UnicodeError) as exc:
        raise ContractError("venv configuration is not readable UTF-8") from exc
    if values.get("include-system-site-packages", "").lower() != "false":
        raise ContractError("venv must disable system site-packages")
    interpreter = venv / "bin" / "python"
    if not interpreter.is_symlink():
        raise ContractError("venv interpreter must be an approved symlink")
    try:
        if interpreter.resolve(strict=True) != base_python.resolve(strict=True):
            raise ContractError("venv interpreter does not resolve to base Python")
    except OSError as exc:
        raise ContractError("venv interpreter target is not available") from exc


def _metadata_identity(dist_info: Path) -> tuple[str, str]:
    metadata_path = dist_info / "METADATA"
    try:
        message = BytesParser().parsebytes(
            metadata_path.read_bytes(), headersonly=True
        )
    except OSError as exc:
        raise ContractError("installed distribution metadata is not readable") from exc
    name = message.get("Name", "")
    version = message.get("Version", "")
    if not name or not version:
        raise ContractError("installed distribution metadata has no identity")
    return normalize_name(name), version


def _record_target(site_packages: Path, venv: Path, value: str) -> Path:
    if not value or "\\" in value or "\x00" in value:
        raise ContractError("distribution RECORD contains an unsafe path")
    pure_path = PurePosixPath(value)
    if pure_path.is_absolute():
        raise ContractError("distribution RECORD contains an absolute path")
    target = Path(os.path.abspath(site_packages.joinpath(*pure_path.parts)))
    try:
        target.relative_to(venv)
    except ValueError as exc:
        raise ContractError("distribution RECORD escapes the managed venv") from exc
    return target


def _record_hash(path: Path) -> tuple[str, str]:
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_TREE_BYTES:
                    raise ContractError(
                        "distribution RECORD target exceeds the scan limit"
                    )
                digest.update(chunk)
    except OSError as exc:
        raise ContractError("distribution RECORD target is not readable") from exc
    encoded = base64.urlsafe_b64encode(digest.digest()).rstrip(b"=").decode("ascii")
    return f"sha256={encoded}", str(size)


def _verify_distribution_records(
    lock: LockContract, venv: Path, site_packages: Path
) -> str:
    forbidden = {"sitecustomize.py", "usercustomize.py"}
    for path in site_packages.rglob("*"):
        lowered = path.name.lower()
        if lowered.endswith(".pth") or lowered in forbidden:
            raise ContractError("venv contains a Python path/code injection file")
        if lowered.endswith((".egg", ".egg-info")):
            raise ContractError("venv contains legacy or extra distribution metadata")

    dist_infos = sorted(site_packages.glob("*.dist-info"))
    installed: dict[str, tuple[str, Path]] = {}
    for dist_info in dist_infos:
        if not dist_info.is_dir() or dist_info.is_symlink():
            raise ContractError("installed distribution metadata path is unsafe")
        name, version = _metadata_identity(dist_info)
        if name in installed:
            raise ContractError("venv contains duplicate distribution metadata")
        installed[name] = (version, dist_info)

    locked = {item.name: item for item in lock.requirements}
    if set(installed) != set(locked):
        raise ContractError("installed distribution set differs from the lock")

    all_recorded: set[Path] = set()
    site_recorded: set[Path] = set()
    record_contract = hashlib.sha256()
    for name in sorted(locked):
        requirement = locked[name]
        version, dist_info = installed[name]
        if version != requirement.version:
            raise ContractError(f"installed dependency version differs: {name}")
        record_path = dist_info / "RECORD"
        try:
            with record_path.open("r", encoding="utf-8", newline="") as handle:
                rows = list(csv.reader(handle))
        except (OSError, UnicodeError, csv.Error) as exc:
            raise ContractError("installed distribution RECORD is not readable") from exc
        if not rows:
            raise ContractError("installed distribution RECORD is empty")
        seen: set[Path] = set()
        for row in rows:
            if len(row) != 3:
                raise ContractError("installed distribution RECORD is malformed")
            value, recorded_hash, recorded_size = row
            target = _record_target(site_packages, venv, value)
            if target in seen or target in all_recorded:
                raise ContractError("distribution RECORD contains a duplicate file")
            seen.add(target)
            all_recorded.add(target)
            if target.is_relative_to(site_packages):
                site_recorded.add(target)
            metadata = _safe_lstat(target)
            if not stat.S_ISREG(metadata.st_mode) or target.is_symlink():
                raise ContractError("distribution RECORD target is not a regular file")
            if target == record_path:
                if recorded_hash or recorded_size:
                    raise ContractError("distribution RECORD self-entry must be unhashed")
                continue
            if not recorded_hash.startswith("sha256=") or not recorded_size.isdigit():
                raise ContractError("distribution RECORD entry lacks sha256 and size")
            actual_hash, actual_size = _record_hash(target)
            if recorded_hash != actual_hash or recorded_size != actual_size:
                raise ContractError("installed distribution file differs from RECORD")
            record_contract.update(
                f"{name}\0{value}\0{actual_hash}\0{actual_size}\0".encode(
                    "utf-8"
                )
            )

    actual_site_files = {
        path
        for path in site_packages.rglob("*")
        if path.is_file() and not path.is_symlink()
    }
    if actual_site_files != site_recorded:
        raise ContractError("site-packages file set differs from distribution RECORDs")
    return record_contract.hexdigest()

def verify_installed(
    lock: LockContract,
    venv: Path,
    base_python: Path,
    expected_uid: int,
    expected_gid: int,
) -> str:
    venv = Path(os.path.abspath(venv))
    tree_sha = audit_managed_tree(
        venv,
        base_python,
        expected_uid,
        expected_gid,
        allow_stale_python_links=False,
    )
    _validate_venv_configuration(venv, base_python)
    site_packages = _site_packages(venv)
    records_sha = _verify_distribution_records(lock, venv, site_packages)
    return "\n".join(
        (
            f"schema={CONTRACT_SCHEMA_VERSION}",
            f"requirements_sha256={lock.sha256}",
            "python_implementation=cpython",
            f"python_version={platform.python_version()}",
            "python_gil=enabled",
            f"records_sha256={records_sha}",
            f"tree_sha256={tree_sha}",
        )
    )


def _add_venv_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("venv", type=Path)
    parser.add_argument("--base-python", required=True, type=Path)
    parser.add_argument("--expected-uid", required=True, type=int)
    parser.add_argument("--expected-gid", required=True, type=int)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate-runtime")
    validate = subparsers.add_parser("validate-lock")
    validate.add_argument("requirements", type=Path)
    verify = subparsers.add_parser("verify-installed")
    verify.add_argument("requirements", type=Path)
    _add_venv_arguments(verify)
    audit = subparsers.add_parser("audit-tree")
    _add_venv_arguments(audit)
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        if arguments.command == "validate-runtime":
            validate_python_runtime()
        elif arguments.command == "validate-lock":
            print(load_lock(arguments.requirements).sha256)
        elif arguments.command == "verify-installed":
            print(
                verify_installed(
                    load_lock(arguments.requirements),
                    arguments.venv,
                    arguments.base_python,
                    arguments.expected_uid,
                    arguments.expected_gid,
                )
            )
        else:
            print(
                audit_managed_tree(
                    arguments.venv,
                    arguments.base_python,
                    arguments.expected_uid,
                    arguments.expected_gid,
                    allow_stale_python_links=True,
                )
            )
    except ContractError as exc:
        print(f"dependency contract validation failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
