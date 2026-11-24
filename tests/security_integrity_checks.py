"""Stage 04B3A-S: CI provenance and fail-closed repository secret guard."""
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class SecurityIntegrityChecks(unittest.TestCase):
    def test_checkout_and_actions_are_immutable(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        import re
        actions = re.findall(r'(?m)^\s*- uses: (\S+)', ci)
        self.assertEqual(len(actions), 6)
        for action in actions:
            self.assertRegex(action, r'^[^@]+@[a-f0-9]{40}$')
        self.assertEqual(ci.count('persist-credentials: false'), 3)
        self.assertEqual(ci.count('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"'), 3)
        self.assertIn('permissions:\n  contents: read', ci)
        self.assertIn('needs: [dotnet-tests, config-tests]', ci)
        self.assertIn('python3 scripts/check-tracked-secrets.py', ci)

    def test_secret_guard_detects_keys_tokens_and_secret_files_without_printing_values(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('guard', ROOT / 'scripts/check-tracked-secrets.py')
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        token = b'ghp_' + b'a' * 36
        key = b'-----BEGIN ' + b'RSA PRIVATE KEY-----'
        self.assertTrue(guard.content_risk(token))
        self.assertTrue(guard.content_risk(key))
        self.assertFalse(guard.content_risk(b'RADIUS_SECRET_FILE=/run/secrets/radius-secret'))
        for name in ('.env', 'nested/.env.local', 'a/server.pfx', 'a/private.key', 'id_ed25519'):
            self.assertTrue(guard.path_risk(name), name)
        for name in ('.env.example', 'src/SecretInput.cs', 'tests/example.txt'):
            self.assertFalse(guard.path_risk(name), name)
        result = subprocess.run(['python3', str(ROOT / 'scripts/check-tracked-secrets.py')],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
