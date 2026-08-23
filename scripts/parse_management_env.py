#!/usr/bin/env python3
"""Parse the production docker/.env without shell evaluation."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import posixpath
import re
import stat
import sys
from pathlib import Path
from typing import Mapping


MAX_INPUT_BYTES = 64 * 1024
OUTPUT_SCHEMA_VERSION = 1
MAX_SHELL_INTEGER = (1 << 63) - 1
MAX_UID_GID = (1 << 32) - 2

PRODUCTION_STORAGE_ROOT = "/srv/storage/cf-agent-wechat"
PRODUCTION_RUNTIME_ROOT = f"{PRODUCTION_STORAGE_ROOT}/runtime"
PRODUCTION_ARCHIVE_ROOT = f"{PRODUCTION_STORAGE_ROOT}/session-archive"

REQUIRED_KEYS = (
    "COMPOSE_PROJECT_NAME",
    "CF_AGENT_WECHAT_STORAGE_ROOT",
    "CF_AGENT_WECHAT_RUNTIME_ROOT",
    "CF_AGENT_WECHAT_ARCHIVE_ROOT",
    "AGENT_WECHAT_BIND_IP",
    "AGENT_WECHAT_PORT",
    "AGENT_WECHAT_CONTAINER_NAME",
    "AGENT_WECHAT_IMAGE",
    "PROXY",
    "RUST_LOG",
    "CF_AGENT_WECHAT_RUNTIME_UID",
    "CF_AGENT_WECHAT_RUNTIME_GID",
    "CF_AGENT_WECHAT_RUNTIME_MODE",
    "CF_AGENT_WECHAT_MANAGEMENT_GID",
    "CF_AGENT_WECHAT_MIN_FREE_BYTES",
    "CF_AGENT_WECHAT_MIN_FREE_PERCENT",
    "CF_AGENT_WECHAT_MIN_FREE_INODES",
    "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES",
    "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES",
)
ALLOWED_KEYS = frozenset(REQUIRED_KEYS)

ASSIGNMENT_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.ASCII)
SAFE_PATH_RE = re.compile(r"/[-A-Za-z0-9._/@%+,=:~]+", re.ASCII)
CONTAINER_NAME_RE = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9_.-]{0,254}", re.ASCII
)
IMAGE_RE = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9._:/-]*[A-Za-z0-9])?"
    r"@sha256:[0-9a-fA-F]{64}",
    re.ASCII,
)
PROXY_RE = re.compile(
    r"(http|https|socks5|socks5h)://([^/?#@]+):([1-9][0-9]{0,4})",
    re.ASCII,
)
HOST_LABEL_RE = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", re.ASCII
)
IPV6_LITERAL_RE = re.compile(r"[0-9A-Fa-f:]+", re.ASCII)


class ManagementEnvError(Exception):
    """A deliberately non-sensitive management environment failure."""


def read_management_env(path: Path, *, max_bytes: int = MAX_INPUT_BYTES) -> bytes:
    """Read one stable single-link regular file without following its leaf."""

    if max_bytes <= 0:
        raise ManagementEnvError("the input size limit is invalid")
    if not path.is_absolute():
        raise ManagementEnvError("the input path must be absolute")
    try:
        before = path.lstat()
    except OSError as exc:
        raise ManagementEnvError("the input could not be inspected safely") from exc
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ManagementEnvError("the input is not a single-link regular file")
    if before.st_size > max_bytes:
        raise ManagementEnvError("the input exceeds the 65536-byte limit")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_BINARY", 0) | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ManagementEnvError("the input could not be opened safely") from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise ManagementEnvError("the input changed while it was opened")
        if opened.st_size > max_bytes:
            raise ManagementEnvError("the input exceeds the 65536-byte limit")

        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, max_bytes + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise ManagementEnvError("the input exceeds the 65536-byte limit")
            chunks.append(chunk)

        final = os.fstat(descriptor)
        if (
            (final.st_dev, final.st_ino) != (opened.st_dev, opened.st_ino)
            or final.st_size != opened.st_size
            or final.st_mtime_ns != opened.st_mtime_ns
            or final.st_ctime_ns != opened.st_ctime_ns
            or total != final.st_size
        ):
            raise ManagementEnvError("the input changed while it was read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _decode_input(data: bytes) -> str:
    if len(data) > MAX_INPUT_BYTES:
        raise ManagementEnvError("the input exceeds the 65536-byte limit")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ManagementEnvError("the input is not strict UTF-8") from exc

    # LF is the only permitted control character and is structural.
    if any(
        (ord(character) < 0x20 and character != "\n")
        or ord(character) in (0x7F, 0x85)
        for character in text
    ):
        raise ManagementEnvError("the input contains a forbidden control character")
    return text


def _positive_decimal(key: str, value: str, *, maximum: int) -> None:
    if re.fullmatch(r"[1-9][0-9]*", value, re.ASCII) is None:
        raise ManagementEnvError(f"{key} must be a positive decimal integer")
    if int(value) > maximum:
        raise ManagementEnvError(f"{key} exceeds its approved numeric range")


def _validate_path(key: str, value: str) -> None:
    if (
        SAFE_PATH_RE.fullmatch(value) is None
        or value.startswith("//")
        or posixpath.normpath(value) != value
    ):
        raise ManagementEnvError(f"{key} must be a canonical safe absolute path")


def _validate_hostname(host: str) -> None:
    if len(host) > 253:
        raise ManagementEnvError("PROXY host is invalid")
    labels = host.split(".")
    if not labels or any(HOST_LABEL_RE.fullmatch(label) is None for label in labels):
        raise ManagementEnvError("PROXY host is invalid")


def _validate_proxy(value: str) -> None:
    if not value:
        return
    match = PROXY_RE.fullmatch(value)
    if match is None:
        raise ManagementEnvError(
            "PROXY must be an approved credential-free scheme, host, and port"
        )
    _scheme, host, port_text = match.groups()
    if int(port_text) > 65535:
        raise ManagementEnvError("PROXY port is invalid")
    if host.startswith("[") or host.endswith("]"):
        if not (host.startswith("[") and host.endswith("]")):
            raise ManagementEnvError("PROXY host is invalid")
        if IPV6_LITERAL_RE.fullmatch(host[1:-1]) is None:
            raise ManagementEnvError("PROXY host is invalid")
        try:
            ipaddress.IPv6Address(host[1:-1])
        except ValueError as exc:
            raise ManagementEnvError("PROXY host is invalid") from exc
    else:
        _validate_hostname(host)


def _validate_value(key: str, value: str) -> None:
    if not value and key != "PROXY":
        raise ManagementEnvError(f"{key} must not be empty")

    if key in {
        "CF_AGENT_WECHAT_STORAGE_ROOT",
        "CF_AGENT_WECHAT_RUNTIME_ROOT",
        "CF_AGENT_WECHAT_ARCHIVE_ROOT",
    }:
        _validate_path(key, value)
    elif key == "COMPOSE_PROJECT_NAME":
        if value != "cf-agent-wechat":
            raise ManagementEnvError(
                "COMPOSE_PROJECT_NAME must be cf-agent-wechat"
            )
    elif key == "AGENT_WECHAT_BIND_IP":
        if value != "127.0.0.1":
            raise ManagementEnvError("AGENT_WECHAT_BIND_IP must be 127.0.0.1")
    elif key == "AGENT_WECHAT_PORT":
        _positive_decimal(key, value, maximum=65535)
    elif key == "AGENT_WECHAT_CONTAINER_NAME":
        if CONTAINER_NAME_RE.fullmatch(value) is None:
            raise ManagementEnvError("AGENT_WECHAT_CONTAINER_NAME is invalid")
    elif key == "AGENT_WECHAT_IMAGE":
        if IMAGE_RE.fullmatch(value) is None:
            raise ManagementEnvError(
                "AGENT_WECHAT_IMAGE must be an approved digest-pinned reference"
            )
    elif key == "PROXY":
        _validate_proxy(value)
    elif key == "RUST_LOG":
        if value not in {"error", "warn", "info"}:
            raise ManagementEnvError("RUST_LOG must be error, warn, or info")
    elif key in {
        "CF_AGENT_WECHAT_RUNTIME_UID",
        "CF_AGENT_WECHAT_RUNTIME_GID",
        "CF_AGENT_WECHAT_MANAGEMENT_GID",
    }:
        _positive_decimal(key, value, maximum=MAX_UID_GID)
    elif key == "CF_AGENT_WECHAT_RUNTIME_MODE":
        if value != "700":
            raise ManagementEnvError(
                "CF_AGENT_WECHAT_RUNTIME_MODE must be exactly 700"
            )
    elif key == "CF_AGENT_WECHAT_MIN_FREE_PERCENT":
        if re.fullmatch(r"[0-9]+", value, re.ASCII) is None or int(value) > 100:
            raise ManagementEnvError(
                "CF_AGENT_WECHAT_MIN_FREE_PERCENT must be between 0 and 100"
            )
    elif key in {
        "CF_AGENT_WECHAT_MIN_FREE_BYTES",
        "CF_AGENT_WECHAT_MIN_FREE_INODES",
        "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES",
        "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES",
    }:
        _positive_decimal(key, value, maximum=MAX_SHELL_INTEGER)
    else:
        raise ManagementEnvError("the input contains an unsupported key")


def _path_is_within(candidate: str, parent: str) -> bool:
    return candidate.startswith(parent.rstrip("/") + "/")


def _validate_path_contract(values: Mapping[str, str], contract: str) -> None:
    storage = values["CF_AGENT_WECHAT_STORAGE_ROOT"]
    runtime = values["CF_AGENT_WECHAT_RUNTIME_ROOT"]
    archive = values["CF_AGENT_WECHAT_ARCHIVE_ROOT"]
    if contract == "production":
        if (
            storage != PRODUCTION_STORAGE_ROOT
            or runtime != PRODUCTION_RUNTIME_ROOT
            or archive != PRODUCTION_ARCHIVE_ROOT
        ):
            raise ManagementEnvError(
                "the production storage paths differ from the approved fixed paths"
            )
        return
    if contract != "portable":
        raise ManagementEnvError("the path contract is invalid")
    if not _path_is_within(runtime, storage) or not _path_is_within(
        archive, storage
    ):
        raise ManagementEnvError(
            "portable runtime and archive paths must remain under storage"
        )
    if (
        runtime == archive
        or _path_is_within(runtime, archive)
        or _path_is_within(archive, runtime)
    ):
        raise ManagementEnvError(
            "portable runtime and archive paths must be separate and non-nested"
        )


def parse_management_env(
    data: bytes, *, path_contract: str = "production"
) -> dict[str, str]:
    """Return the complete validated management environment."""

    text = _decode_input(data)
    values: dict[str, str] = {}
    for line in text.split("\n"):
        if not line.strip(" ") or line.lstrip(" ").startswith("#"):
            continue
        match = ASSIGNMENT_RE.fullmatch(line)
        if match is None:
            raise ManagementEnvError("the input contains unsupported assignment syntax")
        key, value = match.groups()
        if key not in ALLOWED_KEYS:
            raise ManagementEnvError("the input contains an unsupported key")
        if key in values:
            raise ManagementEnvError(f"the input contains a duplicate {key} assignment")
        _validate_value(key, value)
        values[key] = value

    missing = [key for key in REQUIRED_KEYS if key not in values]
    if missing:
        raise ManagementEnvError(
            "the input is missing one or more required management keys"
        )
    _validate_path_contract(values, path_contract)
    return {key: values[key] for key in REQUIRED_KEYS}


def render_json(values: Mapping[str, str]) -> bytes:
    payload = {
        "schemaVersion": OUTPUT_SCHEMA_VERSION,
        "values": {key: values[key] for key in REQUIRED_KEYS},
    }
    return (
        json.dumps(payload, ensure_ascii=True, separators=(",", ":")) + "\n"
    ).encode("ascii")


def render_nul(values: Mapping[str, str]) -> bytes:
    output = bytearray()
    for key in REQUIRED_KEYS:
        output.extend(key.encode("ascii"))
        output.append(0)
        output.extend(values[key].encode("utf-8"))
        output.append(0)
    return bytes(output)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--env-file", required=True)
    parser.add_argument(
        "--path-contract", choices=("production", "portable"), default="production"
    )
    parser.add_argument("--format", choices=("json", "nul"), default="json")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        data = read_management_env(Path(arguments.env_file))
        values = parse_management_env(data, path_contract=arguments.path_contract)
        output = render_json(values) if arguments.format == "json" else render_nul(values)
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()
    except (ManagementEnvError, OSError):
        print("docker/.env validation failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
