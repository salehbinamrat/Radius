#!/usr/bin/env python3
"""Stage 03G: React voucher list must not receive or store one-time lab passwords."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/'src/RadiusManager.Api/wwwroot'
UI=ROOT/'src/RadiusManager.Api/frontend/src'
class VoucherMigrationChecks(unittest.TestCase):
    def test_react_listing_and_legacy_credential_creation_coexist(self):
        html=(WEB/'index.html').read_text(encoding='utf-8')
        app=(WEB/'app.mjs').read_text(encoding='utf-8')
        main=(UI/'main.tsx').read_text(encoding='utf-8')
        for marker in ('id="reactVoucherList"','id="labForm"','id="labPlan"',
                       'id="labCredentials"','id="nocExportAccounts"',
                       'id="labSearch"','id="labFilter"'):
            self.assertIn(marker,html)
        self.assertNotIn('id="labList"',html)
        self.assertIn('VoucherList',main)
        self.assertIn("clearCredentials()",app)
        self.assertIn("el('labCredentials').textContent",app)
    def test_client_only_receives_allowlisted_fields_from_authorized_api(self):
        app=(WEB/'app.mjs').read_text(encoding='utf-8')
        model=(WEB/'voucher-view-model.mjs').read_text(encoding='utf-8')
        jsx=(UI/'VoucherList.tsx').read_text(encoding='utf-8')
        for token in ('buildVoucherViewSnapshot','radius-vouchers-updated','radius-vouchers-request',
                      'radius-voucher-usage','radius-voucher-disable'):
            self.assertIn(token,app+jsx+model)
        for field in ('username','planName','active'):
            self.assertIn(field,model)
        for forbidden in ('password','sessionSecret','Cleartext-Password','localStorage','sessionStorage',
                          'Authorization','dangerouslySetInnerHTML','fetch('):
            self.assertNotIn(forbidden,jsx)
        self.assertNotIn("el('labList')",app)
        self.assertNotIn('renderAccounts()',app)
    def test_server_owning_account_disable_and_usage_logic_is_unchanged(self):
        app=(WEB/'app.mjs').read_text(encoding='utf-8')
        for token in ('async function disableAccount(username)', 'async function queryUsage(username)',
                      '/api/lab-accounts/', "el('labForm').addEventListener",
                      "el('usageAccount').value", 'window.confirm'):
            self.assertIn(token,app)
        smoke=(ROOT/'scripts/ui-smoke.sh').read_text(encoding='utf-8')
        self.assertIn('reactVoucherList',smoke)
        self.assertIn('radius-vouchers-updated',smoke)
if __name__=='__main__':unittest.main(verbosity=2)
