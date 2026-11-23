"""Offline check: Ultra NOC screens never masquerade as live production RADIUS data."""
from html.parser import HTMLParser
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1] / 'src/RadiusManager.Api/wwwroot'
HTML=(ROOT/'index.html').read_text(encoding='utf-8')
APP=(ROOT/'app.mjs').read_text(encoding='utf-8')
NEW=(ROOT/'ultra-features.mjs').read_text(encoding='utf-8')
CSS=(ROOT/'ultra.css').read_text(encoding='utf-8')

class Parser(HTMLParser):
    def __init__(self):
        super().__init__();self.ids=[];self.onattrs=[]
    def handle_starttag(self,tag,attrs):
        for key,value in attrs:
            if key=='id':self.ids.append(value)
            if key.lower().startswith('on'):self.onattrs.append((tag,key))

class UltraUiTests(unittest.TestCase):
    def test_accessible_unique_ids_and_no_inline_event_handlers(self):
        p=Parser();p.feed(HTML)
        self.assertEqual(len(p.ids),len(set(p.ids)))
        self.assertEqual(p.onattrs,[])
    def test_real_existing_app_preserved(self):
        for ident in ['view-overview','view-vouchers','view-plans','view-accounting','view-sessions','view-capacity','planForm','labForm','usageReport']:
            self.assertIn(f'id="{ident}"',HTML)
        self.assertIn('initializeNocUi',APP)
        self.assertIn('initializeUltraFeatures',APP)
    def test_no_unsafe_promises_or_demo_state_leaked_into_production(self):
        self.assertIn('قراءة فقط',HTML)
        self.assertIn('وليس كشفا مؤكدا',HTML)
        self.assertIn('لا يستند إلى قياسات فعلية',HTML)
        self.assertNotIn('innerHTML',NEW)
        self.assertNotIn('localStorage',NEW)
        self.assertNotIn('eval(',NEW)
        self.assertNotIn('fetch(',NEW)
        self.assertIn('/api/lab-sessions',NEW)
        self.assertIn('buildSafeCsv',NEW)
        self.assertIn('max-width:610px',CSS)
    def test_no_external_dependencies_or_secret_disclosure(self):
        self.assertNotIn('cdn.tailwindcss',HTML)
        self.assertNotIn('cdn.jsdelivr',HTML)
        self.assertNotIn('sharedSecret',NEW)
        self.assertNotIn('password',NEW.lower())

if __name__=='__main__':unittest.main(verbosity=2)
