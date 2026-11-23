#!/usr/bin/env python3
"""Stage03 implementation contracts; role permissions and session revocation are server enforced."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
API=ROOT/"src"/"RadiusManager.Api"

class IdentityContracts(unittest.TestCase):
    def test_version_005_contains_identity_and_audit_tables(self):
        sql=(ROOT/"database/005_admin_identity.sql").read_text()
        for name in ('"AspNetUsers"', '"AspNetRoles"', '"AspNetUserRoles"',
                     '"AspNetUserClaims"', '"AspNetRoleClaims"', '"AspNetUserLogins"',
                     '"AspNetUserTokens"', "app_admin_sessions", "app_admin_audit_events",
                     "session_token_hash", "revoked_at", "security_stamp",
                     "super-admin", "noc-operator", "voucher-operator", "reseller", "auditor"):
            self.assertIn(name,sql)
        self.assertNotIn("DROP TABLE",sql.upper())
        self.assertNotIn("TRUNCATE",sql.upper())

    def test_005_is_applied_by_existing_locked_migrator(self):
        engine=(ROOT/"radius/migrate.py").read_text()
        self.assertIn('005_admin_identity.sql',engine)
        self.assertIn("app_admin_sessions",engine)
        self.assertIn("app_admin_audit_events",engine)
        compose=(ROOT/"compose.yaml").read_text()
        self.assertIn("./database/005_admin_identity.sql:/opt/radius/005_admin_identity.sql:ro",compose)
        smoke=(ROOT/"scripts/migration-ledger-smoke.sh").read_text()
        self.assertIn("app_admin_sessions",smoke)
        self.assertIn("app_admin_audit_events",smoke)

    def test_aspnet_identity_requires_tls_and_server_side_roles(self):
        src=(API/"AdminIdentityEndpoints.cs").read_text()
        policy=(API/"AdminAuthorizationRules.cs").read_text()
        server=(API/"Program.cs").read_text()
        db=(API/"AdminIdentityDbContext.cs").read_text()
        for marker in ("UserManager<IdentityUser>", "SignInManager<IdentityUser>",
                       "IsHttps", "IAntiforgery", "PasswordSignIn", "RevokedAt",
                       "Audit", "lockout"):
            self.assertIn(marker.lower(),src.lower())
        for marker in ("super-admin", "noc-operator", "voucher-operator", "reseller", "auditor"):
            self.assertIn(marker,policy)
        self.assertIn("IsAllowed",policy)
        self.assertIn("AddIdentity<IdentityUser, IdentityRole>",server)
        self.assertIn("ConfigureApplicationCookie",server)
        self.assertIn("CookieSecurePolicy.Always",server)
        self.assertIn('RADIUS_ADMIN_AUTH_MODE',server)
        self.assertIn("AdminIdentityDbContext",db)
        self.assertIn('Microsoft.AspNetCore.Identity.EntityFrameworkCore',(API/"RadiusManager.Api.csproj").read_text())

    def test_baseline_lab_path_and_router_behavior_unchanged(self):
        server=(API/"Program.cs").read_text()
        self.assertIn("AdminBasicAuth.Matches(",server)
        self.assertIn("RequestOriginRules.IsAllowed(",server)
        self.assertIn("MapLabAccountEndpoints",server)
        self.assertIn("MapNasDraftEndpoints",server)
        self.assertIn('127.0.0.1:8080:8080',(ROOT/"compose.yaml").read_text())
        self.assertNotIn('INSERT INTO radcheck',(ROOT/"database/005_admin_identity.sql").read_text())

    def test_identity_runtime_negative_security_checks(self):
        smoke=(ROOT/"scripts/admin-identity-smoke.sh").read_text()
        ci=(ROOT/".github/workflows/ci.yml").read_text()
        self.assertIn("admin-identity-smoke.sh",ci)
        self.assertIn("/api/admin/auth/login",smoke)
        self.assertIn("403",smoke)
        self.assertIn("401",smoke)
        self.assertIn("https",smoke)

if __name__=="__main__":
    unittest.main(verbosity=2)
