"""Stage 04B3A-S: CI provenance and fail-closed repository secret guard."""
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class SecurityIntegrityChecks(unittest.TestCase):
    def test_checkout_and_actions_are_immutable(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        import re
        # A step can start with "- uses:" or "- name:" followed by "uses:".
        pattern = r'(?m)^[ \t]+(?:-[ \t]+)?uses:[ \t]+(\S+)'
        actions = re.findall(pattern, ci)
        self.assertEqual(len(actions), 7)
        for action in actions:
            self.assertRegex(action, r'^[^@]+@[a-f0-9]{40}$')
        from collections import Counter
        self.assertEqual(Counter(action.split('@', 1)[0] for action in actions), {
            'actions/checkout': 3,
            'actions/setup-node': 2,
            'actions/setup-dotnet': 1,
            'actions/upload-artifact': 1,
        })
        # Exercise both YAML layouts, including an unpinned named step.
        sample = (
            '      - uses: actions/checkout@v4\n'
            '      - name: Upload\n'
            '        uses: actions/upload-artifact@v4\n'
        )
        self.assertEqual(re.findall(pattern, sample),
                         ['actions/checkout@v4', 'actions/upload-artifact@v4'])
        for action in re.findall(pattern, sample):
            self.assertNotRegex(action, r'^[^@]+@[a-f0-9]{40}$')
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

    def test_radius_uses_patched_distribution_and_strict_lab_authenticator(self):
        docker = (ROOT / 'radius/Dockerfile').read_text()
        self.assertIn('FROM debian:trixie-slim', docker)
        self.assertIn('3.2.7+dfsg-1+deb13u2', docker)
        for name in ('freeradius', 'freeradius-postgresql', 'freeradius-utils'):
            self.assertIn(name + '="${FREERADIUS_VERSION}"', docker)
        clients = (ROOT / 'radius/clients.template').read_text()
        self.assertEqual(clients.count('require_message_authenticator = yes'), 2)
        self.assertEqual(clients.count('limit_proxy_state = yes'), 2)
        self.assertNotIn('require_message_authenticator = no', clients)
        self.assertNotIn('limit_proxy_state = no', clients)
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('scripts/radius-authenticator-smoke.sh', ci)

    def test_build_base_images_have_immutable_digests(self):
        import re
        for path, expected in (('radius/Dockerfile', 1), ('src/RadiusManager.Api/Dockerfile', 3)):
            source = (ROOT / path).read_text()
            images = re.findall(r'(?m)^FROM (\S+)', source)
            self.assertEqual(len(images), expected, path)
            for image in images:
                self.assertRegex(image, r'@sha256:[a-f0-9]{64}$', path)
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('docker image inspect postgres:16-bookworm', ci)
        self.assertNotIn('scripts/emit-lock-candidate.py', ci)
        postgres_images = set()
        for path in ('compose.yaml', 'tests/admin-https.compose.yaml', 'tests/isolated-restore.compose.yaml'):
            compose = (ROOT / path).read_text()
            images = re.findall(r'(?m)^\s*image: (postgres:\S+)', compose)
            self.assertEqual(len(images), 1, path)
            self.assertRegex(images[0], r'^postgres:16-bookworm@sha256:[a-f0-9]{64}$')
            postgres_images.update(images)
        self.assertEqual(len(postgres_images), 1)

    def test_dependency_lockfiles_and_fail_closed_restore(self):
        import json
        import xml.etree.ElementTree as ET
        for path in ('src/RadiusManager.Api/frontend', 'tests/browser'):
            directory = ROOT / path
            manifest = json.loads((directory / 'package.json').read_text())
            lock = json.loads((directory / 'package-lock.json').read_text())
            self.assertEqual(lock['lockfileVersion'], 3)
            for group in ('dependencies', 'devDependencies'):
                self.assertEqual(lock['packages'][''].get(group, {}), manifest.get(group, {}))
            for name, entry in lock['packages'].items():
                if name:
                    self.assertRegex(entry['integrity'], r'^sha(?:512|1)-')
                    self.assertTrue(entry['resolved'].startswith('https://registry.npmjs.org/'))
        for project in ('src/RadiusManager.Api/RadiusManager.Api.csproj', 'tests/RadiusManager.Tests/RadiusManager.Tests.csproj'):
            csproj = ROOT / project
            lock = json.loads((csproj.parent / 'packages.lock.json').read_text())
            deps = lock['dependencies']['net10.0']
            for package in ET.parse(csproj).getroot().iter('PackageReference'):
                entry = deps[package.attrib['Include']]
                self.assertEqual(entry['type'], 'Direct')
                self.assertEqual(entry['resolved'], package.attrib['Version'])
                self.assertTrue(entry['contentHash'])
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        docker = (ROOT / 'src/RadiusManager.Api/Dockerfile').read_text()
        self.assertIn('dotnet restore tests/RadiusManager.Tests/RadiusManager.Tests.csproj --locked-mode', ci)
        self.assertIn('npm ci --no-audit --no-fund --ignore-scripts', ci)
        self.assertIn('npm ci --prefix tests/browser --no-audit --no-fund --ignore-scripts', ci)
        self.assertNotIn('npm install ', ci)
        self.assertIn('COPY frontend/package.json frontend/package-lock.json', docker)
        self.assertIn('COPY RadiusManager.Api.csproj packages.lock.json', docker)
        self.assertIn('RUN dotnet restore --locked-mode', docker)
        self.assertIn('RUN npm ci --no-audit --no-fund --ignore-scripts', docker)
        self.assertNotIn('npm install ', docker)
        self.assertIn('git diff --exit-code --', ci)


    def test_security_scan_and_sbom_are_mandatory(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        scan = (ROOT / 'scripts/security-scan-ci.sh').read_text()
        self.assertIn('-p:NuGetAudit=true -p:NuGetAuditMode=all -p:NuGetAuditLevel=low', ci)
        self.assertIn('npm audit --audit-level=high --include=dev --include=optional', ci)
        self.assertIn('npm audit --prefix tests/browser --package-lock-only --audit-level=high', ci)
        self.assertIn('run: bash scripts/security-scan-ci.sh', ci)
        self.assertIn('LAB_SECURITY_SCAN_ACK: isolated-ci', ci)
        self.assertIn('actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02', ci)
        self.assertNotIn('continue-on-error:', ci)
        self.assertIn('sha256sum -c -', scan)
        self.assertIn('for service in api radius db;', scan)
        self.assertIn("--format '{{.Image}}'", scan)
        self.assertIn('--image-src docker --scanners vuln --severity HIGH,CRITICAL', scan)
        self.assertIn('--exit-code 1 --exit-on-eol 1', scan)
        self.assertIn('--format cyclonedx', scan)
        self.assertIn('exit "$failed"', scan)
        for option in ('--ignore-unfixed', '--skip-db-update', '--exit-code 0'):
            self.assertNotIn(option, scan)
