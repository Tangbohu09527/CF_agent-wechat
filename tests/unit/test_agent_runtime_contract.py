#!/usr/bin/env python3
"""Static contracts for the production agent-wechat Compose invocation."""

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_HELPER = REPO_ROOT / "scripts" / "qr-runtime-common.sh"


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


if __name__ == "__main__":
    unittest.main()
