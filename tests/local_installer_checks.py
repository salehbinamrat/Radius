"""Check the local installer does not assume CI or touch existing deployments."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import os

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts/install-csharp-local-lab.sh"


class LocalInstallerChecks(unittest.TestCase):
    def test_refuses_without_ack_or_existing_destination_before_docker(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = ["bash", str(INSTALLER), tmp, *["sha256:" + "a"*64]*3]
            for ack in ("", "local-lab-only"):
                result = subprocess.run(args, env={**os.environ, "RADIUS_LOCAL_INSTALL_ACK": ack},
                                        capture_output=True, check=False)
                self.assertEqual(result.returncode, 2)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_local_only_and_no_destructive_fallback(self):
        source = INSTALLER.read_text()
        for marker in ("unix:///var/run/docker.sock", "env -i", "local-lab-only",
                       "label=com.docker.compose.project", "radius-csharp-local:",
                       "export-csharp-init-bundle.sh", "CSHARP_MANIFEST_SHA256",
                       "stack up -d --wait db", "stack up -d api radius", "retained state",
                       "C# local laboratory installation PASS"):
            self.assertIn(marker, source)
        for forbidden in ("down -v", "rm -rf", "python3 /", "--build", "docker pull"):
            self.assertNotIn(forbidden, source)
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("run: bash scripts/csharp-local-installer-smoke.sh", ci)
        self.assertNotIn("--migration-install-local", (ROOT / "compose.yaml").read_text())

    def test_slim_profile_and_self_contained_compose_are_explicit(self):
        source = INSTALLER.read_text()
        smoke = (ROOT / "scripts/csharp-local-installer-smoke.sh").read_text()
        compose = (ROOT / "tests/csharp-stack-candidate.compose.yaml").read_text()
        self.assertIn('RADIUS_LOCAL_RUNTIME:-slim', source)
        self.assertIn("Slim runtime requires the Python-free RADIUS image", source)
        self.assertLess(source.index("Slim runtime requires"), source.index('mkdir -- "$state"'))
        for marker in ('"$state/compose/csharp-stack-candidate.compose.yaml"',
                       '"$state/compose/csharp-stack-local.compose.yaml"',
                       '--project-directory "$state"', 'runtime-profile'):
            self.assertIn(marker, source)
        self.assertIn('CSHARP_BUNDLE_DIR:?Required verified migration bundle}/migrations/001_app.sql', compose)
        self.assertIn('Path(mount["source"]).is_relative_to(state)', smoke)
        self.assertIn('(cd "$state" && bash manage.sh stop)', smoke)
        self.assertIn('(cd "$state" && bash manage.sh start)', smoke)
        self.assertIn("Python-free image accepted by actual local installer", smoke)

    def test_installed_manager_is_non_destructive_and_checks_identity(self):
        manager = (ROOT / "scripts/manage-csharp-local-lab.sh").read_text()
        installer = INSTALLER.read_text()
        smoke = (ROOT / "scripts/csharp-local-installer-smoke.sh").read_text()
        for marker in ("installation.sha256", "sha256sum --check --strict --status",
                       "Local service identity mismatch", "Original local service container missing",
                       "stack start db", "stack start radius api", "stack stop db",
                       "radius-csharp-local:", "SELECT count(*) FROM app_schema_migrations"):
            self.assertIn(marker, manager)
        for forbidden in ("stack up", "stack down", "docker pull", "rm -rf", "--build"):
            self.assertNotIn(forbidden, manager)
        self.assertIn('cp -- "$root/scripts/manage-csharp-local-lab.sh" "$state/manage.sh"', installer)
        self.assertIn('unset RADIUS_LOCAL_RUNTIME', smoke)
        self.assertIn('export RADIUS_LOCAL_RUNTIME=compatible', smoke)
        self.assertIn('Manager accepted modified installed Compose file', smoke)
        self.assertIn("Installed manager rejects changed configuration", smoke)
        for marker in ("container-identities.txt", "ledger.sha256", "ORDER BY version"):
            self.assertIn(marker, installer)
            self.assertIn(marker, manager)
        self.assertIn("Manager accepted substituted container identity", smoke)
        self.assertIn("Manager accepted mismatched migration ledger", smoke)
