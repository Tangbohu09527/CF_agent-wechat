#!/usr/bin/env python3
"""Tests for the explicit, default-dry-run archive management tool."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import socket
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "archive-runtime.py"
SPEC = importlib.util.spec_from_file_location("archive_runtime", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
archive_runtime = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = archive_runtime
SPEC.loader.exec_module(archive_runtime)


class ArchiveFixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.storage = self.root / "storage"
        self.runtime = self.storage / "runtime"
        self.archive = self.storage / "session-archive"
        self.token = self.storage / "secrets" / "auth-token"
        self.archive.mkdir(parents=True)
        self.token.parent.mkdir()
        self.token.write_text("fixture-token\n", encoding="utf-8")
        self.archive.chmod(0o700)
        self.storage.chmod(0o755)
        self.token.parent.chmod(0o700)
        self.token.chmod(0o600)
        self.contract = archive_runtime.ArchiveContract(
            storage_root=self.storage,
            runtime_root=self.runtime,
            archive_root=self.archive,
            token_file=self.token,
            management_gid=os.getgid() if hasattr(os, "getgid") else 0,
        )

    def close(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def valid_v1_manifest() -> dict[str, object]:
        return {
            "schemaVersion": 1,
            "runtimeMode": "forced_qr",
            "result": "success",
            "archiveResult": "succeeded",
            "endedAtUtc": "2030-01-01T00:00:01Z",
        }

    @staticmethod
    def valid_v2_manifest() -> dict[str, object]:
        return {
            "schemaVersion": 2,
            "runtimeMode": "forced_qr",
            "result": "success",
            "archiveResult": "succeeded",
            "endedAtUtc": "2030-01-01T00:00:01Z",
            "manifestData": {
                "tokenIncluded": False,
                "accountIdentifiersIncluded": False,
                "chatIdentifiersIncluded": False,
                "messageContentIncluded": False,
            },
            "archivePayloadClassification": {
                "mayContainWechatSession": True,
                "mayContainAccountIdentifiers": True,
                "mayContainChatIdentifiers": True,
                "mayContainMessageMetadata": True,
                "mayContainMessageContent": True,
                "containsIndependentAgentApiToken": False,
                "independentAgentApiTokenScan": "verified",
                "accessClassification": "restricted",
                "productionSessionRecoveryAllowed": False,
            },
        }

    def write_manifest(self, archive: Path, payload: object) -> Path:
        manifest = archive / archive_runtime.MANIFEST_FILE_NAME
        manifest.write_text(
            json.dumps(payload, ensure_ascii=True) + "\n",
            encoding="utf-8",
        )
        manifest.chmod(0o600)
        return manifest

    def add_archive(self, name: str, payload: bytes = b"payload") -> Path:
        path = self.archive / name
        path.mkdir(mode=0o700)
        path.chmod(0o700)
        (path / "payload.bin").write_bytes(payload)
        self.write_manifest(path, self.valid_v1_manifest())
        return path

    def inventory(self):
        return archive_runtime.inventory_archives(
            self.contract,
            expected_uid=os.getuid() if hasattr(os, "getuid") else 0,
            allow_portable_testing=True,
        )


class ArchiveRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ArchiveFixture()

    def tearDown(self) -> None:
        self.fixture.close()

    def test_inventory_reports_count_size_and_oldest_newest(self) -> None:
        older = self.fixture.add_archive("20300101T000000Z", b"old")
        newer = self.fixture.add_archive("20300102T000000Z", b"new-data")
        os.utime(older, (1_700_000_000, 1_700_000_000))
        os.utime(newer, (1_800_000_000, 1_800_000_000))

        inventory = self.fixture.inventory()

        expected_bytes = sum(
            entry.stat().st_size
            for archive in (older, newer)
            for entry in archive.iterdir()
            if entry.is_file()
        )
        self.assertEqual(inventory.archiveCount, 2)
        self.assertEqual(inventory.totalApparentBytes, expected_bytes)
        self.assertEqual(inventory.totalRegularFiles, 4)
        self.assertEqual(inventory.oldest["name"], older.name)
        self.assertEqual(inventory.newest["name"], newer.name)

    def test_completed_schema_v1_is_accepted_as_historical_evidence(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")

        inventory = self.fixture.inventory()

        self.assertEqual(inventory.archiveCount, 1)
        self.assertEqual(inventory.archives[0].name, selected.name)

    def test_completed_schema_v2_requires_restricted_verified_classification(
        self,
    ) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        self.fixture.write_manifest(
            selected,
            self.fixture.valid_v2_manifest(),
        )

        inventory = self.fixture.inventory()

        self.assertEqual(inventory.archiveCount, 1)

    def test_missing_manifest_is_not_schema_v1_compatibility(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        (selected / archive_runtime.MANIFEST_FILE_NAME).unlink()

        with self.assertRaisesRegex(
            archive_runtime.ArchiveError,
            "manifest is missing",
        ):
            self.fixture.inventory()

    def test_malformed_and_non_object_manifests_are_rejected(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        manifest = selected / archive_runtime.MANIFEST_FILE_NAME
        for payload in (b"{", b"[]"):
            with self.subTest(payload=payload):
                manifest.write_bytes(payload)
                manifest.chmod(0o600)
                with self.assertRaises(archive_runtime.ArchiveError):
                    self.fixture.inventory()

    def test_stale_manifest_installation_file_is_rejected(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        (selected / ".manifest.json.1234").write_text(
            "unfinished",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            archive_runtime.ArchiveError,
            "unfinished manifest installation",
        ):
            self.fixture.inventory()

    def test_in_progress_manifest_is_rejected_for_every_schema(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        for payload in (
            self.fixture.valid_v1_manifest(),
            self.fixture.valid_v2_manifest(),
        ):
            with self.subTest(schema=payload["schemaVersion"]):
                payload["result"] = "in_progress"
                payload["endedAtUtc"] = None
                self.fixture.write_manifest(selected, payload)
                with self.assertRaisesRegex(
                    archive_runtime.ArchiveError,
                    "incomplete transaction",
                ):
                    self.fixture.inventory()

    def test_incomplete_schema_v2_classification_is_rejected(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        mutations = (
            ("missing-classification", None),
            ("scan-not-verified", "preflight_passed"),
            ("token-state-unknown", None),
            ("recovery-allowed", True),
        )
        for case, value in mutations:
            with self.subTest(case=case):
                payload = self.fixture.valid_v2_manifest()
                classification = payload["archivePayloadClassification"]
                assert isinstance(classification, dict)
                if case == "missing-classification":
                    payload.pop("archivePayloadClassification")
                elif case == "scan-not-verified":
                    classification["independentAgentApiTokenScan"] = value
                elif case == "token-state-unknown":
                    classification["containsIndependentAgentApiToken"] = value
                else:
                    classification["productionSessionRecoveryAllowed"] = value
                self.fixture.write_manifest(selected, payload)
                with self.assertRaisesRegex(
                    archive_runtime.ArchiveError,
                    "classification",
                ):
                    self.fixture.inventory()

    @unittest.skipUnless(os.name == "posix", "exact manifest mode requires POSIX")
    def test_manifest_requires_exact_protected_mode(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        (selected / archive_runtime.MANIFEST_FILE_NAME).chmod(0o644)

        with self.assertRaisesRegex(
            archive_runtime.ArchiveError,
            "manifest metadata is unsafe",
        ):
            self.fixture.inventory()

    def test_manifest_symlink_and_directory_are_rejected(self) -> None:
        for index, entry_type in enumerate(("symlink", "directory")):
            with self.subTest(entry_type=entry_type):
                selected = self.fixture.add_archive(
                    f"20300101T000000Z-{index + 1:02d}"
                )
                manifest = selected / archive_runtime.MANIFEST_FILE_NAME
                manifest.unlink()
                if entry_type == "symlink":
                    outside = self.fixture.root / "outside-manifest"
                    outside.write_text("{}", encoding="utf-8")
                    try:
                        manifest.symlink_to(outside)
                    except OSError:
                        outside.unlink()
                        self.fixture.write_manifest(
                            selected,
                            self.fixture.valid_v1_manifest(),
                        )
                        continue
                else:
                    manifest.mkdir()
                with self.assertRaisesRegex(
                    archive_runtime.ArchiveError,
                    "manifest metadata is unsafe",
                ):
                    self.fixture.inventory()
                if entry_type == "symlink":
                    manifest.unlink()
                    outside.unlink()
                else:
                    manifest.rmdir()
                self.fixture.write_manifest(
                    selected,
                    self.fixture.valid_v1_manifest(),
                )

    @unittest.skipUnless(os.name == "posix", "hard links require POSIX")
    def test_manifest_hard_link_is_rejected(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        manifest = selected / archive_runtime.MANIFEST_FILE_NAME
        os.link(manifest, self.fixture.root / "manifest-copy")
        with self.assertRaisesRegex(
            archive_runtime.ArchiveError,
            "manifest metadata is unsafe",
        ):
            self.fixture.inventory()

    def test_manifest_owner_contract_is_exact_when_enforced(self) -> None:
        metadata = mock.Mock(
            st_mode=stat.S_IFREG | 0o600,
            st_nlink=1,
            st_uid=1001,
            st_gid=1000,
        )
        with self.assertRaisesRegex(
            archive_runtime.ArchiveError,
            "manifest metadata is unsafe",
        ):
            archive_runtime._validate_manifest_metadata(
                metadata,
                expected_uid=1000,
                expected_gid=1000,
                enforce_identity=True,
            )

    def test_production_contract_requires_all_four_fixed_paths(self) -> None:
        approved = archive_runtime.ArchiveContract(
            storage_root=archive_runtime.PRODUCTION_STORAGE_ROOT,
            runtime_root=archive_runtime.PRODUCTION_RUNTIME_ROOT,
            archive_root=archive_runtime.PRODUCTION_ARCHIVE_ROOT,
            token_file=archive_runtime.PRODUCTION_TOKEN_FILE,
            management_gid=1000,
        )
        archive_runtime.validate_production_contract_paths(approved)

        fields = (
            "storage_root",
            "runtime_root",
            "archive_root",
            "token_file",
        )
        for field in fields:
            values = approved.__dict__.copy()
            values[field] = Path("/srv/unapproved") / field
            with (
                self.subTest(field=field),
                self.assertRaises(archive_runtime.ArchiveError),
            ):
                archive_runtime.validate_production_contract_paths(
                    archive_runtime.ArchiveContract(**values)
                )

    def test_management_env_metadata_accepts_only_exact_approved_tuples(self) -> None:
        operator = archive_runtime.ManagementIdentity(uid=1000, gid=1001)
        management_gid = 2000
        approved = (
            (0, 0, 0o600),
            (1000, 1001, 0o600),
            (0, management_gid, 0o640),
            (1000, management_gid, 0o640),
        )
        for owner_uid, owner_gid, mode in approved:
            with self.subTest(approved=(owner_uid, owner_gid, mode)):
                archive_runtime.validate_management_env_metadata(
                    owner_uid,
                    owner_gid,
                    mode,
                    operator,
                    management_gid,
                )

        rejected = (
            (0, management_gid, 0o600),
            (1000, management_gid, 0o600),
            (0, 0, 0o640),
            (1000, 1001, 0o640),
            (1000, management_gid, 0o644),
            (1000, management_gid, 0o666),
        )
        for owner_uid, owner_gid, mode in rejected:
            with (
                self.subTest(rejected=(owner_uid, owner_gid, mode)),
                self.assertRaises(archive_runtime.ArchiveError),
            ):
                archive_runtime.validate_management_env_metadata(
                    owner_uid,
                    owner_gid,
                    mode,
                    operator,
                    management_gid,
                )

    def test_management_env_cli_metadata_arguments_are_all_or_nothing(self) -> None:
        parser = archive_runtime.build_parser()
        arguments = parser.parse_args(
            ["--env-owner-uid", "1000", "inventory"]
        )
        with self.assertRaisesRegex(archive_runtime.ArchiveError, "provided together"):
            archive_runtime._management_env_metadata(arguments, self.fixture.token)

    def test_management_env_read_uses_nonblocking_cloexec_and_stable_metadata(
        self,
    ) -> None:
        target = self.fixture.token
        original_lstat = Path.lstat
        stable_metadata = original_lstat(target)
        expected_mode = stat.S_IMODE(stable_metadata.st_mode)
        observed_flags: list[int] = []
        real_open = os.open

        def recording_open(path, flags, *args, **kwargs):
            observed_flags.append(flags)
            return real_open(path, flags, *args, **kwargs)

        def stable_target_lstat(path: Path):
            if path == target:
                return stable_metadata
            return original_lstat(path)

        with (
            mock.patch.object(archive_runtime.os, "open", recording_open),
            mock.patch.object(
                archive_runtime.os,
                "fstat",
                return_value=stable_metadata,
            ),
            mock.patch.object(Path, "lstat", stable_target_lstat),
        ):
            data = archive_runtime._read_regular_file(
                target,
                max_bytes=1024,
                expected_uid=os.getuid() if hasattr(os, "getuid") else None,
                expected_gid=os.getgid() if hasattr(os, "getgid") else None,
                expected_mode=expected_mode,
            )
        self.assertEqual(data, b"fixture-token\n")
        self.assertTrue(observed_flags)
        for flag_name in ("O_NONBLOCK", "O_CLOEXEC"):
            flag = getattr(os, flag_name, 0)
            if flag:
                self.assertTrue(observed_flags[-1] & flag, flag_name)

        changed = mock.Mock()
        for attribute in (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_nlink",
            "st_uid",
            "st_gid",
            "st_size",
            "st_ctime_ns",
        ):
            setattr(changed, attribute, getattr(stable_metadata, attribute))
        changed.st_size = stable_metadata.st_size + 1
        with (
            mock.patch.object(
                archive_runtime.os,
                "fstat",
                side_effect=(stable_metadata, changed),
            ),
            mock.patch.object(Path, "lstat", stable_target_lstat),
            self.assertRaisesRegex(
                archive_runtime.ArchiveError,
                "changed during inspection",
            ),
        ):
            archive_runtime._read_regular_file(
                target,
                max_bytes=1024,
                expected_uid=os.getuid() if hasattr(os, "getuid") else None,
                expected_gid=os.getgid() if hasattr(os, "getgid") else None,
                expected_mode=expected_mode,
            )

    def test_management_env_visible_identity_is_rechecked_after_read(self) -> None:
        target = self.fixture.token
        expected_mode = stat.S_IMODE(target.stat().st_mode)
        original_lstat = Path.lstat
        original_read = os.read
        stable_metadata = original_lstat(target)
        reached_eof = False
        post_read_visible_checks = 0

        def record_eof(descriptor: int, size: int) -> bytes:
            nonlocal reached_eof
            chunk = original_read(descriptor, size)
            if not chunk:
                reached_eof = True
            return chunk

        def post_read_mutation(path: Path):
            nonlocal post_read_visible_checks
            if path != target:
                return original_lstat(path)
            if not reached_eof:
                return stable_metadata
            post_read_visible_checks += 1
            fields = list(stable_metadata)
            fields[stat.ST_SIZE] += 1
            return os.stat_result(fields)

        with (
            mock.patch.object(archive_runtime.os, "fstat", return_value=stable_metadata),
            mock.patch.object(archive_runtime.os, "read", record_eof),
            mock.patch.object(Path, "lstat", post_read_mutation),
            self.assertRaisesRegex(
                archive_runtime.ArchiveError,
                "changed during inspection",
            ),
        ):
            archive_runtime._read_regular_file(
                target,
                max_bytes=1024,
                expected_uid=os.getuid() if hasattr(os, "getuid") else None,
                expected_gid=os.getgid() if hasattr(os, "getgid") else None,
                expected_mode=expected_mode,
            )
        self.assertTrue(reached_eof)
        self.assertEqual(post_read_visible_checks, 1)

    def test_inventory_output_never_lists_payload_paths_or_internal_identity(
        self,
    ) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        (selected / "account-identifier.db").write_bytes(b"fixture-token")
        inventory = self.fixture.inventory()

        json_output = json.dumps(archive_runtime.inventory_to_dict(inventory))
        text_output = io.StringIO()
        archive_runtime.print_inventory(
            inventory,
            as_json=False,
            output=text_output,
        )
        rendered = json_output + text_output.getvalue()

        self.assertNotIn("account-identifier.db", rendered)
        self.assertNotIn("payload.bin", rendered)
        self.assertNotIn("fixture-token", rendered)
        self.assertNotIn('"device"', json_output)
        self.assertNotIn('"inode"', json_output)

    def test_inventory_redacts_non_production_archive_names(self) -> None:
        sensitive_name = "a" * 64
        self.fixture.add_archive(sensitive_name)

        with self.assertRaises(
            archive_runtime.InvalidArchiveNamesError
        ) as raised:
            self.fixture.inventory()

        self.assertEqual(raised.exception.count, 1)
        self.assertNotIn(sensitive_name, str(raised.exception))

    def test_archive_names_require_real_utc_timestamp_and_two_digit_suffix(
        self,
    ) -> None:
        for name in (
            "20300101T000000Z",
            "20300101T000000Z-01",
            "20300101T000000Z-99",
        ):
            with self.subTest(valid=name):
                archive_runtime._validate_archive_name(name)
        for name in (
            "archive-2030",
            "20300230T000000Z",
            "20300101T000000Z-1",
            "20300101T000000Z-100",
            "a" * 64,
        ):
            with (
                self.subTest(invalid=name),
                self.assertRaises(archive_runtime.ArchiveError),
            ):
                archive_runtime._validate_archive_name(name)

    @unittest.skipUnless(os.name == "posix", "mountinfo paths require POSIX")
    def test_mountinfo_parser_decodes_kernel_escaped_mount_points(self) -> None:
        data = (
            b"36 25 0:32 / / rw,relatime - ext4 /dev/root rw\n"
            b"37 36 0:32 /source /srv/archive/live\\040data rw - ext4 "
            b"/dev/root rw\n"
        )

        self.assertEqual(
            archive_runtime.parse_mountinfo(data),
            (Path("/"), Path("/srv/archive/live data")),
        )

    @unittest.skipUnless(os.name == "posix", "mount boundaries require POSIX")
    def test_same_filesystem_bind_mount_below_archive_is_rejected(self) -> None:
        archive = Path("/srv/storage/cf-agent-wechat/session-archive")
        mount_points = (
            Path("/"),
            archive,
            archive / "20300101T000000Z" / "live-runtime-subtree",
        )

        with self.assertRaises(archive_runtime.ArchiveError):
            archive_runtime.assert_no_archive_submounts(
                archive,
                mount_points=mount_points,
            )

        archive_runtime.assert_no_archive_submounts(
            archive,
            mount_points=(Path("/"), archive),
        )

    def test_retention_is_dry_run_by_default(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        before = selected.joinpath("payload.bin").read_bytes()

        plan = archive_runtime.retention_plan(self.fixture.inventory(), selected.name)

        self.assertFalse(plan["willDelete"])
        self.assertEqual(selected.joinpath("payload.bin").read_bytes(), before)
        self.assertFalse(
            self.fixture.archive.joinpath(archive_runtime.AUDIT_FILE_NAME).exists()
        )

    def test_path_escape_and_nested_selection_are_rejected(self) -> None:
        self.fixture.add_archive("20300101T000000Z")
        inventory = self.fixture.inventory()
        for selection in ("../runtime", "/tmp/archive", "nested/archive", "."):
            with (
                self.subTest(selection=selection),
                self.assertRaises(archive_runtime.ArchiveError),
            ):
                archive_runtime.retention_plan(inventory, selection)

    def test_current_runtime_cannot_be_nested_under_archive_root(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        invalid = archive_runtime.ArchiveContract(
            storage_root=self.fixture.storage,
            runtime_root=selected,
            archive_root=self.fixture.archive,
            token_file=self.fixture.token,
            management_gid=os.getgid() if hasattr(os, "getgid") else 0,
        )
        with self.assertRaises(archive_runtime.ArchiveError):
            archive_runtime.validate_contract(
                invalid,
                expected_uid=os.getuid() if hasattr(os, "getuid") else 0,
            )

    def test_archive_root_cannot_contain_the_token_path(self) -> None:
        secrets = self.fixture.token.parent
        invalid = archive_runtime.ArchiveContract(
            storage_root=self.fixture.storage,
            runtime_root=self.fixture.runtime,
            archive_root=secrets,
            token_file=self.fixture.token,
            management_gid=os.getgid() if hasattr(os, "getgid") else 0,
        )
        with self.assertRaises(archive_runtime.ArchiveError):
            archive_runtime.validate_contract(
                invalid,
                expected_uid=os.getuid() if hasattr(os, "getuid") else 0,
                require_root_mode=False,
            )

    def test_archive_root_symlink_is_rejected(self) -> None:
        target = self.fixture.root / "real-archive"
        target.mkdir(mode=0o700)
        link = self.fixture.root / "archive-link"
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError as exc:
            self.skipTest(f"symlinks are unavailable: {exc}")
        invalid = archive_runtime.ArchiveContract(
            storage_root=self.fixture.root,
            runtime_root=self.fixture.root / "runtime",
            archive_root=link,
            token_file=self.fixture.root / "secrets" / "auth-token",
            management_gid=os.getgid() if hasattr(os, "getgid") else 0,
        )
        with self.assertRaises(archive_runtime.ArchiveError):
            archive_runtime.validate_contract(
                invalid,
                expected_uid=os.getuid() if hasattr(os, "getuid") else 0,
            )

    def test_symlink_inside_archive_is_rejected_without_following_it(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        outside = self.fixture.root / "outside-secret"
        outside.write_text("must survive", encoding="utf-8")
        link = selected / "escape"
        try:
            link.symlink_to(outside)
        except OSError as exc:
            self.skipTest(f"symlinks are unavailable: {exc}")
        with self.assertRaises(archive_runtime.ArchiveError):
            self.fixture.inventory()
        self.assertEqual(outside.read_text(encoding="utf-8"), "must survive")

    @unittest.skipUnless(os.name == "posix", "hard-link identity requires POSIX")
    def test_hard_link_to_token_is_rejected(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        try:
            os.link(self.fixture.token, selected / "token-copy")
        except OSError as exc:
            self.skipTest(f"hard links are unavailable: {exc}")
        with self.assertRaises(archive_runtime.ArchiveError):
            self.fixture.inventory()

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_fifo_is_rejected(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        os.mkfifo(selected / "blocked-fifo")
        with self.assertRaises(archive_runtime.ArchiveError):
            self.fixture.inventory()

    @unittest.skipUnless(hasattr(socket, "AF_UNIX"), "Unix sockets unavailable")
    def test_unix_socket_is_rejected(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        socket_path = selected / "blocked.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(os.fspath(socket_path))
        except OSError as exc:
            server.close()
            self.skipTest(f"Unix sockets are unavailable: {exc}")
        try:
            with self.assertRaises(archive_runtime.ArchiveError):
                self.fixture.inventory()
        finally:
            server.close()
            socket_path.unlink(missing_ok=True)

    def test_unknown_file_at_archive_root_is_rejected(self) -> None:
        (self.fixture.archive / "unexpected.txt").write_text(
            "unknown", encoding="utf-8"
        )
        with self.assertRaises(archive_runtime.ArchiveError):
            self.fixture.inventory()

    def test_execute_requires_exact_flag_and_interactive_second_confirmation(
        self,
    ) -> None:
        name = "20300101T000000Z"
        phrase = f"DELETE:{name}"
        rejected = (
            (None, phrase, True),
            (phrase, None, True),
            (phrase, phrase, False),
            ("DELETE:other", phrase, True),
        )
        for flag, typed, is_tty in rejected:
            with (
                self.subTest(flag=flag, typed=typed, is_tty=is_tty),
                self.assertRaises(archive_runtime.ArchiveError),
            ):
                archive_runtime.validate_execute_confirmation(
                    name, flag, typed, is_tty=is_tty
                )
        self.assertEqual(
            archive_runtime.validate_execute_confirmation(
                name, phrase, phrase, is_tty=True
            ),
            phrase,
        )

    @unittest.skipUnless(os.name == "posix", "secure deletion requires POSIX")
    def test_explicit_delete_writes_started_and_completed_audit(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        inventory = self.fixture.inventory()
        record = inventory.archives[0]

        archive_runtime.execute_retention(
            self.fixture.contract,
            record,
            expected_uid=os.getuid(),
        )

        self.assertFalse(selected.exists())
        audit = self.fixture.archive / archive_runtime.AUDIT_FILE_NAME
        self.assertEqual(stat.S_IMODE(audit.stat().st_mode), 0o600)
        events = [
            json.loads(line)["event"]
            for line in audit.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(events, ["started", "completed"])

    @unittest.skipUnless(os.name == "posix", "secure deletion requires POSIX")
    def test_delete_rechecks_mount_boundaries_before_first_unlink(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        record = self.fixture.inventory().archives[0]

        with (
            mock.patch.object(
                archive_runtime,
                "assert_no_archive_submounts",
                side_effect=(None, archive_runtime.ArchiveError("mounted subtree")),
            ) as mount_check,
            self.assertRaises(archive_runtime.ArchiveError),
        ):
            archive_runtime.execute_retention(
                self.fixture.contract,
                record,
                expected_uid=os.getuid(),
            )

        self.assertEqual(mount_check.call_count, 2)
        self.assertTrue(selected.joinpath("payload.bin").is_file())
        self.assertFalse(
            self.fixture.archive.joinpath(archive_runtime.AUDIT_FILE_NAME).exists()
        )

    def test_symlink_audit_file_is_rejected(self) -> None:
        self.fixture.add_archive("20300101T000000Z")
        outside = self.fixture.root / "outside-audit"
        outside.write_text("safe", encoding="utf-8")
        audit = self.fixture.archive / archive_runtime.AUDIT_FILE_NAME
        try:
            audit.symlink_to(outside)
        except OSError as exc:
            self.skipTest(f"symlinks are unavailable: {exc}")
        with self.assertRaises(archive_runtime.ArchiveError):
            self.fixture.inventory()
        self.assertEqual(outside.read_text(encoding="utf-8"), "safe")

    @unittest.skipUnless(os.name == "posix", "management flock requires POSIX")
    def test_retention_lock_is_exclusive_and_reusable(self) -> None:
        lock_file = self.fixture.root / "runtime.lock"
        lock_file.touch(mode=0o640)
        lock_file.chmod(0o640)
        with mock.patch.object(archive_runtime, "RUNTIME_LOCK_FILE", lock_file):
            descriptor = archive_runtime.acquire_management_lock(
                self.fixture.contract,
                expected_uid=os.getuid(),
            )
            try:
                with self.assertRaises(archive_runtime.ArchiveError):
                    archive_runtime.acquire_management_lock(
                        self.fixture.contract,
                        expected_uid=os.getuid(),
                    )
            finally:
                archive_runtime.release_management_lock(descriptor)
            descriptor = archive_runtime.acquire_management_lock(
                self.fixture.contract,
                expected_uid=os.getuid(),
            )
            archive_runtime.release_management_lock(descriptor)

    @unittest.skipUnless(os.name == "posix", "management flock requires POSIX")
    def test_retention_lock_rejects_hard_links(self) -> None:
        lock_file = self.fixture.root / "runtime.lock"
        lock_file.touch(mode=0o640)
        lock_file.chmod(0o640)
        os.link(lock_file, self.fixture.root / "runtime.lock-copy")
        with (
            mock.patch.object(archive_runtime, "RUNTIME_LOCK_FILE", lock_file),
            self.assertRaises(archive_runtime.ArchiveError),
        ):
            archive_runtime.acquire_management_lock(
                self.fixture.contract,
                expected_uid=os.getuid(),
            )

    @unittest.skipUnless(os.name == "posix", "exact mode checks require POSIX")
    def test_archive_timestamp_directory_requires_exact_mode(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        selected.chmod(0o755)
        with self.assertRaises(archive_runtime.ArchiveError):
            self.fixture.inventory()

    @unittest.skipUnless(os.name == "posix", "exact mode checks require POSIX")
    def test_storage_root_requires_exact_mode(self) -> None:
        self.fixture.storage.chmod(0o700)
        with self.assertRaises(archive_runtime.ArchiveError):
            self.fixture.inventory()

    def test_audit_metadata_requires_exact_group(self) -> None:
        metadata = mock.Mock(
            st_mode=stat.S_IFREG | 0o600,
            st_nlink=1,
            st_uid=1000,
            st_gid=1001,
        )
        with self.assertRaises(archive_runtime.ArchiveError):
            archive_runtime._validate_audit_metadata(metadata, 1000, 1000)

    @unittest.skipUnless(os.name == "posix", "signal deadlines require POSIX")
    def test_inventory_hard_timeout_interrupts_blocking_validation(self) -> None:
        started = time.monotonic()
        with (
            mock.patch.object(
                archive_runtime,
                "validate_contract",
                side_effect=lambda *_args, **_kwargs: time.sleep(5),
            ),
            self.assertRaises(archive_runtime.ArchiveError),
        ):
            archive_runtime.inventory_archives(
                self.fixture.contract,
                expected_uid=os.getuid(),
                expected_gid=os.getgid(),
                timeout_seconds=1,
            )
        self.assertLess(time.monotonic() - started, 3)

    @unittest.skipUnless(os.name == "posix", "signal deadlines require POSIX")
    def test_nested_hard_timeout_reuses_the_outer_deadline(self) -> None:
        started = time.monotonic()
        with self.assertRaisesRegex(
            archive_runtime.ArchiveError,
            "hard time limit",
        ):
            with archive_runtime.posix_hard_timeout(2):
                with archive_runtime.posix_hard_timeout(1):
                    time.sleep(5)
        self.assertLess(time.monotonic() - started, 3)

    @unittest.skipUnless(os.name == "posix", "signal deadlines require POSIX")
    def test_cli_timeout_includes_blocking_contract_load(self) -> None:
        started = time.monotonic()
        with (
            mock.patch.dict(
                os.environ,
                {"CF_AGENT_WECHAT_TESTING": "1"},
                clear=False,
            ),
            mock.patch.object(
                archive_runtime,
                "load_contract",
                side_effect=lambda *_args, **_kwargs: time.sleep(5),
            ),
        ):
            result = archive_runtime.main(
                [
                    "--testing-env-file",
                    os.fspath(self.fixture.token),
                    "--timeout-seconds",
                    "1",
                    "inventory",
                ]
            )
        self.assertEqual(result, 1)
        self.assertLess(time.monotonic() - started, 3)

    @unittest.skipUnless(os.name == "posix", "signal deadlines require POSIX")
    def test_delete_timeout_bounds_the_failed_audit_recovery(self) -> None:
        selected = self.fixture.add_archive("20300101T000000Z")
        record = self.fixture.inventory().archives[0]
        original_append = archive_runtime._append_audit

        def block_failed_audit(*args, **kwargs):
            if kwargs.get("event") == "failed":
                time.sleep(5)
            return original_append(*args, **kwargs)

        started = time.monotonic()
        with (
            mock.patch.object(
                archive_runtime,
                "_delete_directory_contents",
                side_effect=lambda *_args, **_kwargs: time.sleep(5),
            ),
            mock.patch.object(
                archive_runtime,
                "_append_audit",
                side_effect=block_failed_audit,
            ),
            self.assertRaises(archive_runtime.ArchiveError),
        ):
            archive_runtime.execute_retention(
                self.fixture.contract,
                record,
                expected_uid=os.getuid(),
                expected_gid=os.getgid(),
                timeout_seconds=1,
            )
        self.assertLess(time.monotonic() - started, 4)
        self.assertTrue(selected.is_dir())


class ManagementEnvTests(unittest.TestCase):
    def test_parser_rejects_duplicate_and_shell_syntax(self) -> None:
        bad_values = (
            (
                b"CF_AGENT_WECHAT_STORAGE_ROOT=/srv/x\n"
                b"CF_AGENT_WECHAT_STORAGE_ROOT=/srv/y\n"
            ),
            b"export CF_AGENT_WECHAT_STORAGE_ROOT=/srv/x\n",
            b" CF_AGENT_WECHAT_STORAGE_ROOT=/srv/x\n",
        )
        for data in bad_values:
            with (
                self.subTest(data=data),
                self.assertRaises(archive_runtime.ArchiveError),
            ):
                archive_runtime.parse_management_env(data)

    def test_parser_rejects_non_lf_control_separators(self) -> None:
        base = (
            b"CF_AGENT_WECHAT_STORAGE_ROOT=/srv/storage/cf-agent-wechat\n"
            b"CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/storage/cf-agent-wechat/runtime\n"
            b"CF_AGENT_WECHAT_ARCHIVE_ROOT=/srv/storage/cf-agent-wechat/session-archive\n"
            b"CF_AGENT_WECHAT_MANAGEMENT_GID=1000\n"
        )
        controls = (b"\x00", b"\x0b", b"\x0c", b"\r", b"\r\n", b"\x7f", b"\xc2\x85")
        for control in controls:
            data = base.replace(b"\n", control, 1)
            with (
                self.subTest(control=control),
                self.assertRaises(archive_runtime.ArchiveError),
            ):
                archive_runtime.parse_management_env(data)

    def test_parser_extracts_only_data_without_evaluation(self) -> None:
        values = archive_runtime.parse_management_env(
            b"CF_AGENT_WECHAT_STORAGE_ROOT=/srv/storage/cf-agent-wechat\n"
            b"CF_AGENT_WECHAT_RUNTIME_ROOT=/srv/storage/cf-agent-wechat/runtime\n"
            b"CF_AGENT_WECHAT_ARCHIVE_ROOT=/srv/storage/cf-agent-wechat/session-archive\n"
            b"CF_AGENT_WECHAT_MANAGEMENT_GID=1000\n"
            b"PROXY=\n"
        )
        self.assertEqual(
            values["CF_AGENT_WECHAT_ARCHIVE_ROOT"],
            "/srv/storage/cf-agent-wechat/session-archive",
        )


if __name__ == "__main__":
    unittest.main()
