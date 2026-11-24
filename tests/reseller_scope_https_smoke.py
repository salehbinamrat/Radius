"""Two distinct real HTTPS reseller sessions, disposable fixture only."""
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
                assert response.status == expected, f"Unexpected HTTP {response.status} for {method}"
                for k,v in response.getheaders():
                    if k.lower()=="set-cookie":
                        parsed=SimpleCookie()
                        parsed.load(v)
                        for name,morsel in parsed.items():
                            if name in ("__Host-RadiusAdmin","__Host-RadiusCsrf"):
                                cookies[name]=morsel.value
                data=response.read()
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
    print("Two isolated reseller sessions: own rows only, unassigned and shared resources denied PASS")

if __name__=="__main__":
    try:
        main()
    except Exception as exc:
        print("Reseller scope acceptance failed ("+type(exc).__name__+")",file=sys.stderr)
        sys.exit(1)
