"""Strict single-source hexadecimal lab secrets; no values or paths in errors."""
import os
import re
import sys
import stat
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
            # Open nonblocking, then inspect the opened descriptor: a FIFO
            # must not hang migration, even if a path is replaced during open.
            with os.fdopen(os.open(file, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)), "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    raise ValueError()
                raw = stream.read(51)
            if not re.fullmatch(rb"[a-f0-9]{48}(?:\r?\n)?", raw):
                raise ValueError()
            return raw[:48].decode("ascii")
        except (OSError, ValueError) as exc:
            raise RuntimeError("Missing or invalid " + name + " file") from None
    if not re.fullmatch(r"[a-f0-9]{48}", inline):
        raise RuntimeError("Missing or invalid " + name)
    return inline

if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise RuntimeError("Expected secret name or render")
        if sys.argv[1] == "render":
            # Preserve the legacy CLI without a second configuration writer.
            # The same executable is used by start.sh in both runtime images.
            os.execv("/bin/bash", ["bash", "/opt/radius/radius_secret_input.sh", "render"])
        else:
            print(load_hex(sys.argv[1]))
    except (RuntimeError, OSError, ValueError, KeyError):
        print("RADIUS secret or configuration input rejected", file=sys.stderr)
        sys.exit(1)
