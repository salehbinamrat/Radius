"""Actual SQL checks over TCP as the restricted runtime identity."""
import os
import sys
from pathlib import Path
import psycopg2

sys.path.insert(0,"/opt/radius")
from radius_secret_input import load_hex

def main():
    assert os.environ["RADIUS_DB_USER"]=="radius_runtime"
    host=os.environ.get("RADIUS_ROLE_PROBE_HOST","db")
    conn=psycopg2.connect(host=host,dbname="radius",user="radius_runtime",
                          password=load_hex("DB_PASSWORD"),connect_timeout=5)
    try:
        conn.autocommit=True
        with conn.cursor() as cur:
            cur.execute("""
            SELECT current_user,rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls,
                pg_has_role(current_user,'radius','MEMBER')
            FROM pg_roles WHERE rolname=current_user
            """)
            assert cur.fetchone()==("radius_runtime",False,False,False,False,False,False)
            cur.execute("SELECT count(*) FROM public.radcheck WHERE username='lab_00000000d2a1'")
            expected=0 if host=="restore-db" else 1
            assert cur.fetchone()==(expected,)
            for statement in (
                'SELECT "PasswordHash" FROM public."AspNetUsers"',
                "SELECT * FROM public.app_admin_audit_events",
                "SELECT * FROM public.app_lab_owner_transfers",
                "SELECT * FROM public.app_plans",
                "SELECT * FROM public.nas",
                "SELECT * FROM public.app_lab_usage_snapshot('lab_00000000d2a1')",
                "UPDATE public.radcheck SET value=value WHERE false",
                "DELETE FROM public.radacct WHERE false",
                "TRUNCATE public.radpostauth",
                "CREATE TABLE public.runtime_forbidden(id int)",
                "ALTER TABLE public.app_admin_audit_events DISABLE TRIGGER audit_append_only",
                "SET ROLE radius",
            ):
                try:
                    cur.execute(statement)
                except psycopg2.Error as exc:
                    assert exc.pgcode=="42501"
                else:
                    raise RuntimeError("Unexpectedly permitted SQL operation")
    finally:
        conn.close()
    print("Restricted RADIUS login and forbidden SQL operations PASS")

if __name__=="__main__":
    try:
        main()
    except Exception as exc:
        print("Restricted runtime SQL check failed ("+type(exc).__name__+")",file=sys.stderr)
        sys.exit(1)
