# Radius — private-network RADIUS and ISP management laboratory

> **Laboratory only — not production ready.** Do not connect real subscriber accounts or production MikroTik routers.

Current architecture: ASP.NET Core / C# .NET 10, FreeRADIUS source build, PostgreSQL 16, React/TypeScript and existing JavaScript RTL interface, SignalR, Docker Compose on Linux.

## Verified laboratory capabilities

Plans with stable rate-limit groups; individual synthetic vouchers with one-time credential display; administrative sessions and role-scoped access in the HTTPS test profile; reseller ownership and audited transfers; read-only NAS drafts; service monitoring, alert history and incidents; observational accounting including 64-bit cumulative counters and distinct synthetic NAS session identity; versioned migrations and encrypted logical recovery. See the pinned evidence and limits in [Phase 01 audit](PHASE01_AUDIT_AR.md).

## Not approved for production

Quota, validity and simultaneous-session enforcement, live NAS enrollment, device-specific RouterOS v6/v7 compatibility, production vouchers and billing, high availability and production deployment remain open. The default Compose profile is a loopback laboratory profile, not the separate restricted HTTPS acceptance configuration. The source-built FreeRADIUS scan is not a complete source-level security attestation.

See [README_AR.md](README_AR.md) for setup. Historical status documents describe earlier snapshots, not the current release.

## Safe local tests

```bash
bash scripts/ci-config-checks.sh
dotnet restore tests/RadiusManager.Tests/RadiusManager.Tests.csproj --locked-mode
dotnet test tests/RadiusManager.Tests/RadiusManager.Tests.csproj --no-restore -c Release
```

Node 24, Python 3, Bash and .NET 10 are required for these checks. Docker integration and security checks run in CI after the parallel gates. Never use a production database for laboratory fixtures.

## Repository workflow

Use a separate branch and pull request, preserve all compatibility contracts, require all mandatory checks on the exact proposed revision, and do not merge a failing or incomplete change.
