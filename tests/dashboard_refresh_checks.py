from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class DashboardRefreshChecks(unittest.TestCase):
    def test_dashboard_read_coalescing_and_session_boundary(self):
        app=(ROOT/"src/RadiusManager.Api/wwwroot/app.mjs").read_text()
        self.assertIn("createRefreshCoordinator(8000)",app)
        self.assertNotIn("pendingRequest",app)
        self.assertIn("generation !== sessionGeneration || options.signal?.aborted",app)
        for path in ("/api/summary","/api/plans","/api/lab-accounts"):
            self.assertIn("call('"+path+"', { signal })",app)
        self.assertGreaterEqual(app.count("resetDashboardRefresh();"),3)
        self.assertGreaterEqual(app.count("await reload({ fresh: true })"),3)
        self.assertIn("if (!current() || signal.aborted)",app)
        self.assertIn("cache: 'no-store'",app)
    def test_coordinator_is_bounded_and_never_caches_completed_data(self):
        source=(ROOT/"src/RadiusManager.Api/wwwroot/refresh-coordinator.mjs").read_text()
        for marker in ("if (active && !fresh) return active.promise","controller.abort()",
                       "setTimeout","clearTimeout(timer)","if (isCurrent()) active = null"):
            self.assertIn(marker,source)
        self.assertNotIn("localStorage",source)
if __name__=="__main__":
    unittest.main()
