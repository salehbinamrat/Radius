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
                       "radiusd: FreeRADIUS Version " + source["version"] + " (git #" +
                       source["revision"][:9] + "), for host x86_64-pc-linux-musl, built on Nov 24 2026 at 23:00:08",
                       "FreeRADIUS Version " + source["version"]]) + "\n")

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

    def test_native_banner_rejects_wrong_version_revision_or_architecture(self):
        p = self.root / "radius-source-runtime.provenance.txt"
        original = p.read_text()
        source = self.baseline["source"]
        short = source["revision"][:9]
        for wrong in (
            original.replace("(git #" + short + ")", "(git #" + short[:8] + ")"),
            original.replace("(git #" + short + ")", "(git #" + short + "f)"),
            original.replace("(git #" + short + ")", "(git #" + short[:-1] + "0)"),
            original.replace("x86_64-pc-linux-musl", "aarch64-pc-linux-musl"),
            original.replace("x86_64-pc-linux-musl", "x86_64-pc-linux-musl-other"),
            original.replace("FreeRADIUS Version 3.2.11 (", "FreeRADIUS Version 3.2.10 ("),
            original.replace("radiusd: FreeRADIUS Version", "untrusted: FreeRADIUS Version"),
            original + original.splitlines()[3] + "\n",
        ):
            with self.subTest(banner=wrong.splitlines()[3]):
                p.write_text(wrong)
                with self.assertRaisesRegex(ValueError, "version/architecture evidence mismatch"):
                    evidence.verify(self.root, self.baseline)
        p.write_text(original)
        self.assertFalse(evidence.verify(self.root, self.baseline)["production_approved"])

    def test_ci_requires_evidence_verifier(self):
        scan = (ROOT / "scripts/security-scan-ci.sh").read_text()
        self.assertIn("apk info -v | sort", scan)
        self.assertIn('python3 scripts/verify-security-evidence.py "$reports"', scan)
        self.assertIn('exit "$failed"', scan)

    def test_reviewed_expat_transition_accepts_only_exact_delta(self):
        raw = b"expat-2.10.0-r0\nexpat-dev-2.10.0-r0\nlibexpat-2.10.0-r0\nother-1.0-r0\n"
        expected = {"count": 4, "sha256": hashlib.sha256(raw).hexdigest(),
                    "reviewed_transition": self.baseline["inventories"]["build"].get(
                        "reviewed_transition", {
                            "from_version": "2.10.0-r0", "to_version": "2.11.0-r0",
                            "packages": ["expat", "expat-dev", "libexpat"]})}
        updated = raw.replace(b"2.10.0-r0", b"2.11.0-r0")
        self.assertEqual(evidence.inventory(raw, expected, "build"), set(raw.decode().splitlines()))
        self.assertEqual(evidence.inventory(updated, expected, "build"), set(updated.decode().splitlines()))
        for invalid in (updated.replace(b"other-1.0", b"other-2.0"),
                        updated.replace(b"libexpat-2.11.0", b"libexpat-2.12.0"),
                        updated.replace(b"expat-dev-2.11.0", b"expat-dev-2.10.0"),
                        updated.replace(b"other-1.0-r0", b"expat-2.11.0-r0"),
                        updated + b"extra-1.0-r0\n"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                evidence.inventory(invalid, expected, "build")
