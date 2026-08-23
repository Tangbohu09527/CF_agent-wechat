#!/usr/bin/env python3
"""Security unit tests for the production runtime helper programs."""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import logging
import os
import socket
import subprocess
import sys
import tempfile
import time
import traceback
import unittest
from pathlib import Path, PurePosixPath
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCAN_SCRIPT = REPO_ROOT / "scripts" / "scan_runtime_tree.py"
CONTRACT_SCRIPT = REPO_ROOT / "scripts" / "verify_gateway_contract.py"
TOKEN = b"a" * 64
OTHER_TOKEN = b"b" * 64


def load_helper(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load test helper: {name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


SCAN = load_helper("scan_runtime_tree", SCAN_SCRIPT)
CONTRACT = load_helper("verify_gateway_contract", CONTRACT_SCRIPT)
FD_SCAN_SUPPORTED = (
    os.name == "posix"
    and os.open in os.supports_dir_fd
    and os.rename in os.supports_dir_fd
    and os.scandir in os.supports_fd
    and hasattr(os, "O_NOFOLLOW")
)


def changed_stat(metadata: os.stat_result) -> SimpleNamespace:
    return SimpleNamespace(
        st_dev=metadata.st_dev,
        st_ino=metadata.st_ino,
        st_mode=metadata.st_mode,
        st_nlink=metadata.st_nlink,
        st_uid=metadata.st_uid,
        st_gid=metadata.st_gid,
        st_size=metadata.st_size,
        st_ctime_ns=metadata.st_ctime_ns + 1,
    )


class ProtectedTokenInputTests(unittest.TestCase):
    def test_token_format_is_the_bootstrap_hex_contract(self) -> None:
        invalid_values = (
            b"",
            b"a" * 63,
            b"a" * 65,
            b"A" * 64,
            b"z" * 64,
            b"a" * 32 + b"\n" + b"a" * 32,
            b"a" * 64 + b"\r\n",
        )
        for value in invalid_values:
            with self.subTest(value_length=len(value)):
                with tempfile.TemporaryDirectory() as temporary:
                    token_file = Path(temporary) / "auth-token"
                    token_file.write_bytes(value)
                    with self.assertRaises(SCAN.ScanError):
                        SCAN.read_token(token_file)
                    with self.assertRaises(CONTRACT.ContractError):
                        CONTRACT.read_token(token_file)

    def test_single_trailing_lf_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            token_file = Path(temporary) / "auth-token"
            token_file.write_bytes(TOKEN + b"\n")
            self.assertEqual(SCAN.read_token(token_file), TOKEN)
            self.assertEqual(CONTRACT.read_token(token_file), TOKEN)

    def test_hard_linked_token_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            token_file = Path(temporary) / "auth-token"
            second_link = Path(temporary) / "second-link"
            token_file.write_bytes(TOKEN + b"\n")
            os.link(token_file, second_link)
            with self.assertRaises(SCAN.ScanError):
                SCAN.read_token(token_file)
            with self.assertRaises(CONTRACT.ContractError):
                CONTRACT.read_token(token_file)

    def test_symbolic_linked_token_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            token_file = Path(temporary) / "auth-token"
            token_link = Path(temporary) / "token-link"
            token_file.write_bytes(TOKEN + b"\n")
            try:
                token_link.symlink_to(token_file)
            except OSError as exc:
                self.skipTest(f"symbolic links are unavailable: {exc}")
            with self.assertRaises(SCAN.ScanError):
                SCAN.read_token(token_link)
            with self.assertRaises(CONTRACT.ContractError):
                CONTRACT.read_token(token_link)

    def test_token_change_during_read_is_rejected(self) -> None:
        for helper in (SCAN, CONTRACT):
            with self.subTest(helper=helper.__name__):
                with tempfile.TemporaryDirectory() as temporary:
                    token_file = Path(temporary) / "auth-token"
                    token_file.write_bytes(TOKEN + b"\n")
                    real_fstat = helper.os.fstat
                    calls = 0

                    def changing_fstat(descriptor):
                        nonlocal calls
                        calls += 1
                        metadata = real_fstat(descriptor)
                        return changed_stat(metadata) if calls == 2 else metadata

                    with mock.patch.object(
                        helper.os,
                        "fstat",
                        side_effect=changing_fstat,
                    ):
                        with self.assertRaisesRegex(
                            (SCAN.ScanError, CONTRACT.ContractError),
                            "changed",
                        ):
                            helper.read_token(token_file)

    def test_token_open_is_nonblocking_no_follow_and_close_on_exec(self) -> None:
        for helper in (SCAN, CONTRACT):
            with self.subTest(helper=helper.__name__):
                with tempfile.TemporaryDirectory() as temporary:
                    token_file = Path(temporary) / "auth-token"
                    token_file.write_bytes(TOKEN + b"\n")
                    real_open = helper.os.open
                    open_flags: list[int] = []

                    def recording_open(path, flags, *args, **kwargs):
                        open_flags.append(flags)
                        return real_open(path, flags, *args, **kwargs)

                    with mock.patch.object(
                        helper.os,
                        "open",
                        side_effect=recording_open,
                    ):
                        helper.read_token(token_file)
                    self.assertEqual(len(open_flags), 1)
                    for flag_name in (
                        "O_NONBLOCK",
                        "O_NOFOLLOW",
                        "O_CLOEXEC",
                    ):
                        flag = getattr(os, flag_name, 0)
                        if flag:
                            self.assertTrue(open_flags[0] & flag)


class MountInfoParserTests(unittest.TestCase):
    def test_same_filesystem_bind_mount_record_is_rejected(self) -> None:
        mountinfo = (
            b"36 25 8:1 / / rw,relatime - ext4 /dev/root rw\n"
            b"37 36 8:1 /source /srv/runtime/data rw,relatime "
            b"- ext4 /dev/root rw\n"
        )
        mount_points = SCAN.parse_mountinfo(mountinfo)
        with self.assertRaisesRegex(SCAN.ScanError, "nested mount point"):
            SCAN.reject_nested_mountpoints(
                PurePosixPath("/srv/runtime"),
                mount_points,
            )

    def test_mountinfo_escaped_path_is_decoded(self) -> None:
        mountinfo = (
            b"36 25 0:42 / /tmp/runtime"
            + bytes((92,))
            + b"040tree/data rw,relatime - ext4 /dev/root rw\n"
        )
        self.assertIn(
            PurePosixPath("/tmp/runtime tree/data"),
            SCAN.parse_mountinfo(mountinfo),
        )

    def test_runtime_root_mount_itself_is_allowed(self) -> None:
        SCAN.reject_nested_mountpoints(
            PurePosixPath("/srv/runtime"),
            frozenset((PurePosixPath("/srv/runtime"),)),
        )


@unittest.skipUnless(
    FD_SCAN_SUPPORTED,
    "fd-relative no-follow scanning requires POSIX dir_fd support",
)
class RuntimeTreeScannerTests(unittest.TestCase):
    def scan(
        self,
        root: Path,
        *,
        max_files: int = 100,
        max_bytes: int = 4 * 1024 * 1024,
    ) -> None:
        SCAN.scan_tree(
            root,
            TOKEN,
            max_files,
            max_bytes,
            time.monotonic() + 10,
        )

    def scan_and_move(
        self,
        root: Path,
        destination: Path,
        *,
        mutate_before_verification=None,
        reserved_names: tuple[str, ...] = (),
    ) -> None:
        if mutate_before_verification is None:
            SCAN.scan_and_move_tree(
                root,
                destination,
                TOKEN,
                100,
                4 * 1024 * 1024,
                time.monotonic() + 10,
                reserved_names,
            )
            return
        real_verify = SCAN.verify_tree_attestation
        mutation_applied = False

        def mutate_then_verify(*args, **kwargs):
            nonlocal mutation_applied
            if not mutation_applied:
                mutation_applied = True
                mutate_before_verification()
            return real_verify(*args, **kwargs)

        with mock.patch.object(
            SCAN,
            "verify_tree_attestation",
            side_effect=mutate_then_verify,
        ):
            self.scan_and_move(root, destination, reserved_names=reserved_names)

    def test_normal_binary_tree_without_token_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            nested = root / "data" / "db"
            nested.mkdir(parents=True)
            (nested / "messages.sqlite").write_bytes(bytes(range(256)) * 64)
            (root / "wechat-home").mkdir()
            self.scan(root)

    def test_same_filesystem_bind_mount_record_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            nested = root / "data"
            nested.mkdir(parents=True)
            mountinfo = (
                b"36 25 0:42 / / rw,relatime - ext4 /dev/root rw\n"
                + b"37 36 0:42 /source "
                + os.fsencode(nested)
                + b" rw,relatime - ext4 /dev/root rw\n"
            )
            with mock.patch.object(
                SCAN,
                "read_mountinfo",
                return_value=mountinfo,
            ):
                with self.assertRaisesRegex(
                    SCAN.ScanError,
                    "nested mount point",
                ):
                    self.scan(root)

    def test_directory_change_before_close_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            real_fstat = SCAN.os.fstat
            calls = 0

            def changing_fstat(descriptor):
                nonlocal calls
                calls += 1
                metadata = real_fstat(descriptor)
                return changed_stat(metadata) if calls == 2 else metadata

            mountinfo = b"36 25 0:42 / / rw,relatime - ext4 /dev/root rw\n"
            with (
                mock.patch.object(
                    SCAN,
                    "read_mountinfo",
                    return_value=mountinfo,
                ),
                mock.patch.object(
                    SCAN.os,
                    "fstat",
                    side_effect=changing_fstat,
                ),
            ):
                with self.assertRaisesRegex(
                    SCAN.ScanError,
                    "directory changed",
                ):
                    self.scan(root)

    def test_token_split_across_read_chunks_is_detected_without_disclosure(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            payload = b"x" * (SCAN.READ_CHUNK_BYTES - 17) + TOKEN + b"tail"
            (root / "messages.sqlite").write_bytes(payload)
            with self.assertRaises(SCAN.ScanError) as raised:
                self.scan(root, max_bytes=len(payload) + 1)
            self.assertNotIn(TOKEN.decode(), str(raised.exception))

    def test_external_symlink_and_symlink_loop_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            outside = base / "outside"
            outside.write_bytes(b"public")
            for name, target in (
                ("external", outside),
                ("loop", Path("loop")),
            ):
                with self.subTest(name=name):
                    root = base / f"runtime-{name}"
                    root.mkdir()
                    (root / name).symlink_to(target)
                    with self.assertRaisesRegex(
                        SCAN.ScanError,
                        "symbolic link",
                    ):
                        self.scan(root)

    def test_hard_linked_runtime_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            first = root / "first.db"
            first.write_bytes(b"public")
            os.link(first, root / "second.db")
            with self.assertRaisesRegex(SCAN.ScanError, "hard-linked"):
                self.scan(root)

    def test_fifo_and_unix_socket_are_rejected_without_opening_them(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            fifo_root = base / "fifo-runtime"
            fifo_root.mkdir()
            os.mkfifo(fifo_root / "payload.fifo")
            with self.assertRaisesRegex(SCAN.ScanError, "special file"):
                self.scan(fifo_root)

            socket_root = base / "socket-runtime"
            socket_root.mkdir()
            socket_path = socket_root / "payload.sock"
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                server.bind(str(socket_path))
                with self.assertRaisesRegex(SCAN.ScanError, "special file"):
                    self.scan(socket_root)
            finally:
                server.close()

    def test_file_size_budget_fails_before_unbounded_read(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            (root / "large.db").write_bytes(b"x" * 4096)
            with self.assertRaisesRegex(SCAN.ScanError, "byte limit"):
                self.scan(root, max_bytes=1024)

    def test_deadline_is_rechecked_inside_a_large_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            payload = root / "large.db"
            payload.write_bytes(b"x" * (SCAN.READ_CHUNK_BYTES + 1))
            directory_fd = os.open(
                root,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
            try:
                with mock.patch.object(
                    SCAN.time,
                    "monotonic",
                    side_effect=(0.0, 2.0),
                ):
                    with self.assertRaisesRegex(SCAN.ScanError, "time limit"):
                        SCAN.scan_file(
                            directory_fd,
                            payload.name,
                            payload.stat(),
                            TOKEN,
                            payload.stat().st_size + 1,
                            1.0,
                        )
            finally:
                os.close(directory_fd)

    def test_entry_limit_bounds_directory_only_trees(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            (root / "one").mkdir()
            (root / "two").mkdir()
            with self.assertRaisesRegex(SCAN.ScanError, "file-count limit"):
                self.scan(root, max_files=1)

    def test_file_open_is_fd_relative_and_no_follow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            (root / "payload.db").write_bytes(b"public")
            real_open = os.open
            calls: list[tuple[object, int, object]] = []

            def recording_open(path, flags, *args, **kwargs):
                calls.append((path, flags, kwargs.get("dir_fd")))
                return real_open(path, flags, *args, **kwargs)

            with mock.patch.object(SCAN.os, "open", side_effect=recording_open):
                self.scan(root)
            file_calls = [call for call in calls if call[0] == "payload.db"]
            self.assertEqual(len(file_calls), 1)
            self.assertIsInstance(file_calls[0][2], int)
            self.assertTrue(file_calls[0][1] & os.O_NOFOLLOW)

    def test_file_change_during_scan_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            payload = root / "payload.db"
            payload.write_bytes(b"public")
            directory_fd = os.open(
                root,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
            real_fstat = SCAN.os.fstat
            calls = 0

            def changing_fstat(descriptor):
                nonlocal calls
                calls += 1
                metadata = real_fstat(descriptor)
                return changed_stat(metadata) if calls == 2 else metadata

            try:
                with mock.patch.object(
                    SCAN.os,
                    "fstat",
                    side_effect=changing_fstat,
                ):
                    with self.assertRaisesRegex(SCAN.ScanError, "changed"):
                        SCAN.scan_file(
                            directory_fd,
                            payload.name,
                            payload.stat(),
                            TOKEN,
                            4096,
                            time.monotonic() + 10,
                        )
            finally:
                os.close(directory_fd)

    def test_attested_scan_and_move_preserves_the_verified_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "runtime"
            destination = base / "archive"
            (root / "data").mkdir(parents=True)
            (root / "data" / "payload.db").write_bytes(b"public")

            self.scan_and_move(root, destination)

            self.assertFalse(root.exists())
            self.assertEqual(
                (destination / "data" / "payload.db").read_bytes(),
                b"public",
            )

    def test_root_replacement_after_scan_is_rejected_without_move(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "runtime"
            original = base / "original-runtime"
            destination = base / "archive"
            root.mkdir()
            (root / "payload.db").write_bytes(b"original")

            def replace_root() -> None:
                root.rename(original)
                root.mkdir()
                (root / "payload.db").write_bytes(b"replacement")

            with self.assertRaisesRegex(SCAN.ScanError, "changed"):
                self.scan_and_move(
                    root,
                    destination,
                    mutate_before_verification=replace_root,
                )
            self.assertFalse(destination.exists())
            self.assertEqual((root / "payload.db").read_bytes(), b"replacement")
            self.assertEqual(
                (original / "payload.db").read_bytes(),
                b"original",
            )

    def test_post_scan_entry_injections_are_rejected_before_move(self) -> None:
        for kind in ("symlink", "hardlink", "fifo", "token"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                root = base / "runtime"
                destination = base / "archive"
                outside = base / "outside"
                root.mkdir()
                payload = root / "payload.db"
                payload.write_bytes(b"public")
                outside.write_bytes(b"outside")

                def inject() -> None:
                    if kind == "symlink":
                        (root / "injected").symlink_to(outside)
                    elif kind == "hardlink":
                        os.link(payload, root / "injected")
                    elif kind == "fifo":
                        os.mkfifo(root / "injected")
                    else:
                        payload.write_bytes(TOKEN)

                with self.assertRaises(SCAN.ScanError):
                    self.scan_and_move(
                        root,
                        destination,
                        mutate_before_verification=inject,
                    )
                self.assertTrue(root.is_dir())
                self.assertFalse(destination.exists())

    def test_post_scan_unix_socket_injection_is_rejected_before_move(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "runtime"
            destination = base / "archive"
            root.mkdir()
            (root / "payload.db").write_bytes(b"public")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                with self.assertRaises(SCAN.ScanError):
                    self.scan_and_move(
                        root,
                        destination,
                        mutate_before_verification=lambda: server.bind(
                            str(root / "injected.sock")
                        ),
                    )
            finally:
                server.close()
            self.assertTrue(root.is_dir())
            self.assertFalse(destination.exists())

    def test_existing_destination_is_not_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "runtime"
            destination = base / "archive"
            root.mkdir()
            (root / "payload.db").write_bytes(b"public")
            destination.mkdir()
            (destination / "evidence").write_bytes(b"existing")

            with self.assertRaisesRegex(SCAN.ScanError, "already exists"):
                self.scan_and_move(root, destination)

            self.assertEqual((root / "payload.db").read_bytes(), b"public")
            self.assertEqual(
                (destination / "evidence").read_bytes(),
                b"existing",
            )

    def test_unprotected_parent_and_cross_filesystem_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "runtime"
            destination = base / "archive"
            root.mkdir()
            (root / "payload.db").write_bytes(b"public")
            base.chmod(0o777)
            try:
                with self.assertRaisesRegex(SCAN.ScanError, "not protected"):
                    self.scan_and_move(root, destination)
            finally:
                base.chmod(0o700)
            self.assertTrue(root.is_dir())
            self.assertFalse(destination.exists())

        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "runtime"
            destination = base / "archive"
            root.mkdir()
            (root / "payload.db").write_bytes(b"public")
            real_open_parent = SCAN.open_protected_parent

            def report_different_device(path: Path):
                descriptor, metadata = real_open_parent(path)
                if path == destination:
                    metadata = SimpleNamespace(st_dev=metadata.st_dev + 1)
                return descriptor, metadata

            with (
                mock.patch.object(
                    SCAN,
                    "open_protected_parent",
                    side_effect=report_different_device,
                ),
                self.assertRaisesRegex(SCAN.ScanError, "different filesystems"),
            ):
                self.scan_and_move(root, destination)
            self.assertTrue(root.is_dir())
            self.assertFalse(destination.exists())

    def test_reserved_manifest_payload_is_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "runtime"
            destination = base / "archive"
            root.mkdir()
            manifest = root / "manifest.json"
            manifest.write_bytes(b"payload evidence")

            with self.assertRaisesRegex(SCAN.ScanError, "reserved"):
                self.scan_and_move(
                    root,
                    destination,
                    reserved_names=("manifest.json",),
                )

            self.assertEqual(manifest.read_bytes(), b"payload evidence")
            self.assertFalse(destination.exists())

    def test_cli_is_silent_and_does_not_read_token_from_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "runtime"
            root.mkdir()
            (root / "payload.db").write_bytes(b"public")
            token_file = base / "auth-token"
            token_file.write_bytes(TOKEN + b"\n")
            command = (
                sys.executable,
                str(SCAN_SCRIPT),
                "--root",
                str(root),
                "--token-file",
                str(token_file),
                "--max-files",
                "10",
                "--max-bytes",
                "4096",
                "--timeout-seconds",
                "5",
            )
            environment = os.environ.copy()
            environment["CF_AGENT_WECHAT_TOKEN"] = OTHER_TOKEN.decode()
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                env=environment,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(completed.stdout, b"")
            self.assertEqual(completed.stderr, b"")
            self.assertNotIn(TOKEN.decode(), command)
            self.assertNotIn(OTHER_TOKEN.decode(), command)


class GatewayContractVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.token_file = self.base / "auth-token"
        self.gateway_env = self.base / "gateway.env"
        self.contract_file = self.base / "wechat-runtime-contract.json"
        self.checker = self.base / "check-wechat-worker-heartbeat"
        self.checker_sha256 = "c" * 64
        self.arguments = argparse.Namespace(
            alias="cf-agent-wechat",
            port=6174,
            token_file=str(self.token_file),
            checker=str(self.checker),
            checker_sha256=self.checker_sha256,
            producer_repository="Tangbohu09527/CF_agent-gateway",
            service="worker",
            project="cf-agent-gateway",
            max_age=30,
            attestation_kind="compose",
        )
        self.attestation = self.compose_attestation()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def assert_contract_error_is_redacted(
        self,
        error: Exception,
    ) -> None:
        token = TOKEN.decode()
        self.assertNotIn(token, str(error))
        self.assertNotIn(token, repr(error))
        self.assertIsNone(error.__cause__)
        self.assertIsNone(error.__context__)
        self.assertNotIn(
            token,
            "".join(traceback.format_exception(error)),
        )

        output = io.StringIO()
        logger = logging.getLogger(f"{__name__}.{self.id()}")
        logger.handlers.clear()
        logger.propagate = False
        logger.setLevel(logging.ERROR)
        handler = logging.StreamHandler(output)
        logger.addHandler(handler)
        try:
            try:
                raise error
            except Exception:
                logger.exception("captured Gateway contract error")
        finally:
            logger.removeHandler(handler)
            handler.close()
        self.assertNotIn(token, output.getvalue())

    def test_external_decode_errors_drop_sensitive_exception_chains(
        self,
    ) -> None:
        self.gateway_env.write_bytes(TOKEN + b"\xff")
        operations = (
            (
                "gateway-env",
                lambda: CONTRACT.decode_gateway_environment(
                    self.gateway_env
                ),
            ),
            (
                "attestation-json",
                lambda: CONTRACT.parse_json_bytes(
                    b'{"secret":"' + TOKEN + b'"',
                    label="Gateway attestation",
                ),
            ),
        )
        for name, operation in operations:
            with self.subTest(name=name):
                with self.assertRaises(CONTRACT.ContractError) as raised:
                    operation()
                self.assert_contract_error_is_redacted(raised.exception)

        sensitive_text = TOKEN.decode() + "\ud800"
        with mock.patch.object(sys, "stdin", io.StringIO(sensitive_text)):
            with self.assertRaises(CONTRACT.ContractError) as raised:
                CONTRACT.read_bounded_standard_input()
        self.assert_contract_error_is_redacted(raised.exception)

    def compose_attestation(self) -> bytes:
        return json.dumps(
            {
                "name": self.arguments.project,
                "services": {
                    self.arguments.service: {
                        "restart": "no",
                        "environment": {
                            CONTRACT.TOKEN_FILE_KEY: CONTRACT.WORKER_TOKEN_PATH,
                            "UNRELATED": "public",
                        },
                        "volumes": [
                            {
                                "type": "bind",
                                "source": str(self.token_file),
                                "target": CONTRACT.WORKER_TOKEN_PATH,
                                "read_only": True,
                            }
                        ],
                    }
                },
            }
        ).encode("utf-8")

    def inspect_attestation(self) -> bytes:
        return json.dumps(
            [
                {
                    "Config": {
                        "Env": [
                            f"{CONTRACT.TOKEN_FILE_KEY}="
                            f"{CONTRACT.WORKER_TOKEN_PATH}",
                            "UNRELATED=public",
                        ],
                        "Labels": {
                            "com.docker.compose.project": self.arguments.project,
                            "com.docker.compose.service": self.arguments.service,
                        },
                    },
                    "HostConfig": {
                        "Tmpfs": {},
                        "Devices": [],
                        "RestartPolicy": {
                            "Name": "no",
                            "MaximumRetryCount": 0,
                        },
                    },
                    "Mounts": [
                        {
                            "Type": "bind",
                            "Source": str(self.token_file),
                            "Destination": CONTRACT.WORKER_TOKEN_PATH,
                            "RW": False,
                        }
                    ],
                }
            ]
        ).encode("utf-8")

    def write_valid_inputs(self) -> None:
        self.token_file.write_bytes(TOKEN + b"\n")
        self.gateway_env.write_bytes(
            b"# unrelated settings are not evaluated\n"
            b"POSTGRES_PASSWORD_FILE=/run/secrets/postgres\n"
            + CONTRACT.TOKEN_FILE_KEY.encode()
            + b"="
            + CONTRACT.WORKER_TOKEN_PATH.encode()
            + b"\n"
        )
        self.contract_file.write_text(
            json.dumps(CONTRACT.expected_contract(self.arguments)),
            encoding="utf-8",
        )

    def command(self) -> list[str]:
        return [
            str(CONTRACT_SCRIPT),
            "--contract-file",
            str(self.contract_file),
            "--gateway-env",
            str(self.gateway_env),
            "--token-file",
            str(self.token_file),
            "--checker",
            str(self.checker),
            "--service",
            self.arguments.service,
            "--project",
            self.arguments.project,
            "--alias",
            self.arguments.alias,
            "--port",
            str(self.arguments.port),
            "--max-age",
            str(self.arguments.max_age),
            "--producer-repository",
            self.arguments.producer_repository,
            "--checker-sha256",
            self.arguments.checker_sha256,
            "--attestation-kind",
            self.arguments.attestation_kind,
        ]

    def invoke_main(self) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        stdin = io.StringIO(self.attestation.decode("utf-8"))
        with (
            mock.patch.object(sys, "argv", self.command()),
            mock.patch.object(sys, "stdin", stdin),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            result = CONTRACT.main()
        return result, stdout.getvalue(), stderr.getvalue()

    def test_file_credential_and_exact_v1_contract_are_compatible(self) -> None:
        self.write_valid_inputs()
        with mock.patch.object(
            CONTRACT.hmac,
            "compare_digest",
            wraps=CONTRACT.hmac.compare_digest,
        ) as compare:
            result, stdout, stderr = self.invoke_main()
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "")
        compare.assert_not_called()

    def test_plaintext_token_is_rejected_even_when_it_matches(self) -> None:
        self.write_valid_inputs()
        self.gateway_env.write_bytes(
            CONTRACT.TOKEN_KEY.encode() + b"=" + TOKEN + b"\n"
        )
        result, stdout, stderr = self.invoke_main()
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("plaintext", stderr)
        self.assertNotIn(TOKEN.decode(), stderr)

    def test_file_credential_requires_exact_unquoted_worker_path(
        self,
    ) -> None:
        invalid_assignments = (
            b"CF_AGENT_WECHAT_TOKEN_FILE=/wrong/path\n",
            (
                b"CF_AGENT_WECHAT_TOKEN_FILE=\""
                + CONTRACT.WORKER_TOKEN_PATH.encode()
                + b"\"\n"
            ),
            b"CF_AGENT_WECHAT_TOKEN_FILE=$TOKEN_FILE\n",
            (
                b" CF_AGENT_WECHAT_TOKEN_FILE="
                + CONTRACT.WORKER_TOKEN_PATH.encode()
                + b"\n"
            ),
            (
                b"export CF_AGENT_WECHAT_TOKEN_FILE="
                + CONTRACT.WORKER_TOKEN_PATH.encode()
                + b"\n"
            ),
            (
                b"\xef\xbb\xbfCF_AGENT_WECHAT_TOKEN_FILE="
                + CONTRACT.WORKER_TOKEN_PATH.encode()
                + b"\n"
            ),
            (
                b"CF_AGENT_WECHAT_TOKEN_FILE="
                + CONTRACT.WORKER_TOKEN_PATH.encode()
                + b"\nCF_AGENT_WECHAT_TOKEN_FILE="
                + CONTRACT.WORKER_TOKEN_PATH.encode()
                + b"\n"
            ),
        )
        for payload in invalid_assignments:
            with self.subTest(payload=payload[:32]):
                self.gateway_env.write_bytes(payload)
                with self.assertRaises(CONTRACT.ContractError):
                    CONTRACT.read_gateway_file_credential(
                        self.gateway_env, CONTRACT.WORKER_TOKEN_PATH
                    )

    def test_gateway_env_crlf_and_credential_named_comment_are_safe(self) -> None:
        self.gateway_env.write_bytes(
            b"  # CF_AGENT_WECHAT_TOKEN=ignored\r\n"
            b"OTHER=mentions-CF_AGENT_WECHAT_TOKEN_FILE\r\n"
            b"CF_AGENT_WECHAT_TOKEN_FILE="
            + CONTRACT.WORKER_TOKEN_PATH.encode()
            + b"\r\n"
        )
        CONTRACT.read_gateway_file_credential(
            self.gateway_env, CONTRACT.WORKER_TOKEN_PATH
        )

    def test_gateway_env_invalid_utf8_is_rejected(self) -> None:
        self.gateway_env.write_bytes(
            b"UNRELATED=\xff\nCF_AGENT_WECHAT_TOKEN_FILE="
            + CONTRACT.WORKER_TOKEN_PATH.encode()
            + b"\n"
        )
        with self.assertRaisesRegex(CONTRACT.ContractError, "UTF-8"):
            CONTRACT.read_gateway_file_credential(
                self.gateway_env, CONTRACT.WORKER_TOKEN_PATH
            )

    def test_legacy_token_audit_is_constant_time_but_never_compatible(self) -> None:
        self.token_file.write_bytes(TOKEN + b"\n")
        cases = (
            (
                TOKEN,
                CONTRACT.LegacyTokenAuditResult.MATCH_INCOMPATIBLE,
            ),
            (
                OTHER_TOKEN,
                CONTRACT.LegacyTokenAuditResult.MISMATCH_INCOMPATIBLE,
            ),
        )
        for gateway_token, expected in cases:
            with self.subTest(result=expected.value):
                self.gateway_env.write_bytes(
                    CONTRACT.TOKEN_KEY.encode()
                    + b"="
                    + gateway_token
                    + b"\n"
                )
                with mock.patch.object(
                    CONTRACT.hmac,
                    "compare_digest",
                    wraps=CONTRACT.hmac.compare_digest,
                ) as compare:
                    result = CONTRACT.audit_legacy_token_agreement(
                        self.token_file, self.gateway_env
                    )
                self.assertIs(result, expected)
                self.assertFalse(result.production_compatible)
                compare.assert_called_once_with(TOKEN, gateway_token)

    def test_legacy_audit_rejects_mixed_credential_modes(self) -> None:
        self.token_file.write_bytes(TOKEN + b"\n")
        self.gateway_env.write_bytes(
            CONTRACT.TOKEN_KEY.encode()
            + b"="
            + TOKEN
            + b"\n"
            + CONTRACT.TOKEN_FILE_KEY.encode()
            + b"="
            + CONTRACT.WORKER_TOKEN_PATH.encode()
            + b"\n"
        )
        with self.assertRaisesRegex(CONTRACT.ContractError, "mixes"):
            CONTRACT.audit_legacy_token_agreement(
                self.token_file, self.gateway_env
            )

    def test_compose_attestation_rejects_credential_and_mount_drift(self) -> None:
        base = json.loads(self.compose_attestation())
        mutations = []

        payload = json.loads(json.dumps(base))
        payload["services"]["worker"]["environment"][CONTRACT.TOKEN_KEY] = (
            TOKEN.decode()
        )
        mutations.append(("plaintext-token", payload))

        payload = json.loads(json.dumps(base))
        payload["services"]["worker"]["environment"][
            CONTRACT.TOKEN_FILE_KEY
        ] = "/wrong/path"
        mutations.append(("wrong-pointer", payload))

        payload = json.loads(json.dumps(base))
        payload["services"]["worker"]["volumes"][0]["read_only"] = False
        mutations.append(("writable-mount", payload))

        payload = json.loads(json.dumps(base))
        payload["services"]["worker"]["volumes"].append(
            dict(payload["services"]["worker"]["volumes"][0])
        )
        mutations.append(("duplicate-mount", payload))

        payload = json.loads(json.dumps(base))
        payload["name"] = "wrong-project"
        mutations.append(("wrong-project", payload))

        for name, payload in mutations:
            with self.subTest(name=name):
                with self.assertRaises(CONTRACT.ContractError):
                    CONTRACT.attest_gateway_compose(
                        json.dumps(payload).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_compose_requires_restart_no(self) -> None:
        for restart in (None, "always", "unless-stopped", False):
            with self.subTest(restart=restart):
                payload = json.loads(self.compose_attestation())
                service = payload["services"][self.arguments.service]
                if restart is None:
                    service.pop("restart")
                else:
                    service["restart"] = restart
                with self.assertRaisesRegex(
                    CONTRACT.ContractError,
                    "restart policy is incompatible",
                ):
                    CONTRACT.attest_gateway_compose(
                        json.dumps(payload).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_worker_inspect_requires_restart_no_without_retries(
        self,
    ) -> None:
        policies = (
            None,
            {},
            {"Name": "always", "MaximumRetryCount": 0},
            {"Name": "no", "MaximumRetryCount": 1},
            {"Name": "no", "MaximumRetryCount": False},
        )
        for policy in policies:
            with self.subTest(policy=policy):
                payload = json.loads(self.inspect_attestation())
                host_config = payload[0]["HostConfig"]
                if policy is None:
                    host_config.pop("RestartPolicy")
                else:
                    host_config["RestartPolicy"] = policy
                with self.assertRaisesRegex(
                    CONTRACT.ContractError,
                    "restart policy is incompatible",
                ):
                    CONTRACT.attest_gateway_worker_inspect(
                        json.dumps(payload).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_token_mount_allows_an_unrelated_sibling_bind(self) -> None:
        unrelated_source = self.base.parent / f"{self.base.name}-public"
        compose = json.loads(self.compose_attestation())
        compose["services"]["worker"]["volumes"].append(
            {
                "type": "bind",
                "source": str(unrelated_source),
                "target": "/var/lib/gateway-public",
                "read_only": True,
            }
        )
        CONTRACT.attest_gateway_compose(
            json.dumps(compose).encode(),
            TOKEN,
            project=self.arguments.project,
            service_name=self.arguments.service,
            token_host_path=str(self.token_file),
            token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
        )

        inspect = json.loads(self.inspect_attestation())
        inspect[0]["Mounts"].append(
            {
                "Type": "bind",
                "Source": str(unrelated_source),
                "Destination": "/var/lib/gateway-public",
                "RW": False,
            }
        )
        CONTRACT.attest_gateway_worker_inspect(
            json.dumps(inspect).encode(),
            TOKEN,
            project=self.arguments.project,
            service_name=self.arguments.service,
            token_host_path=str(self.token_file),
            token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
        )

    def test_token_mount_rejects_ancestor_bind_exposure(self) -> None:
        ancestor_sources = (
            self.base,
            self.base / "nested" / "..",
        )
        for source in ancestor_sources:
            with self.subTest(source=source):
                compose = json.loads(self.compose_attestation())
                compose["services"]["worker"]["volumes"].append(
                    {
                        "type": "bind",
                        "source": str(source),
                        "target": "/var/lib/gateway-leak",
                        "read_only": True,
                    }
                )
                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "not unique"
                ):
                    CONTRACT.attest_gateway_compose(
                        json.dumps(compose).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

                inspect = json.loads(self.inspect_attestation())
                inspect[0]["Mounts"].append(
                    {
                        "Type": "bind",
                        "Source": str(source),
                        "Destination": "/var/lib/gateway-leak",
                        "RW": False,
                    }
                )
                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "not unique"
                ):
                    CONTRACT.attest_gateway_worker_inspect(
                        json.dumps(inspect).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_token_mount_rejects_parent_target_overlap(self) -> None:
        targets = (
            "/run/secrets",
            "/run/nested/../secrets",
            "/run",
        )
        for target in targets:
            with self.subTest(target=target):
                compose = json.loads(self.compose_attestation())
                compose["services"]["worker"]["volumes"].append(
                    {
                        "type": "volume",
                        "source": "gateway-public",
                        "target": target,
                        "read_only": True,
                    }
                )
                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "not unique"
                ):
                    CONTRACT.attest_gateway_compose(
                        json.dumps(compose).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

                inspect = json.loads(self.inspect_attestation())
                inspect[0]["Mounts"].append(
                    {
                        "Type": "volume",
                        "Source": "/var/lib/docker/volumes/gateway-public/_data",
                        "Destination": target,
                        "RW": False,
                    }
                )
                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "not unique"
                ):
                    CONTRACT.attest_gateway_worker_inspect(
                        json.dumps(inspect).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_compose_rejects_cross_service_token_bind_exposure(self) -> None:
        for source in (self.token_file, self.base, self.base / "nested" / ".."):
            with self.subTest(source=source):
                compose = json.loads(self.compose_attestation())
                compose["services"]["sidecar"] = {
                    "volumes": [
                        {
                            "type": "bind",
                            "source": str(source),
                            "target": "/var/lib/sidecar-leak",
                            "read_only": True,
                        }
                    ]
                }
                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "another service"
                ):
                    CONTRACT.attest_gateway_compose(
                        json.dumps(compose).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_compose_accepts_unrelated_indirection_controls(self) -> None:
        compose = json.loads(self.compose_attestation())
        compose["secrets"] = {
            "unrelated": {
                "file": "/opt/cf-agent-gateway/secrets/unrelated"
            }
        }
        compose["configs"] = {
            "unrelated": {
                "file": "/opt/cf-agent-gateway/config/unrelated"
            }
        }
        compose["volumes"] = {
            "unrelated": {
                "driver": "local",
                "driver_opts": {
                    "type": "none",
                    "o": "bind",
                    "device": "/opt/cf-agent-gateway/state",
                },
            }
        }

        CONTRACT.attest_gateway_compose(
            json.dumps(compose).encode(),
            TOKEN,
            project=self.arguments.project,
            service_name=self.arguments.service,
            token_host_path=str(self.token_file),
            token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
        )

    def test_compose_rejects_worker_and_sidecar_volumes_from(self) -> None:
        cases = (("worker", "sidecar:ro"), ("sidecar", "worker:ro"))
        for service_name, source in cases:
            with self.subTest(service=service_name):
                compose = json.loads(self.compose_attestation())
                if service_name == "sidecar":
                    compose["services"][service_name] = {}
                compose["services"][service_name]["volumes_from"] = [source]

                with self.assertRaisesRegex(
                    CONTRACT.ContractError, "volumes_from is forbidden"
                ):
                    CONTRACT.attest_gateway_compose(
                        json.dumps(compose).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_compose_rejects_secret_and_config_token_indirection(self) -> None:
        for collection_name in ("secrets", "configs"):
            with self.subTest(collection=collection_name):
                compose = json.loads(self.compose_attestation())
                compose[collection_name] = {
                    "agent-token-copy": {"file": str(self.token_file)}
                }

                with self.assertRaisesRegex(
                    CONTRACT.ContractError,
                    "reuses the Agent Token authority",
                ):
                    CONTRACT.attest_gateway_compose(
                        json.dumps(compose).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_compose_rejects_named_volume_token_ancestor_device(self) -> None:
        compose = json.loads(self.compose_attestation())
        compose["volumes"] = {
            "agent-secrets-copy": {
                "driver": "local",
                "driver_opts": {
                    "type": "none",
                    "o": "bind",
                    "device": str(self.base),
                },
            }
        }

        with self.assertRaisesRegex(
            CONTRACT.ContractError,
            "volume reuses the Agent Token authority",
        ):
            CONTRACT.attest_gateway_compose(
                json.dumps(compose).encode(),
                TOKEN,
                project=self.arguments.project,
                service_name=self.arguments.service,
                token_host_path=str(self.token_file),
                token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
            )

    def test_compose_accepts_unrelated_container_target_controls(self) -> None:
        compose = json.loads(self.compose_attestation())
        service = compose["services"]["worker"]
        service["secrets"] = [
            {
                "source": "database-password",
                "target": "/run/secrets/database-password",
            }
        ]
        service["configs"] = [
            {
                "source": "gateway-config",
                "target": "/etc/cf-gateway/config.json",
            }
        ]
        service["tmpfs"] = [
            "/tmp:mode=1777",
            {"target": "/var/cache/cf-gateway"},
            {"source": "/var/run/cf-gateway"},
        ]
        service["devices"] = [
            "/dev/null:/dev/cf-gateway-null:r",
            {
                "source": "/dev/zero",
                "target": "/dev/cf-gateway-zero",
                "permissions": "r",
            },
            {
                "path_on_host": "/dev/full",
                "path_in_container": "/dev/cf-gateway-full",
                "cgroup_permissions": "rw",
            },
        ]

        CONTRACT.attest_gateway_compose(
            json.dumps(compose).encode(),
            TOKEN,
            project=self.arguments.project,
            service_name=self.arguments.service,
            token_host_path=str(self.token_file),
            token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
        )

    def test_compose_rejects_container_target_overlay_forms(self) -> None:
        targets = (
            CONTRACT.WORKER_TOKEN_PATH,
            "/run/secrets",
            "/run/nested/../secrets",
        )
        cases = (
            (
                "secret",
                "secrets",
                lambda target: [
                    {"source": "database-password", "target": target}
                ],
            ),
            (
                "config",
                "configs",
                lambda target: [
                    {"source": "gateway-config", "target": target}
                ],
            ),
            ("tmpfs-string", "tmpfs", lambda target: [target]),
            (
                "tmpfs-target",
                "tmpfs",
                lambda target: [{"target": target}],
            ),
            (
                "tmpfs-source",
                "tmpfs",
                lambda target: [{"source": target}],
            ),
            (
                "device-string",
                "devices",
                lambda target: [f"/dev/null:{target}:r"],
            ),
            (
                "device-target",
                "devices",
                lambda target: [
                    {
                        "source": "/dev/null",
                        "target": target,
                        "permissions": "r",
                    }
                ],
            ),
            (
                "device-path-in-container",
                "devices",
                lambda target: [
                    {
                        "path_on_host": "/dev/null",
                        "path_in_container": target,
                        "cgroup_permissions": "rwm",
                    }
                ],
            ),
        )
        for target in targets:
            for label, field, factory in cases:
                with self.subTest(target=target, mechanism=label):
                    compose = json.loads(self.compose_attestation())
                    compose["services"]["worker"][field] = factory(target)
                    with self.assertRaisesRegex(
                        CONTRACT.ContractError,
                        "overlays the Agent Token target",
                    ):
                        CONTRACT.attest_gateway_compose(
                            json.dumps(compose).encode(),
                            TOKEN,
                            project=self.arguments.project,
                            service_name=self.arguments.service,
                            token_host_path=str(self.token_file),
                            token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                        )

        compose = json.loads(self.compose_attestation())
        compose["services"]["sidecar"] = {
            "secrets": [
                {
                    "source": "copied-agent-token",
                    "target": CONTRACT.WORKER_TOKEN_PATH,
                }
            ]
        }
        with self.assertRaisesRegex(
            CONTRACT.ContractError,
            "overlays the Agent Token target",
        ):
            CONTRACT.attest_gateway_compose(
                json.dumps(compose).encode(),
                TOKEN,
                project=self.arguments.project,
                service_name=self.arguments.service,
                token_host_path=str(self.token_file),
                token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
            )

    def test_inspect_rejects_tmpfs_and_device_target_overlays(self) -> None:
        inspect = json.loads(self.inspect_attestation())
        inspect[0]["HostConfig"] = {
            "RestartPolicy": {
                "Name": "no",
                "MaximumRetryCount": 0,
            },
            "Tmpfs": {"/tmp": "rw,nosuid"},
            "Devices": [
                {
                    "PathOnHost": "/dev/null",
                    "PathInContainer": "/dev/cf-gateway-null",
                    "CgroupPermissions": "r",
                }
            ],
        }
        CONTRACT.attest_gateway_worker_inspect(
            json.dumps(inspect).encode(),
            TOKEN,
            project=self.arguments.project,
            service_name=self.arguments.service,
            token_host_path=str(self.token_file),
            token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
        )

        targets = (
            CONTRACT.WORKER_TOKEN_PATH,
            "/run/secrets",
            "/run/nested/../secrets",
        )
        for target in targets:
            for mechanism in ("tmpfs", "device"):
                with self.subTest(target=target, mechanism=mechanism):
                    inspect = json.loads(self.inspect_attestation())
                    if mechanism == "tmpfs":
                        inspect[0]["HostConfig"]["Tmpfs"] = {target: "rw"}
                    else:
                        inspect[0]["HostConfig"]["Devices"] = [
                            {
                                "PathOnHost": "/dev/null",
                                "PathInContainer": target,
                                "CgroupPermissions": "rwm",
                            }
                        ]
                    with self.assertRaisesRegex(
                        CONTRACT.ContractError,
                        "overlays the Agent Token target",
                    ):
                        CONTRACT.attest_gateway_worker_inspect(
                            json.dumps(inspect).encode(),
                            TOKEN,
                            project=self.arguments.project,
                            service_name=self.arguments.service,
                            token_host_path=str(self.token_file),
                            token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                        )

    def test_container_target_inventories_fail_closed_when_malformed(
        self,
    ) -> None:
        compose_cases = (
            ("secrets-not-list", "secrets", "database-password"),
            ("secret-short-form", "secrets", ["database-password"]),
            ("secret-missing-source", "secrets", [{"target": "/tmp/x"}]),
            ("tmpfs-missing-target", "tmpfs", [{"mode": "1777"}]),
            ("tmpfs-relative-target", "tmpfs", ["relative/path"]),
            ("device-short-form", "devices", ["/dev/null"]),
            (
                "device-conflicting-targets",
                "devices",
                [
                    {
                        "source": "/dev/null",
                        "target": "/dev/null",
                        "path_in_container": "/dev/zero",
                        "permissions": "r",
                    }
                ],
            ),
            (
                "device-invalid-permissions",
                "devices",
                ["/dev/null:/dev/null:rx"],
            ),
        )
        for label, field, value in compose_cases:
            with self.subTest(kind="compose", case=label):
                compose = json.loads(self.compose_attestation())
                compose["services"]["worker"][field] = value
                with self.assertRaisesRegex(
                    CONTRACT.ContractError,
                    "target inventory is invalid",
                ):
                    CONTRACT.attest_gateway_compose(
                        json.dumps(compose).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

        inspect_cases = (
            ("host-config-missing", None),
            ("tmpfs-not-object", {"Tmpfs": [], "Devices": []}),
            ("tmpfs-options-not-text", {"Tmpfs": {"/tmp": 1}, "Devices": []}),
            ("devices-not-list", {"Tmpfs": {}, "Devices": {}}),
            (
                "device-missing-target",
                {
                    "Tmpfs": {},
                    "Devices": [
                        {
                            "PathOnHost": "/dev/null",
                            "CgroupPermissions": "r",
                        }
                    ],
                },
            ),
            (
                "device-invalid-permissions",
                {
                    "Tmpfs": {},
                    "Devices": [
                        {
                            "PathOnHost": "/dev/null",
                            "PathInContainer": "/dev/null",
                            "CgroupPermissions": "rx",
                        }
                    ],
                },
            ),
        )
        for label, host_config in inspect_cases:
            with self.subTest(kind="inspect", case=label):
                inspect = json.loads(self.inspect_attestation())
                if host_config is None:
                    del inspect[0]["HostConfig"]
                else:
                    inspect[0]["HostConfig"] = host_config
                with self.assertRaisesRegex(
                    CONTRACT.ContractError,
                    "target inventory is invalid",
                ):
                    CONTRACT.attest_gateway_worker_inspect(
                        json.dumps(inspect).encode(),
                        TOKEN,
                        project=self.arguments.project,
                        service_name=self.arguments.service,
                        token_host_path=str(self.token_file),
                        token_worker_path=CONTRACT.WORKER_TOKEN_PATH,
                    )

    def test_actual_worker_inspect_attestation_is_independently_callable(
        self,
    ) -> None:
        self.write_valid_inputs()
        self.arguments.attestation_kind = "worker-inspect"
        self.attestation = self.inspect_attestation()
        result, stdout, stderr = self.invoke_main()
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "")

        payload = json.loads(self.inspect_attestation())
        payload[0]["Mounts"][0]["RW"] = True
        self.attestation = json.dumps(payload).encode()
        result, _, stderr = self.invoke_main()
        self.assertEqual(result, 1)
        self.assertIn("mount", stderr)

    def test_attestation_stdin_is_bounded(self) -> None:
        self.write_valid_inputs()
        self.attestation = b" " * (CONTRACT.MAX_ATTESTATION_BYTES + 1)
        result, stdout, stderr = self.invoke_main()
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("size limit", stderr)

    def test_contract_json_comparison_is_value_and_type_exact(self) -> None:
        expected = CONTRACT.expected_contract(self.arguments)
        self.assertEqual(
            expected["producer"],
            {
                "repository": "Tangbohu09527/CF_agent-gateway",
                "checkerSha256": self.checker_sha256,
            },
        )
        self.assertNotIn(
            "compatibleGatewayCommit",
            json.dumps(expected),
        )
        self.assertEqual(
            expected["gateway"]["checkerExecution"],
            {
                "caller": "management-user",
                "sudo": False,
                "dockerSocketAccess": False,
                "producerLinuxProof": "required",
            },
        )
        self.assertEqual(
            expected["gateway"]["lifecycle"],
            {
                "restartPolicy": "no",
                "bootPolicy": "manual-after-fresh-qr",
                "producerLinuxProof": "required",
            },
        )
        self.assertEqual(
            expected["gateway"]["credential"]["workerReadabilityProof"],
            "producer-linux-integration",
        )
        mutations = (
            ("bool-for-int", ("gateway", "checkerInterfaceVersion"), True),
            ("float-for-int", ("agent", "port"), 6174.0),
            ("int-for-bool", ("gateway", "requiresDockerHealth"), 1),
            (
                "producer-digest",
                ("producer", "checkerSha256"),
                "d" * 64,
            ),
        )
        for name, path, replacement in mutations:
            with self.subTest(name=name):
                payload = json.loads(json.dumps(expected))
                payload[path[0]][path[1]] = replacement
                self.contract_file.write_text(
                    json.dumps(payload),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    CONTRACT.ContractError,
                    "incompatible",
                ):
                    CONTRACT.require_exact_contract(
                        self.contract_file,
                        expected,
                    )

    def test_contract_rejects_duplicate_and_extra_keys(self) -> None:
        expected = CONTRACT.expected_contract(self.arguments)
        serialized = json.dumps(expected)
        self.contract_file.write_text(
            '{"contractVersion":"1",' + serialized[1:],
            encoding="utf-8",
        )
        with self.assertRaisesRegex(CONTRACT.ContractError, "duplicate key"):
            CONTRACT.require_exact_contract(self.contract_file, expected)

        payload = json.loads(serialized)
        payload["undocumented"] = True
        self.contract_file.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(CONTRACT.ContractError, "incompatible"):
            CONTRACT.require_exact_contract(self.contract_file, expected)

    def test_contract_version_two_is_incompatible(self) -> None:
        expected = CONTRACT.expected_contract(self.arguments)
        payload = json.loads(json.dumps(expected))
        payload["contractVersion"] = "2"
        self.contract_file.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(CONTRACT.ContractError, "incompatible"):
            CONTRACT.require_exact_contract(self.contract_file, expected)

    def test_contract_rejects_non_json_constants(self) -> None:
        self.contract_file.write_text('{"value":NaN}', encoding="utf-8")
        with self.assertRaisesRegex(CONTRACT.ContractError, "non-JSON"):
            CONTRACT.require_exact_contract(
                self.contract_file,
                CONTRACT.expected_contract(self.arguments),
            )

    def test_invalid_contract_arguments_are_rejected(self) -> None:
        for attribute, value in (
            ("port", 0),
            ("max_age", 0),
            ("alias", "bad alias"),
            ("checker", "relative/checker"),
            ("producer_repository", "missing-owner"),
            ("checker_sha256", "A" * 64),
        ):
            with self.subTest(attribute=attribute):
                arguments = argparse.Namespace(**vars(self.arguments))
                setattr(arguments, attribute, value)
                with self.assertRaisesRegex(
                    CONTRACT.ContractError,
                    "arguments are invalid",
                ):
                    CONTRACT.expected_contract(arguments)

    def test_os_error_does_not_echo_a_sensitive_path_component(self) -> None:
        self.write_valid_inputs()
        self.contract_file = self.base / TOKEN.decode()
        result, stdout, stderr = self.invoke_main()
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("could not be read safely", stderr)
        self.assertNotIn(TOKEN.decode(), stderr)

    def test_subprocess_ignores_token_environment_and_never_prints_secrets(
        self,
    ) -> None:
        self.write_valid_inputs()
        command = [sys.executable, *self.command()]
        environment = os.environ.copy()
        environment["CF_AGENT_WECHAT_TOKEN"] = OTHER_TOKEN.decode()
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            env=environment,
            input=self.attestation,
            timeout=10,
        )
        self.assertEqual(completed.returncode, 0)
        combined = completed.stdout + completed.stderr
        self.assertNotIn(TOKEN, combined)
        self.assertNotIn(OTHER_TOKEN, combined)
        self.assertNotIn(TOKEN.decode(), command)
        self.assertNotIn(OTHER_TOKEN.decode(), command)

    def test_helpers_do_not_access_process_environment(self) -> None:
        for script in (SCAN_SCRIPT, CONTRACT_SCRIPT):
            with self.subTest(script=script.name):
                self.assertNotIn(
                    "os.environ",
                    script.read_text(encoding="utf-8"),
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
