"""Offline secret validation; no real credentials or Docker required."""
from pathlib import Path
import importlib.util
import ipaddress
import runpy
import subprocess
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

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

    def test_shell_reader_matches_legacy_for_inline_and_file_sources(self):
        script = ROOT / "radius/radius_secret_input.sh"
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "secret"
            for name in ("DB_PASSWORD", "RADIUS_SECRET"):
                for raw in (b"a"*48, b"b"*48+b"\n", b"0"*48+b"\r\n", b"",
                            b"a"*47, b"a"*49, b"a"*48+b"\x00", b"a"*48+b"\n\n",
                            b"\xff"*48, b"A"*48, b"a"*10000, b"a"*24+b"\x00"+b"a"*24):
                    file.write_bytes(raw)
                    self.assert_shell_parity(script, name, {name+"_FILE": str(file)})
                self.assert_shell_parity(script, name, {name:"a"*48})
                self.assert_shell_parity(script, name, {name:"a"*48, name+"_FILE":str(file)})
                self.assert_shell_parity(script, name, {name+"_FILE":"relative"})
                self.assert_shell_parity(script, name, {name+"_FILE":str(file)+"-missing"})
                self.assert_shell_parity(script, name, {name+"_FILE":""})
                self.assert_shell_parity(script, name, {})

    def assert_shell_parity(self, script, name, env):
        result = subprocess.run(["bash", str(script), name],
                                env={"PATH": os.environ["PATH"], **env},
                                capture_output=True, timeout=5)
        try:
            expected = module.load_hex(name, env)
        except RuntimeError:
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"RADIUS secret or configuration input rejected\n")
        else:
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, (expected+"\n").encode())
            self.assertEqual(result.stderr, b"")

    @unittest.skipUnless(hasattr(os, "mkfifo"), "POSIX FIFO fixture")
    def test_readers_reject_nonregular_files_without_blocking(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            fifo_link = root / "fifo-link"
            fifo_link.symlink_to(fifo)
            regular = root / "secret"
            regular.write_bytes(b"a" * 48 + b"\r\n")
            regular_link = root / "regular-link"
            regular_link.symlink_to(regular)
            readers = (
                [sys.executable, str(ROOT / "radius/radius_secret_input.py")],
                ["bash", str(ROOT / "radius/radius_secret_input.sh")],
            )
            for reader in readers:
                for name in ("DB_PASSWORD", "RADIUS_SECRET"):
                    for path, valid in ((root, False), (fifo, False), (fifo_link, False),
                                        (regular, True), (regular_link, True)):
                        with self.subTest(reader=reader[0], name=name, path=path.name):
                            result = subprocess.run(
                                [*reader, name], env={"PATH": os.environ["PATH"],
                                                       name + "_FILE": str(path)},
                                capture_output=True, timeout=5)
                            self.assertEqual(result.returncode, 0 if valid else 1)
                            self.assertEqual(result.stdout, b"a" * 48 + b"\n" if valid else b"")
                            self.assertEqual(result.stderr, b"" if valid else
                                             b"RADIUS secret or configuration input rejected\n")

    def test_shell_ipv4_network_matches_legacy(self):
        script = ROOT / "radius/radius_secret_input.sh"
        cases = ["10.255.70.0/24","0.0.0.0/0","1.2.3.4","255.255.255.255/32",
                 "1.2.3.4/255.255.255.0","1.2.3.4/0.0.0.255",
                 "1.2.3.4/0.0.0.0","1.2.3.4/255.255.255.255",
                 "01.2.3.4/24","1.2.3.4/033","1.2.3.4/00032",
                 "1.2.3.4/255.0.255.0","1.2.3.4/","256.2.3.4/24",
                 "1.2.3.4/24/1","1.2.3.4;exit","::1/64",""]
        for cidr in cases:
            try:
                ipaddress.IPv4Network(cidr, strict=False)
                expected = True
            except ValueError:
                expected = False
            result = subprocess.run(["bash", "-c", 'source "$1"; valid_cidr "$2"',
                                     "bash", str(script), cidr], capture_output=True, timeout=5)
            self.assertEqual(result.returncode == 0, expected, cidr)

    def test_legacy_render_cli_delegates_to_single_shell_writer(self):
        legacy = ROOT / "radius/radius_secret_input.py"
        with patch.object(sys, "argv", [str(legacy), "render"]), \
             patch.object(os, "execv", side_effect=SystemExit(0)) as execute:
            with self.assertRaises(SystemExit) as result:
                runpy.run_path(str(legacy), run_name="__main__")
        self.assertEqual(result.exception.code, 0)
        execute.assert_called_once_with(
            "/bin/bash", ["bash", "/opt/radius/radius_secret_input.sh", "render"])
        self.assertFalse(hasattr(module, "render"))
        self.assertIn("bash /opt/radius/radius_secret_input.sh render",
                      (ROOT / "radius/start.sh").read_text())
        self.assertIn("def load_hex(", legacy.read_text())

    def test_legacy_render_exec_failure_is_redacted(self):
        legacy = ROOT / "radius/radius_secret_input.py"
        from io import StringIO
        with patch.object(sys, "argv", [str(legacy), "render"]), \
             patch.object(os, "execv", side_effect=OSError("private path")), \
             patch("sys.stderr", new_callable=StringIO) as error, \
             patch("sys.stdout", new_callable=StringIO) as output:
            with self.assertRaises(SystemExit) as result:
                runpy.run_path(str(legacy), run_name="__main__")
        self.assertEqual(result.exception.code, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(error.getvalue(), "RADIUS secret or configuration input rejected\n")

    def test_daemon_and_health_probe_do_not_invoke_python(self):
        for path in ("start.sh", "health-probe.sh"):
            source = (ROOT / "radius" / path).read_text()
            self.assertIn("bash /opt/radius/radius_secret_input.sh", source)
            self.assertNotIn("python3", source)
        docker = (ROOT / "radius/Dockerfile").read_text()
        self.assertIn("COPY radius_secret_input.sh /opt/radius/radius_secret_input.sh", docker)
        # Legacy migration remains available until the actual cutover.
        self.assertIn("python3 /opt/radius/migrate.py", (ROOT / "radius/schema-init.sh").read_text())

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

    def test_schema_initializer_shares_strict_shell_reader_before_sql(self):
        source = (ROOT / "radius/schema-init.sh").read_text()
        smoke = (ROOT / "scripts/migration-ledger-smoke.sh").read_text()
        reader = 'db_password=$(bash /opt/radius/radius_secret_input.sh DB_PASSWORD)'
        self.assertIn(reader, source)
        self.assertNotIn("python3 /opt/radius/radius_secret_input.py", source)
        self.assertLess(source.index("set +x"), source.index(reader))
        self.assertLess(source.index(reader), source.index("pgpass=$(mktemp)"))
        self.assertLess(source.index(reader), source.index("psql -X"))
        self.assertIn("python3 /opt/radius/migrate.py", source)
        for marker in ('--no-deps --pull never --entrypoint bash schema-init',
                       'for tool in psql python3', 'test ! -e "$work/unexpected-call"',
                       'Legacy schema initialization rejects invalid secret sources before SQL or migration PASS'):
            self.assertIn(marker, smoke)
        self.assertLess(smoke.index('Legacy schema initialization rejects invalid secret sources'),
                        smoke.index('setup_database "$db_one"'))

if __name__=="__main__":
    unittest.main()
