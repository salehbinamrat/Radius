#!/usr/bin/env python3
"""Narrow tracked-source secret guard. No matches or secret values are printed.
Not a history scanner or a substitute for full secret scanning.
"""
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = (
    re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
    re.compile(rb"(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36}(?![A-Za-z0-9])"),
    re.compile(rb"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{70,}(?![A-Za-z0-9_])"),
    re.compile(rb"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"),
)

def path_risk(name):
    path = PurePosixPath(name)
    base = path.name.lower()
    return (
        (base.startswith(".env.") and base not in {".env.example", ".env.sample", ".env.template"})
        or base == ".env"
        or base in {"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"}
        or path.suffix.lower() in {".pfx", ".p12", ".key", ".kdbx"}
    )

def content_risk(data):
    return any(pattern.search(data) for pattern in PATTERNS)

def main():
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
    failed = False
    for raw in filter(None, paths):
        name = raw.decode("utf-8", errors="surrogateescape")
        path = ROOT / name
        if path_risk(name):
            print(f"Prohibited credential file: {name!r}", file=sys.stderr)
            failed = True
            continue
        if path.is_symlink() or not path.is_file():
            print(f"Cannot safely scan tracked path: {name!r}", file=sys.stderr)
            failed = True
            continue
        if content_risk(path.read_bytes()):
            print(f"Potential credential in tracked file: {name!r}", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print("Tracked-source credential guard passed (limited pattern coverage; no history scan).")
    return 0

if __name__ == "__main__":
    sys.exit(main())
