-- Explicit grants for isolated role acceptance. No ownership or role memberships.
GRANT CONNECT ON DATABASE radius TO radius_api, radius_bootstrap;
GRANT USAGE ON SCHEMA public TO radius_api, radius_bootstrap;

-- Runtime API: read identity and membership, update existing user for Identity
-- lockout/password operations. No creation of principals or role assignment.
GRANT SELECT, UPDATE ON public."AspNetUsers" TO radius_api;
GRANT SELECT ON public."AspNetRoles", public."AspNetUserRoles",
    public."AspNetUserClaims", public."AspNetRoleClaims" TO radius_api;
GRANT SELECT, INSERT, UPDATE ON public.app_admin_sessions TO radius_api;
GRANT SELECT, INSERT ON public.app_admin_audit_events TO radius_api;
GRANT USAGE ON SEQUENCE public.app_admin_audit_events_id_seq TO radius_api;

GRANT SELECT, INSERT, UPDATE ON public.app_plans, public.app_lab_accounts,
    public.app_nas_drafts, public.app_lab_account_owners TO radius_api;
GRANT INSERT ON public.app_nas_draft_events TO radius_api;
GRANT SELECT, INSERT ON public.app_lab_owner_transfers TO radius_api;
GRANT SELECT, INSERT, UPDATE ON public.radgroupreply TO radius_api;
GRANT SELECT, INSERT, DELETE ON public.radcheck, public.radusergroup TO radius_api;
GRANT SELECT ON public.radacct TO radius_api;
GRANT USAGE ON SEQUENCE public.app_nas_draft_events_id_seq, public.radgroupreply_id_seq,
    public.radcheck_id_seq, public.radusergroup_id_seq TO radius_api;
GRANT EXECUTE ON FUNCTION public.app_lab_usage_snapshot(varchar) TO radius_api;

-- One-time console enrollment. Login disabled after the bootstrap race.
GRANT SELECT, INSERT, UPDATE ON public."AspNetUsers" TO radius_bootstrap;
GRANT SELECT ON public."AspNetRoles" TO radius_bootstrap;
GRANT SELECT, INSERT ON public."AspNetUserRoles" TO radius_bootstrap;
GRANT SELECT, INSERT ON public.app_admin_audit_events TO radius_bootstrap;
GRANT USAGE ON SEQUENCE public.app_admin_audit_events_id_seq TO radius_bootstrap;
