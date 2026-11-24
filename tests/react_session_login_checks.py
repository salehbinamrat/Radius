#!/usr/bin/env python3
"""Stage03C: safe opt-in React admin login without changing the Basic lab."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
API = ROOT / "src/RadiusManager.Api"
WEB = API / "wwwroot"
UI = API / "frontend"

class SessionLoginContracts(unittest.TestCase):
    def test_public_mode_discovery_refuses_insecure_session_mode(self):
        src = (API / "AdminIdentityEndpoints.cs").read_text()
        self.assertIn('"/api/admin/auth/mode"', src)
        self.assertIn("identityEnabled && !ctx.Request.IsHttps", src)
        self.assertIn('mode = identityEnabled ? "session" : "basic"', src)
        smoke = (ROOT / "scripts/admin-https-smoke.sh").read_text()
        self.assertIn('api/admin/auth/mode', smoke)

    def test_react_login_is_https_only_and_uses_csrf_and_cookie(self):
        src = (UI / "src/SessionLogin.tsx").read_text()
        for value in ('/api/admin/auth/mode','/api/admin/auth/csrf',
                      '/api/admin/auth/login','/api/admin/auth/me',
                      'X-CSRF-TOKEN','credentials:','radius-session-ready',
                      'radius-session-logged-out'):
            self.assertIn(value,src)
        self.assertIn("https:",src)
        self.assertIn("SessionLogin", (UI / "src/main.tsx").read_text())
        for forbidden in ("localStorage","sessionStorage","indexedDB","Basic "):
            self.assertNotIn(forbidden,src)
        self.assertIn('id="reactAdminLogin"',(WEB / "index.html").read_text())
        self.assertIn('id="loginForm"',(WEB / "index.html").read_text())

    def test_legacy_ui_bridges_cookie_mode_without_creating_client_authority(self):
        src = (WEB / "app.mjs").read_text()
        for token in ('radius-session-ready','radius-session-logged-out',
                      'sessionMode', 'sessionCsrf', 'X-CSRF-TOKEN',
                      'credentials:','/api/admin/auth/logout'):
            self.assertIn(token,src)
        self.assertIn("Authorization:",src)
        self.assertNotIn("localStorage",src)
        self.assertNotIn("sessionStorage",src)

    def test_ui_and_react_bundle_are_covered_by_existing_ci(self):
        smoke = (ROOT / "scripts/ui-smoke.sh").read_text()
        self.assertIn("reactAdminLogin",smoke)
        self.assertIn("SessionLogin", (UI / "src/main.tsx").read_text())
        self.assertIn("noc-react.mjs",smoke)

if __name__ == "__main__":
    unittest.main(verbosity=2)
