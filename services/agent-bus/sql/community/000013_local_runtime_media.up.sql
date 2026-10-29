-- Local Agent image submissions; at-most-once delivery with bounded temporary results.
SET LOCAL search_path=agent_bus,public;

CREATE TABLE agent_bus.local_runtime_media (
    run_uuid uuid NOT NULL REFERENCES agent_bus.local_runtime_tasks(uuid),
    operation_id char(64) NOT NULL CHECK (operation_id ~ '^[a-f0-9]{64}$'),
    request_hash char(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
    state varchar(16) NOT NULL CHECK (state IN ('submitting','completed','unknown','failed')),
    image bytea CHECK (image IS NULL OR octet_length(image) BETWEEN 1 AND 12582912),
    result_expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_uuid, operation_id),
    UNIQUE (run_uuid, request_hash),
    CHECK (image IS NULL OR (state='completed' AND result_expires_at IS NOT NULL))
);
CREATE INDEX local_runtime_media_expiry ON agent_bus.local_runtime_media (result_expires_at) WHERE image IS NOT NULL;
COMMENT ON TABLE agent_bus.local_runtime_media IS 'At-most-once local image submissions; uncertain submissions never automatically retried. Task join enforces tenant/account ownership.';
COMMENT ON COLUMN agent_bus.local_runtime_media.run_uuid IS 'Owning task and identity authority; mandatory tenant/account/fence join';
COMMENT ON COLUMN agent_bus.local_runtime_media.operation_id IS 'Stable helper operation digest; no local paths or prompts';
COMMENT ON COLUMN agent_bus.local_runtime_media.request_hash IS 'Canonical provider request digest; prevents recharging identical intent under a new operation ID';
COMMENT ON COLUMN agent_bus.local_runtime_media.state IS 'Durable claim before provider call; completed response can be replayed; unknown/submitting cannot resubmit';
COMMENT ON COLUMN agent_bus.local_runtime_media.image IS 'Bounded temporary validated PNG for delivery recovery; cleared after 24 hours; final files use normal artifact storage';
COMMENT ON COLUMN agent_bus.local_runtime_media.result_expires_at IS 'Temporary result TTL; expiry never removes submission tombstone';
COMMENT ON COLUMN agent_bus.local_runtime_media.created_at IS 'First submission claim timestamp';
COMMENT ON COLUMN agent_bus.local_runtime_media.updated_at IS 'Latest completion or uncertain result timestamp';
