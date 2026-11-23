-- Phase 3A: observational accounting only. Do NOT enable quotas based on this view.
-- A row in radacct is the latest cumulative snapshot of one session, NOT an
-- individual incremental usage event. Summing duplicate interim packets would
-- overcharge a voucher. This function deliberately reads the canonical rows.
CREATE OR REPLACE FUNCTION app_lab_usage_snapshot(p_username varchar)
RETURNS TABLE (
    upload_bytes numeric,
    download_bytes numeric,
    session_count bigint,
    open_sessions bigint,
    stale_sessions bigint,
    anomalous_sessions bigint,
    observed_nas_count bigint,
    latest_accounting_at timestamptz
)
LANGUAGE sql STABLE
AS $body$
    SELECT
        COALESCE(SUM(GREATEST(COALESCE(a.acctinputoctets, 0), 0)::numeric), 0),
        COALESCE(SUM(GREATEST(COALESCE(a.acctoutputoctets, 0), 0)::numeric), 0),
        COUNT(*)::bigint,
        COUNT(*) FILTER (WHERE a.acctstoptime IS NULL)::bigint,
        COUNT(*) FILTER (
            WHERE a.acctstoptime IS NULL
              AND COALESCE(a.acctupdatetime, a.acctstarttime) < now() - interval '10 minutes'
        )::bigint,
        COUNT(*) FILTER (
            WHERE a.acctinputoctets < 0 OR a.acctoutputoctets < 0
               OR a.acctstarttime IS NULL
               OR (a.acctstoptime IS NOT NULL AND a.acctstoptime < a.acctstarttime)
               OR (a.acctupdatetime IS NOT NULL AND a.acctupdatetime < a.acctstarttime)
        )::bigint,
        COUNT(DISTINCT a.nasipaddress)::bigint,
        MAX(COALESCE(a.acctstoptime, a.acctupdatetime, a.acctstarttime))
    FROM radacct a
    WHERE a.username = p_username;
$body$;

COMMENT ON FUNCTION app_lab_usage_snapshot(varchar) IS
  'Read-only cumulative snapshots across NAS. Missing/lost RADIUS accounting packets cannot be recovered. NOT suitable for billing or quota enforcement.';
