#!/usr/bin/env python3
"""Isolated integration tests for the forced-QR production lifecycle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
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
EXACT_ACTUAL_CONTAINER_ATTESTATION_CASES = (
    ("previously-started-exited", "actual_status", "exited"),
    ("restarting", "actual_restarting", "true"),
    ("paused", "actual_paused", "true"),
    ("dead", "actual_dead", "true"),
    ("oom-killed", "actual_oom_killed", "true"),
    ("nonzero-exit", "actual_exit_code", "1"),
    ("restart-count", "actual_restart_count", "1"),
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
    ("device-requests", "actual_device_requests", "[{}]"),
    ("pid-mode", "actual_pid_mode", "host"),
    ("ipc-mode", "actual_ipc_mode", "host"),
    ("uts-mode", "actual_uts_mode", "host"),
    ("userns-mode", "actual_userns_mode", "host"),
    ("cgroupns-mode", "actual_cgroupns_mode", "host"),
    ("readonly-rootfs", "actual_readonly_rootfs", "true"),
    ("auto-remove", "actual_auto_remove", "true"),
)
LIFECYCLE_SHARD_ESTIMATE_VERSION = 1
LIFECYCLE_SHARD_DEFAULT_SECONDS = 12
LIFECYCLE_SHARD_ATTESTATION_SECONDS = 10
# Fixed estimates are coarse wall-clock budgets based on fixture scenario
# multiplicity and Linux CI watchdog evidence. New tests receive the safe
# default above until an observed duration justifies an explicit override.
LIFECYCLE_SHARD_ESTIMATED_SECONDS = {
    "test_each_start_rejects_startup_and_rendered_policy_drift": 114,
    "test_agent_env_validation_fails_before_any_mutation": 72,
    "test_gateway_contract_gate_stops_worker_and_fails_closed": 60,
    "test_gateway_gate_release_failures_abort_without_worker_start": 56,
    "test_worker_checker_failure_timeout_and_output_revoke_release": 56,
    "test_login_start_error_envelopes_block_websocket_and_worker": 48,
    "test_archive_capacity_rejects_unsafe_df_numbers_before_archive": 40,
    "test_launcher_and_executable_mismatches_fail_closed": 36,
    "test_empty_chats_and_unreadable_messages_both_block_worker": 36,
    "test_gateway_env_missing_or_symlink_fails_before_any_mutation": 32,
    "test_management_numeric_boundaries_fail_before_lifecycle_mutation": 32,
    "test_runtime_permission_drift_is_rejected_before_mutation": 32,
    "test_agent_server_failure_cleans_and_worker_failure_preserves_agent": 28,
    "test_missing_or_unstable_wechat_process_fails_before_login": 24,
    "test_process_identity_change_after_api_validation_blocks_worker": 24,
    "test_repeated_start_never_overwrites_an_archive": 24,
    "test_archive_capacity_and_inode_gates_stop_worker_before_qr": 20,
    "test_archive_capacity_is_rechecked_at_archive_commit_boundary": 20,
    "test_archive_capacity_rejects_available_greater_than_total": 20,
    "test_gateway_gate_begin_failure_and_sensitive_output_fail_closed": 20,
    "test_raw_inspect_token_is_rejected_without_transport_leak": 20,
}
ALLOWED_FLOW_PHASES = frozenset(
    {
        "initializing",
        "validation",
        "stop_gateway_worker",
        "verify_gateway_contract",
        "begin_gateway_generation",
        "archive_preflight",
        "prepare_login_environment",
        "load_auth_token",
        "remove_agent_container",
        "attest_stopped_agent_candidate",
        "guard_worker_before_archive",
        "archive_capacity_commit_gate",
        "gateway_generation_archive_commit_gate",
        "archive_runtime",
        "create_runtime",
        "guard_worker_before_agent_start",
        "start_agent_container",
        "wait_docker_health",
        "wait_agent_server",
        "wait_wechat_process",
        "wait_clean_auth",
        "guard_worker_before_qr",
        "force_qr_login",
        "guard_worker_before_runtime_validation",
        "verify_wechat_process",
        "verify_runtime_apis",
        "guard_worker_before_final_attestation",
        "verify_final_wechat_process",
        "revalidate_final_runtime_contract",
        "guard_worker_before_gateway_release",
        "revalidate_gateway_contract",
        "guard_worker_at_release",
        "create_gateway_worker_candidate",
        "revalidate_gateway_release_bindings",
        "release_gateway_generation",
        "start_gateway_worker",
        "complete",
    }
)
ALLOWED_MUTATION_ACTIONS = frozenset(
    {
        "agent container start attested candidate",
        "gateway worker direct stop",
        "gateway worker stop failed",
        "gateway worker stop",
        "agent container stop",
        "agent container remove",
        "gateway worker start",
        "agent container create stopped",
        "forbidden compose down",
    }
)


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
        self.tmp = self.root / "tmp"
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
        self.gateway_release_gate = (
            self.gateway_deploy / "wechat-runtime-release-gate"
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
        self.gateway_gate_log = self.root / "gateway-gate.log"
        self.login_log = self.root / "login.log"
        self.server: subprocess.Popen[bytes] | None = None
        self.background: list[subprocess.Popen[str]] = []
        self.last_result: subprocess.CompletedProcess[str] | None = None
        self.last_elapsed_seconds = 0.0
        self.diagnostics_emitted = False

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
        self.tmp.mkdir()
        os.chmod(self.tmp, 0o700)
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
            textwrap.dedent(
                """
                #!/usr/bin/python3
                import json
                import os
                import re
                import sys
                import time
                from pathlib import Path

                root = Path(os.environ["MOCK_DOCKER_STATE_DIR"])

                def read_state(name, default=""):
                    path = root / name
                    return path.read_text(encoding="ascii").strip() if path.exists() else default

                try:
                    request = json.load(sys.stdin)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    raise SystemExit(1)
                if set(request) != {
                    "schemaVersion",
                    "generationId",
                    "agentContainerId",
                    "workerContainerId",
                } or request.get("schemaVersion") != 1:
                    raise SystemExit(1)
                identifiers = (
                    request.get("generationId"),
                    request.get("agentContainerId"),
                    request.get("workerContainerId"),
                )
                if any(
                    not isinstance(value, str)
                    or re.fullmatch(r"[0-9a-f]{64}", value) is None
                    for value in identifiers
                ):
                    raise SystemExit(1)
                if (
                    read_state("gateway_gate_state") != "released"
                    or identifiers[0] != read_state("gateway_gate_generation")
                    or identifiers[1] != read_state("gateway_gate_agent_id")
                    or identifiers[2] != read_state("gateway_gate_worker_id")
                    or identifiers[2] != read_state("gateway_compose_id", "c" * 64)
                    or read_state("gateway_running") != "1"
                ):
                    raise SystemExit(1)
                mode = read_state("worker_heartbeat", "healthy")
                if mode == "timeout":
                    time.sleep(30)
                    raise SystemExit(1)
                if mode == "sensitive":
                    sys.stdout.write(
                        Path(os.environ["MOCK_AGENT_TOKEN_FILE"]).read_text(
                            encoding="utf-8"
                        )
                    )
                    raise SystemExit(0)
                if mode == "replace-instance":
                    (root / "gateway_compose_id").write_text(
                        "d" * 64 + "\\n", encoding="ascii"
                    )
                    raise SystemExit(0)
                raise SystemExit(0 if mode == "healthy" else 1)
                """
            ).lstrip(),
            encoding="utf-8",
        )
        os.chmod(self.gateway_heartbeat, 0o755)
        self.gateway_release_gate.write_text(
            textwrap.dedent(
                """
                #!/usr/bin/python3
                import json
                import os
                import re
                import sys
                import time
                from pathlib import Path

                root = Path(os.environ["MOCK_DOCKER_STATE_DIR"])
                log_path = Path(os.environ["MOCK_GATEWAY_GATE_LOG"])

                def read_state(name, default=""):
                    path = root / name
                    return path.read_text(encoding="ascii").strip() if path.exists() else default

                def write_state(name, value):
                    (root / name).write_text(value + "\\n", encoding="ascii")

                def remove_state(name):
                    (root / name).unlink(missing_ok=True)

                try:
                    request = json.load(sys.stdin)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    raise SystemExit(1)
                operation = request.get("operation")
                generation = request.get("generationId")
                short_fields = {"schemaVersion", "operation", "generationId"}
                release_fields = short_fields | {
                    "agentContainerId",
                    "workerContainerId",
                }
                expected_fields = release_fields if operation == "release" else short_fields
                if (
                    operation not in {"begin", "assert-pending", "release", "abort"}
                    or set(request) != expected_fields
                    or request.get("schemaVersion") != 1
                    or not isinstance(generation, str)
                    or re.fullmatch(r"[0-9a-f]{64}", generation) is None
                ):
                    raise SystemExit(1)
                with log_path.open("a", encoding="ascii") as stream:
                    stream.write(operation + "\\n")
                with Path(os.environ["MOCK_DOCKER_LOG"]).open(
                    "a", encoding="ascii"
                ) as stream:
                    stream.write("gateway gate " + operation + "\\n")
                mode = read_state("gateway_gate_mode", "healthy")
                if mode == "timeout-" + operation:
                    time.sleep(30)
                    raise SystemExit(1)
                if mode == "sensitive-" + operation:
                    sys.stdout.write(
                        Path(os.environ["MOCK_AGENT_TOKEN_FILE"]).read_text(
                            encoding="utf-8"
                        )
                    )
                    raise SystemExit(0)
                if mode == "fail-" + operation:
                    raise SystemExit(1)
                if operation == "begin":
                    write_state("gateway_gate_generation", generation)
                    write_state("gateway_gate_state", "pending")
                    remove_state("gateway_gate_agent_id")
                    remove_state("gateway_gate_worker_id")
                    raise SystemExit(0)
                if generation != read_state("gateway_gate_generation"):
                    raise SystemExit(1)
                if operation == "assert-pending":
                    raise SystemExit(
                        0 if read_state("gateway_gate_state") == "pending" else 1
                    )
                if operation == "abort":
                    write_state("gateway_gate_state", "aborted")
                    remove_state("gateway_gate_agent_id")
                    remove_state("gateway_gate_worker_id")
                    raise SystemExit(0)
                agent_id = request.get("agentContainerId")
                worker_id = request.get("workerContainerId")
                if (
                    read_state("gateway_gate_state") != "pending"
                    or not isinstance(agent_id, str)
                    or not isinstance(worker_id, str)
                    or re.fullmatch(r"[0-9a-f]{64}", agent_id) is None
                    or re.fullmatch(r"[0-9a-f]{64}", worker_id) is None
                    or (
                        read_state("gateway_gate_expected_agent")
                        and agent_id != read_state("gateway_gate_expected_agent")
                    )
                    or (
                        read_state("gateway_gate_expected_worker")
                        and worker_id != read_state("gateway_gate_expected_worker")
                    )
                ):
                    raise SystemExit(1)
                if mode == "no-authorize-release":
                    raise SystemExit(0)
                write_state("gateway_gate_agent_id", agent_id)
                write_state("gateway_gate_worker_id", worker_id)
                write_state("gateway_gate_state", "released")
                raise SystemExit(0)
                """
            ).lstrip(),
            encoding="utf-8",
        )
        os.chmod(self.gateway_release_gate, 0o755)
        checker_sha256 = hashlib.sha256(
            self.gateway_heartbeat.read_bytes()
        ).hexdigest()
        gate_sha256 = hashlib.sha256(
            self.gateway_release_gate.read_bytes()
        ).hexdigest()
        self.gateway_contract.write_text(
            json.dumps(
                {
                    "contractVersion": "1",
                    "producer": {
                        "repository": "Tangbohu09527/CF_agent-gateway",
                        "checkerSha256": checker_sha256,
                        "releaseGateSha256": gate_sha256,
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
                        "checkerRequest": {
                            "inputTransport": "stdin-json",
                            "inputSchemaVersion": 1,
                            "maxInputBytes": 4096,
                            "hardTimeoutSeconds": 10,
                            "requestFields": [
                                "schemaVersion",
                                "generationId",
                                "agentContainerId",
                                "workerContainerId",
                            ],
                            "binding": {
                                "generationId": "lowercase-hex-64",
                                "agentContainerId": "lowercase-hex-64",
                                "workerContainerId": "lowercase-hex-64",
                            },
                        },
                        "heartbeatMaxAgeSeconds": 30,
                        "requiresDockerHealth": True,
                        "requiresSuccessfulPoll": True,
                        "requiresLoggedIn": True,
                        "silentOutput": True,
                        "checkerExecution": {
                            "caller": "management-user",
                            "sudo": False,
                            "dockerSocketAccess": False,
                            "producerLinuxProof": "required",
                        },
                        "releaseGate": {
                            "command": str(self.gateway_release_gate),
                            "interfaceVersion": 1,
                            "inputTransport": "stdin-json",
                            "inputSchemaVersion": 1,
                            "maxInputBytes": 4096,
                            "hardTimeoutSeconds": 10,
                            "silentOutput": True,
                            "execution": {
                                "caller": "management-user",
                                "sudo": False,
                                "dockerSocketAccess": False,
                                "producerLinuxProof": "required",
                            },
                            "identifierFormats": {
                                "generationId": "lowercase-hex-64",
                                "agentContainerId": "lowercase-hex-64",
                                "workerContainerId": "lowercase-hex-64",
                            },
                            "operations": {
                                "begin": {
                                    "requestFields": [
                                        "schemaVersion",
                                        "operation",
                                        "generationId",
                                    ],
                                    "invalidatesPreviousReleases": True,
                                },
                                "assert-pending": {
                                    "requestFields": [
                                        "schemaVersion",
                                        "operation",
                                        "generationId",
                                    ],
                                    "requiresCurrentUnreleasedGeneration": True,
                                },
                                "release": {
                                    "requestFields": [
                                        "schemaVersion",
                                        "operation",
                                        "generationId",
                                        "agentContainerId",
                                        "workerContainerId",
                                    ],
                                    "requiresCurrentUnreleasedGeneration": True,
                                    "agentContainerBinding": "exact",
                                    "workerContainerBinding": (
                                        "exact-stopped-candidate"
                                    ),
                                },
                                "abort": {
                                    "requestFields": [
                                        "schemaVersion",
                                        "operation",
                                        "generationId",
                                    ],
                                    "revokesGeneration": True,
                                },
                            },
                            "workerAuthorization": {
                                "default": "deny",
                                "requiresExactCurrentRelease": True,
                            },
                        },
                        "lifecycle": {
                            "restartPolicy": "no",
                            "bootPolicy": "manual-after-fresh-qr",
                            "producerLinuxProof": "required",
                        },
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
                            "workerReadabilityProof": (
                                "producer-linux-integration"
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
            "gateway_exists": "1",
            "gateway_gate_state": "inactive",
            "gateway_gate_mode": "healthy",
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
        fake_mktemp = self.fake_bin / "mktemp"
        fake_mktemp.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            ": \"${MOCK_TMPDIR:?}\"\n"
            "TMPDIR=\"$MOCK_TMPDIR\"\n"
            "export TMPDIR\n"
            "exec /usr/bin/mktemp \"$@\"\n",
            encoding="ascii",
        )
        os.chmod(fake_mktemp, 0o755)

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
                "TMPDIR": str(self.tmp),
                "MOCK_TMPDIR": str(self.tmp),
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
                "MOCK_GATEWAY_GATE_LOG": str(self.gateway_gate_log),
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
                self.server.wait()
                raise RuntimeError("mock agent server exited before ready")
            time.sleep(0.02)
        if not self.ready_file.exists():
            self.server.terminate()
            try:
                self.server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait(timeout=3)
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
        timeout: int = 60,
        trace: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        command = ["bash"]
        if trace:
            command.append("-x")
        command.extend([str(SCRIPTS / script), *arguments])
        command = ["script", "-qefc", shlex.join(command), "/dev/null"]
        self.last_result = None
        started = time.monotonic()
        process = subprocess.Popen(
            command,
            cwd=REPO_ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            output, _ = self.communicate_with_timeout(
                process,
                timeout=timeout,
                label=f"{script} completion",
            )
            result = subprocess.CompletedProcess(
                process.args,
                process.returncode,
                output,
            )
            self.last_result = result
            return result
        except BaseException:
            if process.poll() is None:
                self.terminate_process_group_and_reap(process)
            raise
        finally:
            if process.stdout is not None and not process.stdout.closed:
                process.stdout.close()
            self.last_elapsed_seconds = time.monotonic() - started

    def popen(self, script: str, *arguments: str) -> subprocess.Popen[str]:
        command = ["bash", str(SCRIPTS / script), *arguments]
        process = subprocess.Popen(
            ["script", "-qefc", shlex.join(command), "/dev/null"],
            cwd=REPO_ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self.background.append(process)
        return process

    def wait_for_marker_or_process_exit(
        self,
        marker: Path,
        process: subprocess.Popen[str],
        *,
        timeout: float,
        label: str,
    ) -> None:
        started = time.monotonic()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker.exists():
                if marker.is_symlink() or not marker.is_file():
                    self.terminate_process_group_and_reap(process)
                    self.record_marker_wait_failure(
                        label, "unsafe-marker", process, started
                    )
                    raise AssertionError(f"{label} marker is not a regular file")
                return
            return_code = process.poll()
            if return_code is not None:
                process.wait()
                self.terminate_process_group_and_reap(process)
                self.record_marker_wait_failure(
                    label, "early-exit", process, started
                )
                raise AssertionError(
                    f"{label} process exited before marker: {return_code}"
                )
            time.sleep(0.05)
        self.terminate_process_group_and_reap(process)
        self.record_marker_wait_failure(
            label, "marker-timeout", process, started
        )
        raise AssertionError(f"timed out waiting for {label} marker")

    def record_marker_wait_failure(
        self,
        label: str,
        outcome: str,
        process: subprocess.Popen[str],
        started: float,
        captured_output: str | None = None,
    ) -> None:
        if captured_output is None:
            captured_output = ""
            if process.stdout is not None and not process.stdout.closed:
                try:
                    captured_output += process.stdout.read()
                except (OSError, UnicodeError, ValueError):
                    pass
        if process.stdout is not None and not process.stdout.closed:
            process.stdout.close()
        return_code = process.returncode
        self.last_result = subprocess.CompletedProcess(
            process.args,
            return_code if return_code is not None else 1,
            captured_output,
        )
        self.last_elapsed_seconds = time.monotonic() - started
        self.emit_sanitized_diagnostics(f"{label}:{outcome}")

    def communicate_with_timeout(
        self,
        process: subprocess.Popen[str],
        *,
        timeout: float,
        label: str,
    ) -> tuple[str, None]:
        started = time.monotonic()
        try:
            return process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            self.terminate_process_group_and_reap(process)
            if isinstance(error.output, bytes):
                captured_output = error.output.decode(
                    "utf-8", errors="replace"
                )
            elif isinstance(error.output, str):
                captured_output = error.output
            else:
                captured_output = ""
            try:
                captured_output, _ = process.communicate(timeout=3)
            except (OSError, subprocess.TimeoutExpired, ValueError):
                pass
            self.record_marker_wait_failure(
                label,
                "communicate-timeout",
                process,
                started,
                captured_output,
            )
            raise

    @staticmethod
    def terminate_process_group_and_reap(
        process: subprocess.Popen[str], timeout: float = 3
    ) -> None:
        group_id = process.pid
        try:
            os.killpg(group_id, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            process.poll()
            try:
                os.killpg(group_id, 0)
            except ProcessLookupError:
                if process.poll() is None:
                    process.wait(timeout=max(0.1, deadline - time.monotonic()))
                else:
                    process.wait()
                return
            time.sleep(0.05)
        try:
            os.killpg(group_id, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            process.wait(timeout=timeout)
        else:
            process.wait()

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

    def gate_lines(self) -> list[str]:
        if not self.gateway_gate_log.exists():
            return []
        return [
            line
            for line in self.gateway_gate_log.read_text(
                encoding="ascii"
            ).splitlines()
            if line
        ]

    def audit_lines(self) -> list[str]:
        return [
            line
            for line in self.audit_log.read_text(encoding="utf-8").splitlines()
            if line
        ]

    def sanitized_diagnostics(self, test_name: str) -> str:
        result = self.last_result
        output = result.stdout if result is not None else ""
        phase_match = re.search(
            r"^.*failed during phase:\s*([a-z0-9_]{1,64})\s*$",
            output,
            flags=re.MULTILINE,
        )
        phase_candidate = phase_match.group(1) if phase_match else ""
        phase = (
            phase_candidate
            if phase_candidate in ALLOWED_FLOW_PHASES
            else "unavailable"
        )

        def safe_state(name: str, allowed: set[str]) -> str:
            try:
                value = self.read_state(name)
            except OSError:
                return "missing"
            return value if value in allowed else "redacted-invalid"

        mutation_actions = [
            line if line in ALLOWED_MUTATION_ACTIONS else "redacted-invalid"
            for line in self.mutation_lines()[-50:]
        ]
        gateway_gate_actions = [
            line if line in {"begin", "assert-pending", "release", "abort"}
            else "redacted-invalid"
            for line in self.gate_lines()[-50:]
        ]

        audit_categories: dict[str, int] = {}
        for line in self.audit_lines()[-50:]:
            category = "other"
            for prefix, candidate in (
                ("GET ", "agent-api-get"),
                ("gateway gate ", "gateway-gate"),
                ("gateway worker ", "gateway-worker"),
                ("agent compose ", "agent-compose"),
                ("gateway compose ", "gateway-compose"),
                ("agent container ", "agent-container"),
                ("docker ", "docker"),
            ):
                if line.startswith(prefix):
                    category = candidate
                    break
            audit_categories[category] = audit_categories.get(category, 0) + 1

        root = self.root.resolve(strict=False)
        confinement = {}
        for label, candidate in (
            ("tmp", self.tmp),
            ("storage", self.storage),
            ("runtime", self.runtime),
            ("archive", self.archive),
            ("secrets", self.secrets),
            ("lock", Path(self.env["CF_AGENT_WECHAT_LOCK_FILE"])),
            ("fake_bin", self.fake_bin),
            ("docker_socket", self.docker_socket_path),
            ("docker_state", self.docker_state),
            ("gateway", self.gateway_dir),
        ):
            resolved = candidate.resolve(strict=False)
            confinement[label] = (
                resolved != root
                and os.path.commonpath((root, resolved)) == os.fspath(root)
            )

        return "\n".join(
            (
                "SANITIZED LIFECYCLE FIXTURE DIAGNOSTICS",
                f"test={test_name}",
                "return_code="
                + (str(result.returncode) if result is not None else "unavailable"),
                f"elapsed_seconds={self.last_elapsed_seconds:.3f}",
                f"failure_phase={phase}",
                "gateway_running="
                + safe_state("gateway_running", {"0", "1"}),
                "gateway_gate_state="
                + safe_state(
                    "gateway_gate_state",
                    {"inactive", "pending", "released", "aborted"},
                ),
                "agent_running=" + safe_state("agent_running", {"0", "1"}),
                "mutation_actions=" + json.dumps(mutation_actions),
                "gateway_gate_actions=" + json.dumps(gateway_gate_actions),
                "audit_categories=" + json.dumps(
                    audit_categories, sort_keys=True
                ),
                "paths_confined=" + json.dumps(confinement, sort_keys=True),
            )
        )

    def emit_sanitized_diagnostics(self, test_name: str) -> None:
        if self.diagnostics_emitted:
            return
        try:
            diagnostic_text = self.sanitized_diagnostics(test_name)
        except Exception:
            diagnostic_text = (
                "SANITIZED LIFECYCLE FIXTURE DIAGNOSTICS unavailable"
            )
        print(diagnostic_text, file=sys.stderr, flush=True)
        self.diagnostics_emitted = True

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
            self.terminate_process_group_and_reap(process)
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
        outcome = getattr(self, "_outcome", None)
        result = getattr(outcome, "result", None)
        failed = False
        if result is not None:
            for collection_name in ("failures", "errors"):
                for failed_test, _traceback in getattr(
                    result, collection_name, ()
                ):
                    if failed_test is self or getattr(
                        failed_test, "test_case", None
                    ) is self:
                        failed = True
                        break
                if failed:
                    break
        if failed:
            self.fixture.emit_sanitized_diagnostics(self._testMethodName)
        self.fixture.close()

    def test_fixture_temporary_paths_are_strictly_confined(self) -> None:
        root = self.fixture.root.resolve(strict=True)
        self.assertEqual(
            Path(self.fixture.env["CF_AGENT_WECHAT_TEST_ROOT"]),
            root,
        )
        self.assertEqual(Path(self.fixture.env["TMPDIR"]), self.fixture.tmp)
        self.assertEqual(Path(self.fixture.env["MOCK_TMPDIR"]), self.fixture.tmp)
        for label, candidate in (
            ("temporary directory", self.fixture.tmp),
            ("storage root", self.fixture.storage),
            ("runtime root", self.fixture.runtime),
            ("archive root", self.fixture.archive),
        ):
            with self.subTest(path=label):
                resolved = candidate.resolve(strict=True)
                self.assertNotEqual(resolved, root)
                self.assertEqual(
                    os.path.commonpath((root, resolved)),
                    os.fspath(root),
                )

        metadata = self.fixture.tmp.lstat()
        self.assertTrue(stat.S_ISDIR(metadata.st_mode))
        self.assertFalse(self.fixture.tmp.is_symlink())
        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o700)

        child_environment = self.fixture.env.copy()
        child_environment.pop("TMPDIR", None)
        result = subprocess.run(
            [os.fspath(self.fixture.fake_bin / "mktemp")],
            env=child_environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        created = Path(result.stdout.strip())
        try:
            self.assertEqual(created.parent.resolve(strict=True), self.fixture.tmp)
        finally:
            created.unlink(missing_ok=True)

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

    def assert_candidate_rejected_before_archive(
        self,
        result: subprocess.CompletedProcess[str],
        storage_before: str,
    ) -> None:
        self.assert_failed(result)
        self.assertIn(
            "failed during phase: attest_stopped_agent_candidate",
            result.stdout,
        )
        self.assertEqual(tree_digest(self.fixture.storage), storage_before)
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertTrue(
            (self.fixture.runtime / "data" / "old-state.marker").is_file()
        )
        self.assertFalse(
            (self.fixture.runtime / "data" / "agent-runtime.log").exists()
        )
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.read_state("agent_exists"), "0")
        self.assertEqual(self.fixture.read_state("agent_running"), "0")
        mutations = self.fixture.mutation_lines()
        self.assertIn("agent container create stopped", mutations)
        self.assertNotIn("agent container start attested candidate", mutations)
        self.assertNotIn("gateway worker start", mutations)
        self.assertEqual(self.fixture.login_log.read_text(encoding="utf-8"), "")
        self.assertNotIn("扫描二维码", result.stdout)
        self.fixture.assert_no_sensitive_text(
            self,
            result.stdout,
            self.fixture.audit_log.read_text(encoding="utf-8"),
            self.fixture.mutation_log.read_text(encoding="utf-8"),
            self.fixture.login_log.read_text(encoding="utf-8"),
        )

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
                "agent container create stopped",
                "agent container start attested candidate",
                "gateway worker start",
            ],
        )
        self.assertEqual(self.fixture.read_state("agent_exists"), "1")
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        self.assertTrue(
            (self.fixture.runtime / "data" / "agent-runtime.log").is_file()
        )
        audit = self.fixture.audit_lines()
        gate_operations = self.fixture.gate_lines()
        self.assertEqual(gate_operations[0], "begin")
        self.assertEqual(gate_operations[-1], "release")
        self.assertGreaterEqual(
            gate_operations.count("assert-pending"), 8
        )
        self.assertEqual(gate_operations.count("release"), 1)
        self.assertNotIn("abort", gate_operations)
        self.assertEqual(
            self.fixture.read_state("gateway_gate_state"), "released"
        )
        self.assertEqual(
            self.fixture.read_state("gateway_gate_agent_id"), "a" * 64
        )
        self.assertEqual(
            self.fixture.read_state("gateway_gate_worker_id"),
            self.fixture.read_state("gateway_compose_id"),
        )
        self.assertLess(
            audit.index("gateway worker stop"),
            audit.index("gateway gate begin"),
        )
        self.assertLess(
            audit.index("gateway worker create stopped"),
            audit.index("gateway gate release"),
        )
        self.assertLess(
            audit.index("gateway gate release"),
            audit.index("gateway worker start"),
        )
        self.assertNotIn("gateway worker pre-release denied", audit)
        self.assertNotIn("forbidden gateway compose up", audit)
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
                "active-agent-unit",
                {"agent_unit_activity": "active"},
                "must be inactive",
            ),
            (
                "active-agent-unit-inventory",
                {"agent_unit_active": "1"},
                "unapproved active agent-wechat unit",
            ),
            (
                "active-generic-service",
                {"indirect_agent_unit_active": "1"},
                "active systemd unit could supervise agent-wechat",
            ),
            (
                "active-timer-chain",
                {"generic_timer_active": "1"},
                "systemd timer could automatically start",
            ),
            (
                "active-path-chain",
                {"explicit_path_active": "1"},
                "systemd path unit could automatically start",
            ),
            (
                "active-socket-chain",
                {"explicit_socket_active": "1"},
                "systemd socket could automatically start",
            ),
            (
                "active-target-chain",
                {"target_wants_active": "1"},
                "systemd target could automatically start",
            ),
            (
                "system-state-partial-timeout",
                {"systemd_partial_timeout": "1"},
                "systemd state probe failed",
            ),
            (
                "agent-activity-partial-timeout",
                {"agent_activity_partial_timeout": "1"},
                "activity probe failed",
            ),
            (
                "agent-enablement-partial-timeout",
                {"agent_enablement_partial_timeout": "1"},
                "enablement probe failed",
            ),
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
                if any(
                    "partial_timeout" in name for name in state
                ):
                    self.fixture.env["DOCKER_COMMAND_TIMEOUT"] = "1"
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

    def _assert_exact_actual_container_attestation_rejects_drift(
        self, state_name: str, value: str
    ) -> None:
        self.fixture.write_state(state_name, value)
        storage_before = tree_digest(self.fixture.storage)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_candidate_rejected_before_archive(
            result, storage_before
        )
        self.assertIn("exact production runtime contract", result.stdout)
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
                storage_before = tree_digest(self.fixture.storage)

                result = self.fixture.run("start-qr-login.sh", trace=True)

                self.assert_candidate_rejected_before_archive(
                    result, storage_before
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

    def test_host_path_overrides_fail_closed_before_mutation(self) -> None:
        hostile = {
            "CF_AGENT_WECHAT_STORAGE_ROOT": "/attacker/storage",
            "CF_AGENT_WECHAT_RUNTIME_ROOT": "/attacker/storage/runtime",
            "CF_AGENT_WECHAT_ARCHIVE_ROOT": "/attacker/storage/archive",
        }
        self.fixture.env.update(hostile)
        storage_before = tree_digest(self.fixture.storage)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed(result)
        self.assertIn(
            "must remain within the isolated testing root",
            result.stdout,
        )
        combined = "\n".join(
            (
                result.stdout,
                self.fixture.audit_log.read_text(encoding="utf-8"),
                self.fixture.mutation_log.read_text(encoding="utf-8"),
            )
        )
        for value in hostile.values():
            self.assertNotIn(value, combined)
        self.assertEqual(tree_digest(self.fixture.storage), storage_before)
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertEqual(self.fixture.mutation_lines(), [])
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")

    def test_compose_path_swap_cannot_change_bound_runtime(self) -> None:
        approved_compose = self.fixture.agent_compose.read_text(
            encoding="utf-8"
        )
        self.fixture.write_state("mutate_agent_compose_after_config", "1")
        storage_before = tree_digest(self.fixture.storage)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed(result)
        self.assertIn("Compose changed during the fresh QR operation", result.stdout)
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
        self.assertEqual(tree_digest(self.fixture.storage), storage_before)
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertTrue(
            (self.fixture.runtime / "data" / "old-state.marker").is_file()
        )
        mutations = self.fixture.mutation_lines()
        self.assertNotIn("agent container create stopped", mutations)
        self.assertNotIn("agent container start attested candidate", mutations)
        self.assertNotIn("gateway worker start", mutations)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertEqual(self.fixture.read_state("agent_exists"), "0")
        self.assertNotIn("扫描二维码", result.stdout)

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

    def test_runtime_parent_default_acl_is_rejected_before_mutation(
        self,
    ) -> None:
        setfacl = shutil.which("setfacl")
        if setfacl is None:
            self.skipTest("setfacl is unavailable")
        subprocess.run(
            [
                setfacl,
                "-m",
                "d:u:65534:rwx",
                os.fspath(self.fixture.storage),
            ],
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"},
            timeout=5,
        )
        attributes = os.listxattr(self.fixture.storage)
        self.assertTrue(
            any("posix_acl_default" in os.fsdecode(name) for name in attributes),
            attributes,
        )
        storage_before = tree_digest(self.fixture.storage)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed(result)
        self.assertIn("extended attributes or ACLs", result.stdout)
        self.assertEqual(tree_digest(self.fixture.storage), storage_before)
        self.assertEqual(self.fixture.mutation_lines(), [])
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertEqual(self.fixture.login_log.read_text(), "")
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")

    def test_management_numeric_boundaries_fail_before_lifecycle_mutation(
        self,
    ) -> None:
        cases = (
            ("port", "AGENT_WECHAT_PORT", "65536"),
            ("runtime-uid", "CF_AGENT_WECHAT_RUNTIME_UID", "4294967295"),
            ("runtime-gid", "CF_AGENT_WECHAT_RUNTIME_GID", "4294967295"),
            (
                "management-gid",
                "CF_AGENT_WECHAT_MANAGEMENT_GID",
                "4294967295",
            ),
        )
        for index, (label, key, value) in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{label}"
                )
            with self.subTest(case=label):
                self.fixture.replace_agent_env(key, value)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertIn(
                    "docker/.env failed byte-safe validation", result.stdout
                )
                self.assertEqual(self.fixture.mutation_lines(), [])
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "1"
                )
                self.assertNotIn("扫描二维码", result.stdout)

    def test_archive_capacity_is_rechecked_at_archive_commit_boundary(
        self,
    ) -> None:
        for index, (label, state_name) in enumerate(
            (
                ("space", "df_available_blocks_after_first"),
                ("inode", "df_available_inodes_after_first"),
            )
        ):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{label}"
                )
            with self.subTest(case=label):
                self.fixture.write_state(state_name, "0")
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertIn(
                    "below the approved free space or inode", result.stdout
                )
                self.assertEqual(
                    self.fixture.read_state("df_capacity_probe_count"), "2"
                )
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertTrue(
                    (
                        self.fixture.runtime / "data" / "old-state.marker"
                    ).is_file()
                )
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "0"
                )
                mutations = self.fixture.mutation_lines()
                self.assertIn("agent container create stopped", mutations)
                self.assertNotIn(
                    "agent container start attested candidate", mutations
                )
                self.assertNotIn("gateway worker start", mutations)
                self.assertNotIn("扫描二维码", result.stdout)

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

    def test_archive_capacity_rejects_unsafe_df_numbers_before_archive(
        self,
    ) -> None:
        cases = (
            ("block-total-overflow", "df_total_blocks", str(1 << 63)),
            (
                "block-byte-overflow",
                "df_available_blocks",
                str(((1 << 63) - 1) // 1024 + 1),
            ),
            ("inode-total-overflow", "df_total_inodes", str(1 << 63)),
            ("inode-available-overflow", "df_available_inodes", str(1 << 63)),
            ("malformed-block", "df_available_blocks", "not-a-number"),
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
                self.assertRegex(
                    result.stdout,
                    r"(invalid capacity|could not be measured)",
                )
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "0"
                )
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertNotIn("扫描二维码", result.stdout)

    def test_archive_capacity_rejects_available_greater_than_total(
        self,
    ) -> None:
        cases = (
            ("blocks", "df_total_blocks", "10", "df_available_blocks", "11"),
            ("inodes", "df_total_inodes", "10", "df_available_inodes", "11"),
        )
        for index, case in enumerate(cases):
            label, total_name, total, available_name, available = case
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{label}"
                )
            with self.subTest(case=label):
                self.fixture.write_state(total_name, total)
                self.fixture.write_state(available_name, available)
                result = self.fixture.run("start-qr-login.sh")
                self.assert_failed(result)
                self.assertIn("invalid capacity", result.stdout)
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "0"
                )
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertNotIn("扫描二维码", result.stdout)

    def test_archive_capacity_df_hard_timeout_fails_before_archive_or_qr(
        self,
    ) -> None:
        self.fixture.env["CF_AGENT_WECHAT_TEST_ARCHIVE_TOOL_TIMEOUT"] = "1"
        self.fixture.write_state("df_sleep", "120")
        started = time.monotonic()

        result = self.fixture.run("start-qr-login.sh", timeout=60)

        self.assert_failed(result)
        self.assertLess(time.monotonic() - started, 45)
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
            "gate-missing",
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
                elif mode == "gate-missing":
                    self.fixture.gateway_release_gate.unlink()
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

    def test_gateway_gate_begin_failure_and_sensitive_output_fail_closed(
        self,
    ) -> None:
        for index, mode in enumerate(("fail-begin", "sensitive-begin")):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{mode}"
                )
            with self.subTest(mode=mode):
                self.fixture.write_state("gateway_gate_mode", mode)
                before = tree_digest(self.fixture.storage)

                result = self.fixture.run("start-qr-login.sh")

                self.assert_failed(result)
                self.assertEqual(tree_digest(self.fixture.storage), before)
                self.assertEqual(self.fixture.archive_dirs(), [])
                self.assertEqual(self.fixture.login_log.read_text(), "")
                self.assertEqual(
                    self.fixture.read_state("gateway_running"), "0"
                )
                self.assertNotIn(
                    "gateway worker start", self.fixture.mutation_lines()
                )
                self.assertEqual(self.fixture.gate_lines(), ["begin"])
                self.assertIn("begin_gateway_generation", result.stdout)
                self.fixture.assert_no_sensitive_text(self, result.stdout)

    def test_gateway_gate_release_failures_abort_without_worker_start(
        self,
    ) -> None:
        cases = (
            "fail-release",
            "timeout-release",
            "sensitive-release",
            "mismatched-agent",
        )
        for index, mode in enumerate(cases):
            if index:
                self.fixture.close()
                self.fixture = RuntimeFixture(
                    f"{self._testMethodName}-{mode}"
                )
            with self.subTest(mode=mode):
                if mode == "mismatched-agent":
                    self.fixture.write_state(
                        "gateway_gate_expected_agent", "d" * 64
                    )
                else:
                    self.fixture.write_state("gateway_gate_mode", mode)

                result = self.fixture.run(
                    "start-qr-login.sh", timeout=30
                )

                self.assert_failed_worker_release_preserves_agent(
                    result,
                    "release_gateway_generation",
                    worker_started=False,
                )
                operations = self.fixture.gate_lines()
                self.assertEqual(operations[0], "begin")
                self.assertIn("release", operations)
                self.assertEqual(operations[-1], "abort")
                self.assertEqual(
                    self.fixture.read_state("gateway_gate_state"),
                    "aborted",
                )
                self.assertNotIn(
                    "gateway worker start", self.fixture.mutation_lines()
                )
                self.fixture.assert_no_sensitive_text(self, result.stdout)

    def test_worker_default_deny_blocks_start_without_effective_release(
        self,
    ) -> None:
        self.fixture.write_state(
            "gateway_gate_mode", "no-authorize-release"
        )

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed_worker_release_preserves_agent(
            result, "start_gateway_worker", worker_started=False
        )
        self.assertIn(
            "gateway worker pre-release denied",
            self.fixture.audit_lines(),
        )
        self.assertEqual(self.fixture.gate_lines()[-1], "abort")
        self.assertEqual(
            self.fixture.read_state("gateway_gate_state"), "aborted"
        )
        self.fixture.assert_no_sensitive_text(self, result.stdout)

    def test_pending_generation_drift_aborts_qr_and_keeps_worker_stopped(
        self,
    ) -> None:
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
                    else "start exited before QR generation drift"
                )
            time.sleep(0.05)
        self.assertTrue(self.fixture.login_pause_file.exists())
        self.fixture.write_state("gateway_gate_generation", "d" * 64)
        self.fixture.login_continue_file.touch()
        output, _ = process.communicate(timeout=15)
        result = subprocess.CompletedProcess(
            process.args, process.returncode, output
        )

        self.assert_failed_lifecycle_cleanup(
            result, "force_qr_login", worker_started=False
        )
        self.assertEqual(self.fixture.gate_lines()[-1], "abort")
        self.assertEqual(
            self.fixture.read_state("gateway_gate_state"), "pending"
        )
        self.assertIn(
            "generation revocation could not be confirmed",
            result.stdout,
        )
        self.assertNotIn(
            "gateway worker start", self.fixture.mutation_lines()
        )

    def test_gate_replacement_race_never_executes_or_leaks(self) -> None:
        replacement = self.fixture.root / "replacement-runtime-gate"
        marker = self.fixture.root / "replacement-gate-executed"
        replacement.write_text(
            "#!/bin/sh\n"
            + f"printf '%s\\n' {shlex.quote(self.fixture.token)}\n"
            + f"printf replaced > {shlex.quote(str(marker))}\n"
            + "exit 0\n",
            encoding="utf-8",
        )
        replacement.chmod(0o755)
        self.fixture.env[
            "CF_AGENT_WECHAT_TEST_GATEWAY_GATE_REPLACEMENT"
        ] = str(replacement)
        before = tree_digest(self.fixture.storage)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_failed(result)
        self.assertIn("begin_gateway_generation", result.stdout)
        self.assertEqual(tree_digest(self.fixture.storage), before)
        self.assertFalse(marker.exists())
        self.assertNotIn(self.fixture.token, result.stdout)
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        self.assertNotIn(
            "gateway worker start", self.fixture.mutation_lines()
        )

    def test_live_gateway_worker_credential_drift_revokes_worker(self) -> None:
        self.fixture.write_state(
            "gateway_actual_token_source", "/tmp/unapproved-token"
        )
        result = self.fixture.run("start-qr-login.sh")
        manifest = self.assert_failed_worker_release_preserves_agent(
            result,
            "create_gateway_worker_candidate",
            worker_started=False,
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

    def test_first_start_without_prior_runtime_uses_attested_candidate(
        self,
    ) -> None:
        shutil.rmtree(self.fixture.runtime)

        result = self.fixture.run("start-qr-login.sh")

        self.assert_succeeded(result)
        self.assertEqual(self.fixture.archive_dirs(), [])
        self.assertTrue((self.fixture.runtime / "data").is_dir())
        self.assertTrue((self.fixture.runtime / "wechat-home").is_dir())
        self.assertEqual(
            self.fixture.mutation_lines(),
            [
                "gateway worker stop",
                "agent container stop",
                "agent container remove",
                "agent container create stopped",
                "agent container start attested candidate",
                "gateway worker start",
            ],
        )
        self.assertEqual(self.fixture.read_state("agent_running"), "1")
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")

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

                if mode == "relative":
                    self.assertRegex(
                        result.stdout.lower(),
                        (
                            r"testing asset paths must be absolute"
                            r"|testing management assets are not isolated"
                        ),
                    )
                else:
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
                "agent container create stopped",
                "agent container start attested candidate",
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
                "agent container create stopped",
                "agent container start attested candidate",
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

    def test_worker_restarted_during_qr_wait_is_stopped_and_aborts(
        self,
    ) -> None:
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
                    else "fresh QR process exited before QR wait"
                )
            time.sleep(0.05)
        self.assertTrue(self.fixture.login_pause_file.exists())

        self.fixture.write_state("gateway_running", "1")
        output, _ = process.communicate(timeout=10)
        result = subprocess.CompletedProcess(
            process.args,
            process.returncode,
            output,
        )

        manifest = self.assert_failed_lifecycle_cleanup(
            result, "force_qr_login"
        )
        self.assertEqual(manifest["archiveResult"], "succeeded")
        self.assertIn(
            "became active before authorized fresh-runtime release",
            result.stdout,
        )
        self.assertIn("扫描二维码", result.stdout)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        mutations = self.fixture.mutation_lines()
        self.assertGreaterEqual(
            mutations.count("gateway worker stop"), 2
        )
        self.assertNotIn("gateway worker start", mutations)
        self.fixture.assert_no_sensitive_text(self, result.stdout)

    def test_final_release_rejects_agent_container_id_replacement(self) -> None:
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
                    else "fresh QR process exited before pause"
                )
            time.sleep(0.05)
        self.assertTrue(self.fixture.login_pause_file.exists())
        self.fixture.write_state("agent_compose_id", "d" * 64)
        self.fixture.login_continue_file.touch()
        output, _ = process.communicate(timeout=10)
        result = subprocess.CompletedProcess(
            process.args,
            process.returncode,
            output,
        )

        self.assert_failed_lifecycle_cleanup(
            result, "revalidate_final_runtime_contract"
        )
        self.assertIn("container identity changed", result.stdout)
        self.assertNotIn("gateway worker start", self.fixture.mutation_lines())

    def test_concurrent_start_allows_only_one_lock_holder(self) -> None:
        self.fixture.env["MOCK_LOGIN_MODE"] = "block"
        first = self.fixture.popen("start-qr-login.sh")
        try:
            self.fixture.wait_for_marker_or_process_exit(
                self.fixture.login_pause_file,
                first,
                timeout=10,
                label="concurrent-start QR pause",
            )
            mutations_before = list(self.fixture.mutation_lines())
            archives_before = list(self.fixture.archive_dirs())

            second = self.fixture.run("start-qr-login.sh")
            self.assert_failed(second)
            self.assertIn("Another QR runtime operation", second.stdout)
            self.assertEqual(self.fixture.mutation_lines(), mutations_before)
            self.assertEqual(self.fixture.archive_dirs(), archives_before)

            self.fixture.login_continue_file.touch()
            output, _ = self.fixture.communicate_with_timeout(
                first,
                timeout=30,
                label="concurrent-start completion",
            )
        except BaseException:
            self.fixture.terminate_process_group_and_reap(first)
            raise
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
                "agent container create stopped",
                "agent container start attested candidate",
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
                self.assertEqual(self.fixture.gate_lines()[-1], "abort")
                self.assertEqual(
                    self.fixture.read_state("gateway_gate_state"),
                    "aborted",
                )
                mutations = self.fixture.mutation_lines()
                worker_start = mutations.index("gateway worker start")
                self.assertEqual(
                    mutations[worker_start + 1 :].count(
                        "gateway worker stop"
                    ),
                    2,
                    "post-up failure needs immediate rollback plus EXIT fallback",
                )

    def test_worker_compose_stop_failure_uses_exact_label_fallback(self) -> None:
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
            [
                "gateway worker stop failed",
                "gateway worker direct stop",
                "gateway worker stop",
            ],
        )
        self.assertNotIn("rollback could not be confirmed", result.stdout)
        self.assertIn("remains stopped", result.stdout)
        self.assertNotIn("state is unknown", result.stdout)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")

    def test_worker_rollback_unknown_after_both_stop_attempts_fail(
        self,
    ) -> None:
        self.fixture.write_state("worker_heartbeat", "unhealthy")
        self.fixture.write_state("gateway_cleanup_stop_failures", "2")
        self.fixture.write_state("gateway_direct_stop_error", "1")

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

    def test_worker_direct_fallback_rejects_label_mismatch(self) -> None:
        self.fixture.write_state("worker_heartbeat", "unhealthy")
        self.fixture.write_state("gateway_cleanup_stop_failures", "2")
        self.fixture.write_state("gateway_actual_project", "attacker-project")

        result = self.fixture.run("start-qr-login.sh", timeout=30)

        self.assert_failed(result)
        self.assertEqual(self.fixture.read_state("gateway_running"), "1")
        self.assertIn("rollback could not be confirmed", result.stdout)
        mutations = self.fixture.mutation_lines()
        self.assertNotIn("gateway worker direct stop", mutations)
        self.assertEqual(
            mutations.count("gateway worker stop failed"),
            2,
        )
        self.fixture.assert_no_sensitive_text(self, result.stdout)

    def test_worker_id_replacement_is_rolled_back_immediately(self) -> None:
        self.fixture.write_state("worker_heartbeat", "replace-instance")

        result = self.fixture.run("start-qr-login.sh", timeout=30)

        self.assert_failed_worker_release_preserves_agent(
            result, "start_gateway_worker", worker_started=True
        )
        self.assertIn("instance identity changed", result.stdout)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")
        mutations = self.fixture.mutation_lines()
        self.assertIn("gateway worker stop", mutations)
        self.assertNotIn("gateway worker direct stop", mutations)
        self.fixture.assert_no_sensitive_text(self, result.stdout)

    def test_checker_replacement_race_never_executes_or_leaks(
        self,
    ) -> None:
        replacement = self.fixture.root / "replacement-heartbeat-checker"
        marker = self.fixture.root / "replacement-executed"
        checker_pause = self.fixture.root / "checker-execute.pause"
        checker_continue = self.fixture.root / "checker-execute.continue"
        python_wrapper = self.fixture.root / "checker-python-wrapper"
        replacement.write_text(
            "#!/bin/sh\n"
            + f"printf '%s\\n' {shlex.quote(self.fixture.token)}\n"
            + f"printf replaced > {shlex.quote(str(marker))}\n"
            + "exit 0\n",
            encoding="utf-8",
        )
        replacement.chmod(0o755)
        python_wrapper.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "if [ \"${4:-}\" = execute ] && "
            f"[ \"${{5:-}}\" = {shlex.quote(str(self.fixture.gateway_heartbeat))} ]; then\n"
            f"  : > {shlex.quote(str(checker_pause))}\n"
            f"  while [ ! -f {shlex.quote(str(checker_continue))} ]; do\n"
            "    sleep 0.02\n"
            "  done\n"
            "fi\n"
            f"exec {shlex.quote(sys.executable)} \"$@\"\n",
            encoding="utf-8",
        )
        python_wrapper.chmod(0o755)
        self.fixture.env["PYTHON_BIN"] = str(python_wrapper)
        self.fixture.env[
            "CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT"
        ] = str(replacement)

        process = self.fixture.popen("start-qr-login.sh")
        try:
            self.fixture.wait_for_marker_or_process_exit(
                checker_pause,
                process,
                timeout=12,
                label="checker execute",
            )
            checker_continue.touch()
            output, _ = self.fixture.communicate_with_timeout(
                process,
                timeout=30,
                label="checker replacement completion",
            )
        except BaseException:
            self.fixture.terminate_process_group_and_reap(process)
            raise
        result = subprocess.CompletedProcess(
            process.args,
            process.returncode,
            output,
        )

        self.assert_failed_worker_release_preserves_agent(
            result, "start_gateway_worker", worker_started=True
        )
        self.assertFalse(marker.exists())
        self.assertNotIn(self.fixture.token, result.stdout)
        self.assertEqual(self.fixture.read_state("gateway_running"), "0")


def _make_exact_actual_container_attestation_test(
    state_name: str, value: str
) -> Any:
    def test_case(self: ForcedQrRuntimeTests) -> None:
        self._assert_exact_actual_container_attestation_rejects_drift(
            state_name, value
        )

    return test_case


for (
    _attestation_label,
    _attestation_state_name,
    _attestation_value,
) in EXACT_ACTUAL_CONTAINER_ATTESTATION_CASES:
    _attestation_suffix = re.sub(
        r"[^a-z0-9]+", "_", _attestation_label
    ).strip("_")
    _attestation_test_name = (
        "test_exact_actual_container_attestation_rejects_drift_"
        + _attestation_suffix
    )
    if hasattr(ForcedQrRuntimeTests, _attestation_test_name):
        raise RuntimeError(
            f"duplicate attestation test ID: {_attestation_test_name}"
        )
    _attestation_test = _make_exact_actual_container_attestation_test(
        _attestation_state_name, _attestation_value
    )
    _attestation_test.__name__ = _attestation_test_name
    _attestation_test.__qualname__ = (
        f"{ForcedQrRuntimeTests.__qualname__}.{_attestation_test_name}"
    )
    setattr(
        ForcedQrRuntimeTests,
        _attestation_test_name,
        _attestation_test,
    )


def _flatten_test_suite(suite: unittest.TestSuite) -> list[unittest.TestCase]:
    tests: list[unittest.TestCase] = []
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            tests.extend(_flatten_test_suite(item))
        elif isinstance(item, unittest.TestCase):
            tests.append(item)
        else:
            raise TypeError(f"Unsupported unittest item: {type(item).__name__}")
    return tests


def _lifecycle_test_method_name(test: unittest.TestCase) -> str:
    return test.id().rsplit(".", 1)[-1]


def _lifecycle_test_estimated_seconds(test: unittest.TestCase) -> int:
    method_name = _lifecycle_test_method_name(test)
    if method_name.startswith(
        "test_exact_actual_container_attestation_rejects_drift_"
    ):
        return LIFECYCLE_SHARD_ATTESTATION_SECONDS
    return LIFECYCLE_SHARD_ESTIMATED_SECONDS.get(
        method_name, LIFECYCLE_SHARD_DEFAULT_SECONDS
    )


def _partition_lifecycle_tests(
    all_tests: list[unittest.TestCase],
    shard_count: int,
) -> tuple[list[list[unittest.TestCase]], list[int], dict[str, int]]:
    if type(LIFECYCLE_SHARD_DEFAULT_SECONDS) is not int or (
        LIFECYCLE_SHARD_DEFAULT_SECONDS <= 0
    ):
        raise RuntimeError("Lifecycle default duration estimate is invalid")
    if type(LIFECYCLE_SHARD_ATTESTATION_SECONDS) is not int or (
        LIFECYCLE_SHARD_ATTESTATION_SECONDS <= 0
    ):
        raise RuntimeError(
            "Lifecycle attestation duration estimate is invalid"
        )
    if any(
        type(value) is not int or value <= 0
        for value in LIFECYCLE_SHARD_ESTIMATED_SECONDS.values()
    ):
        raise RuntimeError("Lifecycle duration estimate table is invalid")

    discovered_method_names = {
        _lifecycle_test_method_name(test) for test in all_tests
    }
    if len(discovered_method_names) != len(all_tests):
        raise RuntimeError(
            "Lifecycle sharding requires unique test method names"
        )
    stale_estimates = (
        set(LIFECYCLE_SHARD_ESTIMATED_SECONDS)
        - discovered_method_names
    )
    if stale_estimates:
        raise RuntimeError(
            "Lifecycle duration estimates reference missing tests: "
            + ",".join(sorted(stale_estimates))
        )

    estimated_by_id = {
        test.id(): _lifecycle_test_estimated_seconds(test)
        for test in all_tests
    }
    ordered_tests = sorted(
        all_tests,
        key=lambda test: (
            -estimated_by_id[test.id()],
            hashlib.sha256(
                _lifecycle_test_method_name(test).encode("utf-8")
            ).hexdigest(),
        ),
    )
    minimum_size, larger_shard_count = divmod(
        len(all_tests), shard_count
    )
    capacities = [
        minimum_size + (1 if index < larger_shard_count else 0)
        for index in range(shard_count)
    ]
    partitions: list[list[unittest.TestCase]] = [
        [] for _ in range(shard_count)
    ]
    partition_estimated_seconds = [0 for _ in range(shard_count)]

    for test in ordered_tests:
        test_id = test.id()
        method_name = _lifecycle_test_method_name(test)
        eligible = [
            index
            for index in range(shard_count)
            if len(partitions[index]) < capacities[index]
        ]
        if not eligible:
            raise RuntimeError(
                "Lifecycle duration partition exhausted shard capacity"
            )
        target = min(
            eligible,
            key=lambda index: (
                partition_estimated_seconds[index],
                len(partitions[index]),
                hashlib.sha256(
                    f"{method_name}\0{index}".encode("utf-8")
                ).hexdigest(),
            ),
        )
        partitions[target].append(test)
        partition_estimated_seconds[target] += estimated_by_id[test_id]

    for partition in partitions:
        partition.sort(key=lambda test: test.id())
    if sum(partition_estimated_seconds) != sum(estimated_by_id.values()):
        raise RuntimeError(
            "Lifecycle duration partition estimate accounting failed"
        )
    return partitions, partition_estimated_seconds, estimated_by_id


def _run_lifecycle_shard(shard_index: int, shard_count: int) -> int:
    if shard_count < 1:
        raise ValueError("--shard-count must be greater than zero")
    if shard_index < 0 or shard_index >= shard_count:
        raise ValueError("--shard-index must be within the shard count")

    loaded = unittest.defaultTestLoader.loadTestsFromTestCase(
        ForcedQrRuntimeTests
    )
    all_tests = _flatten_test_suite(loaded)
    all_ids = [test.id() for test in all_tests]
    if len(all_ids) != len(set(all_ids)):
        raise RuntimeError("Lifecycle test discovery produced duplicate IDs")

    (
        partitions,
        partition_estimated_seconds,
        estimated_by_id,
    ) = _partition_lifecycle_tests(all_tests, shard_count)

    partition_ids = [
        test.id() for partition in partitions for test in partition
    ]
    if (
        len(partition_ids) != len(all_ids)
        or len(partition_ids) != len(set(partition_ids))
        or set(partition_ids) != set(all_ids)
    ):
        raise RuntimeError(
            "Lifecycle shard partition is not a complete disjoint test set"
        )

    selected = partitions[shard_index]
    selected_ids = [test.id() for test in selected]
    partition_sizes = ",".join(str(len(partition)) for partition in partitions)
    partition_seconds = ",".join(
        str(seconds) for seconds in partition_estimated_seconds
    )
    print(
        "Lifecycle shard inventory: "
        f"index={shard_index} count={shard_count} total={len(all_tests)} "
        f"selected={len(selected)} partition_sizes={partition_sizes} "
        f"estimate_version={LIFECYCLE_SHARD_ESTIMATE_VERSION} "
        "selected_estimated_seconds="
        f"{partition_estimated_seconds[shard_index]} "
        f"partition_estimated_seconds={partition_seconds}",
        flush=True,
    )
    print(
        "Lifecycle shard partition validation: complete, disjoint, no omissions",
        flush=True,
    )
    print("Lifecycle shard test IDs:", flush=True)
    for test_id in selected_ids:
        print(
            f"{test_id} estimated_seconds={estimated_by_id[test_id]}",
            flush=True,
        )

    result = unittest.TextTestRunner(verbosity=2, failfast=True).run(
        unittest.TestSuite(selected)
    )
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    shard_options = {"--shard-index", "--shard-count"}
    has_shard_option = any(
        argument.split("=", 1)[0] in shard_options
        for argument in sys.argv[1:]
    )
    if has_shard_option:
        parser = argparse.ArgumentParser(
            description="Run one deterministic forced-QR lifecycle test shard."
        )
        parser.add_argument("--shard-index", type=int, required=True)
        parser.add_argument("--shard-count", type=int, required=True)
        arguments = parser.parse_args()
        try:
            exit_code = _run_lifecycle_shard(
                arguments.shard_index, arguments.shard_count
            )
        except (RuntimeError, ValueError) as error:
            parser.error(str(error))
        raise SystemExit(exit_code)
    unittest.main(verbosity=2)
