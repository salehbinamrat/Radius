#!/usr/bin/env python3
"""Independent candidate evidence; never changes the accepted legacy baseline."""
import hashlib
import json
import re
import sys
from pathlib import Path

def require(ok, message):
    if not ok:
        raise ValueError(message)

def verify(root, preflight=False):
    legacy, candidate = json.loads((root / "radius-slim-image-inspect.json").read_text())
    require(legacy["Id"] != candidate["Id"], "Candidate image identity unchanged")
    require(re.fullmatch(r"sha256:[a-f0-9]{64}", candidate["Id"]), "Invalid candidate image ID")
    require(candidate["Size"] < legacy["Size"], "Candidate is not smaller")
    require(candidate["RootFS"]["Layers"] and
            not set(candidate["RootFS"]["Layers"]) & set(legacy["RootFS"]["Layers"]),
            "Legacy image layers retained")
    require(candidate["Config"]["Entrypoint"] == legacy["Config"]["Entrypoint"] and
            candidate["Config"]["ExposedPorts"] == legacy["Config"]["ExposedPorts"],
            "Runtime entrypoint or ports changed")
    old_raw = (root / "radius-slim-legacy-packages.txt").read_bytes()
    new_raw = (root / "radius-slim-packages.txt").read_bytes()
    baseline = json.loads((Path(__file__).resolve().parents[1] / "radius/source-build-baseline.json").read_text())
    require(hashlib.sha256(old_raw).hexdigest() == baseline["inventories"]["runtime"]["sha256"],
            "Legacy package baseline mismatch")
    old, new = set(old_raw.decode().splitlines()), set(new_raw.decode().splitlines())
    require(new and new < old, "Candidate added or changed packages")
    require(not any(re.match(r"(python3|py3-psycopg2|libpython3)(?:-|$)", p) for p in new),
            "Python runtime package retained")
    require(not any(p.startswith("python3-") for p in new), "Python package retained")
    require(new_raw == (root / "radius-slim-build-packages.txt").read_bytes(), "Candidate inventory drift")
    require((root / "radius-slim-source.txt").read_bytes() ==
            (root / "radius-slim-legacy-source.txt").read_bytes(), "Native executable/schema/source changed")
    require(baseline["source"]["revision"].encode() in (root / "radius-slim-source.txt").read_bytes(),
            "Source revision mismatch")
    if not preflight:
        require((root / "radius-slim-image-id.txt").read_text().strip() == candidate["Id"],
                "Tested candidate identity mismatch")
        report = json.loads((root / "radius-slim.vulnerabilities.json").read_text())
        require(report["Metadata"]["ImageID"] == candidate["Id"], "Scanned candidate identity mismatch")
        results = report["Results"]
        require(results and not any(v.get("Severity") in ("HIGH", "CRITICAL")
                    for r in results for v in r.get("Vulnerabilities") or []), "Candidate vulnerability gate failed")
        alpine = [r for r in results if r.get("Type") == "alpine"]
        require(len(alpine) == 1 and alpine[0].get("Packages"), "Candidate package coverage missing")
        scanned = [p["Name"] + "-" + p["Version"] for p in alpine[0]["Packages"]]
        require(len(scanned) == len(new) and set(scanned) == new, "Candidate package scan coverage differs")
        sbom = json.loads((root / "radius-slim.cdx.json").read_text())
        require(sbom.get("bomFormat") == "CycloneDX" and sbom.get("components"), "Candidate SBOM missing")
    result = {"legacy_image": legacy["Id"], "candidate_image": candidate["Id"],
              "legacy_bytes": legacy["Size"], "candidate_bytes": candidate["Size"],
              "bytes_saved": legacy["Size"] - candidate["Size"],
              "removed_packages": sorted(old-new), "retained_packages": len(new),
              "source_scan_limitation": "OS scan does not attest source-built FreeRADIUS",
              "production_approved": False}
    print(json.dumps(result, indent=2))
    if not preflight:
        (root / "radius-slim-comparison.json").write_text(json.dumps(result, indent=2)+"\n")
        print("Reduced RADIUS image identity, size, package subset and scan coverage PASS")

if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]), "--preflight" in sys.argv[2:])
    except (ValueError, KeyError, OSError, TypeError) as exc:
        sys.exit("Reduced RADIUS candidate rejected: " + str(exc))
