"""Protect the candidate installation boundary and full recovery test."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CSharpInstallCandidateChecks(unittest.TestCase):
    def test_install_candidate_is_not_the_default_installer(self):
        executor = (ROOT / "src/RadiusManager.Api/MigrationExecutor.cs").read_text()
        program = (ROOT / "src/RadiusManager.Api/Program.cs").read_text()
        self.assertIn("--migration-install-candidate", program)
        self.assertIn("MigrationVerifier.IsIsolatedDatabase(name)", executor)
        self.assertIn('!= "isolated-ci"', executor)
        self.assertLess(executor.index("pg_advisory_lock"), executor.index("await BootstrapOfficial(conn"))
        self.assertIn("Official FreeRADIUS schema is partial", executor)
        self.assertIn("python3 /opt/radius/migrate.py", (ROOT / "radius/schema-init.sh").read_text())
        self.assertNotIn("--migration-install-candidate", (ROOT / "compose.yaml").read_text())

    def test_mandatory_install_and_restore_acceptance(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        path = "bash scripts/csharp-install-candidate-smoke.sh"
        self.assertIn(path, ci)
        self.assertLess(ci.index("bash scripts/migration-ledger-smoke.sh"), ci.index(path))
        self.assertLess(ci.index(path), ci.index("bash scripts/security-scan-ci.sh"))
        script = (ROOT / "scripts/csharp-install-candidate-smoke.sh").read_text()
        for marker in ("isolated-ci", "radius_mig_", "created+=(", "dropdb", "trap cleanup EXIT",
                       "schema.sql", "pg_dump", "--symmetric", "AES256", "--decrypt",
                       "--single-transaction", 'fingerprint "$restored"', "4294967297:8589934593:1:0",
                       "audit_append_only_verify.sql", "Official FreeRADIUS schema is partial"):
            self.assertIn(marker, script)
        self.assertNotIn("|| true", script)
