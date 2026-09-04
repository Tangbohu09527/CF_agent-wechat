#!/usr/bin/env python3
"""Static contracts for the production agent-wechat Compose invocation."""

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_HELPER = REPO_ROOT / "scripts" / "qr-runtime-common.sh"
COMMON_HELPER = REPO_ROOT / "scripts" / "common.sh"
START_SCRIPT = REPO_ROOT / "scripts" / "start-qr-login.sh"


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

    def test_default_agent_env_file_is_repo_docker_env(self) -> None:
        self.assertIn(
            'AGENT_ENV_FILE="${CF_AGENT_WECHAT_ENV_FILE:'
            '-${RUNTIME_REPO_ROOT}/docker/.env}"',
            self.content,
        )

    def test_agent_compose_uses_env_file_for_direct_and_sudo_docker(self) -> None:
        body = function_body(self.content, "agent_compose")
        self.assertIn('local -a clean_environment=(', body)
        for variable in (
            "AGENT_WECHAT_IMAGE",
            "AGENT_WECHAT_BIND_IP",
            "AGENT_WECHAT_PORT",
            "AGENT_WECHAT_CONTAINER_NAME",
            "COMPOSE_PROJECT_NAME",
            "CF_AGENT_WECHAT_STORAGE_ROOT",
            "CF_AGENT_WECHAT_RUNTIME_ROOT",
            "CF_AGENT_WECHAT_ARCHIVE_ROOT",
            "CF_AGENT_WECHAT_TOKEN_FILE",
            "PROXY",
            "RUST_LOG",
        ):
            self.assertIn(f"-u {variable}", body)
        self.assertIn('sudo -n -- "${clean_environment[@]}"', body)
        self.assertEqual(
            body.count(
                '"CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" docker compose'
            ),
            2,
        )
        self.assertEqual(body.count('--env-file "$AGENT_ENV_FILE"'), 2)
        self.assertEqual(
            body.count('--project-directory "$RUNTIME_REPO_ROOT"'),
            2,
        )
        self.assertEqual(
            body.count('runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT"'),
            2,
        )

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


class ArchiveSafetyContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.content = START_SCRIPT.read_text(encoding="utf-8")
        cls.archive_body = function_body(cls.content, "archive_current_runtime")

    def test_token_scan_precedes_every_archive_destination_mutation(self) -> None:
        runtime_scan = self.archive_body.index(
            'runtime_assert_tree_has_no_auth_token "$RUNTIME_ROOT"'
        )
        legacy_scan = self.archive_body.index(
            'runtime_assert_tree_has_no_auth_token "$LEGACY_DATA_ROOT"'
        )
        choose_destination = self.archive_body.index("choose_archive_path")
        self.assertLess(runtime_scan, choose_destination)
        self.assertLess(legacy_scan, choose_destination)
        self.assertLess(
            self.archive_body.index('ARCHIVE_RESULT="failed"'),
            runtime_scan,
        )
        self.assertGreater(
            self.archive_body.index('ARCHIVE_RESULT="succeeded"'),
            self.archive_body.index('mv --no-clobber -T'),
        )

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