-- Migration 003: Add running_tasks counter to projects table

ALTER TABLE projects ADD COLUMN running_tasks INTEGER NOT NULL DEFAULT 0;

-- Create index for efficient project capacity checks
CREATE INDEX IF NOT EXISTS idx_projects_running_tasks ON projects(running_tasks);
