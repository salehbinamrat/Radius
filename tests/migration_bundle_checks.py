"""Keep the migration-input export deterministic and free of runtime secrets."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = ROOT / "scripts/export-csharp-init-bundle.sh"


class MigrationBundleChecks(unittest.TestCase):
    def test_export_requires_exact_local_image_and_new_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            for image, dest in (("radius:latest", tmp + "/new"),
                                ("sha256:" + "a" * 64, "relative"),
                                ("sha256:" + "a" * 64, tmp)):
                result = subprocess.run(["bash", str(EXPORTER), image, dest],
                                        capture_output=True, check=False)
                self.assertEqual(result.returncode, 2)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_export_is_offline_and_contains_only_known_inputs(self):
        source = EXPORTER.read_text()
        for marker in ("docker image inspect", "--pull never", "--network none",
                       "--read-only", "--cap-drop ALL", "/opt/share/radius-build/revision",
                       "radius/Dockerfile", "database/[0-9][0-9][0-9]_*.sql",
                       "sha256sum --check --strict --status", "SHA256SUMS.tmp"):
            self.assertIn(marker, source)
        for forbidden in ("docker compose", "psql", "DB_PASSWORD", "RADIUS_SECRET", "rm -rf"):
            self.assertNotIn(forbidden, source)

    def test_candidate_installs_from_verified_bundle(self):
        source = (ROOT / "scripts/csharp-stack-candidate-smoke.sh").read_text()
        compose = (ROOT / "tests/csharp-stack-candidate.compose.yaml").read_text()
        self.assertIn('bash scripts/export-csharp-init-bundle.sh "$radius_id" "$tmp/bundle"', source)
        self.assertIn('cmp -s - "$CSHARP_OFFICIAL_SQL"', source)
        self.assertIn('Tampered migration bundle unexpectedly accepted', source)
        self.assertIn('Migration bundle overwrite unexpectedly accepted', source)
        self.assertIn('Packaged migration input identity and tamper detection PASS', source)
        self.assertIn('CSHARP_BUNDLE_DIR:?Required verified migration bundle', compose)
        self.assertLess(source.index("Packaged migration input identity and tamper detection PASS"),
                        source.index("stack up -d --wait db"))

    def test_bundle_is_verified_by_engine_before_database_connection(self):
        source = (ROOT / "src/RadiusManager.Api/MigrationExecutor.cs").read_text()
        self.assertLess(source.index("MigrationBundle.Verify("), source.index("await conn.OpenAsync"))
        script = (ROOT / "scripts/csharp-stack-candidate-smoke.sh").read_text()
        self.assertIn('CSHARP_BUNDLE_DIR="$tmp/tampered" stack run', script)
        self.assertIn("C# initializer rejected tampered bundle before database writes PASS", script)
