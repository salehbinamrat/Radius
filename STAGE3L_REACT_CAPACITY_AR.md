# Stage 03L — React 19 capacity calculator

**Date:** 2026-11-24  
**Scope:** Local, read-only hypothetical planning. No subscribers, live RouterOS, quotas, NAS or accounting writes.

## Implementation
- `CapacityCalculator.tsx` owns its five editable assumptions and three output cards in the existing RTL layout; the component uses React 19 + strict TypeScript and updates results when inputs change.
- It **imports** `estimateCapacity` directly from the **existing tested** `wwwroot/capacity-utils.mjs` via a matching `capacity-utils.d.mts` type declaration. No duplicated formula, validation or API endpoint.
- All initial values, input constraints, output rounding, decimal TB methodology and Arabic warnings are preserved. Invalid inputs produce a validation error and hide misleading output.
- The original DOM calculator and its event listeners were removed from `ultra-features.mjs`; this module still owns all authenticated read-only session fetching, classification, CSV export and network safety warnings.
- The Vite production bundle is self-hosted under `/modern/` within the existing strict CSP. No new npm dependency was introduced.
- The view still explicitly states it is an estimate without network measurements.

## Tests and acceptance
- New `tests/js/capacity-react.test.mjs` tests exact defaults, response to changed assumptions, validation of missing/invalid inputs, immutability; existing `tests/js/capacity-utils.test.mjs` remains intact.
- `tests/react_capacity_calculator_checks.py` ensures complete React ownership, no duplicate math, no network APIs or local storage, and correct disclosure.
- `scripts/ui-smoke.sh` checks deployment of the React mount and original calculation engine.
- Merge only after `config-tests` and `dotnet-tests` both pass in parallel, then the entire `compose-integration` suite (FreeRADIUS, PostgreSQL, HTTPS identities, encrypted backup/restore, migrations) passes. Re-run CI on the merged `main` commit.

## Deferred
Browser automation, SignalR real data source, high-volume performance tuning, and production deployment remain separate work with their own safety gates. This isolated UI migration **does not** certify production readiness.
