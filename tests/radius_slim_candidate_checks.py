from pathlib import Path
import unittest
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

class RadiusSlimCandidateChecks(unittest.TestCase):
    def test_candidate_is_flattened_and_separate(self):
        source = (ROOT / "tests/radius-slim-candidate.Dockerfile").read_text()
        for marker in ("apk del py3-psycopg2 python3", "FROM scratch",
                       "COPY --from=trimmed / /", "mods-enabled", "rlm_python",
                       "ENTRYPOINT", "runtime-packages"):
            self.assertIn(marker, source)
        self.assertNotIn("radius-slim", (ROOT / "compose.yaml").read_text())
        self.assertEqual((ROOT / "tests/radius-slim-candidate.Dockerfile.dockerignore").read_text().splitlines()[0], "**")

    def test_candidate_has_real_protocol_and_independent_scan_gates(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        smoke = (ROOT / "scripts/radius-slim-candidate-smoke.sh").read_text()
        scan = (ROOT / "scripts/security-scan-ci.sh").read_text()
        evidence = (ROOT / "scripts/verify-radius-slim-evidence.py").read_text()
        self.assertLess(ci.index("bash scripts/radius-slim-candidate-smoke.sh"),
                        ci.index("bash scripts/security-scan-ci.sh"))
        for marker in ("radius-prepared-images", "RADIUS_SLIM_IMAGE_ID", "local-fresh", "radius-slim-image-id.txt", "source-prepared"):
            self.assertIn(marker, smoke)
        self.assertIn("bash scripts/csharp-local-installer-smoke.sh", smoke)
        self.assertIn('for service in api radius db;', scan)
        self.assertIn('radius-slim.vulnerabilities.json', scan)
        self.assertIn('python3 scripts/verify-radius-slim-evidence.py "$reports"', scan)
        for marker in ("new < old", 'candidate["Size"] < legacy["Size"]',
                       "Legacy image layers retained", "Candidate package scan coverage differs",
                       '"production_approved": False'):
            self.assertIn(marker, evidence)

    def test_preparation_requires_explicit_new_output_and_no_runtime(self):
        script = ROOT / "scripts/prepare-csharp-local-images.sh"
        source = script.read_text()
        for marker in ("local-lab-only", "unix:///var/run/docker.sock", "env -i",
                       "--network none", "verify_ids", "image-ids.txt",
                       "compatible-image-id.txt", "sha256sum", "C# local image preparation PASS",
                       "tests/postgres-alpine-remediation.Dockerfile",
                       "src/RadiusManager.Api/Dockerfile", "radius/Dockerfile"):
            self.assertIn(marker, source)
        for forbidden in ("compose up", "compose down", "volume rm", "python3 /"):
            self.assertNotIn(forbidden, source)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "new"
            result = subprocess.run(["bash", str(script), str(target)],
                                    env={**os.environ, "RADIUS_LOCAL_BUILD_ACK": ""},
                                    capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(target.exists())
            result = subprocess.run(["bash", str(script), directory],
                                    env={**os.environ, "RADIUS_LOCAL_BUILD_ACK": "local-lab-only"},
                                    capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_direct_source_preparation_drives_all_runtime_checks(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        smoke = (ROOT / "scripts/radius-slim-candidate-smoke.sh").read_text()
        for marker in ('bash scripts/prepare-csharp-local-images.sh "$RUNNER_TEMP/radius-prepared-images"',
                       'docker compose up -d --no-build --pull never',
                       'docker compose ps -aq "$role"',
                       'test "$(docker inspect --format \'{{.Image}}\' "$cid")" = "$expected"',
                       'Source-prepared image identity and compatibility startup PASS'):
            self.assertIn(marker, ci)
        self.assertNotIn("docker compose up -d --build", ci)
        self.assertLess(ci.index('bash scripts/prepare-csharp-local-images.sh'),
                        ci.index('docker compose up -d --no-build --pull never'))
        self.assertLess(ci.index('docker compose up -d --no-build --pull never'),
                        ci.index('bash scripts/radius-slim-candidate-smoke.sh'))
        self.assertNotIn("docker build", smoke)
        self.assertNotIn("bash scripts/prepare-csharp-local-images.sh", smoke)
        self.assertIn('"${prepared[0]}" == "$db" && "${prepared[1]}" == "$api"', smoke)
        self.assertIn('$(cat "$work/compatible-image-id.txt")', smoke)
        self.assertIn('sha256sum --check --strict --status SHA256SUMS', smoke)
