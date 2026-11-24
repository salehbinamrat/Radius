-- Additive ownership of LAB vouchers only. Do not infer ownership or backfill historical rows.
CREATE TABLE app_lab_account_owners (
    username varchar(16) PRIMARY KEY REFERENCES app_lab_accounts(username) ON DELETE RESTRICT,
    owner_user_id text NOT NULL REFERENCES "AspNetUsers"("Id") ON DELETE RESTRICT,
    assigned_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_lab_account_owners_owner ON app_lab_account_owners(owner_user_id, username);
COMMENT ON TABLE app_lab_account_owners IS
    'Explicit lab voucher ownership only. Unassigned vouchers are invisible to reseller reads.';
