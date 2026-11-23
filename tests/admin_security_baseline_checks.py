#!/usr/bin/env python3
"""Stage 03 baseline: do not weaken existing local-lab admin boundaries.

These tests cover current safety invariants, NOT production authentication.
Role/cookie/session tests belong to the owner-approved implementation stage.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
API = ROOT / "src/RadiusManager.Api"
WEB = API / "wwwroot"

class AdminSecurityBaselineChecks(unittest.TestCase):
    def test_lab_admin_api_is_still_loopback_only_by_default(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertIn('"127.0.0.1:8080:8080/tcp"', compose)
        self.assertNotIn('"0.0.0.0:8080', compose)

    def test_sensitive_routes_have_server_side_auth_and_origin_checks(self):
        server = (API / "Program.cs").read_text(encoding="utf-8")
        self.assertIn('AdminBasicAuth.Matches(', server)
        self.assertIn('RequestOriginRules.IsAllowed(', server)
        self.assertIn('context.Response.Headers["Content-Security-Policy"]', server)
        self.assertIn('ctx.Response.StatusCode = StatusCodes.Status403Forbidden', server)
        self.assertIn('ctx.Response.StatusCode = StatusCodes.Status401Unauthorized', server)
        self.assertIn('app.UseRateLimiter()', server)
        # Server-side enforcement, not merely hiding buttons.
        self.assertIn('ctx.Request.Path.StartsWithSegments("/api")', server)

    def test_browser_passwords_not_persisted_in_local_storage(self):
        js = (WEB / "app.mjs").read_text(encoding="utf-8")
        for forbidden in ("localStorage", "sessionStorage", "indexedDB"):
            self.assertNotIn(forbidden, js)
        self.assertIn("auth = '';", js)  # legacy credential lifetime is in-memory only
        self.assertIn("el('loginPass').value = ''", js)
        self.assertIn("function logout(", js)
        self.assertIn("el('dashboard').hidden = true", js)

    def test_no_existing_roles_or_session_revocation_claimed_as_implemented(self):
        design = (ROOT / "STAGE3_ADMIN_SECURITY_DESIGN_AR.md").read_text(encoding="utf-8")
        self.assertIn("غير منفذ", design)
        for name in ("ASP.NET Core Identity", "app_admin_sessions", "app_admin_audit_events",
                     "HTTPS", "CSRF", "super-admin", "NOC operator",
                     "voucher operator", "reseller", "auditor",
                     "موافقة", "005"):
            self.assertIn(name, design)

if __name__ == "__main__":
    unittest.main(verbosity=2)
