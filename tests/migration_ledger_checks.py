#!/usr/bin/env python3
"""Stage 02B: migrations must be immutable, transactional, versioned and serialized."""
import ast
import runpy
import sys
from types import ModuleType
from unittest.mock import MagicMock, patch
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

    def test_legacy_bootstrap_checks_baseline_before_schema_creation(self):
        source = (ROOT / "radius/schema-init.sh").read_text()
        smoke = (ROOT / "scripts/migration-ledger-smoke.sh").read_text()
        verifier = (ROOT / "src/RadiusManager.Api/MigrationVerifier.cs").read_text()
        engine = ENGINE.read_text()
        self.assertIn("LOCK_NAMESPACE = 725134019", engine)
        self.assertIn("LOCK_ID = 20261124", engine)
        self.assertIn("LockNamespace = 725134019", verifier)
        self.assertIn("LockId = 20261124", verifier)
        self.assertEqual(source.count("psql -X"), 1)
        self.assertIn("-v ON_ERROR_STOP=1 -1", source)
        self.assertLess(source.index("SET TRANSACTION ISOLATION LEVEL READ COMMITTED;"), source.index("pg_advisory_xact_lock"))
        self.assertLess(source.index("SET LOCAL lock_timeout"), source.index("pg_advisory_xact_lock(725134019, 20261124)"))
        self.assertLess(source.index("pg_advisory_xact_lock"), source.index("to_regclass('public.app_plans')"))
        self.assertLess(source.index("to_regclass('public.app_plans')"), source.index("SELECT count(*) INTO existing"))
        self.assertLess(source.index("IF existing NOT IN (0, 8)"), source.index(r"\i :schema_file"))
        self.assertLess(source.index("\nBOOTSTRAP_SQL\n"), source.index("python3 /opt/radius/migrate.py"))
        for marker in ("refuse 'Missing app_plans", "refuse 'Refusing an incomplete",
                       "test \"$waiting\" = 1", "test \"$(official_count)\" = 8",
                       "Legacy bootstrap baseline-first guard, shared lock and concurrent schema creation PASS"):
            self.assertIn(marker, smoke)

    def test_read_only_verification_cannot_bootstrap_and_errors_are_redacted(self):
        source = ENGINE.read_text(encoding="utf-8")
        self.assertIn("if verify_only and not ledger_exists:", source)
        self.assertIn("connection.set_session(readonly=True)", source)
        self.assertIn('except psycopg2.Error as exc:', source)
        self.assertIn("exc.pgcode", source)

    def load_engine_with_isolated_dependencies(self):
        driver = ModuleType("psycopg2")
        driver.connect = MagicMock()
        secret = ModuleType("radius_secret_input")
        secret.load_hex = MagicMock(return_value="a" * 48)
        with patch.dict(sys.modules, {"psycopg2": driver, "radius_secret_input": secret}):
            engine = runpy.run_path(str(ENGINE))
        return engine["run"], driver, secret

    def test_invalid_cli_modes_refuse_before_secrets_or_database(self):
        for args in (["--verify"], ["--help"], ["--verify-only", "--verify-only"],
                     ["--verify-only", "extra"], ["extra", "--verify-only"], [""]):
            with self.subTest(args=args):
                run, driver, secret = self.load_engine_with_isolated_dependencies()
                with patch.object(sys, "argv", [str(ENGINE), *args]):
                    with self.assertRaisesRegex(RuntimeError, "^Unsupported migration arguments$"):
                        run()
                secret.load_hex.assert_not_called()
                driver.connect.assert_not_called()

    def test_verify_only_enforces_readonly_before_any_sql(self):
        run, driver, _ = self.load_engine_with_isolated_dependencies()
        conn = driver.connect.return_value
        cursor = conn.cursor.return_value.__enter__.return_value
        files = [(1, "001_app.sql", "digest", "fixture SQL", ("fixture",))]
        adopt = MagicMock()
        with patch.dict(run.__globals__, {"migration_files": MagicMock(return_value=files),
                                           "exists": MagicMock(return_value=True),
                                           "verified_prefix": MagicMock(return_value=1),
                                           "create_ledger_and_adopt_legacy": adopt}), \
             patch.dict("os.environ", {}, clear=True), \
             patch.object(sys, "argv", [str(ENGINE), "--verify-only"]), \
             patch("builtins.print"):
            run()
        conn.set_session.assert_called_once_with(readonly=True)
        self.assertEqual(conn.method_calls[0][0], "set_session")
        adopt.assert_not_called()
        statements = [call.args[0] for call in cursor.execute.call_args_list]
        self.assertEqual(len(statements), 3)
        self.assertIn("pg_advisory_lock", statements[1])
        self.assertIn("pg_advisory_unlock", statements[2])
        self.assertNotIn("fixture SQL", statements)
        conn.close.assert_called_once()

    def test_compose_migrator_bundling_preserves_original_db_volume(self):
        dockerfile = (ROOT / "radius/Dockerfile").read_text()
        compose = (ROOT / "compose.yaml").read_text()
        init = (ROOT / "radius/schema-init.sh").read_text()
        # Alpine names the same PostgreSQL driver py3-psycopg2.
        # Verify the final runtime stage rather than the build dependencies.
        runtime = dockerfile.rsplit("\nFROM ", 1)[-1]
        self.assertRegex(runtime, r"(?m)^FROM |^alpine:3\.24\.4@sha256:[a-f0-9]{64}")
        self.assertRegex(runtime, r"\bpy3-psycopg2\b")
        self.assertIn("python3 -c 'import psycopg2'", runtime)
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

    def test_accounting_index_migration_is_additive_and_verified(self):
        sql=(ROOT/"database/009_accounting_read_indexes.sql").read_text()
        self.assertEqual(sql.count("CREATE INDEX"),2)
        self.assertIn("SET LOCAL lock_timeout",sql)
        self.assertIn("SET LOCAL statement_timeout",sql)
        self.assertNotIn("IF NOT EXISTS",sql)
        engine=ENGINE.read_text()
        for marker in ("009_accounting_read_indexes.sql","indisvalid","indisready","indislive",
                       "pg_get_indexdef","Accounting index definition or validity mismatch"):
            self.assertIn(marker,engine)
        for path in ("compose.yaml","tests/admin-https.compose.yaml"):
            self.assertIn("009_accounting_read_indexes.sql:/opt/radius/009_accounting_read_indexes.sql:ro",
                          (ROOT/path).read_text())
        smoke=(ROOT/"scripts/migration-ledger-smoke.sh").read_text()
        self.assertIn("MIGRATION_FAIL_AFTER_SQL_VERSION=9",smoke)
        self.assertIn("migration9-fixture",smoke)
        self.assertIn("Incorrect accounting index definition was accepted",smoke)
        self.assertIn("accounting_indexes_verify.sql",(ROOT/"scripts/lab-restore-drill.sh").read_text())
        self.assertIn("remove_migrated_indexes_for_baseline",(ROOT/"tests/accounting_query_performance.py").read_text())

    def test_migration_acceptance_in_ci_after_existing_smoke_and_before_recovery(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("bash scripts/migration-ledger-smoke.sh", ci)
        self.assertLess(ci.index("bash scripts/nas-drafts-smoke.sh"), ci.index("bash scripts/migration-ledger-smoke.sh"))
        self.assertLess(ci.index("bash scripts/migration-ledger-smoke.sh"), ci.index("bash scripts/lab-recovery-smoke.sh"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
