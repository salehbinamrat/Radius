#!/usr/bin/env python3
"""Stage 03M: actual browser tests are mandatory after Compose starts."""
import json
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
CI=(ROOT/'.github/workflows/ci.yml').read_text(encoding='utf-8')
BROWSER=ROOT/'tests/browser'

class BrowserCiContract(unittest.TestCase):
    def test_pinned_stable_browser_runner_and_isolated_test_directory(self):
        pkg=json.loads((BROWSER/'package.json').read_text(encoding='utf-8'))
        self.assertEqual(pkg['devDependencies']['@playwright/test'],'1.65.1')
        self.assertTrue(pkg['private'])
        self.assertIn("chromium", (BROWSER/'playwright.config.mjs').read_text())
    def test_real_chromium_checks_without_any_login_shortcut_to_server(self):
        source=(BROWSER/'dashboard.spec.mjs').read_text(encoding='utf-8')
        for key in ("#capUsers","#capVolumeOut","#labCredentials","/api/plans","toBe(401)",
                    "setViewportSize", "pageerror"):
            self.assertIn(key,source)
        self.assertNotIn('localStorage',source)
        self.assertNotIn('Authorization:',source)
        self.assertNotIn('password:',source)
    def test_browser_gate_runs_inside_docker_integration_after_api_health(self):
        self.assertIn('Browser smoke: Chromium + React',CI)
        self.assertIn('tests/browser/node_modules/.bin/playwright test',CI)
        self.assertIn('needs: [dotnet-tests, config-tests]',CI)
        self.assertIn('scripts/admin-https-smoke.sh',CI)
        self.assertIn('scripts/lab-recovery-smoke.sh',CI)
        self.assertIn('actions/setup-node@v4',CI)
    def test_react_library_output_never_requires_node_process_in_chromium(self):
        vite=(ROOT/'src/RadiusManager.Api/frontend/vite.config.ts').read_text(encoding='utf-8')
        self.assertIn("'process.env.NODE_ENV': JSON.stringify('production')",vite)
        self.assertIn('Vite library bundle retained Node process.env',CI)
if __name__=='__main__':
    unittest.main(verbosity=2)
