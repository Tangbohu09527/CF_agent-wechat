#!/usr/bin/env python3
"""Minimal same-origin HTTP/WebSocket mock for login integration tests."""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import signal
import struct
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class MockState:
    def __init__(
        self,
        token_file: Path,
        state_file: Path,
        log_file: Path,
        pause_file: Path,
        continue_file: Path,
    ) -> None:
        self.token = token_file.read_text(encoding="utf-8").rstrip("\n")
        self.state_file = state_file
        self.log_file = log_file
        self.pause_file = pause_file
        self.continue_file = continue_file
        self.lock = threading.Lock()

    def status(self) -> str:
        return self.state_file.read_text(encoding="utf-8").strip()

    def set_status(self, status: str) -> None:
        self.state_file.write_text(status + "\n", encoding="utf-8")

    def record(self, message: str) -> None:
        with self.lock:
            with self.log_file.open("a", encoding="utf-8") as stream:
                stream.write(message + "\n")


def websocket_frame(payload: str) -> bytes:
    encoded = payload.encode("utf-8")
    length = len(encoded)
    if length < 126:
        header = bytes((0x81, length))
    elif length <= 0xFFFF:
        header = bytes((0x81, 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x81, 127)) + struct.pack("!Q", length)
    return header + encoded


class MockHttpServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], state: MockState) -> None:
        super().__init__(address, MockHttpHandler)
        self.state = state


class MockHttpHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    @property
    def mock(self) -> MockState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, *_args: Any) -> None:
        return

    def authorized(self) -> bool:
        return self.headers.get("Authorization") == f"Bearer {self.mock.token}"

    def respond(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        request_path = urlsplit(self.path).path
        if request_path == "/api/ws/login":
            try:
                self.handle_login_websocket()
            except Exception as exc:
                self.mock.record(f"WS_ERROR {type(exc).__name__}")
                self.close_connection = True
            return

        if request_path == "/health":
            self.mock.record("GET /health")
            self.respond(200, {"status": "ok"})
            return

        if request_path != "/api/status/auth":
            self.respond(404, {"error": "not found"})
            return
        if not self.authorized():
            self.respond(401, {"error": "unauthorized"})
            return

        self.mock.record("GET /api/status/auth")
        status = self.mock.status()
        payload: dict[str, object] = {"status": status}
        if status == "logged_in":
            payload["loggedInUser"] = "wxid_permissions_test"
        self.respond(200, payload)

    def handle_login_websocket(self) -> None:
        parsed_path = urlsplit(self.path)
        query = parse_qs(parsed_path.query, keep_blank_values=True)
        if self.headers.get("Upgrade", "").lower() != "websocket":
            raise ConnectionError("missing WebSocket upgrade")
        if query.get("newAccount", [""])[-1] != "true":
            raise ConnectionError("newAccount=true is required")
        if not self.authorized():
            raise ConnectionError("unauthorized WebSocket")
        if self.headers.get("X-Session-Id") != "default":
            raise ConnectionError("unexpected session id")

        websocket_key = self.headers.get("Sec-WebSocket-Key")
        if not websocket_key:
            raise ConnectionError("missing WebSocket key")
        accept_value = base64.b64encode(
            hashlib.sha1((websocket_key + WEBSOCKET_GUID).encode("ascii")).digest()
        ).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept_value)
        self.end_headers()
        self.close_connection = True

        self.mock.record("WS /api/ws/login")
        self.mock.pause_file.touch()
        deadline = time.monotonic() + 60
        while not self.mock.continue_file.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("test did not release WebSocket events")
            time.sleep(0.05)

        events = [
            {"type": "status", "message": "Navigating login flow..."},
            {"type": "qr", "qrData": "fixture://fresh-device-login"},
            {"type": "phone_confirm"},
        ]
        for event in events:
            self.connection.sendall(websocket_frame(json.dumps(event)))
            if event["type"] in {"qr", "phone_confirm"}:
                self.mock.record(f"EVENT {event['type']}")

        self.mock.set_status("logged_in")
        self.mock.record("EVENT login_success")
        self.connection.sendall(
            websocket_frame(
                json.dumps(
                    {"type": "login_success", "userId": "wxid_permissions_test"}
                )
            )
        )
        time.sleep(0.1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--state-file", type=Path, required=True)
    parser.add_argument("--log-file", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    parser.add_argument("--pause-file", type=Path, required=True)
    parser.add_argument("--continue-file", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    state = MockState(
        args.token_file,
        args.state_file,
        args.log_file,
        args.pause_file,
        args.continue_file,
    )
    stop = threading.Event()
    http_server = MockHttpServer(("127.0.0.1", 0), state)
    http_thread = threading.Thread(target=http_server.serve_forever, daemon=True)
    http_thread.start()

    def shutdown(_signum: int, _frame: object) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    port = http_server.server_address[1]
    ready_temp = args.ready_file.with_suffix(args.ready_file.suffix + ".tmp")
    ready_temp.write_text(
        json.dumps({"http_port": port, "ws_port": port}),
        encoding="utf-8",
    )
    ready_temp.replace(args.ready_file)

    while not stop.wait(0.2):
        pass

    http_server.shutdown()
    http_server.server_close()
    http_thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())