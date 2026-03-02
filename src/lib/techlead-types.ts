export interface Task {
  id: string;
  title: string;
  status: 'backlog' | 'in_progress' | 'review' | 'testing' | 'done' | 'failed';
  phase: 'plan' | 'exec' | 'review' | 'reviewed' | 'test' | 'tested' | 'completed' | null;
  review_passed?: boolean;
  test_passed?: boolean;
  review_attempts?: number;
  test_attempts?: number;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
}

export interface Current {
  task_id: string | null;
  phase: string | null;
}
