"""Offline secret validation; no real credentials or Docker required."""
from pathlib import Path
import importlib.util
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("radius_secret_input", ROOT/"radius/radius_secret_input.py")
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class RadiusSecretInputChecks(unittest.TestCase):
    def test_sources_and_exact_bytes(self):
        value="a"*48
        self.assertEqual(module.load_hex("DB_PASSWORD",{"DB_PASSWORD":value}),value)
        with tempfile.TemporaryDirectory() as tmp:
            file=Path(tmp)/"secret"
            env={"DB_PASSWORD_FILE":str(file)}
            for suffix in (b"",b"\n",b"\r\n"):
                file.write_bytes(value.encode()+suffix)
                self.assertEqual(module.load_hex("DB_PASSWORD",env),value)
            for raw in (b"",b"a"*47,b"a"*49,b"a"*48+b"\n\n",b"a"*48+b"\x00",b"\xff"*48,b"a"*10000):
                file.write_bytes(raw)
                with self.assertRaises(RuntimeError): module.load_hex("DB_PASSWORD",env)
            with self.assertRaises(RuntimeError):
                module.load_hex("DB_PASSWORD",{**env,"DB_PASSWORD":value})
            file.unlink()
            with self.assertRaises(RuntimeError): module.load_hex("DB_PASSWORD",env)
        with self.assertRaises(RuntimeError): module.load_hex("DB_PASSWORD",{"DB_PASSWORD_FILE":"relative"})

    def test_wiring_and_real_fixture(self):
        for path in ("start.sh","schema-init.sh","health-probe.sh","migrate.py","Dockerfile"):
            self.assertIn("radius_secret_input",(ROOT/"radius"/path).read_text())
        self.assertNotIn("sed -i",(ROOT/"radius/start.sh").read_text())
        compose=(ROOT/"tests/admin-https.compose.yaml").read_text()
        self.assertIn("POSTGRES_PASSWORD_FILE:",compose)
        self.assertIn("DB_PASSWORD_FILE:",compose)
        self.assertNotIn("POSTGRES_PASSWORD:",compose)
        # The runtime-role wrapper now provisions the restricted SQL login
        # before invoking the original real file-secret/wire test.
        https=(ROOT/"scripts/admin-https-smoke.sh").read_text()
        role=(ROOT/"scripts/radius-runtime-role-smoke.sh").read_text()
        self.assertIn('bash scripts/radius-runtime-role-smoke.sh "$project" "$compose_file"',https)
        self.assertIn('bash scripts/radius-file-secret-smoke.sh "$project" "$compose_file"',role)
        self.assertLess(role.index('CREATE ROLE radius_runtime'),role.index('bash scripts/radius-file-secret-smoke.sh'))
        self.assertIn("RADIUS_SECRET_FILE=/run/radius-secrets/radius-secret",(ROOT/"scripts/radius-file-secret-smoke.sh").read_text())

if __name__=="__main__":
    unittest.main()
