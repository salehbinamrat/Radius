"""Regression tests for source inventory and actual runtime report binding."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("evidence", ROOT / "scripts/verify-security-evidence.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class SecurityEvidenceChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.baseline = json.loads(evidence.BASELINE.read_text())
        self.assertEqual(self.baseline["source"]["status"], "unreleased-lab-only")
        self.raw = b"apk-tools-1.0-r0\n"
        for kind in ("build", "runtime"):
            self.baseline["inventories"][kind] = {
                "count": 1, "sha256": hashlib.sha256(self.raw).hexdigest()}
            (self.root / ("radius-source-" + kind + "-packages.txt")).write_bytes(self.raw)
        (self.root / "radius-live-packages.txt").write_bytes(self.raw)
        ids = {name: "sha256:" + char * 64 for name, char in
               (("api", "a"), ("radius", "b"), ("db", "c"))}
        (self.root / "image-identities.txt").write_text(
            "".join(name + " " + image + "\n" for name, image in ids.items()))
        for name, image in ids.items():
            self.write_report(name, {"Metadata": {"ImageID": image}, "Results": [
                {"Type": "alpine", "Packages": [{"Name": "apk-tools", "Version": "1.0-r0"}]}]})
        source = self.baseline["source"]
        (self.root / "radius-source-runtime.provenance.txt").write_text(
            "\n".join([source["revision"], *source["verified_fix_ancestors"].values(),
                       "FreeRADIUS Version " + source["version"] + " (git #" +
                       source["revision"][:8] + "), for host x86_64-pc-linux-musl"]) + "\n")

    def write_report(self, name, report):
        (self.root / (name + ".vulnerabilities.json")).write_text(json.dumps(report))

    def mutate_report(self, name, change):
        report = json.loads((self.root / (name + ".vulnerabilities.json")).read_text())
        change(report)
        self.write_report(name, report)

    def test_valid_lab_evidence_never_approves_production(self):
        result = evidence.verify(self.root, self.baseline)
        self.assertFalse(result["production_approved"])
        self.assertEqual(result["package_coverage"]["alpine_runtime"], 1)

    def test_reject_different_image(self):
        self.mutate_report("api", lambda r: r["Metadata"].update(ImageID="sha256:" + "f" * 64))
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            evidence.verify(self.root, self.baseline)

    def test_reject_high_vulnerability_even_if_scanner_exit_was_zero(self):
        self.mutate_report("db", lambda r: r["Results"][0].update(
            Vulnerabilities=[{"Severity": "HIGH"}]))
        with self.assertRaisesRegex(ValueError, "vulnerabilities remain"):
            evidence.verify(self.root, self.baseline)

    def test_reject_unreviewed_build_inventory(self):
        (self.root / "radius-source-build-packages.txt").write_bytes(b"apk-tools-2.0-r0\n")
        with self.assertRaisesRegex(ValueError, "inventory changed"):
            evidence.verify(self.root, self.baseline)

    def test_reject_runtime_drift(self):
        (self.root / "radius-live-packages.txt").write_bytes(b"apk-tools-2.0-r0\n")
        with self.assertRaisesRegex(ValueError, "Running daemon package inventory differs"):
            evidence.verify(self.root, self.baseline)

    def test_reject_partial_package_scan(self):
        self.mutate_report("radius", lambda r: r["Results"][0]["Packages"][0].update(Version="9"))
        with self.assertRaisesRegex(ValueError, "coverage differs"):
            evidence.verify(self.root, self.baseline)

    def test_reject_wrong_source_revision(self):
        p = self.root / "radius-source-runtime.provenance.txt"
        p.write_text(p.read_text().replace(self.baseline["source"]["revision"], "bad"))
        with self.assertRaisesRegex(ValueError, "source revision"):
            evidence.verify(self.root, self.baseline)

    def test_ci_requires_evidence_verifier(self):
        scan = (ROOT / "scripts/security-scan-ci.sh").read_text()
        self.assertIn("apk info -v | sort", scan)
        self.assertIn('python3 scripts/verify-security-evidence.py "$reports"', scan)
        self.assertIn('exit "$failed"', scan)
