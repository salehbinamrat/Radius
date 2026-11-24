#!/usr/bin/env python3
"""Real SignalR JSON streaming over certificate-verified loopback WebSockets.

Uses only the standard library and the disposable HTTPS acceptance fixture.
Never prints cookie values, connection tokens, or response payloads.
"""
import base64
import hashlib
import http.client
from http.cookies import SimpleCookie
import json
import os
import socket
import ssl
import struct
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

ORIGIN = "https://localhost:18443"
HOST = "localhost"
PORT = 18443
HUB = "/hubs/lab-status"
RS = b"\x1e"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class Closed(Exception):
    pass


class Fixture:
    def __init__(self, cert, jar):
        self.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self.tls.load_verify_locations(cafile=cert)
        self.cookies = {}
        # curl's Netscape jar marks HttpOnly cookies with a prefix.
        for line in Path(jar).read_text().splitlines():
            if line.startswith("#HttpOnly_"):
                line = line.removeprefix("#HttpOnly_")
            elif line.startswith("#") or not line:
                continue
            fields = line.split("\t")
            if len(fields) == 7:
                domain, _, path, secure, _, name, value = fields
                if (domain == HOST and path == "/" and secure == "TRUE"
                        and name in ("__Host-RadiusAdmin", "__Host-RadiusCsrf")):
                    self.cookies[name] = value
        require("__Host-RadiusAdmin" in self.cookies, "Fixture admin cookie missing")

    def cookie_header(self):
        return "; ".join(f"{name}={value}" for name, value in self.cookies.items())

    def request(self, method, path, body=None, extra=None):
        conn = http.client.HTTPSConnection(HOST, PORT, context=self.tls, timeout=10)
        try:
            headers = {"Origin": ORIGIN, "Sec-Fetch-Site": "same-origin",
                       "Cookie": self.cookie_header()}
            headers.update(extra or {})
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
            require(response.status == 200, f"Unexpected HTTPS status for {path}: {response.status}")
            for name, value in response.getheaders():
                if name.lower() == "set-cookie":
                    parsed = SimpleCookie()
                    parsed.load(value)
                    for key, morsel in parsed.items():
                        if key in ("__Host-RadiusAdmin", "__Host-RadiusCsrf"):
                            if morsel.value:
                                self.cookies[key] = morsel.value
                            else:
                                self.cookies.pop(key, None)
            return json.loads(response.read())
        finally:
            conn.close()

    def connect(self):
        negotiation = self.request("POST", HUB + "/negotiate?negotiateVersion=1", b"")
        require([item["transport"] for item in negotiation["availableTransports"]]
                == ["WebSockets"], "Unexpected transport")
        return Wire(self.tls, self.cookie_header(), negotiation["connectionToken"])

    def logout(self):
        token = self.request("GET", "/api/admin/auth/csrf")["requestToken"]
        result = self.request("POST", "/api/admin/auth/logout", b"{}",
                              {"Content-Type": "application/json", "X-CSRF-TOKEN": token})
        require(result.get("authenticated") is False, "Logout did not revoke session")


class Wire:
    def __init__(self, tls, cookie, token):
        raw = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        try:
            self.sock = tls.wrap_socket(raw, server_hostname=HOST)
        except Exception:
            raw.close()
            raise
        self.reader = self.sock.makefile("rb")
        self.pending = b""
        self.messages = []
        self.fragment = bytearray()
        self.fragment_open = False
        try:
            key = base64.b64encode(os.urandom(16)).decode()
            path = HUB + "?" + urlencode({"id": token})
            request = (
                f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
                f"Origin: {ORIGIN}\r\nSec-Fetch-Site: same-origin\r\n"
                f"Cookie: {cookie}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            )
            self.sock.sendall(request.encode("ascii"))
            status = self.reader.readline(4096)
            require(status.startswith(b"HTTP/1.1 101 "), "WebSocket upgrade rejected")
            headers = {}
            for _ in range(64):
                line = self.reader.readline(4096)
                if line == b"\r\n":
                    break
                name, _, value = line.partition(b":")
                headers[name.lower()] = value.strip()
            else:
                raise AssertionError("Invalid upgrade headers")
            expected = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
            require(headers.get(b"sec-websocket-accept") == expected, "Invalid WebSocket accept")
            self.send({"protocol": "json", "version": 1})
            require(self.receive(10) == {}, "SignalR handshake failed")
        except Exception:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self.reader.close()
        self.sock.close()

    def exact(self, count):
        data = self.reader.read(count)
        if len(data) != count:
            raise Closed()
        return data

    def frame(self, opcode, payload):
        require(len(payload) <= 125, "Fixture client frame too large")
        mask = os.urandom(4)
        masked = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
        self.sock.sendall(bytes((0x80 | opcode, 0x80 | len(payload))) + mask + masked)

    def send(self, message):
        self.frame(1, json.dumps(message, separators=(",", ":")).encode() + RS)

    def receive(self, timeout):
        deadline = time.monotonic() + timeout
        while not self.messages:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "Timed out awaiting SignalR record")
            self.sock.settimeout(remaining)
            first, second = self.exact(2)
            opcode = first & 15
            fin = bool(first & 128)
            require(not second & 128 and not first & 112, "Invalid server frame")
            length = second & 127
            if length == 126:
                length = struct.unpack("!H", self.exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.exact(8))[0]
            require(length <= 65536, "Oversized fixture frame")
            data = self.exact(length)
            if opcode == 8:
                raise Closed()
            if opcode == 9:
                self.frame(10, data)
                continue
            if opcode == 10:
                continue
            require(opcode in (0, 1), "Unexpected server frame opcode")
            if opcode == 1:
                require(not self.fragment_open, "Unexpected new text frame")
                self.fragment_open = not fin
                self.fragment = bytearray(data)
            else:
                require(self.fragment_open, "Unexpected continuation")
                self.fragment.extend(data)
                self.fragment_open = not fin
            require(len(self.fragment) <= 65536, "Oversized fixture message")
            if not fin:
                continue
            self.pending += bytes(self.fragment)
            records = self.pending.split(RS)
            self.pending = records.pop()
            self.messages.extend(json.loads(record) for record in records if record)
            require(len(self.pending) <= 65536, "Unterminated SignalR record")
        return self.messages.pop(0)

    def watch(self, invocation):
        self.send({"type": 4, "invocationId": invocation, "target": "Watch", "arguments": []})

    def sample(self, invocation, cancelled=None):
        deadline = time.monotonic() + 15
        while True:
            message = self.receive(max(0, deadline - time.monotonic()))
            kind = message.get("type")
            if kind == 6:
                continue
            if kind == 3 and message.get("invocationId") == cancelled:
                continue
            require(kind == 2 and message.get("invocationId") == invocation,
                    "Missing current sample or unexpected old stream")
            item = message["item"]
            require(set(item) == {"scope", "api", "database", "sessionCheckMs", "observedAtUtc"}, "Unexpected status fields")
            require(item["scope"] == "lab" and item["api"] == "running"
                    and item["database"] == "reachable", "Unexpected laboratory status")
            elapsed = item["sessionCheckMs"]
            require(type(elapsed) in (int, float) and 0 <= elapsed <= 10000,
                    "Invalid measured session check duration")
            when = datetime.fromisoformat(item["observedAtUtc"].replace("Z", "+00:00"))
            require(abs((datetime.now(timezone.utc) - when).total_seconds()) < 30,
                    "Snapshot is not fresh")
            return when


def main():
    require(os.environ.get("CI") == "true" and os.environ.get("LAB_HTTPS_TEST_ACK") == "isolated-ci",
            "Disposable HTTPS CI acknowledgement required")
    require(len(sys.argv) == 3, "Expected fixture certificate and cookie jar")
    fixture = Fixture(*sys.argv[1:])
    with fixture.connect() as wire:
        wire.watch("first")
        first = wire.sample("first")
        wire.send({"type": 5, "invocationId": "first"})
        # Allow the server's ten-second throttle to elapse, then prove the
        # cancelled stream does not deliver old items or block resubscription.
        time.sleep(10.6)
        wire.watch("second")
        second = wire.sample("second", cancelled="first")
        require(second > first, "Re-subscription replayed an old snapshot")
    # Reconnect with a fresh transport and no replay state.
    with fixture.connect() as wire:
        wire.watch("third")
        third = wire.sample("third")
        require(third >= second, "Reconnect replayed old status")
        fixture.logout()
        # An authenticated stream already open must stop, not just reject a
        # subsequent HTTP request. No fresh sample may follow revocation.
        deadline = time.monotonic() + 16
        try:
            while True:
                message = wire.receive(max(0, deadline - time.monotonic()))
                if message.get("type") == 7:
                    break
                # Abort can race with the stream's terminal completion frame.
                if message.get("type") == 3 and message.get("invocationId") == "third":
                    continue
                require(message.get("type") == 6, "Data delivered after logout")
        except (Closed, ConnectionResetError):
            pass
    print("SignalR TLS WebSocket handshake, sample schema, cancellation, reconnect and live logout revocation PASS")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        # All assertion messages above are fixed and contain no secrets.
        print(f"SignalR acceptance failed: {error}", file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print(f"SignalR acceptance failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
