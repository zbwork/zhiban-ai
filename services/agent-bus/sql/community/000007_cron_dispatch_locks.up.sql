-- Additive scheduler coordination; preserve definitions/history.
CREATE TABLE agent_bus.cron_dispatch_locks (
 job_id bigint PRIMARY KEY REFERENCES agent_bus.agent_cron_jobs(id) ON DELETE CASCADE,
 locked_by varchar(64) NOT NULL,
 locked_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 CONSTRAINT community_cron_lock_expiry CHECK (expires_at > locked_at)
);
COMMENT ON TABLE agent_bus.cron_dispatch_locks IS 'Community shared expiring task locks';
