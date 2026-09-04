#!/usr/bin/env python3
"""Focused tests for the dependency-free repository hygiene checker."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath


SPEC = importlib.util.spec_from_file_location(
    "repository_hygiene_under_test",
    Path(__file__).with_name("repository_hygiene.py"),
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load repository_hygiene.py")
HYGIENE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HYGIENE
SPEC.loader.exec_module(HYGIENE)


class RepositoryHygieneTests(unittest.TestCase):
    def scan(self, files: dict[str, str | bytes]):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths: list[PurePosixPath] = []
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                if isinstance(content, bytes):
                    path.write_bytes(content)
                else:
                    path.write_text(content, encoding="utf-8")
                paths.append(PurePosixPath(name))
            return HYGIENE.scan_repository(root, paths)

    def messages(self, files: dict[str, str | bytes]) -> list[str]:
        return [issue.message for issue in self.scan(files).issues]

    def test_utf8_and_control_characters(self) -> None:
        result = self.scan(
            {
                "valid.txt": "tab\tcrlf\r\n中文\n",
                "invalid.txt": b"not utf-8: \xff\n",
                "control.py": "value = 'bad\x00value'\n",
            }
        )
        rendered = "\n".join(issue.render() for issue in result.issues)
        self.assertIn("text file is not valid UTF-8", rendered)
        self.assertIn("forbidden control character U+0000", rendered)
        self.assertFalse(any(issue.path == "valid.txt" for issue in result.issues))

    def test_markdown_fences_links_and_unicode_anchors(self) -> None:
        valid = self.scan(
            {
                "README.md": (
                    "# 项目说明\n\n"
                    "[section](docs/guide.md#部署步骤)\n\n"
                    "```text\n[ignored](missing.md)\n```\n"
                ),
                "docs/guide.md": "# 部署步骤\n",
            }
        )
        self.assertEqual(valid.issues, ())

        messages = self.messages(
            {
                "README.md": (
                    "# Project\n\n"
                    "[missing](docs/missing.md)\n"
                    "[anchor](guide.md#not-there)\n\n"
                    "```bash\n"
                ),
                "guide.md": "# Present\n",
            }
        )
        self.assertTrue(any("unclosed Markdown fence" in item for item in messages))
        self.assertTrue(any("target does not exist" in item for item in messages))
        self.assertTrue(any("anchor does not exist" in item for item in messages))

    def test_secret_scan_catches_live_shapes_and_allows_sentinels(self) -> None:
        github_token = "gh" + "p_" + "A1" * 20
        private_key = "-----BEGIN " + "PRIVATE KEY-----"
        live_generic = "mT8Qz0wJ3nP7bV5xK2sR9cD4"
        messages = self.messages(
            {
                "secrets.env": (
                    f"GITHUB_TOKEN={github_token}\n"
                    f"SERVICE_PASSWORD={live_generic}\n"
                    f"{private_key}\n"
                ),
                "fixtures.env": (
                    "TOKEN=fixture-token-never-printed\n"
                    "API_SECRET=<API_SECRET>\n"
                    "IMAGE=example/image@sha256:"
                    + "0" * 64
                    + "\n"
                ),
            }
        )
        self.assertTrue(any("GitHub token" in item for item in messages))
        self.assertTrue(any("SERVICE_PASSWORD" in item for item in messages))
        self.assertTrue(any("private-key block" in item for item in messages))
        self.assertFalse(any("fixtures.env" in issue.path for issue in self.scan(
            {
                "fixtures.env": (
                    "TOKEN=fixture-token-never-printed\n"
                    "API_SECRET=<API_SECRET>\n"
                    "IMAGE=example/image@sha256:" + "0" * 64 + "\n"
                )
            }
        ).issues))

    def test_workflow_policy_allows_static_checks(self) -> None:
        result = self.scan(
            {
                ".github/workflows/check.yml": (
                    "name: check\n"
                    "jobs:\n"
                    "  static:\n"
                    "    steps:\n"
                    "      - run: >-\n"
                    "          bash -n\n"
                    "          scripts/start-qr-login.sh\n"
                    "          scripts/login.sh\n"
                    "      - run: shellcheck scripts/start-qr-login.sh\n"
                )
            }
        )
        self.assertEqual(result.issues, ())

    def test_workflow_policy_rejects_listener_and_sensitive_output(self) -> None:
        messages = self.messages(
            {
                ".github/workflows/unsafe.yml": (
                    "name: unsafe\n"
                    "env:\n"
                    "  AGENT_WECHAT_TOKEN: ${{ secrets.WECHAT_TOKEN }}\n"
                    "jobs:\n"
                    "  unsafe:\n"
                    "    steps:\n"
                    "      - run: ./scripts/start-qr-login.sh\n"
                    "      - run: python3 scripts/qr_login.py\n"
                    "      - run: |\n"
                    "          set -x\n"
                    "          echo \"$AGENT_WECHAT_TOKEN\"\n"
                    "          ./scripts/login.sh\n"
                )
            }
        )
        self.assertGreaterEqual(
            sum("directly invokes" in item for item in messages),
            2,
        )
        self.assertTrue(any("shell tracing" in item for item in messages))
        self.assertTrue(any("may print" in item for item in messages))
        self.assertTrue(any("must not import" in item for item in messages))
        self.assertTrue(any("must not declare" in item for item in messages))


if __name__ == "__main__":
    unittest.main()
