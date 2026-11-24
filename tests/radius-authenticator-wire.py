import hashlib
import hmac
import secrets
import socket
import struct
import sys
def attr(kind, value):
    if len(value) > 253:
        raise ValueError("RADIUS attribute too long")
    return bytes((kind, len(value) + 2)) + value


def build_request(secret, username, password, ident, auth, mode, eap=False):
    if mode not in ("unsigned", "valid", "invalid"):
        raise ValueError("Unknown authenticator test mode")
    if len(password) != 16 or len(auth) != 16:
        raise ValueError("Synthetic PAP test uses exactly one 16-byte block")
    encrypted = bytes(a ^ b for a, b in zip(password, hashlib.md5(secret + auth).digest()))
    attrs = attr(1, username) + attr(2, encrypted) + attr(4, socket.inet_aton("127.0.0.1"))
    if eap:
        if mode != "valid":
            raise ValueError("EAP test requires a valid authenticator")
        # Ordinary synthetic EAP Identity Response.
        identity = username
        eap_message = struct.pack("!BBHB", 2, ident, 5 + len(identity), 1) + identity
        attrs = attr(1, username) + attr(79, eap_message) + attr(4, socket.inet_aton("127.0.0.1"))
    if mode != "unsigned":
        attrs += attr(80, bytes(16))
    packet = struct.pack("!BBH", 1, ident, 20 + len(attrs)) + auth + attrs
    if mode != "unsigned":
        mac = hmac.digest(secret, packet, "md5")
        if mode == "invalid":
            # Change exactly one bit of an otherwise valid Message-Authenticator.
            mac = bytes((mac[0] ^ 1,)) + mac[1:]
        packet = packet[:-16] + mac
    return packet


def verify_reject(reply, ident, auth, secret):
    if len(reply) < 20:
        raise RuntimeError("Malformed signed-request response")
    code, response_id, length = struct.unpack("!BBH", reply[:4])
    expected = hashlib.md5(reply[:4] + auth + reply[20:] + secret).digest()
    if code != 3 or response_id != ident or length != len(reply) or not hmac.compare_digest(reply[4:20], expected):
        raise RuntimeError("Expected authenticated Access-Reject for unknown synthetic account")


def request(secret, username, password, mode, eap=False):
    ident = secrets.randbelow(256)
    auth = secrets.token_bytes(16)
    packet = build_request(secret, username, password, ident, auth, mode, eap)
    # Fresh socket per exchange: delayed responses cannot satisfy the next test.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(3)
        sock.connect(("127.0.0.1", 1812))
        sock.send(packet)
        try:
            reply = sock.recv(4096)
        except socket.timeout:
            if mode == "valid":
                raise RuntimeError("Signed synthetic request received no response")
            return
    if mode != "valid":
        raise RuntimeError(mode + " Access-Request was not dropped")
    verify_reject(reply, ident, auth, secret)


def main():
    sys.path.insert(0, "/opt/radius")
    from radius_secret_input import load_hex
    secret = load_hex("RADIUS_SECRET").encode("ascii")
    username = ("lab_" + secrets.token_hex(6)).encode("ascii")
    password = secrets.token_hex(8).encode("ascii")
    request(secret, username, password, "unsigned")
    request(secret, username, password, "valid")
    request(secret, username, password, "invalid")
    request(secret, username, password, "valid")
    request(secret, username, password, "valid", eap=True)
    print("Unused EAP path: signed EAP request rejected PASS")
    print("Strict lab Message-Authenticator policy: unsigned request dropped, signed unknown account rejected PASS")
    print("Invalid Message-Authenticator dropped; subsequent signed request verified PASS")


if __name__ == "__main__":
    main()
