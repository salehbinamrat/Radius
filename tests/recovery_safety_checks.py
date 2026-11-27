#!/usr/bin/env python3
"""Stage 02A: fail-closed schema preflight and isolated encrypted recovery contracts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"

class RecoverySafetyChecks(unittest.TestCase):
    def test_existing_freeradius_schema_must_be_complete_before_skipping_init(self):
        init = (ROOT / "radius/schema-init.sh").read_text(encoding="utf-8")
        # Assert the fail-closed behavior, not the retired Bash variable.
        self.assertEqual(init.count("psql -X"), 1)
        self.assertIn("SET TRANSACTION ISOLATION LEVEL READ COMMITTED;", init)
        self.assertIn("IF existing NOT IN (0, 8) THEN", init)
        self.assertIn("RAISE EXCEPTION 'Refusing an incomplete FreeRADIUS schema", init)
        self.assertLess(init.index("pg_advisory_xact_lock("), init.index("SELECT count(*) INTO existing"))
        self.assertLess(init.index("IF existing NOT IN (0, 8) THEN"), init.index(r"\i :schema_file"))
        self.assertLess(init.index(r"\i :schema_file"), init.index("Official schema creation incomplete"))
        self.assertLess(init.index("Official schema creation incomplete"), init.index("\nBOOTSTRAP_SQL\n"))
        smoke = (SCRIPTS / "migration-ledger-smoke.sh").read_text()
        self.assertIn("refuse 'Refusing an incomplete FreeRADIUS schema (1 of 8 tables)", smoke)
        self.assertIn('test "$(official_count)" = 1', smoke)
        self.assertIn('test "$(official_count)" = 8', smoke)
        for name in ("radcheck", "radreply", "radgroupcheck", "radgroupreply",
                     "radusergroup", "radacct", "radpostauth", "nas"):
            self.assertIn(name, init)
        self.assertIn("app_plans", init)
        self.assertIn("ON_ERROR_STOP=1 -1", init)  # one transaction for the complete official bootstrap
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
        self.assertIn("image: radius-postgres-local:16.16-icu", restore_compose)
        self.assertIn("pull_policy: never", restore_compose)
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

    def test_populated_audit_restore_checks_content_not_just_schema(self):
        source = (SCRIPTS / "audit-recovery-smoke.sh").read_text()
        restore = (SCRIPTS / "lab-restore-drill.sh").read_text()
        fingerprint = (ROOT / "tests/audit_recovery_fingerprint.sql").read_text()
        https = (SCRIPTS / "admin-https-smoke.sh").read_text()
        self.assertIn('COMPOSE_PROJECT_NAME="$project" COMPOSE_FILE="$compose_file" bash scripts/lab-backup.sh', source)
        self.assertIn('LAB_AUDIT_RESTORE_SHA256="$before"', source)
        self.assertIn('LAB_AUDIT_RESTORE_SHA256="$wrong"', source)
        self.assertIn('Restored audit content fingerprint mismatch', source)
        self.assertIn('Restored audit content fingerprint mismatch', restore)
        self.assertIn('POPULATED_AUDIT_OK', source)
        for table in ('app_admin_audit_events','app_lab_owner_transfers','app_lab_account_owners'):
            self.assertIn(table, fingerprint)
        self.assertIn('REPEATABLE READ READ ONLY', fingerprint)
        self.assertLess(https.index('node tests/browser/https-live-status-smoke.mjs'),
                        https.index('bash scripts/audit-recovery-smoke.sh'))

    def test_recovery_reapplies_and_compares_roles_without_restoring_credentials(self):
        restore=(SCRIPTS/"lab-restore-drill.sh").read_text()
        roles=(SCRIPTS/"restore-runtime-roles-smoke.sh").read_text()
        source=(SCRIPTS/"audit-recovery-smoke.sh").read_text()
        self.assertIn('LAB_ROLE_RESTORE_SHA256="$roles_before"',source)
        self.assertIn('[[ "$(role_fingerprint)" == "$roles_before" ]]',source)
        self.assertLess(restore.index("Restored populated audit and ownership content fingerprint PASS"),
                        restore.index("bash scripts/restore-runtime-roles-smoke.sh"))
        for marker in ("^radiusrestore[a-f0-9]{8}$", "radius_runtime_grants.sql",
                       "api_runtime_grants.sql", "radius_bootstrap NOLOGIN",
                       "runtime_role_fingerprint.sql", "Restored role policy fingerprint mismatch",
                       "api_runtime_role_probe.py","radius_runtime_role_probe.py"):
            self.assertIn(marker,roles)
        self.assertIn("secrets.token_hex(24)",roles)
        self.assertNotIn("pg_dumpall",roles)
        self.assertNotIn("RADIUS_HTTPS_SECRET_DIR",roles)

    def test_ci_runs_recovery_only_after_existing_smoke_suite(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("bash scripts/lab-recovery-smoke.sh", ci)
        self.assertLess(ci.index("bash scripts/nas-drafts-smoke.sh"),
                        ci.index("bash scripts/lab-recovery-smoke.sh"))


    def test_recovery_replay_cannot_rebuild_or_recreate_dependencies(self):
        script = (SCRIPTS / "lab-recovery-smoke.sh").read_text(encoding="utf-8")
        replay = "docker compose run --rm --no-deps --pull never schema-init"
        self.assertIn(replay, script)
        self.assertNotIn("docker compose run --rm schema-init", script)
        self.assertLess(script.index("db_image_before="), script.index(replay))
        self.assertLess(script.index(replay), script.index('[[ "$(docker compose ps -q db)" == "$db_before" ]]'))
        for marker in ('db_tag_before=', 'schema_image_before=',
                       '[[ "$(docker inspect --format \'{{.Image}}\' "$db_before")" == "$db_image_before" ]]',
                       'Recovery replay preserved original database and initializer image identities PASS'):
            self.assertIn(marker, script)

if __name__ == "__main__":
    unittest.main(verbosity=2)
