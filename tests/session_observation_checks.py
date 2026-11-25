"""Protect the shared session observation timestamp and benchmark query contract."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SessionObservationChecks(unittest.TestCase):
    def test_api_uses_one_cutoff_before_query(self):
        src = (ROOT / "src/RadiusManager.Api/LabSessionEndpoints.cs").read_text()
        self.assertIn("COALESCE(a.acctupdatetime,a.acctstarttime) < @stale_before", src)
        self.assertIn('AddWithValue("stale_before", LabSessionRules.StaleCutoff(observedAt))', src)
        self.assertIn("LabSessionRules.Classify(stopped, lastUpdated ?? started, anomalous, observedAt)", src)
        self.assertLess(src.index("var observedAt ="), src.index("command.ExecuteReaderAsync"))
        self.assertEqual(src.count("DateTime.UtcNow"), 1)

    def test_performance_fixture_uses_same_cutoff_for_both_index_cases(self):
        src = (ROOT / "tests/accounting_query_performance.py").read_text()
        self.assertIn('.replace("@stale_before","%(stale_before)s")', src)
        self.assertIn('"stale_before":cutoff', src)
        self.assertIn('assert after==before[label]', src)
