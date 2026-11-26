"""Keep build contexts narrowly scoped and check the live runtime package in CI."""
from pathlib import Path
import unittest
import re

ROOT = Path(__file__).resolve().parents[1]


class RuntimePackageChecks(unittest.TestCase):
    def test_contexts_deny_by_default(self):
        for name in ("src/RadiusManager.Api/.dockerignore", "radius/.dockerignore",
                     "tests/postgres-alpine-remediation.Dockerfile.dockerignore"):
            rules = [line for line in (ROOT / name).read_text().splitlines()
                     if line and not line.startswith("#")]
            self.assertEqual(rules[0], "**", name)
            self.assertTrue(all(line.startswith("!") for line in rules[1:]), name)

    def test_radius_and_db_contexts_match_dockerfile_copy_sources(self):
        for directory, dockerfile, ignore in (
            ("radius", "Dockerfile", ".dockerignore"),
            ("tests", "postgres-alpine-remediation.Dockerfile",
             "postgres-alpine-remediation.Dockerfile.dockerignore"),
        ):
            root = ROOT / directory
            allowed = set(line[1:] for line in (root / ignore).read_text().splitlines()
                          if line.startswith("!"))
            sources = set()
            for line in (root / dockerfile).read_text().splitlines():
                if not line.startswith("COPY ") or "--from=" in line:
                    continue
                args = [word for word in line.split()[1:] if not word.startswith("--")]
                sources.update(args[:-1])
            self.assertTrue(sources)
            self.assertTrue(sources <= allowed, sources - allowed)
            self.assertTrue(all((root / name).is_file() for name in sources))

    def test_api_context_excludes_build_outputs_and_secrets(self):
        root = ROOT / "src/RadiusManager.Api"
        rules = (root / ".dockerignore").read_text().splitlines()
        for required in ("!*.cs", "!frontend/src/**/*.tsx", "!wwwroot/*.mjs",
                         "!wwwroot/*.d.mts", "!packages.lock.json"):
            self.assertIn(required, rules)
        for line in rules:
            if line.startswith("!"):
                self.assertNotRegex(line, r"(?i)node_modules|/bin/|/obj/|\.env|\.pfx|\.p12|\.key|modern/")

    def test_runtime_package_gate_is_mandatory(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("run: bash scripts/runtime-package-smoke.sh", ci)
        self.assertLess(ci.index("docker compose up -d --no-build --pull never"),
                        ci.index("run: bash scripts/runtime-package-smoke.sh"))
        self.assertLess(ci.index("run: bash scripts/runtime-package-smoke.sh"),
                        ci.index("run: bash scripts/security-scan-ci.sh"))
        gate = (ROOT / "scripts/runtime-package-smoke.sh").read_text()
        for marker in ("isolated-ci", 'dotnet --list-sdks', 'node npm python python3',
                       'wwwroot/modern/noc-react.mjs', 'docker image inspect', 'find /app'):
            self.assertIn(marker, gate)
        self.assertNotIn("|| true", gate)
