"""Regression checks for the bounded installed performance baseline."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("perf", ROOT / "tests/local_stack_performance.py")
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


class LocalStackPerformanceChecks(unittest.TestCase):
    def test_nearest_rank_percentiles_and_invalid_samples(self):
        samples = [n / 1000 for n in range(16, 0, -1)]
        self.assertEqual(perf.metrics(samples),
                         {"count": 16, "p50_ms": 8.0, "p95_ms": 16.0, "max_ms": 16.0})
        for bad in (samples[:-1], samples[:-1] + [float("nan")],
                    samples[:-1] + [-1], samples[:-1] + [6]):
            with self.assertRaises(ValueError):
                perf.metrics(bad)

    def test_read_only_local_gate_and_artifact(self):
        source = (ROOT / "tests/local_stack_performance.py").read_text()
        smoke = (ROOT / "scripts/csharp-local-installer-smoke.sh").read_text()
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertEqual(perf.WORKERS, 4)
        self.assertEqual(perf.PER_ENDPOINT * len(perf.ENDPOINTS), 48)
        for marker in ('method="GET"', "ProxyHandler({})", "NoRedirect",
                       'expected=401', 'docker("port"', '"--no-stream"',
                       "CSHARP_LOCAL_INSTALL_TEST_ACK", "resource_snapshots"):
            self.assertIn(marker, source)
        self.assertIn('python3 tests/local_stack_performance.py "$state"', smoke)
        self.assertIn("radius-installed-performance", ci)
