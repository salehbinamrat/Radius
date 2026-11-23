#!/usr/bin/env python3
"""Security and integration contracts for the draft-only NAS registry."""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]
class TestNasDraft(unittest.TestCase):
    def test_no_production_router_activation(self):
        db=(R/'database/004_nas_drafts.sql').read_text()
        code=(R/'src/RadiusManager.Api/NasDraftEndpoints.cs').read_text()
        self.assertIn('CREATE TABLE IF NOT EXISTS app_nas_drafts',db)
        self.assertIn('vpn_ip inet NOT NULL UNIQUE',db)
        self.assertNotIn('INSERT INTO nas ',code+db)
        self.assertNotIn('UPDATE nas ',code+db)
        self.assertNotIn('shared_secret',code+db)
        self.assertIn('radiusClientEnabled = false',code)
        self.assertIn('RequireRateLimiting("admin")',code)
    def test_wiring_and_security(self):
        self.assertIn('004_nas_drafts.sql',(R/'compose.yaml').read_text())
        self.assertIn('004_nas_drafts.sql',(R/'radius/schema-init.sh').read_text())
        self.assertIn('app.MapNasDraftEndpoints();',(R/'src/RadiusManager.Api/Program.cs').read_text())
        html=(R/'src/RadiusManager.Api/wwwroot/index.html').read_text()
        for x in ['nasDraftForm','nasDraftName','nasDraftIp','nasDraftSite','nasDraftList','nasDraftError','nasDraftRefresh']:
            self.assertIn(f'id="{x}"',html)
        js=(R/'src/RadiusManager.Api/wwwroot/nas-drafts.mjs').read_text()
        self.assertNotIn('innerHTML',js)
        self.assertNotIn('localStorage',js)
        self.assertNotIn('sessionStorage',js)
        self.assertNotIn('secret',js.lower())
        self.assertIn('لا تستخدم كروت فعلية',html)
    def test_ci(self):
        ci=(R/'.github/workflows/ci.yml').read_text()
        self.assertIn('bash scripts/ci-config-checks.sh',ci)
        self.assertIn('scripts/nas-drafts-smoke.sh',ci)
        runner=(R/'scripts/ci-config-checks.sh').read_text()
        self.assertIn("python3 -m unittest discover -s tests -p '*checks.py'",runner)
        self.assertIn('node --check',runner)
        self.assertTrue((R/'src/RadiusManager.Api/wwwroot/nas-drafts.mjs').is_file())
if __name__=='__main__':unittest.main(verbosity=2)
