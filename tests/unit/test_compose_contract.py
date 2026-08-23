#!/usr/bin/env python3
"""Static production Compose contract checks that do not require Docker."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
COMPOSE_FILE = REPO_ROOT / "docker" / "compose.cfserver.yaml"


class ComposeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.content = COMPOSE_FILE.read_text(encoding="utf-8")

    def test_manual_restart_policy_and_rotating_runtime_mounts(self) -> None:
        self.assertIn('restart: "no"', self.content)
        self.assertNotRegex(
            self.content,
            r"restart:\s*(always|unless-stopped|on-failure)",
        )
        self.assertIn(
            'source: "${CF_AGENT_WECHAT_RUNTIME_ROOT:'
            '-/srv/storage/cf-agent-wechat/runtime}/data"',
            self.content,
        )
        self.assertIn(
            'source: "${CF_AGENT_WECHAT_RUNTIME_ROOT:'
            '-/srv/storage/cf-agent-wechat/runtime}/wechat-home"',
            self.content,
        )
        self.assertIn(
            'source: "/srv/storage/cf-agent-wechat/secrets/auth-token"',
            self.content,
        )
        token_mount = re.search(
            r'source: "/srv/storage/cf-agent-wechat/secrets/auth-token"'
            r".*?target: /data/auth-token"
            r".*?read_only: true",
            self.content,
            re.DOTALL,
        )
        self.assertIsNotNone(token_mount)

    def test_security_network_health_and_logging_contract_is_preserved(self) -> None:
        required_fragments = (
            'image: "${AGENT_WECHAT_IMAGE:?Set AGENT_WECHAT_IMAGE in .env}"',
            "- seccomp=unconfined",
            "- SYS_PTRACE",
            'ENABLE_VNC: "0"',
            '"http://127.0.0.1:6174/health"',
            "driver: json-file",
            'max-size: "20m"',
            'max-file: "3"',
            "cf-internal:",
            "aliases:",
            "- cf-agent-wechat",
            "external: true",
            "name: cf-internal",
        )
        for fragment in required_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, self.content)

    def test_only_existing_parameterized_6174_port_is_published(self) -> None:
        ports = re.search(
            r"^    ports:\s*$\n(?P<body>(?:^      .*\n)+)",
            self.content,
            re.MULTILINE,
        )
        self.assertIsNotNone(ports)
        entries = [
            line.strip()
            for line in ports.group("body").splitlines()
            if line.strip().startswith("- ")
        ]
        self.assertEqual(
            entries,
            [
                '- "${AGENT_WECHAT_BIND_IP:?Set AGENT_WECHAT_BIND_IP in .env}:'
                '${AGENT_WECHAT_PORT:-6174}:6174"'
            ],
        )


if __name__ == "__main__":
    unittest.main()
