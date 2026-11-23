-- Phase 7A: metadata-only draft registry. Does not register RADIUS clients.
CREATE TABLE IF NOT EXISTS app_nas_drafts (
  id uuid PRIMARY KEY,
  label varchar(64) NOT NULL UNIQUE,
  site varchar(80) NOT NULL,
  vpn_ip inet NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz,
  CONSTRAINT nas_drafts_private_ipv4 CHECK (
    family(vpn_ip) = 4 AND masklen(vpn_ip) = 32 AND
    (vpn_ip <<= inet '10.0.0.0/8' OR
     vpn_ip <<= inet '172.16.0.0/12' OR
     vpn_ip <<= inet '192.168.0.0/16')
  )
);
CREATE TABLE IF NOT EXISTS app_nas_draft_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  draft_id uuid NOT NULL REFERENCES app_nas_drafts(id) ON DELETE RESTRICT,
  operation varchar(12) NOT NULL CHECK (operation IN ('created','retired')),
  happened_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_nas_drafts_created ON app_nas_drafts(created_at DESC);
COMMENT ON TABLE app_nas_drafts IS 'Draft-only inventory. No shared secrets, no router reachability checks, no RADIUS client registration.';
