SET LOCAL search_path=agent_bus,public;
-- 000034_runtime_call_logs.up.sql
-- F19: 可观测性 runtime 调用日志 — 记录 Bus 对 ZAP / 外部集成的每一次 HTTP 调用。

-- §1 runtime_call_logs 主表 (月分区)
CREATE TABLE runtime_call_logs (
    id                 bigint         GENERATED ALWAYS AS IDENTITY,
    uuid               uuid           NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          bigint         NOT NULL,
    account_id         bigint,
    trace_id           varchar(64),
    span_id            varchar(32),
    direction          varchar(16)    NOT NULL DEFAULT 'outbound',
    target_service     varchar(64)    NOT NULL,
    operation          varchar(128),
    runtime_environment_id bigint,
    digital_employee_id bigint,
    conversation_uuid  uuid,
    message_uuid       uuid,
    stream_id          varchar(128),
    method             varchar(8)     NOT NULL,
    path               varchar(512)   NOT NULL,
    http_status        smallint,
    grpc_code          smallint,
    latency_ms         integer        NOT NULL DEFAULT 0,
    request_body_json  jsonb          DEFAULT '{}'::jsonb,
    response_body_json jsonb          DEFAULT '{}'::jsonb,
    body_truncated     boolean        NOT NULL DEFAULT false,
    error_message      text,
    tags               jsonb          DEFAULT '{}'::jsonb,
    created_at         timestamptz    NOT NULL DEFAULT now(),

    CONSTRAINT runtime_call_logs_direction_check
        CHECK (direction IN ('outbound', 'inbound')),
    CONSTRAINT runtime_call_logs_method_check
        CHECK (method IN ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'))
) PARTITION BY RANGE (created_at);

COMMENT ON TABLE runtime_call_logs IS
    'F19: 出站 HTTP 调用日志 (月分区, 90 天 hot retention)。一行 = Bus 到 ZAP/外部集成的一次 HTTP 调用。';
COMMENT ON COLUMN runtime_call_logs.uuid IS '对外业务唯一标识';
COMMENT ON COLUMN runtime_call_logs.tenant_id IS '租户 ID';
COMMENT ON COLUMN runtime_call_logs.account_id IS '触发调用的用户 (可空, 系统调用无 account)';
COMMENT ON COLUMN runtime_call_logs.trace_id IS 'OTel trace ID (关联 Jaeger)';
COMMENT ON COLUMN runtime_call_logs.span_id IS 'OTel span ID';
COMMENT ON COLUMN runtime_call_logs.direction IS '调用方向: outbound(Bus→外部) / inbound(外部→Bus)';
COMMENT ON COLUMN runtime_call_logs.target_service IS '目标服务标识: zap / hermes / aigc 等';
COMMENT ON COLUMN runtime_call_logs.operation IS '业务操作标识: zap.dispatch / zap.session_create / external.openapi 等';
COMMENT ON COLUMN runtime_call_logs.runtime_environment_id IS '运行环境 ID, 用于按托管环境排障';
COMMENT ON COLUMN runtime_call_logs.digital_employee_id IS '数字员工 ID';
COMMENT ON COLUMN runtime_call_logs.conversation_uuid IS '会话 UUID';
COMMENT ON COLUMN runtime_call_logs.message_uuid IS '消息 UUID';
COMMENT ON COLUMN runtime_call_logs.stream_id IS '流式消息 stream_id';
COMMENT ON COLUMN runtime_call_logs.method IS 'HTTP method';
COMMENT ON COLUMN runtime_call_logs.path IS 'HTTP path (不含 host)';
COMMENT ON COLUMN runtime_call_logs.http_status IS 'HTTP 响应状态码';
COMMENT ON COLUMN runtime_call_logs.latency_ms IS '调用耗时 (毫秒)';
COMMENT ON COLUMN runtime_call_logs.request_body_json IS '请求体 (已脱敏; body_truncated=true 时已截断)';
COMMENT ON COLUMN runtime_call_logs.response_body_json IS '响应体 (已脱敏; body_truncated=true 时已截断)';
COMMENT ON COLUMN runtime_call_logs.body_truncated IS 'request/response body 是否因超限被截断';
COMMENT ON COLUMN runtime_call_logs.error_message IS '调用失败时的错误信息 (≤500 字符)';
COMMENT ON COLUMN runtime_call_logs.tags IS '扩展字段: agent_uuid / session_id / runtime_env_id 等';

-- §2 default partition (兜底; 月分区 cron 未创建当月分区时落这里)
CREATE TABLE runtime_call_logs_default PARTITION OF runtime_call_logs DEFAULT;

-- §3 indexes (建在父表上, 自动传播到所有分区)
CREATE INDEX idx_rcl_tenant_time  ON runtime_call_logs (tenant_id, created_at DESC);
CREATE INDEX idx_rcl_trace        ON runtime_call_logs (trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX idx_rcl_target_time  ON runtime_call_logs (target_service, created_at DESC);
CREATE INDEX idx_rcl_runtime_time ON runtime_call_logs (runtime_environment_id, created_at DESC) WHERE runtime_environment_id IS NOT NULL;
CREATE INDEX idx_rcl_message_time ON runtime_call_logs (message_uuid, created_at DESC) WHERE message_uuid IS NOT NULL;
CREATE INDEX idx_rcl_conversation_time ON runtime_call_logs (conversation_uuid, created_at DESC) WHERE conversation_uuid IS NOT NULL;
CREATE INDEX idx_rcl_stream_time ON runtime_call_logs (stream_id, created_at DESC) WHERE stream_id IS NOT NULL;
CREATE UNIQUE INDEX uq_rcl_uuid  ON runtime_call_logs (uuid, created_at);
