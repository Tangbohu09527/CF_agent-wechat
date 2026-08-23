#!/usr/bin/env python3
"""Isolated integration tests for the forced-QR production lifecycle."""

from __future__ import annotations

import hashlib
import json
import os
import shlex
import shutil
import socket
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
SENSITIVE_AGENT_ENV_PREFIX = "agent-env-fixture-sensitive-"
SENSITIVE_GATEWAY_ENV_PREFIX = "gateway-env-fixture-sensitive-"


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


def metadata_without_contents(path: Path) -> tuple[int, int, int, int, int, int]:
    metadata = path.lstat()
    return (
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_mtime_ns,
    )


class RuntimeFixture:
    def __init__(self, name: str) -> None:
        fixture_label = hashlib.sha256(name.encode("utf-8")).hexdigest()[:12]
        self.root = Path(tempfile.mkdtemp(prefix=f"cf-qr-{fixture_label}-"))
        self.storage = self.root / "storage"
        self.runtime = self.storage / "runtime"
        self.archive = self.storage / "session-archive"
        self.secrets = self.storage / "secrets"
        self.gateway_dir = self.root / "gateway"
        self.gateway_deploy = self.gateway_dir / "deploy"
        self.agent_compose = self.root / "agent-compose.yaml"
        self.agent_env = self.root / "agent.env"
        self.gateway_compose = self.gateway_dir / "docker-compose.prod.yml"
        self.gateway_env = self.gateway_dir / ".env"
        self.fake_bin = self.root / "bin"
        self.gateway_heartbeat = (
            self.gateway_deploy / "check-wechat-worker-heartbeat"
        )
        self.gateway_contract = (
            self.gateway_deploy / "wechat-runtime-contract.json"
        )
        self.docker_state = self.root / "docker-state"
        self.docker_socket_path = self.root / "docker.sock"
        self.docker_socket: socket.socket | None = None
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

        self.token = hashlib.sha256(
            f"{SENSITIVE_TOKEN_PREFIX}{name}".encode()
        ).hexdigest()
        self.account = f"{SENSITIVE_ACCOUNT_PREFIX}{name}"
        self.chat = f"{SENSITIVE_CHAT_PREFIX}{name}#/id"
        proxy_label = hashlib.sha256(name.encode("utf-8")).hexdigest()[:16]
        self.agent_env_sentinel = (
            f"{SENSITIVE_AGENT_ENV_PREFIX}{proxy_label}"
        )
        self.gateway_env_sentinel = f"{SENSITIVE_GATEWAY_ENV_PREFIX}{name}"
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
        os.chmod(self.runtime, 0o700)
        os.chmod(self.runtime / "data", 0o700)
        os.chmod(self.runtime / "wechat-home", 0o700)
        self.archive.mkdir()
        os.chmod(self.archive, 0o700)

        self.secrets.mkdir()
        os.chmod(self.secrets, 0o700)
        token_file = self.secrets / "auth-token"
        token_file.write_text(self.token + "\n", encoding="utf-8")
        os.chmod(token_file, 0o600)

        self.gateway_deploy.mkdir(parents=True)
        current_uid = os.getuid()
        current_gid = os.getgid()
        self.agent_compose.write_text("services: {}\n", encoding="utf-8")
        self.agent_env.write_text(
            "\n".join(
                (
                    "COMPOSE_PROJECT_NAME=cf-agent-wechat",
                    "AGENT_WECHAT_IMAGE=ghcr.io/example/agent-wechat@sha256:"
                    + ("0" * 64),
                    "AGENT_WECHAT_CONTAINER_NAME=agent-wechat-fixture",
                    f"CF_AGENT_WECHAT_STORAGE_ROOT={self.storage}",
                    f"CF_AGENT_WECHAT_RUNTIME_ROOT={self.runtime}",
                    f"CF_AGENT_WECHAT_ARCHIVE_ROOT={self.archive}",
                    "AGENT_WECHAT_BIND_IP=127.0.0.1",
                    "AGENT_WECHAT_PORT=6174",
                    f"CF_AGENT_WECHAT_RUNTIME_UID={current_uid}",
                    f"CF_AGENT_WECHAT_RUNTIME_GID={current_gid}",
                    "CF_AGENT_WECHAT_RUNTIME_MODE=700",
                    f"CF_AGENT_WECHAT_MANAGEMENT_GID={current_gid}",
                    "CF_AGENT_WECHAT_MIN_FREE_BYTES=1",
                    "CF_AGENT_WECHAT_MIN_FREE_PERCENT=0",
                    "CF_AGENT_WECHAT_MIN_FREE_INODES=1",
                    "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES=200000",
                    "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES=21474836480",
                    f"PROXY=http://{self.agent_env_sentinel}.invalid:8080",
                    "RUST_LOG=info",
                    "",
                )
            ),
            encoding="utf-8",
        )
        os.chmod(self.agent_env, 0o600)
        self.gateway_compose.write_text("services: {}\n", encoding="utf-8")
        self.gateway_env.write_text(
            "\n".join(
                (
                    "CF_AGENT_WECHAT_TOKEN_FILE="
                    "/run/secrets/cf-agent-wechat-auth-token",
                    f"FIXTURE_SENTINEL={self.gateway_env_sentinel}",
                    "",
                )
            ),
            encoding="utf-8",
        )
        os.chmod(self.gateway_env, 0o600)
        self.gateway_heartbeat.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            'case "$(cat "$MOCK_DOCKER_STATE_DIR/worker_heartbeat")" in\n'
            "  healthy) exit 0 ;;\n"
            '  sensitive) cat "$MOCK_AGENT_TOKEN_FILE"; exit 0 ;;\n'
            "  timeout) sleep 30; exit 1 ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        os.chmod(self.gateway_heartbeat, 0o755)
        checker_sha256 = hashlib.sha256(
            self.gateway_heartbeat.read_bytes()
        ).hexdigest()
        self.gateway_contract.write_text(
            json.dumps(
                {
                    "contractVersion": "1",
                    "producer": {
                        "repository": "Tangbohu09527/CF_agent-gateway",
                        "checkerSha256": checker_sha256,
                    },
                    "agent": {
                        "networkAlias": "cf-agent-wechat",
                        "port": 6174,
                        "tokenAuthority": {
                            "hostPath": str(token_file),
                            "ownership": "root:root",
                            "mode": "0600",
                        },
                    },
                    "gateway": {
                        "service": "worker",
                        "composeProject": "cf-agent-gateway",
                        "checker": str(self.gateway_heartbeat),
                        "checkerInterfaceVersion": 1,
                        "heartbeatMaxAgeSeconds": 30,
                        "requiresDockerHealth": True,
                        "requiresSuccessfulPoll": True,
                        "requiresLoggedIn": True,
                        "silentOutput": True,
                        "credential": {
                            "type": "file",
                            "environmentVariable": (
                                "CF_AGENT_WECHAT_TOKEN_FILE"
                            ),
                            "workerPath": (
                                "/run/secrets/"
                                "cf-agent-wechat-auth-token"
                            ),
                            "readOnly": True,
                            "forbiddenEnvironmentVariable": (
                                "CF_AGENT_WECHAT_TOKEN"
                            ),
                        },
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        os.chmod(self.gateway_contract, 0o600)
        self.fake_bin.mkdir()
        self.docker_state.mkdir()
        self.home.mkdir()
        for name, value in {
            "gateway_running": "1",
            "worker_heartbeat": "healthy",
            "agent_exists": "1",
            "agent_running": "1",
            "wechat_mode": "stable",
            "wechat_calls": "0",
            "wechat_launcher_resolves": "1",
            "wechat_launcher_real": "/opt/wechat/wechat",
            "wechat_proc_exe": "/opt/wechat/wechat",
        }.items():
            (self.docker_state / name).write_text(value + "\n", encoding="ascii")

        if not hasattr(socket, "AF_UNIX"):
            raise RuntimeError("lifecycle fixture requires Unix sockets")
        self.docker_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.docker_socket.bind(os.fspath(self.docker_socket_path))
        os.chmod(self.docker_socket_path, 0o600)

        helper_names = {
            "docker": "mock_docker.sh",
            "sudo": "mock_sudo.sh",
            "date": "mock_date.sh",
            "systemctl": "mock_runtime_systemctl.sh",
            "df": "mock_df.sh",
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
        requirements_sha256 = hashlib.sha256(requirements).hexdigest()
        (venv_dir / ".cf-agent-wechat-requirements").write_text(
            "\n".join(
                (
                    "schema=3",
                    f"requirements_sha256={requirements_sha256}",
                    "python_implementation=cpython",
                    "python_version=fixture",
                    "python_gil=enabled",
                    f"records_sha256={'d' * 64}",
                    f"tree_sha256={'e' * 64}",
                    "",
                )
            ),
            encoding="ascii",
        )
        os.chmod(venv_dir / ".cf-agent-wechat-requirements", 0o600)

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
                "CF_AGENT_WECHAT_TESTING": "1",
                "CF_AGENT_WECHAT_TEST_ROOT": str(self.root),
                "TMPDIR": str(self.root),
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
                "CF_AGENT_WECHAT_ENV_FILE": str(self.agent_env),
                "CF_AGENT_GATEWAY_COMPOSE_FILE": str(self.gateway_compose),
                "CF_AGENT_GATEWAY_PROJECT_DIR": str(self.gateway_dir),
                "CF_AGENT_GATEWAY_ENV_FILE": str(self.gateway_env),
                "CF_AGENT_WECHAT_RUNTIME_UID": current_uid,
                "CF_AGENT_WECHAT_RUNTIME_GID": current_gid,
                "CF_AGENT_WECHAT_RUNTIME_MODE": "700",
                "CF_AGENT_WECHAT_MANAGEMENT_GID": current_gid,
                "CF_AGENT_WECHAT_DOCKER_BIN": "docker",
                "CF_AGENT_WECHAT_SYSTEMCTL_BIN": "systemctl",
                "CF_AGENT_WECHAT_DOCKER_SOCKET_PATH": str(self.docker_socket_path),
                "CF_AGENT_WECHAT_DF_BIN": "df",
                "MOCK_APPROVED_DOCKER_SOCKET": str(self.docker_socket_path),
                "SERVER_READY_TIMEOUT": "3",
                "WECHAT_READY_TIMEOUT": "3",
                "CF_AGENT_GATEWAY_HEARTBEAT_COMMAND": str(self.gateway_heartbeat),
                "WECHAT_STABLE_SECONDS": "1",
                "POST_LOGIN_READY_TIMEOUT": "3",
                "RUNTIME_POLL_INTERVAL": "1",
                "DOCKER_COMMAND_TIMEOUT": "3",
                "COMPOSE_COMMAND_TIMEOUT": "3",
                "WORKER_READY_TIMEOUT": "3",
                "WORKER_STABLE_SECONDS": "0",
                "WORKER_HEARTBEAT_TIMEOUT": "1",
                "HTTP_CONNECT_TIMEOUT": "1",
                "HTTP_TIMEOUT": "2",
                "LOGIN_TIMEOUT_MS": "2000",
                "LOGIN_CONFIRM_RETRIES": "2",
                "LOGIN_CONFIRM_INTERVAL": "0",
                "MOCK_DOCKER_STATE_DIR": str(self.docker_state),
                "MOCK_DOCKER_LOG": str(self.audit_log),
                "MOCK_DOCKER_MUTATION_LOG": str(self.mutation_log),
                "MOCK_AGENT_COMPOSE_FILE": str(self.agent_compose),
                "MOCK_AGENT_ENV_FILE": str(self.agent_env),
                "MOCK_AGENT_PROJECT_DIR": str(REPO_ROOT),
                "MOCK_GATEWAY_COMPOSE_FILE": str(self.gateway_compose),
                "MOCK_GATEWAY_ENV_FILE": str(self.gateway_env),
                "MOCK_GATEWAY_PROJECT_DIR": str(self.gateway_dir),
                "MOCK_AGENT_TOKEN_FILE": str(self.secrets / "auth-token"),
                "MOCK_APPROVED_AGENT_IMAGE":
                    "ghcr.io/example/agent-wechat@sha256:" + ("0" * 64),
                "MOCK_APPROVED_AGENT_CONTAINER": "agent-wechat-fixture",
                "MOCK_APPROVED_AGENT_PROJECT": "cf-agent-wechat",
                "MOCK_APPROVED_STORAGE_ROOT": str(self.storage),
                "MOCK_APPROVED_RUNTIME_ROOT": str(self.runtime),
                "MOCK_APPROVED_ARCHIVE_ROOT": str(self.archive),
                "MOCK_APPROVED_TOKEN_FILE": str(
                    self.secrets / "auth-token"
                ),
                "MOCK_APPROVED_BIND_IP": "127.0.0.1",
                "MOCK_APPROVED_PORT": "6174",
                "MOCK_APPROVED_PROXY":
                    f"http://{self.agent_env_sentinel}.invalid:8080",
                "MOCK_APPROVED_RUST_LOG": "info",
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

    def replace_agent_env(self, key: str, value: str) -> None:
        prefix = key + "="
        lines = self.agent_env.read_text(encoding="utf-8").splitlines()
        matches = [index for index, line in enumerate(lines) if line.startswith(prefix)]
        if len(matches) != 1:
            raise AssertionError(f"fixture env key is not unique: {key}")
        lines[matches[0]] = prefix + value
        self.agent_env.write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )
        os.chmod(self.agent_env, 0o600)

    def write_gateway_file_credential(self, worker_path: str) -> None:
        self.gateway_env.write_text(
            f"CF_AGENT_WECHAT_TOKEN_FILE={worker_path}\n",
            encoding="utf-8",
        )
        os.chmod(self.gateway_env, 0o600)

    def write_gateway_plaintext_credential(self, token: str) -> None:
        self.gateway_env.write_text(
            f"CF_AGENT_WECHAT_TOKEN={token}\n", encoding="utf-8"
        )
        os.chmod(self.gateway_env, 0o600)

    def simulate_docker_daemon_restart(self) -> None:
        if self.read_state("agent_exists") == "1":
            self.write_state("agent_running", "0")

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
        os.chmod(legacy_data, 0o700)
        os.chmod(legacy_home, 0o700)

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
        command = ["script", "-qefc", shlex.join(command), "/dev/null"]
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
        command = ["bash", str(SCRIPTS / script), *arguments]
        process = subprocess.Popen(
            ["script", "-qefc", shlex.join(command), "/dev/null"],
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
        for sensitive in (
            self.token,
            self.account,
            self.chat,
            self.agent_env_sentinel,
            self.gateway_env_sentinel,
        ):
            testcase.assertNotIn(sensitive, combined)

    def assert_tree_has_no_sensitive_text(
        self, testcase: unittest.TestCase, root: Path
    ) -> None:
        sensitive_values = (
            self.token,
            self.account,
            self.chat,
            self.agent_env_sentinel,
            self.gateway_env_sentinel,
        )
        for path in root.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            content = path.read_bytes()
            for sensitive in sensitive_values:
                testcase.assertNotIn(sensitive.encode(), content)

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
        if self.docker_socket is not None:
            self.docker_socket.close()
            self.docker_socket = None
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
        self.assert_result_is_redacted(result)

    def assert_succeeded(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_result_is_redacted(result)

    def assert_result_is_redacted(
        self, result: subprocess.CompletedProcess[str]
    ) -> None:
        self.fixture.assert_no_sensitive_text(
            self,
            result.stdout,
            self.fixture.audit_log.read_text(encoding="utf-8"),
            self.fixture.mutation_log.read_text(encoding="utf-8"),
            self.fixture.login_log.read_text(encoding="utf-8"),
        )

    def assert_failed_lifecycle_cleanup(
        self,
        result: subprocess.CompletedProcess[str],
        expected_phase: str,
        *,
        stop_result: str = "succeeded",
        remove_result: str = "succeeded",
        worker_started: bool = False,
    ) -> dict[str, object]:
        self.assert_failed(result)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.read_state("agent_exists"), "0")
        self.assertEqual(self.fixture.read_state("agent_running"), "0")
        if worker_started:
            self.assertIn(
                "gateway worker start", self.fixture.mutation_lines()
            )
        else:
            self.assertNotIn(
                "gateway worker start", self.fixture.mutation_lines()
            )
        self.assertTrue(
            (self.fixture.runtime / "data" / "agent-runtime.log").is_file()
        )
        self.assertTrue((self.fixture.runtime / "wechat-home").is_dir())

        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        archived = archives[0]
        self.assertTrue((archived / "data" / "old-state.marker").is_file())
        manifest_path = archived / "manifest.json"
        self.assertTrue(manifest_path.is_file())
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertNotIn("sensitiveData", manifest)
        self.assertEqual(manifest["result"], "failed")
        self.assertEqual(manifest["archiveResult"], "succeeded")
        self.assertEqual(manifest["phase"], expected_phase)
        self.assertTrue(manifest["endedAtUtc"])
        self.assertEqual(
            manifest["failureCleanup"],
            {
                "attempted": True,
                "agentContainerStop": stop_result,
                "agentContainerRemove": remove_result,
                "volumesRemoved": False,
            },
        )

        self.fixture.simulate_docker_daemon_restart()
        self.assertEqual(self.fixture.read_state("agent_exists"), "0")
        self.assertEqual(self.fixture.read_state("agent_running"), "0")
        self.fixture.assert_no_sensitive_text(
            self,
            result.stdout,
            manifest_path.read_text(encoding="utf-8"),
            self.fixture.audit_log.read_text(encoding="utf-8"),
            self.fixture.mutation_log.read_text(encoding="utf-8"),
            self.fixture.login_log.read_text(encoding="utf-8"),
        )
        self.fixture.assert_tree_has_no_sensitive_text(self, archived)
        self.fixture.assert_tree_has_no_sensitive_text(
            self, self.fixture.runtime
        )
        return manifest

    def assert_failed_worker_release_preserves_agent(
        self,
        result: subprocess.CompletedProcess[str],
        expected_phase: str,
        *,
        worker_started: bool,
    ) -> dict[str, object]:
        self.assert_failed(result)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.read_state("agent_exists"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        if worker_started:
            self.assertIn(
                "gateway worker start", self.fixture.mutation_lines()
            )
        else:
            self.assertNotIn(
                "gateway worker start", self.fixture.mutation_lines()
            )
        self.assertTrue(
            (self.fixture.runtime / "data" / "agent-runtime.log").is_file()
        )
        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        manifest_path = archives[0] / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(manifest["result"], "failed")
        self.assertEqual(manifest["archiveResult"], "succeeded")
        self.assertEqual(manifest["phase"], expected_phase)
        self.assertEqual(
            manifest["failureCleanup"],
            {
                "attempted": False,
                "agentContainerStop": "not_attempted",
                "agentContainerRemove": "not_attempted",
                "volumesRemoved": False,
            },
        )
        self.fixture.assert_no_sensitive_text(
            self,
            result.stdout,
            manifest_path.read_text(encoding="utf-8"),
            self.fixture.audit_log.read_text(encoding="utf-8"),
            self.fixture.mutation_log.read_text(encoding="utf-8"),
            self.fixture.login_log.read_text(encoding="utf-8"),
        )
        self.fixture.assert_tree_has_no_sensitive_text(self, archives[0])
        self.fixture.assert_tree_has_no_sensitive_text(
            self, self.fixture.runtime
        )
        return manifest

    def test_dry_run_changes_nothing(self) -> None:
        before = tree_digest(self.fixture.storage)
        agent_env_before = metadata_without_contents(self.fixture.agent_env)
        gateway_env_before = metadata_without_contents(
            self.fixture.gateway_env
        )
        start = self.fixture.run("start-qr-login.sh", "--dry-run")
        self.assert_succeeded(start)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertEqual(
            metadata_without_contents(self.fixture.agent_env),
            agent_env_before,
        )
        self.assertEqual(
            metadata_without_contents(self.fixture.gateway_env),
            gateway_env_before,
        )
        self.assertEqual(self.fixture.mutation_lines(), [])
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        self.assertIn(
            "agent compose env-file verified",
            self.fixture.audit_lines(),
        )
        self.assertIn(
            "gateway compose env-file verified",
            self.fixture.audit_lines(),
        )

        agent_env_calls_before_stop = self.fixture.audit_lines().count(
            "agent compose env-file verified"
        )
        stop = self.fixture.run("stop-qr-runtime.sh", "--dry-run")
        self.assert_succeeded(stop)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertEqual(
            metadata_without_contents(self.fixture.agent_env),
            agent_env_before,
        )
        self.assertEqual(
            metadata_without_contents(self.fixture.gateway_env),
            gateway_env_before,
        )
        self.assertEqual(self.fixture.mutation_lines(), [])
        self.assertGreater(
            self.fixture.audit_lines().count(
                "agent compose env-file verified"
            ),
            agent_env_calls_before_stop,
        )

    def test_real_start_rejects_non_tty_before_any_mutation(self) -> None:
        before = tree_digest(self.fixture.storage)
        result = subprocess.run(
            ["bash", str(SCRIPTS / "start-qr-login.sh")],
            cwd=REPO_ROOT,
            env=self.fixture.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("interactive controlled terminal", result.stdout)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertEqual(self.fixture.mutation_lines(), [])

    def test_success_archives_atomically_preserves_permissions_and_gates_worker(
        self,
    ) -> None:
        self.assertNotEqual(
            self.fixture.read_state("wechat_launcher_real"),
            "/usr/bin/wechat",
        )
        self.assertEqual(
            self.fixture.read_state("wechat_proc_exe"),
            self.fixture.read_state("wechat_launcher_real"),
        )
        old_inode = self.fixture.runtime.stat().st_ino
        token_hash = hashlib.sha256(
            (self.fixture.secrets / "auth-token").read_bytes()
        ).hexdigest()
        result = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(result)
        self.assertIn("Archive capacity:", result.stdout)
        self.assertIn("Archives: 0", result.stdout)

        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        archived = archives[0]
        self.assertEqual(archived.stat().st_ino, old_inode)
        self.assertTrue((archived / "data" / "old-state.marker").is_file())
        self.assertFalse((self.fixture.runtime / "data" / "old-state.marker").exists())
        self.assertEqual(stat.S_IMODE(self.fixture.runtime.stat().st_mode), 0o700)
        self.assertEqual(
            stat.S_IMODE((self.fixture.runtime / "data").stat().st_mode), 0o700
        )
        self.assertEqual(
            stat.S_IMODE(
                (self.fixture.runtime / "wechat-home").stat().st_mode
            ),
            0o700,
        )

        manifest = json.loads(
            (archived / "manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["result"], "success")
        self.assertEqual(manifest["archiveResult"], "succeeded")
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(manifest["sourcePaths"], [str(self.fixture.runtime)])
        self.assertEqual(
            manifest["imageReference"],
            "ghcr.io/example/agent-wechat@sha256:" + ("0" * 64),
        )
        self.assertEqual(manifest["imageDigest"], "sha256:" + ("0" * 64))
        self.assertEqual(
            manifest["manifestData"],
            {
                "tokenIncluded": False,
                "accountIdentifiersIncluded": False,
                "chatIdentifiersIncluded": False,
                "messageContentIncluded": False,
            },
        )
        self.assertEqual(
            manifest["archivePayloadClassification"],
            {
                "mayContainWechatSession": True,
                "mayContainAccountIdentifiers": True,
                "mayContainChatIdentifiers": True,
                "mayContainMessageMetadata": True,
                "mayContainMessageContent": True,
                "containsIndependentAgentApiToken": False,
                "accessClassification": "restricted",
                "productionSessionRecoveryAllowed": False,
            },
        )
        self.assertNotIn("sensitiveData", manifest)
        self.assertTrue(manifest["startedAtUtc"])
        self.assertTrue(manifest["endedAtUtc"])
        self.assertEqual(
            manifest["originalPermissions"]["runtime"]["mode"], "700"
        )
        self.assertEqual(
            manifest["originalPermissions"]["data"]["mode"], "700"
        )
        self.assertEqual(
            manifest["originalPermissions"]["wechatHome"]["mode"], "700"
        )
        protection = manifest["archiveProtection"]
        self.assertEqual(protection["archiveRootMode"], "700")
        self.assertEqual(protection["archiveTopLevelMode"], "700")
        self.assertFalse(protection["automaticUploadAllowed"])
        self.assertFalse(protection["automaticDeletionAllowed"])
        self.assertEqual(
            manifest["failureCleanup"],
            {
                "attempted": False,
                "agentContainerStop": "not_attempted",
                "agentContainerRemove": "not_attempted",
                "volumesRemoved": False,
            },
        )
        self.assertEqual(
            hashlib.sha256(
                (self.fixture.secrets / "auth-token").read_bytes()
            ).hexdigest(),
            token_hash,
        )
        self.fixture.assert_tree_has_no_sensitive_text(self, archived)

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
        self.assertEqual(self.fixture.read_state("agent_exists"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        self.assertTrue(
            (self.fixture.runtime / "data" / "agent-runtime.log").is_file()
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
        self.assertIn("WeChat Process:\n  running", traced_status.stdout)
        self.fixture.assert_no_sensitive_text(self, traced_status.stdout)

    def test_existing_logged_in_state_still_runs_fresh_qr(self) -> None:
        self.fixture.auth_state.write_text("logged_in\n", encoding="ascii")
        result = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(result)
        self.assertIn("扫描二维码", result.stdout)
        self.assertIn(
            "QR login new-account=true",
            self.fixture.login_log.read_text(encoding="utf-8"),
        )
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")

    def test_repeated_daemon_initialization_does_not_restore_agent(self) -> None:
        result = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(result)
        self.fixture.simulate_docker_daemon_restart()
        self.assertEqual(self.fixture.read_state("agent_exists"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "0")
        self.fixture.simulate_docker_daemon_restart()
        self.assertEqual(self.fixture.read_state("agent_running"), "0")

    def test_live_restore_is_rejected_before_lifecycle_mutation(self) -> None:
        self.fixture.write_state("live_restore", "true")
        before = tree_digest(self.fixture.storage)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed(result)
        self.assertIn("live-restore", result.stdout)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertEqual(self.fixture.mutation_lines(), [])

    def test_each_start_rejects_startup_and_rendered_policy_drift(self) -> None:
        cases = (
            (
                "enabled-unit",
                {"agent_unit_enabled": "1"},
                "must not be enabled",
            ),
            (
                "enablement-query-error",
                {"agent_unit_enablement_error": "1"},
                "enablement could not be determined safely",
            ),
            (
                "direct-definition",
                {"indirect_agent_unit_enabled": "1"},
                "could automatically start agent-wechat",
            ),
            (
                "definition-inspection-failure",
                {
                    "indirect_agent_unit_enabled": "1",
                    "unreadable_unit_definition": "1",
                },
                "definitions could not be inspected",
            ),
            (
                "default-timer-target",
                {"generic_timer_enabled": "1"},
                "enabled systemd timer could automatically start",
            ),
            (
                "explicit-timer-target",
                {"explicit_timer_enabled": "1"},
                "enabled systemd timer could automatically start",
            ),
            (
                "explicit-path-target",
                {"explicit_path_enabled": "1"},
                "enabled systemd path unit could automatically start",
            ),
            (
                "default-path-target",
                {"default_path_enabled": "1"},
                "enabled systemd path unit could automatically start",
            ),
            (
                "explicit-socket-target",
                {"explicit_socket_enabled": "1"},
                "enabled systemd socket could automatically start",
            ),
            (
                "default-socket-target",
                {"default_socket_enabled": "1"},
                "enabled systemd socket could automatically start",
            ),
            (
                "target-wants",
                {"target_wants_enabled": "1"},
                "enabled systemd target could automatically start",
            ),
            (
                "target-requires",
                {"target_requires_enabled": "1"},
                "enabled systemd target could automatically start",
            ),
            (
                "malformed-target",
                {"malformed_activation_target": "1"},
                "target is missing or ambiguous",
            ),
            (
                "unsupported-target-type",
                {"unknown_activation_target": "1"},
                "target must resolve to a service unit",
            ),
            (
                "activation-inspection-failure",
                {"activation_show_failure": "1"},
                "target could not be resolved safely",
            ),
            (
                "templated-socket",
                {"templated_socket_enabled": "1"},
                "unsupported templated activation",
            ),
            (
                "rendered-restart",
                {"rendered_restart": "unless-stopped"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-project",
                {"rendered_project": "wrong-project"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-container",
                {"rendered_container": "wrong-container"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-image",
                {
                    "rendered_image":
                        "ghcr.io/example/agent-wechat@sha256:" + ("2" * 64)
                },
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-proxy",
                {"rendered_proxy": "http://attacker.invalid:8080"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-rust-log",
                {"rendered_rust": "trace"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-entrypoint",
                {"rendered_entrypoint": "1"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-command",
                {"rendered_command": "1"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-user",
                {"rendered_user": "1"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-working-dir",
                {"rendered_working_dir": "1"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-post-start-hook",
                {"rendered_post_start": "1"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-pre-stop-hook",
                {"rendered_pre_stop": "1"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-stop-grace-period",
                {"rendered_stop_grace_period": "5s"},
                "Rendered agent-wechat Compose",
            ),
            (
                "rendered-create-host-path",
                {"rendered_create_host_path": "true"},
                "Rendered agent-wechat Compose",
            ),
        )
        for index, (label, state, expected_error) in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{label}"
                )
            with self.subTest(case=label):
                for name, value in state.items():
                    self.fixture.write_state(name, value)
                before = tree_digest(self.fixture.storage)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertIn(expected_error, result.stdout)
                self.assertEqual(tree_digest(self.fixture.storage), before)
                self.assertEqual(self.fixture.mutation_lines(), [])
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "1"
                )
                self.assertNotIn("扫描二维码", result.stdout)

    def test_exact_actual_container_attestation_rejects_drift(self) -> None:
        cases = (
            ("restart", "actual_restart", "unless-stopped"),
            (
                "image",
                "actual_image",
                "ghcr.io/example/agent-wechat@sha256:" + ("1" * 64),
            ),
            ("project", "actual_project", "wrong-project"),
            ("container", "actual_container", "wrong-container"),
            (
                "container-image-id",
                "actual_container_image_id",
                "sha256:" + ("c" * 64),
            ),
            (
                "approved-repo-digest",
                "actual_repo_digest",
                "ghcr.io/example/agent-wechat@sha256:" + ("d" * 64),
            ),
            ("environment", "actual_extra_environment", "1"),
            ("published-port", "actual_extra_port", "1"),
            ("network-alias", "actual_network_alias", "attacker-alias"),
            ("restart-retry", "actual_restart_retry", "1"),
            ("entrypoint", "actual_entrypoint", '["/bin/sh"]'),
            ("command", "actual_command", '["sleep","infinity"]'),
            ("user", "actual_user", "root"),
            ("working-dir", "actual_working_dir", "/tmp"),
            ("stop-signal", "actual_stop_signal", "SIGKILL"),
            ("stop-timeout", "actual_stop_timeout", "5"),
            ("healthcheck-test", "actual_healthcheck_test", '["NONE"]'),
            ("healthcheck-interval", "actual_healthcheck_interval", "1"),
            ("data-bind-source", "actual_data_bind_source", "/tmp/attacker"),
            ("token-bind-mode", "actual_token_bind_mode", "rw"),
            ("extra-bind", "actual_extra_bind", "1"),
            ("network-mode", "actual_network_mode", "bridge"),
            ("extra-network", "actual_extra_network", "1"),
            ("log-driver", "actual_log_driver", "local"),
            ("log-options", "actual_log_max_size", "200m"),
            ("data-mount-source", "actual_data_mount_source", "/tmp/attacker"),
            ("token-mount-writable", "actual_token_mount_rw", "true"),
            ("mount-propagation", "actual_propagation", "shared"),
            ("bind-ip", "actual_bind_ip", "0.0.0.0"),
            ("host-port", "actual_port", "9999"),
            ("proxy", "actual_proxy", "http://attacker.invalid:8080"),
            ("rust-log", "actual_rust", "trace"),
            ("privileged", "actual_privileged", "true"),
            ("cap-add", "actual_cap_add", "[]"),
            ("security-opt", "actual_security_opt", "[]"),
            ("devices", "actual_devices", '[{"PathOnHost":"/dev/null"}]'),
            ("device-requests", "actual_device_requests", '[{}]'),
            ("pid-mode", "actual_pid_mode", "host"),
            ("ipc-mode", "actual_ipc_mode", "host"),
            ("uts-mode", "actual_uts_mode", "host"),
            ("userns-mode", "actual_userns_mode", "host"),
            ("cgroupns-mode", "actual_cgroupns_mode", "host"),
            ("readonly-rootfs", "actual_readonly_rootfs", "true"),
            ("auto-remove", "actual_auto_remove", "true"),
        )
        for index, (label, state_name, value) in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{label}"
                )
            with self.subTest(case=label):
                self.fixture.write_state(state_name, value)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed_lifecycle_cleanup(
                    result, "start_agent_container"
                )
                self.assertIn(
                    "exact production runtime contract", result.stdout
                )
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertNotIn("扫描二维码", result.stdout)

    def test_raw_inspect_token_is_rejected_without_transport_leak(self) -> None:
        cases = (
            "actual_inspect_contains_token",
            "image_inspect_contains_token",
        )
        for index, state_name in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{state_name}"
                )
            with self.subTest(source=state_name):
                docker_transport = self.fixture.root / "docker-transport.bin"
                python_transport = self.fixture.root / "python-transport.bin"
                python_wrapper = self.fixture.root / "python-transport-wrapper"
                python_wrapper.write_text(
                    "#!/bin/sh\n"
                    f"printf 'argv\\0' >> {shlex.quote(str(python_transport))}\n"
                    f"printf '%s\\0' \"$@\" >> {shlex.quote(str(python_transport))}\n"
                    f"printf 'environment\\0' >> {shlex.quote(str(python_transport))}\n"
                    f"/usr/bin/env -0 >> {shlex.quote(str(python_transport))}\n"
                    f"exec {shlex.quote(sys.executable)} \"$@\"\n",
                    encoding="utf-8",
                )
                os.chmod(python_wrapper, 0o755)
                self.fixture.env["PYTHON_BIN"] = str(python_wrapper)
                self.fixture.env["MOCK_DOCKER_TRANSPORT_LOG"] = str(
                    docker_transport
                )
                self.fixture.write_state(state_name, "1")

                result = self.fixture.run("start-qr-login.sh", trace=True)

                self.assert_failed_lifecycle_cleanup(
                    result, "start_agent_container"
                )
                self.assertIn(
                    "exact production runtime contract", result.stdout
                )
                self.assertNotIn("扫描二维码", result.stdout)
                self.assertTrue(docker_transport.is_file())
                self.assertTrue(python_transport.is_file())
                self.assertNotIn(
                    self.fixture.token.encode(), docker_transport.read_bytes()
                )
                self.assertNotIn(
                    self.fixture.token.encode(), python_transport.read_bytes()
                )
                self.fixture.assert_no_sensitive_text(
                    self,
                    result.stdout,
                    self.fixture.audit_log.read_text(encoding="utf-8"),
                    self.fixture.mutation_log.read_text(encoding="utf-8"),
                    self.fixture.login_log.read_text(encoding="utf-8"),
                )

    def test_host_compose_overrides_cannot_escape_approved_env(self) -> None:
        hostile = {
            "AGENT_WECHAT_IMAGE":
                "attacker.invalid/image@sha256:" + ("f" * 64),
            "COMPOSE_PROJECT_NAME": "attacker-project",
            "AGENT_WECHAT_CONTAINER_NAME": "attacker-container",
            "PROXY": "http://attacker.invalid:8080",
            "RUST_LOG": "trace",
            "CF_AGENT_WECHAT_STORAGE_ROOT": "/attacker/storage",
            "CF_AGENT_WECHAT_RUNTIME_ROOT": "/attacker/storage/runtime",
            "CF_AGENT_WECHAT_ARCHIVE_ROOT": "/attacker/storage/archive",
        }
        self.fixture.env.update(hostile)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_succeeded(result)
        audit = "\n".join(self.fixture.audit_lines())
        self.assertIn("agent compose clean environment verified", audit)
        self.assertIn("agent compose invocation verified", audit)
        combined = "\n".join(
            (
                result.stdout,
                audit,
                self.fixture.mutation_log.read_text(encoding="utf-8"),
            )
        )
        for value in hostile.values():
            self.assertNotIn(value, combined)
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")

    def test_compose_path_swap_cannot_change_bound_runtime(self) -> None:
        approved_compose = self.fixture.agent_compose.read_text(
            encoding="utf-8"
        )
        self.fixture.write_state("mutate_agent_compose_after_config", "1")

        result = self.fixture.run("start-qr-login.sh")

        self.assert_succeeded(result)
        self.assertEqual(
            self.fixture.read_state("agent_compose_mutated"), "1"
        )
        self.assertIn(
            "attacker.invalid/latest",
            self.fixture.agent_compose.read_text(encoding="utf-8"),
        )
        self.assertEqual(
            (
                self.fixture.docker_state / "approved-agent-compose"
            ).read_text(encoding="utf-8"),
            approved_compose,
        )
        audit = "\n".join(self.fixture.audit_lines())
        self.assertIn("agent compose invocation verified", audit)
        self.assertNotIn("attacker.invalid", result.stdout + audit)
        self.assertIn(
            "agent container start", self.fixture.mutation_lines()
        )
        self.assertIn(
            "gateway worker start", self.fixture.mutation_lines()
        )
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")

    def test_runtime_permission_drift_is_rejected_before_mutation(self) -> None:
        cases = (
            ("runtime-mode", self.fixture.runtime, 0o755, None),
            ("data-writable", self.fixture.runtime / "data", 0o770, None),
            (
                "home-mode",
                self.fixture.runtime / "wechat-home",
                0o755,
                None,
            ),
            (
                "owner-contract",
                None,
                None,
                ("CF_AGENT_WECHAT_RUNTIME_UID", str(os.getuid() + 1)),
            ),
        )
        for index, (label, path, mode, env_change) in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{label}"
                )
                if label == "runtime-mode":
                    path = self.fixture.runtime
                elif label == "data-writable":
                    path = self.fixture.runtime / "data"
                elif label == "home-mode":
                    path = self.fixture.runtime / "wechat-home"
            with self.subTest(case=label):
                if path is not None and mode is not None:
                    os.chmod(path, mode)
                if env_change is not None:
                    self.fixture.replace_agent_env(*env_change)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertIn("must exactly match approved UID:GID:mode", result.stdout)
                self.assertEqual(self.fixture.mutation_lines(), [])
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "1"
                )

    def test_archive_capacity_and_inode_gates_stop_worker_before_qr(self) -> None:
        cases = (
            ("space", "df_available_blocks", "0"),
            ("inode", "df_available_inodes", "0"),
        )
        for index, (label, state_name, value) in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{label}"
                )
            with self.subTest(case=label):
                self.fixture.write_state(state_name, value)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertIn("below the approved free space or inode", result.stdout)
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "0"
                )
                self.assertEqual(self.fixture.read_state("agent_exists"), "1")
                self.assertEqual(self.fixture.read_state("agent_running"), "1")
                self.assertTrue(self.fixture.mutation_lines())
                self.assertEqual(
                    set(self.fixture.mutation_lines()),
                    {"gateway worker stop"},
                )
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertNotIn("扫描二维码", result.stdout)

    def test_archive_free_percent_gate_fails_with_sufficient_bytes(
        self,
    ) -> None:
        self.fixture.replace_agent_env(
            "CF_AGENT_WECHAT_MIN_FREE_BYTES", "1024"
        )
        self.fixture.replace_agent_env(
            "CF_AGENT_WECHAT_MIN_FREE_PERCENT", "10"
        )
        self.fixture.write_state("df_total_blocks", "1000000")
        self.fixture.write_state("df_available_blocks", "2")

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed(result)
        self.assertIn("below the approved free space or inode", result.stdout)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.read_state("agent_exists"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        self.assertEqual(
            set(self.fixture.mutation_lines()), {"gateway worker stop"}
        )
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertEqual(self.fixture.login_log.read_text(), "")
        self.assertNotIn("扫描二维码", result.stdout)

    def test_archive_capacity_df_hard_timeout_fails_before_archive_or_qr(
        self,
    ) -> None:
        self.fixture.env["CF_AGENT_WECHAT_TEST_ARCHIVE_TOOL_TIMEOUT"] = "1"
        self.fixture.write_state("df_sleep", "10")
        started = time.monotonic()

        result = self.fixture.run("start-qr-login.sh", timeout=10)

        self.assert_failed(result)
        self.assertLess(time.monotonic() - started, 6)
        self.assertIn("free space could not be measured", result.stdout)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.read_state("agent_exists"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        self.assertEqual(
            set(self.fixture.mutation_lines()),
            {"gateway worker stop"},
        )
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertEqual(self.fixture.login_log.read_text(), "")
        self.assertNotIn("扫描二维码", result.stdout)

    def test_gateway_contract_gate_stops_worker_and_fails_closed(self) -> None:
        cases = (
            "credential-path-mismatch",
            "plaintext-credential",
            "checker-missing",
            "version-incompatible",
        )
        for index, mode in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{mode}"
                )

            with self.subTest(case=mode):
                sensitive_value = ""
                if mode == "credential-path-mismatch":
                    self.fixture.write_gateway_file_credential(
                        "/run/secrets/unapproved-token"
                    )
                elif mode == "plaintext-credential":
                    sensitive_value = hashlib.sha256(
                        b"different-gateway-token"
                    ).hexdigest()
                    self.fixture.write_gateway_plaintext_credential(
                        sensitive_value
                    )
                elif mode == "checker-missing":
                    self.fixture.gateway_heartbeat.unlink()
                else:
                    contract = json.loads(
                        self.fixture.gateway_contract.read_text(
                            encoding="utf-8"
                        )
                    )
                    contract["contractVersion"] = "999"
                    self.fixture.gateway_contract.write_text(
                        json.dumps(contract) + "\n", encoding="utf-8"
                    )
                    os.chmod(self.fixture.gateway_contract, 0o600)
                before = tree_digest(self.fixture.storage)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertEqual(tree_digest(self.fixture.storage), before)
                self.assertEqual(
                    self.fixture.mutation_lines(),
                    ["gateway worker stop", "gateway worker stop"],
                )
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "0"
                )
                self.assertNotIn("扫描二维码", result.stdout)
                if sensitive_value:
                    self.assertNotIn(
                        sensitive_value,
                        result.stdout
                        + self.fixture.audit_log.read_text(encoding="utf-8")
                        + self.fixture.mutation_log.read_text(encoding="utf-8"),
                    )

    def test_gateway_contract_is_revalidated_before_worker_release(self) -> None:
        self.fixture.env["MOCK_LOGIN_MODE"] = "block"
        process = self.fixture.popen("start-qr-login.sh")
        deadline = time.monotonic() + 8
        while (
            time.monotonic() < deadline
            and not self.fixture.login_pause_file.exists()
        ):
            if process.poll() is not None:
                self.fail(
                    process.stdout.read()
                    if process.stdout
                    else "start exited before QR confirmation"
                )
            time.sleep(0.05)
        self.assertTrue(self.fixture.login_pause_file.exists())
        drifted_credential = "/run/secrets/drifted-after-preflight"
        self.fixture.write_gateway_file_credential(drifted_credential)
        self.fixture.login_continue_file.touch()
        output, _ = process.communicate(timeout=12)
        result = subprocess.CompletedProcess(
            process.args, process.returncode, output
        )
        self.assert_failed_worker_release_preserves_agent(
            result, "revalidate_gateway_contract", worker_started=False
        )
        self.assertNotIn("gateway worker start", self.fixture.mutation_lines())
        self.assertNotIn(
            drifted_credential,
            result.stdout
            + self.fixture.audit_log.read_text(encoding="utf-8")
            + self.fixture.mutation_log.read_text(encoding="utf-8"),
        )

    def test_live_gateway_worker_credential_drift_revokes_worker(self) -> None:
        self.fixture.write_state(
            "gateway_actual_token_source", "/tmp/unapproved-token"
        )
        result = self.fixture.run("start-qr-login.sh")
        manifest = self.assert_failed_worker_release_preserves_agent(
            result, "start_gateway_worker", worker_started=True
        )
        self.assertEqual(manifest["archiveResult"], "succeeded")
        self.assertIn("file credential contract", result.stdout)
        self.fixture.assert_no_sensitive_text(self, result.stdout)

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
            0o700,
        )
        self.assertEqual(
            stat.S_IMODE(
                (self.fixture.runtime / "wechat-home").stat().st_mode
            ),
            0o700,
        )
        self.assertEqual(
            (
                token_file.stat().st_ino,
                stat.S_IMODE(token_file.stat().st_mode),
                hashlib.sha256(token_file.read_bytes()).hexdigest(),
            ),
            token_before,
        )
        self.fixture.assert_tree_has_no_sensitive_text(self, archived)

    def test_legacy_home_move_failure_rolls_data_back_without_split(self) -> None:
        self.fixture.create_legacy_layout(remove_runtime=True)
        outside = self.fixture.root / "outside-legacy-home"
        outside.write_text("must not be followed", encoding="utf-8")
        unsafe_link = (
            self.fixture.storage / "wechat-home" / "unsafe-runtime-link"
        )
        unsafe_link.symlink_to(outside)

        first = self.fixture.run("start-qr-login.sh")
        self.assert_failed(first)
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
        self.assertTrue(unsafe_link.is_symlink())
        self.assertEqual(outside.read_text(encoding="utf-8"), "must not be followed")
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertNotIn(
            "gateway worker start", self.fixture.mutation_lines()
        )
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertIn(
            "Legacy WeChat HOME could not be moved into Archive staging",
            first.stdout,
        )

        unsafe_link.unlink()
        second = self.fixture.run("start-qr-login.sh")
        self.assert_succeeded(second)
        archives = self.fixture.archive_dirs()
        self.assertEqual(
            [path.name for path in archives],
            ["20300102T030405Z"],
        )
        self.assertTrue(
            (archives[0] / "data" / "legacy-data.marker").is_file()
        )
        self.assertTrue(
            (
                archives[0]
                / "wechat-home"
                / "legacy-home.marker"
            ).is_file()
        )
        self.assertFalse((self.fixture.storage / "data").exists())
        self.assertFalse((self.fixture.storage / "wechat-home").exists())
        self.assertEqual(
            self.fixture.mutation_lines().count("gateway worker start"), 1
        )
        self.assertEqual(outside.read_text(encoding="utf-8"), "must not be followed")

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

    def test_gateway_env_missing_or_symlink_fails_before_any_mutation(
        self,
    ) -> None:
        cases = (
            ("start-qr-login.sh", "missing"),
            ("start-qr-login.sh", "symlink"),
            ("stop-qr-runtime.sh", "missing"),
            ("stop-qr-runtime.sh", "symlink"),
        )
        for index, (script_name, mode) in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{script_name}-{mode}"
                )
            with self.subTest(script=script_name, mode=mode):
                self.fixture.gateway_env.unlink()
                external_target: Path | None = None
                target_before: tuple[int, int, int, int, int, int] | None = None
                if mode == "symlink":
                    external_target = (
                        self.fixture.root / "external-gateway.env"
                    )
                    external_target.write_text(
                        self.fixture.gateway_env_sentinel + "\n",
                        encoding="utf-8",
                    )
                    os.chmod(external_target, 0o640)
                    target_before = metadata_without_contents(external_target)
                    os.symlink(external_target, self.fixture.gateway_env)

                storage_before = tree_digest(self.fixture.storage)
                gateway_dir_before = metadata_without_contents(
                    self.fixture.gateway_dir
                )
                result = self.fixture.run(script_name)
                self.assert_failed(result)

                self.assertEqual(
                    tree_digest(self.fixture.storage), storage_before
                )
                self.assertEqual(
                    metadata_without_contents(self.fixture.gateway_dir),
                    gateway_dir_before,
                )
                if mode == "missing":
                    self.assertFalse(self.fixture.gateway_env.exists())
                else:
                    self.assertIsNotNone(external_target)
                    self.assertIsNotNone(target_before)
                    self.assertTrue(self.fixture.gateway_env.is_symlink())
                    self.assertEqual(
                        self.fixture.gateway_env.resolve(),
                        external_target.resolve(),
                    )
                    self.assertEqual(
                        metadata_without_contents(external_target),
                        target_before,
                    )

                self.assertEqual(self.fixture.mutation_lines(), [])
                self.assertEqual(self.fixture.audit_lines(), [])
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

    def test_agent_env_validation_fails_before_any_mutation(self) -> None:
        cases = tuple(
            (script_name, mode)
            for script_name in (
                "start-qr-login.sh",
                "stop-qr-runtime.sh",
            )
            for mode in ("missing", "symlink", "relative", "directory")
        )
        for index, (script_name, mode) in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{script_name}-{mode}"
                )
            with self.subTest(script=script_name, mode=mode):
                external_target: Path | None = None
                target_before: tuple[int, int, int, int, int, int] | None = None
                env_path_before: (
                    tuple[int, int, int, int, int, int] | None
                ) = None

                if mode in ("missing", "symlink", "directory"):
                    self.fixture.agent_env.unlink()
                if mode == "symlink":
                    external_target = self.fixture.root / "external-agent.env"
                    external_target.write_text(
                        f"AGENT_ENV_FIXTURE="
                        f"{self.fixture.agent_env_sentinel}\n",
                        encoding="utf-8",
                    )
                    os.chmod(external_target, 0o640)
                    target_before = metadata_without_contents(external_target)
                    os.symlink(external_target, self.fixture.agent_env)
                elif mode == "relative":
                    self.fixture.env["CF_AGENT_WECHAT_ENV_FILE"] = (
                        "relative-agent.env"
                    )
                elif mode == "directory":
                    self.fixture.agent_env.mkdir()

                if mode != "missing":
                    env_path_before = metadata_without_contents(
                        self.fixture.agent_env
                    )
                storage_before = tree_digest(self.fixture.storage)
                result = self.fixture.run(script_name)
                self.assert_failed(result)

                self.assertIn(
                    "agent-wechat environment file",
                    result.stdout.lower(),
                )
                self.assertEqual(
                    tree_digest(self.fixture.storage),
                    storage_before,
                )
                if mode == "missing":
                    self.assertFalse(self.fixture.agent_env.exists())
                else:
                    self.assertIsNotNone(env_path_before)
                    self.assertEqual(
                        metadata_without_contents(self.fixture.agent_env),
                        env_path_before,
                    )
                if mode == "symlink":
                    self.assertIsNotNone(external_target)
                    self.assertIsNotNone(target_before)
                    self.assertTrue(self.fixture.agent_env.is_symlink())
                    self.assertEqual(
                        metadata_without_contents(external_target),
                        target_before,
                    )

                self.assertEqual(self.fixture.mutation_lines(), [])
                self.assertEqual(self.fixture.audit_lines(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertEqual(
                    self.fixture.read_state("gateway_running"),
                    "1",
                )
                self.assertEqual(
                    self.fixture.read_state("agent_running"),
                    "1",
                )
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertFalse(
                    (self.fixture.root / "qr-runtime.lock").exists()
                )

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

    def test_storage_symlink_ancestor_fails_before_any_mutation(self) -> None:
        real_storage = self.fixture.root / "storage-real"
        self.fixture.storage.rename(real_storage)
        os.symlink(
            real_storage,
            self.fixture.storage,
            target_is_directory=True,
        )
        storage_before = tree_digest(real_storage)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed(result)
        self.assertIn("symbolic link ancestors", result.stdout)
        self.assertEqual(tree_digest(real_storage), storage_before)
        self.assertTrue(self.fixture.storage.is_symlink())
        self.assertEqual(self.fixture.storage.resolve(), real_storage.resolve())
        self.assertEqual(self.fixture.mutation_lines(), [])
        self.assertEqual(self.fixture.audit_lines(), [])
        self.assertEqual(self.fixture.login_log.read_text(), "")
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        self.assertFalse((self.fixture.root / "qr-runtime.lock").exists())

    def test_login_failure_keeps_worker_stopped_and_finalizes_manifest(self) -> None:
        self.fixture.env["MOCK_LOGIN_MODE"] = "fail"
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed_lifecycle_cleanup(result, "force_qr_login")
        self.assertEqual(
            self.fixture.mutation_lines(),
            [
                "gateway worker stop",
                "agent container stop",
                "agent container remove",
                "agent container start",
                "gateway worker stop",
                "agent container stop",
                "agent container remove",
            ],
        )
        self.assertIn("Archive preserved at:", result.stdout)
        self.assertIn(
            "Failed-flow cleanup stopped and removed the agent-wechat container",
            result.stdout,
        )

    def test_agent_server_failure_cleans_and_worker_failure_preserves_agent(
        self,
    ) -> None:
        cases = (
            (
                "wait_agent_server",
                {"health_status": 503},
                {},
                "Agent Server did not become reachable",
            ),
            (
                "start_gateway_worker",
                {},
                {"gateway_start_error": "1"},
                "Gateway wechat-worker start command failed",
            ),
        )
        for index, (phase, scenario, state, expected_error) in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{phase}"
                )
            with self.subTest(phase=phase):
                self.fixture.set_scenario(**scenario)
                for name, value in state.items():
                    self.fixture.write_state(name, value)
                result = self.fixture.run("start-qr-login.sh")
                if phase == "start_gateway_worker":
                    self.assert_failed_worker_release_preserves_agent(
                        result, phase, worker_started=False
                    )
                else:
                    self.assert_failed_lifecycle_cleanup(result, phase)
                self.assertIn(expected_error, result.stdout)

    def test_cleanup_error_preserves_original_failure_and_manifest_phase(
        self,
    ) -> None:
        self.fixture.env["MOCK_LOGIN_MODE"] = "fail"
        self.fixture.write_state("agent_cleanup_stop_error", "1")
        result = self.fixture.run("start-qr-login.sh", trace=True)

        self.assertEqual(result.returncode, 1, result.stdout)
        manifest = self.assert_failed_lifecycle_cleanup(
            result,
            "force_qr_login",
            stop_result="failed",
        )
        self.assertEqual(manifest["phase"], "force_qr_login")
        self.assertIn(
            "Fresh QR WebSocket login did not complete.", result.stdout
        )
        self.assertIn(
            "cleanup encountered errors (stop: failed; remove: succeeded)",
            result.stdout,
        )
        self.assertIn(
            "agent container cleanup stop failed",
            self.fixture.audit_lines(),
        )

    def test_cleanup_remove_error_preserves_evidence_and_warns(
        self,
    ) -> None:
        self.fixture.env["MOCK_LOGIN_MODE"] = "fail"
        self.fixture.write_state("agent_cleanup_remove_error", "1")
        result = self.fixture.run("start-qr-login.sh")

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.read_state("agent_exists"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "0")
        self.assertNotIn("gateway worker start", self.fixture.mutation_lines())
        self.assertTrue(
            (self.fixture.runtime / "data" / "agent-runtime.log").is_file()
        )

        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        manifest_path = archives[0] / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["result"], "failed")
        self.assertEqual(manifest["phase"], "force_qr_login")
        self.assertEqual(
            manifest["failureCleanup"],
            {
                "attempted": True,
                "agentContainerStop": "succeeded",
                "agentContainerRemove": "failed",
                "volumesRemoved": False,
            },
        )
        self.assertIn(
            "Fresh QR WebSocket login did not complete.", result.stdout
        )
        self.assertIn(
            "cleanup encountered errors (stop: succeeded; remove: failed)",
            result.stdout,
        )
        self.assertNotIn(
            "cleanup stopped and removed the agent-wechat container",
            result.stdout,
        )
        self.assertIn(
            "agent container cleanup remove failed",
            self.fixture.audit_lines(),
        )
        self.fixture.assert_no_sensitive_text(
            self,
            result.stdout,
            manifest_path.read_text(encoding="utf-8"),
            self.fixture.audit_log.read_text(encoding="utf-8"),
            self.fixture.mutation_log.read_text(encoding="utf-8"),
            self.fixture.login_log.read_text(encoding="utf-8"),
        )
        self.fixture.assert_tree_has_no_sensitive_text(
            self, self.fixture.runtime
        )
        self.fixture.assert_tree_has_no_sensitive_text(self, archives[0])

        self.fixture.simulate_docker_daemon_restart()
        self.assertEqual(self.fixture.read_state("agent_exists"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "0")

    def test_success_manifest_failure_revokes_worker_and_preserves_agent(
        self,
    ) -> None:
        manifest_path = (
            self.fixture.archive / "20300102T030405Z" / "manifest.json"
        )
        self.fixture.env.update(
            {
                "MOCK_SUDO_FAIL_MV_DESTINATION": str(manifest_path),
                "MOCK_SUDO_FAIL_MV_ON_CALL": "2",
                "MOCK_SUDO_MV_COUNT_FILE": str(
                    self.fixture.root / "manifest-mv-count"
                ),
            }
        )
        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed_worker_release_preserves_agent(
            result,
            "complete",
            worker_started=True,
        )
        self.assertIn(
            "Could not finalize the archive manifest.",
            result.stdout,
        )
        self.assertEqual(
            self.fixture.mutation_lines(),
            [
                "gateway worker stop",
                "agent container stop",
                "agent container remove",
                "agent container start",
                "gateway worker start",
                "gateway worker stop",
            ],
        )

    def test_missing_or_unstable_wechat_process_fails_before_login(self) -> None:
        for index, mode in enumerate(("missing", "unstable")):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{mode}"
                )
            with self.subTest(mode=mode):
                self.fixture.write_state("wechat_mode", mode)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed_lifecycle_cleanup(
                    result, "wait_wechat_process"
                )
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertIn(
                    "/usr/bin/wechat did not remain stable", result.stdout
                )

    def test_launcher_and_executable_mismatches_fail_closed(self) -> None:
        cases = (
            {"wechat_launcher_resolves": "0"},
            {"wechat_launcher_real": "opt/wechat/wechat"},
            {
                "wechat_proc_exe": "/opt/wechat/not-wechat",
                "wechat_comm": "wechat",
                "wechat_cmdline": "/usr/bin/wechat --fixture",
            },
        )
        for index, state in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{index}"
                )
            with self.subTest(state=state):
                for name, value in state.items():
                    self.fixture.write_state(name, value)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed_lifecycle_cleanup(
                    result, "wait_wechat_process"
                )
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertIn(
                    "/usr/bin/wechat did not remain stable", result.stdout
                )

    def test_logged_in_with_unreadable_chats_never_starts_worker(self) -> None:
        self.fixture.set_scenario(chats_mode="error")
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed_lifecycle_cleanup(result, "verify_runtime_apis")
        self.assertEqual(self.fixture.auth_state.read_text().strip(), "logged_in")
        self.assertIn("GET /api/chats", self.fixture.audit_lines())

    def test_chats_error_envelope_with_data_never_starts_worker(self) -> None:
        self.fixture.set_scenario(chats_mode="api_error")
        result = self.fixture.run("start-qr-login.sh")
        self.assert_failed_lifecycle_cleanup(result, "verify_runtime_apis")
        self.assertEqual(self.fixture.auth_state.read_text().strip(), "logged_in")
        self.assertIn("GET /api/chats", self.fixture.audit_lines())
        self.assertNotIn(
            "GET /api/messages/<redacted>", self.fixture.audit_lines()
        )

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
                self.assert_failed_lifecycle_cleanup(
                    result, "verify_runtime_apis"
                )

    def test_process_identity_change_after_api_validation_blocks_worker(
        self,
    ) -> None:
        modes = (
            "change_on_final_check",
            "same_pid_new_start_on_final_check",
        )
        for index, mode in enumerate(modes):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{mode}"
                )
            with self.subTest(mode=mode):
                self.fixture.write_state("wechat_mode", mode)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed_lifecycle_cleanup(
                    result, "verify_final_wechat_process"
                )
                self.assertIn(
                    "GET /api/messages/<redacted>",
                    self.fixture.audit_lines(),
                )

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
        for archived in archives:
            self.fixture.assert_tree_has_no_sensitive_text(self, archived)

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
        self.fixture.assert_no_sensitive_text(
            self,
            output,
            self.fixture.audit_log.read_text(encoding="utf-8"),
            self.fixture.mutation_log.read_text(encoding="utf-8"),
            self.fixture.login_log.read_text(encoding="utf-8"),
        )
        self.assertEqual(len(self.fixture.archive_dirs()), 1)
        self.assertEqual(
            self.fixture.mutation_lines().count("gateway worker start"), 1
        )

    def test_login_wrapper_always_runs_the_fresh_lifecycle(self) -> None:
        self.fixture.auth_state.write_text("logged_in\n", encoding="ascii")
        success = self.fixture.run("login.sh")
        self.assert_succeeded(success)
        self.assertIn("compatibility wrapper", success.stdout)
        self.assertIn("扫描二维码", success.stdout)
        self.assertIn(
            "QR login new-account=true", self.fixture.login_log.read_text()
        )
        archives = self.fixture.archive_dirs()
        self.assertEqual(len(archives), 1)
        self.assertTrue((archives[0] / "data" / "old-state.marker").is_file())
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
        self.fixture.assert_no_sensitive_text(self, success.stdout)

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

        self.fixture.write_state("wechat_calls", "0")
        self.fixture.write_state("wechat_mode", "unstable")
        replaced_process = self.fixture.run("status.sh")
        self.assert_failed(replaced_process)
        self.assertIn(
            "WeChat Process:\n  exited_or_replaced",
            replaced_process.stdout,
        )
        self.assertEqual(self.fixture.mutation_lines(), [])

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


    def test_runtime_containing_token_is_never_archived(self) -> None:
        leaked_file = self.fixture.runtime / "data" / "unsafe-token-copy"
        leaked_file.write_text(self.fixture.token, encoding="utf-8")

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed(result)
        self.assertIn("auth-token bytes", result.stdout)
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertTrue(leaked_file.is_file())
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.read_state("agent_exists"), "0")
        self.assertNotIn(
            "gateway worker start", self.fixture.mutation_lines()
        )


    def test_login_start_error_envelopes_block_websocket_and_worker(
        self,
    ) -> None:
        for index, mode in enumerate(
            ("http_error", "api_error", "invalid", "rejected")
        ):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{mode}"
                )
            with self.subTest(mode=mode):
                self.fixture.set_scenario(login_request_mode=mode)
                result = self.fixture.run("start-qr-login.sh")
                manifest = self.assert_failed_lifecycle_cleanup(
                    result, "force_qr_login"
                )
                self.assertEqual(manifest["archiveResult"], "succeeded")
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertIn(
                    "Fresh QR login API", result.stdout
                )

    def test_worker_checker_failure_timeout_and_output_revoke_release(
        self,
    ) -> None:
        for index, mode in enumerate(
            ("unhealthy", "stale", "timeout", "sensitive")
        ):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{mode}"
                )
            with self.subTest(mode=mode):
                self.fixture.write_state("worker_heartbeat", mode)
                result = self.fixture.run(
                    "start-qr-login.sh", timeout=30
                )
                manifest = self.assert_failed_worker_release_preserves_agent(
                    result, "start_gateway_worker", worker_started=True
                )
                self.assertEqual(manifest["archiveResult"], "succeeded")
                self.assertIn("heartbeat", result.stdout.lower())
                self.fixture.assert_no_sensitive_text(self, result.stdout)
                mutations = self.fixture.mutation_lines()
                worker_start = mutations.index("gateway worker start")
                self.assertEqual(
                    mutations[worker_start + 1 :].count(
                        "gateway worker stop"
                    ),
                    2,
                    "post-up failure needs immediate rollback plus EXIT fallback",
                )

    def test_worker_rollback_stop_failure_retries_in_exit_guard(self) -> None:
        self.fixture.write_state("worker_heartbeat", "unhealthy")
        self.fixture.write_state("gateway_cleanup_stop_failures", "1")

        result = self.fixture.run("start-qr-login.sh", timeout=30)

        self.assert_failed_worker_release_preserves_agent(
            result, "start_gateway_worker", worker_started=True
        )
        mutations = self.fixture.mutation_lines()
        worker_start = mutations.index("gateway worker start")
        self.assertEqual(
            mutations[worker_start + 1 :],
            ["gateway worker stop failed", "gateway worker stop"],
        )
        self.assertIn("rollback could not be confirmed", result.stdout)
        self.assertIn("remains stopped", result.stdout)
        self.assertNotIn("state is unknown", result.stdout)

    def test_worker_rollback_unknown_after_both_stop_attempts_fail(
        self,
    ) -> None:
        self.fixture.write_state("worker_heartbeat", "unhealthy")
        self.fixture.write_state("gateway_cleanup_stop_failures", "2")

        result = self.fixture.run("start-qr-login.sh", timeout=30)

        self.assert_failed(result)
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        mutations = self.fixture.mutation_lines()
        worker_start = mutations.index("gateway worker start")
        self.assertEqual(
            mutations[worker_start + 1 :],
            ["gateway worker stop failed", "gateway worker stop failed"],
        )
        self.assertIn("rollback could not be confirmed", result.stdout)
        self.assertIn("state is unknown", result.stdout)
        self.assertNotIn(
            "AI scheduling was not started",
            result.stdout,
        )

    def test_checker_replacement_race_never_executes_or_leaks(
        self,
    ) -> None:
        replacement = self.fixture.root / "replacement-heartbeat-checker"
        marker = self.fixture.root / "replacement-executed"
        replacement.write_text(
            "#!/bin/sh\n"
            + f"printf '%s\\n' {shlex.quote(self.fixture.token)}\n"
            + f"printf replaced > {shlex.quote(str(marker))}\n"
            + "exit 0\n",
            encoding="utf-8",
        )
        replacement.chmod(0o755)
        self.fixture.env[
            "CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT"
        ] = str(replacement)

        result = self.fixture.run("start-qr-login.sh", timeout=30)

        self.assert_failed_worker_release_preserves_agent(
            result, "start_gateway_worker", worker_started=True
        )
        self.assertFalse(marker.exists())
        self.assertNotIn(self.fixture.token, result.stdout)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
