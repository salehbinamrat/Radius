-- Explicit allowlist for the disposable role test, executed by the schema owner.
-- Role creation/password are supplied separately, not stored here.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.app_lab_usage_snapshot(varchar) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.app_reject_audit_mutation() FROM PUBLIC;
GRANT CONNECT ON DATABASE radius TO radius_runtime;
GRANT USAGE ON SCHEMA public TO radius_runtime;
GRANT SELECT ON public.radcheck, public.radreply, public.radgroupcheck,
    public.radgroupreply, public.radusergroup TO radius_runtime;
GRANT SELECT, INSERT, UPDATE ON public.radacct TO radius_runtime;
GRANT INSERT ON public.radpostauth TO radius_runtime;
GRANT USAGE ON SEQUENCE public.radacct_radacctid_seq, public.radpostauth_id_seq TO radius_runtime;
