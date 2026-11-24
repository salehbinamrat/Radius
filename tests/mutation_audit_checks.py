"""Ensure every supported successful lab mutation is audited before its commit."""
from pathlib import Path
import unittest

API = Path(__file__).resolve().parents[1] / "src/RadiusManager.Api"

class MutationAuditContracts(unittest.TestCase):
    def test_mutation_audit_precedes_each_commit(self):
        for filename, actions in (
            ("PlanEndpoints.cs", ("PlanCreated", "PlanUpdated")),
            ("LabAccountEndpoints.cs", ("VoucherCreated", "VoucherDisabled")),
            ("NasDraftEndpoints.cs", ("NasDraftCreated", "NasDraftRetired")),
        ):
            source = (API / filename).read_text()
            commits = source.split("await tx.CommitAsync(ct);")
            self.assertEqual(len(commits), 3, filename)
            for block, action in zip(commits, actions):
                self.assertRegex(block, r"await LabMutationAudit\.AppendAsync\(conn, tx, ctx\.User, sessionMode, LabMutation\." + action + r", [^;]+, ct\);\s*$", filename)

    def test_audit_uses_same_transaction_and_fixed_metadata(self):
        source = (API / "LabMutationAudit.cs").read_text()
        self.assertIn("INSERT INTO app_admin_audit_events", source)
        self.assertIn('VALUES (@actor,@action,@kind,@subject,\'success\',@correlation)', source)
        self.assertIn('""", conn, tx)', source)
        self.assertIn("if (!sessionMode) return null;", source)
        self.assertIn("NpgsqlDbType.Text", source)
        self.assertNotIn("HttpContext", source)
        self.assertNotIn("Password", source)

if __name__ == "__main__":
    unittest.main()
