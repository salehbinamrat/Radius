-- Preserve existing ownership and assign opaque concurrency versions; no inferred transfer history.
ALTER TABLE app_lab_account_owners
    ADD COLUMN ownership_version uuid NOT NULL DEFAULT gen_random_uuid();
CREATE TABLE app_lab_owner_transfers (
    id uuid PRIMARY KEY,
    username varchar(16) NOT NULL REFERENCES app_lab_accounts(username) ON DELETE RESTRICT,
    previous_owner_id text NOT NULL REFERENCES "AspNetUsers"("Id") ON DELETE RESTRICT,
    new_owner_id text NOT NULL REFERENCES "AspNetUsers"("Id") ON DELETE RESTRICT,
    actor_user_id text NOT NULL REFERENCES "AspNetUsers"("Id") ON DELETE RESTRICT,
    previous_version uuid NOT NULL,
    new_version uuid NOT NULL UNIQUE,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    CHECK (previous_owner_id <> new_owner_id),
    CHECK (previous_version <> new_version),
    UNIQUE (username, previous_version)
);
CREATE INDEX idx_lab_owner_transfers_account ON app_lab_owner_transfers(username, occurred_at DESC);
COMMENT ON TABLE app_lab_owner_transfers IS 'LAB transfer history; no fabricated initial history. Correlation ID equals the administrative audit event correlation ID.';
