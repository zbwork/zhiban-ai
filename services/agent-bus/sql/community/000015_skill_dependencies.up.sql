-- Restore upstream skill dependencies used by the existing skill runtime.
-- Source: upstream immutable 000001 schema; no grants or policy bypass.
SET LOCAL search_path = agent_bus, public;

CREATE TABLE agent_bus.builtin_skill_keys (
    id bigint NOT NULL,
    code character varying(64) NOT NULL,
    name character varying(128) NOT NULL,
    description text,
    supported_platforms text[] NOT NULL,
    min_client_versions jsonb DEFAULT '{}'::jsonb NOT NULL,
    default_execution_mode character varying(32) DEFAULT 'asynchronous_floating'::character varying NOT NULL,
    default_native_capabilities text[] DEFAULT '{}'::text[] NOT NULL,
    registered_by bigint,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by bigint,
    CONSTRAINT builtin_skill_keys_default_execution_mode_check CHECK (((default_execution_mode)::text = ANY (ARRAY[('synchronous_inline'::character varying)::text, ('asynchronous_floating'::character varying)::text]))),
    CONSTRAINT builtin_skill_keys_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('deprecated'::character varying)::text])))
);

COMMENT ON TABLE agent_bus.builtin_skill_keys IS 'module: f03; F03 v0.9.1 内置技能 builtin_key 白名单；skills.builtin_key 必须存在于此表 status=active 行（应用层强校）';

COMMENT ON COLUMN agent_bus.builtin_skill_keys.is_deleted IS 'module: f03; 软删除标记。删除与 status 启停分离，删除行默认不出现在 admin 字典列表。';

ALTER TABLE agent_bus.builtin_skill_keys ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.builtin_skill_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE agent_bus.skill_label_bindings (
    skill_id bigint NOT NULL,
    label_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

COMMENT ON TABLE agent_bus.skill_label_bindings IS 'module: f03; F03 v0.9.1 技能 × 能力标签 N:N 绑定表';

CREATE TABLE agent_bus.skill_labels (
    id bigint NOT NULL,
    code character varying(64) NOT NULL,
    name character varying(128) NOT NULL,
    description text,
    sort_order integer DEFAULT 0 NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by bigint,
    CONSTRAINT skill_labels_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('archived'::character varying)::text])))
);

COMMENT ON TABLE agent_bus.skill_labels IS 'module: f03; F03 v0.9.1 能力标签字典；仅一组：tool_calling/generation/automation/data_processing';

COMMENT ON COLUMN agent_bus.skill_labels.is_deleted IS 'module: f03; 软删除标记。删除与 status 启停分离，删除行默认不出现在 admin 字典列表。';

ALTER TABLE agent_bus.skill_labels ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.skill_labels_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE agent_bus.skill_version_files (
    id bigint NOT NULL,
    version_id bigint NOT NULL,
    path text NOT NULL,
    size_bytes bigint NOT NULL,
    sha256 character(64) NOT NULL,
    content_type text DEFAULT 'application/octet-stream'::text NOT NULL,
    is_binary boolean DEFAULT false NOT NULL,
    truncated boolean DEFAULT false NOT NULL,
    content_text text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

COMMENT ON TABLE agent_bus.skill_version_files IS 'F03 §4.7 R1：技能版本 zip 解析后的文件清单 + 文本预览（OSS zip 是真值源、本表是投影）';

COMMENT ON COLUMN agent_bus.skill_version_files.is_binary IS 'true 表示该文件未通过文本嗅探，content_text 必为 NULL';

COMMENT ON COLUMN agent_bus.skill_version_files.truncated IS 'true 表示原文超过 1MB 上限被忽略，content_text 为 NULL';

COMMENT ON COLUMN agent_bus.skill_version_files.content_text IS '文本文件原文，二进制或 >1MB 文件留 NULL（is_binary / truncated 标识）';

CREATE SEQUENCE agent_bus.skill_version_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE agent_bus.skill_version_files_id_seq OWNED BY agent_bus.skill_version_files.id;

CREATE TABLE agent_bus.tenant_skill_disables (
    tenant_id bigint NOT NULL,
    skill_id bigint NOT NULL,
    disable_reason text,
    disabled_at timestamp with time zone DEFAULT now() NOT NULL,
    disabled_by bigint
);

COMMENT ON TABLE agent_bus.tenant_skill_disables IS 'module: f03; F03 v0.9.1 租户禁用某平台技能的独立黑名单；存量绑定保留，运行时全方位拒绝（chip rail/广场/message metadata 校验都拒绝）';

CREATE TABLE agent_bus.tenant_skill_preferences (
    tenant_id bigint NOT NULL,
    skill_id bigint NOT NULL,
    behavior character varying(16) NOT NULL,
    note text,
    created_by bigint,
    updated_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tenant_skill_preferences_behavior_check CHECK (((behavior)::text = ANY (ARRAY[('force_on'::character varying)::text, ('force_off'::character varying)::text])))
);

COMMENT ON TABLE agent_bus.tenant_skill_preferences IS 'module: f03; F03 v0.9.1 租户对某平台技能的默认装配偏好（force_on/force_off）；应用层强校 skill.scope_kind=platform';

CREATE TABLE agent_bus.user_agent_skill_overrides (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    agent_id bigint NOT NULL,
    skill_id bigint NOT NULL,
    behavior character varying(32) NOT NULL,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_agent_skill_overrides_behavior_check CHECK (((behavior)::text = ANY (ARRAY[('temporary_attach'::character varying)::text, ('temporary_detach'::character varying)::text])))
);

COMMENT ON TABLE agent_bus.user_agent_skill_overrides IS 'module: f03; F03 v0.9.1 用户在某数字员工对话中临时挂或临时摘的技能；过期行由 cron worker 按 expires_at 索引清理';

ALTER TABLE agent_bus.user_agent_skill_overrides ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.user_agent_skill_overrides_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY agent_bus.skill_version_files ALTER COLUMN id SET DEFAULT nextval('agent_bus.skill_version_files_id_seq'::regclass);

ALTER TABLE ONLY agent_bus.builtin_skill_keys
    ADD CONSTRAINT builtin_skill_keys_code_key UNIQUE (code);

ALTER TABLE ONLY agent_bus.builtin_skill_keys
    ADD CONSTRAINT builtin_skill_keys_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.skill_label_bindings
    ADD CONSTRAINT skill_label_bindings_pkey PRIMARY KEY (skill_id, label_id);

ALTER TABLE ONLY agent_bus.skill_labels
    ADD CONSTRAINT skill_labels_code_key UNIQUE (code);

ALTER TABLE ONLY agent_bus.skill_labels
    ADD CONSTRAINT skill_labels_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.skill_version_files
    ADD CONSTRAINT skill_version_files_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.skill_version_files
    ADD CONSTRAINT skill_version_files_version_id_path_key UNIQUE (version_id, path);

ALTER TABLE ONLY agent_bus.tenant_skill_disables
    ADD CONSTRAINT tenant_skill_disables_pkey PRIMARY KEY (tenant_id, skill_id);

ALTER TABLE ONLY agent_bus.tenant_skill_preferences
    ADD CONSTRAINT tenant_skill_preferences_pkey PRIMARY KEY (tenant_id, skill_id);

ALTER TABLE ONLY agent_bus.user_agent_skill_overrides
    ADD CONSTRAINT user_agent_skill_overrides_account_id_agent_id_skill_id_key UNIQUE (account_id, agent_id, skill_id);

ALTER TABLE ONLY agent_bus.user_agent_skill_overrides
    ADD CONSTRAINT user_agent_skill_overrides_pkey PRIMARY KEY (id);

CREATE INDEX idx_builtin_skill_keys_not_deleted ON agent_bus.builtin_skill_keys USING btree (status, id) WHERE (is_deleted = false);

CREATE INDEX idx_skill_label_bindings_label ON agent_bus.skill_label_bindings USING btree (label_id);

CREATE INDEX idx_skill_labels_not_deleted ON agent_bus.skill_labels USING btree (status, sort_order, id) WHERE (is_deleted = false);

CREATE INDEX idx_skill_version_files_version ON agent_bus.skill_version_files USING btree (version_id);

CREATE INDEX idx_tenant_skill_disables_skill ON agent_bus.tenant_skill_disables USING btree (skill_id);

CREATE INDEX idx_tenant_skill_preferences_skill ON agent_bus.tenant_skill_preferences USING btree (skill_id);

CREATE INDEX idx_user_agent_skill_overrides_expires ON agent_bus.user_agent_skill_overrides USING btree (expires_at) WHERE (expires_at IS NOT NULL);

CREATE INDEX idx_user_agent_skill_overrides_lookup ON agent_bus.user_agent_skill_overrides USING btree (account_id, agent_id) WHERE (expires_at IS NULL);

CREATE INDEX idx_user_agent_skill_overrides_lookup_with_expiry ON agent_bus.user_agent_skill_overrides USING btree (account_id, agent_id, expires_at) WHERE (expires_at IS NOT NULL);

ALTER TABLE ONLY agent_bus.builtin_skill_keys
    ADD CONSTRAINT builtin_skill_keys_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.builtin_skill_keys
    ADD CONSTRAINT builtin_skill_keys_registered_by_fkey FOREIGN KEY (registered_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.skill_label_bindings
    ADD CONSTRAINT skill_label_bindings_label_id_fkey FOREIGN KEY (label_id) REFERENCES agent_bus.skill_labels(id);

ALTER TABLE ONLY agent_bus.skill_label_bindings
    ADD CONSTRAINT skill_label_bindings_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES agent_bus.skills(id) ON DELETE CASCADE;

ALTER TABLE ONLY agent_bus.skill_labels
    ADD CONSTRAINT skill_labels_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.skill_version_files
    ADD CONSTRAINT skill_version_files_version_id_fkey FOREIGN KEY (version_id) REFERENCES agent_bus.skill_versions(id) ON DELETE CASCADE;

ALTER TABLE ONLY agent_bus.tenant_skill_disables
    ADD CONSTRAINT tenant_skill_disables_disabled_by_fkey FOREIGN KEY (disabled_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.tenant_skill_disables
    ADD CONSTRAINT tenant_skill_disables_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES agent_bus.skills(id);

ALTER TABLE ONLY agent_bus.tenant_skill_disables
    ADD CONSTRAINT tenant_skill_disables_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id) ON DELETE CASCADE;

ALTER TABLE ONLY agent_bus.tenant_skill_preferences
    ADD CONSTRAINT tenant_skill_preferences_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.tenant_skill_preferences
    ADD CONSTRAINT tenant_skill_preferences_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES agent_bus.skills(id);

ALTER TABLE ONLY agent_bus.tenant_skill_preferences
    ADD CONSTRAINT tenant_skill_preferences_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id) ON DELETE CASCADE;

ALTER TABLE ONLY agent_bus.tenant_skill_preferences
    ADD CONSTRAINT tenant_skill_preferences_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.user_agent_skill_overrides
    ADD CONSTRAINT user_agent_skill_overrides_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id) ON DELETE CASCADE;

ALTER TABLE ONLY agent_bus.user_agent_skill_overrides
    ADD CONSTRAINT user_agent_skill_overrides_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agent_bus.digital_employees(id) ON DELETE CASCADE;

ALTER TABLE ONLY agent_bus.user_agent_skill_overrides
    ADD CONSTRAINT user_agent_skill_overrides_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES agent_bus.skills(id);

ALTER TABLE ONLY agent_bus.user_agent_skill_overrides
    ADD CONSTRAINT user_agent_skill_overrides_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);
