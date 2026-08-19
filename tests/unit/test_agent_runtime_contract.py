#!/usr/bin/env python3
"""Static contracts for the production agent-wechat Compose invocation."""

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_HELPER = REPO_ROOT / "scripts" / "qr-runtime-common.sh"
COMMON_HELPER = REPO_ROOT / "scripts" / "common.sh"


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
        continuation = chr(92)
        compose_arguments = (
            f'      --env-file "$AGENT_ENV_FILE" {continuation}',
            f'      --project-directory "$RUNTIME_REPO_ROOT" {continuation}',
            '      -f "$AGENT_COMPOSE_FILE" "$@"',
        )
        sudo_invocation = "\n".join(
            (
                '    sudo -- env '
                '"CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" '
                f"docker compose {continuation}",
                *compose_arguments,
            )
        )
        direct_invocation = "\n".join(
            (
                '    env "CF_AGENT_WECHAT_RUNTIME_ROOT=$RUNTIME_ROOT" '
                f"docker compose {continuation}",
                *compose_arguments,
            )
        )
        self.assertIn(sudo_invocation, self.content)
        self.assertIn(direct_invocation, self.content)

    def test_start_and_stop_validate_agent_env_before_compose(self) -> None:
        absolute_error = (
            "agent-wechat environment file path must be absolute:"
        )
        file_condition = (
            'if [ -L "$AGENT_ENV_FILE" ] || '
            '[ ! -f "$AGENT_ENV_FILE" ]; then'
        )
        file_error = (
            "agent-wechat environment file must be an existing non-symlink "
            "regular file:"
        )
        self.assertEqual(self.content.count('case "$AGENT_ENV_FILE" in'), 2)
        self.assertEqual(self.content.count(absolute_error), 2)
        self.assertEqual(self.content.count(file_condition), 2)
        self.assertEqual(self.content.count(file_error), 2)


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
