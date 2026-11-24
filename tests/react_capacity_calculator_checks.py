#!/usr/bin/env python3
"""Stage 03L: the calculator migrates to React without duplicating math or touching NAS."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
API=ROOT/"src/RadiusManager.Api"
WEB=API/"wwwroot"
FRONT=API/"frontend/src"

class CapacityReactContracts(unittest.TestCase):
    def test_react_owns_complete_hypothetical_calculator(self):
        html=(WEB/"index.html").read_text(encoding="utf-8")
        react=(FRONT/"CapacityCalculator.tsx").read_text(encoding="utf-8")
        main=(FRONT/"main.tsx").read_text(encoding="utf-8")
        self.assertIn('id="reactCapacityCalculator"',html)
        self.assertIn('id="view-capacity"',html)
        self.assertNotIn('id="capForm"',html)
        self.assertIn('CapacityCalculator',main)
        for key in ('capForm','capUsers','capSpeed','capConcurrency','capSharing',
                    'capHours','capPeakOut','capSpeedOut','capVolumeOut','capError'):
            self.assertIn('id="'+key+'"',react)
        self.assertIn('لا يستند إلى قياسات فعلية',html)
        self.assertIn('تقدير استرشادي',html)
    def test_one_shared_calculation_engine_no_duplicate_backend_or_network_telemetry(self):
        react=(FRONT/"CapacityCalculator.tsx").read_text(encoding="utf-8")
        ultra=(WEB/"ultra-features.mjs").read_text(encoding="utf-8")
        code=(WEB/"capacity-utils.mjs").read_text(encoding="utf-8")
        self.assertIn('estimateCapacity(',react)
        self.assertIn("from '../../wwwroot/capacity-utils.mjs'",react)
        self.assertIn('Math.ceil(',code)
        self.assertNotIn('estimateCapacity(',ultra)
        self.assertNotIn('capForm',ultra)
        self.assertNotIn('Math.ceil(',react)
        for banned in ('fetch(', 'localStorage', 'sessionStorage', 'Authorization',
                       '/api/', 'dangerouslySetInnerHTML', 'NAS API', 'MikroTik API'):
            self.assertNotIn(banned,react)
    def test_pipeline_smoke_keeps_old_integrations(self):
        smoke=(ROOT/"scripts/ui-smoke.sh").read_text(encoding="utf-8")
        ci=(ROOT/".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn('reactCapacityCalculator',smoke)
        self.assertIn('estimateCapacity',smoke)
        docker=(API/"Dockerfile").read_text(encoding="utf-8")
        self.assertIn('COPY wwwroot/capacity-utils.mjs wwwroot/capacity-utils.d.mts /ui/wwwroot/', docker)
        self.assertIn('npm run check && npm run build', docker)
        self.assertIn('needs: [dotnet-tests, config-tests]',ci)
        self.assertIn('scripts/admin-https-smoke.sh',ci)

if __name__=="__main__":
    unittest.main(verbosity=2)
