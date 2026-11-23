-- Owner uses official FreeRADIUS PostgreSQL schema in schema-init service.
-- This application schema is intentionally independent of radacct for now.
CREATE TABLE IF NOT EXISTS app_plans (
  id uuid PRIMARY KEY,
  name varchar(80) NOT NULL UNIQUE,
  upload_kbps integer NOT NULL CHECK (upload_kbps BETWEEN 64 AND 1000000),
  download_kbps integer NOT NULL CHECK (download_kbps BETWEEN 64 AND 1000000),
  quota_bytes bigint NULL CHECK (quota_bytes IS NULL OR quota_bytes > 0),
  validity_days integer NULL CHECK (validity_days IS NULL OR validity_days BETWEEN 1 AND 3650),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE app_plans IS 'Lab policy metadata: quotas/validity are NOT enforced until accounting phase is complete';
