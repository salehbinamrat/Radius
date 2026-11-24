#!/usr/bin/env python3
"""Stage 03 frontend transition: test existing app and real React + TS bundle wiring."""
from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
API = ROOT / "src/RadiusManager.Api"
UI = API / "frontend"

class ReactTypeScriptContracts(unittest.TestCase):
    def test_react_typescript_vite_are_real_dependencies(self):
        package=json.loads((UI/"package.json").read_text())
        self.assertEqual(package["type"],"module")
        for dep in ("react","react-dom"):
            self.assertIn(dep,package["dependencies"])
        for dep in ("typescript","vite","@vitejs/plugin-react"):
            self.assertIn(dep,package["devDependencies"])
        self.assertIn("tsc --noEmit",package["scripts"]["check"])
        self.assertIn("vite build",package["scripts"]["build"])

    def test_react_component_is_reachable_without_replacing_existing_ui(self):
        html=(API/"wwwroot/index.html").read_text()
        self.assertIn('id="reactNocStatus"',html)
        self.assertIn('src="modern/noc-react.mjs"',html)
        self.assertIn('src="app.mjs"',html)
        jsx=(UI/"src/StatusPanel.tsx").read_text()
        self.assertIn("/api/health/live",jsx)
        self.assertIn("useEffect",jsx)
        self.assertIn("AbortController",jsx)
        self.assertNotIn("Authorization",jsx)

    def test_bundle_is_built_in_docker_and_covered_by_ci(self):
        dock=(API/"Dockerfile").read_text()
        self.assertIn("node:24-bookworm-slim",dock)
        self.assertIn("npm run check",dock)
        self.assertIn("npm run build",dock)
        self.assertIn("COPY --from=ui-build",dock)
        vite=(UI/"vite.config.ts").read_text()
        self.assertIn("noc-react.mjs",vite)
        ci=(ROOT/".github/workflows/ci.yml").read_text()
        self.assertIn("npm run check",ci)
        self.assertIn("npm run build",ci)
        smoke=(ROOT/"scripts/ui-smoke.sh").read_text()
        self.assertIn("/modern/noc-react.mjs",smoke)

    def test_compiled_assets_are_not_committed_as_source(self):
        ignored=(ROOT/".gitignore").read_text()
        self.assertIn("src/RadiusManager.Api/wwwroot/modern/",ignored)

if __name__=="__main__":
    unittest.main(verbosity=2)
