#!/usr/bin/env bash
# Protocol acceptance on container loopback only, never a production NAS.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true && "${LAB_RADIUS_AUTHENTICATOR_ACK:-}" == isolated-ci ]] || {
  echo 'Requires isolated CI acknowledgement' >&2; exit 1;
}
docker compose exec -T radius dpkg-query -W freeradius freeradius-postgresql freeradius-utils
docker compose exec -T radius python3 - <<'PY'
import hashlib
import hmac
import secrets
import socket
import struct
import sys
sys.path.insert(0, '/opt/radius')
from radius_secret_input import load_hex

secret = load_hex("RADIUS_SECRET").encode("ascii")
username = ("lab_" + secrets.token_hex(6)).encode("ascii")
password = secrets.token_hex(8).encode("ascii")

def attr(kind, value):
    return bytes((kind, len(value) + 2)) + value

def request(sock, signed):
    ident = secrets.randbelow(256)
    auth = secrets.token_bytes(16)
    encrypted = bytes(a ^ b for a, b in zip(password, hashlib.md5(secret + auth).digest()))
    attrs = attr(1, username) + attr(2, encrypted) + attr(4, socket.inet_aton("127.0.0.1"))
    if signed:
        attrs += attr(80, bytes(16))
    packet = struct.pack("!BBH", 1, ident, 20 + len(attrs)) + auth + attrs
    if signed:
        packet = packet[:-16] + hmac.digest(secret, packet, "md5")
    sock.send(packet)
    try:
        reply = sock.recv(4096)
    except socket.timeout:
        if signed:
            raise RuntimeError("Signed synthetic request received no response")
        return
    if not signed:
        raise RuntimeError("Unsigned Access-Request was not dropped")
    if len(reply) < 20:
        raise RuntimeError("Malformed signed-request response")
    code, response_id, length = struct.unpack("!BBH", reply[:4])
    expected = hashlib.md5(reply[:4] + auth + reply[20:] + secret).digest()
    if code != 3 or response_id != ident or length != len(reply) or not hmac.compare_digest(reply[4:20], expected):
        raise RuntimeError("Expected authenticated Access-Reject for unknown synthetic account")

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.settimeout(3)
    sock.connect(("127.0.0.1", 1812))
    request(sock, False)
    request(sock, True)
print("Strict lab Message-Authenticator policy: unsigned request dropped, signed unknown account rejected PASS")
PY
