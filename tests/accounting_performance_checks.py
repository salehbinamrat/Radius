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

    def test_concurrent_write_benchmark_preserves_correctness(self):
        source=(ROOT/"tests/accounting_query_performance.py").read_text()
        for marker in ("ThreadPoolExecutor(max_workers=6)","threading.Barrier(6",
                       "ids[number*250:(number+1)*250]","range(100)",
                       "conn.commit()","p95_ms","PERF CONCURRENT",
                       "assert cur.fetchone()==(1000,1000)",
                       "assert baseline[:4]==candidate[:4]",
                       "Foreign session escaped","lock_timeout=5000",
                       "compare_concurrent_writes(conn,db,query)"):
            self.assertIn(marker,source)
        self.assertLess(source.index('concurrent_workload(db,query,ids,"baseline")'),
                        source.index('concurrent_workload(db,query,ids,"candidate")'))

if __name__=="__main__":
    unittest.main()
