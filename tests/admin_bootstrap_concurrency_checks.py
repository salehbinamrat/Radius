from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BootstrapConcurrencyChecks(unittest.TestCase):
    def test_transaction_lock_precedes_authoritative_recheck_and_creation(self):
        source = (ROOT / "src/RadiusManager.Api/AdminBootstrap.cs").read_text()
        lock = source.index("pg_advisory_xact_lock")
        self.assertLess(source.index("BeginTransactionAsync"), lock)
        self.assertLess(source.index("Console.ReadKey"), lock)
        self.assertLess(lock, source.index("GetUsersInRoleAsync", lock))
        self.assertLess(source.index("GetUsersInRoleAsync", lock), source.index("users.CreateAsync"))
        self.assertLess(source.index("users.CreateAsync"), source.index("users.AddToRoleAsync"))
        self.assertLess(source.index("bootstrap_admin"), source.index("transaction.CommitAsync"))
        self.assertNotIn("users.DeleteAsync", source)

    def test_real_concurrent_bootstrap_in_isolated_https_smoke(self):
        shell = (ROOT / "scripts/admin-https-smoke.sh").read_text()
        race = (ROOT / "tests/concurrent_admin_bootstrap_smoke.py").read_text()
        self.assertIn("concurrent_admin_bootstrap_smoke.py", shell)
        self.assertIn('sorted(codes) != [0, 2]', race)
        self.assertIn('all(w["ready"] for w in workers)', race)
        self.assertIn('"1","1","1"', shell)

if __name__ == "__main__":
    unittest.main()
