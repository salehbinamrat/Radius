"""Check SQL variable bindings and per-session accounting fixture isolation."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AccountingWireSqlChecks(unittest.TestCase):
    def setUp(self):
        self.script = (ROOT / "scripts/accounting-wire-smoke.sh").read_text()

    def test_every_psql_heredoc_variable_has_binding(self):
        blocks = re.findall(r"(docker compose exec -T db psql[^<]*?)<<'SQL'[^\n]*\n(.*?)\nSQL", self.script, re.S)
        self.assertEqual(len(blocks), 5)
        for command, sql in blocks:
            bindings = set(re.findall(r"-v\s+(\w+)=", command))
            variables = set(re.findall(r":'([a-z_]+)'", sql))
            self.assertTrue(variables <= bindings, variables - bindings)

    def test_cleanup_removes_all_synthetic_sessions_only(self):
        cleanup = self.script.split("cleanup() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("DELETE FROM radacct WHERE username=:'username';", cleanup)
        self.assertNotIn("acctsessionid", cleanup)
        self.assertNotIn("|| true", cleanup)
        self.assertIn('exit "$status"', cleanup)

    def test_assertion_is_scoped_to_current_session(self):
        body = self.script.split("assert_row() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("COUNT(*)=1", body)
        self.assertIn("WHERE username=:'username' AND acctsessionid=:'session_id'", body)
        self.assertIn("AND nasipaddress=CAST(:'nas_ip' AS inet);", body)
        self.assertIn('[[ "$result" == ACCT_WIRE_OK ]]', body)

    def test_final_verification_counts_both_sessions(self):
        body = self.script.split("# Both independent sessions", 1)[1].split("# Multi-NAS collision", 1)[0]
        self.assertIn("COUNT(*) = 2 AND COUNT(DISTINCT acctsessionid) = 2", body)
        self.assertIn("WHERE username=:'username';", body)
        self.assertNotIn("WHERE username=:'username' AND", body)

    def test_multi_nas_collision_keeps_same_session_id_and_distinct_addresses(self):
        body = self.script.split("# Multi-NAS collision", 1)[1]
        self.assertEqual(body.count("session_id=\"wire_"), 1)
        self.assertIn("nas_ip=10.255.70.21", body)
        self.assertIn("nas_ip=10.255.70.22", body)
        self.assertIn("COUNT(DISTINCT nasipaddress)=2", body)
        self.assertIn("COUNT(DISTINCT acctuniqueid)=2", body)
        self.assertIn("COUNT(*)=4 AND COUNT(DISTINCT acctuniqueid)=4", body)
        self.assertIn("SUM(acctinputoctets)=120 AND SUM(acctoutputoctets)=140", body)

    def test_nas_address_is_sent_and_bound_in_assertion(self):
        self.assertIn("printf 'NAS-IP-Address = %s\\n' \"$nas_ip\"", self.script)
        self.assertIn('-v nas_ip="$nas_ip"', self.script)
