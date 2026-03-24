-- Rollback 003: Remove running_tasks counter

DROP INDEX IF EXISTS idx_projects_running_tasks;

ALTER TABLE projects DROP COLUMN running_tasks;
