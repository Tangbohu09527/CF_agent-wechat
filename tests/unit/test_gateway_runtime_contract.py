#!/usr/bin/env python3
"""Static contracts for the production Gateway Compose invocation."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_HELPER = REPO_ROOT / "scripts" / "qr-runtime-common.sh"


class GatewayRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.content = RUNTIME_HELPER.read_text(encoding="utf-8")

    def test_default_gateway_deploy_paths_are_exact(self) -> None:
        expected = (
            'GATEWAY_COMPOSE_FILE="${CF_AGENT_GATEWAY_COMPOSE_FILE:'
            '-/opt/cf-agent-gateway/deploy/compose.yaml}"',
            'GATEWAY_PROJECT_DIR="${CF_AGENT_GATEWAY_PROJECT_DIR:'
            '-/opt/cf-agent-gateway/deploy}"',
            'GATEWAY_ENV_FILE="${CF_AGENT_GATEWAY_ENV_FILE:'
            '-/opt/cf-agent-gateway/deploy/.env}"',
        )
        for fragment in expected:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.content)

    def test_gateway_compose_uses_the_validated_env_file(self) -> None:
        invocation = re.compile(
            r"gateway_compose\(\) \{\s*"
            r"runtime_docker compose \\\s*"
            r'--env-file "\$GATEWAY_ENV_FILE" \\\s*'
            r'--project-directory "\$GATEWAY_PROJECT_DIR" \\\s*'
            r'-f "\$GATEWAY_COMPOSE_FILE" "\$@"',
            re.MULTILINE,
        )
        self.assertRegex(self.content, invocation)

    def test_start_and_stop_validators_reject_missing_or_symlink_env(self) -> None:
        condition = (
            'if [ -L "$GATEWAY_ENV_FILE" ] || '
            '[ ! -f "$GATEWAY_ENV_FILE" ]; then'
        )
        message = (
            "Gateway environment file must be an existing non-symlink "
            "regular file:"
        )
        self.assertEqual(self.content.count(condition), 2)
        self.assertEqual(self.content.count(message), 2)


if __name__ == "__main__":
    unittest.main()
