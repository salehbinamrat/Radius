"""Require the C# HTTPS candidate without weakening legacy or role acceptance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CSharpHttpsInitializerChecks(unittest.TestCase):
    def test_separate_owner_only_initializer(self):
        source = (ROOT / "tests/admin-https.compose.yaml").read_text()
        init = source.split("  csharp-schema-init:\n", 1)[1].split("  # Explicit one-off", 1)[0]
        self.assertIn('profiles: ["csharp-init-test"]', init)
        self.assertIn("image: radius-stage3-ci-api:latest", init)
        self.assertIn("pull_policy: never", init)
        self.assertIn("--migration-install-candidate", init)
        self.assertIn("RADIUS_DB_PASSWORD_FILE: /run/radius-secrets/db-password", init)
        self.assertIn(":/run/radius-secrets/db-password:ro", init)
        self.assertNotIn("Password=", init)
        self.assertNotIn("ports:", init)
        self.assertIn("Username=radius_api", source)
        self.assertIn("RADIUS_DB_USER: radius_runtime", source)
        self.assertIn("Username=radius_bootstrap", source)

    def test_initializer_precedes_roles_and_requires_marker(self):
        script = (ROOT / "scripts/admin-https-smoke.sh").read_text()
        for marker in ("Unmarked HTTPS database accepted", "Isolated stack database marker mismatch",
                       "COMMENT ON DATABASE radius", "wait csharp-schema-init", "3.0.0-csharp-lab",
                       "ps -aq schema-init", "C# HTTPS full acceptance"):
            self.assertIn(marker, script)
        self.assertLess(script.index("wait csharp-schema-init"), script.index("bash scripts/api-runtime-role-smoke.sh"))
        self.assertLess(script.index("bash scripts/audit-recovery-smoke.sh"), script.index("C# HTTPS full acceptance"))
        executor = (ROOT / "src/RadiusManager.Api/MigrationExecutor.cs").read_text()
        self.assertIn("radius(?:csharp|https)", executor)
        self.assertIn('actual != "radius-csharp-ci:" + stack', executor)

    def test_resolved_compose_checks_all_profiles_and_cleanup_is_mandatory(self):
        script = (ROOT / "scripts/admin-https-smoke.sh").read_text()
        self.assertIn("--profile '*' config --format json", script)
        self.assertIn('assert len(ports)==1', script)
        self.assertIn('port["host_ip"]=="127.0.0.1"', script)
        self.assertIn('assert set(services)==', script)
        self.assertIn('assert not any(s.get("network_mode")', script)
        self.assertIn("--profile '*' down -v --remove-orphans", script)
        self.assertIn("Isolated HTTPS stack cleanup failed", script)
        self.assertIn("--profile csharp-init-test wait csharp-schema-init", script)

    def test_both_https_paths_remain_mandatory(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("run: bash scripts/admin-https-smoke.sh\n", ci)
        self.assertIn("run: bash scripts/admin-https-smoke.sh csharp", ci)
        self.assertLess(ci.index("run: bash scripts/admin-https-smoke.sh csharp"),
                        ci.index("run: bash scripts/security-scan-ci.sh"))
