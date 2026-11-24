"""Real two-session password change race, only in disposable HTTPS CI."""
from concurrent.futures import ThreadPoolExecutor
from http.cookies import SimpleCookie
import http.client
import json
import os
import ssl
import sys
import threading

def main():
    assert os.environ.get("CI")=="true" and os.environ.get("LAB_HTTPS_TEST_ACK")=="isolated-ci"
    assert len(sys.argv)==2
    tls=ssl.create_default_context(cafile=sys.argv[1])
    origin="https://localhost:18443"
    def client():
        cookies={}
        def request(method,path,body=None,csrf=None):
            conn=http.client.HTTPSConnection("localhost",18443,context=tls,timeout=15)
            headers={"Origin":origin,"Sec-Fetch-Site":"same-origin",
                     "Cookie":"; ".join(f"{k}={v}" for k,v in cookies.items())}
            if body is not None:
                headers["Content-Type"]="application/json"
                body=json.dumps(body)
            if csrf: headers["X-CSRF-TOKEN"]=csrf
            try:
                conn.request(method,path,body=body,headers=headers)
                response=conn.getresponse()
                for k,v in response.getheaders():
                    if k.lower()=="set-cookie":
                        parsed=SimpleCookie()
                        parsed.load(v)
                        for name,m in parsed.items():
                            if name in ("__Host-RadiusAdmin","__Host-RadiusCsrf"):
                                cookies[name]=m.value
                raw=response.read()
                return response.status, json.loads(raw) if response.status==200 else None
            finally:
                conn.close()
        status,body=request("GET","/api/admin/auth/csrf")
        assert status==200
        status,_=request("POST","/api/admin/auth/login",
                         {"username":os.environ["LAB_ADMIN_USER"],"password":os.environ["LAB_ADMIN_PASSWORD"]},
                         body["requestToken"])
        assert status==200
        status,body=request("GET","/api/admin/auth/csrf")
        assert status==200
        return request,body["requestToken"]
    clients=[client(),client()]
    barrier=threading.Barrier(2,timeout=10)
    def change(entry):
        request,csrf=entry
        barrier.wait()
        status,_=request("POST","/api/admin/auth/change-password",
                         {"currentPassword":os.environ["LAB_ADMIN_PASSWORD"],
                          "newPassword":os.environ["LAB_ADMIN_PASSWORD_NEXT"]},csrf)
        return status
    with ThreadPoolExecutor(max_workers=2) as pool:
        statuses=sorted(pool.map(change,clients))
    assert statuses==[200,401],f"Unexpected race statuses: {statuses}"
    # The parent verifies all DB revocations before trying any stale cookie.
    print("Two concurrent password changes: one committed and one revoked-session denial PASS")

if __name__=="__main__":
    try:
        main()
    except Exception as exc:
        print("Password race failed ("+type(exc).__name__+")",file=sys.stderr)
        sys.exit(1)
