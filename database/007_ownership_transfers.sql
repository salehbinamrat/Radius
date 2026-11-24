-- Explicit forward-only ownership transfer journal for laboratory vouchers.
-- No inferred past transfers, no modification of the existing ownership rows.
CREATE TABLE app_lab_ownership_transfers (
    username varchar(16) NOT NULL REFERENCES app_lab_account_owners(username) ON DELETE RESTRICT,
    revision bigint NOT NULL CHECK (revision > 0),
    previous_owner_id text NOT NULL REFERENCES "AspNetUsers"("Id") ON DELETE RESTRICT,
    new_owner_id text NOT NULL REFERENCES "AspNetUsers"("Id") ON DELETE RESTRICT,
    audit_event_id bigint NOT NULL UNIQUE REFERENCES app_admin_audit_events(id) ON DELETE RESTRICT,
    PRIMARY KEY (username, revision),
    CHECK (previous_owner_id <> new_owner_id)
);
COMMENT ON TABLE app_lab_ownership_transfers IS
    'Forward-only lab ownership journal linked to the administrative audit event; no synthetic history.';
