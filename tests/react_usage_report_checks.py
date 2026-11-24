#!/usr/bin/env python3
"""Stage03J: move usage REPORT only, protect logout and out-of-order API results."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/'src/RadiusManager.Api/wwwroot'
UI=ROOT/'src/RadiusManager.Api/frontend/src'

class ReactUsageReportChecks(unittest.TestCase):
    def test_existing_selection_and_actions_remain_in_original_noc_shell(self):
        html=(WEB/'index.html').read_text(encoding='utf-8')
        main=(UI/'main.tsx').read_text(encoding='utf-8')
        for ident in ('reactUsageReport','usageAccount','loadUsage','view-accounting','view-sessions'):
            self.assertIn(f'id="{ident}"',html)
        self.assertNotIn('id="usageEmpty"',html)
        self.assertNotIn('id="usageReport"',html)
        self.assertIn('UsageReport',main)
        self.assertIn('radacct',html)

    def test_react_receives_allowlisted_data_and_never_fetches_directly(self):
        js=(WEB/'app.mjs').read_text(encoding='utf-8')
        model=(WEB/'usage-view-model.mjs').read_text(encoding='utf-8')
        react=(UI/'UsageReport.tsx').read_text(encoding='utf-8')
        for name in ("radius-usage-updated","radius-usage-request","buildUsageViewSnapshot"):
            self.assertIn(name,js+react+model)
        for token in ("usageGeneration", "++usageGeneration", "if (!isCurrentUsage", "resetUsage()", "loading(el('loadUsage')"):
            self.assertIn(token,js)
        self.assertIn('/api/lab-accounts/',js)
        self.assertIn("credentials: 'same-origin'",js)
        for blocked in ('fetch(', 'Authorization', 'localStorage', 'sessionStorage',
                        'dangerouslySetInnerHTML', 'password', 'sharedSecret'):
            self.assertNotIn(blocked,react)
        for removed in ("el('usageTotal')", "el('usageReport')", "el('usageEmpty')",
                        "el('usageSessions')", "el('usageWarning')"):
            self.assertNotIn(removed,js)
        self.assertIn("formatBytes",model)
        self.assertIn("reportIsFinal === true",model)

    def test_regression_checks_and_deployed_bundle(self):
        smoke=(ROOT/'scripts/ui-smoke.sh').read_text(encoding='utf-8')
        self.assertIn('reactUsageReport',smoke)
        self.assertIn('usage-view-model.mjs',smoke)
        self.assertIn('radius-usage-updated',smoke)
        ci=(ROOT/'scripts/ci-config-checks.sh').read_text(encoding='utf-8')
        self.assertIn('node --test tests/js/*.test.mjs',ci)

if __name__ == '__main__':
    unittest.main(verbosity=2)
