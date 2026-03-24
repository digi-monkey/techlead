-- Rollback 002: Remove lease tracking columns

DROP INDEX IF EXISTS idx_tasks_lease_heartbeat;
DROP INDEX IF EXISTS idx_tasks_leased_at;

ALTER TABLE tasks DROP COLUMN leased_at;
ALTER TABLE tasks DROP COLUMN lease_heartbeat_at;
