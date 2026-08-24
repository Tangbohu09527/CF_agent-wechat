#!/usr/bin/env python3
"""Static contracts for the production Gateway Compose invocation."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_HELPER = REPO_ROOT / "scripts" / "qr-runtime-common.sh"
START_SCRIPT = REPO_ROOT / "scripts" / "start-qr-login.sh"
CONTRACT_VERIFIER = REPO_ROOT / "scripts" / "verify_gateway_contract.py"
BOOTSTRAP_SCRIPT = REPO_ROOT / "scripts" / "bootstrap-cfserver.sh"
STATUS_SCRIPT = REPO_ROOT / "scripts" / "status.sh"
CONTRACT_DOCUMENT = (
    REPO_ROOT / "docs" / "contracts" / "gateway-wechat-runtime-contract.md"
)


class GatewayRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.content = RUNTIME_HELPER.read_text(encoding="utf-8")
        cls.start_content = START_SCRIPT.read_text(encoding="utf-8")
        cls.verifier_content = CONTRACT_VERIFIER.read_text(encoding="utf-8")
        cls.bootstrap_content = BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")
        cls.status_content = STATUS_SCRIPT.read_text(encoding="utf-8")

        cls.contract_document = CONTRACT_DOCUMENT.read_text(
            encoding="utf-8"
        )

    def test_default_gateway_deploy_paths_are_exact(self) -> None:
        expected = (
            'GATEWAY_COMPOSE_FILE="${CF_AGENT_GATEWAY_COMPOSE_FILE:'
            '-${GATEWAY_PROJECT_DIR}/docker-compose.prod.yml}"',
            'GATEWAY_PROJECT_DIR="${CF_AGENT_GATEWAY_PROJECT_DIR:'
            '-/opt/cf-agent-gateway}"',
            'GATEWAY_ENV_FILE="${CF_AGENT_GATEWAY_ENV_FILE:'
            '-${GATEWAY_PROJECT_DIR}/.env}"',
            'GATEWAY_HEARTBEAT_COMMAND="${GATEWAY_PROJECT_DIR}/'
            'deploy/check-wechat-worker-heartbeat"',
            'GATEWAY_RELEASE_GATE_COMMAND="${GATEWAY_PROJECT_DIR}/'
            'deploy/wechat-runtime-release-gate"',
            'GATEWAY_CONTRACT_FILE="${GATEWAY_PROJECT_DIR}/'
            'deploy/wechat-runtime-contract.json"',
            'GATEWAY_SERVICE="worker"',
            'GATEWAY_PROJECT_NAME="cf-agent-gateway"',
        )
        for fragment in expected:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.content)

    def test_gateway_compose_uses_the_validated_env_file(self) -> None:
        body = re.search(
            r"gateway_compose\(\) \{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(body)
        function = body.group("body")
        self.assertIn('sudo -n -- /usr/bin/env', function)
        self.assertIn('runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT"', function)
        self.assertEqual(function.count('--env-file "$GATEWAY_ENV_FILE"'), 1)
        self.assertEqual(
            function.count('--project-directory "$GATEWAY_PROJECT_DIR"'),
            1,
        )
        self.assertIn('--project-name "$GATEWAY_PROJECT_NAME"', function)
        self.assertIn("--profile worker", function)
        self.assertEqual(function.count("-f -"), 1)
        self.assertIn('"$GATEWAY_COMPOSE_SNAPSHOT"', function)
        self.assertIn("/usr/bin/base64 --decode", function)
        self.assertIn("runtime_compose_clean_env", function)

    def test_gateway_contract_gate_is_after_worker_stop(self) -> None:
        start = self.content[
            self.content.index("runtime_validate_configuration() {") :
            self.content.index("runtime_validate_stop_configuration() {")
        ]
        stop = self.content[self.content.index("runtime_validate_stop_configuration() {") :]
        verifier = re.search(
            r"runtime_verify_gateway_contract\(\) \{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(verifier)
        condition = (
            'if runtime_privileged test -L "$GATEWAY_ENV_FILE" ||\n'
            '    ! runtime_privileged test -f "$GATEWAY_ENV_FILE"; then'
        )
        self.assertNotIn("runtime_verify_gateway_contract", start)
        worker_stop = self.start_content.index(
            'FLOW_PHASE="stop_gateway_worker"'
        )
        contract_gate = self.start_content.index(
            'FLOW_PHASE="verify_gateway_contract"'
        )
        archive_gate = self.start_content.index('FLOW_PHASE="archive_preflight"')
        self.assertLess(worker_stop, contract_gate)
        self.assertLess(contract_gate, archive_gate)
        self.assertIn(condition, stop)
        self.assertIn(
            'runtime_validate_root_file "$GATEWAY_ENV_FILE"',
            verifier.group("body"),
        )
        self.assertIn(
            'runtime_validate_root_file "$TOKEN_FILE"',
            verifier.group("body"),
        )

    def test_worker_is_guarded_during_qr_and_at_every_release_boundary(
        self,
    ) -> None:
        strict = re.search(
            r"runtime_gateway_worker_is_strictly_stopped\(\) "
            r"\{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        guard = re.search(
            r"guard_gateway_worker_stopped\(\) \{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        pending_guard = re.search(
            r"guard_gateway_worker_and_generation_pending\(\) "
            r"\{(?P<body>.*?)\n\}",
            self.start_content,
            re.DOTALL,
        )
        prepare_worker = re.search(
            r"prepare_gateway_worker_candidate\(\) "
            r"\{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        start_worker = re.search(
            r"start_gateway_worker\(\) \{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        forced_login = re.search(
            r"run_forced_login\(\) \{(?P<body>.*?)\n\}",
            self.start_content,
            re.DOTALL,
        )
        for match in (
            strict,
            guard,
            pending_guard,
            prepare_worker,
            start_worker,
            forced_login,
        ):
            self.assertIsNotNone(match)

        self.assertIn("gateway_worker_state", strict.group("body"))
        self.assertIn(
            "runtime_gateway_worker_running_ids_by_label",
            strict.group("body"),
        )
        self.assertIn("stop_gateway_worker", guard.group("body"))
        self.assertIn("fresh QR flow was aborted", guard.group("body"))
        self.assertIn(
            "guard_gateway_worker_stopped", pending_guard.group("body")
        )
        self.assertIn(
            "runtime_gateway_gate_assert_pending", pending_guard.group("body")
        )

        login_body = forced_login.group("body")
        self.assertIn(
            '"${LOGIN_PYTHON_COMMAND[@]}" "${login_arguments[@]}" &',
            login_body,
        )
        self.assertIn('while kill -0 "$login_pid"', login_body)
        self.assertIn('kill "$login_pid"', login_body)
        self.assertIn('QR_LOGIN_HELPER_PID="$login_pid"', login_body)
        self.assertIn('kill "$QR_LOGIN_HELPER_PID"', self.start_content)
        self.assertIn('wait "$QR_LOGIN_HELPER_PID"', self.start_content)
        self.assertGreaterEqual(
            login_body.count("guard_gateway_worker_and_generation_pending"), 4
        )

        prepare_body = prepare_worker.group("body")
        self.assertLess(
            prepare_body.index("guard_gateway_worker_stopped"),
            prepare_body.index("gateway_compose create"),
        )
        start_body = start_worker.group("body")
        self.assertLess(
            start_body.index("GATEWAY_GATE_RELEASED"),
            start_body.index(
                'runtime_attest_gateway_worker_container created "$expected_id"'
            ),
        )
        self.assertLess(
            start_body.index(
                'runtime_attest_gateway_worker_container created "$expected_id"'
            ),
            start_body.index("gateway_compose start"),
        )
        phases = (
            "guard_worker_before_archive",
            "guard_worker_before_agent_start",
            "guard_worker_before_qr",
            "guard_worker_before_runtime_validation",
            "guard_worker_before_final_attestation",
            "guard_worker_before_gateway_release",
            "guard_worker_at_release",
        )
        positions = [self.start_content.index(phase) for phase in phases]
        self.assertEqual(positions, sorted(positions))

    def test_shell_supplies_producer_pins_and_rendered_compose_stdin(self) -> None:
        verifier = re.search(
            r"runtime_verify_gateway_contract\(\) \{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        runner = re.search(
            r"runtime_execute_gateway_contract_verifier\(\) "
            r"\{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(verifier)
        self.assertIsNotNone(runner)
        function = verifier.group("body")
        runner_function = runner.group("body")
        self.assertIn(
            '--producer-repository "$GATEWAY_PRODUCER_REPOSITORY"',
            runner_function,
        )
        self.assertIn('checker_sha="$GATEWAY_CHECKER_SHA256"', function)
        self.assertIn('--checker-sha256 "$checker_sha"', runner_function)
        self.assertIn('--gate "$GATEWAY_RELEASE_GATE_COMMAND"', runner_function)
        self.assertIn('--gate-sha256 "$gate_sha"', runner_function)
        self.assertIn("gateway_compose config --format json", function)
        self.assertIn("runtime_execute_gateway_contract_verifier \\", function)
        self.assertIn('"$checker_sha" "$gate_sha" compose', function)
        for fragment in (
            '"producer"',
            '"checkerSha256"',
            '"releaseGateSha256"',
            '"checkerRequest"',
            '"releaseGate"',
            '"tokenAuthority"',
            '"credential"',
            'choices=("compose", "worker-inspect")',
        ):
            self.assertIn(fragment, self.verifier_content)

    def test_verifier_requires_explicit_release_gate_pins(self) -> None:
        for fragment in (
            'parser.add_argument("--gate", required=True)',
            'parser.add_argument("--gate-sha256", required=True)',
            'arguments.gate_sha256',
            '"releaseGateSha256"',
            '"command": arguments.gate',
            '"inputTransport": "stdin-json"',
            '"generationId": "lowercase-hex-64"',
            '"workerContainerBinding": "exact-stopped-candidate"',
            '"requiresExactCurrentRelease": True',
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.verifier_content)

    def test_contract_pins_credential_checker_and_boot_policy(
        self,
    ) -> None:
        verifier_fragments = (
            '"workerReadabilityProof": "producer-linux-integration"',
            '"caller": "management-user"',
            '"sudo": False',
            '"dockerSocketAccess": False',
            '"producerLinuxProof": "required"',
            '"restartPolicy": "no"',
            '"bootPolicy": "manual-after-fresh-qr"',
            '"releaseGateSha256"',
            '"checkerRequest"',
            '"releaseGate"',
            '"hardTimeoutSeconds": 10',
            '"silentOutput": True',
            '"assert-pending"',
            '"invalidatesPreviousReleases": True',
            'service.get("restart") != "no"',
            'restart_policy.get("Name") != "no"',
            'restart_policy.get("MaximumRetryCount") != 0',
        )
        for fragment in verifier_fragments:
            with self.subTest(source="verifier", fragment=fragment):
                self.assertIn(fragment, self.verifier_content)

        document_fragments = (
            "root:root 0600 的 host bind",
            "workerReadabilityProof=producer-linux-integration",
            "不得把 Worker 常驻身份提升为 root",
            "checkerExecution",
            "不得 sudo",
            "不得要求该用户可读 Docker socket",
            "requiresDockerHealth=true",
            "lifecycle.restartPolicy=no",
            "HostConfig.RestartPolicy",
            "bootPolicy=manual-after-fresh-qr",
            "producer-enforced generation/release",
            "releaseGateSha256",
            "wechat-runtime-release-gate",
            "assert-pending",
            "exact-stopped-candidate",
            "checkerRequest",
            "stdin JSON",
            "stale release",
            "Docker daemon restart 与 Debian reboot",
            "Docker Swarm",
            "Kubernetes",
            "CFserver 人工审计 pending",
            "BLOCKED BY GATEWAY CONTRACT",
        )
        for fragment in document_fragments:
            with self.subTest(source="document", fragment=fragment):
                self.assertIn(fragment, self.contract_document)

    def test_bootstrap_and_runtime_gateway_pins_are_identical(self) -> None:
        names = (
            "GATEWAY_HEARTBEAT_MAX_AGE",
            "GATEWAY_PRODUCER_REPOSITORY",
            "GATEWAY_COMPATIBLE_COMMIT",
            "GATEWAY_CHECKER_SHA256",
            "GATEWAY_RELEASE_GATE_SHA256",
        )
        for name in names:
            pattern = rf'^{name}=(?:"([^"]*)"|([0-9]+))$'
            runtime_match = re.search(pattern, self.content, re.MULTILINE)
            bootstrap_match = re.search(
                pattern, self.bootstrap_content, re.MULTILINE
            )
            with self.subTest(name=name):
                self.assertIsNotNone(runtime_match)
                self.assertIsNotNone(bootstrap_match)
                self.assertEqual(
                    next(
                        value for value in runtime_match.groups()
                        if value is not None
                    ),
                    next(
                        value for value in bootstrap_match.groups()
                        if value is not None
                    ),
                )

        compatible_commit = re.search(
            r'^GATEWAY_COMPATIBLE_COMMIT="([^"]*)"',
            self.content,
            re.MULTILINE,
        )
        self.assertIsNotNone(compatible_commit)
        self.assertEqual(
            compatible_commit.group(1),
            "",
            "remove this blocker only with a published Gateway contract",
        )

    def test_gateway_git_allows_only_the_exact_validated_checkout(self) -> None:
        wrappers = (
            ("runtime", self.content, "runtime_gateway_git"),
            ("bootstrap", self.bootstrap_content, "bootstrap_gateway_git"),
        )
        for name, content, function_name in wrappers:
            body = re.search(
                rf"{function_name}\(\) \{{(?P<body>.*?)\n\}}",
                content,
                re.DOTALL,
            )
            with self.subTest(entrypoint=name):
                self.assertIsNotNone(body)
                function = body.group("body")
                for fragment in (
                    "GIT_CONFIG_NOSYSTEM=1",
                    "GIT_CONFIG_GLOBAL=/dev/null",
                    "GIT_NO_REPLACE_OBJECTS=1",
                    "GIT_ATTR_NOSYSTEM=1",
                    "GIT_LITERAL_PATHSPECS=1",
                    'GIT_OPTIONAL_LOCKS=0',
                    '-c "safe.directory=$GATEWAY_PROJECT_DIR"',
                    "-c core.fsmonitor=false",
                    "-c core.untrackedCache=false",
                    "-c core.hooksPath=/dev/null",
                    "-c core.fileMode=true",
                    "-c core.symlinks=true",
                    "-c diff.ignoreSubmodules=none",
                    '-C "$GATEWAY_PROJECT_DIR"',
                ):
                    self.assertIn(fragment, function)
                self.assertNotIn("safe.directory=*", function)

        attestations = (
            (
                "runtime",
                self.content,
                "runtime_attest_gateway_checkout",
                'runtime_attest_gateway_checkout '
                '"$GATEWAY_COMPATIBLE_COMMIT"',
            ),
            (
                "bootstrap",
                self.bootstrap_content,
                "bootstrap_attest_gateway_checkout",
                'bootstrap_attest_gateway_checkout '
                '"$GATEWAY_COMPATIBLE_COMMIT"',
            ),
        )
        for name, content, function_name, invocation in attestations:
            body = re.search(
                rf"{function_name}\(\) \{{(?P<body>.*?)\n\}}",
                content,
                re.DOTALL,
            )
            with self.subTest(attestation=name):
                self.assertIsNotNone(body)
                function = body.group("body")
                for fragment in (
                    "rev-parse --show-toplevel",
                    "rev-parse --absolute-git-dir",
                    "config --local --no-includes",
                    "--get-regexp",
                    "--get-all remote.origin.url",
                    "ls-files -v --",
                    "diff-index --cached --quiet",
                    "diff-files --quiet",
                    "--ignore-submodules=none",
                    "ls-files --others",
                    "--directory --no-empty-directory",
                    'GATEWAY_ENV_FILE',
                    '".env"',
                ):
                    self.assertIn(fragment, function)
                self.assertNotIn("remote get-url", function)
                self.assertNotIn("--exclude-standard", function)
                self.assertIn(invocation, content)

    def test_heartbeat_checker_uses_digest_bound_snapshot_without_sudo(
        self,
    ) -> None:
        body = re.search(
            r"gateway_worker_heartbeat_is_healthy\(\) \{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(body)
        function = body.group("body")
        self.assertIn(
            'runtime_gateway_checker_snapshot \\',
            function,
        )
        self.assertIn(
            '"$GATEWAY_RUNTIME_COMMAND_TIMEOUT" execute',
            function,
        )
        self.assertIn("runtime_gateway_write_request checker", function)
        self.assertIn('"$checker_sha" stdin-json', function)
        self.assertIn("runtime_capture_gateway_checker_digest", function)
        self.assertNotIn('"$GATEWAY_HEARTBEAT_COMMAND"', function)
        self.assertNotIn("runtime_privileged", function)
        self.assertNotIn("sudo", function)

    def test_checker_snapshot_is_sealed_and_cwd_is_fixed(self) -> None:
        loader = re.search(
            r"GATEWAY_CHECKER_SNAPSHOT_LOADER <<'PYTHON' \|\| :\n"
            r"(?P<body>.*?)\nPYTHON\n"
            r"readonly GATEWAY_CHECKER_SNAPSHOT_LOADER",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(loader)
        compile(
            loader.group("body"),
            "GATEWAY_CHECKER_SNAPSHOT_LOADER",
            "exec",
        )
        for fragment in (
            "O_NOFOLLOW",
            "st_nlink != 1",
            "MAX_SOURCE_BYTES",
            "metadata_signature(final)",
            "metadata_signature(visible)",
            "hmac.compare_digest(digest, expected_digest)",
            "os.memfd_create(",
            "os.O_DIRECTORY",
            "fcntl.F_ADD_SEALS",
            "fcntl.F_SEAL_WRITE",
            "os.set_inheritable(executable_descriptor, True)",
            "os.fchdir(directory_descriptor)",
            'f"/proc/self/fd/{executable_descriptor}"',
            "stdout=subprocess.PIPE",
            "stderr=subprocess.STDOUT",
            "start_new_session=True",
            "os.read(output_descriptor, 1)",
            "os.killpg(child.pid, signal.SIGTERM)",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.content)

        runner = re.search(
            r"runtime_gateway_checker_snapshot\(\) \{"
            r"(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(runner)
        runner_body = runner.group("body")
        executor = re.search(
            r"runtime_gateway_executable_snapshot\(\) \{"
            r"(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(executor)
        executor_body = executor.group("body")
        self.assertIn("runtime_gateway_executable_snapshot", runner_body)
        self.assertIn(
            'checker "$GATEWAY_HEARTBEAT_COMMAND"', runner_body
        )
        self.assertIn('"$GATEWAY_PROJECT_DIR"', executor_body)
        self.assertIn("/usr/bin/env -i", executor_body)
        self.assertIn('"$PYTHON_BIN" -I -c', executor_body)
        self.assertNotIn("runtime_privileged", runner_body)
        self.assertNotIn("sudo", runner_body)

        heartbeat = re.search(
            r"gateway_worker_heartbeat_is_healthy\(\) \{"
            r"(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(heartbeat)
        heartbeat_body = heartbeat.group("body")
        self.assertNotIn("mktemp", heartbeat_body)
        self.assertNotIn("checker_output_file", heartbeat_body)
        self.assertNotIn("/proc/self/fd/", heartbeat_body)

        provenance = re.search(
            r"runtime_verify_gateway_provenance\(\) \{"
            r"(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(provenance)
        self.assertIn(
            "runtime_capture_gateway_checker_digest",
            provenance.group("body"),
        )
        self.assertNotIn(
            'sha256sum -- "$GATEWAY_HEARTBEAT_COMMAND"',
            self.content,
        )

    def test_checker_replacement_hook_is_testing_only(self) -> None:
        loader_start = self.content.index(
            "GATEWAY_CHECKER_SNAPSHOT_LOADER <<'PYTHON'"
        )
        loader_end = self.content.index(
            "readonly GATEWAY_CHECKER_SNAPSHOT_LOADER"
        )
        loader = self.content[loader_start:loader_end]
        testing_gate = loader.index(
            'os.environ.get("CF_AGENT_WECHAT_TESTING") == "1"'
        )
        replacement = loader.index(
            "CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT"
        )
        self.assertLess(testing_gate, replacement)

    def test_every_worker_start_failure_has_immediate_rollback(self) -> None:
        start = re.search(
            r"start_gateway_worker\(\) \{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(start)
        body = start.group("body")
        rollback_call = (
            'rollback_gateway_worker_after_start_failure "$original_error"'
        )
        failure_assignments = list(
            re.finditer(r"^    original_error=", body, re.MULTILINE)
        )
        self.assertEqual(len(failure_assignments), 8)
        self.assertEqual(body.count(rollback_call), len(failure_assignments))
        for index, assignment in enumerate(failure_assignments):
            branch_end = body.find("    return 1", assignment.start())
            with self.subTest(failure_branch=index + 1):
                self.assertNotEqual(branch_end, -1)
                branch = body[assignment.start():branch_end]
                self.assertIn(
                    rollback_call,
                    branch,
                    "each Worker start failure must rollback immediately",
                )
        for gate in (
            "gateway_compose start",
            "gateway_worker_state",
            "runtime_verify_gateway_contract",
            "runtime_attest_gateway_worker_container",
            "wait_for_gateway_worker_health",
        ):
            with self.subTest(gate=gate):
                self.assertIn(gate, body)

        rollback = re.search(
            r"rollback_gateway_worker_after_start_failure\(\) \{"
            r"(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(rollback)
        rollback_body = rollback.group("body")
        self.assertIn("stop_gateway_worker", rollback_body)
        self.assertIn('WORKER_STOP_CONFIRMED=1', rollback_body)
        self.assertIn('WORKER_STOP_CONFIRMED=0', rollback_body)
    def test_gateway_verifier_is_protected_and_snapshot_executed(self) -> None:
        for fragment in (
            "O_NOFOLLOW",
            "st_nlink != 1",
            "MAX_SOURCE_BYTES",
            "metadata_signature(final)",
            "metadata_signature(visible)",
            "hmac.compare_digest(digest, expected_digest)",
            "compile(source, path, \"exec\")",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.content)

        self.assertIn(
            '"$GATEWAY_CONTRACT_VERIFIER" "Gateway contract verifier"',
            self.content,
        )
        self.assertIn(
            '"$GATEWAY_CONTRACT_VERIFIER" "Gateway contract verifier"',
            self.status_content,
        )
        verifier_calls = re.findall(
            r"runtime_execute_gateway_contract_verifier \\\n"
            r'\s+"\$checker_sha" "\$gate_sha" '
            r"(compose|worker-inspect)",
            self.content,
        )
        self.assertCountEqual(verifier_calls, ("compose", "worker-inspect"))
        self.assertNotIn(
            '"$PYTHON_BIN" -I "$GATEWAY_CONTRACT_VERIFIER"',
            self.content,
        )
        runtime_loader = re.search(
            r"GATEWAY_VERIFIER_SNAPSHOT_LOADER <<'PYTHON' \|\| :\n"
            r"(?P<body>.*?)\nPYTHON\n"
            r"readonly GATEWAY_VERIFIER_SNAPSHOT_LOADER",
            self.content,
            re.DOTALL,
        )
        bootstrap_loader = re.search(
            r"GATEWAY_VERIFIER_SNAPSHOT_LOADER <<'PYTHON' \|\| :\n"
            r"(?P<body>.*?)\nPYTHON\n"
            r"readonly GATEWAY_VERIFIER_SNAPSHOT_LOADER",
            self.bootstrap_content,
            re.DOTALL,
        )
        self.assertIsNotNone(runtime_loader)
        self.assertIsNotNone(bootstrap_loader)
        for name, loader in (
            ("runtime", runtime_loader),
            ("bootstrap", bootstrap_loader),
        ):
            body = loader.group("body")
            compile(body, f"{name.upper()}_GATEWAY_VERIFIER_LOADER", "exec")
            for fragment in (
                "O_NOFOLLOW",
                "st_nlink != 1",
                "MAX_SOURCE_BYTES",
                "metadata_signature(final)",
                "metadata_signature(visible)",
                "hmac.compare_digest(digest, expected_digest)",
                'compile(source, path, "exec")',
            ):
                with self.subTest(loader=name, fragment=fragment):
                    self.assertIn(fragment, body)
        self.assertIn(
            "CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT",
            runtime_loader.group("body"),
        )
        self.assertNotIn(
            "CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT",
            bootstrap_loader.group("body"),
        )
        self.assertIn(
            "bootstrap_capture_gateway_verifier_digest",
            self.bootstrap_content,
        )
        self.assertIn(
            'bootstrap_gateway_verifier_snapshot execute "$verifier_digest"',
            self.bootstrap_content,
        )
        self.assertNotIn(
            '/usr/bin/python3 -I "$GATEWAY_CONTRACT_VERIFIER"',
            self.bootstrap_content,
        )

    def test_verifier_replacement_hook_is_testing_only(self) -> None:
        function = self.content[
            self.content.index("runtime_gateway_verifier_snapshot() {") :
            self.content.index("runtime_capture_gateway_verifier_digest() {")
        ]
        testing_gate = function.index(
            'if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then'
        )
        execute_gate = function.index('if [ "$mode" = "execute" ]; then')
        replacement = function.index(
            "CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT"
        )
        self.assertLess(testing_gate, execute_gate)
        self.assertLess(execute_gate, replacement)


@unittest.skipUnless(
    shutil.which("git") and shutil.which("bash"),
    "dynamic Gateway provenance tests require Git and Bash",
)
class GatewayCheckoutProvenanceTests(unittest.TestCase):
    PRODUCER = "Tangbohu09527/CF_agent-gateway"
    APPROVED_ORIGIN = "https://github.com/Tangbohu09527/CF_agent-gateway.git"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.project = self.root / "gateway"
        self.project.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.name", "Gateway Contract Test")
        self.git("config", "user.email", "gateway-contract@example.invalid")
        self.git("config", "core.autocrlf", "false")
        self.git("remote", "add", "origin", self.APPROVED_ORIGIN)

        (self.project / "deploy").mkdir()
        (self.project / "src").mkdir()
        (self.project / ".gitignore").write_text(
            ".env\nignored/\n",
            encoding="utf-8",
        )
        (self.project / ".env").write_text(
            "GATEWAY_MODE=production\n",
            encoding="utf-8",
        )
        (self.project / "docker-compose.prod.yml").write_text(
            "services: {}\n",
            encoding="utf-8",
        )
        (self.project / "deploy" / "wechat-runtime-contract.json").write_text(
            "{}\n",
            encoding="utf-8",
        )
        checker = (
            self.project / "deploy" / "check-wechat-worker-heartbeat"
        )
        checker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        checker.chmod(0o755)
        (self.project / "src" / "helper.py").write_text(
            "VALUE = 1\n",
            encoding="utf-8",
        )
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "approved")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(
        self,
        *arguments: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [shutil.which("git") or "git", "-C", str(self.project), *arguments],
            check=check,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def run_attestation(
        self,
        *,
        project: Path | None = None,
        extra_environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        selected_project = project or self.project
        environment = os.environ.copy()
        environment["CF_AGENT_WECHAT_TESTING"] = "1"
        if extra_environment:
            environment.update(extra_environment)
        script = r"""
set -uo pipefail
source "$1"
GATEWAY_PROJECT_DIR="$2"
GATEWAY_ENV_FILE="$2/.env"
GATEWAY_PRODUCER_REPOSITORY="$3"
DOCKER_COMMAND_TIMEOUT=5
if runtime_attest_gateway_checkout "$4"; then
  exit 0
fi
printf '%s\n' "$LAST_ERROR" >&2
exit 1
"""
        return subprocess.run(
            [
                shutil.which("bash") or "bash",
                "-c",
                script,
                "gateway-checkout-provenance-test",
                str(RUNTIME_HELPER),
                selected_project.as_posix(),
                self.PRODUCER,
                self.commit,
            ],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
            timeout=20,
        )

    def assert_rejected(
        self,
        completed: subprocess.CompletedProcess[str],
        error_fragment: str,
    ) -> None:
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        combined = completed.stdout + completed.stderr
        self.assertIn(error_fragment, combined)
        self.assertNotIn(str(self.project), combined)
        self.assertNotIn("helper.py", combined)
        self.assertNotIn("ignored-secret", combined)

    def test_clean_checkout_and_scrubbed_host_git_environment_pass(self) -> None:
        completed = self.run_attestation(
            extra_environment={
                "GIT_DIR": str(self.root / "attacker.git"),
                "GIT_WORK_TREE": str(self.root / "attacker-worktree"),
                "GIT_INDEX_FILE": str(self.root / "attacker-index"),
                "GIT_OBJECT_DIRECTORY": str(self.root / "attacker-objects"),
                "GIT_CONFIG_GLOBAL": str(self.root / "attacker-config"),
            }
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, "")

    def test_staged_unstaged_and_deleted_tracked_files_are_rejected(self) -> None:
        helper = self.project / "src" / "helper.py"

        helper.write_text("VALUE = 2\n", encoding="utf-8")
        self.assert_rejected(self.run_attestation(), "tracked worktree")
        self.git("restore", "--worktree", "src/helper.py")

        helper.write_text("VALUE = 3\n", encoding="utf-8")
        self.git("add", "src/helper.py")
        self.assert_rejected(self.run_attestation(), "tracked worktree")
        self.git("restore", "--staged", "--worktree", "src/helper.py")

        helper.unlink()
        self.assert_rejected(self.run_attestation(), "tracked worktree")


    def test_only_validated_top_level_env_may_be_untracked(self) -> None:
        ordinary = self.project / "unexpected.py"
        ordinary.write_text("UNEXPECTED = True\n", encoding="utf-8")
        self.assert_rejected(
            self.run_attestation(),
            "outside the validated environment allowlist",
        )
        ordinary.unlink()

        ignored = self.project / "ignored"
        ignored.mkdir()
        (ignored / "ignored-secret.txt").write_text(
            "not-a-real-secret\n",
            encoding="utf-8",
        )
        self.assert_rejected(
            self.run_attestation(),
            "outside the validated environment allowlist",
        )

    def test_assume_unchanged_and_skip_worktree_are_rejected(self) -> None:
        self.git("update-index", "--assume-unchanged", "src/helper.py")
        self.assert_rejected(self.run_attestation(), "hidden worktree state")
        self.git("update-index", "--no-assume-unchanged", "src/helper.py")

        self.git("update-index", "--skip-worktree", "src/helper.py")
        self.assert_rejected(self.run_attestation(), "hidden worktree state")
        self.git("update-index", "--no-skip-worktree", "src/helper.py")

    def test_include_and_url_rewrite_cannot_forge_origin(self) -> None:
        included = self.root / "included-git-config"
        included.write_text("[core]\n\tfilemode = false\n", encoding="utf-8")
        self.git("config", "include.path", included.as_posix())
        self.assert_rejected(
            self.run_attestation(),
            "forbidden local Git configuration",
        )
        self.git("config", "--unset-all", "include.path")

        attacker_origin = "attacker://gateway"
        self.git("remote", "set-url", "origin", attacker_origin)
        rewrite_key = f"url.{self.APPROVED_ORIGIN}.insteadOf"
        self.git("config", rewrite_key, attacker_origin)
        self.assertEqual(
            self.git("remote", "get-url", "origin").stdout.strip(),
            self.APPROVED_ORIGIN,
            "the fixture must prove porcelain remote output is rewritten",
        )
        self.assert_rejected(
            self.run_attestation(),
            "forbidden local Git configuration",
        )

    def test_local_config_cannot_hide_dirty_submodule(self) -> None:
        git_bin = shutil.which("git") or "git"
        submodule_source = self.root / "submodule-source"
        submodule_source.mkdir()

        def submodule_git(*arguments: str) -> None:
            subprocess.run(
                [git_bin, "-C", str(submodule_source), *arguments],
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            )

        submodule_git("init", "--quiet")
        submodule_git("config", "user.name", "Gateway Contract Test")
        submodule_git(
            "config",
            "user.email",
            "gateway-contract@example.invalid",
        )
        tracked = submodule_source / "tracked.txt"
        tracked.write_text("approved\n", encoding="utf-8")
        submodule_git("add", "tracked.txt")
        submodule_git("commit", "--quiet", "-m", "approved")

        self.git(
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "--quiet",
            str(submodule_source),
            "vendor/dependency",
        )
        self.git("commit", "--quiet", "-m", "add approved submodule")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("config", "diff.ignoreSubmodules", "all")

        dependency = self.project / "vendor" / "dependency" / "tracked.txt"
        dependency.write_text("modified\n", encoding="utf-8")
        dirty = subprocess.run(
            [git_bin, "-C", str(dependency.parent), "diff-files", "--quiet"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertNotEqual(dirty.returncode, 0)
        self.assert_rejected(self.run_attestation(), "tracked worktree")
    def test_local_fsmonitor_hook_is_never_executed(self) -> None:
        marker = self.root / "fsmonitor-executed"
        hook = self.root / "fsmonitor-hook.sh"
        hook.write_text(
            "#!/bin/sh\n"
            f"printf executed > {marker.as_posix()!r}\n"
            "exit 1\n",
            encoding="utf-8",
        )
        hook.chmod(0o755)
        self.git("config", "core.fsmonitor", hook.as_posix())

        completed = self.run_attestation()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(marker.exists())

    def test_parent_discovery_and_gitfile_metadata_are_rejected(self) -> None:
        nested = self.project / "nested"
        nested.mkdir()
        (nested / ".env").write_text("MODE=test\n", encoding="utf-8")
        self.assert_rejected(
            self.run_attestation(project=nested),
            "exact non-symlink Git directory",
        )

        linked = self.root / "linked-checkout"
        linked.mkdir()
        (linked / ".env").write_text("MODE=test\n", encoding="utf-8")
        (linked / ".git").write_text(
            f"gitdir: {(self.project / '.git').as_posix()}\n",
            encoding="utf-8",
        )
        self.assert_rejected(
            self.run_attestation(project=linked),
            "exact non-symlink Git directory",
        )



    @unittest.skipUnless(
        os.name == "posix" and shutil.which("sudo"),
        "root-owned checkout test requires Linux sudo",
    )
    def test_non_root_user_can_attest_exact_root_owned_checkout(self) -> None:
        sudo = shutil.which("sudo") or "sudo"
        probe = subprocess.run(
            [sudo, "-n", "true"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if probe.returncode != 0:
            self.skipTest("passwordless sudo is unavailable")

        owner = f"{os.getuid()}:{os.getgid()}"
        subprocess.run(
            [sudo, "-n", "chown", "-R", "root:root", str(self.project)],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        subprocess.run(
            [
                sudo,
                "-n",
                shutil.which("git") or "git",
                "-c",
                f"safe.directory={self.project}",
                "-C",
                str(self.project),
                "update-index",
                "--refresh",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        try:
            plain_environment = {
                "HOME": "/nonexistent",
                "PATH": os.environ.get("PATH", ""),
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
            }
            plain = subprocess.run(
                [
                    shutil.which("git") or "git",
                    "-C",
                    str(self.project),
                    "rev-parse",
                    "--verify",
                    "HEAD",
                ],
                check=False,
                capture_output=True,
                env=plain_environment,
                text=True,
                timeout=10,
            )
            self.assertNotEqual(
                plain.returncode,
                0,
                "plain Git must retain dubious-ownership protection",
            )

            completed = self.run_attestation()
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout, "")
            self.assertEqual(completed.stderr, "")
        finally:
            subprocess.run(
                [sudo, "-n", "chown", "-R", owner, str(self.project)],
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            )


@unittest.skipUnless(
    os.name == "posix"
    and shutil.which("bash")
    and Path("/usr/bin/timeout").is_file()
    and hasattr(os, "O_NOFOLLOW"),
    "Gateway verifier snapshot tests require Linux O_NOFOLLOW support",
)
class GatewayVerifierSnapshotTests(unittest.TestCase):
    TOKEN = "f" * 64

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.verifier = self.root / "verify_gateway_contract.py"
        self.replacement = self.root / "replacement.py"
        self.marker = self.root / "executed.marker"
        self.write_verifier(self.verifier, "approved", include_token=False)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_verifier(
        self,
        path: Path,
        marker_value: str,
        *,
        include_token: bool,
    ) -> None:
        token_output = (
            f'print("{self.TOKEN}")\n'
            if include_token
            else ""
        )
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib\n"
            "import sys\n"
            f"{token_output}"
            "pathlib.Path(sys.argv[1]).write_text("
            f'"{marker_value}", encoding="utf-8")\n',
            encoding="utf-8",
        )
        path.chmod(0o755)

    def run_snapshot(
        self,
        action: str,
        verifier: Path,
        *,
        replacement: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["CF_AGENT_WECHAT_TESTING"] = "1"
        environment["CF_AGENT_WECHAT_TEST_ROOT"] = str(self.root)
        if replacement is not None:
            environment[
                "CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT"
            ] = str(replacement)
        script = r"""
set -uo pipefail
source "$1/scripts/common.sh"
source "$1/scripts/qr-runtime-common.sh"
runtime_privileged() {
  "$@"
}
GATEWAY_CONTRACT_VERIFIER="$2"
PYTHON_BIN="$3"
DOCKER_COMMAND_TIMEOUT=5
case "$4" in
  digest)
    runtime_capture_gateway_verifier_digest
    ;;
  execute)
    digest="$(runtime_capture_gateway_verifier_digest)" || exit 1
    runtime_gateway_verifier_snapshot execute "$digest" "$5"
    ;;
  *)
    exit 2
    ;;
esac
"""
        return subprocess.run(
            [
                "bash",
                "-c",
                script,
                "gateway-verifier-snapshot-test",
                str(REPO_ROOT),
                str(verifier),
                sys.executable,
                action,
                str(self.marker),
            ],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
            timeout=10,
        )

    def assert_redacted_failure(
        self,
        completed: subprocess.CompletedProcess[str],
    ) -> None:
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        combined = completed.stdout + completed.stderr
        self.assertNotIn(self.TOKEN, combined)
        self.assertFalse(self.marker.exists())

    def test_approved_snapshot_executes(self) -> None:
        completed = self.run_snapshot("execute", self.verifier)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.marker.read_text(encoding="utf-8"), "approved")
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, "")

    def test_symlink_and_hardlink_are_rejected(self) -> None:
        symlink = self.root / f"verifier-{self.TOKEN}"
        symlink.symlink_to(self.verifier)
        self.assert_redacted_failure(
            self.run_snapshot("digest", symlink)
        )

        hardlink = self.root / "verifier-hardlink.py"
        os.link(self.verifier, hardlink)
        self.assert_redacted_failure(
            self.run_snapshot("digest", hardlink)
        )

    def test_oversize_verifier_is_rejected(self) -> None:
        oversized = self.root / "oversized.py"
        oversized.write_bytes(b"x" * (1024 * 1024 + 1))
        oversized.chmod(0o755)
        self.assert_redacted_failure(
            self.run_snapshot("digest", oversized)
        )

    def test_replacement_after_lstat_is_never_executed(self) -> None:
        self.write_verifier(
            self.replacement,
            "replacement",
            include_token=True,
        )
        completed = self.run_snapshot(
            "execute",
            self.verifier,
            replacement=self.replacement,
        )
        self.assert_redacted_failure(completed)
        self.assertIn(
            "Gateway verifier snapshot validation failed.",
            completed.stderr,
        )


@unittest.skipUnless(
    os.name == "posix"
    and shutil.which("bash")
    and Path("/usr/bin/timeout").is_file()
    and Path("/proc/self/fd").is_dir()
    and hasattr(os, "O_NOFOLLOW")
    and hasattr(os, "memfd_create"),
    "Gateway checker snapshot tests require Linux memfd execution",
)
class GatewayCheckerSnapshotTests(unittest.TestCase):
    TOKEN = "e" * 64

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.project = self.root / "gateway"
        self.project.mkdir()
        self.checker = self.project / "check-wechat-worker-heartbeat"
        self.replacement = self.root / "replacement-checker"
        self.marker = self.root / "executed.marker"
        self.write_checker(self.checker, "approved", include_token=False)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_checker(
        self,
        path: Path,
        marker_value: str,
        *,
        include_token: bool,
    ) -> None:
        token_output = (
            f'printf "%s\\n" "{self.TOKEN}"\n'
            if include_token
            else ""
        )
        path.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            f"{token_output}"
            f'printf "%s:%s" "{marker_value}" "$PWD" '
            '>"$CHECKER_MARKER"\n',
            encoding="utf-8",
        )
        path.chmod(0o755)

    def run_snapshot(
        self,
        action: str,
        checker: Path,
        *,
        replacement: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["CF_AGENT_WECHAT_TESTING"] = "1"
        environment["CF_AGENT_WECHAT_TEST_ROOT"] = str(self.root)
        environment["CHECKER_MARKER"] = str(self.marker)
        if replacement is not None:
            environment[
                "CF_AGENT_WECHAT_TEST_GATEWAY_CHECKER_REPLACEMENT"
            ] = str(replacement)
        script = r"""
set -uo pipefail
source "$1/scripts/common.sh"
source "$1/scripts/qr-runtime-common.sh"
GATEWAY_HEARTBEAT_COMMAND="$2"
GATEWAY_PROJECT_DIR="$3"
PYTHON_BIN="$4"
DOCKER_COMMAND_TIMEOUT=5
case "$5" in
  digest)
    runtime_capture_gateway_checker_digest
    ;;
  execute)
    digest="$(runtime_capture_gateway_checker_digest)" || exit 1
    runtime_gateway_checker_snapshot 5 execute "$digest" none
    ;;
  *)
    exit 2
    ;;
esac
"""
        return subprocess.run(
            [
                "bash",
                "-c",
                script,
                "gateway-checker-snapshot-test",
                str(REPO_ROOT),
                str(checker),
                str(self.project),
                sys.executable,
                action,
            ],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
            timeout=10,
        )

    def assert_redacted_failure(
        self,
        completed: subprocess.CompletedProcess[str],
    ) -> None:
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assertNotIn(
            self.TOKEN,
            completed.stdout + completed.stderr,
        )
        self.assertFalse(self.marker.exists())

    def test_approved_sealed_snapshot_executes_from_fixed_cwd(self) -> None:
        completed = self.run_snapshot("execute", self.checker)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            self.marker.read_text(encoding="utf-8"),
            f"approved:{self.project}",
        )
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, "")

    def test_symlink_hardlink_and_oversize_are_rejected(self) -> None:
        symlink = self.root / f"checker-{self.TOKEN}"
        symlink.symlink_to(self.checker)
        self.assert_redacted_failure(
            self.run_snapshot("digest", symlink)
        )

        hardlink = self.root / "checker-hardlink"
        os.link(self.checker, hardlink)
        self.assert_redacted_failure(
            self.run_snapshot("digest", hardlink)
        )

        oversized = self.root / "checker-oversized"
        oversized.write_bytes(b"x" * (1024 * 1024 + 1))
        oversized.chmod(0o755)
        self.assert_redacted_failure(
            self.run_snapshot("digest", oversized)
        )

    def test_replacement_after_lstat_never_executes_or_leaks(self) -> None:
        self.write_checker(
            self.replacement,
            "replacement",
            include_token=True,
        )
        completed = self.run_snapshot(
            "execute",
            self.checker,
            replacement=self.replacement,
        )
        self.assert_redacted_failure(completed)




if __name__ == "__main__":
    unittest.main()
