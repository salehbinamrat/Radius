#!/usr/bin/env python3
"""Stage 03F tests-first: React plan CRUD preserves the original API + validation."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
API=ROOT/"src/RadiusManager.Api"
WEB=API/"wwwroot"
FRONT=API/"frontend/src"

class PlanMigrationContracts(unittest.TestCase):
    def test_react_owns_plan_editor_and_table_without_duplicate_controls(self):
        html=(WEB/"index.html").read_text(encoding="utf-8")
        ui=(FRONT/"PlanManagement.tsx").read_text(encoding="utf-8")
        main=(FRONT/"main.tsx").read_text(encoding="utf-8")
        for marker in ('id="reactPlanEditor"','id="reactPlansTable"','id="planSearch"','id="nocExportPlans"',
                       'id="refresh"','id="openPlanForm"','id="view-plans"'):
            self.assertIn(marker,html)
        for marker in ('id="planForm"','id="planName"','id="planDown"','id="planUp"',
                       'id="planQuota"','id="planDays"','id="savePlan"','id="cancelEdit"'):
            self.assertIn(marker,ui)
            self.assertNotIn(marker,html)
        self.assertIn("PlanEditor",main)
        self.assertIn("PlansTable",main)
        self.assertNotIn('id="plansList"',html)

    def test_single_validated_http_mutation_path_remains_in_legacy_authenticated_client(self):
        js=(WEB/"app.mjs").read_text(encoding="utf-8")
        jsx=(FRONT/"PlanManagement.tsx").read_text(encoding="utf-8")
        model=(WEB/"plan-view-model.mjs").read_text(encoding="utf-8")
        for token in ('normalizedPlan(','radius-plan-save-request','radius-plans-updated',
                      'radius-plan-edit','radius-plan-clear-edit','/api/plans'):
            self.assertIn(token,js+jsx)
        self.assertIn('buildPlanViewSnapshot(',js)
        self.assertIn("filterPlans(",model)
        self.assertNotIn('fetch(',jsx)
        self.assertNotIn('Authorization',jsx)
        self.assertNotIn('localStorage',jsx)
        self.assertNotIn('sessionStorage',jsx)
        self.assertNotIn('dangerouslySetInnerHTML',jsx)
        self.assertNotIn("el('planForm')",js)
        self.assertNotIn("el('plansList')",js)

    def test_all_old_operators_and_exports_are_preserved(self):
        js=(WEB/"app.mjs").read_text(encoding="utf-8")
        noc=(WEB/"noc-ui.mjs").read_text(encoding="utf-8")
        for token in ("el('planSearch')","el('nocExportPlans')","el('refresh')"):
            self.assertIn(token,js+noc)
        for token in ("radius-voucher-create-request", "el('labSearch')", "el('labFilter')",
                      "el('openPlanForm')", "el('refreshAll')"):
            self.assertIn(token,js)
        self.assertIn("buildSafeCsv",noc)
        self.assertIn("clearCredentials()",js)
        self.assertIn("sessionCsrf",js)
        creator=(FRONT/'VoucherCreator.tsx').read_text(encoding='utf-8')
        self.assertIn('id="labForm"',creator)
        self.assertIn('id="labPlan"',creator)

    def test_smoke_validates_frontend_bundling(self):
        smoke=(ROOT/"scripts/ui-smoke.sh").read_text(encoding="utf-8")
        self.assertIn('reactPlanEditor',smoke)
        self.assertIn('reactPlansTable',smoke)
        self.assertIn('radius-plan-save-request',smoke)

if __name__=="__main__":
    unittest.main(verbosity=2)
