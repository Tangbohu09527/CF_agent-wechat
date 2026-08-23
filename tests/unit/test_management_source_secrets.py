#!/usr/bin/env python3
"""Unit tests for the stable, silent management-source Token scanner."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "verify_management_source_secrets.py"
TOKEN = b"a" * 64


def load_helper():
    spec = importlib.util.spec_from_file_location(
        "verify_management_source_secrets", SCRIPT
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load management-source verifier")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


HELPER = load_helper()
SUPPORTED = os.name == "posix" and hasattr(os, "O_NOFOLLOW")


@unittest.skipUnless(SUPPORTED, "requires POSIX O_NOFOLLOW semantics")
class ManagementSourceSecretTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, list[Path]]:
        token_file = root / "auth-token"
        token_file.write_bytes(TOKEN + b"\n")
        sources = [root / f"source-{index}" for index in range(4)]
        for source in sources:
            source.write_bytes(b"approved=value\n")
        return token_file, sources

    def command(self, token_file: Path, sources: list[Path]) -> list[str]:
        command = [sys.executable, "-I", os.fspath(SCRIPT), "--token-file", os.fspath(token_file)]
        for source in sources:
            command.extend(("--source", os.fspath(source)))
        return command

    def run_verifier(self, token_file: Path, sources: list[Path]):
        return subprocess.run(
            self.command(token_file, sources),
            check=False,
            capture_output=True,
            timeout=10,
        )

    def test_clean_sources_pass_without_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            token_file, sources = self.fixture(Path(temporary))
            result = self.run_verifier(token_file, sources)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")
            self.assertNotIn(TOKEN.decode("ascii"), self.command(token_file, sources))

    def test_token_in_each_source_fails_silently(self) -> None:
        for source_index in range(4):
            with self.subTest(source_index=source_index):
                with tempfile.TemporaryDirectory() as temporary:
                    token_file, sources = self.fixture(Path(temporary))
                    sources[source_index].write_bytes(b"# duplicate=" + TOKEN + b"\n")
                    result = self.run_verifier(token_file, sources)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(result.stderr, b"")

    def test_symlink_hardlink_and_oversize_sources_are_rejected(self) -> None:
        for kind in ("symlink", "hardlink", "oversize"):
            with self.subTest(kind=kind):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    token_file, sources = self.fixture(root)
                    target = root / "replacement"
                    target.write_bytes(b"approved=value\n")
                    sources[0].unlink()
                    if kind == "symlink":
                        sources[0].symlink_to(target)
                    elif kind == "hardlink":
                        os.link(target, sources[0])
                    else:
                        sources[0].write_bytes(b"x" * (HELPER.SOURCE_LIMIT + 1))
                    result = self.run_verifier(token_file, sources)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout + result.stderr, b"")

    def test_read_failure_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            token_file, _ = self.fixture(Path(temporary))
            with mock.patch.object(HELPER.os, "read", side_effect=OSError):
                with self.assertRaises(OSError):
                    HELPER.read_stable_regular_file(token_file, HELPER.TOKEN_LIMIT)

    def test_metadata_change_during_read_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            token_file, _ = self.fixture(Path(temporary))
            real_fstat = HELPER.os.fstat
            calls = 0

            def changing_fstat(descriptor):
                nonlocal calls
                calls += 1
                metadata = real_fstat(descriptor)
                if calls != 2:
                    return metadata
                values = {
                    name: getattr(metadata, name)
                    for name in (
                        "st_dev", "st_ino", "st_uid", "st_gid", "st_mode",
                        "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns",
                    )
                }
                values["st_ctime_ns"] += 1
                return SimpleNamespace(**values)

            with mock.patch.object(HELPER.os, "fstat", side_effect=changing_fstat):
                with self.assertRaises(HELPER.VerificationError):
                    HELPER.read_stable_regular_file(token_file, HELPER.TOKEN_LIMIT)


if __name__ == "__main__":
    unittest.main()
