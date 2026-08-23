#!/usr/bin/env python3
"""Unit tests for the QR dependency lock contract."""

from __future__ import annotations

import hashlib
import base64
import csv
import os
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_login_dependencies_under_test",
    REPO_ROOT / "scripts" / "verify_login_dependencies.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load dependency verifier")
VERIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFIER
SPEC.loader.exec_module(VERIFIER)


class LoginDependencyContractTests(unittest.TestCase):
    def write_lock(self, text: str) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "requirements.txt"
        path.write_text(text, encoding="ascii")
        return path

    def test_repository_lock_has_only_exact_hashed_dependencies(self) -> None:
        path = REPO_ROOT / "scripts" / "requirements.txt"
        contract = VERIFIER.load_lock(path)
        self.assertEqual(
            contract.sha256,
            hashlib.sha256(path.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            {item.name for item in contract.requirements},
            set(VERIFIER.EXPECTED_PACKAGES),
        )
        self.assertTrue(all(item.hashes for item in contract.requirements))

    def test_production_paths_ignore_host_python_home_and_xdg(self) -> None:
        common = (REPO_ROOT / "scripts" / "common.sh").read_text(encoding="utf-8")
        self.assertIn("PYTHON_BIN=/usr/bin/python3", common)
        self.assertIn('REQUIREMENTS_FILE="${SCRIPTS_DIR}/requirements.txt"', common)
        self.assertIn("pwd.getpwuid(os.getuid()).pw_dir", common)
        self.assertIn(
            'VENV_DIR="${_operator_home}/.local/share/cf-agent-wechat/venv"',
            common,
        )

        self.assertIn('selected_python="$(/usr/bin/env -i', common)

    def test_pip_runs_with_hashes_hard_timeout_and_clean_environment(self) -> None:
        helper = (
            REPO_ROOT / "scripts" / "ensure-login-environment.sh"
        ).read_text(encoding="utf-8")
        self.assertEqual(helper.splitlines()[0], "#!/usr/bin/env bash")
        self.assertEqual(helper.splitlines()[1], "umask 077")
        for fragment in (
            "timeout --signal=TERM --kill-after=5s",
            "/usr/bin/env -i",
            "PIP_NO_INPUT=1",
            "PIP_DISABLE_PIP_VERSION_CHECK=1",
            "PIP_CONFIG_FILE=/dev/null",
            "--require-hashes",
            "--only-binary=:all:",
            "--no-compile",
            "pip setuptools wheel",
            "validate-runtime",
            'bounded_clean_python "$python_bin" -I -B "$verifier"',
            'verify-installed "$requirements_file" "$venv_dir"',
            'audit-tree "$candidate"',
            '--retries "$retries"',
            '--timeout "$network_timeout"',
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, helper)
        self.assertNotIn("--proxy", helper)

        runtime_gate = helper.index("validate-runtime")
        parent_creation = helper.index(
            'if [ ! -e "$venv_parent" ] && [ ! -L "$venv_parent" ]'
        )
        old_move = helper.index('/bin/mv -- "$venv_dir" "$previous_venv"')
        pip_install = helper.index("-m pip install")
        self.assertLess(runtime_gate, parent_creation)
        self.assertLess(runtime_gate, old_move)
        self.assertLess(runtime_gate, pip_install)

        stamp_move = helper.index('/bin/mv -- "$temporary_stamp" "$stamp_file"')
        committed = helper.index("committed=1", stamp_move)
        cleanup = helper.index('remove_managed_tree "$previous_venv"', committed)
        self.assertLess(stamp_move, committed)
        self.assertLess(committed, cleanup)
        self.assertLess(helper.index("transaction_started=1", old_move - 100), old_move)

        common = (REPO_ROOT / "scripts" / "common.sh").read_text(encoding="utf-8")
        self.assertIn('PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1', common)
        self.assertIn('"$LOGIN_PYTHON" -I -B "$@"', common)
        self.assertIn('"$CF_AGENT_WECHAT_TESTING")', common)


    def test_missing_or_malformed_hash_fails_closed(self) -> None:
        digest = "a" * 64
        cases = (
            (
                "--only-binary=:all:\n"
                "Pillow==12.3.0\n"
                f"qrcode==8.2 --hash=sha256:{digest}\n"
                f"websocket-client==1.8.0 --hash=sha256:{digest}\n"
            ),
            (
                "--only-binary=:all:\n"
                f"Pillow==12.3.0 --hash=sha256:{'b' * 63}\n"
                f"qrcode==8.2 --hash=sha256:{digest}\n"
                f"websocket-client==1.8.0 --hash=sha256:{digest}\n"
            ),
        )
        for text in cases:
            with self.subTest(text=text), self.assertRaises(VERIFIER.ContractError):
                VERIFIER.load_lock(self.write_lock(text))

    def test_source_distributions_cannot_be_enabled(self) -> None:
        digest = "a" * 64
        path = self.write_lock(
            f"Pillow==12.3.0 --hash=sha256:{digest}\n"
            f"qrcode==8.2 --hash=sha256:{digest}\n"
            f"websocket-client==1.8.0 --hash=sha256:{digest}\n"
        )
        with self.assertRaisesRegex(VERIFIER.ContractError, "only-binary"):
            VERIFIER.load_lock(path)

    def test_free_threaded_cpython_is_rejected(self) -> None:
        with mock.patch.object(
            VERIFIER.platform,
            "python_implementation",
            return_value="CPython",
        ), mock.patch.object(
            VERIFIER.sysconfig,
            "get_config_var",
            return_value=1,
        ), self.assertRaisesRegex(
            VERIFIER.ContractError,
            "GIL-enabled CPython",
        ):
            VERIFIER.validate_python_runtime()

    def test_unsupported_runtime_fails_the_standalone_preinstall_gate(self) -> None:
        with (
            mock.patch.object(
                VERIFIER.platform,
                "python_implementation",
                return_value="PyPy",
            ),
            self.assertRaisesRegex(VERIFIER.ContractError, "requires CPython"),
        ):
            VERIFIER.validate_python_runtime()

        with (
            mock.patch.object(
                VERIFIER.platform,
                "python_implementation",
                return_value="CPython",
            ),
            mock.patch.object(VERIFIER.sys, "version_info", (3, 9, 0)),
            self.assertRaisesRegex(VERIFIER.ContractError, "3.10-3.14"),
        ):
            VERIFIER.validate_python_runtime()


@unittest.skipUnless(os.name == "posix" and hasattr(os, "getuid"), "POSIX only")
class InstalledVenvContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name) / "managed"
        self.venv = self.parent / "venv"
        self.bin_dir = self.venv / "bin"
        version_dir = f"python{sys.version_info.major}.{sys.version_info.minor}"
        self.site_packages = self.venv / "lib" / version_dir / "site-packages"
        self.site_packages.mkdir(parents=True)
        self.bin_dir.mkdir()
        for directory in (
            self.parent,
            self.venv,
            self.venv / "lib",
            self.venv / "lib" / version_dir,
            self.site_packages,
            self.bin_dir,
        ):
            directory.chmod(0o700)

        self.base_python = Path(sys.executable).resolve()
        (self.bin_dir / "python").symlink_to(self.base_python)
        self._write_file(
            self.venv / "pyvenv.cfg",
            "include-system-site-packages = false\n",
        )
        self.activate = self.bin_dir / "activate"
        self._write_file(self.activate, "# fixture\n")
        self.lock = VERIFIER.load_lock(
            REPO_ROOT / "scripts" / "requirements.txt"
        )
        module_paths = {
            "pillow": Path("PIL/__init__.py"),
            "qrcode": Path("qrcode/__init__.py"),
            "websocket-client": Path("websocket.py"),
        }
        for requirement in self.lock.requirements:
            module_path = self.site_packages / module_paths[requirement.name]
            module_path.parent.mkdir(parents=True, exist_ok=True)
            module_path.parent.chmod(0o700)
            self._write_file(module_path, f"VERSION = {requirement.version!r}\n")
            dist_name = requirement.name.replace("-", "_")
            dist_info = self.site_packages / (
                f"{dist_name}-{requirement.version}.dist-info"
            )
            dist_info.mkdir(mode=0o700)
            metadata = dist_info / "METADATA"
            self._write_file(
                metadata,
                f"Name: {requirement.name}\nVersion: {requirement.version}\n",
            )
            record = dist_info / "RECORD"
            rows = [
                self._record_row(module_path),
                self._record_row(metadata),
                (self._relative_record_path(record), "", ""),
            ]
            if requirement.name == "qrcode":
                console_script = self.bin_dir / "qr"
                self._write_file(console_script, "#!/bin/sh\nexit 0\n")
                console_script.chmod(0o700)
                rows.insert(1, self._record_row(console_script))
            with record.open("w", encoding="utf-8", newline="") as handle:
                csv.writer(handle).writerows(rows)
            record.chmod(0o600)

    def _write_file(self, path: Path, content: str) -> None:
        path.write_text(content, encoding="utf-8")
        path.chmod(0o600)

    def _relative_record_path(self, path: Path) -> str:
        return Path(os.path.relpath(path, self.site_packages)).as_posix()

    def _record_row(self, path: Path) -> tuple[str, str, str]:
        content = path.read_bytes()
        digest = base64.urlsafe_b64encode(hashlib.sha256(content).digest())
        encoded = digest.rstrip(b"=").decode("ascii")
        return (
            self._relative_record_path(path),
            f"sha256={encoded}",
            str(len(content)),
        )

    def verify(self) -> str:
        return VERIFIER.verify_installed(
            self.lock,
            self.venv,
            self.base_python,
            os.getuid(),
            os.getgid(),
        )

    def test_matching_venv_emits_record_and_tree_contract(self) -> None:
        rendered = self.verify()
        self.assertIn("schema=3", rendered)
        self.assertIn(f"requirements_sha256={self.lock.sha256}", rendered)
        self.assertIn("python_gil=enabled", rendered)
        self.assertRegex(rendered, r"records_sha256=[0-9a-f]{64}")
        self.assertRegex(rendered, r"tree_sha256=[0-9a-f]{64}")
        self.assertNotIn("--hash", rendered)
        pillow = next(item for item in self.lock.requirements if item.name == "pillow")
        self.assertEqual(pillow.version, "12.3.0")

    def test_stale_minor_interpreter_link_is_auditable_but_requires_rebuild(
        self,
    ) -> None:
        current_minor = sys.version_info.minor
        stale_minor = current_minor - 1 if current_minor > 0 else current_minor + 1
        stale_link = self.bin_dir / f"python3.{stale_minor}"
        stale_link.symlink_to(self.base_python)

        relaxed = VERIFIER.audit_managed_tree(
            self.venv,
            self.base_python,
            os.getuid(),
            os.getgid(),
            allow_stale_python_links=True,
        )
        self.assertRegex(relaxed, r"^[0-9a-f]{64}$")
        with self.assertRaisesRegex(VERIFIER.ContractError, "unapproved symlink"):
            VERIFIER.audit_managed_tree(
                self.venv,
                self.base_python,
                os.getuid(),
                os.getgid(),
                allow_stale_python_links=False,
            )
        with self.assertRaisesRegex(VERIFIER.ContractError, "unapproved symlink"):
            self.verify()

    def test_stale_minor_link_to_foreign_interpreter_is_never_auditable(
        self,
    ) -> None:
        current_minor = sys.version_info.minor
        stale_minor = current_minor - 1 if current_minor > 0 else current_minor + 1
        foreign = Path("/bin/sh").resolve()
        if foreign == self.base_python:
            self.skipTest("fixture foreign interpreter unexpectedly equals Python")
        (self.bin_dir / f"python3.{stale_minor}").symlink_to(foreign)

        with self.assertRaisesRegex(VERIFIER.ContractError, "unapproved symlink"):
            VERIFIER.audit_managed_tree(
                self.venv,
                self.base_python,
                os.getuid(),
                os.getgid(),
                allow_stale_python_links=True,
            )

    def test_tampered_package_fails_closed(self) -> None:
        package = self.site_packages / "websocket.py"
        self._write_file(package, "TAMPERED = True\n")
        with self.assertRaisesRegex(VERIFIER.ContractError, "differs from RECORD"):
            self.verify()

    def test_tampered_record_fails_closed(self) -> None:
        record = next(self.site_packages.glob("qrcode-*.dist-info/RECORD"))
        record.write_text(
            record.read_text(encoding="utf-8").replace("sha256=", "sha256=AAAA", 1),
            encoding="utf-8",
        )
        record.chmod(0o600)
        with self.assertRaisesRegex(VERIFIER.ContractError, "differs from RECORD"):
            self.verify()

    def test_extra_distribution_and_path_hooks_fail_closed(self) -> None:
        extra = self.site_packages / "extra-1.dist-info"
        extra.mkdir(mode=0o700)
        self._write_file(extra / "METADATA", "Name: extra\nVersion: 1\n")
        self._write_file(extra / "RECORD", "extra-1.dist-info/RECORD,,\n")
        with self.assertRaisesRegex(VERIFIER.ContractError, "set differs"):
            self.verify()

    def test_pth_and_sitecustomize_fail_closed(self) -> None:
        hook = self.site_packages / "attacker.pth"
        self._write_file(hook, "import attacker\n")
        with self.assertRaisesRegex(VERIFIER.ContractError, "injection"):
            self.verify()
        hook.unlink()

        self._write_file(
            self.site_packages / "sitecustomize.py", "raise RuntimeError\n"
        )
        with self.assertRaisesRegex(VERIFIER.ContractError, "injection"):
            self.verify()

    def test_fake_interpreter_is_never_executed(self) -> None:
        interpreter = self.bin_dir / "python"
        interpreter.unlink()
        marker = self.parent / "executed"
        self._write_file(
            interpreter,
            f"#!/bin/sh\ntouch {marker}\nexit 0\n",
        )
        interpreter.chmod(0o700)
        with self.assertRaisesRegex(VERIFIER.ContractError, "approved symlink"):
            self.verify()
        self.assertFalse(marker.exists())

    def test_stamp_tree_digest_detects_non_record_tampering(self) -> None:
        original = self.verify()
        stamp = self.venv / VERIFIER.STAMP_NAME
        self._write_file(stamp, original + "\n")
        self.assertEqual(self.verify(), original)

        self._write_file(self.activate, "# modified after attestation\n")
        changed = self.verify()
        self.assertNotEqual(changed, original)
        self.assertIn("tree_sha256=", changed)

    def test_world_readable_venv_is_rejected(self) -> None:
        self.venv.chmod(0o755)
        with self.assertRaisesRegex(VERIFIER.ContractError, "approved mode"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
