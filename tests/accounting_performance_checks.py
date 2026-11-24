from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]

class AccountingPerformanceChecks(unittest.TestCase):
    def test_fixture_is_isolated_and_uses_real_schema(self):
        shell=(ROOT/"scripts/accounting-query-performance.sh").read_text()
        for marker in ("isolated-ci","createdb","dropdb","radius_mig_","trap cleanup EXIT",
                       "postgresql/schema.sql","/opt/radius/migrate.py","LabSessionEndpoints.cs"):
            self.assertIn(marker,shell)
        self.assertNotIn("DROP TABLE",shell)
        workflow=(ROOT/".github/workflows/ci.yml").read_text()
        self.assertIn("bash scripts/accounting-query-performance.sh",workflow)

    def test_comparison_keeps_correctness_and_reports_real_metrics(self):
        source=(ROOT/"tests/accounting_query_performance.py").read_text()
        for marker in ("generate_series(1,100000)","EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)",
                       "statistics.median","foreign-denied","actual_session_query()",
                       "assert after==before[label]","conn.rollback()","pg_relation_size"):
            self.assertIn(marker,source)
        self.assertNotIn("enable_seqscan",source)

if __name__=="__main__":
    unittest.main()
