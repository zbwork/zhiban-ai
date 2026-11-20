SET LOCAL search_path=agent_bus,public;

ALTER TABLE a2a_approval_requests ALTER COLUMN parent_session_token_id DROP NOT NULL;

CREATE TABLE local_a2a_jobs (
    approval_id bigint PRIMARY KEY REFERENCES a2a_approval_requests(id),
    source_run_uuid uuid NOT NULL UNIQUE,
    task_text text NOT NULL CHECK (length(task_text) BETWEEN 1 AND 4000),
    queued_at timestamptz,
    started_at timestamptz,
    finished_at timestamptz
);
COMMENT ON TABLE local_a2a_jobs IS 'Binds a local collaboration approval to one authenticated source run. Bus claims approved jobs once.';
COMMENT ON COLUMN local_a2a_jobs.task_text IS 'User-directed work instruction for the destination runtime, cleared when the job settles.';
CREATE INDEX local_a2a_jobs_ready_idx ON local_a2a_jobs(queued_at) WHERE queued_at IS NOT NULL AND started_at IS NULL;
