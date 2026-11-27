#!/usr/bin/env python3
"""Bind lab security reports to actual runtime identity; not production attestation."""
import hashlib
import json
import re
import sys
from pathlib import Path

BASELINE = Path(__file__).resolve().parents[1] / "radius" / "source-build-baseline.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inventory(raw, expected, label):
    lines = raw.decode("utf-8").splitlines()
    require(len(lines) == expected["count"] and len(set(lines)) == len(lines),
            label + ": package count/uniqueness changed; review required")
    actual = hashlib.sha256(raw).hexdigest()
    if actual != expected["sha256"]:
        # Canonicalize only complete, independently reviewed transitions.
        # The original whole-inventory SHA-256 must still match. This also
        # handles two security updates arriving together without accepting
        # partial groups, unknown versions, or unrelated inventory changes.
        transitions = ([expected["reviewed_transition"]]
                       if "reviewed_transition" in expected else [])
        transitions += expected.get("additional_reviewed_transitions", [])
        canonical = raw
        changed = False
        used = set()
        for transition in transitions:
            names = transition["packages"]
            require(names and len(set(names)) == len(names) and not used.intersection(names),
                    label + ": invalid overlapping reviewed transitions")
            used.update(names)
            old = [name + "-" + transition["from_version"] for name in names]
            new = [name + "-" + transition["to_version"] for name in names]
            if all(lines.count(item) == 1 for item in new) and not set(old) & set(lines):
                for before, after in zip(old, new):
                    canonical = canonical.replace((after + "\n").encode(), (before + "\n").encode())
                changed = True
            elif not (all(lines.count(item) == 1 for item in old) and not set(new) & set(lines)):
                raise ValueError(label + ": package inventory changed; review required (SHA-256 " + actual + ")")
        if changed and hashlib.sha256(canonical).hexdigest() == expected["sha256"]:
            print(label + ": exact reviewed package transition verified; actual SHA-256 " + actual)
            return set(lines)
        raise ValueError(label + ": package inventory changed; review required (SHA-256 " + actual + ")")
    return set(lines)


def verify(root, baseline):
    identities = {}
    for line in (root / "image-identities.txt").read_text().splitlines():
        service, image = line.split()
        require(service not in identities and re.fullmatch(r"sha256:[0-9a-f]{64}", image),
                "Invalid or duplicate runtime image identity")
        identities[service] = image
    require(set(identities) == {"api", "radius", "db"}, "Incomplete runtime image identities")
    reports = {}
    for service, image in identities.items():
        report = json.loads((root / (service + ".vulnerabilities.json")).read_text())
        require(report.get("Metadata", {}).get("ImageID") == image,
                service + ": scan image identity mismatch")
        results = report.get("Results")
        require(isinstance(results, list) and results, service + ": missing scan targets")
        require(not any(v.get("Severity") in ("HIGH", "CRITICAL")
                        for r in results for v in (r.get("Vulnerabilities") or [])),
                service + ": HIGH/CRITICAL vulnerabilities remain")
        reports[service] = results

    inv = baseline["inventories"]
    build_packages = inventory((root / "radius-source-build-packages.txt").read_bytes(), inv["build"], "build")
    runtime_raw = (root / "radius-source-runtime-packages.txt").read_bytes()
    packages = inventory(runtime_raw, inv["runtime"], "runtime")
    for shared in ("libexpat", "libffi"):
        require({p for p in build_packages if p.startswith(shared + "-")} ==
                {p for p in packages if p.startswith(shared + "-")},
                "Build/runtime " + shared + " version mismatch")
    require((root / "radius-live-packages.txt").read_bytes() == runtime_raw,
            "Running daemon package inventory differs from build")
    alpine = [r for r in reports["radius"] if r.get("Type") == "alpine"]
    require(len(alpine) == 1 and alpine[0].get("Packages"), "Missing Alpine package coverage")
    scanned = [p["Name"] + "-" + p["Version"] for p in alpine[0]["Packages"]]
    require(len(scanned) == len(packages) and set(scanned) == packages,
            "Trivy Alpine package coverage differs from actual runtime inventory")
    source = baseline["source"]
    provenance = (root / "radius-source-runtime.provenance.txt").read_text().splitlines()
    require(provenance[:3] == [source["revision"], *source["verified_fix_ancestors"].values()],
            "FreeRADIUS source revision/fix evidence mismatch")
    # Native radiusd -v uses a nine-character source abbreviation.
    # Match the complete native banner, not unrelated version/help lines.
    banner = (r"radiusd: FreeRADIUS Version " + re.escape(source["version"]) +
              r" \(git #" + re.escape(source["revision"][:9]) +
              r"\), for host " + re.escape(baseline["architecture"] + "-pc-linux-musl") +
              r", built on .+")
    require(sum(re.fullmatch(banner, line) is not None for line in provenance[3:]) == 1,
            "Native FreeRADIUS version/architecture evidence mismatch")
    # Explicit source inventory supplements, never modifies, Trivy's OS SBOM.
    return {"schema": 1, "image": identities["radius"], "component": "FreeRADIUS",
            "source": source, "package_coverage": {"alpine_runtime": len(packages)},
            "coverage_limitation": "OS package scan does not attest source-built FreeRADIUS",
            "production_approved": False}


def main():
    root = Path(sys.argv[1])
    result = verify(root, json.loads(BASELINE.read_text()))
    (root / "radius-source-coverage.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Runtime image identities, package baseline and scan coverage PASS (lab only)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, TypeError) as exc:
        sys.exit("Security evidence rejected: " + str(exc))
