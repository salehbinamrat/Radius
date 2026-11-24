#!/usr/bin/env python3
"""Stage 03H tests-first: a one-time voucher secret must not enter React state or storage."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/"src/RadiusManager.Api/wwwroot"
FRONT=ROOT/"src/RadiusManager.Api/frontend/src"

class VoucherCreationChecks(unittest.TestCase):
    def test_react_creator_mount_and_legacy_voucher_list_stay_intact(self):
        html=(WEB/"index.html").read_text(encoding="utf-8")
        main=(FRONT/"main.tsx").read_text(encoding="utf-8")
        creator=(FRONT/"VoucherCreator.tsx").read_text(encoding="utf-8")
        for token in ('id="reactVoucherCreator"','id="reactVoucherList"','id="labSearch"',
                      'id="labFilter"','id="nocExportAccounts"'):
            self.assertIn(token,html)
        for token in ('id="labForm"','id="labPlan"','id="generateLab"',
                      'id="labError"','id="labCredentials"'):
            self.assertNotIn(token,html)
            self.assertIn(token,creator)
        self.assertIn("VoucherCreator",main)
        self.assertIn("VoucherList",main)

    def test_no_persistent_secret_or_secret_containing_react_state(self):
        creator=(FRONT/"VoucherCreator.tsx").read_text(encoding="utf-8")
        for forbidden in ("localStorage","sessionStorage","indexedDB",
                          "dangerouslySetInnerHTML","console.log","console.error",
                          "setPassword(", "useState<string>(", "fetch(", "Authorization"):
            self.assertNotIn(forbidden,creator)
        for required in ("useRef<HTMLPreElement>",".textContent = ''",
                         ".textContent =","radius-voucher-create-request",
                         "radius-voucher-creator-clear","radius-voucher-plans-updated",
                         "currentView.current","generation.current",
                         "view-vouchers", "passwordDisplayedOnce"):
            self.assertIn(required,creator)

    def test_account_creation_and_secret_lifecycle_only_in_legacy_api_controller(self):
        app=(WEB/"app.mjs").read_text(encoding="utf-8")
        model=(WEB/"voucher-create-model.mjs").read_text(encoding="utf-8")
        for required in ("eligibleVoucherPlans","radius-voucher-create-request",
                         "radius-voucher-creator-clear","radius-voucher-plans-updated",
                         "clearCredentials()","if (view !== 'vouchers')",
                         "clearCredentials();resetUsage()",
                         "call('/api/lab-accounts'","passwordDisplayedOnce"):
            self.assertIn(required,app+model)
        self.assertNotIn("el('labCredentials')",app)
        self.assertNotIn("el('labForm')",app)
        self.assertNotIn("el('generateLab')",app)
        self.assertNotIn("el('labPlan')",app)
        self.assertIn("async function disableAccount(username)",app)
        self.assertIn("async function queryUsage(username)",app)
        self.assertIn("radius-vouchers-updated",app)
        self.assertIn("el('usageAccount').value",app)

    def test_ci_tests_and_bundles_creator(self):
        smoke=(ROOT/"scripts/ui-smoke.sh").read_text(encoding="utf-8")
        for token in ("reactVoucherCreator","radius-voucher-create-request",
                      "voucher-create-model.mjs"):
            self.assertIn(token,smoke)
        self.assertTrue((ROOT/"tests/js/voucher-create-model.test.mjs").exists())

if __name__=="__main__":unittest.main(verbosity=2)
