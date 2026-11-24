#!/usr/bin/env python3
"""Dependency-free, offline guards for the redesigned RADIUS lab dashboard."""
from html.parser import HTMLParser
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / 'src/RadiusManager.Api/wwwroot'
HTML = (WEB / 'index.html').read_text(encoding='utf-8')
CSS = (WEB / 'styles.css').read_text(encoding='utf-8')
JS = (WEB / 'app.mjs').read_text(encoding='utf-8')

class Parse(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.attrs = []
        self.scripts = []
        self.external = []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.attrs.append((tag,a))
        if 'id' in a: self.ids.append(a['id'])
        if tag == 'script': self.scripts.append(a)
        for field in ('href','src'):
            if a.get(field,'').startswith(('https://','http://','//')):
                self.external.append(a[field])

class UiStructureChecks(unittest.TestCase):
    def setUp(self):
        self.page=Parse();self.page.feed(HTML)
    def test_unique_ids_and_all_js_bindings_present(self):
        self.assertEqual(len(self.page.ids), len(set(self.page.ids)))
        used=set(re.findall(r"el\('([A-Za-z0-9_-]+)'\)",JS))
        react=(ROOT/'src/RadiusManager.Api/frontend/src/PlanManagement.tsx').read_text(encoding='utf-8')
        unresolved={name for name in used-set(self.page.ids) if f'id="{name}"' not in react}
        self.assertFalse(unresolved,f'Missing HTML/React IDs: {unresolved}')
    def test_secure_shell_never_loads_external_assets(self):
        self.assertEqual(self.page.external,[])
        self.assertEqual([s.get('src') for s in self.page.scripts],['app.mjs','modern/noc-react.mjs'])
        self.assertFalse(any(any(key.lower().startswith('on') for key in attrs) for _,attrs in self.page.attrs))
    def test_required_views_and_real_form_identifiers(self):
        for key in ['view-overview','view-plans','view-vouchers','view-accounting','view-networks','view-roadmap','loginPanel','dashboard','reactPlanEditor','reactPlansTable','labForm','usageReport','usageAccount','planSearch','labFilter']:
            self.assertIn(key,self.page.ids)
        react=(ROOT/'src/RadiusManager.Api/frontend/src/PlanManagement.tsx').read_text(encoding='utf-8')
        for key in ['planForm','planName','planDown','planUp','planQuota','planDays']:
            self.assertIn('id="'+key+'"',react)
        self.assertIn('data-view="overview"',HTML)
        self.assertIn('data-view="accounting"',HTML)
    def test_no_mock_data_or_stored_admin_password_in_production(self):
        self.assertNotIn('localStorage',JS)
        self.assertNotIn('sessionStorage',JS)
        self.assertNotIn('demoAccounts',JS)
        self.assertNotIn('fakeAccounts',JS)
        self.assertIn('textContent =',JS)
        self.assertNotIn('.innerHTML',JS)
        self.assertIn('clearCredentials()',JS)
    def test_nonproduction_features_visibly_disclosed(self):
        self.assertIn('لا تستخدم كروت فعلية',HTML)
        self.assertIn('لم يتم تفعيلها بعد',HTML)
        self.assertIn('قيد التطوير',HTML)
        self.assertIn('حد القراءة: 100',JS)
    def test_mobile_responsive_and_accessibility(self):
        self.assertIn('@media(max-width:950px)',CSS)
        self.assertIn('@media(max-width:680px)',CSS)
        self.assertIn('prefers-reduced-motion',CSS)
        self.assertIn('aria-current',JS)
        self.assertIn('aria-expanded',HTML)
        self.assertIn('role="alert"',HTML)

if __name__=='__main__':unittest.main(verbosity=2)
