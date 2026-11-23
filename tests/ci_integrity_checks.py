#!/usr/bin/env python3
"""Stage 1 CI invariants. Tests are written before the CI refactor."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CiIntegrityChecks(unittest.TestCase):
    def test_parallel_gates_and_downstream_integration(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text(encoding='utf-8')
        self.assertRegex(ci, r'(?m)^  dotnet-tests:\s*$')
        self.assertRegex(ci, r'(?m)^  config-tests:\s*$')
        self.assertRegex(ci, r'(?m)^  compose-integration:\s*$')
        self.assertIn('needs: [dotnet-tests, config-tests]', ci)
        self.assertIn('run: bash scripts/ci-config-checks.sh', ci)
        self.assertIn('run: bash scripts/api-contract-smoke.sh', ci)

    def test_all_module_syntax_and_all_python_checks_are_discovered(self):
        script = (ROOT / 'scripts/ci-config-checks.sh').read_text(encoding='utf-8')
        self.assertIn('node --test tests/js/*.test.mjs', script)
        self.assertIn('bash -n scripts/*.sh radius/*.sh', script)
        self.assertIn('node --check', script)
        self.assertIn("'*.mjs'", script)
        self.assertIn("python3 -m unittest discover -s tests -p '*checks.py'", script)
        modules = list((ROOT / 'src/RadiusManager.Api/wwwroot').rglob('*.mjs'))
        self.assertTrue(modules)

    def test_sensitive_credentials_never_checked_in(self):
        self.assertIn('.env\n', (ROOT / '.gitignore').read_text(encoding='utf-8'))
        self.assertFalse((ROOT / '.env').exists())
        self.assertTrue((ROOT / 'scripts/setup.sh').exists())

    def test_plans_extracted_without_changing_public_routes(self):
        program = (ROOT / 'src/RadiusManager.Api/Program.cs').read_text(encoding='utf-8')
        plans = (ROOT / 'src/RadiusManager.Api/PlanEndpoints.cs').read_text(encoding='utf-8')
        self.assertIn('api.MapPlanEndpoints()', program)
        self.assertIn('api.MapGet("/plans"', plans)
        self.assertIn('api.MapPost("/plans"', plans)
        self.assertIn('api.MapPut("/plans/{id:guid}"', plans)
        self.assertIn('BeginTransactionAsync', plans)
        self.assertIn('UniqueViolation', plans)
        self.assertIn('accountingEnforced = false', plans)
        self.assertNotIn('api.MapPost("/plans"', program)

if __name__ == '__main__':
    unittest.main(verbosity=2)
