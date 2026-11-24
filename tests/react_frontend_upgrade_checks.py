#!/usr/bin/env python3
"""Stage03K: stable frontend dependency upgrade must not loosen security or pipeline gates."""
import json
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
FRONT=ROOT/'src/RadiusManager.Api/frontend'
class FrontendUpgradeChecks(unittest.TestCase):
    def test_exact_react_vite_typescript_versions(self):
        pkg=json.loads((FRONT/'package.json').read_text(encoding='utf-8'))
        self.assertEqual(pkg['dependencies']['react'],'19.3.1')
        self.assertEqual(pkg['dependencies']['react-dom'],'19.3.1')
        self.assertEqual(pkg['devDependencies']['vite'],'8.3.8')
        self.assertEqual(pkg['devDependencies']['typescript'],'7.0.2')
        self.assertEqual(pkg['devDependencies']['@vitejs/plugin-react'],'6.3.0')
    def test_no_risk_to_existing_security_contracts(self):
        ci=(ROOT/'.github/workflows/ci.yml').read_text(encoding='utf-8')
        docker=(ROOT/'src/RadiusManager.Api/Dockerfile').read_text(encoding='utf-8')
        for line in ('dotnet-tests:', 'config-tests:', 'compose-integration:',
                     'scripts/lab-recovery-smoke.sh', 'scripts/admin-https-smoke.sh',
                     'bash scripts/ui-smoke.sh'):
            self.assertIn(line,ci)
        self.assertIn('needs: [dotnet-tests, config-tests]',ci)
        self.assertIn('node:24-bookworm-slim',docker)
        self.assertIn('npm run check && npm run build',docker)
    def test_stage_execution_doc_is_present(self):
        doc=(ROOT/'STAGE3K_FRONTEND_DEPENDENCIES_AR.md').read_text(encoding='utf-8')
        self.assertIn('React 19.3.1',doc)
        self.assertIn('TypeScript 7.0.2',doc)
        self.assertIn('Vite 8.3.8',doc)
        self.assertIn('npm run check',doc)
        self.assertIn('npm run build',doc)
if __name__=='__main__': unittest.main(verbosity=2)
