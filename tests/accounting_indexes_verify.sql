-- Validate the expected definitions and usable indexes after migration/restore.
DO $body$
DECLARE actual_count integer;
BEGIN
  SELECT count(*) INTO actual_count
  FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND i.indrelid='public.radacct'::regclass
    AND i.indisvalid AND i.indisready AND i.indislive
    AND regexp_replace(lower(replace(pg_get_indexdef(c.oid),'ON public.radacct ','ON radacct ')),
                       '\s+', '', 'g') =
      CASE c.relname
        WHEN 'idx_app_radacct_recent' THEN
          'createindexidx_app_radacct_recentonradacctusingbtree(coalesce(acctupdatetime,acctstarttime)desc,radacctiddesc)'
        WHEN 'idx_app_radacct_user_recent' THEN
          'createindexidx_app_radacct_user_recentonradacctusingbtree(username,coalesce(acctupdatetime,acctstarttime)desc,radacctiddesc)'
      END;
  IF actual_count <> 2 THEN
    RAISE EXCEPTION 'Accounting index definitions or validity mismatch';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.app_schema_migrations
                WHERE version=9 AND filename='009_accounting_read_indexes.sql') THEN
    RAISE EXCEPTION 'Accounting index migration ledger entry missing';
  END IF;
END
$body$;
