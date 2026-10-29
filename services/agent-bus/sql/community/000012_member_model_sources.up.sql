-- ADR-0042 member model platforms synced from the client model service.
SET LOCAL search_path=agent_bus,public;

CREATE TABLE agent_bus.member_model_sources (
    uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id bigint NOT NULL REFERENCES agent_bus.tenants(id),
    account_id bigint NOT NULL REFERENCES agent_bus.accounts(id),
    source_id text NOT NULL CHECK (length(source_id) BETWEEN 1 AND 128),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    fingerprint text NOT NULL,
    enabled boolean NOT NULL DEFAULT false,
    config_ciphertext bytea NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, account_id, source_id)
);
COMMENT ON TABLE agent_bus.member_model_sources IS 'ADR-0042 当前成员的模型平台配置；按租户账号隔离，原始凭据加密，禁止消息携带明文';
COMMENT ON COLUMN agent_bus.member_model_sources.uuid IS '平台配置记录 UUID；模型引用携带它而非客户端平台 ID';
COMMENT ON COLUMN agent_bus.member_model_sources.tenant_id IS '所属租户；每次读取都按当前租户过滤';
COMMENT ON COLUMN agent_bus.member_model_sources.account_id IS '所属成员；不得从请求体接收';
COMMENT ON COLUMN agent_bus.member_model_sources.source_id IS '当前成员客户端平台 ID，不作为全局授权身份';
COMMENT ON COLUMN agent_bus.member_model_sources.version IS '配置变化递增；过期模型引用不得执行';
COMMENT ON COLUMN agent_bus.member_model_sources.fingerprint IS '服务端 HMAC 配置摘要；防止低熵凭据离线猜测';
COMMENT ON COLUMN agent_bus.member_model_sources.enabled IS '客户端是否启用该平台；禁用后其模型引用不可执行';
COMMENT ON COLUMN agent_bus.member_model_sources.config_ciphertext IS 'AES-256-GCM 配置与 API Key；仅 Bus 推理代理解密，不回显';
COMMENT ON COLUMN agent_bus.member_model_sources.updated_at IS '最后一次同步写入时间';
