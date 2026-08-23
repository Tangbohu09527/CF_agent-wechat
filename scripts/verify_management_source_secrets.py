#!/usr/bin/env python3
"""Silently reject Agent Token bytes in approved management source files."""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path


TOKEN_LIMIT = 8192
SOURCE_LIMIT = 1024 * 1024
EXPECTED_SOURCE_COUNT = 4


class VerificationError(Exception):
    pass


def _metadata_signature(metadata: os.stat_result) -> tuple[int, ...]:
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


def read_stable_regular_file(path: Path, limit: int) -> bytes:
    if not path.is_absolute() or not hasattr(os, "O_NOFOLLOW"):
        raise VerificationError
    before = path.lstat()
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size < 0
        or before.st_size > limit
    ):
        raise VerificationError

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if _metadata_signature(opened) != _metadata_signature(before):
            raise VerificationError
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, limit + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise VerificationError
            chunks.append(chunk)
        final = os.fstat(descriptor)
    finally:
        os.close(descriptor)

    visible = path.lstat()
    if (
        total != opened.st_size
        or _metadata_signature(final) != _metadata_signature(opened)
        or _metadata_signature(visible) != _metadata_signature(before)
    ):
        raise VerificationError
    return b"".join(chunks)


def normalize_token(raw_token: bytes) -> bytes:
    token = raw_token[:-1] if raw_token.endswith(b"\n") else raw_token
    if (
        len(token) != 64
        or b"\r" in token
        or b"\n" in token
        or any(byte not in b"0123456789abcdef" for byte in token)
    ):
        raise VerificationError
    return token


def parse_arguments(arguments: list[str]) -> tuple[Path, list[Path]]:
    token_file: Path | None = None
    sources: list[Path] = []
    index = 0
    while index < len(arguments):
        option = arguments[index]
        index += 1
        if index >= len(arguments):
            raise VerificationError
        value = Path(arguments[index])
        index += 1
        if option == "--token-file" and token_file is None:
            token_file = value
        elif option == "--source":
            sources.append(value)
        else:
            raise VerificationError
    if token_file is None or len(sources) != EXPECTED_SOURCE_COUNT:
        raise VerificationError
    if len({os.fspath(path) for path in sources}) != EXPECTED_SOURCE_COUNT:
        raise VerificationError
    return token_file, sources


def verify(token_file: Path, sources: list[Path]) -> None:
    token = normalize_token(read_stable_regular_file(token_file, TOKEN_LIMIT))
    for source in sources:
        if token in read_stable_regular_file(source, SOURCE_LIMIT):
            raise VerificationError


def main() -> int:
    try:
        token_file, sources = parse_arguments(sys.argv[1:])
        verify(token_file, sources)
    except (OSError, OverflowError, VerificationError, ValueError):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
