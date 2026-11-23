# Radius — local private-network RADIUS lab (Phase 1)

> **Laboratory only — not production ready.** No real customer vouchers or MikroTik production routers should be connected yet.

This is the first phase of a self-hosted RADIUS management project for MikroTik RouterOS 6 Hotspot networks.

**Components:** FreeRADIUS 3.x, PostgreSQL 16, ASP.NET Core 10 API, Arabic RTL web interface, Docker Compose, automated tests.

**Implemented:** basic management of experimental plans, storing plan name, speed, quota/validity metadata, and emitting the rate limit for RADIUS groups.

**Not implemented:** production vouchers, quota/validity enforcement, cross-site shared credit, simultaneous-use enforcement, failover, and RouterOS integration. Do not market or sell cards with this phase.

See [README_AR.md](README_AR.md) for the Arabic setup guide and [PROJECT_STATUS_AR.md](PROJECT_STATUS_AR.md) for verification limitations.

## Safe local tests

```bash
python3 tests/config_checks.py
node --test tests/js/*.test.mjs
bash -n scripts/*.sh radius/*.sh
```

Integration tests require a Linux Docker host and .NET SDK, or the included GitHub Actions CI. All network service ports bind to localhost by default.

## Repository workflow

Develop on a feature branch, run tests and Docker integration, then open a pull request. Do not merge while any check is failing.
