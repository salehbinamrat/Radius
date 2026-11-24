-- Canonical rows, stable UTC formatting and deterministic ordering.
-- Pipe directly to SHA-256: never log row text or include credentials, hashes,
-- session tokens, RADIUS attributes or request payloads in this fingerprint.
SET TIME ZONE 'UTC';
SET DateStyle TO 'ISO, YMD';
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_build_array('audit',id,actor_user_id,action,subject_kind,subject_id,
                         outcome,occurred_at,correlation_id)::text
FROM public.app_admin_audit_events ORDER BY id;
SELECT jsonb_build_array('transfer',id,username,previous_owner_id,new_owner_id,
                         actor_user_id,previous_version,new_version,occurred_at)::text
FROM public.app_lab_owner_transfers ORDER BY id;
SELECT jsonb_build_array('owner',username,owner_user_id,assigned_at,ownership_version)::text
FROM public.app_lab_account_owners ORDER BY username COLLATE "C";
COMMIT;
