-- Additive migration; safe when schema-init runs again on an existing volume.
-- The application never stores cleartext passwords here. FreeRADIUS radcheck
-- requires a retrievable password for PAP/CHAP; secure DB access accordingly.
CREATE TABLE IF NOT EXISTS app_lab_accounts (
    username varchar(16) PRIMARY KEY CHECK (username ~ '^lab_[a-f0-9]{12}$'),
    plan_id uuid NOT NULL REFERENCES app_plans(id) ON DELETE RESTRICT,
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz,
    CONSTRAINT lab_status_consistent CHECK (
        (active = true AND disabled_at IS NULL)
        OR (active = false AND disabled_at IS NOT NULL)
    )
);
CREATE INDEX IF NOT EXISTS idx_app_lab_accounts_created
    ON app_lab_accounts (created_at DESC);
COMMENT ON TABLE app_lab_accounts IS
    'LAB ONLY: no quota/validity enforcement, and disabling does not disconnect existing sessions';
