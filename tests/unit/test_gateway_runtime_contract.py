#!/usr/bin/env python3
"""Static contracts for Gateway Runtime Controller version 1."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_HELPER = REPO_ROOT / "scripts" / "qr-runtime-common.sh"
START_SCRIPT = REPO_ROOT / "scripts" / "start-qr-login.sh"


def function_body(content: str, name: str) -> str:
    start = content.index(f"{name}() {{")
    next_function = re.search(
        r"^[A-Za-z_][A-Za-z0-9_]*\(\) \{",
        content[start + len(name) + 5 :],
        re.MULTILINE,
    )
    if next_function is None:
        return content[start:]
    end = start + len(name) + 5 + next_function.start()
    return content[start:end]


class GatewayRuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.content = RUNTIME_HELPER.read_text(encoding="utf-8")
        cls.start_content = START_SCRIPT.read_text(encoding="utf-8")

    def test_controller_path_is_fixed_and_not_environment_driven(self) -> None:
        self.assertIn(
            'GATEWAY_RUNTIME_CONTROL="/opt/cf-agent-gateway/deploy/'
            'wechat-runtime-control"',
            self.content,
        )
        self.assertNotIn("CF_AGENT_GATEWAY_RUNTIME_CONTROL", self.content)
        self.assertNotIn("${GATEWAY_RUNTIME_CONTROL:-", self.content)

    def test_contract_validation_is_bounded_and_exact_v1(self) -> None:
        body = function_body(self.content, "gateway_validate_runtime_contract")
        for fragment in (
            "runtime_authorize_sudo || return 1",
            "gateway_controller_check_file runtime_with_timeout",
            'runtime_with_timeout "$COMPOSE_COMMAND_TIMEOUT" --privileged',
            '"$GATEWAY_RUNTIME_CONTROL" contract',
            '"contract_version": 1',
            '"poll_worker_service": "worker"',
            '"delivery_worker_service": "delivery-worker"',
            '"dispatch_worker_service": "dispatch-worker"',
            '"token_mode": "file"',
            '"/run/secrets/cf-agent-wechat-auth-token"',
            "if set(payload) != set(expected):",
            'type(payload.get("contract_version")) is not int',
            "could not be read",
            "does not match required version 1",
        ):
            self.assertIn(fragment, body)

    def test_privilege_precedes_protected_controller_inspection(self) -> None:
        body = function_body(self.content, "gateway_validate_runtime_contract")
        self.assertLess(body.index("runtime_authorize_sudo"), body.index("gateway_controller_check_file"))
        shared = (REPO_ROOT / "scripts/gateway-controller-common.sh").read_text(encoding="utf-8")
        for fragment in (
            'controller=/opt/cf-agent-gateway/deploy/wechat-runtime-control',
            '[ ! -L "$directory" ]', '[ ! -L "$controller" ]',
            '[ -f "$controller" ]', '[ -x "$controller" ]',
            '[ "$owner:$group" = "0:0" ]', '07022', 'stat -c "%h"',
        ):
            self.assertIn(fragment, shared)
        bootstrap = (REPO_ROOT / "scripts/bootstrap-cfserver.sh").read_text(encoding="utf-8")
        self.assertIn("gateway_controller_check_file run_with_hard_timeout", bootstrap)
        self.assertNotIn('MANAGEMENT_UID="${SUDO_UID:-', bootstrap)

    def test_control_operations_use_fixed_controller_and_timeout(self) -> None:
        body = function_body(self.content, "gateway_runtime_control")
        self.assertIn("stop|start|status", body)
        self.assertIn('runtime_with_timeout "$GATEWAY_CONTROL_TIMEOUT"', body)
        self.assertEqual(body.count('"$GATEWAY_RUNTIME_CONTROL" "$@"'), 1)
        self.assertIn('runtime_with_timeout "$GATEWAY_CONTROL_TIMEOUT" --privileged', body)
        self.assertIn("requires prior sudo authorization", body)
        self.assertIn("Unsupported Gateway Runtime Contract operation", body)

    def test_stop_confirmation_precedes_fresh_qr_mutation(self) -> None:
        stop_body = function_body(self.content, "stop_gateway_workers")
        self.assertIn("gateway_runtime_control stop", stop_body)
        self.assertIn('set(payload) != {"stopped"}', stop_body)
        self.assertIn('payload.get("stopped") is not True', stop_body)
        self.assertIn("did not confirm both controlled workers stopped", stop_body)

        main_body = function_body(self.start_content, "main")
        stop = main_body.index("if ! stop_gateway_workers; then")
        for later in (
            "if ! stop_agent_container; then",
            "if ! archive_current_runtime; then",
            "if ! start_agent_container; then",
        ):
            self.assertLess(stop, main_body.index(later))

    def test_start_requires_valid_ready_status(self) -> None:
        start_body = function_body(self.content, "start_gateway_workers")
        self.assertLess(
            start_body.index("gateway_runtime_control start"),
            start_body.index("gateway_runtime_control status"),
        )
        for fragment in (
            "gateway_status_json_is_ready",
            "start command failed",
            "status command failed after start",
            "status is not ready after start",
        ):
            self.assertIn(fragment, start_body)

        ready_body = function_body(self.content, "gateway_status_json_is_ready")
        for fragment in (
            'payload.get("ready") is not True',
            'payload.get("token_contract_valid") is not True',
            'payload.get("worker_health") != "healthy"',
            'payload.get("delivery_health") != "healthy"',
        ):
            self.assertIn(fragment, ready_body)

    def test_status_summary_validates_types_and_health_fields(self) -> None:
        body = function_body(self.content, "gateway_status_summary")
        for fragment in (
            "gateway_runtime_control status",
            'ready = payload.get("ready")',
            'token_valid = payload.get("token_contract_valid")',
            'worker = payload.get("worker_health")',
            'delivery = payload.get("delivery_health")',
            "type(ready) is not bool",
            "type(token_valid) is not bool",
            r're.fullmatch(r"[a-z_]+", value)',
            "status response is invalid",
        ):
            self.assertIn(fragment, body)

    def test_legacy_compose_env_and_heartbeat_helpers_are_absent(self) -> None:
        for legacy in (
            "GATEWAY_COMPOSE_FILE",
            "GATEWAY_PROJECT_DIR",
            "GATEWAY_ENV_FILE",
            "GATEWAY_HEARTBEAT_COMMAND",
            "gateway_compose()",
            "gateway_worker_heartbeat_is_healthy()",
            "check-wechat-worker-heartbeat",
        ):
            with self.subTest(legacy=legacy):
                self.assertNotIn(legacy, self.content)


if __name__ == "__main__":
    unittest.main()