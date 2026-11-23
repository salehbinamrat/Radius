#!/usr/bin/env python3
"""Stage 02A: fail-closed schema preflight and isolated encrypted recovery contracts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"

class RecoverySafetyChecks(unittest.TestCase):
    def test_existing_freeradius_schema_must_be_complete_before_skipping_init(self):
        init = (ROOT / "radius/schema-init.sh").read_text(encoding="utf-8")
        self.assertIn("SCHEMA_TABLE_COUNT", init)
        self.assertIn("incomplete FreeRADIUS schema", init)
        for name in ("radcheck", "radreply", "radgroupcheck", "radgroupreply",
                     "radusergroup", "radacct", "radpostauth", "nas"):
            self.assertIn(name, init)
        self.assertIn("app_plans", init)
        self.assertIn("ON_ERROR_STOP=1 -1", init)  # one transaction per existing app SQL file
        self.assertIn("ON_ERROR_STOP=1", init)

    def test_backup_is_encrypted_and_never_overwrites_an_existing_snapshot(self):
        source = (SCRIPTS / "lab-backup.sh").read_text(encoding="utf-8")
        for marker in ("LAB_BACKUP_ACK", "BACKUP_PASSPHRASE_FILE", "pg_dump",
                       "--format=custom", "gpg", "--symmetric",
                       "--cipher-algo AES256", "--passphrase-file",
                       "sha256sum", 'ln "$partial" "$dest"'):
            self.assertIn(marker, source)
        self.assertIn('wc -c < "$BACKUP_PASSPHRASE_FILE"', source)
        self.assertNotIn("pg_dump -f", source)
        self.assertNotIn("docker compose down -v", source)

    def test_restore_is_on_new_isolated_postgres_never_on_primary_service(self):
        source = (SCRIPTS / "lab-restore-drill.sh").read_text(encoding="utf-8")
        for marker in ("LAB_BACKUP_ACK", "BACKUP_PASSPHRASE_FILE", "sha256sum -c",
                       "gpg", "--decrypt", "pg_restore", "restore_project",
                       'down -v --remove-orphans', "pg_catalog.pg_tables"):
            self.assertIn(marker, source)
        self.assertIn('docker compose -p "$restore_project" -f "$compose_file"', source)
        self.assertIn('wc -c < "$BACKUP_PASSPHRASE_FILE"', source)
        self.assertNotIn("docker compose exec -T db pg_restore", source)
        restore_compose = (ROOT / "tests/isolated-restore.compose.yaml").read_text(encoding="utf-8")
        self.assertIn("postgres:16-bookworm", restore_compose)
        self.assertIn("restore-db:", restore_compose)
        self.assertNotIn("postgres_data:", restore_compose)
        self.assertNotIn("ports:", restore_compose)

    def test_recovery_integration_uses_ephemeral_fixture_and_negative_cases(self):
        script = (SCRIPTS / "lab-recovery-smoke.sh").read_text(encoding="utf-8")
        self.assertIn("trap cleanup EXIT", script)
        self.assertIn("lab-backup.sh", script)
        self.assertIn("lab-restore-drill.sh", script)
        self.assertIn("tampered", script)
        self.assertIn("DELETE FROM app_plans", script)
        self.assertIn("DELETE FROM radcheck", script)

    def test_ci_runs_recovery_only_after_existing_smoke_suite(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("bash scripts/lab-recovery-smoke.sh", ci)
        self.assertLess(ci.index("bash scripts/nas-drafts-smoke.sh"),
                        ci.index("bash scripts/lab-recovery-smoke.sh"))

if __name__ == "__main__":
    unittest.main(verbosity=2)
