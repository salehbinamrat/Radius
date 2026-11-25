from pathlib import Path
import unittest

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
        for marker in ("--network none", "RADIUS_SLIM_IMAGE_ID", "local-fresh", "radius-slim-image-id.txt"):
            self.assertIn(marker, smoke)
        self.assertIn('for service in api radius db;', scan)
        self.assertIn('radius-slim.vulnerabilities.json', scan)
        self.assertIn('python3 scripts/verify-radius-slim-evidence.py "$reports"', scan)
        for marker in ("new < old", 'candidate["Size"] < legacy["Size"]',
                       "Legacy image layers retained", "Candidate package scan coverage differs",
                       '"production_approved": False'):
            self.assertIn(marker, evidence)
