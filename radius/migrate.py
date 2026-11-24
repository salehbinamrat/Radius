#!/usr/bin/env python3
"""Versioned additive PostgreSQL migrations for isolated Radius deployments.

The original 001..004 SQL files are immutable baselines. Database migration
ownership is independent of FreeRADIUS official schema ownership.
No production router/accounting/user data is changed by the migrator itself.
"""
from __future__ import annotations

import hashlib
import os
import re
import sys
import uuid
from pathlib import Path

import psycopg2
from radius_secret_input import load_hex

ENGINE_VERSION = "2.1.0"
SQL_DIR = Path("/opt/radius")
MIGRATIONS = (
    (1, "001_app.sql", ("public.app_plans",)),
    (2, "002_lab_accounts.sql", (
        "public.app_lab_accounts", "public.idx_app_lab_accounts_created",
    )),
    (3, "003_accounting.sql", (
        "procedure:public.app_lab_usage_snapshot(character varying)",)),
    (4, "004_nas_drafts.sql", (
        "public.app_nas_drafts", "public.app_nas_draft_events",
        "public.idx_nas_drafts_created",
    )),
    (5, "005_admin_identity.sql", (
        'public."AspNetUsers"', 'public."AspNetRoles"',
        'public."AspNetUserRoles"', 'public."AspNetUserClaims"',
        'public."AspNetRoleClaims"', 'public."AspNetUserLogins"',
        'public."AspNetUserTokens"',
        "public.app_admin_sessions", "public.app_admin_audit_events",
        "public.idx_admin_sessions_user_active", "public.idx_admin_audit_actor_time",
    )),
    (6, "006_reseller_ownership.sql", (
        "public.app_lab_account_owners", "public.idx_lab_account_owners_owner",
    )),
    (7, "007_ownership_transfers.sql", (
        "public.app_lab_owner_transfers", "public.idx_lab_owner_transfers_account",
        "column:public.app_lab_account_owners.ownership_version",
    )),
    (8, "008_audit_append_only.sql", (
        "procedure:public.app_reject_audit_mutation()",
        "trigger:public.app_admin_audit_events.audit_append_only",
        "trigger:public.app_lab_owner_transfers.ownership_history_append_only",
    )),
    (9, "009_accounting_read_indexes.sql", (
        "index:public.idx_app_radacct_recent",
        "index:public.idx_app_radacct_user_recent",
    )),
)
FREERADIUS_OBJECTS = (
    "radcheck", "radreply", "radgroupcheck", "radgroupreply",
    "radusergroup", "radacct", "radpostauth", "nas",
)
LOCK_NAMESPACE = 725134019
LOCK_ID = 20261124


def migration_files():
    files = []
    for version, name, objects in MIGRATIONS:
        path = SQL_DIR / name
        raw = path.read_bytes()
        data = raw.decode("utf-8")
        # Never execute destructive SQL as an automatic migration.
        # Only the exact trigger event clauses below are not executable TRUNCATE.
        # Continue scanning the complete remaining SQL for destructive commands.
        scan = re.sub(
            r"(?im)^BEFORE UPDATE OR DELETE OR TRUNCATE ON public\.(?:app_admin_audit_events|app_lab_owner_transfers)\s*$",
            "", data) if name == "008_audit_append_only.sql" else data
        if re.search(r"\b(?:DROP\s+(?:TABLE|SCHEMA|DATABASE)|TRUNCATE\b)\b",
                     scan, re.IGNORECASE):
            raise RuntimeError(f"Destructive SQL is prohibited in {name}")
        files.append((version, name, hashlib.sha256(raw).hexdigest(), data, objects))
    return files


# Canonical PostgreSQL 16 index definitions. Qualification of the table
# depends on search_path; normalize only that and whitespace/case.
ACCOUNTING_INDEX_DEFINITIONS = {
    "public.idx_app_radacct_recent":
        "CREATE INDEX idx_app_radacct_recent ON radacct USING btree (COALESCE(acctupdatetime, acctstarttime) DESC, radacctid DESC)",
    "public.idx_app_radacct_user_recent":
        "CREATE INDEX idx_app_radacct_user_recent ON radacct USING btree (username, COALESCE(acctupdatetime, acctstarttime) DESC, radacctid DESC)",
}

def normalized_index(definition):
    return re.sub(r"\s+", "", definition.lower().replace("on public.radacct ", "on radacct "))

def exists(cursor, object_name):
    if object_name.startswith("index:"):
        name = object_name[6:]
        cursor.execute("""
            SELECT c.relkind, i.indisvalid, i.indisready, i.indislive,
                   i.indrelid=to_regclass('public.radacct'), pg_get_indexdef(c.oid)
            FROM pg_class c LEFT JOIN pg_index i ON i.indexrelid=c.oid
            WHERE c.oid=to_regclass(%s)
        """, (name,))
        row = cursor.fetchone()
        if row is None:
            return False
        if row[:5] != ("i", True, True, True, True) or not row[5] or (
            normalized_index(row[5]) != normalized_index(ACCOUNTING_INDEX_DEFINITIONS[name])
        ):
            raise RuntimeError(f"Accounting index definition or validity mismatch: {name}")
        return True
    if object_name.startswith("trigger:"):
        schema, table, trigger = object_name[8:].split(".")
        cursor.execute("""
            SELECT 1 FROM pg_trigger t
            JOIN pg_class c ON c.oid=t.tgrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname=%s AND c.relname=%s AND t.tgname=%s
              AND NOT t.tgisinternal AND t.tgenabled='A' AND t.tgtype=58
              AND t.tgfoid=to_regprocedure('public.app_reject_audit_mutation()')
        """, (schema, table, trigger))
        return cursor.fetchone() is not None
    if object_name.startswith("column:"):
        schema, table, column = object_name[7:].split(".")
        cursor.execute("""
            SELECT 1 FROM information_schema.columns
            WHERE table_schema=%s AND table_name=%s AND column_name=%s
        """, (schema, table, column))
        return cursor.fetchone() is not None
    if object_name.startswith("procedure:"):
        cursor.execute("SELECT to_regprocedure(%s)", (object_name[10:],))
    else:
        cursor.execute("SELECT to_regclass(%s)", (object_name,))
    return cursor.fetchone()[0] is not None


def object_state(cursor, objects):
    present = [exists(cursor, item) for item in objects]
    if all(present):
        return "complete"
    if not any(present):
        return "absent"
    return "partial"


def check_official_schema(cursor):
    for table in FREERADIUS_OBJECTS:
        if not exists(cursor, f"public.{table}"):
            raise RuntimeError(f"FreeRADIUS schema incomplete: {table} absent")


def create_ledger_and_adopt_legacy(connection, files):
    """Bootstrap ledger atomically; trust only complete contiguous legacy objects."""
    with connection:
        with connection.cursor() as cursor:
            check_official_schema(cursor)
            states = [object_state(cursor, migration[4]) for migration in files]
            if states[0] != "complete":
                raise RuntimeError("app_plans missing/partial; refusing a synthetic baseline")
            if "partial" in states:
                raise RuntimeError("Existing application schema is partial; manual repair needed")
            seen_absent = False
            for state in states:
                if state == "absent":
                    seen_absent = True
                elif seen_absent:
                    raise RuntimeError("Legacy migration objects are out of order")
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS app_schema_migrations (
                    version integer PRIMARY KEY CHECK (version >= 1),
                    filename varchar(160) NOT NULL UNIQUE,
                    sha256 char(64) NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
                    applied_at timestamptz NOT NULL DEFAULT now(),
                    execution_id uuid NOT NULL,
                    engine_version varchar(40) NOT NULL
                )
            """)
            batch = uuid.uuid4()
            for (version, name, digest, _sql, _objects), state in zip(files, states):
                if state == "complete":
                    cursor.execute("""
                        INSERT INTO app_schema_migrations
                            (version, filename, sha256, execution_id, engine_version)
                        VALUES (%s, %s, %s, %s, %s)
                    """, (version, name, digest, str(batch), ENGINE_VERSION))
            print(f"Migrations: adopted {states.count('complete')} verified legacy version(s)")


def verified_prefix(connection, files):
    with connection:
        with connection.cursor() as cursor:
            check_official_schema(cursor)
            cursor.execute("""
                SELECT version, filename, sha256, applied_at, execution_id, engine_version
                FROM app_schema_migrations ORDER BY version
            """)
            rows = cursor.fetchall()
            known = {version: (name, digest) for version, name, digest, _, _ in files}
            versions = [row[0] for row in rows]
            if versions != list(range(1, len(rows) + 1)):
                raise RuntimeError("Migration ledger has missing versions or is out of order")
            if len(rows) > len(files):
                raise RuntimeError("Migration ledger has unrecognized future versions")
            for version, name, digest, *_ in rows:
                if version not in known or (name, digest) != known[version]:
                    raise RuntimeError(f"Migration checksum/filename mismatch at version {version}")
                current = object_state(cursor, files[version - 1][4])
                if current != "complete":
                    raise RuntimeError(f"Applied migration {version} has missing/partial objects")
            for version, name, digest, sql, objects in files[len(rows):]:
                state = object_state(cursor, objects)
                if state != "absent":
                    raise RuntimeError(
                        f"Unrecorded migration {version} has {state} objects; refusing replay"
                    )
            return len(rows)


def run():
    password = load_hex("DB_PASSWORD")
    dbname = os.environ.get("MIGRATION_DB_NAME", "radius")
    lab_mode = os.environ.get("LAB_MIGRATION_TEST_MODE") == "isolated-ci"
    if dbname != "radius" and not (
        lab_mode and re.fullmatch(r"radius_mig_[a-f0-9]{8}", dbname)
    ):
        raise RuntimeError("Non-default migration database is restricted to isolated CI")
    fail_version = os.environ.get("MIGRATION_FAIL_AFTER_SQL_VERSION")
    if fail_version and not (
        lab_mode and dbname != "radius" and fail_version in ("2", "3", "4", "6", "7", "8", "9")
    ):
        raise RuntimeError("Migration failure injection requires an isolated CI database")
    files = migration_files()
    connection = psycopg2.connect(
        host="db", user="radius", dbname=dbname, password=password,
        connect_timeout=10, application_name="radius-schema-migrator",
    )
    try:
        # One session advisory lock spans ALL version transactions. BEGIN/COMMIT
        # and ROLLBACK are handled by the psycopg2 "with connection:" blocks.
        with connection:
            with connection.cursor() as cursor:
                cursor.execute("SET LOCAL lock_timeout TO '60s'")
                cursor.execute("SELECT pg_advisory_lock(%s, %s)",
                               (LOCK_NAMESPACE, LOCK_ID))
        with connection:
            with connection.cursor() as cursor:
                ledger_exists = exists(cursor, "public.app_schema_migrations")
        if "--verify-only" in sys.argv and not ledger_exists:
            raise RuntimeError("Migration ledger missing; verify-only cannot create schema")
        if not ledger_exists:
            create_ledger_and_adopt_legacy(connection, files)

        applied = verified_prefix(connection, files)
        if "--verify-only" in sys.argv:
            if applied != len(files):
                raise RuntimeError("Migrations still pending; verification incomplete")
            print(f"Migrations: verified {applied} immutable versions")
            return
        for version, name, digest, sql, _objects in files[applied:]:
            with connection:
                with connection.cursor() as cursor:
                    cursor.execute(sql)
                    if version == 9 and object_state(cursor, _objects) != "complete":
                        raise RuntimeError("Accounting indexes failed verification before commit")
                    if fail_version == str(version):
                        raise RuntimeError(
                            f"CI failure injection after version {version} SQL; transaction rolled back"
                        )
                    cursor.execute("""
                        INSERT INTO app_schema_migrations
                            (version, filename, sha256, execution_id, engine_version)
                        VALUES (%s, %s, %s, %s, %s)
                    """, (version, name, digest, str(uuid.uuid4()), ENGINE_VERSION))
            print(f"Migrations: applied immutable version {version} transactionally")
        verified_prefix(connection, files)
        print(f"Migrations: all {len(files)} versions verified")
    finally:
        try:
            # Advisory lock is session-scoped and is also released on connection loss.
            connection.rollback()
            with connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT pg_advisory_unlock(%s, %s)",
                                   (LOCK_NAMESPACE, LOCK_ID))
        finally:
            connection.close()


if __name__ == "__main__":
    try:
        run()
    except psycopg2.Error as exc:
        # PostgreSQL errors can quote rejected SQL and values; emit SQLSTATE only.
        print(f"Database migration refused: SQLSTATE {exc.pgcode or 'unclassified'}", file=sys.stderr)
        sys.exit(1)
    except (OSError, UnicodeError, ValueError, RuntimeError) as exc:
        print(f"Database migration refused: {exc}", file=sys.stderr)
        sys.exit(1)
