"""Two distinct real HTTPS reseller sessions, disposable fixture only."""
from concurrent.futures import ThreadPoolExecutor
import http.client
from http.cookies import SimpleCookie
import json
import os
import re
import ssl
import subprocess
import sys

def main():
    assert os.environ.get("CI") == "true" and os.environ.get("LAB_HTTPS_TEST_ACK") == "isolated-ci"
    cert, project, compose_file = sys.argv[1:]
    assert re.fullmatch(r"radiushttps[a-f0-9]{8}", project) and compose_file == "tests/admin-https.compose.yaml"
    # The ephemeral fixture already has a rotated Identity password hash.
    # Clone it inside the database only, not in Python, for two disposable test logins.
    sql = """
    BEGIN;
    INSERT INTO "AspNetUsers" ("Id","UserName","NormalizedUserName","PasswordHash","SecurityStamp","ConcurrencyStamp")
      SELECT v.id,v.name,upper(v.name),u."PasswordHash",gen_random_uuid()::text,gen_random_uuid()::text
      FROM "AspNetUsers" u JOIN "AspNetUserRoles" r ON r."UserId"=u."Id"
      CROSS JOIN (VALUES ('ci-owner-a','ci_owner_a'),('ci-owner-b','ci_owner_b')) v(id,name)
      WHERE r."RoleId"='role-super-admin';
    INSERT INTO "AspNetUserRoles" ("UserId","RoleId") VALUES ('ci-owner-a','role-reseller'),('ci-owner-b','role-reseller');
    INSERT INTO app_plans(id,name,upload_kbps,download_kbps)
      VALUES ('00600000-0000-4000-8000-000000000001','CI Ownership Test',256,1024);
    INSERT INTO app_lab_accounts(username,plan_id)
      SELECT v.name,'00600000-0000-4000-8000-000000000001'::uuid
      FROM (VALUES ('lab_0000000000a1'),('lab_0000000000b1'),('lab_0000000000c1')) v(name);
    INSERT INTO app_lab_account_owners(username,owner_user_id)
      VALUES ('lab_0000000000a1','ci-owner-a'),('lab_0000000000b1','ci-owner-b');
    COMMIT;
    """
    subprocess.run(["docker","compose","-p",project,"-f",compose_file,"exec","-T","db",
                    "psql","-X","-v","ON_ERROR_STOP=1","-U","radius","-d","radius"],
                   input=sql, text=True, capture_output=True, check=True, timeout=20)
    tls = ssl.create_default_context(cafile=cert)
    def session(username):
        cookies = {}
        def request(method, path, expected, body=None, csrf=None):
            conn = http.client.HTTPSConnection("localhost",18443,context=tls,timeout=10)
            headers = {"Origin":"https://localhost:18443","Sec-Fetch-Site":"same-origin",
                       "Cookie":"; ".join(f"{k}={v}" for k,v in cookies.items())}
            if body is not None:
                headers["Content-Type"]="application/json"
                body=json.dumps(body)
            if csrf: headers["X-CSRF-TOKEN"]=csrf
            try:
                conn.request(method,path,body=body,headers=headers)
                response=conn.getresponse()
                accepted=expected if isinstance(expected,tuple) else (expected,)
                assert response.status in accepted, f"Unexpected HTTP {response.status} for {method}"
                for k,v in response.getheaders():
                    if k.lower()=="set-cookie":
                        parsed=SimpleCookie()
                        parsed.load(v)
                        for name,morsel in parsed.items():
                            if name in ("__Host-RadiusAdmin","__Host-RadiusCsrf"):
                                cookies[name]=morsel.value
                data=response.read()
                if isinstance(expected,tuple): return response.status, None
                return json.loads(data) if expected==200 else None
            finally:
                conn.close()
        csrf=request("GET","/api/admin/auth/csrf",200)["requestToken"]
        request("POST","/api/admin/auth/login",200,{"username":username,"password":os.environ["LAB_ADMIN_PASSWORD_NEXT"]},csrf)
        return request
    for name, own, other in (("ci_owner_a","lab_0000000000a1","ci-owner-b"),
                             ("ci_owner_b","lab_0000000000b1","ci-owner-a")):
        request=session(name)
        assert request("GET","/api/admin/auth/me",200)["roles"] == ["reseller"]
        for path in ("/api/reseller/accounts","/api/reseller/accounts?ownerId="+other):
            result=request("GET",path,200)
            assert set(result)=={"accounts","hasMore","limit","labOnly"}
            assert [row["username"] for row in result["accounts"]]==[own]
            assert set(result["accounts"][0])=={"username","planName","active","createdAt","disabledAt"}
        request("GET","/api/lab-accounts",403)
        request("GET","/api/lab-accounts/lab_0000000000c1/usage",403)
        request("POST","/api/reseller/accounts",403,{})
        request("POST","/hubs/lab-status/negotiate?negotiateVersion=1",403)
        csrf=request("GET","/api/admin/auth/csrf",200)["requestToken"]
        request("POST","/api/admin/auth/logout",200,{},csrf)
    # Real administrator may assign only an unassigned active lab voucher.
    admin=session(os.environ["LAB_ADMIN_USER"])
    eligible=admin("GET","/api/ownership/resellers",200)
    assert {row["id"] for row in eligible["resellers"]}=={"ci-owner-a","ci-owner-b"}
    assert all(set(row)=={"id","username"} for row in eligible["resellers"])
    csrf=admin("GET","/api/admin/auth/csrf",200)["requestToken"]
    assign="/api/ownership/accounts/lab_0000000000c1/assign"
    admin("POST",assign,403,{"ownerId":"ci-owner-a"})
    admin("POST",assign,409,{"ownerId":"missing-owner"},csrf)
    admin("POST","/api/ownership/accounts/lab_0000000000d1/assign",404,{"ownerId":"ci-owner-a"},csrf)
    admin("POST","/api/ownership/accounts/lab_0000000000a1/assign",409,{"ownerId":"ci-owner-b"},csrf)
    reseller=session("ci_owner_a")
    reseller_csrf=reseller("GET","/api/admin/auth/csrf",200)["requestToken"]
    reseller("GET","/api/ownership/resellers",403)
    reseller("POST",assign,403,{"ownerId":"ci-owner-a"},reseller_csrf)
    # Separate authenticated admin sessions race to claim the same voucher.
    # The helper returns the actual status for this one race only.
    contenders=[(session(os.environ["LAB_ADMIN_USER"]), owner) for owner in ("ci-owner-a","ci-owner-b")]
    def compete(item):
        request,owner=item
        token=request("GET","/api/admin/auth/csrf",200)["requestToken"]
        result=request("POST",assign,(200,409),{"ownerId":owner},token)
        return result[0],owner
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(compete,contenders))
    assert sorted(status for status,_ in results)==[200,409]
    winner=next(owner for status,owner in results if status==200)
    for username,owner,original in (("ci_owner_a","ci-owner-a","lab_0000000000a1"),
                                    ("ci_owner_b","ci-owner-b","lab_0000000000b1")):
        request=session(username)
        expected={original}
        if owner==winner: expected.add("lab_0000000000c1")
        assert {r["username"] for r in request("GET","/api/reseller/accounts",200)["accounts"]}==expected
    # Exactly one successful event in the same committed transaction.
    check_sql="""
    SELECT count(*) FROM app_admin_audit_events
    WHERE action='voucher_owner_assigned' AND subject_kind='lab_account'
      AND subject_id='lab_0000000000c1' AND outcome='success'
      AND actor_user_id IN (SELECT "UserId" FROM "AspNetUserRoles" WHERE "RoleId"='role-super-admin');
    """
    result=subprocess.run(["docker","compose","-p",project,"-f",compose_file,"exec","-T","db",
                           "psql","-X","-At","-v","ON_ERROR_STOP=1","-U","radius","-d","radius"],
                          input=check_sql,text=True,capture_output=True,check=True,timeout=20)
    assert result.stdout.strip()=="1"
    # Exercise real transfer with separate sessions and a compare-and-swap revision.
    detail="/api/ownership/accounts/lab_0000000000a1"
    transfer=detail+"/transfer"
    before=admin("GET",detail,200)
    assert before["ownerId"]=="ci-owner-a" and before["revision"]==0
    payload={"expectedOwnerId":"ci-owner-a","expectedRevision":0,"newOwnerId":"ci-owner-b"}
    admin("POST",transfer,403,payload)
    reseller("POST",transfer,403,payload,reseller_csrf)
    reseller("GET",detail,403)
    admin("POST",transfer,400,{**payload,"newOwnerId":"ci-owner-a"},csrf)
    admin("POST",transfer,400,{"expectedOwnerId":"ci-owner-a","newOwnerId":"ci-owner-b"},csrf)
    admin("POST",transfer,409,{**payload,"newOwnerId":"missing-owner"},csrf)
    admin("POST",transfer,409,{**payload,"expectedRevision":1},csrf)
    race_sessions=[session(os.environ["LAB_ADMIN_USER"]) for _ in range(2)]
    def transfer_once(request):
        token=request("GET","/api/admin/auth/csrf",200)["requestToken"]
        return request("POST",transfer,(200,409),payload,token)[0]
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(transfer_once,race_sessions))==[200,409]
    assert admin("GET",detail,200)["revision"]==1
    owner_a=session("ci_owner_a")
    owner_b=session("ci_owner_b")
    assert "lab_0000000000a1" not in {r["username"] for r in owner_a("GET","/api/reseller/accounts",200)["accounts"]}
    assert "lab_0000000000a1" in {r["username"] for r in owner_b("GET","/api/reseller/accounts",200)["accounts"]}
    # Transfer back, then reject the original stale request even though owner A returned.
    result=admin("POST",transfer,200,{"expectedOwnerId":"ci-owner-b","expectedRevision":1,"newOwnerId":"ci-owner-a"},csrf)
    assert result["revision"]==2
    admin("POST",transfer,409,payload,csrf)
    assert admin("GET",detail,200)["ownerId"]=="ci-owner-a"
    journal_sql="""
    SELECT t.revision,t.previous_owner_id,t.new_owner_id
    FROM app_lab_ownership_transfers t JOIN app_admin_audit_events a ON a.id=t.audit_event_id
    WHERE t.username='lab_0000000000a1' AND a.action='voucher_owner_transferred'
      AND a.subject_id=t.username AND a.outcome='success'
      AND a.actor_user_id IN (SELECT "UserId" FROM "AspNetUserRoles" WHERE "RoleId"='role-super-admin')
    ORDER BY t.revision;
    """
    result=subprocess.run(["docker","compose","-p",project,"-f",compose_file,"exec","-T","db",
                           "psql","-X","-At","-v","ON_ERROR_STOP=1","-U","radius","-d","radius"],
                          input=journal_sql,text=True,capture_output=True,check=True,timeout=20)
    assert result.stdout.splitlines()==["1|ci-owner-a|ci-owner-b","2|ci-owner-b|ci-owner-a"]
    print("Ownership transfer: single concurrent winner, current owner isolation, stale ABA rejection, linked audit PASS")
    # Leave exactly one active unassigned and one disabled unassigned voucher
    # in this disposable database for the subsequent real Chromium acceptance.
    browser_sql="""
    INSERT INTO app_lab_accounts(username,plan_id)
    VALUES ('lab_0000000000e1','00600000-0000-4000-8000-000000000001');
    INSERT INTO app_lab_accounts(username,plan_id,active,disabled_at)
    VALUES ('lab_0000000000f1','00600000-0000-4000-8000-000000000001',false,now());
    """
    subprocess.run(["docker","compose","-p",project,"-f",compose_file,"exec","-T","db",
                    "psql","-X","-v","ON_ERROR_STOP=1","-U","radius","-d","radius"],
                   input=browser_sql,text=True,capture_output=True,check=True,timeout=20)
    options=admin("GET","/api/ownership/accounts",200)
    assert [row["username"] for row in options["accounts"]]==["lab_0000000000e1"]
    reseller("GET","/api/ownership/accounts",403)
    print("Two isolated reseller sessions: owner-only reads, forbidden writes, concurrent initial assignment and atomic audit PASS")

if __name__=="__main__":
    try:
        main()
    except Exception as exc:
        print("Reseller scope acceptance failed ("+type(exc).__name__+")",file=sys.stderr)
        sys.exit(1)
