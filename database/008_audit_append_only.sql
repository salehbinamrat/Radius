-- Ordinary DML cannot change recorded administrative events or transfer history.
-- A database owner/superuser can still alter the schema; this is not external tamper evidence.
CREATE FUNCTION public.app_reject_audit_mutation() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Recorded audit history is append-only';
END;
$$;
CREATE TRIGGER audit_append_only
BEFORE UPDATE OR DELETE OR TRUNCATE ON public.app_admin_audit_events
FOR EACH STATEMENT EXECUTE FUNCTION public.app_reject_audit_mutation();
CREATE TRIGGER ownership_history_append_only
BEFORE UPDATE OR DELETE OR TRUNCATE ON public.app_lab_owner_transfers
FOR EACH STATEMENT EXECUTE FUNCTION public.app_reject_audit_mutation();
ALTER TABLE public.app_admin_audit_events ENABLE ALWAYS TRIGGER audit_append_only;
ALTER TABLE public.app_lab_owner_transfers ENABLE ALWAYS TRIGGER ownership_history_append_only;
