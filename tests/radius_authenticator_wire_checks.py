"""Offline regression tests for the isolated RADIUS authenticator acceptance probe."""
import hashlib
import hmac
import importlib.util
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("wire", ROOT / "tests/radius-authenticator-wire.py")
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


class RadiusAuthenticatorWireChecks(unittest.TestCase):
    def setUp(self):
        self.secret = b"synthetic-test-secret"
        self.auth = bytes(range(16))
        self.ident = 42

    def packet(self, mode, eap=False):
        return wire.build_request(self.secret, b"lab_unknown", b"0123456789abcdef",
                                  self.ident, self.auth, mode, eap)

    def test_valid_and_invalid_mac_differ_by_exactly_one_bit(self):
        valid, invalid = self.packet("valid"), self.packet("invalid")
        self.assertEqual(valid[:-16], invalid[:-16])
        self.assertEqual(valid[-16] ^ invalid[-16], 1)
        self.assertEqual(valid[-15:], invalid[-15:])
        self.assertEqual(valid[-18:-16], bytes((80, 18)))
        self.assertEqual(valid[-16:], hmac.digest(self.secret, valid[:-16] + bytes(16), "md5"))

    def test_unsigned_has_no_mac_and_consistent_length(self):
        packet = self.packet("unsigned")
        self.assertEqual(len(self.packet("valid")), len(packet) + 18)
        self.assertEqual(struct.unpack("!BBH", packet[:4]), (1, self.ident, len(packet)))
        self.assertEqual(packet[4:20], self.auth)

    def test_signed_eap_and_invalid_input(self):
        packet = self.packet("valid", eap=True)
        self.assertEqual(packet[-16:], hmac.digest(self.secret, packet[:-16] + bytes(16), "md5"))
        for mode in ("invalid", "unsigned", "unknown"):
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.packet(mode, eap=True)

    def test_response_verification_rejects_malformed_or_tampered_packets(self):
        header = struct.pack("!BBH", 3, self.ident, 20)
        reply = header + hashlib.md5(header + self.auth + self.secret).digest()
        wire.verify_reject(reply, self.ident, self.auth, self.secret)
        for bad in (reply[:19], reply + b"x", bytes((2,)) + reply[1:],
                    reply[:1] + b"\x00" + reply[2:], reply[:-1] + bytes((reply[-1] ^ 1,))):
            with self.subTest(packet=bad), self.assertRaises(RuntimeError):
                wire.verify_reject(bad, self.ident, self.auth, self.secret)

    def test_smoke_executes_helper_only_inside_lab_container(self):
        script = (ROOT / "scripts/radius-authenticator-smoke.sh").read_text()
        self.assertIn("LAB_RADIUS_AUTHENTICATOR_ACK", script)
        self.assertIn("docker compose exec -T radius python3 - < tests/radius-authenticator-wire.py", script)
        self.assertIn('sock.connect(("127.0.0.1", 1812))',
                      (ROOT / "tests/radius-authenticator-wire.py").read_text())
