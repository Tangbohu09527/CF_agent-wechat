#!/usr/bin/env python3
"""Unit tests for the dependency-free parts of the QR login client."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import types
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit


REPO_ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "qr_login_under_test", REPO_ROOT / "scripts" / "qr_login.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load scripts/qr_login.py")
QR_LOGIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QR_LOGIN)


class FakeConnection:
    def __init__(self, events: list[dict[str, object]] | None = None) -> None:
        if events is None:
            events = [
                {
                    "type": "qr",
                    "qrData": "fixture://fresh-device-login",
                },
                {"type": "login_success"},
            ]
        self.events = [json.dumps(event) for event in events]
        self.closed = False

    def recv(self) -> str:
        return self.events.pop(0)

    def close(self) -> None:
        self.closed = True


class QrLoginTests(unittest.TestCase):
    def test_new_account_overrides_existing_false_query(self) -> None:
        result = QR_LOGIN._login_url(
            "ws://127.0.0.1/api/ws/login?newAccount=false&keep=value",
            1234,
            new_account=True,
        )
        query = parse_qs(urlsplit(result).query)
        self.assertEqual(query["newAccount"], ["true"])
        self.assertEqual(query["timeoutMs"], ["1234"])
        self.assertEqual(query["keep"], ["value"])

    def test_fresh_device_qr_event_is_rendered_on_forced_listener(self) -> None:
        connection = FakeConnection()
        captured: dict[str, object] = {}

        def create_connection(url: str, **kwargs: object) -> FakeConnection:
            captured["url"] = url
            captured["kwargs"] = kwargs
            return connection

        websocket_module = types.SimpleNamespace(
            create_connection=create_connection
        )
        output = io.StringIO()
        with (
            mock.patch.dict(sys.modules, {"websocket": websocket_module}),
            mock.patch.object(
                QR_LOGIN, "render_event_qr", return_value=True
            ) as render,
            contextlib.redirect_stdout(output),
        ):
            QR_LOGIN.listen_for_login(
                "ws://127.0.0.1/api/ws/login?newAccount=false",
                "fixture-token-never-printed",
                "default",
                1000,
                new_account=True,
            )

        query = parse_qs(urlsplit(str(captured["url"])).query)
        self.assertEqual(query["newAccount"], ["true"])
        render.assert_called_once()
        self.assertIn("扫描二维码", output.getvalue())
        self.assertIn("登录成功", output.getvalue())
        self.assertNotIn("fixture-token-never-printed", output.getvalue())
        self.assertTrue(connection.closed)

    def test_forced_listener_rejects_success_without_ever_receiving_qr(
        self,
    ) -> None:
        connection = FakeConnection(
            [{"type": "phone_confirm"}, {"type": "login_success"}]
        )
        websocket_module = types.SimpleNamespace(
            create_connection=lambda *_args, **_kwargs: connection
        )
        output = io.StringIO()
        with (
            mock.patch.dict(sys.modules, {"websocket": websocket_module}),
            mock.patch.object(
                QR_LOGIN, "render_event_qr", return_value=True
            ) as render,
            contextlib.redirect_stdout(output),
        ):
            with self.assertRaises(QR_LOGIN.LoginToolError):
                QR_LOGIN.listen_for_login(
                    "ws://127.0.0.1/api/ws/login",
                    "fixture-token-never-printed",
                    "default",
                    1000,
                    new_account=True,
                )

        render.assert_not_called()
        self.assertNotIn("fixture-token-never-printed", output.getvalue())
        self.assertTrue(connection.closed)

    def test_forced_listener_accepts_http_rendered_qr_evidence(self) -> None:
        connection = FakeConnection(
            [{"type": "phone_confirm"}, {"type": "login_success"}]
        )
        websocket_module = types.SimpleNamespace(
            create_connection=lambda *_args, **_kwargs: connection
        )
        output = io.StringIO()
        with (
            mock.patch.dict(sys.modules, {"websocket": websocket_module}),
            mock.patch.object(
                QR_LOGIN, "render_event_qr", return_value=True
            ) as render,
            contextlib.redirect_stdout(output),
        ):
            QR_LOGIN.listen_for_login(
                "ws://127.0.0.1/api/ws/login",
                "fixture-token-never-printed",
                "default",
                1000,
                new_account=True,
                qr_already_rendered=True,
            )

        render.assert_not_called()
        self.assertIn("请在手机微信确认登录", output.getvalue())
        self.assertIn("登录成功", output.getvalue())
        self.assertNotIn("fixture-token-never-printed", output.getvalue())
        self.assertTrue(connection.closed)


if __name__ == "__main__":
    unittest.main()
