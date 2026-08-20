#!/usr/bin/env python3
"""Render WeChat login QR codes and consume the login WebSocket."""

from __future__ import annotations

import argparse
import base64
import binascii
import io
import json
import os
import shutil
import sys
from typing import Any, Sequence
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


NO_QR_DATA = 4
MAX_TOKEN_BYTES = 8192


class LoginToolError(Exception):
    """Expected error that should be shown without a traceback."""


def _terminal_qr_width() -> int:
    configured = os.environ.get("QR_MAX_WIDTH")
    if configured:
        try:
            width = int(configured)
        except ValueError as exc:
            raise LoginToolError("QR_MAX_WIDTH 必须是整数。") from exc
        if width < 21:
            raise LoginToolError("QR_MAX_WIDTH 不能小于 21。")
        return width

    columns = shutil.get_terminal_size(fallback=(100, 24)).columns
    return max(21, min(columns - 2, 120))


def _render_matrix(matrix: Sequence[Sequence[bool]]) -> None:
    if not matrix or not matrix[0]:
        raise LoginToolError("二维码图像为空。")

    width = len(matrix[0])
    if any(len(row) != width for row in matrix):
        raise LoginToolError("二维码图像尺寸不一致。")

    use_color = (
        sys.stdout.isatty()
        and os.environ.get("TERM", "") != "dumb"
        and "NO_COLOR" not in os.environ
    )
    prefix = "\033[30;47m" if use_color else ""
    suffix = "\033[0m" if use_color else ""
    padded = list(matrix)
    if len(padded) % 2:
        padded.append([False] * width)

    glyphs = {
        (False, False): " ",
        (True, False): "▀",
        (False, True): "▄",
        (True, True): "█",
    }
    for row_index in range(0, len(padded), 2):
        top = padded[row_index]
        bottom = padded[row_index + 1]
        line = "".join(glyphs[(bool(a), bool(b))] for a, b in zip(top, bottom))
        print(f"{prefix}{line}{suffix}")


def _matrix_from_image(image_bytes: bytes) -> list[list[bool]]:
    try:
        from PIL import Image, ImageOps, UnidentifiedImageError
    except ImportError as exc:
        raise LoginToolError("缺少 Pillow，请通过 requirements.txt 安装依赖。") from exc

    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            image.load()
            grayscale = ImageOps.autocontrast(image.convert("L"))
    except (UnidentifiedImageError, OSError) as exc:
        raise LoginToolError("输入数据不是有效的二维码图片。") from exc

    max_width = _terminal_qr_width()
    if grayscale.width > max_width:
        ratio = max_width / grayscale.width
        target_height = max(1, round(grayscale.height * ratio))
        grayscale = grayscale.resize((max_width, target_height), Image.Resampling.NEAREST)

    threshold = 128
    return [
        [grayscale.getpixel((x, y)) < threshold for x in range(grayscale.width)]
        for y in range(grayscale.height)
    ]


def _decode_png_base64(value: str) -> bytes:
    payload = value.strip()
    if payload.startswith("data:"):
        header, separator, payload = payload.partition(",")
        if not separator or ";base64" not in header.lower():
            raise LoginToolError("二维码 data URL 不是 Base64 图片。")

    compact = "".join(payload.split())
    if not compact:
        raise LoginToolError("二维码 Base64 数据为空。")
    try:
        return base64.b64decode(compact, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise LoginToolError("二维码 Base64 数据无效。") from exc


def render_png_base64(value: str) -> None:
    _render_matrix(_matrix_from_image(_decode_png_base64(value)))


def render_qr_content(value: str) -> None:
    try:
        import qrcode
        from qrcode.exceptions import DataOverflowError
    except ImportError as exc:
        raise LoginToolError("缺少 qrcode，请通过 requirements.txt 安装依赖。") from exc

    if not value:
        raise LoginToolError("二维码内容为空。")
    qr = qrcode.QRCode(border=4, box_size=1)
    try:
        qr.add_data(value)
        qr.make(fit=True)
    except (DataOverflowError, ValueError) as exc:
        raise LoginToolError("QR content is too long to render.") from exc
    matrix = [[bool(cell) for cell in row] for row in qr.get_matrix()]
    _render_matrix(matrix)


def _binary_qr_content(value: Any) -> str:
    if isinstance(value, list):
        try:
            raw = bytes(value)
        except (TypeError, ValueError) as exc:
            raise LoginToolError("qrBinaryData 必须是字节数组。") from exc
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise LoginToolError("qrBinaryData 不是 UTF-8 二维码内容。") from exc
    if isinstance(value, str):
        return value
    raise LoginToolError("不支持的 qrBinaryData 格式。")


def render_event_qr(event: dict[str, Any]) -> bool:
    qr_binary_data = event.get("qrBinaryData")
    if qr_binary_data not in (None, "", []):
        render_qr_content(_binary_qr_content(qr_binary_data))
        return True

    qr_data = event.get("qrData")
    if isinstance(qr_data, str) and qr_data:
        render_qr_content(qr_data)
        return True

    qr_data_url = event.get("qrDataUrl")
    if isinstance(qr_data_url, str) and qr_data_url:
        render_png_base64(qr_data_url)
        return True

    return False


def _read_json_stdin() -> dict[str, Any]:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise LoginToolError(f"输入不是有效 JSON：{exc}") from exc
    if not isinstance(payload, dict):
        raise LoginToolError("二维码事件必须是 JSON 对象。")
    return payload


def _read_token_stdin() -> str:
    try:
        raw_token = sys.stdin.buffer.read(MAX_TOKEN_BYTES + 1)
    except OSError as exc:
        raise LoginToolError("无法从标准输入读取 token。") from exc
    if len(raw_token) > MAX_TOKEN_BYTES:
        raise LoginToolError("token 长度超过安全限制。")
    if not raw_token:
        raise LoginToolError("标准输入中没有 token。")
    if b"\n" in raw_token or b"\r" in raw_token:
        raise LoginToolError("token 必须只包含一行非空内容。")
    try:
        return raw_token.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise LoginToolError("token 不是有效的 UTF-8 文本。") from exc


def _login_url(url: str, timeout_ms: int, new_account: bool = False) -> str:
    parts = urlsplit(url)
    if parts.scheme not in {"ws", "wss"} or not parts.netloc:
        raise LoginToolError("WebSocket URL 必须是有效的 ws:// 或 wss:// 地址。")
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    query.setdefault("timeoutMs", str(timeout_ms))
    if new_account:
        query["newAccount"] = "true"
    else:
        query.setdefault("newAccount", "false")
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


def listen_for_login(
    url: str,
    token: str,
    session_id: str,
    timeout_ms: int,
    new_account: bool = False,
    qr_already_rendered: bool = False,
) -> None:
    try:
        import websocket
    except ImportError as exc:
        raise LoginToolError(
            "缺少 websocket-client，请通过 requirements.txt 安装依赖。"
        ) from exc

    headers = [
        f"Authorization: Bearer {token}",
        f"X-Session-Id: {session_id}",
    ]
    socket_timeout = max(30, timeout_ms / 1000 + 15)

    try:
        connection = websocket.create_connection(
            _login_url(url, timeout_ms, new_account),
            header=headers,
            timeout=socket_timeout,
            http_no_proxy=["*"],
        )
    except Exception as exc:
        raise LoginToolError("无法连接登录 WebSocket。") from exc

    terminal_event = False
    qr_rendered = qr_already_rendered
    try:
        while True:
            try:
                raw_event = connection.recv()
            except Exception as exc:
                raise LoginToolError("读取登录事件失败。") from exc
            if raw_event in (None, "", b""):
                break
            if isinstance(raw_event, bytes):
                try:
                    raw_event = raw_event.decode("utf-8")
                except UnicodeDecodeError as exc:
                    raise LoginToolError("登录事件不是 UTF-8 JSON。") from exc

            try:
                event = json.loads(raw_event)
            except json.JSONDecodeError as exc:
                raise LoginToolError("收到无法解析的登录事件。") from exc
            if not isinstance(event, dict):
                raise LoginToolError("收到格式错误的登录事件。")

            event_type = event.get("type")
            if event_type == "status":
                print("正在启动微信登录流程")
            elif event_type == "qr":
                print("请使用手机微信扫描二维码：")
                if not render_event_qr(event):
                    raise LoginToolError("登录事件未包含可显示的二维码数据。")
                qr_rendered = True
            elif event_type == "phone_confirm":
                print("请在手机微信确认登录")
            elif event_type == "login_success":
                terminal_event = True
                if new_account and not qr_rendered:
                    raise LoginToolError(
                        "强制新设备登录未收到可显示的二维码，拒绝接受登录成功事件。"
                    )
                print("登录成功。")
                return
            elif event_type == "login_timeout":
                terminal_event = True
                raise LoginToolError(
                    "登录超时，请重新执行 ./scripts/start-qr-login.sh。"
                )
            elif event_type == "error":
                terminal_event = True
                raise LoginToolError("登录失败：agent-wechat 登录流程返回错误。")
    finally:
        connection.close()

    if not terminal_event:
        raise LoginToolError("登录 WebSocket 在成功事件前断开。")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="在终端显示微信登录二维码。")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--render-json",
        action="store_true",
        help="从标准输入读取事件 JSON 并显示其中的二维码。",
    )
    mode.add_argument(
        "--listen",
        action="store_true",
        help="连接登录 WebSocket 并处理登录事件。",
    )
    parser.add_argument("--url", help="登录 WebSocket URL。")
    parser.add_argument("--session-id", default="default", help="agent-wechat session ID。")
    parser.add_argument("--timeout-ms", type=int, default=300000, help="登录超时毫秒数。")
    parser.add_argument(
        "--new-account",
        action="store_true",
        help="强制 WebSocket 使用 newAccount=true。",
    )
    parser.add_argument(
        "--qr-already-rendered",
        action="store_true",
        help="HTTP 登录响应已经成功显示二维码。",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.listen:
        if not args.url:
            raise LoginToolError("--listen 需要 --url。")
        if args.timeout_ms <= 0:
            raise LoginToolError("--timeout-ms 必须大于 0。")
        token = _read_token_stdin()
        listen_for_login(
            args.url,
            token,
            args.session_id,
            args.timeout_ms,
            new_account=args.new_account,
            qr_already_rendered=args.qr_already_rendered,
        )
        return 0

    if args.render_json:
        event = _read_json_stdin()
        if not render_event_qr(event):
            return NO_QR_DATA
        return 0

    render_png_base64(sys.stdin.read())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LoginToolError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        raise SystemExit(1) from None
    except KeyboardInterrupt:
        print("\n登录已取消。", file=sys.stderr)
        raise SystemExit(130) from None
