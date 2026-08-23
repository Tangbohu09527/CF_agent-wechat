#!/usr/bin/env python3
"""Static contracts for the production agent-wechat Compose invocation."""

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_HELPER = REPO_ROOT / "scripts" / "qr-runtime-common.sh"
COMMON_HELPER = REPO_ROOT / "scripts" / "common.sh"
START_SCRIPT = REPO_ROOT / "scripts" / "start-qr-login.sh"
STOP_SCRIPT = REPO_ROOT / "scripts" / "stop-qr-runtime.sh"
STATUS_SCRIPT = REPO_ROOT / "scripts" / "status.sh"
BOOTSTRAP_SCRIPT = REPO_ROOT / "scripts" / "bootstrap-cfserver.sh"
SCAN_SCRIPT = REPO_ROOT / "scripts" / "scan_runtime_tree.py"


def function_body(content: str, name: str) -> str:
    start = content.index(f"{name}() {{")
    end = content.index("\n}\n", start)
    return content[start : end + 3]


def container_script(body: str) -> str:
    marker = " sh -c '\n"
    start = body.index(marker) + len(marker)
    end = body.index("\n' 2>/dev/null", start)
    return body[start:end]


class AgentRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.content = RUNTIME_HELPER.read_text(encoding="utf-8")

    def test_runtime_lock_rechecks_path_and_descriptor_after_flock(self) -> None:
        lock = function_body(self.content, "runtime_acquire_lock")
        post_flock = lock[lock.index('if ! flock'):]
        self.assertIn('/proc/self/fd/${RUNTIME_LOCK_FD}', post_flock)
        self.assertIn(
            '[ "$path_metadata_after" != "$path_metadata" ]',
            post_flock,
        )
        self.assertIn('[ "$fd_metadata" != "$path_metadata" ]', post_flock)

    def test_default_agent_env_file_is_repo_docker_env(self) -> None:
        self.assertIn(
            'AGENT_ENV_FILE="${CF_AGENT_WECHAT_ENV_FILE:'
            '-${RUNTIME_REPO_ROOT}/docker/.env}"',
            self.content,
        )

    def test_agent_compose_uses_env_file_for_direct_and_sudo_docker(self) -> None:
        compose = function_body(self.content, "agent_compose")
        scrub = function_body(self.content, "runtime_compose_clean_env")
        self.assertIn('sudo -n -- /usr/bin/env', compose)
        self.assertIn('runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT"', compose)
        self.assertEqual(compose.count("--env-file /dev/null"), 1)
        self.assertEqual(compose.count("-f -"), 1)
        self.assertIn('"$AGENT_COMPOSE_SNAPSHOT"', compose)
        self.assertIn("/usr/bin/base64 --decode", compose)
        self.assertEqual(
            compose.count('--project-directory "$RUNTIME_REPO_ROOT"'),
            1,
        )
        self.assertIn('--project-name "$APPROVED_AGENT_PROJECT"', compose)
        approved_assignments = (
            "AGENT_WECHAT_IMAGE=$APPROVED_AGENT_IMAGE",
            "AGENT_WECHAT_BIND_IP=$AGENT_WECHAT_BIND_IP",
            "AGENT_WECHAT_PORT=$AGENT_WECHAT_PUBLISHED_PORT",
            "AGENT_WECHAT_CONTAINER_NAME=$APPROVED_AGENT_CONTAINER",
            "COMPOSE_PROJECT_NAME=$APPROVED_AGENT_PROJECT",
            "PROXY=$APPROVED_PROXY",
            "RUST_LOG=$APPROVED_RUST_LOG",
        )
        for assignment in approved_assignments:
            with self.subTest(assignment=assignment):
                self.assertIn(assignment, compose)
        for variable in (
            "AGENT_WECHAT_IMAGE",
            "AGENT_WECHAT_CONTAINER_NAME",
            "COMPOSE_PROJECT_NAME",
            "PROXY",
            "RUST_LOG",
            "AUTH_TOKEN",
        ):
            with self.subTest(variable=variable):
                self.assertIn(variable, scrub)

    def test_compose_snapshot_is_bounded_nofollow_and_race_checked(self) -> None:
        capture = function_body(
            self.content, "runtime_capture_compose_snapshot"
        )
        prepare = function_body(
            self.content, "runtime_prepare_compose_snapshots"
        )
        for fragment in (
            "O_NOFOLLOW", "st_nlink != 1", "1024 * 1024",
            "st_dev, opened.st_ino", "st_mtime_ns", "st_ctime_ns",
        ):
            self.assertIn(fragment, capture)
        self.assertIn('"$AGENT_COMPOSE_FILE"', prepare)
        self.assertIn('"$GATEWAY_COMPOSE_FILE"', prepare)

    def test_start_and_stop_validate_agent_env_before_compose(self) -> None:
        absolute_error = (
            "agent-wechat environment file path must be absolute:"
        )
        file_condition = (
            'if runtime_privileged test -L "$AGENT_ENV_FILE" ||\n'
            '    ! runtime_privileged test -f "$AGENT_ENV_FILE"; then'
        )
        file_error = (
            "agent-wechat environment file must be an existing non-symlink "
            "regular file:"
        )
        self.assertEqual(self.content.count('case "$AGENT_ENV_FILE" in'), 2)
        self.assertEqual(self.content.count(absolute_error), 2)
        self.assertEqual(self.content.count(file_condition), 2)
        self.assertEqual(self.content.count(file_error), 2)

    def test_actual_container_attestation_binds_image_id_and_repo_digest(self) -> None:
        attestation = function_body(
            self.content, "runtime_attest_actual_agent_container"
        )
        self.assertIn('item.get("Image") != image_item.get("Id")', attestation)
        self.assertIn("expected_image not in repo_digests", attestation)

    def test_actual_container_attestation_rejects_raw_token_before_python(self) -> None:
        start = self.content.index(
            "runtime_attest_actual_agent_container() {"
        )
        end = self.content.index(
            "\nruntime_validate_configuration() {", start
        )
        attestation = self.content[start:end]
        parser_offset = attestation.index("| run_isolated_python -c")
        self.assertIn('[ -z "${AUTH_TOKEN:-}" ]', attestation)
        self.assertEqual(attestation.count('*"$AUTH_TOKEN"*'), 2)
        self.assertLess(
            attestation.rindex('*"$AUTH_TOKEN"*'), parser_offset
        )
        parser_invocation = attestation[
            parser_offset : attestation.index(">/dev/null; then", parser_offset)
        ]
        self.assertNotIn("AUTH_TOKEN", parser_invocation)

    def test_status_loads_token_before_actual_container_attestation(self) -> None:
        status = STATUS_SCRIPT.read_text(encoding="utf-8")
        self.assertLess(
            status.index("load_auth_token"),
            status.index("runtime_attest_actual_agent_container"),
        )

    def test_management_environment_load_follows_file_validation(self) -> None:
        for function_name in (
            "runtime_validate_configuration",
            "runtime_validate_stop_configuration",
        ):
            body = function_body(self.content, function_name)
            self.assertLess(
                body.index('runtime_privileged test -L "$AGENT_ENV_FILE"'),
                body.index("runtime_load_management_environment"),
            )
        self.assertEqual(
            self.content.count("runtime_load_management_environment"), 3
        )

    def test_management_env_metadata_is_exact_and_bound_to_archive_preflight(
        self,
    ) -> None:
        validator = function_body(
            self.content,
            "runtime_validate_agent_environment_metadata_contract",
        )
        for fragment in (
            '[ "$owner" = "$current_uid" ]',
            '[ "$group" = "$current_gid" ]',
            '600)',
            '"$RUNTIME_MANAGEMENT_GID"',
            'AGENT_ENV_APPROVED_UID="$owner"',
            'AGENT_ENV_APPROVED_GID="$group"',
            'AGENT_ENV_APPROVED_MODE="$mode"',
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, validator)

        start = START_SCRIPT.read_text(encoding="utf-8")
        for option in (
            "--env-owner-uid",
            "--env-owner-gid",
            "--env-mode",
            "--operator-uid",
            "--operator-gid",
        ):
            self.assertEqual(start.count(option), 2)

    def test_runtime_payload_uses_exact_uid_gid_mode_contract(self) -> None:
        validation = function_body(
            self.content, "runtime_validate_configuration"
        )
        self.assertNotIn(
            '"$required_path" "Runtime management directory"',
            validation,
        )
        for path, label in (
            ("$RUNTIME_ROOT", "Runtime root"),
            ("${RUNTIME_ROOT}/data", "Runtime data"),
            ("${RUNTIME_ROOT}/wechat-home", "Runtime WeChat HOME"),
            ("$LEGACY_DATA_ROOT", "Legacy data"),
            ("$LEGACY_WECHAT_HOME_ROOT", "Legacy WeChat HOME"),
        ):
            with self.subTest(path=path):
                self.assertIn(path, validation)
                self.assertIn(label, validation)
        self.assertIn("runtime_validate_approved_runtime_directory", validation)


class ManagementEnvironmentIsolationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.common = COMMON_HELPER.read_text(encoding="utf-8")
        cls.runtime = RUNTIME_HELPER.read_text(encoding="utf-8")

    def test_production_rejects_all_management_and_proxy_overrides(
        self,
    ) -> None:
        capture = self.common[
            self.common.index("_MANAGEMENT_OVERRIDE_NAMES=(") :
            self.common.index("# Production endpoints")
        ]
        for name in (
            "API_URL",
            "WS_URL",
            "TOKEN_FILE",
            "SESSION_ID",
            "AGENT_WECHAT_IMAGE",
            "AGENT_WECHAT_BIND_IP",
            "AGENT_WECHAT_PORT",
            "AGENT_WECHAT_CONTAINER_NAME",
            "COMPOSE_PROJECT_NAME",
            "PROXY",
            "RUST_LOG",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "HTTP_CONNECT_TIMEOUT",
            "HTTP_TIMEOUT",
            "DOCKER_READ_TIMEOUT",
            "CF_AGENT_WECHAT_CURL_BIN",
        ):
            with self.subTest(name=name):
                self.assertIn(name, capture)
        self.assertIn('unset "$_override_name"', capture)
        self.assertIn("_CF_AGENT_WECHAT_EARLY_OVERRIDES", capture)

    def test_production_curl_has_a_clean_environment_and_stdin_header(
        self,
    ) -> None:
        curl_body = function_body(self.common, "run_agent_curl")
        request_body = function_body(self.common, "api_request")
        self.assertIn("/usr/bin/env -i", curl_body)
        self.assertIn("HOME=/nonexistent", curl_body)
        self.assertNotIn("AUTH_TOKEN", curl_body)
        self.assertIn("printf 'Authorization: Bearer %s", request_body)
        self.assertIn("| run_agent_curl", request_body)
        self.assertIn("--header @-", request_body)
        self.assertNotIn('--header "Authorization:', request_body)

    def test_compose_scrubs_then_injects_only_approved_management_values(
        self,
    ) -> None:
        scrub = function_body(self.runtime, "runtime_compose_clean_env")
        compose = function_body(self.runtime, "agent_compose")
        for name in (
            "AGENT_WECHAT_IMAGE",
            "AGENT_WECHAT_BIND_IP",
            "AGENT_WECHAT_PORT",
            "AGENT_WECHAT_CONTAINER_NAME",
            "COMPOSE_PROJECT_NAME",
            "PROXY",
            "RUST_LOG",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "CF_AGENT_WECHAT_TOKEN",
            "AUTH_TOKEN",
            "API_URL",
            "WS_URL",
        ):
            with self.subTest(name=name):
                self.assertIn(name, scrub)
        for assignment in (
            "AGENT_WECHAT_IMAGE=$APPROVED_AGENT_IMAGE",
            "AGENT_WECHAT_BIND_IP=$AGENT_WECHAT_BIND_IP",
            "AGENT_WECHAT_PORT=$AGENT_WECHAT_PUBLISHED_PORT",
            "AGENT_WECHAT_CONTAINER_NAME=$APPROVED_AGENT_CONTAINER",
            "COMPOSE_PROJECT_NAME=$APPROVED_AGENT_PROJECT",
            "PROXY=$APPROVED_PROXY",
            "RUST_LOG=$APPROVED_RUST_LOG",
        ):
            with self.subTest(assignment=assignment):
                self.assertIn(assignment, compose)

    def test_testing_mode_is_explicitly_isolated_from_production_assets(
        self,
    ) -> None:
        aggregate = function_body(
            self.runtime, "runtime_validate_testing_isolation"
        )
        for gate in (
            "testing_validate_root_contract",
            "validate_testing_token_isolation",
            "validate_testing_endpoint_isolation",
            "runtime_validate_testing_storage_isolation",
            "runtime_validate_testing_gateway_isolation",
            "runtime_validate_testing_lock_isolation",
            "runtime_validate_testing_code_isolation",
            "runtime_validate_testing_replacement_isolation",
            "runtime_validate_testing_tool_isolation",
            "validate_testing_docker_isolation",
        ):
            with self.subTest(gate=gate):
                self.assertIn(gate, aggregate)

        storage = function_body(
            self.runtime, "runtime_validate_testing_storage_isolation"
        )
        gateway = function_body(
            self.runtime, "runtime_validate_testing_gateway_isolation"
        )
        lock = function_body(
            self.runtime, "runtime_validate_testing_lock_isolation"
        )
        self.assertIn("/srv/storage/cf-agent-wechat", self.runtime)
        self.assertIn("/opt/cf-agent-gateway", self.runtime)
        self.assertIn("/opt/cf-agent-wechat", self.common)
        self.assertIn("CF_AGENT_WECHAT_TEST_ROOT", self.common)
        for name in (
            "STORAGE_ROOT",
            "RUNTIME_ROOT",
            "ARCHIVE_ROOT",
            "LEGACY_DATA_ROOT",
            "LEGACY_WECHAT_HOME_ROOT",
        ):
            self.assertIn(f'"${name}"', storage)
        for name in (
            "GATEWAY_PROJECT_DIR",
            "GATEWAY_COMPOSE_FILE",
            "GATEWAY_ENV_FILE",
            "GATEWAY_HEARTBEAT_COMMAND",
            "GATEWAY_CONTRACT_FILE",
        ):
            self.assertIn(f'"${name}"', gateway)
        self.assertIn(
            "/run/lock/cf-agent-wechat-qr-runtime.lock", lock
        )

    def test_testing_custom_tools_never_cross_sudo_or_root(self) -> None:
        readonly_docker = function_body(
            self.common, "docker_readonly_capture"
        )
        runtime_docker = function_body(self.runtime, "runtime_docker")
        select_docker = function_body(self.runtime, "runtime_select_docker")
        privileged_python = function_body(
            self.runtime, "runtime_privileged_isolated_python"
        )
        archive_capacity = function_body(
            self.runtime, "runtime_check_archive_capacity"
        )

        testing_stop = readonly_docker.index(
            'if [ "$CF_AGENT_WECHAT_TESTING" = "1" ]; then'
        )
        sudo_call = readonly_docker.index("sudo -n --")
        self.assertLess(testing_stop, sudo_call)
        self.assertIn(
            "Testing Docker fake must never execute through sudo.",
            runtime_docker,
        )
        self.assertIn(
            "Testing Docker fake failed without privilege",
            select_docker,
        )
        self.assertIn("/usr/bin/python3 -I", privileged_python)
        self.assertNotIn('"$PYTHON_BIN" -I', privileged_python)
        self.assertIn(
            'runtime_with_timeout "$ARCHIVE_TOOL_TIMEOUT"', archive_capacity
        )
        self.assertIn("/usr/bin/df -Pk", archive_capacity)
        self.assertIn("/usr/bin/df -Pi", archive_capacity)

    def test_testing_assets_and_tools_are_positively_confined(self) -> None:
        code = function_body(
            self.runtime, "runtime_validate_testing_code_isolation"
        )
        tools = function_body(
            self.runtime, "runtime_validate_testing_tool_isolation"
        )
        login_assets = function_body(
            self.common, "validate_testing_login_asset_isolation"
        )
        for name in (
            "RUNTIME_REPO_ROOT",
            "RUNTIME_SCRIPTS_DIR",
            "AGENT_COMPOSE_FILE",
            "AGENT_ENV_FILE",
            "GATEWAY_CONTRACT_VERIFIER",
            "RUNTIME_TREE_SCANNER",
            "ARCHIVE_RUNTIME_TOOL",
            "MANAGEMENT_ENV_PARSER",
        ):
            with self.subTest(name=name):
                self.assertIn(f'"${name}"', code)
        for name in ("DOCKER_BIN", "SYSTEMCTL_BIN", "DF_BIN", "TIMEOUT_BIN"):
            with self.subTest(name=name):
                self.assertIn(f'"${name}"', tools)
        for name in ("VENV_DIR", "TMPDIR", "REQUIREMENTS_FILE", "PYTHON_BIN"):
            with self.subTest(name=name):
                self.assertIn(name, login_assets)

    def test_replacement_hooks_require_non_elevated_confined_source_and_target(
        self,
    ) -> None:
        gate = function_body(
            self.runtime, "runtime_validate_testing_replacement_isolation"
        )
        verifier = function_body(
            self.runtime, "runtime_gateway_verifier_snapshot"
        )
        self.assertIn("GATEWAY_CONTRACT_VERIFIER", gate)
        self.assertIn("GATEWAY_HEARTBEAT_COMMAND", gate)
        self.assertIn("runtime_with_timeout", verifier)
        self.assertIn("runtime_privileged", verifier)
        self.assertIn("os.getuid() == 0", self.runtime)
        self.assertIn("os.geteuid() != os.getuid()", self.runtime)
        self.assertIn("os.path.commonpath", self.runtime)

    def test_bootstrap_testing_is_confined_before_temp_or_sudo_and_has_no_hook(
        self,
    ) -> None:
        bootstrap = BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")
        main = function_body(bootstrap, "main")
        execute_docker = function_body(bootstrap, "execute_docker")
        verifier = function_body(
            bootstrap, "bootstrap_gateway_verifier_snapshot"
        )
        self.assertLess(
            main.index("validate_testing_isolation"),
            main.index("validate_platform_and_tools"),
        )
        self.assertLess(
            main.index("validate_testing_isolation"),
            main.index("authorize_privilege"),
        )
        self.assertIn("CF_AGENT_WECHAT_TEST_ROOT", bootstrap)
        self.assertIn("/opt/cf-agent-wechat", bootstrap)
        self.assertIn(
            "testing Docker mocks must never execute through sudo",
            execute_docker,
        )
        self.assertNotIn(
            "CF_AGENT_WECHAT_TEST_GATEWAY_VERIFIER_REPLACEMENT",
            bootstrap,
        )
        self.assertIn("run_with_hard_timeout", verifier)
        self.assertIn("run_privileged_with_hard_timeout", verifier)

    def test_testing_path_check_is_lexical_before_sudo_authorization(
        self,
    ) -> None:
        canonical = function_body(self.common, "testing_canonical_path")
        self.assertNotIn("readlink", canonical)
        self.assertIn("path_stack", canonical)
        self.assertIn("[[:cntrl:]]", canonical)

    def test_token_load_rejects_all_symbolic_link_ancestors(self) -> None:
        ancestor_check = function_body(
            self.common, "validate_token_path_ancestors"
        )
        token_load = function_body(self.common, "load_auth_token")
        self.assertIn('[ -L "$current" ]', ancestor_check)
        self.assertIn(
            "validate_token_path_ancestors || return 1", token_load
        )
        self.assertIn(
            'current=$(/usr/bin/dirname -- "$token_file")', token_load
        )
        self.assertIn('if [ -L "$current" ]; then', token_load)
        self.assertIn('52) LAST_ERROR="Token path must not contain', token_load)

    def test_testing_gate_precedes_every_entrypoint_operation(self) -> None:
        for path in (START_SCRIPT, STOP_SCRIPT, STATUS_SCRIPT):
            content = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                gate = content.index(
                    "if ! runtime_validate_testing_isolation; then"
                )
                self.assertGreater(
                    gate, content.index('source "${SCRIPT_DIR}/qr-runtime-common.sh"')
                )
                self.assertLess(gate, content.index("\nmain() {"))

    def test_testing_docker_endpoint_is_explicit_and_production_stays_fixed(
        self,
    ) -> None:
        select = function_body(self.runtime, "runtime_select_docker")
        self.assertIn('expected_endpoint="unix://${DOCKER_SOCKET_PATH}"', select)
        self.assertIn('expected_endpoint="unix:///var/run/docker.sock"', select)
        self.assertIn('[ "$endpoint" != "$expected_endpoint" ]', select)


class ArchiveSafetyContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.content = START_SCRIPT.read_text(encoding="utf-8")
        cls.archive_body = function_body(cls.content, "archive_current_runtime")

    def test_archive_source_moves_are_bound_to_staging_and_token_scanner(
        self,
    ) -> None:
        self.assertIn(
            '"$RUNTIME_ROOT" "Current runtime" "$ARCHIVE_STAGING_PATH"',
            self.archive_body,
        )
        self.assertIn('"manifest.json"', self.archive_body)
        self.assertIn(
            '"$LEGACY_DATA_ROOT" "Legacy data"',
            self.archive_body,
        )
        self.assertIn(
            '"${ARCHIVE_STAGING_PATH}/data"',
            self.archive_body,
        )
        self.assertIn(
            '"$LEGACY_WECHAT_HOME_ROOT" "Legacy WeChat HOME"',
            self.archive_body,
        )
        self.assertIn(
            '"${ARCHIVE_STAGING_PATH}/wechat-home"',
            self.archive_body,
        )
        self.assertIn(
            '"${ARCHIVE_STAGING_PATH}/data" '
            '"Staged legacy data rollback"',
            self.archive_body,
        )
        self.assertNotIn("runtime_privileged mv", self.archive_body)
        isolated_scan = self.archive_body.index(
            '"Isolated Archive staging payload"'
        )
        manifest = self.archive_body.index(
            'write_manifest in_progress ""',
            isolated_scan,
        )
        publish = self.archive_body.index(
            "publish_archive_staging",
            manifest,
        )
        fresh_result = self.archive_body.index(
            'ARCHIVE_RESULT="succeeded"',
            isolated_scan,
        )
        self.assertLess(isolated_scan, fresh_result)
        self.assertLess(fresh_result, manifest)
        self.assertLess(manifest, publish)

    def test_scanner_uses_dirfd_relative_identity_bound_rename(self) -> None:
        scanner = SCAN_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("verify_tree_attestation(root, attestation", scanner)
        self.assertIn("src_dir_fd=source_parent_fd", scanner)
        self.assertIn("dst_dir_fd=destination_parent_fd", scanner)
        self.assertIn("reserved archive metadata path", scanner)

    def test_script_ends_at_the_single_production_entrypoint(self) -> None:
        self.assertTrue(self.content.rstrip().endswith('main "$@"'))

class FailedFlowCleanupContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        runtime_content = RUNTIME_HELPER.read_text(encoding="utf-8")
        start_content = START_SCRIPT.read_text(encoding="utf-8")
        cls.cleanup_body = function_body(
            runtime_content, "cleanup_failed_agent_container"
        )
        cls.remove_body = function_body(
            runtime_content, "remove_agent_container"
        )
        cls.exit_body = function_body(start_content, "on_exit")
        cls.main_body = function_body(start_content, "main")

    def test_cleanup_attempts_stop_then_remove_without_volume_deletion(
        self,
    ) -> None:
        stop_call = self.cleanup_body.index("if stop_agent_container; then")
        remove_call = self.cleanup_body.index(
            "if remove_agent_container; then"
        )
        self.assertLess(stop_call, remove_call)
        self.assertIn(
            'AGENT_FAILURE_CLEANUP_STOP_RESULT="failed"',
            self.cleanup_body,
        )
        self.assertIn(
            'AGENT_FAILURE_CLEANUP_REMOVE_RESULT="failed"',
            self.cleanup_body,
        )
        for forbidden in ("rm -v", " down ", "runtime_privileged rm"):
            self.assertNotIn(forbidden, self.cleanup_body)
        self.assertIn(
            "agent_compose rm --force agent-wechat",
            self.remove_body,
        )
        for forbidden in ("rm -v", "--volumes", " down "):
            self.assertNotIn(forbidden, self.remove_body)

    def test_exit_trap_cleans_agent_before_failed_manifest(self) -> None:
        self.assertIn(
            '[ "$AGENT_CLEANUP_GUARD" -eq 1 ]',
            self.exit_body,
        )
        cleanup_call = self.exit_body.index(
            "cleanup_failed_agent_container"
        )
        manifest_call = self.exit_body.index(
            'write_manifest failed "$ended_at"'
        )
        self.assertLess(cleanup_call, manifest_call)
        self.assertIn('exit "$exit_status"', self.exit_body)

    def test_cleanup_guard_starts_only_at_agent_destructive_phase(
        self,
    ) -> None:
        token_load = self.main_body.index("if ! load_auth_token; then")
        cleanup_guard = self.main_body.index("AGENT_CLEANUP_GUARD=1")
        first_agent_stop = self.main_body.index("if ! stop_agent_container; then")
        self.assertLess(token_load, cleanup_guard)
        self.assertLess(cleanup_guard, first_agent_stop)

    def test_forced_login_failure_preserves_safe_stage_error(self) -> None:
        forced_login = self.main_body.index("if ! run_forced_login; then")
        next_phase = self.main_body.index(
            'FLOW_PHASE="verify_wechat_process"', forced_login
        )
        failure_block = self.main_body[forced_login:next_phase]
        self.assertIn('error "$LAST_ERROR"', failure_block)


class WeChatProcessIdentityContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        common_content = COMMON_HELPER.read_text(encoding="utf-8")
        runtime_content = RUNTIME_HELPER.read_text(encoding="utf-8")
        cls.common_body = function_body(
            common_content, "get_wechat_process_identity"
        )
        cls.runtime_body = function_body(
            runtime_content, "runtime_wechat_process_identity"
        )
        cls.common_script = container_script(cls.common_body)
        cls.runtime_script = container_script(cls.runtime_body)

    def test_helpers_keep_their_direct_and_sudo_capable_docker_wrappers(
        self,
    ) -> None:
        self.assertIn(
            'docker_readonly_capture exec "$CONTAINER_NAME" sh -c',
            self.common_body,
        )
        self.assertIn(
            'runtime_docker exec "$CONTAINER_NAME" sh -c',
            self.runtime_body,
        )

    def test_helpers_use_identical_canonical_executable_semantics(self) -> None:
        self.assertEqual(self.common_script, self.runtime_script)
        for fragment in (
            'launcher_real="$(readlink -f /usr/bin/wechat '
            '2>/dev/null || true)"',
            'case "$launcher_real" in',
            "/*) ;;",
            "*) exit 1 ;;",
            'proc_exe="$(readlink "$process_dir/exe" '
            '2>/dev/null || true)"',
            '[ "$proc_exe" = "$launcher_real" ] || continue',
        ):
            self.assertIn(fragment, self.common_script)
        self.assertNotIn("= /usr/bin/wechat ]", self.common_script)

    def test_identity_remains_pid_and_proc_start_time(self) -> None:
        self.assertIn(
            'start_time="$(awk "{ print \\$22 }" '
            '"$process_dir/stat" 2>/dev/null || true)"',
            self.common_script,
        )
        self.assertIn(
            'printf "%s:%s\\n" "$process_id" "$start_time"',
            self.common_script,
        )

    def test_identity_does_not_use_weak_process_name_matching(self) -> None:
        for forbidden in ("pgrep", "/comm", "cmdline", "basename"):
            self.assertNotIn(forbidden, self.common_script)


if __name__ == "__main__":
    unittest.main()
