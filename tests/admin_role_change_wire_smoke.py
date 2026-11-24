"""Isolated HTTPS role-change acceptance, using a real active SignalR stream."""
import os
import re
import subprocess
import sys
import time
from signalr_https_wire_smoke import Fixture, Closed, require

def main():
    require(os.environ.get("CI") == "true" and os.environ.get("LAB_HTTPS_TEST_ACK") == "isolated-ci",
            "Isolated fixture required")
    cert, jar, project, compose_file = sys.argv[1:]
    require(re.fullmatch(r"radiushttps[a-f0-9]{8}", project) and compose_file == "tests/admin-https.compose.yaml",
            "Unexpected fixture")
    def change(old, new):
        # Role IDs are fixed fixture constants, never supplied by an external client.
        cmd = ["docker","compose","-p",project,"-f",compose_file,"exec","-T","db",
               "psql","-U","radius","-d","radius","-At","-v","ON_ERROR_STOP=1","-c",
               f"""UPDATE "AspNetUserRoles" SET "RoleId" = '{new}' WHERE "RoleId" = '{old}';"""]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=True)
        require(result.stdout.strip() == "UPDATE 1", "Expected exactly one fixture role update")
    fixture = Fixture(cert, jar)
    with fixture.connect() as wire:
        wire.watch("role-change")
        wire.sample("role-change")
        change("role-super-admin", "role-auditor")
        try:
            deadline = time.monotonic() + 16
            try:
                while True:
                    message = wire.receive(max(0, deadline-time.monotonic()))
                    if message.get("type") == 7:
                        break
                    if message.get("type") == 3 and message.get("invocationId") == "role-change":
                        continue
                    require(message.get("type") == 6, "Data delivered after role membership change")
            except (Closed, ConnectionResetError):
                pass
        finally:
            change("role-auditor", "role-super-admin")
    print("Live role change stopped stream and restored fixture role; old cookie must remain revoked")

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Role-change acceptance failed (" + type(exc).__name__ + ")", file=sys.stderr)
        sys.exit(1)
