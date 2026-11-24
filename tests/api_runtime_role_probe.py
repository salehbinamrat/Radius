"""Verify actual TCP login grants, with no credential output."""
from pathlib import Path
import sys
import psycopg2

def main():
    assert not Path("/run/radius-secrets/db-password").exists()
    assert not Path("/run/radius-secrets/bootstrap-db-password").exists()
    password=Path("/run/radius-secrets/api-db-password").read_text(encoding="ascii")
    conn=psycopg2.connect(host="db",dbname="radius",user="radius_api",password=password,connect_timeout=5)
    try:
        conn.autocommit=True
        with conn.cursor() as cur:
            cur.execute("""SELECT current_user,rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls,
                pg_has_role(current_user,'radius','MEMBER'),pg_has_role(current_user,'radius_bootstrap','MEMBER')
                FROM pg_roles WHERE rolname=current_user""")
            assert cur.fetchone()==("radius_api",False,False,False,False,False,False,False)
            for statement in (
                "SELECT count(*) FROM public.app_plans",
                "SELECT * FROM public.app_lab_usage_snapshot('lab_000000000000')",
                'SELECT count(*) FROM public."AspNetUsers"',
                "SELECT count(*) FROM public.app_admin_audit_events",
            ):
                cur.execute(statement)
                cur.fetchall()
            for statement in (
                'INSERT INTO public."AspNetUsers" ("Id") VALUES (\'forbidden\')',
                'INSERT INTO public."AspNetUserRoles" ("UserId","RoleId") VALUES (\'forbidden\',\'role-super-admin\')',
                'UPDATE public."AspNetRoles" SET "Name"="Name" WHERE false',
                'DELETE FROM public."AspNetUsers" WHERE false',
                "UPDATE public.app_admin_audit_events SET outcome=outcome WHERE false",
                "DELETE FROM public.app_lab_owner_transfers WHERE false",
                "TRUNCATE public.app_admin_audit_events",
                "ALTER TABLE public.app_admin_audit_events DISABLE TRIGGER audit_append_only",
                "UPDATE public.radacct SET acctsessiontime=0 WHERE false",
                "SELECT * FROM public.nas",
                "CREATE TABLE public.api_forbidden(id int)",
                "SET ROLE radius",
                "SET ROLE radius_bootstrap",
            ):
                try:
                    cur.execute(statement)
                except psycopg2.Error as exc:
                    assert exc.pgcode=="42501",exc.pgcode
                else:
                    raise RuntimeError("Unexpectedly permitted SQL operation")
    finally:
        conn.close()
    print("Restricted API SQL login and denied operations PASS")

if __name__=="__main__":
    try: main()
    except Exception as exc:
        print("Restricted API SQL probe failed ("+type(exc).__name__+")",file=sys.stderr)
        sys.exit(1)
