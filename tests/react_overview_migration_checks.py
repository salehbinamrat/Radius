#!/usr/bin/env python3
"""Stage 03D: React owns real NOC statistics without claiming live-router metrics."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/"src/RadiusManager.Api/wwwroot"
FRONT=ROOT/"src/RadiusManager.Api/frontend/src"

class OverviewMigrationChecks(unittest.TestCase):
    def test_react_overview_mounts_and_retains_the_original_noc_layout(self):
        html=(WEB/"index.html").read_text(encoding="utf-8")
        main=(FRONT/"main.tsx").read_text(encoding="utf-8")
        self.assertIn('id="view-overview"', html)
        self.assertIn('id="reactOverviewKpis"', html)
        self.assertIn('id="reactOverviewRecent"', html)
        self.assertIn('id="reactOverviewPackages"', html)
        self.assertIn('id="reactOverviewServices"', html)
        self.assertIn('id="view-plans"', html)
        self.assertIn("OverviewKpis", main)
        self.assertIn("OverviewRecent", main)
        self.assertNotIn('id="statPlans"', html)
        self.assertNotIn('id="recentAccounts"', html)

    def test_statistic_flow_is_from_authenticated_existing_api_not_a_mock(self):
        js=(WEB/"app.mjs").read_text(encoding="utf-8")
        model=(WEB/"overview-model.mjs").read_text(encoding="utf-8")
        jsx=(FRONT/"Overview.tsx").read_text(encoding="utf-8")
        for token in ("buildOverviewSnapshot", "radius-overview-updated",
                      "radius-overview-request", "accounts", "summary"):
            self.assertIn(token, js+model+jsx)
        self.assertIn("call('/api/summary')", js)
        self.assertIn("call('/api/lab-accounts')", js)
        self.assertIn("first-100-loaded", model)
        self.assertIn("addEventListener", jsx)
        self.assertIn("removeEventListener", jsx)
        self.assertNotIn("fetch(", jsx)
        self.assertNotIn("Authorization", jsx)
        self.assertNotIn("dangerouslySetInnerHTML", jsx)
        self.assertNotIn("localStorage", jsx)

    def test_show_first_100_data_scope_and_api_errors_without_false_online_claims(self):
        jsx=(FRONT/"Overview.tsx").read_text(encoding="utf-8")
        self.assertIn("أول 100", jsx)
        self.assertIn("البيانات السابقة", jsx)
        self.assertIn("غير مفحوص", (WEB/"index.html").read_text(encoding="utf-8") + jsx)
        self.assertIn("onOverviewError", (WEB/"app.mjs").read_text(encoding="utf-8"))

    def test_ci_covers_react_bundle_and_node_model_tests(self):
        checks=(ROOT/"scripts/ci-config-checks.sh").read_text(encoding="utf-8")
        smoke=(ROOT/"scripts/ui-smoke.sh").read_text(encoding="utf-8")
        self.assertIn("node --test tests/js/*.test.mjs",checks)
        self.assertIn("reactOverviewKpis", smoke)
        self.assertIn("reactOverviewRecent", smoke)

if __name__=="__main__":
    unittest.main(verbosity=2)
