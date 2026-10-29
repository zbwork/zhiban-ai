-- Local Agent transport for community: devices, tasks, events and approvals.
SET LOCAL search_path=agent_bus,public;

CREATE TABLE agent_bus.local_runtime_devices (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id bigint NOT NULL REFERENCES agent_bus.tenants(id),
    account_id bigint NOT NULL REFERENCES agent_bus.accounts(id),
    login_session_uuid uuid NOT NULL,
    public_key text CHECK (length(public_key) BETWEEN 40 AND 64),
    installation_id uuid,
    platform varchar(16) NOT NULL CHECK (platform IN ('darwin','win32')),
    generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
    protocol_version integer NOT NULL DEFAULT 1 CHECK (protocol_version IN (1,2)),
    engines jsonb NOT NULL DEFAULT '{"dsh":"legacy"}'::jsonb CHECK (jsonb_typeof(engines)='object'),
    seen_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, account_id, login_session_uuid)
);
COMMENT ON TABLE agent_bus.local_runtime_devices IS 'Local Agent: login-session-bound installation identity; no primary-device or multi-device scheduler semantics.';
COMMENT ON COLUMN agent_bus.local_runtime_devices.uuid IS 'Opaque device identity, scoped to this login and tenant';
COMMENT ON COLUMN agent_bus.local_runtime_devices.tenant_id IS 'Owning tenant; checked on every control-plane operation';
COMMENT ON COLUMN agent_bus.local_runtime_devices.account_id IS 'Owning member; never accepted from a request body';
COMMENT ON COLUMN agent_bus.local_runtime_devices.login_session_uuid IS 'Authoritative login_sessions UUID; revocation/expiry/scope checked by joins';
COMMENT ON COLUMN agent_bus.local_runtime_devices.public_key IS 'Legacy development Ed25519 public key; unused by session-ticket authentication';
COMMENT ON COLUMN agent_bus.local_runtime_devices.installation_id IS 'Non-secret client installation UUID; bound once by the authenticated desktop session';
COMMENT ON COLUMN agent_bus.local_runtime_devices.platform IS 'Release target platform, darwin or win32; not proof that isolation passed';
COMMENT ON COLUMN agent_bus.local_runtime_devices.generation IS 'Monotonic connection fence; old connections cannot submit heartbeats/events';
COMMENT ON COLUMN agent_bus.local_runtime_devices.protocol_version IS 'Version 2 requires Bus-authoritative approvals and supports mobile task sources; legacy devices cannot receive remote tasks.';
COMMENT ON COLUMN agent_bus.local_runtime_devices.engines IS 'Desktop-probed available engines mapped to pinned versions; names and versions only';
COMMENT ON COLUMN agent_bus.local_runtime_devices.seen_at IS 'Server clock of last valid device heartbeat; 15 second online window';
COMMENT ON COLUMN agent_bus.local_runtime_devices.revoked_at IS 'Explicit local-runtime revocation, in addition to login-session revocation';
COMMENT ON COLUMN agent_bus.local_runtime_devices.created_at IS 'Server creation timestamp';

CREATE TABLE agent_bus.local_runtime_tasks (
    uuid uuid PRIMARY KEY,
    device_uuid uuid NOT NULL REFERENCES agent_bus.local_runtime_devices(uuid),
    tenant_id bigint NOT NULL REFERENCES agent_bus.tenants(id),
    account_id bigint NOT NULL REFERENCES agent_bus.accounts(id),
    login_session_uuid uuid NOT NULL,
    requester_session_uuid uuid,
    digital_employee_id bigint NOT NULL REFERENCES agent_bus.digital_employees(id),
    conversation_uuid uuid NOT NULL,
    message_uuid uuid NOT NULL UNIQUE,
    stream_id varchar(128) NOT NULL UNIQUE,
    fence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
    model varchar(1024) NOT NULL CHECK (length(model) > 0),
    local_engine varchar(24) NOT NULL DEFAULT 'dsh' CHECK (local_engine IN ('dsh','codex_app_server')),
    status varchar(16) NOT NULL DEFAULT 'dispatched' CHECK (status IN ('dispatched','accepted','completed','failed','cancelled')),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload)='object'),
    token_hash char(64) NOT NULL,
    expires_at timestamptz NOT NULL,
    last_seq bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    settled_at timestamptz
);
CREATE UNIQUE INDEX local_runtime_tasks_active_conversation ON agent_bus.local_runtime_tasks (tenant_id, account_id, conversation_uuid) WHERE status IN ('dispatched','accepted');
CREATE INDEX local_runtime_tasks_delivery ON agent_bus.local_runtime_tasks (device_uuid, status, created_at);
COMMENT ON TABLE agent_bus.local_runtime_tasks IS 'Local Agent durable delivery ledger: created only while a device is online; retransmission is same-task idempotent, never cloud fallback.';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.uuid IS 'Server-generated run UUID';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.device_uuid IS 'One exact destination device; never retargeted';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.tenant_id IS 'Authoritative tenant scope';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.account_id IS 'Triggering member';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.login_session_uuid IS 'Exact desktop login session that authorized dispatch';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.requester_session_uuid IS 'Authenticated initiating session; NULL on legacy desktop tasks; execution session remains login_session_uuid.';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.digital_employee_id IS 'Private personal local employee owned by the member';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.conversation_uuid IS 'Existing chat conversation, not a separate local-agent chat';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.message_uuid IS 'Existing assistant message and idempotent delivery anchor';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.stream_id IS 'Existing message stream consumed by the ordinary chat UI';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.fence IS 'Server-issued execution fence; only equality is valid';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.model IS 'Opaque model reference chosen on the client; the server never holds its credentials (maximum 1024 characters)';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.local_engine IS 'Server-resolved employee engine snapshot, immutable for the task';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.status IS 'Transport/run status; terminal states cannot be overwritten';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.payload IS 'Public ZAP task context; excludes credentials and all local filesystem paths';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.token_hash IS 'SHA-256 of run-scoped capability; no plaintext credentials';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.expires_at IS 'Server-authoritative hard task deadline';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.last_seq IS 'Highest contiguous committed event sequence';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.created_at IS 'Server dispatch time';
COMMENT ON COLUMN agent_bus.local_runtime_tasks.settled_at IS 'First terminal transition time';

CREATE TABLE agent_bus.local_runtime_events (
    run_uuid uuid NOT NULL REFERENCES agent_bus.local_runtime_tasks(uuid),
    seq bigint NOT NULL CHECK (seq > 0),
    event varchar(64) NOT NULL CHECK (event IN ('message.created','message.block.delta','message.reasoning','message.tool_call','message.tool_result','message.completed','message.failed','message.cancelled')),
    data jsonb NOT NULL CHECK (jsonb_typeof(data)='object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_uuid, seq)
);
COMMENT ON TABLE agent_bus.local_runtime_events IS 'ZAP business events only; committed before ACK; bounded retention follows chat transport policy.';
COMMENT ON COLUMN agent_bus.local_runtime_events.run_uuid IS 'Owning local task';
COMMENT ON COLUMN agent_bus.local_runtime_events.seq IS 'Contiguous sequence, with duplicates checked for identical contents';
COMMENT ON COLUMN agent_bus.local_runtime_events.event IS 'Allowlisted ZAP event name, never a native engine event';
COMMENT ON COLUMN agent_bus.local_runtime_events.data IS 'Validated business payload; no device or model credentials';
COMMENT ON COLUMN agent_bus.local_runtime_events.created_at IS 'Server receipt time';

CREATE TABLE agent_bus.local_runtime_approvals (
    uuid uuid PRIMARY KEY,
    run_uuid uuid NOT NULL REFERENCES agent_bus.local_runtime_tasks(uuid),
    fence bigint NOT NULL CHECK (fence > 0),
    revision integer NOT NULL CHECK (revision > 0),
    intent_hash char(64) NOT NULL CHECK (intent_hash ~ '^[a-f0-9]{64}$'),
    display jsonb NOT NULL CHECK (jsonb_typeof(display)='object'),
    status varchar(16) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired')),
    decision_scope varchar(8) NOT NULL DEFAULT 'once' CHECK (decision_scope IN ('once','task')),
    expires_at timestamptz NOT NULL,
    decided_by_session uuid,
    decided_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX local_runtime_approvals_run ON agent_bus.local_runtime_approvals (run_uuid, created_at);
COMMENT ON TABLE agent_bus.local_runtime_approvals IS 'Shared desktop/mobile operation approvals. First valid decision wins; helper revalidates intent and lease before executing.';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.uuid IS 'Helper-generated immutable approval ID';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.run_uuid IS 'Owning task; identity and tenant inherited through mandatory join';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.fence IS 'Exact execution fence, never a range';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.revision IS 'Local policy revision bound to this request';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.intent_hash IS 'SHA-256 of full local intent; raw arguments remain on device';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.display IS 'Allowlisted operation/tool/target summary; no content, secrets or absolute local paths';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.status IS 'Single decision, with effective expiry also derived from task/lease state';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.decision_scope IS 'Once, or identical-intent grant for current run; upload always once';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.expires_at IS 'Deadline bounded by task deadline and two minutes';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.decided_by_session IS 'Authenticated session deciding the request';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.decided_at IS 'Server time of the winning decision';
COMMENT ON COLUMN agent_bus.local_runtime_approvals.created_at IS 'Server registration time';
