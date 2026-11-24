-- Disposable database acceptance only. Every rejected statement is rolled back
-- by its PL/pgSQL subtransaction; unexpectedly accepted DML aborts the test.
DO $$
DECLARE
    statement text;
BEGIN
    FOREACH statement IN ARRAY ARRAY[
        'UPDATE public.app_admin_audit_events SET outcome=outcome',
        'DELETE FROM public.app_admin_audit_events',
        'TRUNCATE public.app_admin_audit_events',
        'UPDATE public.app_lab_owner_transfers SET new_owner_id=new_owner_id',
        'DELETE FROM public.app_lab_owner_transfers',
        'TRUNCATE public.app_lab_owner_transfers'
    ] LOOP
        BEGIN
            EXECUTE statement;
            RAISE EXCEPTION 'Audit mutation unexpectedly accepted';
        EXCEPTION WHEN SQLSTATE '55000' THEN
            IF SQLERRM <> 'Recorded audit history is append-only' THEN RAISE; END IF;
        END;
    END LOOP;
END;
$$;
