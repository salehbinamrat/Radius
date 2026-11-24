"""Strict single-source hexadecimal lab secrets; no values or paths in errors."""
import os
import re
import sys
from pathlib import Path

NAMES = ("DB_PASSWORD", "RADIUS_SECRET")

def load_hex(name, env=None):
    if name not in NAMES:
        raise RuntimeError("Unknown secret name")
    env = os.environ if env is None else env
    inline = env.get(name, "")
    file = env.get(name + "_FILE")
    if file is not None:
        if inline or not Path(file).is_absolute():
            raise RuntimeError("Invalid or conflicting " + name + " source")
        try:
            with open(file, "rb") as stream:
                raw = stream.read(51)
            if not re.fullmatch(rb"[a-f0-9]{48}(?:\r?\n)?", raw):
                raise ValueError()
            return raw[:48].decode("ascii")
        except (OSError, ValueError) as exc:
            raise RuntimeError("Missing or invalid " + name + " file") from None
    if not re.fullmatch(r"[a-f0-9]{48}", inline):
        raise RuntimeError("Missing or invalid " + name)
    return inline

def render():
    import grp
    import ipaddress
    import tempfile
    db = load_hex("DB_PASSWORD")
    secret = load_hex("RADIUS_SECRET")
    user = os.environ.get("RADIUS_DB_USER", "radius")
    if user not in ("radius", "radius_runtime"):
        raise RuntimeError("Invalid RADIUS_DB_USER")
    cidr = os.environ.get("RADIUS_CLIENT_CIDR", "")
    try:
        if not re.fullmatch(r"[0-9./]+", cidr):
            raise ValueError()
        ipaddress.IPv4Network(cidr, strict=False)
    except ValueError:
        raise RuntimeError("Invalid RADIUS_CLIENT_CIDR") from None
    gid = grp.getgrnam("freerad").gr_gid
    for template, dest, replacements in (
        ("sql.template", "/etc/freeradius/3.0/mods-available/sql", {"__DB_PASSWORD__": db, "__DB_USER__": user}),
        ("clients.template", "/etc/freeradius/3.0/clients.conf",
         {"__RADIUS_SECRET__": secret, "__RADIUS_CLIENT_CIDR__": cidr}),
    ):
        content = (Path("/opt/radius") / template).read_text(encoding="utf-8")
        for key, value in replacements.items():
            if key not in content:
                raise RuntimeError("Invalid RADIUS configuration template")
            content = content.replace(key, value)
        # Create private temporary file before writing, then publish atomically.
        path = Path(dest)
        fd, temp = tempfile.mkstemp(prefix=".radius-config-", dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                os.fchown(out.fileno(), 0, gid)
                os.fchmod(out.fileno(), 0o640)
                out.write(content)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise RuntimeError("Expected secret name or render")
        if sys.argv[1] == "render":
            render()
        else:
            print(load_hex(sys.argv[1]))
    except (RuntimeError, OSError, ValueError, KeyError):
        print("RADIUS secret or configuration input rejected", file=sys.stderr)
        sys.exit(1)
