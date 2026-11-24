-- Additive, transactional migration for measured session reads.
-- Schedule a maintenance window: ordinary index creation blocks concurrent writes.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';
CREATE INDEX idx_app_radacct_recent ON public.radacct
    ((COALESCE(acctupdatetime,acctstarttime)) DESC, radacctid DESC);
CREATE INDEX idx_app_radacct_user_recent ON public.radacct
    (username, (COALESCE(acctupdatetime,acctstarttime)) DESC, radacctid DESC);
