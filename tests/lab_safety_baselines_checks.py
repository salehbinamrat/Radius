#!/usr/bin/env python3
"""Stage 03N tests-first: prevent unsafe lab publication and establish safe read baselines."""
from pathlib import Path
import importlib.util
import unittest
import copy

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("validate_lab_compose",ROOT/"scripts/validate_lab_compose.py")
lab=importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

def config():
    return {"services": {
        "api": {"ports": [{"target": 8080, "published": "8080", "host_ip": "127.0.0.1", "protocol": "tcp"}]},
        "radius": {"ports": [
            {"target": 1812, "published": "1812", "host_ip": "127.0.0.1", "protocol": "udp"},
            {"target": 1813, "published": "1813", "host_ip": "127.0.0.1", "protocol": "udp"}]},
        "db": {},
        "schema-init": {},
    }}

class LabPreflightTests(unittest.TestCase):
    def test_known_good_local_services_are_allowed(self):
        self.assertEqual(lab.validate_loopback_configuration(config()),3)

    def test_public_ports_and_implicit_wildcard_are_forbidden(self):
        for host in ("0.0.0.0", "::", "", None, "10.0.0.1"):
            state=config()
            state["services"]["api"]["ports"][0]["host_ip"]=host
            with self.subTest(host=host):
                with self.assertRaises(ValueError):
                    lab.validate_loopback_configuration(state)

    def test_postgres_or_unrecognized_public_ports_cannot_be_exposed(self):
        state=config()
        state["services"]["db"]["ports"]=[{"target":5432,"published":"5432","host_ip":"127.0.0.1"}]
        with self.assertRaises(ValueError):
            lab.validate_loopback_configuration(state)
        state=config()
        state["services"]["extra"]={"ports":[{"target":9999,"published":"9999","host_ip":"127.0.0.1"}]}
        with self.assertRaises(ValueError):
            lab.validate_loopback_configuration(state)

    def test_required_udp_radius_ports_must_match_exactly(self):
        state=config()
        state["services"]["radius"]["ports"][0]["protocol"]="tcp"
        with self.assertRaises(ValueError):
            lab.validate_loopback_configuration(state)
        state=config()
        state["services"]["radius"]["ports"].pop()
        with self.assertRaises(ValueError):
            lab.validate_loopback_configuration(state)

    def test_scripts_require_explicit_lab_ack_and_never_echo_secrets(self):
        pre=(ROOT/"scripts/lab-deployment-preflight.sh").read_text()
        perf=(ROOT/"scripts/lab-read-performance.sh").read_text()
        self.assertIn("LAB_NETWORK_PREFLIGHT_ACK",pre)
        self.assertIn("RADIUS_PERF_TEST_ACK",perf)
        self.assertIn('API="http://127.0.0.1:8080/api"',perf)
        self.assertIn("--netrc-file",perf)
        self.assertIn("mktemp",perf)
        self.assertIn("time_total",perf)
        self.assertNotIn("curl -u",perf)
        self.assertNotIn("set -x",perf)
        for command in (" -X POST", " -X PUT", " -X DELETE", "docker compose down -v"):
            self.assertNotIn(command,pre+perf)

    def test_ci_runs_preflight_before_containers_and_baseline_inside_lab(self):
        ci=(ROOT/".github/workflows/ci.yml").read_text()
        self.assertIn("Loopback lab port preflight",ci)
        self.assertIn("Read-only API latency baseline",ci)
        self.assertIn("LAB_NETWORK_PREFLIGHT_ACK: isolated-lab",ci)
        self.assertIn("RADIUS_PERF_TEST_ACK: isolated-ci",ci)
        self.assertIn("needs: [dotnet-tests, config-tests]",ci)
        self.assertIn("Browser smoke: Chromium + React",ci)
        self.assertIn("scripts/admin-https-smoke.sh",ci)
if __name__=="__main__":
    unittest.main(verbosity=2)
