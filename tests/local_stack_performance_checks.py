"""Regression checks for the bounded installed performance baseline."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

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

    def test_rate_limit_windows_match_application_policy(self):
        program = (ROOT / "src/RadiusManager.Api/Program.cs").read_text()
        self.assertIn(f"PermitLimit = {perf.RATE_LIMIT}, Window = TimeSpan.FromMinutes(1), QueueLimit = 0", program)
        self.assertEqual(perf.WINDOW_SECONDS, 60)
        self.assertGreater(perf.COOLDOWN_SECONDS, perf.WINDOW_SECONDS)
        self.assertEqual([perf.window_plan(*stage) for stage in perf.STAGES],
                         [[16], [32], [32, 32]])
        for stage in perf.STAGES:
            for count in perf.window_plan(*stage):
                self.assertLess(count * len(perf.ENDPOINTS) + 2, perf.RATE_LIMIT)

    def test_highest_stage_preserves_all_samples_and_separate_windows(self):
        with patch.object(perf.time, "sleep") as wait, \
             patch.object(perf, "snapshot", return_value={}), \
             patch.object(perf, "request", return_value=0.01) as read:
            report = perf.run_stage("http://127.0.0.1:1234", "test-only", {}, "fixture", 16, 64)
        self.assertEqual(wait.call_count, 2)
        self.assertTrue(all(call.args == (61,) for call in wait.call_args_list))
        self.assertEqual(report["requests"], 192)
        self.assertEqual([window["requests"] for window in report["windows"]], [96, 96])
        self.assertEqual(read.call_count, 196)
        self.assertEqual(sum(call.kwargs.get("expected") == 401 for call in read.call_args_list), 4)
        self.assertEqual([v["count"] for v in report["endpoints"].values()], [64, 64, 64])
        self.assertIn("wall_requests_per_second", report)

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
