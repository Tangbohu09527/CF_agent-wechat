#!/usr/bin/env python3
"""Crash-consistency tests for runtime Archive staging and publication."""

from __future__ import annotations

import importlib.util
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCANNER_PATH = REPO_ROOT / "scripts" / "scan_runtime_tree.py"
ARCHIVE_TOOL_PATH = REPO_ROOT / "scripts" / "archive-runtime.py"


def load_script_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


scanner = load_script_module("archive_durability_scanner", SCANNER_PATH)
archive_runtime = load_script_module(
    "archive_durability_inventory",
    ARCHIVE_TOOL_PATH,
)


@unittest.skipUnless(os.name == "posix", "directory durability requires POSIX")
class MoveDurabilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.storage = self.root / "storage"
        self.archive = self.storage / "session-archive"
        self.secrets = self.storage / "secrets"
        self.runtime = self.storage / "runtime"
        self.destination = (
            self.archive / ".incomplete-20300101T000000Z-1234"
        )
        self.storage.mkdir(mode=0o755)
        self.storage.chmod(0o755)
        self.archive.mkdir(mode=0o700)
        self.archive.chmod(0o700)
        self.secrets.mkdir(mode=0o700)
        self.secrets.chmod(0o700)
        self.runtime.mkdir(mode=0o700)
        self.runtime.chmod(0o700)
        (self.runtime / "data").mkdir(mode=0o700)
        (self.runtime / "data" / "state.db").write_bytes(
            b"\x00normal-binary-runtime\xff"
        )
        self.token = self.secrets / "auth-token"
        self.token_value = b"a" * 64
        self.token.write_bytes(self.token_value + b"\n")
        self.token.chmod(0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def scanner_command(
        self,
        marker: Path | None = None,
        release: Path | None = None,
    ) -> list[str]:
        command = [
            sys.executable,
            "-I",
            os.fspath(SCANNER_PATH),
            "--root",
            os.fspath(self.runtime),
            "--token-file",
            os.fspath(self.token),
            "--max-files",
            "1000",
            "--max-bytes",
            "1048576",
            "--timeout-seconds",
            "30",
            "--move-to",
            os.fspath(self.destination),
        ]
        if marker is not None or release is not None:
            if marker is None or release is None:
                raise ValueError("barrier paths must be supplied together")
            command.extend(
                (
                    "--testing",
                    "--testing-move-barrier-marker",
                    os.fspath(marker),
                    "--testing-move-barrier-release",
                    os.fspath(release),
                )
            )
        return command

    def barrier_paths(self) -> tuple[Path, Path]:
        return (
            self.root / "rename-fsynced.marker",
            self.root / "rename-fsynced.release",
        )
    def wait_for_barrier(
        self,
        process: subprocess.Popen[bytes],
        marker: Path,
    ) -> None:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if marker.is_file():
                return
            status = process.poll()
            if status is not None:
                self.fail(f"scanner exited before its durability barrier: {status}")
            time.sleep(0.01)
        process.kill()
        process.wait(timeout=5)
        self.fail("scanner did not reach its durability barrier")

    def assert_interrupted_staging_is_fail_closed(self) -> None:
        self.assertFalse(self.runtime.exists())
        self.assertTrue(self.destination.is_dir())
        self.assertTrue(self.destination.name.startswith(".incomplete-"))
        self.assertNotEqual(self.runtime.exists(), self.destination.exists())

        contract = archive_runtime.ArchiveContract(
            storage_root=self.storage,
            runtime_root=self.runtime,
            archive_root=self.archive,
            token_file=self.token,
            management_gid=os.getgid(),
        )
        with self.assertRaises(archive_runtime.InvalidArchiveNamesError):
            archive_runtime.inventory_archives(
                contract,
                expected_uid=os.getuid(),
                expected_gid=os.getgid(),
                timeout_seconds=10,
            )

    def run_and_interrupt(self, signum: signal.Signals) -> None:
        marker, release = self.barrier_paths()
        process = subprocess.Popen(
            self.scanner_command(marker, release),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.wait_for_barrier(process, marker)
        os.kill(process.pid, signum)
        process.wait(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assert_interrupted_staging_is_fail_closed()

    def test_sigterm_after_parent_fsync_leaves_only_incomplete_staging(
        self,
    ) -> None:
        self.run_and_interrupt(signal.SIGTERM)

    @unittest.skipUnless(hasattr(signal, "SIGKILL"), "SIGKILL is unavailable")
    def test_sigkill_after_parent_fsync_leaves_only_incomplete_staging(
        self,
    ) -> None:
        self.run_and_interrupt(signal.SIGKILL)

    def test_gnu_timeout_after_parent_fsync_leaves_only_incomplete_staging(
        self,
    ) -> None:
        timeout_bin = shutil.which("timeout")
        if timeout_bin is None:
            self.skipTest("GNU timeout is unavailable")
        marker, release = self.barrier_paths()
        process = subprocess.Popen(
            [
                timeout_bin,
                "--signal=TERM",
                "--kill-after=1s",
                "1s",
                *self.scanner_command(marker, release),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.wait_for_barrier(process, marker)
        process.wait(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assert_interrupted_staging_is_fail_closed()

    def test_second_parent_fsync_failure_rolls_the_rename_back(self) -> None:
        deadline = time.monotonic() + 10
        attestation = scanner.scan_tree(
            self.runtime,
            self.token_value,
            max_files=1000,
            max_bytes=1048576,
            deadline=deadline,
        )
        real_fsync = scanner.os.fsync
        calls: list[int] = []

        def fail_destination_parent_once(descriptor: int) -> None:
            calls.append(descriptor)
            if len(calls) == 2:
                raise OSError("injected destination-parent fsync failure")
            real_fsync(descriptor)

        with (
            mock.patch.object(
                scanner.os,
                "fsync",
                side_effect=fail_destination_parent_once,
            ),
            self.assertRaises(OSError),
        ):
            scanner.move_attested_tree(
                self.runtime,
                self.destination,
                attestation,
                max_files=1000,
                deadline=deadline,
            )

        self.assertGreaterEqual(len(calls), 4)
        self.assertTrue(self.runtime.is_dir())
        self.assertFalse(self.destination.exists())


class DurabilityContractTests(unittest.TestCase):
    def test_rename_precedes_both_parent_fsyncs_and_the_test_barrier(self) -> None:
        source = SCANNER_PATH.read_text(encoding="utf-8")
        start = source.index("def move_attested_tree(")
        end = source.index("\ndef scan_and_move_tree(", start)
        body = source[start:end]

        rename = body.index("os.rename(")
        source_fsync = body.index("os.fsync(source_parent_fd)", rename)
        destination_fsync = body.index(
            "os.fsync(destination_parent_fd)",
            source_fsync,
        )
        barrier = body.index(
            "testing_move_barrier(testing_barrier_paths)",
            destination_fsync,
        )
        post_move_stat = body.index(
            "runtime source still exists after archive move",
            barrier,
        )
        self.assertLess(rename, source_fsync)
        self.assertLess(source_fsync, destination_fsync)
        self.assertLess(destination_fsync, barrier)
        self.assertLess(barrier, post_move_stat)

    def test_barrier_is_disabled_without_explicit_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "marker"
            scanner.testing_move_barrier(None)
            self.assertFalse(marker.exists())

    def test_cli_barrier_paths_require_the_explicit_testing_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "marker"
            command = [
                sys.executable,
                "-I",
                os.fspath(SCANNER_PATH),
                "--root",
                os.fspath(root / "runtime"),
                "--token-file",
                os.fspath(root / "token"),
                "--max-files",
                "1",
                "--max-bytes",
                "1",
                "--timeout-seconds",
                "1",
                "--move-to",
                os.fspath(root / "archive" / ".incomplete-test"),
                "--testing-move-barrier-marker",
                os.fspath(marker),
                "--testing-move-barrier-release",
                os.fspath(root / "release"),
            ]
            result = subprocess.run(
                command,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertFalse(marker.exists())

    def test_invalid_testing_barrier_configuration_fails_closed(self) -> None:
        with self.assertRaises(scanner.ScanError):
            scanner.testing_move_barrier(
                (Path("relative-marker"), Path("/absolute-release"))
            )

if __name__ == "__main__":
    unittest.main()
