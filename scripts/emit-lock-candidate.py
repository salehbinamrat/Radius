"""Emit public dependency lock candidates, not credentials or configuration.
Temporary bootstrap step until reviewed lockfiles are committed and enforced.
"""
import base64
import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

ALLOWED = {
    "src/RadiusManager.Api/packages.lock.json",
    "tests/RadiusManager.Tests/packages.lock.json",
    "src/RadiusManager.Api/frontend/package-lock.json",
    "tests/browser/package-lock.json",
}

def validate(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "resolved":
                if not isinstance(child, str):
                    raise ValueError("Non-string package source")
                url = urlsplit(child)
                if (url.scheme != "https" or url.netloc != "registry.npmjs.org"
                        or url.query or url.fragment):
                    raise ValueError("Non-public or credential-bearing package source")
            validate(child)
    elif isinstance(value, list):
        for child in value:
            validate(child)

def main():
    for name in sys.argv[1:]:
        if name not in ALLOWED:
            raise ValueError("Not an approved lockfile")
        path = Path(name)
        if path.is_symlink():
            raise ValueError("Symlink is not an approved lockfile")
        raw = path.read_bytes()
        if len(raw) > 500_000:
            raise ValueError("Lockfile exceeds review limit")
        obj = json.loads(raw)
        if path.name == "package-lock.json":
            if obj.get("lockfileVersion") != 3 or not obj.get("packages"):
                raise ValueError("Unexpected npm lockfile schema")
            validate(obj)
        elif not isinstance(obj.get("dependencies"), dict) or not obj["dependencies"]:
            raise ValueError("Unexpected NuGet lockfile schema")
        print("LOCK_BEGIN", name, hashlib.sha256(raw).hexdigest(), flush=True)
        encoded = base64.b64encode(raw).decode("ascii")
        for start in range(0, len(encoded), 120):
            print("LOCK_DATA", encoded[start:start + 120])
        print("LOCK_END", name, flush=True)

if __name__ == "__main__":
    main()
