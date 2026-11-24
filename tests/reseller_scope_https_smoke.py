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
                return json.loads(data) if expected in (200,201) else None
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
    # Transfer requires a fresh ownership version, and cannot be performed by a reseller.
    path="/api/ownership/accounts/lab_0000000000a1"
    first=admin("GET",path+"/owner",200)
    assert first["ownerId"]=="ci-owner-a" and first["active"] and first["version"]
    payload={"expectedOwnerId":"ci-owner-a","expectedVersion":first["version"],"newOwnerId":"ci-owner-b"}
    reseller("GET",path+"/owner",403)
    reseller("POST",path+"/transfer",403,payload,reseller_csrf)
    admin("POST",path+"/transfer",403,payload)
    admin("POST",path+"/transfer",400,{**payload,"newOwnerId":"ci-owner-a"},csrf)
    admin("POST",path+"/transfer",409,{**payload,"newOwnerId":"missing-owner"},csrf)
    admin("POST","/api/ownership/accounts/lab_0000000000d1/transfer",404,payload,csrf)
    # Race the same expected version in two real admin sessions.
    def transfer(request):
        token=request("GET","/api/admin/auth/csrf",200)["requestToken"]
        return request("POST",path+"/transfer",(200,409),payload,token)[0]
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(transfer,[item[0] for item in contenders]))==[200,409]
    second=admin("GET",path+"/owner",200)
    assert second["ownerId"]=="ci-owner-b" and second["version"]!=first["version"]
    assert "lab_0000000000a1" not in {r["username"] for r in reseller("GET","/api/reseller/accounts",200)["accounts"]}
    other=session("ci_owner_b")
    assert "lab_0000000000a1" in {r["username"] for r in other("GET","/api/reseller/accounts",200)["accounts"]}
    reverse={"expectedOwnerId":"ci-owner-b","expectedVersion":second["version"],"newOwnerId":"ci-owner-a"}
    admin("POST",path+"/transfer",200,reverse,csrf)
    third=admin("GET",path+"/owner",200)
    assert third["ownerId"]=="ci-owner-a" and third["version"] not in (first["version"],second["version"])
    admin("POST",path+"/transfer",409,payload,csrf)
    check_transfers="""
    SELECT count(*) FROM app_lab_owner_transfers t
    JOIN app_admin_audit_events a ON a.correlation_id=t.id AND a.actor_user_id=t.actor_user_id
    WHERE t.username='lab_0000000000a1' AND a.action='voucher_owner_transferred'
      AND a.subject_id=t.username AND a.outcome='success';
    SELECT count(*) FROM app_lab_owner_transfers WHERE username='lab_0000000000a1';
    """
    result=subprocess.run(["docker","compose","-p",project,"-f",compose_file,"exec","-T","db",
                           "psql","-X","-At","-v","ON_ERROR_STOP=1","-U","radius","-d","radius"],
                          input=check_transfers,text=True,capture_output=True,check=True,timeout=20)
    assert result.stdout.splitlines()==["2","2"]
    history=admin("GET",path+"/history",200)
    assert set(history)=={"username","active","ownerId","version","transfers","hasMore","limit","labOnly"}
    assert history["ownerId"]=="ci-owner-a" and history["version"]==third["version"]
    assert not history["hasMore"] and history["limit"]==50 and history["labOnly"]
    assert [(r["previousOwnerId"],r["newOwnerId"]) for r in history["transfers"]]==[("ci-owner-b","ci-owner-a"),("ci-owner-a","ci-owner-b")]
    assert all(set(r)=={"id","previousOwnerId","newOwnerId","actorId","occurredAt"} for r in history["transfers"])
    reseller("GET",path+"/history",403)
    admin("GET","/api/ownership/accounts/lab_0000000000d1/history",404)
    # Verify actual populated history is protected, even against no-op updates.
    guard_sql=open("tests/audit_append_only_verify.sql",encoding="utf-8").read()
    subprocess.run(["docker","compose","-p",project,"-f",compose_file,"exec","-T","db",
                    "psql","-X","-v","ON_ERROR_STOP=1","-U","radius","-d","radius"],
                   input=guard_sql,text=True,capture_output=True,check=True,timeout=20)
    assert admin("GET",path+"/history",200)==history
    print("Version-bound transfer race, owner isolation, stale ABA rejection and correlated audit PASS")
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
    # Six successful named administrative mutations must produce exactly six
    # allowlisted events. Keep the created voucher disabled so it cannot affect
    # the existing ownership browser fixture.
    plan={"name":"CI Audit Plan","downloadKbps":1024,"uploadKbps":256}
    plan_id=admin("POST","/api/plans",201,plan,csrf)["id"]
    admin("PUT","/api/plans/"+plan_id,200,{**plan,"downloadKbps":2048},csrf)
    created=admin("POST","/api/lab-accounts",201,{"planId":plan_id},csrf)
    voucher=created["username"]
    del created
    admin("POST","/api/lab-accounts/"+voucher+"/disable",200,{},csrf)
    admin("POST","/api/lab-accounts/"+voucher+"/disable",404,{},csrf)
    draft={"name":"CI Audit Router","site":"CI Lab","vpnIp":"10.255.70.25"}
    nas_id=admin("POST","/api/nas-drafts",201,draft,csrf)["id"]
    admin("POST","/api/nas-drafts/"+nas_id+"/retire",200,{},csrf)
    admin("POST","/api/nas-drafts/"+nas_id+"/retire",404,{},csrf)
    # Inject a failure of the audit write in this disposable fixture only.
    # A NOT VALID constraint affects new rows without changing recorded history.
    db_cmd=["docker","compose","-p",project,"-f",compose_file,"exec","-T","db",
            "psql","-X","-At","-v","ON_ERROR_STOP=1","-U","radius","-d","radius"]
    def sql_check(query):
        return subprocess.run(db_cmd,input=query,text=True,capture_output=True,check=True,timeout=20).stdout
    sql_check("ALTER TABLE app_admin_audit_events ADD CONSTRAINT ci_reject_plan_audit CHECK (action <> 'plan_created') NOT VALID;")
    try:
        admin("POST","/api/plans",500,{**plan,"name":"CI Audit Rollback"},csrf)
        assert sql_check("SELECT count(*) FROM app_plans WHERE name='CI Audit Rollback';").strip()=="0"
    finally:
        sql_check("ALTER TABLE app_admin_audit_events DROP CONSTRAINT ci_reject_plan_audit;")
    assert re.fullmatch(r"[a-f0-9-]{36}",plan_id) and re.fullmatch(r"[a-f0-9-]{36}",nas_id)
    assert re.fullmatch(r"lab_[a-f0-9]{12}",voucher)
    audit=sql_check(f"""
        SELECT action,subject_kind,subject_id,outcome FROM app_admin_audit_events
        WHERE subject_id IN ('{plan_id}','{voucher}','{nas_id}')
          AND actor_user_id IN (SELECT "UserId" FROM "AspNetUserRoles" WHERE "RoleId"='role-super-admin')
        ORDER BY action;
        """).splitlines()
    assert audit==sorted([
        f"plan_created|plan|{plan_id}|success",f"plan_updated|plan|{plan_id}|success",
        f"voucher_created|lab_account|{voucher}|success",f"voucher_disabled|lab_account|{voucher}|success",
        f"nas_draft_created|nas_draft|{nas_id}|success",f"nas_draft_retired|nas_draft|{nas_id}|success"])
    audit_page=admin("GET","/api/admin-audit?action=plan_created&outcome=success",200)
    assert set(audit_page)=={"events","nextBefore","limit","labOnly"} and audit_page["labOnly"]
    assert audit_page["limit"]==50 and any(r["subjectId"]==plan_id for r in audit_page["events"])
    assert all(r["action"]=="plan_created" and r["outcome"]=="success" and isinstance(r["id"],str) for r in audit_page["events"])
    assert all(set(r)=={"id","actorId","action","subjectKind","subjectId","outcome","occurredAt","correlationId"} for r in audit_page["events"])
    actor=next(r["actorId"] for r in audit_page["events"] if r["subjectId"]==plan_id)
    from urllib.parse import quote
    filtered=admin("GET","/api/admin-audit?actor="+quote(actor,safe="")+"&action=plan_created",200)
    assert all(r["actorId"]==actor for r in filtered["events"])
    assert admin("GET","/api/admin-audit?from=2000-01-01&to=2000-01-02",200)["events"]==[]
    admin("GET","/api/admin-audit?outcome=unknown",400)
    admin("GET","/api/admin-audit?before=0",400)
    admin("GET","/api/admin-audit?from=2026-12-01&to=2026-01-01",400)
    reseller("GET","/api/admin-audit",403)
    admin("POST","/api/admin-audit",403,{},csrf)
    # Populate a known isolated historical day to exercise the 50+1 boundary,
    # cursor continuity, inclusive end date, and exclusion of the following day.
    sql_check("""
        INSERT INTO app_admin_audit_events(action,subject_kind,outcome,occurred_at,correlation_id)
        SELECT 'login_failure','admin','denied','2001-01-01 23:59:59+00'::timestamptz,gen_random_uuid()
        FROM generate_series(1,55);
        INSERT INTO app_admin_audit_events(action,subject_kind,outcome,occurred_at,correlation_id)
        VALUES ('login_failure','admin','denied','2001-01-02 00:00:00+00',gen_random_uuid());
    """)
    day="/api/admin-audit?action=login_failure&outcome=denied&from=2001-01-01&to=2001-01-01"
    first_page=admin("GET",day,200)
    assert len(first_page["events"])==50
    assert first_page["nextBefore"]==first_page["events"][-1]["id"]
    next_page=admin("GET",day+"&before="+first_page["nextBefore"],200)
    assert len(next_page["events"])==5 and next_page["nextBefore"] is None
    ids=[int(r["id"]) for r in first_page["events"]+next_page["events"]]
    assert len(set(ids))==55 and ids==sorted(ids,reverse=True)
    assert all(r["occurredAt"].startswith("2001-01-01T") for r in first_page["events"]+next_page["events"])
    print("Audit cursor paging, UTC day boundary and unique ordered IDs PASS")
    print("Named administrative audit coverage and rollback on audit failure PASS")
    print("Two isolated reseller sessions: owner-only reads, forbidden writes, concurrent initial assignment and atomic audit PASS")

if __name__=="__main__":
    try:
        main()
    except Exception as exc:
        print("Reseller scope acceptance failed ("+type(exc).__name__+")",file=sys.stderr)
        sys.exit(1)
