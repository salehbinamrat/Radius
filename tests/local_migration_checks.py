"""Ensure local lab initialization cannot become an implicit runtime path."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalMigrationChecks(unittest.TestCase):
    def test_explicit_local_mode_remains_separate_from_default(self):
        executor = (ROOT / "src/RadiusManager.Api/MigrationExecutor.cs").read_text()
        for marker in ('localInstall && Environment.GetEnvironmentVariable("CI") != "true"',
                       'RADIUS_LOCAL_MIGRATION_ACK") == "local-lab-only"',
                       'string.IsNullOrEmpty(mode)', 'actual != "radius-csharp-local:" + stack',
                       'RADIUS_MIGRATION_MANIFEST_SHA256', 'localInstall || stackMode || inject is not'):
            self.assertIn(marker, executor)
        self.assertLess(executor.index("MigrationBundle.Verify("), executor.index("await conn.OpenAsync"))
        self.assertLess(executor.index('actual != "radius-csharp-local:"'), executor.index("SELECT pg_advisory_lock"))
        self.assertNotIn("--migration-install-local", (ROOT / "compose.yaml").read_text())
        overlay = (ROOT / "tests/csharp-stack-local.compose.yaml").read_text()
        for marker in ('CI: "false"', 'LAB_MIGRATION_TEST_MODE: ""',
                       "local-lab-only", "CSHARP_MANIFEST_SHA256:?", "--migration-install-local"):
            self.assertIn(marker, overlay)

    def test_local_full_stack_is_mandatory_and_fail_closed(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        script = (ROOT / "scripts/csharp-stack-candidate-smoke.sh").read_text()
        self.assertIn("bash scripts/csharp-stack-candidate-smoke.sh local-fresh", ci)
        for marker in ("reject_local", "RADIUS_LOCAL_MIGRATION_ACK=", "-e CI=true",
                       "RADIUS_MIGRATION_MANIFEST_SHA256=", "MIGRATION_FAIL_AFTER_SQL_VERSION=2",
                       'CSHARP_BUNDLE_DIR="$tmp/rewritten"', "radius-csharp-local:",
                       "Local C# initialization without CI authorization"):
            self.assertIn(marker, script)
