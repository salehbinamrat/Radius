#!/usr/bin/env python3
"""Stage 03E: NOC service and package insight components migrate to React with no fake telemetry."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/"src/RadiusManager.Api/wwwroot"
FRONT=ROOT/"src/RadiusManager.Api/frontend/src"

class ReactOverviewInsightsContracts(unittest.TestCase):
    def test_mounts_retain_original_layout_and_preserve_unmigrated_features(self):
        html=(WEB/"index.html").read_text(encoding="utf-8")
        main=(FRONT/"main.tsx").read_text(encoding="utf-8")
        for marker in ('id="reactOverviewPackages"', 'id="reactOverviewServices"',
                       'id="view-overview"', 'id="view-plans"',
                       'id="nocMixTitle"', 'id="nocServicesTitle"'):
            self.assertIn(marker,html)
        self.assertIn('OverviewPackages',main)
        self.assertIn('OverviewServices',main)
        self.assertNotIn('id="nocPackageBars"',html)
        self.assertNotIn('id="nocApiState"',html)

    def test_aggregator_is_reused_not_reinvented(self):
        model=(WEB/"overview-model.mjs").read_text(encoding="utf-8")
        self.assertIn("groupLoadedAccounts",model)
        self.assertIn("lastSyncedAt",model)
        self.assertIn("groups",model)
        app=(WEB/"app.mjs").read_text(encoding="utf-8")
        self.assertIn("buildOverviewSnapshot",app)
        self.assertIn("onOverviewError()",app)
        self.assertIn("publishOverview()",app)

    def test_react_makes_no_unsupported_router_or_freeradius_claim(self):
        jsx=(FRONT/"Overview.tsx").read_text(encoding="utf-8")
        self.assertIn("export function OverviewPackages()",jsx)
        self.assertIn("export function OverviewServices()",jsx)
        for marker in ("غير مفحوص من الواجهة", "غير مفعلة بعد",
                       "أول 100", "API وقاعدة PostgreSQL", "لا تعني اتصال أجهزة MikroTik"):
            self.assertIn(marker,jsx)
        self.assertNotIn("fetch(",jsx)
        self.assertNotIn("Authorization",jsx)
        self.assertNotIn("dangerouslySetInnerHTML",jsx)

    def test_legacy_noc_controller_stops_manipulating_react_owned_dom(self):
        js=(WEB/"noc-ui.mjs").read_text(encoding="utf-8")
        for forbidden in ("el('nocPackageBars')","el('nocApiState')",
                          "el('nocApiLed')","el('nocLastSync')",
                          "renderBars()", "groupLoadedAccounts("):
            self.assertNotIn(forbidden,js)
        self.assertIn("nocTopStatusText",js)
        self.assertIn("downloadFilteredCsv",js)

    def test_deployed_bundle_has_insight_components(self):
        smoke=(ROOT/"scripts/ui-smoke.sh").read_text(encoding="utf-8")
        self.assertIn('reactOverviewPackages',smoke)
        self.assertIn('reactOverviewServices',smoke)
        self.assertIn('noc-bar-track',smoke)

if __name__=="__main__":
    unittest.main(verbosity=2)
