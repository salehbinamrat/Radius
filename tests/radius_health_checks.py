from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class RadiusHealthChecks(unittest.TestCase):
    def test_probe_is_fixed_loopback_read_only_and_secret_is_not_in_argv(self):
        source = (ROOT / "radius/health-probe.sh").read_text()
        for item in ('127.0.0.1:1812 status', 'Message-Authenticator = 0x00',
                     '-S "$secret_file"', 'umask 077', 'mktemp', 'trap ', 'timeout 4s',
                     'Received Access-Accept'):
            self.assertIn(item, source)
        self.assertNotIn('User-Name', source)
        self.assertNotIn('User-Password', source)
        self.assertNotIn('set -x', source)
        self.assertNotIn('18121', source)

    def test_healthcheck_is_bounded_and_not_a_new_network_listener(self):
        compose = (ROOT / "compose.yaml").read_text()
        self.assertIn('test: ["CMD", "/usr/local/bin/radius-health-probe.sh"]', compose)
        self.assertIn('timeout: 5s', compose)
        self.assertNotIn('18121', compose)
        docker = (ROOT / "radius/Dockerfile").read_text()
        self.assertIn('COPY health-probe.sh /usr/local/bin/radius-health-probe.sh', docker)

    def test_real_ci_probe_checks_positive_and_negative_without_mutating_accounts(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        smoke = (ROOT / "scripts/radius-health-smoke.sh").read_text()
        self.assertIn('LAB_RADIUS_STATUS_ACK: isolated-ci', ci)
        self.assertIn('run: bash scripts/radius-health-smoke.sh', ci)
        self.assertIn('LAB_RADIUS_STATUS_ACK', smoke)
        self.assertIn('docker inspect', smoke)
        self.assertIn('RADIUS probe accepted an incorrect secret', smoke)
        self.assertNotIn('radcheck', smoke)
        self.assertNotIn('docker compose stop', smoke)

if __name__ == '__main__':
    unittest.main()
