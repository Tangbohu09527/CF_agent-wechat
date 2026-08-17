#!/usr/bin/env python3
"""Isolated integration tests for the forced-QR production lifecycle."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
HELPERS = REPO_ROOT / "tests" / "helpers"
SENSITIVE_TOKEN_PREFIX = "token-fixture-sensitive-"
SENSITIVE_ACCOUNT_PREFIX = "account-fixture-sensitive-"
SENSITIVE_CHAT_PREFIX = "chat fixture/sensitive?"


def tree_digest(path: Path) -> str:
    digest = hashlib.sha256()
    if not path.exists():
        digest.update(b"<missing>")
        return digest.hexdigest()
    for current in sorted([path, *path.rglob("*")], key=lambda item: str(item)):
        metadata = current.lstat()
        relative = "." if current == path else str(current.relative_to(path))
        digest.update(relative.encode("utf-8"))
        digest.update(
            (
                f":{stat.S_IMODE(metadata.st_mode):o}:"
                f"{metadata.st_uid}:{metadata.st_gid}:{metadata.st_mtime_ns}"
            ).encode("ascii")
        )
        if current.is_file() and not current.is_symlink():
            digest.update(current.read_bytes())
    return digest.hexdigest()


class RuntimeFixture:
    def __init__(self, name: str) -> None:
        self.root = Path(tempfile.mkdtemp(prefix=f"cf-qr-{name}-"))
        self.storage = self.root / "storage"
        self.runtime = self.storage / "runtime"
        self.archive = self.storage / "session-archive"
        self.secrets = self.storage / "secrets"
        self.gateway_dir = self.root / "gateway"
        self.agent_compose = self.root / "agent-compose.yaml"
        self.gateway_compose = self.gateway_dir / "compose.yaml"
        self.fake_bin = self.root / "bin"
        self.docker_state = self.root / "docker-state"
        self.home = self.root / "home"
        self.auth_state = self.root / "auth-state"
        self.scenario_file = self.root / "scenario.json"
        self.ready_file = self.root / "mock.ready"
        self.pause_file = self.root / "ws.pause"
        self.continue_file = self.root / "ws.continue"
        self.login_pause_file = self.root / "login.pause"
        self.login_continue_file = self.root / "login.continue"
        self.audit_log = self.root / "audit.log"
        self.mutation_log = self.root / "mutations.log"
        self.login_log = self.root / "login.log"
        self.server: subprocess.Popen[bytes] | None = None
        self.background: list[subprocess.Popen[str]] = []

        self.token = f"{SENSITIVE_TOKEN_PREFIX}{name}"
        self.account = f"{SENSITIVE_ACCOUNT_PREFIX}{name}"
        self.chat = f"{SENSITIVE_CHAT_PREFIX}{name}#/id"
        self._create_layout()
        self.env = self._build_environment()
        self.set_scenario()
        self._start_server()

    def _create_layout(self) -> None:
        self.runtime.mkdir(parents=True)
        (self.runtime / "data").mkdir()
        (self.runtime / "wechat-home").mkdir()
        (self.runtime / "data" / "old-state.marker").write_text(
            "old runtime state\n", encoding="utf-8"
        )
        os.chmod(self.storage, 0o755)
        os.chmod(self.runtime, 0o751)
        os.chmod(self.runtime / "data", 0o731)
        os.chmod(self.runtime / "wechat-home", 0o711)

        self.secrets.mkdir()
        os.chmod(self.secrets, 0o700)
        token_file = self.secrets / "auth-token"
        token_file.write_text(self.token + "\n", encoding="utf-8")
        os.chmod(token_file, 0o600)

        self.gateway_dir.mkdir()
        self.agent_compose.write_text("services: {}\n", encoding="utf-8")
        self.gateway_compose.write_text("services: {}\n", encoding="utf-8")
        self.fake_bin.mkdir()
        self.docker_state.mkdir()
        self.home.mkdir()
        for name, value in {
            "gateway_running": "1",
            "agent_exists": "1",
            "agent_running": "1",
            "wechat_mode": "stable",
            "wechat_calls": "0",
        }.items():
            (self.docker_state / name).write_text(value + "\n", encoding="ascii")

        helper_names = {
            "docker": "mock_docker.sh",
            "sudo": "mock_sudo.sh",
            "date": "mock_date.sh",
        }
        for target, source in helper_names.items():
            destination = self.fake_bin / target
            shutil.copy2(HELPERS / source, destination)
            os.chmod(destination, 0o755)

        venv_dir = self.home / ".local" / "share" / "cf-agent-wechat" / "venv"
        (venv_dir / "bin").mkdir(parents=True)
        fake_python = venv_dir / "bin" / "python"
        shutil.copy2(HELPERS / "mock_login_python.sh", fake_python)
        os.chmod(fake_python, 0o755)
        requirements = (SCRIPTS / "requirements.txt").read_bytes()
        checksum = subprocess.check_output(["cksum"], input=requirements, text=False)
        (venv_dir / ".cf-agent-wechat-requirements").write_bytes(checksum)

        self.auth_state.write_text("logged_out\n", encoding="ascii")
        for log_file in (self.audit_log, self.mutation_log, self.login_log):
            log_file.write_text("", encoding="utf-8")

    def _build_environment(self) -> dict[str, str]:
        current_uid = str(os.getuid())
        current_gid = str(os.getgid())
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "HOME": str(self.home),
                "API_URL": "http://127.0.0.1:1",
                "WS_URL": "ws://127.0.0.1:1/api/ws/login?newAccount=false",
                "TOKEN_FILE": str(self.secrets / "auth-token"),
                "CONTAINER_NAME": "agent-wechat-fixture",
                "PYTHON_BIN": sys.executable,
                "CF_AGENT_WECHAT_VENV": str(
                    self.home
                    / ".local"
                    / "share"
                    / "cf-agent-wechat"
                    / "venv"
                ),
                "CF_AGENT_WECHAT_STORAGE_ROOT": str(self.storage),
                "CF_AGENT_WECHAT_RUNTIME_ROOT": str(self.runtime),
                "CF_AGENT_WECHAT_ARCHIVE_ROOT": str(self.archive),
                "CF_AGENT_WECHAT_LOCK_FILE": str(
                    self.root / "qr-runtime.lock"
                ),
                "CF_AGENT_WECHAT_COMPOSE_FILE": str(self.agent_compose),
                "CF_AGENT_GATEWAY_COMPOSE_FILE": str(self.gateway_compose),
                "CF_AGENT_GATEWAY_PROJECT_DIR": str(self.gateway_dir),
                "CF_AGENT_WECHAT_RUNTIME_UID": current_uid,
                "CF_AGENT_WECHAT_RUNTIME_GID": current_gid,
                "CF_AGENT_WECHAT_RUNTIME_MODE": "700",
                "SERVER_READY_TIMEOUT": "3",
                "WECHAT_READY_TIMEOUT": "3",
                "WECHAT_STABLE_SECONDS": "1",
                "POST_LOGIN_READY_TIMEOUT": "3",
                "RUNTIME_POLL_INTERVAL": "1",
                "HTTP_CONNECT_TIMEOUT": "1",
                "HTTP_TIMEOUT": "2",
                "LOGIN_TIMEOUT_MS": "2000",
                "LOGIN_CONFIRM_RETRIES": "2",
                "LOGIN_CONFIRM_INTERVAL": "0",
                "MOCK_DOCKER_STATE_DIR": str(self.docker_state),
                "MOCK_DOCKER_LOG": str(self.audit_log),
                "MOCK_DOCKER_MUTATION_LOG": str(self.mutation_log),
                "MOCK_GATEWAY_COMPOSE_FILE": str(self.gateway_compose),
                "MOCK_LOGIN_LOG": str(self.login_log),
                "MOCK_AUTH_STATE_FILE": str(self.auth_state),
                "MOCK_LOGIN_PAUSE_FILE": str(self.login_pause_file),
                "MOCK_LOGIN_CONTINUE_FILE": str(self.login_continue_file),
                "MOCK_REAL_PYTHON": sys.executable,
                "MOCK_REAL_DATE": shutil.which("date") or "/bin/date",
                "MOCK_FIXED_UTC": "1",
                "NO_COLOR": "1",
                "HTTP_PROXY": "http://127.0.0.1:9",
                "HTTPS_PROXY": "http://127.0.0.1:9",
                "http_proxy": "http://127.0.0.1:9",
                "https_proxy": "http://127.0.0.1:9",
                "NO_PROXY": "",
                "no_proxy": "",
            }
        )
        return env

    def set_scenario(self, **overrides: object) -> None:
        payload: dict[str, object] = {
            "health_status": 200,
            "chats_mode": "ok",
            "messages_mode": "ok",
            "account_id": self.account,
            "chat_id": self.chat,
        }
        payload.update(overrides)
        self.scenario_file.write_text(
            json.dumps(payload), encoding="utf-8"
        )

    def _start_server(self) -> None:
        command = [
            sys.executable,
            str(HELPERS / "mock_agent_wechat.py"),
            "--token-file",
            str(self.secrets / "auth-token"),
            "--state-file",
            str(self.auth_state),
            "--log-file",
            str(self.audit_log),
            "--ready-file",
            str(self.ready_file),
            "--pause-file",
            str(self.pause_file),
            "--continue-file",
            str(self.continue_file),
            "--scenario-file",
            str(self.scenario_file),
        ]
        self.server = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not self.ready_file.exists():
            if self.server.poll() is not None:
                raise RuntimeError("mock agent server exited before ready")
            time.sleep(0.02)
        if not self.ready_file.exists():
            raise RuntimeError("mock agent server did not become ready")
        ports = json.loads(self.ready_file.read_text(encoding="utf-8"))
        self.env["API_URL"] = f"http://127.0.0.1:{ports['http_port']}"
        self.env["WS_URL"] = (
            f"ws://127.0.0.1:{ports['ws_port']}"
            "/api/ws/login?newAccount=false"
        )

    def write_state(self, name: str, value: str) -> None:
        (self.docker_state / name).write_text(value + "\n", encoding="ascii")

    def read_state(self, name: str) -> str:
        return (self.docker_state / name).read_text(encoding="ascii").strip()

    def create_legacy_layout(self, remove_runtime: bool = False) -> None:
        if remove_runtime:
            shutil.rmtree(self.runtime)
        legacy_data = self.storage / "data"
        legacy_home = self.storage / "wechat-home"
        legacy_data.mkdir()
        legacy_home.mkdir()
        (legacy_data / "legacy-data.marker").write_text(
            "legacy data\n", encoding="utf-8"
        )
        (legacy_home / "legacy-home.marker").write_text(
            "legacy home\n", encoding="utf-8"
        )
        os.chmod(legacy_data, 0o735)
        os.chmod(legacy_home, 0o715)

    def run(
        self,
        script: str,
        *arguments: str,
        timeout: int = 20,
        trace: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        command = ["bash"]
        if trace:
            command.append("-x")
        command.extend([str(SCRIPTS / script), *arguments])
        return subprocess.run(
            command,
            cwd=REPO_ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )

    def popen(self, script: str, *arguments: str) -> subprocess.Popen[str]:
        process = subprocess.Popen(
            ["bash", str(SCRIPTS / script), *arguments],
            cwd=REPO_ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.background.append(process)
        return process

    def archive_dirs(self) -> list[Path]:
        if not self.archive.exists():
            return []
        return sorted(path for path in self.archive.iterdir() if path.is_dir())

    def mutation_lines(self) -> list[str]:
        return [
            line
            for line in self.mutation_log.read_text(encoding="utf-8").splitlines()
            if line
        ]

    def audit_lines(self) -> list[str]:
        return [
            line
            for line in self.audit_log.read_text(encoding="utf-8").splitlines()
            if line
        ]

    def assert_no_sensitive_text(
        self, testcase: unittest.TestCase, *values: str
    ) -> None:
        combined = "\n".join(values)
        for sensitive in (self.token, self.account, self.chat):
            testcase.assertNotIn(sensitive, combined)

    def close(self) -> None:
        for process in self.background:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
        if self.server is not None and self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait(timeout=3)
        shutil.rmtree(self.root, ignore_errors=True)


@unittest.skipUnless(
    os.name == "posix"
    and shutil.which("bash")
    and shutil.which("flock")
    and shutil.which("curl"),
    "forced-QR integration tests require a Linux userland",
)
class ForcedQrRuntimeTests(unittest.TestCase):
    fixture: RuntimeFixture

    def setUp(self) -> None:
        self.fixture = RuntimeFixture(self._testMethodName)

    def tearDown(self) -> None:
        self.fixture.close()

    def assert_failed(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def assert_succeeded(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_dry_run_changes_nothing(self) -> None:
        before = tree_digest(self.fixture.storage)
        start = self.fixture.run("start-qr-login.sh", "--dry-run")
        self.assert_succeeded(start)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertEqual(self.fixture.mutation_lines(), [])
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")

        stop = self.fixture.run("stop-qr-runtime.sh", "--dry-run")
        self.assert_succeeded(stop)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertEqual(self.fixture.mutation_lines(), [])

    def test_success_archives_atomically_preserves_permissions_and_gates_worker(
        self,
    ) -> None:
        old_inode = self.fixture.runtime.stat().st_ino
        token_hash = hashlib.sha256(
            (self.fixture.secrets / "auth-token").read_bytes()
        ).hexdigest()
        result = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(result)

        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        archived = archives[0]
        self.assertEqual(archived.stat().st_ino, old_inode)
        self.assertTrue((archived / "data" / "old-state.marker").is_file())
        self.assertFalse((self.fixture.runtime / "data" / "old-state.marker").exists())
        self.assertEqual(stat.S_IMODE(self.fixture.runtime.stat().st_mode), 0o751)
        self.assertEqual(
            stat.S_IMODE((self.fixture.runtime / "data").stat().st_mode), 0o731
        )
        self.assertEqual(
            stat.S_IMODE(
                (self.fixture.runtime / "wechat-home").stat().st_mode
            ),
            0o711,
        )

        manifest = json.loads(
            (archived / "manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["result"], "success")
        self.assertTrue(manifest["startedAtUtc"])
        self.assertTrue(manifest["endedAtUtc"])
        self.assertEqual(
            manifest["originalPermissions"]["runtime"]["mode"], "751"
        )
        self.assertEqual(
            manifest["originalPermissions"]["data"]["mode"], "731"
        )
        self.assertEqual(
            manifest["originalPermissions"]["wechatHome"]["mode"], "711"
        )
        self.assertEqual(
            hashlib.sha256(
                (self.fixture.secrets / "auth-token").read_bytes()
            ).hexdigest(),
            token_hash,
        )
        for archived_file in archived.rglob("*"):
            if archived_file.is_file():
                self.assertNotIn(self.fixture.token.encode(), archived_file.read_bytes())

        self.assertEqual(
            self.fixture.mutation_lines(),
            [
                "gateway worker stop",
                "agent container stop",
                "agent container remove",
                "agent container start",
                "gateway worker start",
            ],
        )
        audit = self.fixture.audit_lines()
        self.assertLess(
            audit.index("GET /api/messages/<redacted>"),
            audit.index("gateway worker start"),
        )
        self.assertIn("扫描二维码", result.stdout)
        self.assertIn("QR login new-account=true", self.fixture.login_log.read_text())
        self.fixture.assert_no_sensitive_text(
            self,
            result.stdout,
            (archived / "manifest.json").read_text(encoding="utf-8"),
            self.fixture.audit_log.read_text(encoding="utf-8"),
            self.fixture.mutation_log.read_text(encoding="utf-8"),
        )

        traced_status = self.fixture.run("status.sh", trace=True)
        self.assert_succeeded(traced_status)
        self.fixture.assert_no_sensitive_text(self, traced_status.stdout)

    def test_first_start_archives_the_complete_legacy_layout(self) -> None:
        self.fixture.create_legacy_layout(remove_runtime=True)
        token_file = self.fixture.secrets / "auth-token"
        token_before = (
            token_file.stat().st_ino,
            stat.S_IMODE(token_file.stat().st_mode),
            hashlib.sha256(token_file.read_bytes()).hexdigest(),
        )

        result = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(result)
        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        archived = archives[0]
        self.assertTrue((archived / "data" / "legacy-data.marker").is_file())
        self.assertTrue(
            (archived / "wechat-home" / "legacy-home.marker").is_file()
        )
        self.assertFalse((self.fixture.storage / "data").exists())
        self.assertFalse((self.fixture.storage / "wechat-home").exists())
        self.assertEqual(
            stat.S_IMODE((self.fixture.runtime / "data").stat().st_mode),
            0o735,
        )
        self.assertEqual(
            stat.S_IMODE(
                (self.fixture.runtime / "wechat-home").stat().st_mode
            ),
            0o715,
        )
        self.assertEqual(
            (
                token_file.stat().st_ino,
                stat.S_IMODE(token_file.stat().st_mode),
                hashlib.sha256(token_file.read_bytes()).hexdigest(),
            ),
            token_before,
        )
        for archived_file in archived.rglob("*"):
            if archived_file.is_file():
                self.assertNotIn(
                    self.fixture.token.encode(), archived_file.read_bytes()
                )

    def test_legacy_home_move_failure_rolls_data_back_without_split(self) -> None:
        self.fixture.create_legacy_layout(remove_runtime=True)
        fail_marker = self.fixture.root / "legacy-home-move.failed"
        self.fixture.env.update(
            {
                "MOCK_SUDO_FAIL_MV_SOURCE": str(
                    self.fixture.storage / "wechat-home"
                ),
                "MOCK_SUDO_FAIL_MV_MARKER": str(fail_marker),
            }
        )

        first = self.fixture.run("start-qr-login.sh")
        self.assert_failed(first)
        self.assertTrue(fail_marker.is_file())
        self.assertTrue(
            (
                self.fixture.storage
                / "data"
                / "legacy-data.marker"
            ).is_file()
        )
        self.assertTrue(
            (
                self.fixture.storage
                / "wechat-home"
                / "legacy-home.marker"
            ).is_file()
        )
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertNotIn(
            "gateway worker start", self.fixture.mutation_lines()
        )

        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        failed_archive = archives[0]
        self.assertFalse((failed_archive / "data").exists())
        self.assertFalse((failed_archive / "wechat-home").exists())
        failed_manifest = json.loads(
            (failed_archive / "manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(failed_manifest["result"], "failed")
        failed_digest = tree_digest(failed_archive)

        second = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(second)
        archives = self.fixture.archive_dirs()
        self.assertEqual(
            [path.name for path in archives],
            ["20300102T030405Z", "20300102T030405Z-01"],
        )
        self.assertEqual(tree_digest(failed_archive), failed_digest)
        self.assertTrue(
            (archives[1] / "data" / "legacy-data.marker").is_file()
        )
        self.assertTrue(
            (
                archives[1]
                / "wechat-home"
                / "legacy-home.marker"
            ).is_file()
        )
        self.assertFalse((self.fixture.storage / "data").exists())
        self.assertFalse((self.fixture.storage / "wechat-home").exists())
        self.assertEqual(
            self.fixture.mutation_lines().count("gateway worker start"), 1
        )

    def test_mixed_runtime_and_legacy_layout_fails_before_any_change(self) -> None:
        self.fixture.create_legacy_layout()
        before = tree_digest(self.fixture.storage)
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed(result)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertEqual(self.fixture.mutation_lines(), [])
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        self.assertIn("legacy", result.stdout.lower())
        self.assertIn("runtime", result.stdout.lower())

    def test_runtime_child_symlink_fails_before_any_mutation(self) -> None:
        for index, child_name in enumerate(("data", "wechat-home")):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{child_name}"
                )
            with self.subTest(child=child_name):
                child_path = self.fixture.runtime / child_name
                shutil.rmtree(child_path)
                external = self.fixture.root / f"external-{child_name}"
                external.mkdir()
                (external / "outside.marker").write_text(
                    "must remain unchanged\n", encoding="utf-8"
                )
                os.symlink(external, child_path, target_is_directory=True)
                storage_before = tree_digest(self.fixture.storage)
                external_before = tree_digest(external)

                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertEqual(
                    tree_digest(self.fixture.storage), storage_before
                )
                self.assertEqual(tree_digest(external), external_before)
                self.assertTrue(child_path.is_symlink())
                self.assertEqual(child_path.resolve(), external.resolve())
                self.assertEqual(self.fixture.mutation_lines(), [])
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "1"
                )
                self.assertEqual(
                    self.fixture.read_state("agent_running"), "1"
                )
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertFalse(
                    (self.fixture.root / "qr-runtime.lock").exists()
                )

    def test_login_failure_keeps_worker_stopped_and_finalizes_manifest(self) -> None:
        self.fixture.env["MOCK_LOGIN_MODE"] = "fail"
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed(result)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertNotIn("gateway worker start", self.fixture.mutation_lines())
        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        manifest = json.loads(
            (archives[0] / "manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["result"], "failed")
        self.assertTrue(manifest["endedAtUtc"])
        self.assertIn("Archive preserved at:", result.stdout)
        self.fixture.assert_no_sensitive_text(
            self,
            result.stdout,
            (archives[0] / "manifest.json").read_text(encoding="utf-8"),
            self.fixture.audit_log.read_text(encoding="utf-8"),
            self.fixture.mutation_log.read_text(encoding="utf-8"),
        )

    def test_missing_or_unstable_wechat_process_fails_before_login(self) -> None:
        self.fixture.write_state("wechat_mode", "missing")
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed(result)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.login_log.read_text(), "")
        self.assertNotIn("gateway worker start", self.fixture.mutation_lines())
        self.assertIn("/usr/bin/wechat did not remain stable", result.stdout)

    def test_logged_in_with_unreadable_chats_never_starts_worker(self) -> None:
        self.fixture.set_scenario(chats_mode="error")
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed(result)
        self.assertEqual(self.fixture.auth_state.read_text().strip(), "logged_in")
        self.assertIn("GET /api/chats", self.fixture.audit_lines())
        self.assertNotIn("gateway worker start", self.fixture.mutation_lines())
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")

    def test_chats_error_envelope_with_data_never_starts_worker(self) -> None:
        self.fixture.set_scenario(chats_mode="api_error")
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed(result)
        self.assertEqual(self.fixture.auth_state.read_text().strip(), "logged_in")
        self.assertIn("GET /api/chats", self.fixture.audit_lines())
        self.assertNotIn(
            "GET /api/messages/<redacted>", self.fixture.audit_lines()
        )
        self.assertNotIn("gateway worker start", self.fixture.mutation_lines())
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")

    def test_empty_chats_and_unreadable_messages_both_block_worker(self) -> None:
        cases: list[dict[str, object]] = [
            {"chats_mode": "empty"},
            {"messages_mode": "error"},
            {"messages_mode": "api_error"},
        ]
        for index, scenario in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{index}"
                )
            with self.subTest(scenario=scenario):
                self.fixture.set_scenario(**scenario)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertNotIn(
                    "gateway worker start", self.fixture.mutation_lines()
                )
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "0"
                )

    def test_process_identity_change_after_api_validation_blocks_worker(
        self,
    ) -> None:
        self.fixture.write_state("wechat_mode", "change_on_final_check")
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed(result)
        self.assertIn(
            "GET /api/messages/<redacted>", self.fixture.audit_lines()
        )
        self.assertNotIn("gateway worker start", self.fixture.mutation_lines())
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")

    def test_repeated_start_never_overwrites_an_archive(self) -> None:
        first = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(first)
        first_archive = self.fixture.archive_dirs()[0]
        first_digest = tree_digest(first_archive)

        (self.fixture.runtime / "data" / "second-state.marker").write_text(
            "second runtime state\n", encoding="utf-8"
        )
        self.fixture.auth_state.write_text("logged_out\n", encoding="ascii")
        second = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(second)
        archives = self.fixture.archive_dirs()
        self.assertEqual(
            [path.name for path in archives],
            ["20300102T030405Z", "20300102T030405Z-01"],
        )
        self.assertEqual(tree_digest(first_archive), first_digest)
        self.assertTrue(
            (archives[1] / "data" / "second-state.marker").is_file()
        )

    def test_concurrent_start_allows_only_one_lock_holder(self) -> None:
        self.fixture.env["MOCK_LOGIN_MODE"] = "block"
        first = self.fixture.popen("start-qr-login.sh")
        deadline = time.monotonic() + 8
        while (
            time.monotonic() < deadline
            and not self.fixture.login_pause_file.exists()
        ):
            if first.poll() is not None:
                self.fail(first.stdout.read() if first.stdout else "first start exited")
            time.sleep(0.05)
        self.assertTrue(self.fixture.login_pause_file.exists())
        mutations_before = list(self.fixture.mutation_lines())
        archives_before = list(self.fixture.archive_dirs())

        second = self.fixture.run("start-qr-login.sh")
        self.assert_failed(second)
        self.assertIn("Another QR runtime operation", second.stdout)
        self.assertEqual(self.fixture.mutation_lines(), mutations_before)
        self.assertEqual(self.fixture.archive_dirs(), archives_before)

        self.fixture.login_continue_file.touch()
        output, _ = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, output)
        self.assertEqual(len(self.fixture.archive_dirs()), 1)
        self.assertEqual(
            self.fixture.mutation_lines().count("gateway worker start"), 1
        )

    def test_login_force_qr_rejects_dirty_runtime_and_passes_new_account(self) -> None:
        success = self.fixture.run("login.sh", "--force-qr")
        self.assert_succeeded(success)
        self.assertIn("扫描二维码", success.stdout)
        self.assertIn(
            "QR login new-account=true", self.fixture.login_log.read_text()
        )
        self.fixture.assert_no_sensitive_text(self, success.stdout)

        self.fixture.audit_log.write_text("", encoding="utf-8")
        self.fixture.login_log.write_text("", encoding="utf-8")
        dirty = self.fixture.run("login.sh", "--force-qr")
        self.assert_failed(dirty)
        self.assertIn(
            "runtime is not clean; use start-qr-login.sh", dirty.stdout
        )
        audit = self.fixture.audit_log.read_text(encoding="utf-8")
        self.assertNotIn("POST /api/status/login", audit)
        self.assertNotIn("logout", audit.lower())
        self.assertEqual(self.fixture.login_log.read_text(), "")

    def test_status_requires_process_auth_and_readable_chats(self) -> None:
        self.fixture.auth_state.write_text("logged_in\n", encoding="ascii")
        self.fixture.set_scenario(chats_mode="error")
        false_logged_in = self.fixture.run("status.sh")
        self.assert_failed(false_logged_in)
        self.assertIn("Auth:\n  logged_in", false_logged_in.stdout)
        self.assertIn("Message API:\n  unavailable", false_logged_in.stdout)
        self.fixture.assert_no_sensitive_text(self, false_logged_in.stdout)

        self.fixture.set_scenario(chats_mode="ok")
        healthy = self.fixture.run("status.sh")
        self.assert_succeeded(healthy)
        for heading in (
            "Container:",
            "Agent Server:",
            "WeChat Process:",
            "Auth:",
            "QR Runtime Mode:",
            "Message API:",
            "Gateway WeChat Worker:",
        ):
            self.assertIn(heading, healthy.stdout)
        self.fixture.assert_no_sensitive_text(self, healthy.stdout)

        self.fixture.write_state("wechat_mode", "missing")
        missing_process = self.fixture.run("status.sh")
        self.assert_failed(missing_process)
        self.assertIn("/usr/bin/wechat is not running", missing_process.stdout)

    def test_gateway_compose_ps_error_is_not_reported_as_stopped_or_success(
        self,
    ) -> None:
        self.fixture.auth_state.write_text("logged_in\n", encoding="ascii")
        self.fixture.write_state("gateway_ps_error", "1")
        status_result = self.fixture.run("status.sh")
        self.assert_failed(status_result)
        self.assertNotIn(
            "Gateway WeChat Worker:\n  stopped", status_result.stdout
        )

        stop_result = self.fixture.run("stop-qr-runtime.sh")
        self.assert_failed(stop_result)
        self.assertNotIn(
            "Gateway WeChat Worker:\n  stopped", stop_result.stdout
        )

    def test_agent_compose_ps_error_does_not_make_stop_succeed(self) -> None:
        self.fixture.write_state("agent_ps_error", "1")
        result = self.fixture.run("stop-qr-runtime.sh")
        self.assert_failed(result)
        self.assertNotIn("Container:\n  stopped", result.stdout)

    def test_stop_preserves_runtime_token_and_all_archives(self) -> None:
        old_archive = self.fixture.archive / "historical-session"
        old_archive.mkdir(parents=True)
        (old_archive / "preserved.marker").write_text(
            "preserve me\n", encoding="utf-8"
        )
        before = tree_digest(self.fixture.storage)
        result = self.fixture.run("stop-qr-runtime.sh")
        self.assert_succeeded(result)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertEqual(
            self.fixture.mutation_lines(),
            ["gateway worker stop", "agent container stop"],
        )
        self.assertNotIn("remove", self.fixture.mutation_log.read_text())
        self.assertNotIn("down", self.fixture.mutation_log.read_text())

        repeated = self.fixture.run("stop-qr-runtime.sh")
        self.assert_succeeded(repeated)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertIn("Runtime:\n  preserved", repeated.stdout)
        self.assertIn("Token:\n  preserved", repeated.stdout)
        self.assertIn("Session Archives:\n  preserved", repeated.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
