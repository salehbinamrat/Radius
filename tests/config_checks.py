#!/usr/bin/env python3
"""Static security and layout checks. Independent from Docker/.NET runtime."""
from pathlib import Path
import unittest
import re
import os
import shutil
import stat
import subprocess
import tempfile

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

    def test_setup_without_python_preserves_existing_and_publishes_private_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            shutil.copyfile(ROOT / 'scripts/setup.sh', root / 'scripts/setup.sh')
            shutil.copyfile(ROOT / '.env.example', root / '.env.example')
            # Only explicit utilities, no Python in the child PATH.
            tools = root / 'tools'
            tools.mkdir()
            for name in ('dirname', 'openssl', 'mktemp', 'chmod', 'ln', 'rm', 'rmdir'):
                (tools / name).symlink_to(shutil.which(name))
            env = {**os.environ, 'PATH': str(tools)}
            cmd = [shutil.which('bash'), str(root / 'scripts/setup.sh')]
            first = subprocess.run(cmd, env=env, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            config = root / '.env'
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
            original = config.read_text()
            values = dict(line.split('=', 1) for line in original.splitlines()
                          if line and not line.startswith('#'))
            secrets = [values[key] for key in ('DB_PASSWORD', 'RADIUS_SECRET', 'ADMIN_PASSWORD')]
            self.assertEqual(len(set(secrets)), 3)
            for value in secrets:
                self.assertRegex(value, r'^[a-f0-9]{48}$')
                self.assertNotIn(value, first.stdout + first.stderr)
            self.assertEqual(values['RADIUS_BIND_IP'], '127.0.0.1')
            self.assertEqual(values['ADMIN_USER'], 'admin')
            second = subprocess.run(cmd, env=env, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertTrue(config.read_text() == original)
            config.unlink()
            with subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as one, \
                 subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as two:
                one.communicate(timeout=15)
                two.communicate(timeout=15)
                self.assertEqual((one.returncode, two.returncode), (0, 0))
            self.assertEqual(config.read_text().count('CHANGE_ME_GENERATE_WITH_SETUP'), 0)
            self.assertEqual(len(config.read_text().splitlines()), len(original.splitlines()))
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
            self.assertFalse(list(root.glob('.env.setup.*')))

    def test_setup_refuses_invalid_template_and_generator_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            shutil.copyfile(ROOT / 'scripts/setup.sh', root / 'scripts/setup.sh')
            template = root / '.env.example'
            valid = (ROOT / '.env.example').read_text()
            cmd = ['bash', str(root / 'scripts/setup.sh')]
            for text in (valid.replace('DB_PASSWORD=CHANGE_ME_GENERATE_WITH_SETUP\n', ''),
                         valid + 'DB_PASSWORD=CHANGE_ME_GENERATE_WITH_SETUP\n',
                         valid.replace('ADMIN_PASSWORD=CHANGE_ME_GENERATE_WITH_SETUP', 'ADMIN_PASSWORD=invalid')):
                template.write_text(text)
                self.assertNotEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
                self.assertFalse((root / '.env').exists())
                self.assertFalse(list(root.glob('.env.setup.*')))
            template.write_text(valid)
            tools = root / 'tools'
            tools.mkdir()
            openssl = tools / 'openssl'
            openssl.write_text('#!/bin/sh\nexit 23\n')
            openssl.chmod(0o755)
            env = {**os.environ, 'PATH': str(tools) + ':' + os.environ['PATH']}
            self.assertNotEqual(subprocess.run(cmd, env=env, capture_output=True).returncode, 0)
            self.assertFalse((root / '.env').exists())
            self.assertFalse(list(root.glob('.env.setup.*')))
            (root / '.env').symlink_to(root / 'missing')
            self.assertNotEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
            self.assertTrue((root / '.env').is_symlink())

    def test_quota_explicitly_not_enforced(self):
        text=(ROOT/'README_AR.md').read_text()
        self.assertIn('ليستا مطبقتين',text)
        src=(ROOT/'src/RadiusManager.Api/Program.cs').read_text()
        self.assertIn('accountingEnforced = false',src)
        plans=(ROOT/'src/RadiusManager.Api/PlanEndpoints.cs').read_text()
        self.assertIn('radgroupreply',plans)
        self.assertNotIn('Mikrotik-Total-Limit',src + plans)

    def test_freeradius_auth_sections_parseable_multiline(self):
        site=(ROOT/'radius/default.site').read_text()
        for auth_type, module in [('PAP','pap'),('CHAP','chap'),('MS-CHAP','mschap')]:
            self.assertIn(f'Auth-Type {auth_type} {{\n      {module}\n    }}', site)
        self.assertNotRegex(site, r'Auth-Type[ \t]+[A-Z-]+[ \t]*\{[ \t]*\w+[ \t]*\}')

    def test_lab_migration_runs_on_existing_database(self):
        script=(ROOT/'radius/schema-init.sh').read_text()
        self.assertIn('002_lab_accounts.sql',script)
        self.assertIn('initial schema init skipped.',script)
        self.assertIn('./database/002_lab_accounts.sql', (ROOT/'compose.yaml').read_text())

    def test_lab_smoke_sends_valid_json_body(self):
        script=(ROOT/'scripts/lab-account-smoke.sh').read_text()
        self.assertIn('payload=$(printf', script)
        self.assertIn('-d "$payload" "$API/lab-accounts"',script)

    def test_lab_endpoints_are_only_for_generated_users(self):
        routes=(ROOT/'src/RadiusManager.Api/LabAccountEndpoints.cs').read_text()
        self.assertIn('RequireRateLimiting("admin")',routes)
        self.assertIn('Cleartext-Password',routes)
        self.assertIn('radusergroup',routes)
        self.assertIn('existingSessionsMayContinue = true',routes)
        self.assertIn('quota_bytes IS NULL AND validity_days IS NULL',routes)
        self.assertIn('MapLabAccountEndpoints(sessionMode)', (ROOT/'src/RadiusManager.Api/Program.cs').read_text())
        self.assertNotIn('INSERT INTO radcheck', (ROOT/'database/002_lab_accounts.sql').read_text())

    def test_accounting_is_observational_not_a_balance_ledger(self):
        sql=(ROOT/'database/003_accounting.sql').read_text()
        api=(ROOT/'src/RadiusManager.Api/LabUsageEndpoints.cs').read_text()
        self.assertIn('app_lab_usage_snapshot',sql)
        self.assertIn('FROM radacct a',sql)
        self.assertIn('acctstoptime IS NULL',sql)
        self.assertIn('COUNT(DISTINCT a.nasipaddress)',sql)
        self.assertIn('BillingVerified = false',api)
        self.assertIn('QuotaEnforced = false',api)
        self.assertIn('MapLabUsageEndpoints()', (ROOT/'src/RadiusManager.Api/Program.cs').read_text())
        self.assertIn('003_accounting.sql', (ROOT/'radius/schema-init.sh').read_text())
        self.assertIn('003_accounting.sql', (ROOT/'compose.yaml').read_text())
        self.assertIn('scripts/accounting-smoke.sh', (ROOT/'.github/workflows/ci.yml').read_text())

    def test_no_default_real_accounts(self):
        self.assertNotIn('INSERT INTO radcheck',(ROOT/'database/001_app.sql').read_text())
        self.assertIn('lab_', (ROOT/'scripts/smoke-test.sh').read_text())

    def test_sql_queries_parameterized(self):
        source=(ROOT/'src/RadiusManager.Api/PlanEndpoints.cs').read_text()
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
