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
        self.assertIn(
            'sudo -n -- env "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" '
            "docker compose",
            self.content,
        )
        self.assertIn(
            'env "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" docker compose',
            self.content,
        )
        self.assertEqual(self.content.count('--env-file "$AGENT_ENV_FILE"'), 2)
        self.assertEqual(
            self.content.count('--project-directory "$RUNTIME_REPO_ROOT"'),
            2,
        )
        self.assertGreaterEqual(
            self.content.count('runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT"'),
            4,
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
