-- Restore existing upstream cron prompt template dependencies for the task UI.
SET LOCAL search_path = agent_bus, public;

CREATE TABLE agent_bus.cron_prompt_template_variables (
    id bigint NOT NULL,
    template_id bigint NOT NULL,
    var_name character varying(64) NOT NULL,
    var_type character varying(16) NOT NULL,
    required boolean DEFAULT false NOT NULL,
    default_value jsonb,
    options jsonb,
    display_name character varying(128),
    placeholder character varying(256),
    order_index integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT cron_prompt_template_variables_check CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT cron_prompt_template_variables_var_type_check CHECK (((var_type)::text = ANY (ARRAY[('string'::character varying)::text, ('enum'::character varying)::text, ('int'::character varying)::text, ('datetime'::character varying)::text, ('list'::character varying)::text])))
);

COMMENT ON TABLE agent_bus.cron_prompt_template_variables IS 'F08 R9 · Cron prompt 模板的变量定义 (UI 表单 schema)';

COMMENT ON COLUMN agent_bus.cron_prompt_template_variables.var_type IS 'string/enum/int/datetime/list; UI 据此生成对应 input';

COMMENT ON COLUMN agent_bus.cron_prompt_template_variables.options IS 'var_type=enum 时存可选值数组 [{value, label}, ...]';

COMMENT ON COLUMN agent_bus.cron_prompt_template_variables.order_index IS 'UI 表单字段渲染顺序';

ALTER TABLE agent_bus.cron_prompt_template_variables ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.cron_prompt_template_variables_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE agent_bus.cron_prompt_templates (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    scope_kind character varying(16) NOT NULL,
    tenant_id bigint,
    code character varying(64) NOT NULL,
    name character varying(128) NOT NULL,
    description text,
    template_body text NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT cron_prompt_templates_check CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT cron_prompt_templates_check1 CHECK (((((scope_kind)::text = 'platform'::text) AND (tenant_id IS NULL)) OR (((scope_kind)::text = 'tenant'::text) AND (tenant_id IS NOT NULL)))),
    CONSTRAINT cron_prompt_templates_scope_kind_check CHECK (((scope_kind)::text = ANY (ARRAY[('platform'::character varying)::text, ('tenant'::character varying)::text]))),
    CONSTRAINT cron_prompt_templates_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('active'::character varying)::text, ('archived'::character varying)::text])))
);

COMMENT ON TABLE agent_bus.cron_prompt_templates IS 'F08 R9 · Cron prompt 模板; 平台预置 (scope=platform) + 租户可扩展 (scope=tenant)';

COMMENT ON COLUMN agent_bus.cron_prompt_templates.scope_kind IS '平台 / 租户两层 scope; 用 partial unique index 防 nullable UNIQUE 多 NULL';

COMMENT ON COLUMN agent_bus.cron_prompt_templates.tenant_id IS 'scope=platform 必 NULL; scope=tenant 必非 NULL (CHECK 强制)';

COMMENT ON COLUMN agent_bus.cron_prompt_templates.code IS '业务编码; partial unique 按 scope 分治';

COMMENT ON COLUMN agent_bus.cron_prompt_templates.template_body IS 'Jinja-like {{var}} 占位文本; 渲染算法见 F08 §4.7';

COMMENT ON COLUMN agent_bus.cron_prompt_templates.is_system IS '平台预置 (true) 不允许 admin 删除, 只能 archive';

ALTER TABLE agent_bus.cron_prompt_templates ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.cron_prompt_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY agent_bus.cron_prompt_template_variables
    ADD CONSTRAINT cron_prompt_template_variables_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.cron_prompt_template_variables
    ADD CONSTRAINT cron_prompt_template_variables_template_id_var_name_key UNIQUE (template_id, var_name);

ALTER TABLE ONLY agent_bus.cron_prompt_templates
    ADD CONSTRAINT cron_prompt_templates_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.cron_prompt_templates
    ADD CONSTRAINT cron_prompt_templates_uuid_key UNIQUE (uuid);

CREATE INDEX idx_cron_prompt_tpl_scope_status ON agent_bus.cron_prompt_templates USING btree (scope_kind, tenant_id, status) WHERE (is_deleted = false);

CREATE INDEX idx_cron_prompt_tpl_var_order ON agent_bus.cron_prompt_template_variables USING btree (template_id, order_index) WHERE (is_deleted = false);

CREATE UNIQUE INDEX uq_cron_prompt_tpl_platform_code ON agent_bus.cron_prompt_templates USING btree (code) WHERE (((scope_kind)::text = 'platform'::text) AND (is_deleted = false));

CREATE UNIQUE INDEX uq_cron_prompt_tpl_tenant_code ON agent_bus.cron_prompt_templates USING btree (tenant_id, code) WHERE (((scope_kind)::text = 'tenant'::text) AND (is_deleted = false));

ALTER TABLE ONLY agent_bus.cron_prompt_template_variables
    ADD CONSTRAINT cron_prompt_template_variables_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.cron_prompt_template_variables
    ADD CONSTRAINT cron_prompt_template_variables_template_id_fkey FOREIGN KEY (template_id) REFERENCES agent_bus.cron_prompt_templates(id) ON DELETE CASCADE;

ALTER TABLE ONLY agent_bus.cron_prompt_template_variables
    ADD CONSTRAINT cron_prompt_template_variables_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.cron_prompt_templates
    ADD CONSTRAINT cron_prompt_templates_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.cron_prompt_templates
    ADD CONSTRAINT cron_prompt_templates_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);

ALTER TABLE ONLY agent_bus.cron_prompt_templates
    ADD CONSTRAINT cron_prompt_templates_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);
