#!/usr/bin/env python3
"""Minimal HTTP/WebSocket mock for login management integration tests."""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import signal
import socket
import struct
import threading
import time
from pathlib import Path
from typing import Any


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
        if self.path != "/api/status/auth":
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

    def do_POST(self) -> None:
        if self.path != "/api/status/login":
            self.respond(404, {"error": "not found"})
            return
        if not self.authorized():
            self.respond(401, {"error": "unauthorized"})
            return

        self.mock.record("POST /api/status/login")
        self.respond(200, {"success": False, "state": {"status": "qr_pending"}})


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


def read_websocket_request(connection: socket.socket) -> tuple[str, dict[str, str]]:
    request = bytearray()
    while b"\r\n\r\n" not in request:
        chunk = connection.recv(4096)
        if not chunk:
            raise ConnectionError("client closed during handshake")
        request.extend(chunk)
        if len(request) > 65536:
            raise ConnectionError("handshake is too large")

    lines = bytes(request).decode("iso-8859-1").split("\r\n")
    request_path = lines[0].split(" ", 2)[1]
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        name, value = line.split(":", 1)
        headers[name.lower()] = value.strip()
    return request_path, headers


def handle_websocket(connection: socket.socket, state: MockState) -> None:
    connection.settimeout(30)
    path, headers = read_websocket_request(connection)
    if not path.startswith("/api/ws/login"):
        raise ConnectionError("unexpected WebSocket path")
    if headers.get("authorization") != f"Bearer {state.token}":
        raise ConnectionError("unauthorized WebSocket")
    if headers.get("x-session-id") != "default":
        raise ConnectionError("unexpected session id")

    websocket_key = headers.get("sec-websocket-key")
    if not websocket_key:
        raise ConnectionError("missing WebSocket key")
    accept_value = base64.b64encode(
        hashlib.sha1((websocket_key + WEBSOCKET_GUID).encode("ascii")).digest()
    ).decode("ascii")
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept_value}\r\n"
        "\r\n"
    )
    connection.sendall(response.encode("ascii"))
    state.record("WS /api/ws/login")
    state.pause_file.touch()

    deadline = time.monotonic() + 60
    while not state.continue_file.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError("test did not release WebSocket events")
        time.sleep(0.05)

    events = [
        {"type": "status", "message": "Navigating login flow..."},
        {"type": "phone_confirm"},
    ]
    for event in events:
        connection.sendall(websocket_frame(json.dumps(event)))
    state.record("EVENT phone_confirm")

    state.set_status("logged_in")
    state.record("EVENT login_success")
    connection.sendall(
        websocket_frame(
            json.dumps({"type": "login_success", "userId": "wxid_permissions_test"})
        )
    )
    time.sleep(0.1)


def serve_websockets(listener: socket.socket, state: MockState, stop: threading.Event) -> None:
    listener.settimeout(0.5)
    while not stop.is_set():
        try:
            connection, _address = listener.accept()
        except TimeoutError:
            continue
        except OSError:
            break
        try:
            with connection:
                handle_websocket(connection, state)
        except Exception as exc:
            state.record(f"WS_ERROR {type(exc).__name__}")


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

    websocket_listener = socket.socket()
    websocket_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    websocket_listener.bind(("127.0.0.1", 0))
    websocket_listener.listen()
    websocket_thread = threading.Thread(
        target=serve_websockets,
        args=(websocket_listener, state, stop),
        daemon=True,
    )
    websocket_thread.start()

    def shutdown(_signum: int, _frame: object) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    ready_temp = args.ready_file.with_suffix(args.ready_file.suffix + ".tmp")
    ready_temp.write_text(
        json.dumps(
            {
                "http_port": http_server.server_address[1],
                "ws_port": websocket_listener.getsockname()[1],
            }
        ),
        encoding="utf-8",
    )
    ready_temp.replace(args.ready_file)

    while not stop.wait(0.2):
        pass

    http_server.shutdown()
    http_server.server_close()
    websocket_listener.close()
    http_thread.join(timeout=5)
    websocket_thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
