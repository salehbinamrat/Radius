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

    def test_bounded_progressive_stages(self):
        self.assertEqual(perf.STAGES, ((4, 16), (8, 32), (16, 64)))
        self.assertEqual(sum(n * len(perf.ENDPOINTS) for _, n in perf.STAGES), 336)
        values = [i / 1000 for i in range(1, 65)]
        self.assertEqual(perf.metrics(values, 64),
                         {"count": 64, "p50_ms": 32.0, "p95_ms": 61.0, "max_ms": 64.0})
        with self.assertRaises(ValueError):
            perf.metrics(values, 32)
        with self.assertRaisesRegex(ValueError, "Unapproved load stage"):
            perf.run_stage(None, None, None, None, 128, 1024)

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
