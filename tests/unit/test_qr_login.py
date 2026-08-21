#!/usr/bin/env python3
"""Unit tests for the dependency-free QR login control flow."""

from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import os
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


class FakeImage:
    def __init__(self, width: int, height: int, pixel: int) -> None:
        self.width = width
        self.height = height
        self.pixel = pixel

    def __enter__(self) -> "FakeImage":
        return self

    def __exit__(self, *_args: object) -> None:
        return

    def load(self) -> None:
        return

    def convert(self, _mode: str) -> "FakeImage":
        return self

    def getpixel(self, _coordinates: tuple[int, int]) -> int:
        return self.pixel


class FakeConnection:
    def __init__(
        self,
        events: list[dict[str, object] | str | bytes],
        *,
        recv_error: Exception | None = None,
    ) -> None:
        self.events = [
            json.dumps(event) if isinstance(event, dict) else event
            for event in events
        ]
        self.recv_error = recv_error
        self.closed = False

    def recv(self) -> str | bytes:
        if self.recv_error is not None:
            raise self.recv_error
        if self.events:
            return self.events.pop(0)
        return ""

    def close(self) -> None:
        self.closed = True


class QrLoginTests(unittest.TestCase):
    def run_listener_for_error(
        self,
        events: list[dict[str, object] | str | bytes],
        *,
        token: str = "fixture-token-never-printed",
        require_qr: bool = False,
        recv_error: Exception | None = None,
    ) -> tuple[FakeConnection, Exception]:
        connection = FakeConnection(events, recv_error=recv_error)
        websocket_module = types.SimpleNamespace(
            create_connection=lambda *_args, **_kwargs: connection
        )
        with (
            mock.patch.dict(sys.modules, {"websocket": websocket_module}),
            mock.patch.object(QR_LOGIN, "render_event_qr", return_value=True),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            with self.assertRaises(QR_LOGIN.LoginToolError) as raised:
                QR_LOGIN.listen_for_login(
                    "ws://127.0.0.1/api/ws/login",
                    token,
                    "default",
                    1000,
                    require_qr=require_qr,
                )
        return connection, raised.exception

    def assert_safe_error(self, error: Exception, token: str) -> str:
        message = str(error)
        self.assertNotIn(token, message)
        for character in message:
            self.assertFalse(
                ord(character) < 0x20 or ord(character) == 0x7F,
                repr(message),
            )
        return message

    def run_listener(
        self,
        events: list[dict[str, object]],
    ) -> tuple[FakeConnection, dict[str, object], str]:
        connection = FakeConnection(events)
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
            mock.patch.object(QR_LOGIN, "render_event_qr", return_value=True),
            contextlib.redirect_stdout(output),
        ):
            QR_LOGIN.listen_for_login(
                "ws://127.0.0.1/api/ws/login?newAccount=false",
                "fixture-token-never-printed",
                "default",
                1000,
                new_account=True,
                require_qr=True,
            )
        return connection, captured, output.getvalue()

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

    def test_nested_http_qr_payload_is_supported(self) -> None:
        with mock.patch.object(QR_LOGIN, "render_qr_content") as render:
            self.assertTrue(
                QR_LOGIN.render_event_qr(
                    {"success": False, "state": {"qrData": "fixture://qr"}}
                )
            )
        render.assert_called_once_with("fixture://qr")

    def test_fresh_listener_renders_qr_before_accepting_success(self) -> None:
        connection, captured, output = self.run_listener(
            [
                {"type": "qr", "qrData": "fixture://fresh-device"},
                {"type": "login_success"},
            ]
        )
        query = parse_qs(urlsplit(str(captured["url"])).query)
        self.assertEqual(query["newAccount"], ["true"])
        headers = captured["kwargs"]
        self.assertIn(
            "Authorization: Bearer fixture-token-never-printed",
            headers["header"],  # type: ignore[index]
        )
        self.assertIn("扫描二维码", output)
        self.assertIn("登录成功", output)
        self.assertNotIn("fixture-token-never-printed", output)
        self.assertTrue(connection.closed)

    def test_fresh_listener_rejects_success_without_qr(self) -> None:
        connection = FakeConnection(
            [{"type": "phone_confirm"}, {"type": "login_success"}]
        )
        websocket_module = types.SimpleNamespace(
            create_connection=lambda *_args, **_kwargs: connection
        )
        with mock.patch.dict(sys.modules, {"websocket": websocket_module}):
            with self.assertRaisesRegex(
                QR_LOGIN.LoginToolError, "未收到可显示的二维码"
            ):
                QR_LOGIN.listen_for_login(
                    "ws://127.0.0.1/api/ws/login",
                    "fixture-token-never-printed",
                    "default",
                    1000,
                    new_account=True,
                    require_qr=True,
                )
        self.assertTrue(connection.closed)

    def test_preceding_http_qr_cannot_authorize_websocket_success(self) -> None:
        with mock.patch.object(QR_LOGIN, "render_qr_content"):
            self.assertTrue(
                QR_LOGIN.render_event_qr(
                    {"success": False, "state": {"qrData": "fixture://stale-http"}}
                )
            )

        connection = FakeConnection([{"type": "login_success"}])
        websocket_module = types.SimpleNamespace(
            create_connection=lambda *_args, **_kwargs: connection
        )
        with (
            mock.patch.dict(sys.modules, {"websocket": websocket_module}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            with self.assertRaisesRegex(
                QR_LOGIN.LoginToolError, "未收到可显示的二维码"
            ):
                QR_LOGIN.listen_for_login(
                    "ws://127.0.0.1/api/ws/login",
                    "fixture-token-never-printed",
                    "default",
                    1000,
                    new_account=True,
                    require_qr=True,
                )
        self.assertTrue(connection.closed)

    def test_status_events_cannot_extend_total_deadline(self) -> None:
        connection = FakeConnection(
            [
                {"type": "status", "message": "still waiting"},
                {"type": "status", "message": "still waiting"},
                {"type": "login_success"},
            ]
        )
        websocket_module = types.SimpleNamespace(
            create_connection=lambda *_args, **_kwargs: connection
        )
        with (
            mock.patch.dict(sys.modules, {"websocket": websocket_module}),
            mock.patch.object(
                QR_LOGIN.time,
                "monotonic",
                side_effect=[100.0, 100.2, 101.1],
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "登录超时"):
                QR_LOGIN.listen_for_login(
                    "ws://127.0.0.1/api/ws/login",
                    "fixture-token-never-printed",
                    "default",
                    1000,
                )
        self.assertTrue(connection.closed)

    def test_websocket_connection_failure_sanitizes_external_error(self) -> None:
        token = "fixture-connect-secret"

        def fail_connection(*_args: object, **_kwargs: object) -> None:
            raise OSError(
                f"connection refused {token}\r\n\x1b\x00\t\x7f"
            )

        websocket_module = types.SimpleNamespace(
            create_connection=fail_connection
        )
        with mock.patch.dict(sys.modules, {"websocket": websocket_module}):
            with self.assertRaises(QR_LOGIN.LoginToolError) as raised:
                QR_LOGIN.listen_for_login(
                    "ws://127.0.0.1/api/ws/login",
                    token,
                    "default",
                    1000,
                )

        message = self.assert_safe_error(raised.exception, token)
        self.assertIn("无法连接登录 WebSocket", message)
        self.assertIn("[REDACTED]", message)

    def test_websocket_recv_failure_sanitizes_external_error(self) -> None:
        token = "fixture-recv-secret"
        recv_error = OSError(
            f"read failed {token}\r\n\x1b\x00\t\x7f"
        )
        connection, error = self.run_listener_for_error(
            [],
            token=token,
            recv_error=recv_error,
        )

        message = self.assert_safe_error(error, token)
        self.assertIn("读取登录事件失败", message)
        self.assertIn("[REDACTED]", message)
        self.assertTrue(connection.closed)

    def test_external_message_sanitizer_truncates_to_240(self) -> None:
        token = "fixture-sanitizer-secret"
        sanitized = QR_LOGIN._safe_external_message(
            f"{token}\r\n\x1b\x00\t\x7f" + "x" * 300,
            token,
        )

        self.assertEqual(len(sanitized), 240)
        self.assertTrue(sanitized.startswith("[REDACTED]"))
        self.assert_safe_error(QR_LOGIN.LoginToolError(sanitized), token)

    def test_invalid_json_and_non_utf8_events_fail_closed(self) -> None:
        token = "fixture-malformed-secret"
        cases: list[tuple[str | bytes, str]] = [
            (f"not-json {token}\r\n", "无法解析"),
            (token.encode("ascii") + b"\xff\r\n", "不是 UTF-8"),
        ]

        for raw_event, expected_message in cases:
            with self.subTest(expected_message=expected_message):
                connection, error = self.run_listener_for_error(
                    [raw_event], token=token
                )
                message = self.assert_safe_error(error, token)
                self.assertIn(expected_message, message)
                self.assertTrue(connection.closed)

    def test_login_timeout_event_fails_closed(self) -> None:
        token = "fixture-timeout-secret"
        connection, error = self.run_listener_for_error(
            [
                {
                    "type": "login_timeout",
                    "message": f"expired\r\n{token}\x7f",
                }
            ],
            token=token,
        )

        message = self.assert_safe_error(error, token)
        self.assertIn("登录超时", message)
        self.assertTrue(connection.closed)

    def test_server_error_event_redacts_token_and_controls(self) -> None:
        token = "fixture-server-secret"
        connection, error = self.run_listener_for_error(
            [
                {
                    "type": "error",
                    "message": f"denied\r\nAuthorization: {token}\x7f",
                }
            ],
            token=token,
        )

        message = self.assert_safe_error(error, token)
        self.assertIn("登录失败", message)
        self.assertIn("[REDACTED]", message)
        self.assertTrue(connection.closed)

    def test_connection_close_before_qr_or_success_fails_closed(self) -> None:
        token = "fixture-close-secret"
        cases = [
            ([], "显示二维码前断开"),
            (
                [{"type": "qr", "qrData": "fixture://fresh-device"}],
                "成功事件前断开",
            ),
        ]

        for events, expected_message in cases:
            with self.subTest(expected_message=expected_message):
                connection, error = self.run_listener_for_error(
                    events,
                    token=token,
                    require_qr=True,
                )
                message = self.assert_safe_error(error, token)
                self.assertIn(expected_message, message)
                self.assertTrue(connection.closed)

    def test_nondefault_session_id_is_rejected(self) -> None:
        for session_id in ("other", "", "default\nInjected: value"):
            with self.subTest(session_id=session_id):
                with self.assertRaisesRegex(
                    QR_LOGIN.LoginToolError, "必须是 default"
                ):
                    QR_LOGIN._validate_session_id(session_id)

    def test_terminal_width_never_exceeds_actual_columns(self) -> None:
        with (
            mock.patch.dict(os.environ, {"QR_MAX_WIDTH": "120"}, clear=False),
            mock.patch.object(
                QR_LOGIN.shutil,
                "get_terminal_size",
                return_value=os.terminal_size((32, 24)),
            ),
        ):
            self.assertEqual(QR_LOGIN._terminal_qr_width(), 30)

    def test_narrow_terminal_rejects_before_printing(self) -> None:
        matrix = [
            [(row + column) % 2 == 0 for column in range(29)]
            for row in range(29)
        ]
        output = io.StringIO()
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch.object(
                QR_LOGIN.shutil,
                "get_terminal_size",
                return_value=os.terminal_size((28, 24)),
            ),
            contextlib.redirect_stdout(output),
        ):
            with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "可用宽度仅 26"):
                QR_LOGIN._render_matrix(matrix)
        self.assertEqual(output.getvalue(), "")

    def test_blank_png_matrix_is_rejected(self) -> None:
        with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "深色或浅色"):
            self._render_fake_png(29, 29, 255)

    def test_tiny_png_matrix_is_rejected(self) -> None:
        with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "尺寸过小"):
            self._render_fake_png(1, 1, 0)

    def test_image_path_rejects_zero_or_narrow_width_before_resize(self) -> None:
        for columns in (1, 20):
            with self.subTest(columns=columns):
                with self.assertRaisesRegex(
                    QR_LOGIN.LoginToolError, "终端可用宽度"
                ):
                    self._render_fake_png(100, 100, 0, terminal_columns=columns)

    def _render_fake_png(
        self,
        width: int,
        height: int,
        pixel: int,
        *,
        terminal_columns: int = 100,
    ) -> None:
        image = FakeImage(width, height, pixel)
        pil_module = types.ModuleType("PIL")
        pil_module.Image = types.SimpleNamespace(open=lambda _stream: image)
        pil_module.ImageOps = types.SimpleNamespace(autocontrast=lambda value: value)
        pil_module.UnidentifiedImageError = ValueError
        encoded = base64.b64encode(b"fixture-png").decode("ascii")
        with (
            mock.patch.dict(sys.modules, {"PIL": pil_module}),
            mock.patch.object(
                QR_LOGIN.shutil,
                "get_terminal_size",
                return_value=os.terminal_size((terminal_columns, 24)),
            ),
        ):
            QR_LOGIN.render_png_base64(encoded)

    def test_error_message_redacts_token_and_controls(self) -> None:
        token = "fixture-secret"
        message = QR_LOGIN._safe_event_message(
            {"message": f"failed\r\nAuthorization: {token}"}, token
        )
        self.assertNotIn(token, message)
        self.assertNotIn("\r", message)
        self.assertNotIn("\n", message)
        self.assertIn("[REDACTED]", message)


if __name__ == "__main__":
    unittest.main()
