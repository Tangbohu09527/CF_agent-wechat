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
            'GATEWAY_HEARTBEAT_COMMAND="${GATEWAY_PROJECT_DIR}/'
            'check-wechat-worker-heartbeat"',
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
        self.assertIn('sudo -n -- docker compose', function)
        self.assertIn('runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT"', function)
        self.assertEqual(function.count('--env-file "$GATEWAY_ENV_FILE"'), 2)
        self.assertEqual(
            function.count('--project-directory "$GATEWAY_PROJECT_DIR"'),
            2,
        )
        self.assertEqual(function.count('-f "$GATEWAY_COMPOSE_FILE" "$@"'), 2)

    def test_start_and_stop_validators_reject_missing_or_symlink_env(self) -> None:
        condition = (
            'if runtime_privileged test -L "$GATEWAY_ENV_FILE" ||\n'
            '    ! runtime_privileged test -f "$GATEWAY_ENV_FILE"; then'
        )
        message = (
            "Gateway environment file must be an existing non-symlink "
            "regular file:"
        )
        self.assertEqual(self.content.count(condition), 2)
        self.assertEqual(self.content.count(message), 2)

    def test_heartbeat_checker_is_fixed_and_never_runs_through_sudo(self) -> None:
        body = re.search(
            r"gateway_worker_heartbeat_is_healthy\(\) \{(?P<body>.*?)\n\}",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(body)
        function = body.group("body")
        self.assertIn(
            'runtime_with_timeout "$WORKER_HEARTBEAT_TIMEOUT"',
            function,
        )
        self.assertIn('"$GATEWAY_HEARTBEAT_COMMAND"', function)
        self.assertNotIn("runtime_privileged", function)
        self.assertNotIn("sudo", function)



if __name__ == "__main__":
    unittest.main()
