#!/usr/bin/env python3
"""Tests for the byte-safe production docker/.env parser."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "parse_management_env.py"
SPEC = importlib.util.spec_from_file_location("management_env_parser", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PARSER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PARSER
SPEC.loader.exec_module(PARSER)

DIGEST = "a" * 64


def valid_values() -> dict[str, str]:
    return {
        "COMPOSE_PROJECT_NAME": "cf-agent-wechat",
        "CF_AGENT_WECHAT_STORAGE_ROOT": "/srv/storage/cf-agent-wechat",
        "CF_AGENT_WECHAT_RUNTIME_ROOT": "/srv/storage/cf-agent-wechat/runtime",
        "CF_AGENT_WECHAT_ARCHIVE_ROOT": (
            "/srv/storage/cf-agent-wechat/session-archive"
        ),
        "AGENT_WECHAT_BIND_IP": "127.0.0.1",
        "AGENT_WECHAT_PORT": "6174",
        "AGENT_WECHAT_CONTAINER_NAME": "cf-agent-wechat",
        "AGENT_WECHAT_IMAGE": f"ghcr.io/example/agent-wechat@sha256:{DIGEST}",
        "PROXY": "",
        "RUST_LOG": "info",
        "CF_AGENT_WECHAT_RUNTIME_UID": "1000",
        "CF_AGENT_WECHAT_RUNTIME_GID": "1000",
        "CF_AGENT_WECHAT_RUNTIME_MODE": "700",
        "CF_AGENT_WECHAT_MANAGEMENT_GID": "1000",
        "CF_AGENT_WECHAT_MIN_FREE_BYTES": "1073741824",
        "CF_AGENT_WECHAT_MIN_FREE_PERCENT": "10",
        "CF_AGENT_WECHAT_MIN_FREE_INODES": "1024",
        "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_FILES": "200000",
        "CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES": "21474836480",
    }


def encode_values(values: dict[str, str] | None = None) -> bytes:
    selected = valid_values() if values is None else values
    return "".join(f"{key}={selected[key]}\n" for key in PARSER.REQUIRED_KEYS).encode()


def replace_value(data: bytes, key: str, value: str) -> bytes:
    lines = data.decode("utf-8").splitlines()
    prefix = key + "="
    matches = [index for index, line in enumerate(lines) if line.startswith(prefix)]
    if len(matches) != 1:
        raise AssertionError(f"fixture key is not unique: {key}")
    lines[matches[0]] = prefix + value
    return ("\n".join(lines) + "\n").encode("utf-8")


class ManagementEnvParserTests(unittest.TestCase):
    def test_valid_production_environment_is_complete_and_ordered(self) -> None:
        data = b"# approved production values\n\n" + encode_values()

        parsed = PARSER.parse_management_env(data)

        self.assertEqual(parsed, valid_values())
        self.assertEqual(tuple(parsed), PARSER.REQUIRED_KEYS)

    def test_exact_64_kib_is_accepted_and_larger_input_is_rejected(self) -> None:
        base = encode_values()
        remaining = PARSER.MAX_INPUT_BYTES - len(base)
        self.assertGreater(remaining, 2)
        exact = base + b"#" + (b"a" * (remaining - 2)) + b"\n"

        self.assertEqual(len(exact), PARSER.MAX_INPUT_BYTES)
        PARSER.parse_management_env(exact)
        with self.assertRaisesRegex(PARSER.ManagementEnvError, "65536-byte"):
            PARSER.parse_management_env(exact + b" ")

    def test_invalid_utf8_is_rejected(self) -> None:
        with self.assertRaisesRegex(PARSER.ManagementEnvError, "strict UTF-8"):
            PARSER.parse_management_env(encode_values() + b"#\xff\n")

    def test_every_non_lf_c0_del_and_nel_is_rejected(self) -> None:
        controls = [bytes((value,)) for value in range(0x20) if value != 0x0A]
        controls.extend((b"\x7f", "\u0085".encode("utf-8")))
        for control in controls:
            with (
                self.subTest(control=control),
                self.assertRaisesRegex(PARSER.ManagementEnvError, "control character"),
            ):
                PARSER.parse_management_env(encode_values() + b"#unsafe" + control + b"\n")

    def test_crlf_and_lone_cr_are_rejected(self) -> None:
        for data in (encode_values().replace(b"\n", b"\r\n"), encode_values() + b"\r"):
            with (
                self.subTest(data=data[-20:]),
                self.assertRaisesRegex(PARSER.ManagementEnvError, "control character"),
            ):
                PARSER.parse_management_env(data)

    def test_duplicate_unknown_missing_and_shell_syntax_are_rejected(self) -> None:
        cases = {
            "duplicate": encode_values() + b"RUST_LOG=warn\n",
            "unknown": encode_values() + b"UNAPPROVED=value\n",
            "missing": b"".join(encode_values().splitlines(keepends=True)[:-1]),
            "export": b"export " + encode_values(),
            "quoted": replace_value(encode_values(), "RUST_LOG", '"info"'),
            "expansion": replace_value(
                encode_values(), "CF_AGENT_WECHAT_STORAGE_ROOT", "$(id)"
            ),
            "separator": replace_value(
                encode_values(),
                "CF_AGENT_WECHAT_STORAGE_ROOT",
                "/srv/storage/cf-agent-wechat;id",
            ),
            "whitespace": replace_value(
                encode_values(), "AGENT_WECHAT_CONTAINER_NAME", "cf agent"
            ),
        }
        for name, data in cases.items():
            with self.subTest(name=name), self.assertRaises(PARSER.ManagementEnvError):
                PARSER.parse_management_env(data)

    def test_field_contracts_fail_closed(self) -> None:
        invalid_values = (
            ("COMPOSE_PROJECT_NAME", "other-project"),
            ("AGENT_WECHAT_BIND_IP", "0.0.0.0"),
            ("AGENT_WECHAT_PORT", "0"),
            ("AGENT_WECHAT_PORT", "65536"),
            ("AGENT_WECHAT_CONTAINER_NAME", "-invalid"),
            ("AGENT_WECHAT_IMAGE", "ghcr.io/example/agent-wechat:latest"),
            ("RUST_LOG", "debug"),
            ("CF_AGENT_WECHAT_RUNTIME_UID", "0"),
            ("CF_AGENT_WECHAT_RUNTIME_GID", str(1 << 32)),
            ("CF_AGENT_WECHAT_RUNTIME_MODE", "755"),
            ("CF_AGENT_WECHAT_MIN_FREE_BYTES", "0"),
            ("CF_AGENT_WECHAT_MIN_FREE_PERCENT", "101"),
            ("CF_AGENT_WECHAT_TOKEN_SCAN_MAX_BYTES", str(1 << 63)),
        )
        for key, value in invalid_values:
            with self.subTest(key=key, value=value), self.assertRaises(
                PARSER.ManagementEnvError
            ):
                PARSER.parse_management_env(replace_value(encode_values(), key, value))

    def test_proxy_accepts_only_credential_free_scheme_host_and_port(self) -> None:
        accepted = (
            "",
            "http://proxy.example:8080",
            "https://127.0.0.1:8443",
            "socks5://localhost:1080",
            "socks5h://[2001:db8::1]:1080",
        )
        rejected = (
            "http://user:password@proxy.example:8080",
            "https://proxy.example:8443/path",
            "https://proxy.example:8443?token=secret",
            "https://proxy.example:8443#fragment",
            "ftp://proxy.example:21",
            "http://proxy.example",
            "http://proxy..example:8080",
            "http://-proxy.example:8080",
            "http://[not-ipv6]:8080",
            "http://[fe80::1%eth0]:8080",
            "http://proxy.example:65536",
        )
        for proxy in accepted:
            with self.subTest(accepted=proxy):
                parsed = PARSER.parse_management_env(
                    replace_value(encode_values(), "PROXY", proxy)
                )
                self.assertEqual(parsed["PROXY"], proxy)
        for proxy in rejected:
            with self.subTest(rejected=proxy), self.assertRaises(
                PARSER.ManagementEnvError
            ):
                PARSER.parse_management_env(
                    replace_value(encode_values(), "PROXY", proxy)
                )

    def test_paths_are_canonical_and_production_paths_are_fixed(self) -> None:
        invalid = (
            "/srv/storage/cf-agent-wechat/../escape",
            "/srv//storage/cf-agent-wechat",
            "/srv/storage/cf-agent-wechat/",
            "relative/path",
        )
        for path in invalid:
            with self.subTest(path=path), self.assertRaises(
                PARSER.ManagementEnvError
            ):
                PARSER.parse_management_env(
                    replace_value(
                        encode_values(), "CF_AGENT_WECHAT_STORAGE_ROOT", path
                    )
                )

        with self.assertRaisesRegex(PARSER.ManagementEnvError, "fixed paths"):
            PARSER.parse_management_env(
                replace_value(
                    encode_values(),
                    "CF_AGENT_WECHAT_STORAGE_ROOT",
                    "/srv/storage/other",
                )
            )

    def test_portable_paths_must_be_under_one_non_nested_storage_root(self) -> None:
        values = valid_values()
        values.update(
            {
                "CF_AGENT_WECHAT_STORAGE_ROOT": "/tmp/fixture/storage",
                "CF_AGENT_WECHAT_RUNTIME_ROOT": "/tmp/fixture/storage/runtime",
                "CF_AGENT_WECHAT_ARCHIVE_ROOT": "/tmp/fixture/storage/archive",
            }
        )
        parsed = PARSER.parse_management_env(
            encode_values(values), path_contract="portable"
        )
        self.assertEqual(
            parsed["CF_AGENT_WECHAT_STORAGE_ROOT"], "/tmp/fixture/storage"
        )

        values["CF_AGENT_WECHAT_ARCHIVE_ROOT"] = "/tmp/fixture/storage/runtime/old"
        with self.assertRaisesRegex(PARSER.ManagementEnvError, "non-nested"):
            PARSER.parse_management_env(
                encode_values(values), path_contract="portable"
            )

    def test_json_and_nul_outputs_are_deterministic_and_unambiguous(self) -> None:
        values = PARSER.parse_management_env(encode_values())
        payload = json.loads(PARSER.render_json(values).decode("ascii"))
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["values"], values)

        records = PARSER.render_nul(values).split(b"\0")
        self.assertEqual(records[-1], b"")
        pairs = dict(
            zip(
                (item.decode("ascii") for item in records[0:-1:2]),
                (item.decode("utf-8") for item in records[1:-1:2]),
            )
        )
        self.assertEqual(pairs, values)
        self.assertFalse(any("TOKEN" == key or key.endswith("_TOKEN") for key in pairs))

    def test_safe_file_reader_rejects_symlink_hardlink_and_oversize(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "docker.env"
            source.write_bytes(encode_values())
            self.assertEqual(PARSER.read_management_env(source), encode_values())

            hardlink = root / "hardlink.env"
            os.link(source, hardlink)
            with self.assertRaisesRegex(PARSER.ManagementEnvError, "single-link"):
                PARSER.read_management_env(source)
            hardlink.unlink()

            symlink = root / "symlink.env"
            try:
                symlink.symlink_to(source)
            except OSError:
                symlink = None
            if symlink is not None:
                with self.assertRaisesRegex(
                    PARSER.ManagementEnvError, "single-link"
                ):
                    PARSER.read_management_env(symlink)

            oversized = root / "oversized.env"
            oversized.write_bytes(b"x" * (PARSER.MAX_INPUT_BYTES + 1))
            with self.assertRaisesRegex(PARSER.ManagementEnvError, "65536-byte"):
                PARSER.read_management_env(oversized)

    def test_cli_failure_is_fixed_and_does_not_echo_input(self) -> None:
        secret = "management-env-fixture-secret"
        with tempfile.TemporaryDirectory() as temporary:
            env_file = Path(temporary) / "docker.env"
            env_file.write_bytes(encode_values() + f"UNKNOWN={secret}\n".encode())
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--env-file", str(env_file)],
                check=False,
                capture_output=True,
                timeout=10,
            )

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(completed.stdout, b"")
        self.assertEqual(
            completed.stderr.replace(b"\r\n", b"\n"),
            b"docker/.env validation failed\n",
        )
        self.assertNotIn(secret.encode(), completed.stderr)


    def test_cli_json_and_nul_success_outputs_are_machine_readable(self) -> None:
        expected = valid_values()
        with tempfile.TemporaryDirectory() as temporary:
            env_file = Path(temporary) / "docker.env"
            env_file.write_bytes(encode_values(expected))
            json_result = subprocess.run(
                [sys.executable, str(SCRIPT), "--env-file", str(env_file)],
                check=False,
                capture_output=True,
                timeout=10,
            )
            nul_result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--env-file",
                    str(env_file),
                    "--format",
                    "nul",
                ],
                check=False,
                capture_output=True,
                timeout=10,
            )

        self.assertEqual(json_result.returncode, 0)
        self.assertEqual(json_result.stderr, b"")
        self.assertEqual(json.loads(json_result.stdout)["values"], expected)
        self.assertEqual(nul_result.returncode, 0)
        self.assertEqual(nul_result.stderr, b"")
        records = nul_result.stdout.split(b"\0")
        self.assertEqual(records[-1], b"")
        self.assertEqual(
            dict(
                zip(
                    (item.decode("ascii") for item in records[0:-1:2]),
                    (item.decode("utf-8") for item in records[1:-1:2]),
                )
            ),
            expected,
        )

if __name__ == "__main__":
    unittest.main(verbosity=2)
