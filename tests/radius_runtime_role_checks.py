from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]

class RuntimeRoleContracts(unittest.TestCase):
    def test_role_is_scoped_to_explicit_fixture(self):
        source=(ROOT/"scripts/radius-runtime-role-smoke.sh").read_text()
        for value in ("isolated-ci","^radiushttps[a-f0-9]{8}$","NOSUPERUSER","NOCREATEDB",
                      "NOCREATEROLE","NOBYPASSRLS","SCRAM-SHA-256","RUNTIME_WIRE_OK"):
            self.assertIn(value,source)
        grants=(ROOT/"tests/radius_runtime_grants.sql").read_text()
        self.assertNotIn("ALL TABLES",grants)
        self.assertNotIn("ALL PRIVILEGES",grants)
        self.assertNotIn("GRANT DELETE",grants)
        self.assertIn("GRANT SELECT, INSERT, UPDATE ON public.radacct",grants)
        self.assertIn("GRANT INSERT ON public.radpostauth",grants)
        self.assertIn("REVOKE EXECUTE ON FUNCTION",grants)
    def test_one_off_service_has_no_owner_secret_or_listener(self):
        compose=(ROOT/"tests/admin-https.compose.yaml").read_text()
        runtime=compose.split("\n  radius-runtime:",1)[1].split("\n  api:",1)[0]
        self.assertIn('profiles: ["role-test"]',runtime)
        self.assertIn("RADIUS_DB_USER: radius_runtime",runtime)
        self.assertIn("runtime-db-password:",runtime)
        self.assertNotIn("/run/radius-secrets/db-password",runtime)
        self.assertNotIn("ports:",runtime)
        self.assertIn("radius-runtime -ec",(ROOT/"scripts/radius-file-secret-smoke.sh").read_text())
        self.assertIn("radius-runtime-role-smoke.sh",(ROOT/"scripts/admin-https-smoke.sh").read_text())

if __name__=="__main__":
    unittest.main()
