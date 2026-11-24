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
                     "/api/summary",
                     "401", "403", "200",
                     "docker compose -p"):
            self.assertIn(item, source)
        # Bootstrap moved to a two-PTY helper. Verify the actual invocation,
        # not a comment or an obsolete string in the parent shell.
        race = (ROOT / "tests/concurrent_admin_bootstrap_smoke.py").read_text(encoding="utf-8")
        self.assertIn('python3 tests/concurrent_admin_bootstrap_smoke.py "$project" "$compose_file"', source)
        self.assertIn('"RadiusManager.Api.dll", "--bootstrap-admin"', race)
        self.assertIn('subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave', race)
        self.assertIn('sorted(codes) != [0, 2]', race)
        self.assertIn('all(w["ready"] for w in workers)', race)
        self.assertLess(source.index("python3 tests/concurrent_admin_bootstrap_smoke.py"),
                        source.index('build_body login'))
        self.assertNotIn("curl -k", source)
        self.assertNotIn("curl --insecure", source)
        self.assertIn("docker compose -p", source)

    def test_https_logout_is_exercised_by_the_wire_and_browser_fixtures(self):
        source = (ROOT / "scripts/admin-https-smoke.sh").read_text(encoding="utf-8")
        wire = (ROOT / "tests/signalr_https_wire_smoke.py").read_text(encoding="utf-8")
        browser = (ROOT / "tests/browser/https-live-status-smoke.mjs").read_text(encoding="utf-8")
        # Logout moved from curl to the actual streaming fixture. Require the
        # invocation, real POST, CSRF, live-session revocation and stale-cookie denial.
        self.assertIn('python3 tests/signalr_https_wire_smoke.py "$tmp/tls/server.crt" "$jar"', source)
        self.assertIn('node tests/browser/https-live-status-smoke.mjs', source)
        self.assertIn('self.request("POST", "/api/admin/auth/logout"', wire)
        self.assertIn('"X-CSRF-TOKEN": token', wire)
        self.assertIn('fixture.logout()', wire)
        self.assertIn('Data delivered after logout', wire)
        self.assertIn('check 401 -b "$tmp/stale-after-logout.cookies" "$url/api/summary"', source)
        self.assertIn("page.locator('#logout').click()", browser)
        self.assertIn("assert.equal(denied.status(), 401", browser)
        self.assertLess(source.index('python3 tests/signalr_https_wire_smoke.py'),
                        source.index('node tests/browser/https-live-status-smoke.mjs'))

    def test_independent_https_phases_restart_only_the_fixture_api(self):
        source = (ROOT / "scripts/admin-https-smoke.sh").read_text(encoding="utf-8")
        phase = source[source.index("restart_fixture_api() {"):]
        self.assertIn('docker compose -p "$project" -f "$compose_file" restart api', phase)
        self.assertIn('check 401 -b "$tmp/stale-after-logout.cookies" "$url/api/summary"', phase)
        self.assertIn('restart_fixture_api\n# Two distinct disposable identities', phase)
        self.assertIn('restart_fixture_api\n# A separate browser session', phase)
        self.assertNotIn('down -v', phase)

    def test_ci_runs_https_only_after_existing_tests(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("bash scripts/admin-https-smoke.sh", ci)
        self.assertLess(ci.index("bash scripts/lab-recovery-smoke.sh"),
                        ci.index("bash scripts/admin-https-smoke.sh"))
        self.assertIn("LAB_HTTPS_TEST_ACK: isolated-ci", ci)

if __name__ == "__main__":
    unittest.main(verbosity=2)
