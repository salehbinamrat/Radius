#!/usr/bin/env python3
"""Stage 03B: secure, isolated HTTPS session acceptance contracts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
API = ROOT / "src/RadiusManager.Api"

class HttpsSessionContracts(unittest.TestCase):
    def test_data_protection_keys_are_persisted_and_encrypted_under_tls(self):
        server = (API / "Program.cs").read_text(encoding="utf-8")
        for value in ("AddDataProtection()", "PersistKeysToFileSystem",
                      "ProtectKeysWithCertificate", "X509CertificateLoader",
                      "RADIUS_ADMIN_DATA_PROTECTION_PATH",
                      "ASPNETCORE_Kestrel__Certificates__Default__Path"):
            self.assertIn(value, server)
        docker = (API / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("mkdir -p /var/lib/radius-admin-keys", docker)
        self.assertIn("chmod 700", docker)

    def test_https_compose_is_isolated_and_no_external_listener(self):
        source = (ROOT / "tests/admin-https.compose.yaml").read_text(encoding="utf-8")
        for item in ("https://+:8443", "RADIUS_ADMIN_AUTH_MODE: session",
                     "127.0.0.1:18443:8443", "admin_dp_keys:",
                     "https_pg_data:", "schema-init:", "db:", "api:"):
            self.assertIn(item, source)
        self.assertNotIn("0.0.0.0:18443", source)
        self.assertNotIn("postgres_data:", source)
        self.assertNotIn("private-radius-lab", source)
        self.assertNotIn("radius:", source)

    def test_https_smoke_uses_real_tls_verification_and_ephemeral_credentials(self):
        source = (ROOT / "scripts/admin-https-smoke.sh").read_text(encoding="utf-8")
        for item in ("openssl", "pkcs12", "LAB_HTTPS_TEST_ACK",
                     "docker compose -p", "trap cleanup EXIT",
                     "down -v --remove-orphans", "--cacert",
                     "/api/admin/auth/csrf", "/api/admin/auth/login",
                     "/api/admin/auth/logout", "/api/summary",
                     "bootstrap-admin", "401", "403", "200",
                     "docker compose -p"):
            self.assertIn(item, source)
        self.assertNotIn("curl -k", source)
        self.assertNotIn("curl --insecure", source)
        self.assertIn("docker compose -p", source)

    def test_ci_runs_https_only_after_existing_tests(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("bash scripts/admin-https-smoke.sh", ci)
        self.assertLess(ci.index("bash scripts/lab-recovery-smoke.sh"),
                        ci.index("bash scripts/admin-https-smoke.sh"))
        self.assertIn("LAB_HTTPS_TEST_ACK: isolated-ci", ci)

if __name__ == "__main__":
    unittest.main(verbosity=2)
