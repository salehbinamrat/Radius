#!/usr/bin/env python3
"""Guard NOC styling against fake backend state, duplicate IDs and remote dependencies."""
from pathlib import Path
from html.parser import HTMLParser
import re
import unittest
ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/'src/RadiusManager.Api/wwwroot'
HTML=(WEB/'index.html').read_text(encoding='utf-8')
APP=(WEB/'app.mjs').read_text(encoding='utf-8')
UI=(WEB/'noc-ui.mjs').read_text(encoding='utf-8')
CSS=(WEB/'noc.css').read_text(encoding='utf-8')

class Parse(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids=[]
        self.remote=[]
        self.handlers=[]
        self.styles=[]
        self.scripts=[]
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if a.get('id'):self.ids.append(a['id'])
        for key,val in attrs:
            if key.lower().startswith('on'):self.handlers.append((tag,key))
            if key in ('href','src') and val.startswith(('https://','http://','//')):self.remote.append(val)
        if tag=='script':self.scripts.append(a.get('src'))
        if tag=='link' and a.get('rel')=='stylesheet':self.styles.append(a.get('href'))

class NocUiTests(unittest.TestCase):
    def setUp(self):
        self.page=Parse();self.page.feed(HTML)
    def test_unique_ids_and_known_controls(self):
        self.assertEqual(len(self.page.ids),len(set(self.page.ids)))
        needed={'nocQuickSearch','nocSearchResults','nocThemeToggle','sidebarCollapse',
                'nocActivityToggle','nocActivityClose','nocDrawerBackdrop','nocActivityDrawer',
                'nocActivityList','nocPackageBars','nocApiState','nocTopStatusText',
                'nocExportPlans','nocExportAccounts','nocLastSync'}
        self.assertTrue(needed.issubset(self.page.ids),needed-set(self.page.ids))
        referenced=set(re.findall(r"el\('([A-Za-z0-9_-]+)'\)",UI))
        self.assertFalse(referenced-set(self.page.ids),referenced-set(self.page.ids))
    def test_self_hosted_assets_and_strict_csp_compatibility(self):
        self.assertEqual(self.page.remote,[])
        self.assertEqual(self.page.handlers,[])
        self.assertEqual(self.page.scripts,['app.mjs','modern/noc-react.mjs'])
        self.assertEqual(self.page.styles,['styles.css','noc.css','ultra.css'])
        for dep in ['cdn.tailwindcss.com','jsdelivr.net','fonts.googleapis.com']:
            self.assertNotIn(dep,HTML+CSS+UI)
        self.assertNotIn('.innerHTML',UI)
        self.assertNotIn('eval(',UI)
    def test_no_fake_services_or_persistent_secrets(self):
        self.assertIn('غير مفحوص من الواجهة',HTML)
        self.assertIn('غير مفعلة بعد',HTML)
        self.assertIn('أول 100 كرت',HTML)
        self.assertIn('noc?.status(true)',APP)
        self.assertIn('noc?.status(false)',APP)
        self.assertIn('noc?.reset()',APP)
        self.assertIn('getAccounts: () => accounts',APP)
        self.assertNotIn('localStorage',APP+UI)
        self.assertNotIn('sessionStorage',APP+UI)
        self.assertNotIn('Math.random()',UI)
        self.assertNotIn('password:',UI)
    def test_exports_are_filtered_and_exclude_passwords(self):
        self.assertIn('buildSafeCsv',UI)
        self.assertIn("el('planSearch')",UI)
        self.assertIn("el('labSearch')",UI)
        self.assertIn("el('labFilter')",UI)
        self.assertNotIn('secret',UI.lower())
        self.assertNotIn('data.password',UI)
    def test_mobile_and_accessibility(self):
        self.assertIn('@media(max-width:680px)',CSS)
        self.assertIn('prefers-reduced-motion',CSS)
        self.assertIn('aria-expanded',HTML)
        self.assertIn('role="dialog"',HTML)
        self.assertIn("event.key === 'Escape'",UI)
if __name__=='__main__':unittest.main(verbosity=2)
