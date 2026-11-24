"""GitHub CI only: race two real interactive bootstrap processes."""
import os
import pty
import select
import subprocess
import sys
import time

if os.environ.get("CI") != "true" or os.environ.get("LAB_HTTPS_TEST_ACK") != "isolated-ci":
    raise SystemExit("Isolated HTTPS fixture required")
project, compose_file = sys.argv[1:]
if not project.startswith("radiushttps") or compose_file != "tests/admin-https.compose.yaml":
    raise SystemExit("Unexpected fixture")
workers = []
try:
    for label, suffix in (("primary", ""), ("contender", "_other")):
        master, slave = pty.openpty()
        cmd = ["docker", "compose", "-p", project, "-f", compose_file,
               "run", "--rm", "--no-deps", "-it", "--entrypoint", "dotnet", "api",
               "RadiusManager.Api.dll", "--bootstrap-admin"]
        try:
            proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                                    close_fds=True, env={**os.environ, "TERM":"xterm"})
        finally:
            os.close(slave)
        workers.append(dict(label=label, suffix=suffix, fd=master, proc=proc, seen=b"",
                            user=False, ready=False, sent=False, ended=False))
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        active = [w for w in workers if not w["ended"]]
        if not active:
            break
        ready, _, _ = select.select([w["fd"] for w in active], [], [], 1)
        for w in active:
            if w["fd"] not in ready:
                continue
            try:
                part = os.read(w["fd"], 8192)
            except OSError:
                part = b""
            if not part:
                w["ended"] = True
                continue
            w["seen"] = (w["seen"] + part)[-15000:]
            if not w["user"] and b"username" in w["seen"].lower():
                os.write(w["fd"], (os.environ["LAB_ADMIN_USER"]+w["suffix"]).encode()+b"\r")
                w["user"] = True
                w["seen"] = b""
            if w["user"] and not w["ready"] and b"password" in w["seen"].lower():
                w["ready"] = True
                w["seen"] = b""
        if all(w["ready"] for w in workers) and not any(w["sent"] for w in workers):
            for w in workers:
                os.write(w["fd"], os.environ["LAB_ADMIN_PASSWORD"].encode()+b"\r")
                w["sent"] = True
        if all(w["proc"].poll() is not None for w in workers):
            break
    if not all(w["sent"] for w in workers):
        raise RuntimeError("Both processes did not reach the barrier")
    codes = [w["proc"].wait(timeout=5) for w in workers]
    if sorted(codes) != [0, 2]:
        raise RuntimeError("Expected one success and one refusal")
    print(workers[codes.index(0)]["label"])
except Exception as exc:
    print("Concurrent bootstrap acceptance failed ("+type(exc).__name__+"); credentials not logged", file=sys.stderr)
    sys.exit(1)
finally:
    for w in workers:
        if w["proc"].poll() is None:
            w["proc"].kill()
            w["proc"].wait()
        os.close(w["fd"])
