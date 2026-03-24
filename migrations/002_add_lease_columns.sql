-- Migration 002: Add lease tracking columns for worker crash recovery
-- Note: lease_until already exists, adding leased_at and lease_heartbeat_at

ALTER TABLE tasks ADD COLUMN leased_at INTEGER;
ALTER TABLE tasks ADD COLUMN lease_heartbeat_at INTEGER;

-- Create index for efficient lease expiration queries
CREATE INDEX IF NOT EXISTS idx_tasks_lease_heartbeat ON tasks(lease_heartbeat_at);
CREATE INDEX IF NOT EXISTS idx_tasks_leased_at ON tasks(leased_at);
