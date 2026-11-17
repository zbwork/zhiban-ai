-- Shared overview dependencies; exact original table definitions and public EMP schemas.
SET LOCAL search_path=agent_bus,public;
--
-- Name: emp_block_registry; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.emp_block_registry (
    id bigint NOT NULL,
    code character varying(64) NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    name character varying(128) NOT NULL,
    category character varying(32) NOT NULL,
    json_schema jsonb NOT NULL,
    status character varying(32) DEFAULT 'draft'::character varying NOT NULL,
    min_client_version character varying(32),
    fallback_block_type character varying(64) DEFAULT 'markdown'::character varying NOT NULL,
    breaking_changes text,
    deprecated_at timestamp with time zone,
    eol_date date,
    description text,
    is_system boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT emp_block_registry_category_check CHECK (((category)::text = ANY (ARRAY[('content'::character varying)::text, ('interactive'::character varying)::text, ('process'::character varying)::text, ('artifact'::character varying)::text]))),
    CONSTRAINT emp_block_registry_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('stable'::character varying)::text, ('deprecated'::character varying)::text])))
);


--
-- Name: TABLE emp_block_registry; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.emp_block_registry IS 'EMP Block 类型注册表';


--
-- Name: COLUMN emp_block_registry.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.id IS '主键 ID';


--
-- Name: COLUMN emp_block_registry.code; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.code IS 'Block 编码 markdown/chart/form';


--
-- Name: COLUMN emp_block_registry.version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.version IS '协议版本号';


--
-- Name: COLUMN emp_block_registry.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.name IS '显示名';


--
-- Name: COLUMN emp_block_registry.category; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.category IS '类别 content/interactive/process/artifact';


--
-- Name: COLUMN emp_block_registry.json_schema; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.json_schema IS 'JSON Schema 校验定义';


--
-- Name: COLUMN emp_block_registry.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.status IS '状态 draft/stable/deprecated';


--
-- Name: COLUMN emp_block_registry.min_client_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.min_client_version IS '最低支持的客户端版本';


--
-- Name: COLUMN emp_block_registry.fallback_block_type; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.fallback_block_type IS '不支持时降级到的 Block 类型';


--
-- Name: COLUMN emp_block_registry.breaking_changes; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.breaking_changes IS '不兼容变更说明';


--
-- Name: COLUMN emp_block_registry.deprecated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.deprecated_at IS '废弃时间';


--
-- Name: COLUMN emp_block_registry.eol_date; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.eol_date IS '下线日期';


--
-- Name: COLUMN emp_block_registry.description; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.description IS '描述';


--
-- Name: COLUMN emp_block_registry.is_system; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.is_system IS '平台维护';


--
-- Name: COLUMN emp_block_registry.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.created_at IS '创建时间';


--
-- Name: COLUMN emp_block_registry.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.emp_block_registry.updated_at IS '更新时间';


--
-- Name: emp_block_registry_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.emp_block_registry ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.emp_block_registry_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: emp_block_registry emp_block_registry_code_version_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.emp_block_registry
    ADD CONSTRAINT emp_block_registry_code_version_key UNIQUE (code, version);


--
-- Name: emp_block_registry emp_block_registry_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.emp_block_registry
    ADD CONSTRAINT emp_block_registry_pkey PRIMARY KEY (id);



INSERT INTO agent_bus."emp_block_registry" ("id", "code", "version", "name", "category", "json_schema", "status", "min_client_version", "fallback_block_type", "breaking_changes", "deprecated_at", "eol_date", "description", "is_system", "created_at", "updated_at") OVERRIDING SYSTEM VALUE VALUES
('1', 'markdown', '1', 'Markdown', 'content', '{"type": "object", "properties": {"text": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '富文本', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('2', 'plain', '1', '纯文本', 'content', '{"type": "object", "properties": {"text": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '纯文本', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('3', 'chart', '1', '图表', 'content', '{"type": "object", "required": ["chart_kind"], "properties": {"data": {"type": "array"}, "unit": {"type": "string"}, "table": {"type": "object"}, "title": {"type": "string"}, "series": {"type": "array"}, "source": {"type": "string"}, "summary": {"type": "string"}, "insights": {"type": "array"}, "chart_kind": {"enum": ["bar", "line", "area", "pie", "donut", "scatter", "radar", "kpi", "mixed", "heatmap", "sankey", "candlestick", "map"], "type": "string"}, "updated_at": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '图表(chart_kind: bar/line/area/pie/donut/scatter/radar/kpi;复杂图走客户端富 fallback)', 'true', '2026-05-21 16:27:12.593121+08', '2026-07-02 00:00:00+08'),
('4', 'image', '1', '图片', 'content', '{"type": "object", "properties": {"alt": {"type": "string"}, "url": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '图片', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('5', 'video', '1', '视频', 'content', '{"type": "object", "properties": {"url": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '视频', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('6', 'audio', '1', '音频', 'content', '{"type": "object", "properties": {"url": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '音频', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('7', 'form', '1', '表单', 'interactive', '{"type": "object", "properties": {"fields": {"type": "array"}, "submit": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '表单', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('8', 'approval', '1', '审批卡片', 'interactive', '{"type": "object", "properties": {"title": {"type": "string"}, "actions": {"type": "array"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '审批卡片', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('9', 'action', '1', '操作按钮', 'interactive', '{"type": "object", "properties": {"buttons": {"type": "array"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '按钮组', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('10', 'suggestion', '1', '推荐回复', 'interactive', '{"type": "object", "properties": {"items": {"type": "array"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '快速回复', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('11', 'progress', '1', '进度', 'process', '{"type": "object", "properties": {"steps": {"type": "array"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '进度条/步骤', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('12', 'thought', '1', '思考过程', 'process', '{"type": "object", "properties": {"text": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '思考/Reasoning', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('13', 'reasoning', '1', '推理', 'process', '{"type": "object", "properties": {"text": {"type": "string"}}}', 'stable', '0.1.0', 'thought', NULL, NULL, NULL, '推理详情', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('14', 'tool_call', '1', '工具调用', 'process', '{"type": "object", "properties": {"tool": {"type": "string"}, "input": {"type": "object"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '工具调用', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('15', 'source', '1', '引用来源', 'process', '{"type": "object", "properties": {"items": {"type": "array"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '知识库引用', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('16', 'artifact', '1', '产物', 'artifact', '{"type": "object", "properties": {"data": {"type": "object"}, "kind": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '可下载的产物', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('17', 'file', '1', '文件', 'artifact', '{"type": "object", "properties": {"url": {"type": "string"}, "name": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '附件文件', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('18', 'app_card', '1', '应用卡片', 'interactive', '{"type": "object", "properties": {"app_code": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '应用入口卡片', 'true', '2026-05-21 16:27:12.593121+08', '2026-05-21 16:27:37.089948+08'),
('19', 'code', '1', '代码块', 'content', '{"type": "object", "properties": {"lang": {"type": "string"}, "text": {"type": "string"}, "source": {"type": "string"}, "content": {"type": "string"}, "language": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '代码高亮块', 'true', '2026-06-22 00:00:00+08', '2026-06-22 00:00:00+08'),
('20', 'table', '1', '表格', 'content', '{"type": "object", "properties": {"data": {"type": "array"}, "rows": {"type": "array"}, "title": {"type": "string"}, "columns": {"type": "array"}, "headers": {"type": "array"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '结构化表格', 'true', '2026-06-22 00:00:00+08', '2026-06-22 00:00:00+08'),
('21', 'confirm', '1', '二次确认', 'interactive', '{"type": "object", "properties": {"text": {"type": "string"}, "title": {"type": "string"}, "actions": {"type": "array"}, "summary": {"type": "string"}, "action_id": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '确认/取消类人机协同组件', 'true', '2026-06-22 00:00:00+08', '2026-06-22 00:00:00+08'),
('22', 'plan', '1', '计划', 'process', '{"type": "object", "properties": {"items": {"type": "array"}, "steps": {"type": "array"}, "title": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '计划与步骤', 'true', '2026-06-22 00:00:00+08', '2026-06-22 00:00:00+08'),
('23', 'error', '1', '内联错误', 'process', '{"type": "object", "properties": {"code": {"type": "string"}, "title": {"type": "string"}, "detail": {"type": "string"}, "message": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '可展示给用户的内联错误', 'true', '2026-06-22 00:00:00+08', '2026-06-22 00:00:00+08'),
('37', 'orchestration', '1', '协作编排', 'process', '{"type": "object", "required": ["plan_summary", "steps"], "properties": {"steps": {"type": "array", "items": {"type": "object", "required": ["step_index", "role", "status"], "properties": {"role": {"enum": ["planner", "worker", "reducer", "validator"], "type": "string"}, "status": {"enum": ["pending", "running", "done", "failed", "skipped"], "type": "string"}, "tokens_in": {"type": "integer"}, "agent_name": {"type": "string"}, "agent_uuid": {"type": "string"}, "started_at": {"type": "string"}, "step_index": {"type": "integer"}, "tokens_out": {"type": "integer"}, "completed_at": {"type": "string"}, "error_message": {"type": "string"}, "input_summary": {"type": "string"}, "output_summary": {"type": "string"}}}}, "plan_summary": {"type": "string"}, "total_tokens_in": {"type": "integer"}, "total_latency_ms": {"type": "integer"}, "total_tokens_out": {"type": "integer"}, "default_collapsed": {"type": "boolean"}}}', 'stable', '1.0.0', 'markdown', NULL, NULL, NULL, '主-子 Agent 编排折叠视图 (default_collapsed=true)', 'true', '2026-05-27 17:55:34.342248+08', '2026-05-27 17:55:34.342248+08'),
('38', 'tool_result', '1', '工具结果', 'process', '{"type": "object", "properties": {"tool": {"type": "string"}, "output": {"type": "string"}, "status": {"type": "string"}, "tool_call_id": {"type": "string"}}}', 'stable', '0.1.0', 'markdown', NULL, NULL, NULL, '工具调用结果', 'true', '2026-06-11 22:33:56.614335+08', '2026-06-11 22:33:56.614335+08');
SELECT pg_catalog.setval(pg_get_serial_sequence('agent_bus.emp_block_registry','id'), GREATEST((SELECT max(id) FROM agent_bus.emp_block_registry),1),true);
SET search_path TO agent_bus, public;

-- 000088_agent_runs_observability.up.sql
-- F24 P0: Agent 运行监测与会话可观测性 — agent_runs / agent_run_steps 运行轨迹表
-- + usage_events 归因提取列 + L3 内容权限 + 「审计与合规」菜单。
-- 设计：docs/features/F24-observability-agent-runs.md §2-§6（v0.4 已拍板，D1-D10）。

-- §1 agent_runs 主表（月分区）。一行 = 一次 agent 执行（锚点 = 一条 agent 回复消息）。
-- 幂等键 = (message_uuid, created_at)：finalize 重试 / HITL 恢复 / 对账补写均 upsert 同一行（D7）。
CREATE TABLE agent_runs (
    id                     bigint      GENERATED ALWAYS AS IDENTITY,
    uuid                   uuid        NOT NULL DEFAULT gen_random_uuid(),
    tenant_id              bigint      NOT NULL,
    account_id             bigint,
    digital_employee_id    bigint      NOT NULL,
    conversation_uuid      uuid,
    message_uuid           uuid        NOT NULL,
    stream_id              varchar(128),
    room_id                bigint,
    runtime_kind           varchar(32) NOT NULL,
    runtime_environment_id bigint,
    runtime_instance_id    uuid,
    trigger_source         varchar(16) NOT NULL DEFAULT 'chat',
    status                 varchar(16) NOT NULL DEFAULT 'running',
    started_at             timestamptz NOT NULL,
    completed_at           timestamptz,
    duration_ms            integer,
    first_output_ms        integer,
    thinking_ms            integer,
    hitl_wait_ms           integer,
    tool_call_count        integer     NOT NULL DEFAULT 0,
    tool_error_count       integer     NOT NULL DEFAULT 0,
    a2a_edge_count         integer     NOT NULL DEFAULT 0,
    input_tokens           bigint,
    output_tokens          bigint,
    total_tokens           bigint,
    usage_source           varchar(16) NOT NULL DEFAULT 'none',
    model                  varchar(128),
    agent_version_id       bigint,
    root_a2a_edge_uuid     uuid,
    error_code             varchar(64),
    error_message          text,
    trace_id               varchar(64),
    tags                   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT agent_runs_runtime_kind_check
        CHECK (runtime_kind IN ('openclaw', 'hermes', 'zap_external', 'builtin_llm', 'unknown')),
    CONSTRAINT agent_runs_trigger_source_check
        CHECK (trigger_source IN ('chat', 'room', 'a2a', 'debug', 'cron', 'rtc')),
    CONSTRAINT agent_runs_status_check
        CHECK (status IN ('running', 'awaiting_user', 'completed', 'failed', 'cancelled')),
    CONSTRAINT agent_runs_usage_source_check
        CHECK (usage_source IN ('runtime', 'none'))
) PARTITION BY RANGE (created_at);

COMMENT ON TABLE agent_runs IS
    'F24: Agent 运行轨迹 (月分区, 默认 6 个月 retention)。一行 = 一次 agent 执行, 锚点 message_uuid; 只存元数据不存正文 (D1)。';
COMMENT ON COLUMN agent_runs.uuid IS '对外业务唯一标识';
COMMENT ON COLUMN agent_runs.tenant_id IS '租户 ID (租户侧查询强隔离)';
COMMENT ON COLUMN agent_runs.account_id IS '触发人 (可空: a2a 被调 / cron 无人触发)';
COMMENT ON COLUMN agent_runs.digital_employee_id IS '执行的数字员工 ID';
COMMENT ON COLUMN agent_runs.message_uuid IS '锚点: agent 回复消息 UUID; 业务幂等键 (D7)';
COMMENT ON COLUMN agent_runs.room_id IS '群聊场景所属 room';
COMMENT ON COLUMN agent_runs.runtime_kind IS '运行时类型: openclaw/hermes/zap_external/builtin_llm';
COMMENT ON COLUMN agent_runs.trigger_source IS '触发来源: chat/room/a2a (P0) + debug/cron/rtc (P1+ 预留)';
COMMENT ON COLUMN agent_runs.status IS '运行状态: running/awaiting_user/completed/failed/cancelled (终态语义对齐 messages.status)';
COMMENT ON COLUMN agent_runs.started_at IS 'Bus 观察时钟: 派发运行时时刻 (D2)';
COMMENT ON COLUMN agent_runs.duration_ms IS '总耗时 (不含 hitl_wait_ms, 口径见 F24 §3.4)';
COMMENT ON COLUMN agent_runs.first_output_ms IS '首个可见输出延迟';
COMMENT ON COLUMN agent_runs.thinking_ms IS '思考累计时长 (runtime 不透出则 NULL, 正文不落库 O3)';
COMMENT ON COLUMN agent_runs.hitl_wait_ms IS 'HITL awaiting_user 等待累计 (多轮求和)';
COMMENT ON COLUMN agent_runs.total_tokens IS '运行时上报口径 token (非计费权威, D3); NULL=runtime 未上报';
COMMENT ON COLUMN agent_runs.usage_source IS 'token 来源: runtime=运行时上报 / none=未上报';
COMMENT ON COLUMN agent_runs.model IS '主模型名 (runtime 上报; 诊断维度)';
COMMENT ON COLUMN agent_runs.agent_version_id IS '执行时数字员工版本 (版本回归对比用)';
COMMENT ON COLUMN agent_runs.root_a2a_edge_uuid IS '本 run 由哪条 A2A 边触发 (被调场景)';
COMMENT ON COLUMN agent_runs.error_message IS '失败留痕 (落库前已 redact, ≤500 字符, D9)';
COMMENT ON COLUMN agent_runs.tags IS '扩展 (白名单键: backfilled/chain_budget 等, D9)';

CREATE TABLE agent_runs_default PARTITION OF agent_runs DEFAULT;

CREATE INDEX idx_ar_tenant_time      ON agent_runs (tenant_id, started_at DESC);
CREATE INDEX idx_ar_tenant_agent     ON agent_runs (tenant_id, digital_employee_id, started_at DESC);
CREATE INDEX idx_ar_conversation     ON agent_runs (conversation_uuid, started_at DESC) WHERE conversation_uuid IS NOT NULL;
CREATE INDEX idx_ar_status_time      ON agent_runs (status, started_at DESC);
CREATE INDEX idx_ar_trace            ON agent_runs (trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX idx_ar_tenant_duration  ON agent_runs (tenant_id, duration_ms DESC) WHERE duration_ms IS NOT NULL;
CREATE INDEX idx_ar_root_edge        ON agent_runs (root_a2a_edge_uuid) WHERE root_a2a_edge_uuid IS NOT NULL;
CREATE UNIQUE INDEX uq_ar_uuid       ON agent_runs (uuid, created_at);
CREATE UNIQUE INDEX uq_ar_message    ON agent_runs (message_uuid, created_at);

-- §2 agent_run_steps（月分区）。一行 = 运行内一个步骤; 只存元数据 (D1)。
-- steps.created_at 恒等于所属 run 的 created_at → 同 run 全部行落同一分区,
-- (run_uuid, seq, created_at) 幂等键在重试时可命中。
CREATE TABLE agent_run_steps (
    id             bigint       GENERATED ALWAYS AS IDENTITY,
    uuid           uuid         NOT NULL DEFAULT gen_random_uuid(),
    tenant_id      bigint       NOT NULL,
    run_uuid       uuid         NOT NULL,
    seq            integer      NOT NULL,
    step_kind      varchar(24)  NOT NULL,
    name           varchar(256) NOT NULL DEFAULT '',
    status         varchar(16)  NOT NULL DEFAULT 'running',
    started_at     timestamptz  NOT NULL,
    ended_at       timestamptz,
    duration_ms    integer,
    ref_kind       varchar(32),
    ref_uuid       varchar(128),
    ref_created_at timestamptz,
    error_message  text,
    attrs          jsonb        NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT agent_run_steps_kind_check
        CHECK (step_kind IN ('thinking', 'tool_call', 'a2a_invoke', 'kb_retrieval', 'hitl_wait', 'stage')),
    CONSTRAINT agent_run_steps_status_check
        CHECK (status IN ('running', 'ok', 'error', 'cancelled'))
) PARTITION BY RANGE (created_at);

COMMENT ON TABLE agent_run_steps IS
    'F24: 运行步骤明细 (月分区)。只存元数据; 正文经 ref_kind/ref_uuid 回查原表 (messages.blocks / a2a_call_edges)。';
COMMENT ON COLUMN agent_run_steps.run_uuid IS '所属 agent_runs.uuid';
COMMENT ON COLUMN agent_run_steps.seq IS '运行内序号 (时间线排序; 与 run_uuid+created_at 组成幂等键)';
COMMENT ON COLUMN agent_run_steps.step_kind IS '步骤类型: thinking/tool_call/a2a_invoke/kb_retrieval/hitl_wait/stage';
COMMENT ON COLUMN agent_run_steps.name IS '工具名/被调 agent 名/KB 名 (仅标识符, 禁拼参数, D9)';
COMMENT ON COLUMN agent_run_steps.ref_kind IS '明细引用类型: message_block/a2a_edge/runtime_call_log/kb_recall_log';
COMMENT ON COLUMN agent_run_steps.ref_uuid IS '明细引用 ID (tool_call_id / edge uuid 等)';
COMMENT ON COLUMN agent_run_steps.ref_created_at IS '引用目标行的分区键, 跨月分区回查精确定位 (codex P2)';
COMMENT ON COLUMN agent_run_steps.error_message IS '错误摘要 (落库前已 redact, ≤500 字符, D9)';
COMMENT ON COLUMN agent_run_steps.attrs IS '白名单键结构化属性 (tool_category/kb_hit_count/a2a_invoke_kind 等, 非白名单键写入即丢弃, D9)';
COMMENT ON COLUMN agent_run_steps.created_at IS '分区键; 恒等于所属 run 的 created_at';

CREATE TABLE agent_run_steps_default PARTITION OF agent_run_steps DEFAULT;

CREATE UNIQUE INDEX uq_ars_run_seq   ON agent_run_steps (run_uuid, seq, created_at);
CREATE UNIQUE INDEX uq_ars_uuid      ON agent_run_steps (uuid, created_at);
CREATE INDEX idx_ars_tenant_kind     ON agent_run_steps (tenant_id, step_kind, started_at DESC);
CREATE INDEX idx_ars_tenant_name     ON agent_run_steps (tenant_id, name, started_at DESC) WHERE name <> '';
CREATE INDEX idx_ars_ref             ON agent_run_steps (ref_uuid) WHERE ref_uuid IS NOT NULL;


-- F25 告警中心：alerts（告警实体）+ alert_rule_state（评估器连击状态）
-- 设计权威：docs/features/F25-alert-center-and-admin-visibility.md §2-§3
-- 写主体：cmd/worker 评估器（创建/累加/自动恢复）+ Admin（acknowledge/人工 resolve）；Bus 不读不写（边界文档 §4 已登记）。
-- 不分区：低基数运营数据（活跃告警 <10^3），远低于 ADR 0002 分区阈值。
SET search_path TO agent_bus, public;

CREATE TABLE alerts (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    uuid              UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    scope_kind        VARCHAR(16) NOT NULL CHECK (scope_kind IN ('platform', 'tenant')),
    tenant_id         BIGINT,
    source_kind       VARCHAR(32) NOT NULL CHECK (source_kind IN ('agent_run', 'runtime', 'kb_provider', 'cron', 'drive_worker', 'outbox', 'billing')),
    alert_type        VARCHAR(64) NOT NULL,
    severity          VARCHAR(16) NOT NULL CHECK (severity IN ('warning', 'critical')),
    status            VARCHAR(16) NOT NULL DEFAULT 'firing' CHECK (status IN ('firing', 'acknowledged', 'resolved')),
    fingerprint       TEXT NOT NULL,
    title             VARCHAR(256) NOT NULL,
    summary           TEXT NOT NULL DEFAULT '',
    resource_kind     VARCHAR(32) NOT NULL DEFAULT '',
    resource_uuid     TEXT NOT NULL DEFAULT '',
    first_triggered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_triggered_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    occurrence_count  INT NOT NULL DEFAULT 1,
    acknowledged_by   BIGINT,
    acknowledged_at   TIMESTAMPTZ,
    resolved_at       TIMESTAMPTZ,
    resolved_by       BIGINT,
    context           JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT alerts_tenant_scope_check CHECK (scope_kind <> 'tenant' OR tenant_id IS NOT NULL)
);

COMMENT ON TABLE alerts IS 'F25 告警实体：评估器按内置规则创建/累加/自动恢复；Admin 确认与人工恢复。状态机 firing→acknowledged→resolved（resolved 终态）。';
COMMENT ON COLUMN alerts.scope_kind IS '责任范围：platform=平台运维处置（基础设施类）；tenant=租户可见（本租户运行/计费/配额）';
COMMENT ON COLUMN alerts.tenant_id IS 'scope_kind=tenant 时必填；platform 告警可为 NULL（全平台）或带租户归属';
COMMENT ON COLUMN alerts.fingerprint IS '去重指纹 = alert_type + 资源维度；未恢复态内唯一（partial unique）';
COMMENT ON COLUMN alerts.occurrence_count IS '同 fingerprint 持续命中累计次数（去重累加，不新增行）';
COMMENT ON COLUMN alerts.resolved_by IS 'NULL=评估器自动恢复；非 NULL=管理员人工标记恢复（写审计）';
COMMENT ON COLUMN alerts.context IS '白名单键结构化上下文（观测值/阈值/窗口/下钻参数）；禁止请求正文、会话正文、密钥';

-- 未恢复告警的去重键：同一异常只存在一行未恢复告警
CREATE UNIQUE INDEX uq_alerts_open_fingerprint ON alerts (fingerprint) WHERE status <> 'resolved';
CREATE INDEX idx_alerts_scope_status_time ON alerts (scope_kind, status, last_triggered_at DESC);
CREATE INDEX idx_alerts_tenant_status_time ON alerts (tenant_id, status, last_triggered_at DESC) WHERE tenant_id IS NOT NULL;
CREATE INDEX idx_alerts_type_status ON alerts (alert_type, status);

CREATE TABLE alert_rule_state (
    rule_key            VARCHAR(64) NOT NULL,
    resource_key        TEXT NOT NULL,
    consecutive_hits    INT NOT NULL DEFAULT 0,
    consecutive_misses  INT NOT NULL DEFAULT 0,
    last_evaluated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (rule_key, resource_key)
);

COMMENT ON TABLE alert_rule_state IS 'F25 评估器连击状态：瞬时信号（run 失败率/provider 探活）需连续 K 轮命中才建告警、连续 M 轮未命中自动恢复；worker 重启不丢状态。行数=活跃资源数，自然有界。';

ALTER TABLE agent_bus.agent_runs DROP CONSTRAINT agent_runs_runtime_kind_check;
ALTER TABLE agent_bus.agent_runs ADD CONSTRAINT agent_runs_runtime_kind_check CHECK (runtime_kind IN ('openclaw','hermes','zap_external','dsh','codex_app_server','builtin_llm','unknown'));
