from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class ApiRoleContracts(unittest.TestCase):
    def test_separate_role_and_bootstrap_login(self):
        source=(ROOT/"tests/admin-https.compose.yaml").read_text()
        runtime=source.split("\n  api:",1)[1].split("\n  admin-bootstrap:",1)[0]
        bootstrap=source.split("\n  admin-bootstrap:",1)[1]
        self.assertIn("Username=radius_api",runtime)
        self.assertIn("Username=radius_bootstrap",bootstrap)
        self.assertNotIn("bootstrap-db-password",runtime)
        self.assertNotIn("/run/radius-secrets/db-password",runtime)
        self.assertNotIn("ports:",bootstrap)
        self.assertIn('"dotnet", "admin-bootstrap"',(ROOT/"tests/concurrent_admin_bootstrap_smoke.py").read_text())
        smoke=(ROOT/"scripts/admin-https-smoke.sh").read_text()
        self.assertLess(smoke.index("bash scripts/api-runtime-role-smoke.sh"),smoke.index("up -d --no-deps api"))
        self.assertIn("ALTER ROLE radius_bootstrap NOLOGIN",smoke)
        self.assertIn("usename='radius_api'",smoke)
    def test_explicit_grants_without_identity_enrollment_or_audit_mutation(self):
        grants=(ROOT/"tests/api_runtime_grants.sql").read_text()
        self.assertIn('GRANT SELECT, UPDATE ON public."AspNetUsers" TO radius_api;',grants)
        self.assertIn('GRANT SELECT, INSERT ON public.app_admin_audit_events TO radius_api;',grants)
        self.assertIn('GRANT SELECT, INSERT ON public."AspNetUserRoles" TO radius_bootstrap;',grants)
        self.assertNotIn("ALL PRIVILEGES",grants)
        self.assertNotIn("ALL TABLES",grants)
        self.assertNotIn("GRANT CREATE",grants)
        self.assertIn("SET ROLE radius_bootstrap",(ROOT/"tests/api_runtime_role_probe.py").read_text())
if __name__=="__main__":
    unittest.main()
