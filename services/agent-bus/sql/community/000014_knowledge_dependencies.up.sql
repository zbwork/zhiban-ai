-- Restore existing upstream KB dependencies omitted from the community export.
-- Source: upstream 000001 schema, 000076 quota guards, 000092 scope contract.
SET LOCAL search_path = agent_bus, public;

CREATE TABLE agent_bus.kb_chunks (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    kb_id bigint NOT NULL,
    document_id bigint NOT NULL,
    chunk_index integer NOT NULL,
    content text NOT NULL,
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple'::regconfig, content)) STORED,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

COMMENT ON TABLE agent_bus.kb_chunks IS 'M8 Phase A · stub provider 物理 chunk 表; tsv 为 GENERATED + GIN; Dify 接入后该表不再写新行, 保留作为 fallback';

COMMENT ON COLUMN agent_bus.kb_chunks.id IS '主键 ID';

COMMENT ON COLUMN agent_bus.kb_chunks.uuid IS '对外业务唯一标识 (= provider_doc_id 的 chunk 维度参考)';

COMMENT ON COLUMN agent_bus.kb_chunks.kb_id IS '所属 knowledge_bases.id';

COMMENT ON COLUMN agent_bus.kb_chunks.document_id IS '所属 kb_documents.id';

COMMENT ON COLUMN agent_bus.kb_chunks.chunk_index IS '同文档内的 chunk 序号 (从 0 起)';

COMMENT ON COLUMN agent_bus.kb_chunks.content IS 'chunk 原文 (Phase A 切片策略: paragraph + 1000 字符硬切, 见 docs/tasks/m8-knowledge-bases.md §4.3)';

COMMENT ON COLUMN agent_bus.kb_chunks.tsv IS '全文检索向量, GENERATED ALWAYS AS to_tsvector(''simple'', content) STORED';

COMMENT ON COLUMN agent_bus.kb_chunks.metadata IS '扩展 metadata JSON';

COMMENT ON COLUMN agent_bus.kb_chunks.created_at IS '创建时间';

ALTER TABLE agent_bus.kb_chunks ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.kb_chunks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE agent_bus.kb_ingest_jobs (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    kb_id bigint NOT NULL,
    document_id bigint,
    job_kind character varying(32) NOT NULL,
    status character varying(32) DEFAULT 'pending'::character varying NOT NULL,
    progress smallint DEFAULT 0 NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_message text,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

COMMENT ON TABLE agent_bus.kb_ingest_jobs IS '知识库导入任务';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.id IS '主键 ID';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.uuid IS '对外业务唯一标识';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.kb_id IS '知识库 ID';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.document_id IS '文档 ID';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.job_kind IS '任务类型 upload/sync/recrawl';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.status IS '状态 pending/running/done/failed';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.progress IS '进度 0-100';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.payload IS '任务参数 JSON';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.error_message IS '错误信息';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.started_at IS '开始时间';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.finished_at IS '结束时间';

COMMENT ON COLUMN agent_bus.kb_ingest_jobs.created_at IS '创建时间';

ALTER TABLE agent_bus.kb_ingest_jobs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.kb_ingest_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE agent_bus.kb_outbox_events (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id bigint NOT NULL,
    op character varying(32) NOT NULL,
    payload jsonb NOT NULL,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    next_retry_at timestamp with time zone DEFAULT now() NOT NULL,
    last_error text,
    completed_at timestamp with time zone,
    locked_by character varying(64),
    locked_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT kb_outbox_events_op_check CHECK (((op)::text = ANY (ARRAY[('delete_dataset'::character varying)::text, ('delete_document'::character varying)::text, ('tenant_cleanup_datasets'::character varying)::text, ('tenant_cleanup_user'::character varying)::text, ('reconcile_provision'::character varying)::text]))),
    CONSTRAINT kb_outbox_events_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text, ('done'::character varying)::text, ('failed'::character varying)::text, ('dlq'::character varying)::text])))
);

COMMENT ON TABLE agent_bus.kb_outbox_events IS 'F07 D8: KB 删除 / 租户 cleanup / provision reconcile 的异步事件 outbox; agent-bus 事务先成, worker 推 RAGFlow';

COMMENT ON COLUMN agent_bus.kb_outbox_events.op IS 'delete_dataset=删单 KB; delete_document=删单文档; tenant_cleanup_*=租户硬删 30 天后级联; reconcile_provision=provision 失败重试';

COMMENT ON COLUMN agent_bus.kb_outbox_events.payload IS 'op 相关数据: {kb_uuid, ragflow_dataset_id, ...} 或 {tenant_id, ragflow_email}';

COMMENT ON COLUMN agent_bus.kb_outbox_events.status IS 'pending → running → done; 失败回 failed (有 next_retry_at) 或 dlq (attempts >= 3)';

COMMENT ON COLUMN agent_bus.kb_outbox_events.attempts IS '尝试次数, 失败时递增, exp backoff 计算 next_retry_at';

COMMENT ON COLUMN agent_bus.kb_outbox_events.locked_by IS 'worker uuid, SKIP LOCKED 配合防多实例并发';

COMMENT ON COLUMN agent_bus.kb_outbox_events.locked_until IS '锁过期时间, 超时其他 worker 可抢占';

ALTER TABLE agent_bus.kb_outbox_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.kb_outbox_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE agent_bus.kb_recall_logs (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint,
    agent_id bigint,
    kb_id bigint NOT NULL,
    caller_kind character varying(16) NOT NULL,
    conversation_uuid character varying(64),
    query_text text NOT NULL,
    top_k smallint NOT NULL,
    threshold numeric(8,4) NOT NULL,
    chunk_hits smallint NOT NULL,
    score_top numeric(8,4),
    latency_ms integer,
    error_code character varying(64),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT kb_recall_logs_caller_kind_check CHECK (((caller_kind)::text = ANY (ARRAY[('user'::character varying)::text, ('agent'::character varying)::text, ('admin'::character varying)::text])))
)
PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE agent_bus.kb_recall_logs IS 'M8 Phase A · KB 召回审计; PARTITION BY RANGE(occurred_at) 月分区; Phase B 接 M10 统一 audit pipeline 后可冻该表';

COMMENT ON COLUMN agent_bus.kb_recall_logs.id IS '主键 ID (与 occurred_at 组合 PK)';

COMMENT ON COLUMN agent_bus.kb_recall_logs.uuid IS '对外业务唯一标识';

COMMENT ON COLUMN agent_bus.kb_recall_logs.occurred_at IS '召回发生时间, 分区键';

COMMENT ON COLUMN agent_bus.kb_recall_logs.tenant_id IS '租户 ID';

COMMENT ON COLUMN agent_bus.kb_recall_logs.account_id IS 'user 调时记录, agent 调时为 NULL';

COMMENT ON COLUMN agent_bus.kb_recall_logs.agent_id IS 'agent (digital_employees.id) 调时记录, user 调时为 NULL';

COMMENT ON COLUMN agent_bus.kb_recall_logs.kb_id IS '被召回的 knowledge_bases.id';

COMMENT ON COLUMN agent_bus.kb_recall_logs.caller_kind IS '调用方 user/agent/admin';

COMMENT ON COLUMN agent_bus.kb_recall_logs.conversation_uuid IS '关联会话 (agent backchannel 时由 source_message_uuid 反查; Phase A 通常空)';

COMMENT ON COLUMN agent_bus.kb_recall_logs.query_text IS '原始 query';

COMMENT ON COLUMN agent_bus.kb_recall_logs.top_k IS '请求 top_k';

COMMENT ON COLUMN agent_bus.kb_recall_logs.threshold IS '请求 threshold';

COMMENT ON COLUMN agent_bus.kb_recall_logs.chunk_hits IS '本次返回的 chunk 数';

COMMENT ON COLUMN agent_bus.kb_recall_logs.score_top IS '本次 top1 score';

COMMENT ON COLUMN agent_bus.kb_recall_logs.latency_ms IS '本次召回耗时 ms';

COMMENT ON COLUMN agent_bus.kb_recall_logs.error_code IS '若失败, 记错误码 (zap.kb_not_attached / kb.visibility_invalid / ...)';

COMMENT ON COLUMN agent_bus.kb_recall_logs.metadata IS '扩展 metadata JSON';

CREATE TABLE agent_bus.kb_recall_logs_default (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint,
    agent_id bigint,
    kb_id bigint NOT NULL,
    caller_kind character varying(16) NOT NULL,
    conversation_uuid character varying(64),
    query_text text NOT NULL,
    top_k smallint NOT NULL,
    threshold numeric(8,4) NOT NULL,
    chunk_hits smallint NOT NULL,
    score_top numeric(8,4),
    latency_ms integer,
    error_code character varying(64),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT kb_recall_logs_caller_kind_check CHECK (((caller_kind)::text = ANY (ARRAY[('user'::character varying)::text, ('agent'::character varying)::text, ('admin'::character varying)::text])))
);

ALTER TABLE agent_bus.kb_recall_logs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.kb_recall_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY agent_bus.kb_recall_logs ATTACH PARTITION agent_bus.kb_recall_logs_default DEFAULT;

ALTER TABLE ONLY agent_bus.kb_chunks
    ADD CONSTRAINT kb_chunks_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.kb_chunks
    ADD CONSTRAINT kb_chunks_uuid_key UNIQUE (uuid);

ALTER TABLE ONLY agent_bus.kb_ingest_jobs
    ADD CONSTRAINT kb_ingest_jobs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.kb_ingest_jobs
    ADD CONSTRAINT kb_ingest_jobs_uuid_key UNIQUE (uuid);

ALTER TABLE ONLY agent_bus.kb_outbox_events
    ADD CONSTRAINT kb_outbox_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.kb_outbox_events
    ADD CONSTRAINT kb_outbox_events_uuid_key UNIQUE (uuid);

ALTER TABLE ONLY agent_bus.kb_recall_logs
    ADD CONSTRAINT kb_recall_logs_pkey PRIMARY KEY (id, occurred_at);

ALTER TABLE ONLY agent_bus.kb_recall_logs_default
    ADD CONSTRAINT kb_recall_logs_default_pkey PRIMARY KEY (id, occurred_at);

CREATE INDEX idx_kb_chunks_document ON agent_bus.kb_chunks USING btree (document_id);

CREATE INDEX idx_kb_chunks_kb ON agent_bus.kb_chunks USING btree (kb_id);

CREATE INDEX idx_kb_chunks_tsv ON agent_bus.kb_chunks USING gin (tsv);

CREATE INDEX idx_kb_jobs_status ON agent_bus.kb_ingest_jobs USING btree (status);

CREATE INDEX idx_kb_outbox_op ON agent_bus.kb_outbox_events USING btree (op, status);

CREATE INDEX idx_kb_outbox_pending ON agent_bus.kb_outbox_events USING btree (next_retry_at) WHERE ((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('failed'::character varying)::text]));

CREATE INDEX idx_kb_outbox_tenant ON agent_bus.kb_outbox_events USING btree (tenant_id);

CREATE INDEX idx_kb_recall_caller ON ONLY agent_bus.kb_recall_logs USING btree (caller_kind, occurred_at DESC);

CREATE INDEX idx_kb_recall_kb_time ON ONLY agent_bus.kb_recall_logs USING btree (kb_id, occurred_at DESC);

CREATE INDEX idx_kb_recall_tenant_time ON ONLY agent_bus.kb_recall_logs USING btree (tenant_id, occurred_at DESC);

CREATE INDEX kb_recall_logs_default_caller_kind_occurred_at_idx ON agent_bus.kb_recall_logs_default USING btree (caller_kind, occurred_at DESC);

CREATE INDEX kb_recall_logs_default_kb_id_occurred_at_idx ON agent_bus.kb_recall_logs_default USING btree (kb_id, occurred_at DESC);

CREATE INDEX kb_recall_logs_default_tenant_id_occurred_at_idx ON agent_bus.kb_recall_logs_default USING btree (tenant_id, occurred_at DESC);

ALTER INDEX agent_bus.idx_kb_recall_caller ATTACH PARTITION agent_bus.kb_recall_logs_default_caller_kind_occurred_at_idx;

ALTER INDEX agent_bus.idx_kb_recall_kb_time ATTACH PARTITION agent_bus.kb_recall_logs_default_kb_id_occurred_at_idx;

ALTER INDEX agent_bus.kb_recall_logs_pkey ATTACH PARTITION agent_bus.kb_recall_logs_default_pkey;

ALTER INDEX agent_bus.idx_kb_recall_tenant_time ATTACH PARTITION agent_bus.kb_recall_logs_default_tenant_id_occurred_at_idx;

ALTER TABLE ONLY agent_bus.kb_chunks
    ADD CONSTRAINT kb_chunks_document_id_fkey FOREIGN KEY (document_id) REFERENCES agent_bus.kb_documents(id);

ALTER TABLE ONLY agent_bus.kb_chunks
    ADD CONSTRAINT kb_chunks_kb_id_fkey FOREIGN KEY (kb_id) REFERENCES agent_bus.knowledge_bases(id);

ALTER TABLE ONLY agent_bus.kb_ingest_jobs
    ADD CONSTRAINT kb_ingest_jobs_document_id_fkey FOREIGN KEY (document_id) REFERENCES agent_bus.kb_documents(id);

ALTER TABLE ONLY agent_bus.kb_ingest_jobs
    ADD CONSTRAINT kb_ingest_jobs_kb_id_fkey FOREIGN KEY (kb_id) REFERENCES agent_bus.knowledge_bases(id);

ALTER TABLE ONLY agent_bus.kb_outbox_events
    ADD CONSTRAINT kb_outbox_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);

-- F11 P2: quota enforcement guards.
-- kb_tenant_quota_usage stores tenant KB storage usage as a transactional
-- counter, avoiding concurrent upload races caused by read-time SUM checks.
CREATE TABLE IF NOT EXISTS kb_tenant_quota_usage (
    tenant_id BIGINT PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
    used_bytes BIGINT NOT NULL DEFAULT 0 CHECK (used_bytes >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO kb_tenant_quota_usage (tenant_id, used_bytes)
SELECT k.tenant_id, COALESCE(SUM(d.file_size), 0)::BIGINT
  FROM knowledge_bases k
  JOIN kb_documents d ON d.kb_id = k.id
 WHERE k.deleted_at IS NULL
   AND d.deleted_at IS NULL
   AND d.status NOT IN ('failed', 'disabled')
 GROUP BY k.tenant_id
ON CONFLICT (tenant_id) DO UPDATE
    SET used_bytes = EXCLUDED.used_bytes,
        updated_at = now();


ALTER TABLE kb_outbox_events
    ALTER COLUMN tenant_id DROP NOT NULL,
    ADD COLUMN scope_kind varchar(16) NOT NULL DEFAULT 'tenant',
    ADD COLUMN kb_id bigint REFERENCES knowledge_bases(id);

-- Development-stage cutover: old rows do not carry the authoritative scope/kb
-- columns and are intentionally discarded instead of guessed/backfilled.
-- Newly exported table has no legacy rows to discard.

ALTER TABLE kb_outbox_events DROP CONSTRAINT kb_outbox_events_op_check;
ALTER TABLE kb_outbox_events
    ADD CONSTRAINT kb_outbox_events_op_check CHECK (op IN (
      'ensure_dataset', 'ingest_document', 'delete_dataset', 'delete_document',
      'tenant_cleanup_datasets', 'tenant_cleanup_user', 'reconcile_provision'
    )),
    ADD CONSTRAINT kb_outbox_events_scope_kind_check CHECK (scope_kind IN ('platform', 'tenant')),
    ADD CONSTRAINT chk_kb_outbox_scope_tenant CHECK (
      (scope_kind = 'platform' AND tenant_id IS NULL) OR
      (scope_kind = 'tenant' AND tenant_id IS NOT NULL)
    ),
    ADD CONSTRAINT chk_kb_outbox_kb_reference CHECK (
      op IN ('tenant_cleanup_datasets', 'tenant_cleanup_user', 'reconcile_provision') OR kb_id IS NOT NULL
    );

ALTER TABLE kb_recall_logs
    ADD COLUMN kb_scope_kind varchar(16),
    ADD COLUMN api_key_prefix varchar(24),
    ADD COLUMN session_token_id bigint;

UPDATE kb_recall_logs l
   SET kb_scope_kind = k.space_kind
  FROM knowledge_bases k
 WHERE k.id = l.kb_id;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM kb_recall_logs WHERE kb_scope_kind IS NULL) THEN
        RAISE EXCEPTION 'F07 preflight: kb_recall_logs rows cannot resolve kb scope';
    END IF;
END $$;

ALTER TABLE kb_recall_logs
    ALTER COLUMN kb_scope_kind SET NOT NULL,
    ALTER COLUMN tenant_id DROP NOT NULL,
    DROP CONSTRAINT kb_recall_logs_caller_kind_check,
    ADD CONSTRAINT kb_recall_logs_scope_kind_check
      CHECK (kb_scope_kind IN ('platform', 'tenant', 'personal', 'workspace')),
    ADD CONSTRAINT kb_recall_logs_caller_kind_check
      CHECK (caller_kind IN ('user', 'agent', 'admin', 'external_api_key'));

CREATE TABLE kb_platform_quota_usage (
    singleton_id smallint PRIMARY KEY DEFAULT 1 CHECK (singleton_id = 1),
    used_bytes bigint NOT NULL DEFAULT 0 CHECK (used_bytes >= 0),
    updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO kb_platform_quota_usage (singleton_id, used_bytes)
SELECT 1, coalesce(sum(d.file_size) FILTER (
           WHERE d.deleted_at IS NULL AND d.status NOT IN ('failed', 'disabled')
       ), 0)::bigint
  FROM knowledge_bases k
  LEFT JOIN kb_documents d ON d.kb_id = k.id
 WHERE k.space_kind = 'platform' AND k.deleted_at IS NULL;


