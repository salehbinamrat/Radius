"""Protect the isolated full-stack candidate and its mandatory CI gate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CSharpStackChecks(unittest.TestCase):
    def test_candidate_requires_database_marker(self):
        source = (ROOT / "src/RadiusManager.Api/MigrationExecutor.cs").read_text()
        self.assertIn('mode == "isolated-stack-ci"', source)
        self.assertIn('actual != "radius-csharp-ci:" + stack', source)
        self.assertLess(source.index("Isolated stack database marker mismatch"), source.index("SELECT pg_advisory_lock"))
        self.assertIn("stackMode || inject is not", source)

    def test_candidate_compose_is_separate(self):
        source = (ROOT / "tests/csharp-stack-candidate.compose.yaml").read_text()
        self.assertIn('condition: service_completed_successfully', source)
        self.assertIn('--migration-install-candidate', source)
        self.assertEqual(source.count("pull_policy: never"), 4)
        self.assertIn('"127.0.0.1::8080/tcp"', source)
        self.assertNotIn("external: true", source)
        self.assertNotIn("build:", source)
        self.assertNotIn("isolated-stack-ci", (ROOT / "compose.yaml").read_text())

    def test_legacy_upgrade_keeps_the_existing_database_and_checks_fixture(self):
        script = (ROOT / "scripts/csharp-stack-candidate-smoke.sh").read_text()
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("bash scripts/csharp-stack-candidate-smoke.sh legacy-upgrade", ci)
        for marker in ("legacy-upgrade", "schema-init.sh", "2.1.0", "db_container_before",
                       "stack stop api radius", "verify_initializer", "fingerprint",
                       "radcheck", "radusergroup", "radacct",
                       "Legacy Python to C# full-stack upgrade preserved"):
            self.assertIn(marker, script)
        self.assertEqual(script.count("stack down -v"), 1)

    def test_full_stack_gate_is_mandatory(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        script = (ROOT / "scripts/csharp-stack-candidate-smoke.sh").read_text()
        self.assertIn("bash scripts/csharp-stack-candidate-smoke.sh", ci)
        self.assertLess(ci.index("bash scripts/csharp-install-candidate-smoke.sh"), ci.index("bash scripts/csharp-stack-candidate-smoke.sh"))
        for marker in ("stack down -v --remove-orphans", "label=com.docker.compose.project", "Unmarked stack database accepted",
                       "RADIUS_UI_URL", "Access-Accept", "Access-Reject", "Accounting-Response",
                       "ledger_before", "C# isolated full-stack startup"):
            self.assertIn(marker, script)
