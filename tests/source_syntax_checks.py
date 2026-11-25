"""Exercise the actual syntax gate with good and bad files in a disposable tree."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SourceSyntaxChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ("scripts", "radius", "tests", "src/RadiusManager.Api/wwwroot/nested"):
            (self.root / directory).mkdir(parents=True)
        self.helper = self.root / "scripts/check-source-syntax.sh"
        shutil.copyfile(ROOT / "scripts/check-source-syntax.sh", self.helper)
        for name in ("scripts/a.sh", "scripts/z.sh", "radius/a.sh", "tests/a.sh"):
            (self.root / name).write_text("echo valid\n")
        self.module = self.root / "src/RadiusManager.Api/wwwroot/nested/a.mjs"
        self.module.write_text("export const value = 1;\n")

    def run_gate(self):
        return subprocess.run(["bash", str(self.helper)], cwd=self.root, capture_output=True, text=True)

    def test_good_sources_are_all_counted(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 5 shell sources and 1 frontend ES modules.", result.stdout)

    def test_old_gate_missed_invalid_second_shell_file(self):
        bad = self.root / "scripts/z.sh"
        bad.write_text("if then\n")
        old = subprocess.run(["bash", "-n", str(self.root / "scripts/a.sh"), str(bad)],
                             capture_output=True, text=True)
        self.assertEqual(old.returncode, 0)
        self.assertNotEqual(self.run_gate().returncode, 0)

    def test_invalid_shell_fixture_is_rejected(self):
        (self.root / "tests/a.sh").write_text("if then\n")
        self.assertNotEqual(self.run_gate().returncode, 0)

    def test_invalid_nested_module_is_rejected(self):
        self.module.write_text("const = ;\n")
        self.assertNotEqual(self.run_gate().returncode, 0)

    def test_missing_module_inventory_is_rejected(self):
        self.module.unlink()
        self.assertNotEqual(self.run_gate().returncode, 0)

    def test_missing_shell_group_is_rejected(self):
        (self.root / "tests/a.sh").unlink()
        self.assertNotEqual(self.run_gate().returncode, 0)
