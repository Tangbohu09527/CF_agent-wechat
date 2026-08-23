#!/usr/bin/env python3
"""Unit tests for the dependency-free QR login control flow."""

from __future__ import annotations

import contextlib
import base64
import importlib.util
import io
import json
import logging
import os
import sys
import traceback
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
    def __init__(
        self,
        events: list[dict[str, object] | str | bytes] | None = None,
        *,
        set_timeout_error: Exception | None = None,
        recv_error: Exception | None = None,
        close_error: Exception | None = None,
    ) -> None:
        self.events = [
            json.dumps(event) if isinstance(event, dict) else event
            for event in (events or [])
        ]
        self.set_timeout_error = set_timeout_error
        self.recv_error = recv_error
        self.close_error = close_error
        self.closed = False
        self.timeouts: list[float] = []

    def settimeout(self, timeout: float) -> None:
        if self.set_timeout_error is not None:
            raise self.set_timeout_error
        self.timeouts.append(timeout)

    def recv(self) -> str | bytes:
        if self.recv_error is not None:
            raise self.recv_error
        if self.events:
            return self.events.pop(0)
        return ""

    def close(self) -> None:
        self.closed = True
        if self.close_error is not None:
            raise self.close_error


class QrLoginTests(unittest.TestCase):
    def run_listener_for_error(
        self,
        events: list[dict[str, object] | str | bytes],
        *,
        token: str = "fixture-token-never-printed",
        new_account: bool = False,
        qr_already_rendered: bool = False,
        require_qr: bool = False,
        set_timeout_error: Exception | None = None,
        recv_error: Exception | None = None,
        close_error: Exception | None = None,
    ) -> tuple[FakeConnection, Exception]:
        connection = FakeConnection(
            events,
            set_timeout_error=set_timeout_error,
            recv_error=recv_error,
            close_error=close_error,
        )
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
                    new_account=new_account,
                    qr_already_rendered=qr_already_rendered,
                    require_qr=require_qr,
                )
        return connection, raised.exception

    def assert_safe_error(self, error: Exception, token: str) -> str:
        message = str(error)
        self.assertNotIn(token, message)
        self.assertNotIn(token, repr(error))
        self.assertIsNone(error.__cause__)
        self.assertIsNone(error.__context__)
        self.assertNotIn(token, "".join(traceback.format_exception(error)))

        output = io.StringIO()
        logger = logging.getLogger(f"{__name__}.{self.id()}")
        logger.handlers.clear()
        logger.propagate = False
        logger.setLevel(logging.ERROR)
        handler = logging.StreamHandler(output)
        logger.addHandler(handler)
        try:
            try:
                raise error
            except Exception:
                logger.exception("captured sanitized login error")
        finally:
            logger.removeHandler(handler)
            handler.close()
        self.assertNotIn(token, output.getvalue())

        for character in message:
            self.assertFalse(
                ord(character) < 0x20 or ord(character) == 0x7F,
                repr(message),
            )
        return message

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

    def test_websocket_url_rejects_embedded_credentials(self) -> None:
        with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "用户名或密码"):
            QR_LOGIN._login_url(
                "ws://user:secret@127.0.0.1/api/ws/login",
                1000,
            )

    def test_nested_qr_payload_is_supported(self) -> None:
        with mock.patch.object(QR_LOGIN, "render_qr_content") as render:
            self.assertTrue(
                QR_LOGIN.render_event_qr(
                    {"success": False, "state": {"qrData": "fixture://qr"}}
                )
            )
        render.assert_called_once_with("fixture://qr")

    def test_fresh_listener_renders_current_ws_qr_before_success(self) -> None:
        connection = FakeConnection(
            [
                {"type": "qr", "qrData": "fixture://fresh-device"},
                {"type": "login_success"},
            ]
        )
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
        connection_options = captured["kwargs"]
        self.assertIsInstance(connection_options, dict)
        self.assertEqual(connection_options["redirect_limit"], 0)
        self.assertEqual(connection_options["http_no_proxy"], ["*"])
        render.assert_called_once_with(
            {"type": "qr", "qrData": "fixture://fresh-device"},
            "fixture-token-never-printed",
            allow_png=False,
        )
        self.assertIn("扫描二维码", output.getvalue())
        self.assertIn("登录成功", output.getvalue())
        self.assertNotIn("fixture-token-never-printed", output.getvalue())
        self.assertTrue(connection.closed)
        self.assertTrue(connection.timeouts)

    def test_new_account_rejects_success_without_current_ws_qr(self) -> None:
        connection, error = self.run_listener_for_error(
            [{"type": "phone_confirm"}, {"type": "login_success"}],
            new_account=True,
        )
        self.assertIn("当前 WebSocket", str(error))
        self.assertTrue(connection.closed)

    def test_http_qr_evidence_cannot_authorize_fresh_success(self) -> None:
        connection, error = self.run_listener_for_error(
            [{"type": "phone_confirm"}, {"type": "login_success"}],
            new_account=True,
            qr_already_rendered=True,
        )
        self.assertIn("当前 WebSocket", str(error))
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
            raise OSError(f"connection refused {token}\r\n\x1b\x00\t\x7f")

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
        connection, error = self.run_listener_for_error(
            [],
            token=token,
            recv_error=OSError(f"read failed {token}\r\n\x1b\x00\t\x7f"),
        )

        message = self.assert_safe_error(error, token)
        self.assertIn("读取登录事件失败", message)
        self.assertIn("[REDACTED]", message)
        self.assertTrue(connection.closed)

    def test_websocket_settimeout_failure_sanitizes_external_error(self) -> None:
        token = "fixture-settimeout-secret"
        connection, error = self.run_listener_for_error(
            [],
            token=token,
            set_timeout_error=OSError(
                f"settimeout failed {token}\r\n\x1b\x00\t\x7f"
            ),
        )
        message = self.assert_safe_error(error, token)
        self.assertIn("无法设置登录 WebSocket 超时", message)
        self.assertIn("[REDACTED]", message)
        self.assertTrue(connection.closed)

    def test_close_failure_does_not_override_receive_error(self) -> None:
        token = "fixture-close-secret"
        connection, error = self.run_listener_for_error(
            [],
            token=token,
            recv_error=OSError(f"primary read failure {token}"),
            close_error=OSError(f"secondary close failure {token}"),
        )

        message = self.assert_safe_error(error, token)
        self.assertIn("读取登录事件失败", message)
        self.assertNotIn("secondary close failure", message)
        self.assertTrue(connection.closed)

    def test_close_failure_does_not_override_success(self) -> None:
        connection = FakeConnection(
            [
                {"type": "qr", "qrData": "fixture://fresh-device"},
                {"type": "login_success"},
            ],
            close_error=OSError("close failed"),
        )
        websocket_module = types.SimpleNamespace(
            create_connection=lambda *_args, **_kwargs: connection
        )
        with (
            mock.patch.dict(sys.modules, {"websocket": websocket_module}),
            mock.patch.object(QR_LOGIN, "render_event_qr", return_value=True),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            QR_LOGIN.listen_for_login(
                "ws://127.0.0.1/api/ws/login",
                "fixture-token-never-printed",
                "default",
                1000,
                new_account=True,
            )
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
            (
                f"not-json {token}".encode("utf-8") + b"\xff\r\n",
                "不是 UTF-8",
            ),
        ]

        for raw_event, expected_message in cases:
            with self.subTest(expected_message=expected_message):
                connection, error = self.run_listener_for_error(
                    [raw_event],
                    token=token,
                )
                message = self.assert_safe_error(error, token)
                self.assertIn(expected_message, message)
                self.assertTrue(connection.closed)

    def test_timeout_and_server_error_events_fail_closed(self) -> None:
        token = "fixture-event-secret"
        cases = [
            (
                {
                    "type": "login_timeout",
                    "message": f"expired\r\n{token}\x7f",
                },
                "登录超时",
            ),
            (
                {
                    "type": "error",
                    "message": f"denied\r\nAuthorization: {token}\x7f",
                },
                "登录失败",
            ),
        ]

        for event, expected_message in cases:
            with self.subTest(expected_message=expected_message):
                connection, error = self.run_listener_for_error(
                    [event],
                    token=token,
                )
                message = self.assert_safe_error(error, token)
                self.assertIn(expected_message, message)
                self.assertTrue(connection.closed)

    def test_connection_close_before_qr_or_success_fails_closed(self) -> None:
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
                    require_qr=True,
                    close_error=OSError("close failure must be ignored"),
                )
                self.assertIn(expected_message, str(error))
                self.assertTrue(connection.closed)

    def test_nondefault_session_id_is_rejected(self) -> None:
        for session_id in ("other", "", "default\nInjected: value"):
            with self.subTest(session_id=session_id):
                with self.assertRaisesRegex(
                    QR_LOGIN.LoginToolError,
                    "必须是 default",
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


    def test_token_bearing_qr_event_is_rejected_before_rendering(self) -> None:
        token = "fixture-qr-secret"
        with mock.patch.object(QR_LOGIN, "render_qr_content") as render:
            with self.assertRaises(QR_LOGIN.LoginToolError) as raised:
                QR_LOGIN.render_event_qr(
                    {"type": "qr", "qrData": f"fixture://{token}"},
                    token,
                )
        message = self.assert_safe_error(raised.exception, token)
        self.assertIn("受保护", message)
        render.assert_not_called()

    def test_png_data_url_requires_png_mime_and_signature(self) -> None:
        valid_payload = base64.b64encode(QR_LOGIN.PNG_SIGNATURE).decode("ascii")
        with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "Base64 PNG"):
            QR_LOGIN._decode_png_base64(
                f"data:image/jpeg;base64,{valid_payload}"
            )
        with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "PNG 签名"):
            QR_LOGIN._decode_png_base64(
                "data:image/png;base64,"
                + base64.b64encode(b"not-a-png").decode("ascii")
            )
        self.assertEqual(
            QR_LOGIN._decode_png_base64(
                f"data:image/png;base64,{valid_payload}"
            ),
            QR_LOGIN.PNG_SIGNATURE,
        )

    def test_png_encoded_and_decoded_size_limits_fail_before_render(self) -> None:
        with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "编码长度"):
            QR_LOGIN._decode_png_base64(
                "A" * (QR_LOGIN.MAX_QR_BASE64_CHARS + 1)
            )

        oversized = QR_LOGIN.PNG_SIGNATURE + (
            b"x" * QR_LOGIN.MAX_QR_IMAGE_BYTES
        )
        with mock.patch.object(
            QR_LOGIN.base64, "b64decode", return_value=oversized
        ):
            with self.assertRaisesRegex(QR_LOGIN.LoginToolError, "解码长度"):
                QR_LOGIN._decode_png_base64("iVBORw0KGgo=")

    def test_png_dimension_pixel_format_and_frame_limits(self) -> None:
        class FakeImage:
            def __init__(
                self,
                size: tuple[int, int],
                image_format: str = "PNG",
                frames: int = 1,
            ) -> None:
                self.size = size
                self.format = image_format
                self.n_frames = frames

            def __enter__(self) -> "FakeImage":
                return self

            def __exit__(self, *_args: object) -> None:
                return None

            def load(self) -> None:
                raise AssertionError("oversized image must fail before decoding")

        cases = (
            ((2049, 29), "PNG", 1, "尺寸超过"),
            ((2001, 2000), "PNG", 1, "像素数超过"),
            ((29, 29), "JPEG", 1, "必须是 PNG"),
            ((29, 29), "PNG", 2, "多个图像帧"),
        )
        for size, image_format, frames, message in cases:
            with self.subTest(message=message):
                image_module = types.SimpleNamespace(
                    open=lambda *_args, size=size, image_format=image_format,
                    frames=frames: FakeImage(size, image_format, frames),
                    Resampling=types.SimpleNamespace(NEAREST=0),
                )
                pillow_module = types.SimpleNamespace(
                    Image=image_module,
                    ImageOps=types.SimpleNamespace(autocontrast=lambda value: value),
                    UnidentifiedImageError=OSError,
                )
                with mock.patch.dict(sys.modules, {"PIL": pillow_module}):
                    with self.assertRaisesRegex(QR_LOGIN.LoginToolError, message):
                        QR_LOGIN._matrix_from_image(QR_LOGIN.PNG_SIGNATURE)

    def test_production_fresh_qr_rejects_png_only_events(self) -> None:
        token = "fixture-png-secret"
        with mock.patch.object(QR_LOGIN, "render_png_base64") as render:
            with self.assertRaises(QR_LOGIN.LoginToolError) as raised:
                QR_LOGIN.render_event_qr(
                    {
                        "type": "qr",
                        "qrDataUrl": "data:image/png;base64,ZmFrZQ==",
                    },
                    token,
                    allow_png=False,
                )
        self.assertIn("图片型二维码", str(raised.exception))
        render.assert_not_called()



if __name__ == "__main__":
    unittest.main()
