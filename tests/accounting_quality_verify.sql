-- Pure classifier acceptance; uses synthetic composite values without modifying rows.
DO $verify$
DECLARE
    good public.radacct;
    missing public.radacct;
BEGIN
    good := jsonb_populate_record(NULL::public.radacct,
       '{"acctinputoctets":0,"acctoutputoctets":0,"acctstarttime":"2026-01-01T00:00:00Z"}'::jsonb);
    missing := good;
    missing.acctinputoctets := NULL;
    IF public.app_accounting_row_anomalous(good) IS DISTINCT FROM false
        OR public.app_accounting_row_anomalous(missing) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Accounting quality classifier mismatch';
    END IF;
END;
$verify$;
