#!/usr/bin/env python3
"""Static security and layout checks. Independent from Docker/.NET runtime."""
from pathlib import Path
import unittest
import re

ROOT=Path(__file__).resolve().parent.parent

class ProjectConfigTests(unittest.TestCase):
    def test_official_schema_loaded_only_after_db_ready(self):
        compose=(ROOT/'compose.yaml').read_text()
        self.assertIn('service_healthy',compose)
        self.assertIn('service_completed_successfully',compose)
        self.assertIn('postgresql/schema.sql',(ROOT/'radius/schema-init.sh').read_text())

    def test_ports_loopback_by_default(self):
        compose=(ROOT/'compose.yaml').read_text()
        self.assertIn('127.0.0.1:8080:8080',compose)
        self.assertIn('${RADIUS_BIND_IP:-127.0.0.1}:1812:1812/udp',compose)
        self.assertIn('${RADIUS_BIND_IP:-127.0.0.1}:1813:1813/udp',compose)
        self.assertNotRegex(compose,r'(?m)^\s*-\s*"0\.0\.0\.0:')
        self.assertNotRegex(compose,r'(?m)^\s*-\s*"5432:')

    def test_example_secrets_are_not_active(self):
        env=(ROOT/'.env.example').read_text()
        self.assertEqual(env.count('CHANGE_ME_GENERATE_WITH_SETUP'),3)
        self.assertFalse((ROOT/'.env').exists(),'do not bundle secrets')
        self.assertIn('.env\n',(ROOT/'.gitignore').read_text())

    def test_quota_explicitly_not_enforced(self):
        text=(ROOT/'README_AR.md').read_text()
        self.assertIn('ليستا مطبقتين',text)
        src=(ROOT/'src/RadiusManager.Api/Program.cs').read_text()
        self.assertIn('accountingEnforced = false',src)
        self.assertIn('radgroupreply',src)
        self.assertNotIn('Mikrotik-Total-Limit',src)

    def test_freeradius_auth_sections_parseable_multiline(self):
        site=(ROOT/'radius/default.site').read_text()
        for auth_type, module in [('PAP','pap'),('CHAP','chap'),('MS-CHAP','mschap')]:
            self.assertIn(f'Auth-Type {auth_type} {{\n      {module}\n    }}', site)
        self.assertNotRegex(site, r'Auth-Type[ \t]+[A-Z-]+[ \t]*\{[ \t]*\w+[ \t]*\}')

    def test_no_default_real_accounts(self):
        self.assertNotIn('INSERT INTO radcheck',(ROOT/'database/001_app.sql').read_text())
        self.assertIn('lab_', (ROOT/'scripts/smoke-test.sh').read_text())

    def test_sql_queries_parameterized(self):
        source=(ROOT/'src/RadiusManager.Api/Program.cs').read_text()
        self.assertIn('AddWithValue',source)
        self.assertIn('BeginTransactionAsync',source)
        self.assertIn('UniqueViolation',source)

    def test_package_contents(self):
        required=['README_AR.md','PROJECT_STATUS_AR.md','compose.yaml',
                  'src/RadiusManager.Api/Program.cs','radius/start.sh','radius/schema-init.sh',
                  'scripts/setup.sh','scripts/smoke-test.sh','.github/workflows/ci.yml']
        for x in required:self.assertTrue((ROOT/x).is_file(),x)

    def test_no_production_mikrotik_credentials(self):
        for item in ROOT.rglob('*'):
            if item.is_file() and item.suffix in ('.yaml','.sh','.sql','.cs','.mjs','.html'):
                self.assertNotRegex(item.read_text(),r'\b(?:10\.0\.0\.1|192\.168\.88\.1)\b')

if __name__=='__main__':unittest.main(verbosity=2)
