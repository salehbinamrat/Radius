#!/usr/bin/env python3
"""Stage 02B: migrations must be immutable, transactional, versioned and serialized."""
import ast
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "radius" / "migrate.py"


class MigrationLedgerContracts(unittest.TestCase):
    def test_sql_engine_and_ledger_contract(self):
        source = ENGINE.read_text(encoding="utf-8")
        ast.parse(source)
        for name in ("app_schema_migrations", "pg_advisory_lock",
                     "pg_advisory_unlock", "execution_id", "engine_version",
                     "applied_at", "filename", "sha256", "version",
                     "hashlib.sha256", "psycopg2", "BEGIN",
                     "COMMIT", "ROLLBACK", "ON_ERROR_STOP"):
            # The Python driver controls transactions; psql guards remain in bootstrap.
            self.assertIn(name, source + (ROOT / "radius/schema-init.sh").read_text(), name)
        self.assertIn("CREATE TABLE IF NOT EXISTS app_schema_migrations", source)
        self.assertIn("SELECT version, filename, sha256", source)
        self.assertIn("with connection:", source)
        self.assertIn("raise RuntimeError", source)
        self.assertNotIn("DROP TABLE", source.upper())
        for name in ("001_app.sql", "002_lab_accounts.sql", "003_accounting.sql", "004_nas_drafts.sql"):
            sql = (ROOT / "database" / name).read_text(encoding="utf-8")
            self.assertNotRegex(sql, r"(?im)^\\s*(?:DROP|TRUNCATE)\\b")

    def test_baseline_is_pinned_to_original_sql_files_and_requires_complete_objects(self):
        source = ENGINE.read_text(encoding="utf-8")
        for name in ("001_app.sql", "002_lab_accounts.sql", "003_accounting.sql", "004_nas_drafts.sql",
                     "app_plans", "app_lab_accounts", "app_lab_usage_snapshot",
                     "app_nas_drafts", "app_nas_draft_events", "idx_nas_drafts_created",
                     "radcheck", "radacct"):
            self.assertIn(name, source)
        self.assertIn("partial", source.lower())
        self.assertIn("checksum", source.lower())
        self.assertIn("out of order", source.lower())
        self.assertIn("MIGRATION_FAIL_AFTER_SQL_VERSION", source)
        self.assertIn("LAB_MIGRATION_TEST_MODE", source)

    def test_read_only_verification_cannot_bootstrap_and_errors_are_redacted(self):
        source = ENGINE.read_text(encoding="utf-8")
        self.assertIn('if "--verify-only" in sys.argv and not ledger_exists:', source)
        self.assertIn('except psycopg2.Error as exc:', source)
        self.assertIn("exc.pgcode", source)

    def test_compose_migrator_bundling_preserves_original_db_volume(self):
        dockerfile = (ROOT / "radius/Dockerfile").read_text()
        compose = (ROOT / "compose.yaml").read_text()
        init = (ROOT / "radius/schema-init.sh").read_text()
        self.assertIn("python3-psycopg2", dockerfile)
        self.assertIn("COPY migrate.py", dockerfile)
        self.assertIn("./database/001_app.sql:/opt/radius/001_app.sql:ro", compose)
        self.assertIn("postgres_data:/var/lib/postgresql/data", compose)
        self.assertIn("python3 /opt/radius/migrate.py", init)
        self.assertNotIn("docker compose down -v", init)

    def test_migration_smoke_has_retries_concurrency_and_drift_rejection(self):
        smoke = (ROOT / "scripts/migration-ledger-smoke.sh").read_text()
        for marker in ("trap cleanup EXIT", "createdb", "dropdb", "schema-init",
                       "MIGRATION_FAIL_AFTER_SQL_VERSION", "LAB_MIGRATION_TEST_MODE",
                       "sha256", "pg_catalog", "app_schema_migrations",
                       "wait", "preserved"):
            self.assertIn(marker, smoke)

    def test_migration_acceptance_in_ci_after_existing_smoke_and_before_recovery(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("bash scripts/migration-ledger-smoke.sh", ci)
        self.assertLess(ci.index("bash scripts/nas-drafts-smoke.sh"), ci.index("bash scripts/migration-ledger-smoke.sh"))
        self.assertLess(ci.index("bash scripts/migration-ledger-smoke.sh"), ci.index("bash scripts/lab-recovery-smoke.sh"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
