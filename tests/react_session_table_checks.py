#!/usr/bin/env python3
"""Stage 03I: move only readonly accounting table to React while keeping API and CSV."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/'src/RadiusManager.Api/wwwroot'
FRONT=ROOT/'src/RadiusManager.Api/frontend/src'

class ReactSessionTableChecks(unittest.TestCase):
    def test_mount_and_readonly_no_network_bypass(self):
        html=(WEB/'index.html').read_text(encoding='utf-8')
        ui=(FRONT/'SessionTable.tsx').read_text(encoding='utf-8')
        main=(FRONT/'main.tsx').read_text(encoding='utf-8')
        self.assertIn('id="reactSessionTable"',html)
        self.assertNotIn('id="ultraSessionsList"',html)
        for part in ('id="ultraSessionsRefresh"','id="ultraSessionState"',
                     'id="ultraSessionSearch"','id="ultraSessionsExport"',
                     'id="ultraSessionsWarning"','id="ultraSessionCount"'):
            self.assertIn(part,html)
        self.assertIn('SessionTable',main)
        self.assertIn('radius-sessions-updated',ui)
        self.assertIn('radius-sessions-request',ui)
        for forbidden in ('fetch(','Authorization','localStorage','sessionStorage',
                          'dangerouslySetInnerHTML','Cleartext-Password'):
            self.assertNotIn(forbidden,ui)

    def test_existing_search_export_and_server_request_stay_in_one_place(self):
        source=(WEB/'ultra-features.mjs').read_text(encoding='utf-8')
        model=(WEB/'session-view-model.mjs').read_text(encoding='utf-8')
        for marker in ("buildSessionViewSnapshot(", "radius-sessions-updated",
                       "radius-sessions-request", "el('ultraSessionSearch')",
                       "el('ultraSessionState')","el('ultraSessionsExport')",
                       "buildSafeCsv","/api/lab-sessions?state="):
            self.assertIn(marker,source+model)
        self.assertNotIn("el('ultraSessionsList')",source)
        self.assertNotIn('insertRow()',source)
        for marker in ("open-unconfirmed", "قديمة / غير مؤكدة", "غير سليم",
                       "first-100-loaded"):
            self.assertIn(marker,model)
        self.assertNotIn('password',model)

    def test_smoke_includes_both_react_and_mjs(self):
        smoke=(ROOT/'scripts/ui-smoke.sh').read_text(encoding='utf-8')
        self.assertIn('reactSessionTable',smoke)
        self.assertIn('session-view-model.mjs',smoke)
        self.assertIn('radius-sessions-updated',smoke)

if __name__ == '__main__':
    unittest.main(verbosity=2)
