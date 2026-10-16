-- Community baseline: schema only, no accounts or deployment credentials.
CREATE SCHEMA agent_bus;
CREATE OR REPLACE FUNCTION agent_bus.enforce_zap_digital_employee_agent_key_unique()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    runtime_framework text;
    normalized_key text;
BEGIN
    IF NEW.is_deleted = true
       OR NEW.deleted_at IS NOT NULL
       OR NEW.runtime_environment_id IS NULL
       OR NULLIF(BTRIM(NEW.metadata->>'agent_key'), '') IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT LOWER(COALESCE(framework, ''))
      INTO runtime_framework
      FROM agent_bus.runtime_environments
     WHERE id = NEW.runtime_environment_id
       AND is_deleted = false;

    IF runtime_framework IS DISTINCT FROM 'zap' THEN
        RETURN NEW;
    END IF;

    normalized_key := LOWER(BTRIM(NEW.metadata->>'agent_key'));
    IF EXISTS (
        SELECT 1
          FROM agent_bus.digital_employees de
         WHERE COALESCE(de.tenant_id, 0) = COALESCE(NEW.tenant_id, 0)
           AND de.runtime_environment_id = NEW.runtime_environment_id
           AND de.id <> NEW.id
           AND de.is_deleted = false
           AND de.deleted_at IS NULL
           AND LOWER(BTRIM(de.metadata->>'agent_key')) = normalized_key
    ) THEN
        RAISE EXCEPTION 'duplicate ZAP agent_key % for runtime %', NEW.metadata->>'agent_key', NEW.runtime_environment_id
            USING ERRCODE = 'unique_violation';
    END IF;

    RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION agent_bus.prevent_org_outbox_done_without_delivery()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.topic LIKE 'org.%'
       AND NEW.status = 'done'
       AND OLD.status IS DISTINCT FROM NEW.status
       AND EXISTS (
           SELECT 1
           FROM agent_bus.tenant_webhook_configs c
           WHERE c.tenant_id = NEW.tenant_id
             AND c.enabled = true
             AND c.deleted_at IS NULL
             AND (
                 c.event_types IS NULL
                 OR cardinality(c.event_types) = 0
                 OR NEW.topic = ANY(c.event_types)
             )
       )
       AND NOT EXISTS (
           SELECT 1
           FROM agent_bus.tenant_webhook_deliveries d
           WHERE d.outbox_id = NEW.id
       )
    THEN
        RAISE EXCEPTION 'org outbox % cannot be marked done before webhook fan-out', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION agent_bus.seed_default_tenant_positions(target_tenant bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO agent_bus.tenant_positions (tenant_id, name, description, sort_order, is_system, metadata) VALUES
        (target_tenant, '员工',     '通用基层员工',           10,  true, '{"seed_key":"employee"}'::jsonb),
        (target_tenant, '主管',     '小组负责人',             20,  true, '{"seed_key":"supervisor"}'::jsonb),
        (target_tenant, '经理',     '部门经理',               30,  true, '{"seed_key":"manager"}'::jsonb),
        (target_tenant, '总监',     '部门总监 / 资深管理',    40,  true, '{"seed_key":"director"}'::jsonb),
        (target_tenant, '副总裁',   '业务线负责人',           50,  true, '{"seed_key":"vp"}'::jsonb),
        (target_tenant, '销售',     '销售岗',                 60,  true, '{"seed_key":"sales"}'::jsonb),
        (target_tenant, '客服',     '客户服务岗',             70,  true, '{"seed_key":"customer-service"}'::jsonb),
        (target_tenant, '工程师',   '技术研发岗',             80,  true, '{"seed_key":"engineer"}'::jsonb),
        (target_tenant, '产品经理', '产品规划岗',             90,  true, '{"seed_key":"product-manager"}'::jsonb),
        (target_tenant, '人力资源', 'HR / 行政岗',            100, true, '{"seed_key":"hr"}'::jsonb)
    ON CONFLICT (tenant_id, name) WHERE deleted_at IS NULL DO NOTHING;
END;
$function$
;
CREATE OR REPLACE FUNCTION agent_bus.touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION agent_bus.trg_tenant_seed_positions()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM agent_bus.seed_default_tenant_positions(NEW.id);
    RETURN NEW;
END;
$function$
;

--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Debian 16.15-1.pgdg12+2)
-- Dumped by pg_dump version 16.15 (Debian 16.15-1.pgdg12+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_identities; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.account_identities (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    provider character varying(64) NOT NULL,
    provider_uid character varying(256) NOT NULL,
    provider_meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    linked_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone
);


--
-- Name: TABLE account_identities; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.account_identities IS '账号外部 IdP 凭证(SCIM/OIDC/SAML/LDAP/wecom...)';


--
-- Name: COLUMN account_identities.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.account_identities.id IS '主键 ID';


--
-- Name: COLUMN account_identities.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.account_identities.account_id IS '账号 ID';


--
-- Name: COLUMN account_identities.provider; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.account_identities.provider IS '凭证提供方 oidc/saml/ldap/wecom/feishu/scim';


--
-- Name: COLUMN account_identities.provider_uid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.account_identities.provider_uid IS '提供方那边的唯一 ID';


--
-- Name: COLUMN account_identities.provider_meta; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.account_identities.provider_meta IS '元数据 JSON(如 ldap_dn)';


--
-- Name: COLUMN account_identities.linked_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.account_identities.linked_at IS '绑定时间';


--
-- Name: COLUMN account_identities.last_used_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.account_identities.last_used_at IS '最近一次使用时间';


--
-- Name: account_identities_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.account_identities ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.account_identities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: accounts; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.accounts (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying(256),
    phone character varying(32),
    username character varying(64),
    password_hash character varying(256),
    password_set_at timestamp with time zone,
    display_name character varying(128) NOT NULL,
    avatar_url character varying(512),
    locale character varying(16) DEFAULT 'zh-CN'::character varying,
    timezone character varying(32) DEFAULT 'Asia/Shanghai'::character varying,
    status character varying(32) DEFAULT 'active'::character varying NOT NULL,
    email_verified_at timestamp with time zone,
    phone_verified_at timestamp with time zone,
    mfa_enabled boolean DEFAULT false NOT NULL,
    last_login_at timestamp with time zone,
    last_login_ip inet,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT accounts_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('active'::character varying)::text, ('suspended'::character varying)::text, ('locked'::character varying)::text, ('deactivated'::character varying)::text])))
);


--
-- Name: TABLE accounts; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.accounts IS '账号主体,全局唯一';


--
-- Name: COLUMN accounts.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.id IS '主键 ID';


--
-- Name: COLUMN accounts.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN accounts.email; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.email IS '邮箱(可选,唯一)';


--
-- Name: COLUMN accounts.phone; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.phone IS '手机号(可选,唯一)';


--
-- Name: COLUMN accounts.username; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.username IS '用户名(可选,密码登录)';


--
-- Name: COLUMN accounts.password_hash; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.password_hash IS '密码 hash(bcrypt),仅 SSO 时可为空';


--
-- Name: COLUMN accounts.password_set_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.password_set_at IS '密码设置时间';


--
-- Name: COLUMN accounts.display_name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.display_name IS '显示昵称';


--
-- Name: COLUMN accounts.avatar_url; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.avatar_url IS '头像 URL';


--
-- Name: COLUMN accounts.locale; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.locale IS '语言偏好';


--
-- Name: COLUMN accounts.timezone; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.timezone IS '时区偏好';


--
-- Name: COLUMN accounts.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.status IS '状态 pending=未激活 active=可用 suspended=暂停 locked=锁定 deactivated=已注销';


--
-- Name: COLUMN accounts.email_verified_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.email_verified_at IS '邮箱验证时间';


--
-- Name: COLUMN accounts.phone_verified_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.phone_verified_at IS '手机验证时间';


--
-- Name: COLUMN accounts.mfa_enabled; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.mfa_enabled IS '是否启用 MFA';


--
-- Name: COLUMN accounts.last_login_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.last_login_at IS '最近一次登录时间';


--
-- Name: COLUMN accounts.last_login_ip; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.last_login_ip IS '最近一次登录 IP';


--
-- Name: COLUMN accounts.settings; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.settings IS '个人偏好 JSON';


--
-- Name: COLUMN accounts.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.created_at IS '创建时间';


--
-- Name: COLUMN accounts.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.updated_at IS '更新时间';


--
-- Name: COLUMN accounts.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.accounts.deleted_at IS '软删除时间';


--
-- Name: accounts_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.accounts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: admin_accounts; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.admin_accounts (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    is_platform boolean DEFAULT false NOT NULL,
    notes text,
    failed_login_attempts integer DEFAULT 0 NOT NULL,
    locked_until timestamp with time zone,
    last_password_change timestamp with time zone,
    must_change_password boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: TABLE admin_accounts; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.admin_accounts IS '管理员账号扩展信息(平台管理员/租户管理员)';


--
-- Name: COLUMN admin_accounts.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.id IS '主键 ID';


--
-- Name: COLUMN admin_accounts.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.account_id IS '关联 accounts.id';


--
-- Name: COLUMN admin_accounts.is_platform; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.is_platform IS '是否平台超管,true=可访问 platform 域';


--
-- Name: COLUMN admin_accounts.notes; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.notes IS '备注';


--
-- Name: COLUMN admin_accounts.failed_login_attempts; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.failed_login_attempts IS '连续失败次数';


--
-- Name: COLUMN admin_accounts.locked_until; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.locked_until IS '锁定到期时间';


--
-- Name: COLUMN admin_accounts.last_password_change; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.last_password_change IS '上次改密时间';


--
-- Name: COLUMN admin_accounts.must_change_password; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.must_change_password IS '是否强制改密';


--
-- Name: COLUMN admin_accounts.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.created_at IS '创建时间';


--
-- Name: COLUMN admin_accounts.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.updated_at IS '更新时间';


--
-- Name: COLUMN admin_accounts.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.admin_accounts.deleted_at IS '软删除时间';


--
-- Name: admin_accounts_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.admin_accounts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.admin_accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_app_bindings; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.agent_app_bindings (
    id bigint NOT NULL,
    agent_id bigint NOT NULL,
    app_id bigint NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE agent_app_bindings; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.agent_app_bindings IS 'F04: 数字员工挂业务应用 (跟 agent_composer_skill_bindings 平行)';


--
-- Name: COLUMN agent_app_bindings.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_app_bindings.id IS '主键 ID';


--
-- Name: COLUMN agent_app_bindings.agent_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_app_bindings.agent_id IS '数字员工 ID';


--
-- Name: COLUMN agent_app_bindings.app_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_app_bindings.app_id IS '应用 ID';


--
-- Name: COLUMN agent_app_bindings.sort_order; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_app_bindings.sort_order IS '该数字员工内业务应用顺序';


--
-- Name: COLUMN agent_app_bindings.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_app_bindings.created_at IS '创建时间';


--
-- Name: COLUMN agent_app_bindings.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_app_bindings.updated_at IS '更新时间';


--
-- Name: agent_app_bindings_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.agent_app_bindings ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.agent_app_bindings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_kb_bindings; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.agent_kb_bindings (
    id bigint NOT NULL,
    agent_id bigint NOT NULL,
    kb_id bigint NOT NULL,
    binding_kind character varying(16) DEFAULT 'attached'::character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    note text,
    created_by bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT agent_kb_bindings_binding_kind_check CHECK (((binding_kind)::text = ANY (ARRAY[('attached'::character varying)::text, ('required'::character varying)::text, ('optional'::character varying)::text])))
);


--
-- Name: TABLE agent_kb_bindings; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.agent_kb_bindings IS 'F07 D5/D9: 数字员工绑定的 KB 列表, EAP retrieve capability check 真相源';


--
-- Name: COLUMN agent_kb_bindings.binding_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_kb_bindings.binding_kind IS 'attached=普通; required=必查; optional=LLM 决定是否查';


--
-- Name: COLUMN agent_kb_bindings.priority; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_kb_bindings.priority IS '多 KB 时 RRF 融合权重';


--
-- Name: COLUMN agent_kb_bindings.created_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_kb_bindings.created_by IS '后台创建数字员工时 = 租户 admin; 用户自建 = 自己';


--
-- Name: agent_kb_bindings_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.agent_kb_bindings ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.agent_kb_bindings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_skill_bindings; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.agent_skill_bindings (
    id bigint NOT NULL,
    agent_id bigint NOT NULL,
    skill_id bigint NOT NULL,
    pinned boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    pinned_version_id bigint,
    default_params jsonb DEFAULT '{}'::jsonb NOT NULL,
    source character varying(32) DEFAULT 'manual_attach'::character varying NOT NULL,
    created_by bigint,
    updated_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT agent_skill_bindings_source_check CHECK (((source)::text = ANY (ARRAY[('default_inherit'::character varying)::text, ('manual_attach'::character varying)::text, ('ai_recommend'::character varying)::text])))
);


--
-- Name: TABLE agent_skill_bindings; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.agent_skill_bindings IS 'module: f03; F03 v0.9.1 数字员工 × 技能 独立绑定表（不复用 agent_capability_bindings 通用表）';


--
-- Name: COLUMN agent_skill_bindings.pinned_version_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_skill_bindings.pinned_version_id IS 'module: f03; NULL=跟随 latest published；非 NULL=pin 到具体版本';


--
-- Name: COLUMN agent_skill_bindings.default_params; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_skill_bindings.default_params IS 'module: f03; 数字员工管理员预填的 chip 参数默认值';


--
-- Name: COLUMN agent_skill_bindings.source; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_skill_bindings.source IS 'module: f03; default_inherit=新建数字员工默认继承；manual_attach=管理员手动加；ai_recommend=AI 推荐';


--
-- Name: agent_skill_bindings_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.agent_skill_bindings ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.agent_skill_bindings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_trigger_log; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.agent_trigger_log (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    room_id bigint NOT NULL,
    sender_account_id bigint,
    agent_id bigint,
    openim_client_msg_id character varying(128) NOT NULL,
    decision character varying(16) NOT NULL,
    reject_reason character varying(64),
    agent_run_id bigint,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    substrate character varying(16) DEFAULT 'wukong'::character varying NOT NULL,
    wukong_run_status character varying(16),
    wukong_stream_id character varying(128),
    wukong_agent_message_uuid character varying(64),
    wukong_run_error text,
    CONSTRAINT agent_trigger_log_decision_check CHECK (((decision)::text = ANY (ARRAY[('triggered'::character varying)::text, ('skipped'::character varying)::text, ('rejected'::character varying)::text]))),
    CONSTRAINT agent_trigger_log_wukong_run_status_check CHECK (((wukong_run_status IS NULL) OR ((wukong_run_status)::text = ANY (ARRAY[('starting'::character varying)::text, ('started'::character varying)::text, ('failed'::character varying)::text]))))
);


--
-- Name: TABLE agent_trigger_log; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.agent_trigger_log IS 'module: m5/F09; 群聊 webhook 触发 Agent 的去重 + 审计; 幂等键 = (tenant_id, room_id, substrate, openim_client_msg_id); substrate=openim|wukong.';


--
-- Name: COLUMN agent_trigger_log.openim_client_msg_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_trigger_log.openim_client_msg_id IS '历史列名;当前 WuKong 路径写 webhook message_id';


--
-- Name: COLUMN agent_trigger_log.substrate; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_trigger_log.substrate IS 'IM 底座: wukong; openim 仅为历史行兼容. 幂等键 = (tenant_id, room_id, substrate, openim_client_msg_id)';


--
-- Name: COLUMN agent_trigger_log.wukong_run_status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_trigger_log.wukong_run_status IS 'ADR-0026 agent-direct run 状态机: starting(gate 占位) | started(run 已起+stream 已写) | failed(run 出错). NULL=非 agent-direct 行.';


--
-- Name: COLUMN agent_trigger_log.wukong_stream_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_trigger_log.wukong_stream_id IS 'ADR-0026 agent-direct: 该 WuKong user message 触发的 run 的 SSE stream_id (status=started 时回写). webhook/attach 共享; attach 据此返回同一 stream (不二次 run).';


--
-- Name: COLUMN agent_trigger_log.wukong_agent_message_uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_trigger_log.wukong_agent_message_uuid IS 'ADR-0026 agent-direct: 该 run 的 agent message uuid (UUID 格式串, 存 varchar 不做 ::uuid cast, 避免回写失败). 与 stream_id 同时回写.';


--
-- Name: COLUMN agent_trigger_log.wukong_run_error; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_trigger_log.wukong_run_error IS 'ADR-0026 agent-direct: run 失败 (status=failed) 的内部错误; 脱敏, 不直接回客户端.';


--
-- Name: agent_trigger_log_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.agent_trigger_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.agent_trigger_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: agent_versions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.agent_versions (
    id bigint NOT NULL,
    digital_employee_id bigint NOT NULL,
    version integer NOT NULL,
    snapshot jsonb NOT NULL,
    status character varying(32) DEFAULT 'draft'::character varying NOT NULL,
    grayscale_pct smallint DEFAULT 0 NOT NULL,
    grayscale_groups text[] DEFAULT '{}'::text[] NOT NULL,
    notes text,
    published_by bigint,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT agent_versions_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('grayed'::character varying)::text, ('rolled_back'::character varying)::text, ('archived'::character varying)::text])))
);


--
-- Name: TABLE agent_versions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.agent_versions IS '数字员工版本快照与灰度';


--
-- Name: COLUMN agent_versions.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.id IS '主键 ID';


--
-- Name: COLUMN agent_versions.digital_employee_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.digital_employee_id IS '数字员工 ID';


--
-- Name: COLUMN agent_versions.version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.version IS '版本号';


--
-- Name: COLUMN agent_versions.snapshot; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.snapshot IS '完整快照 JSON(配置/技能/MCP/KB/系统提示)';


--
-- Name: COLUMN agent_versions.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.status IS '状态 draft/published/grayed/rolled_back/archived';


--
-- Name: COLUMN agent_versions.grayscale_pct; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.grayscale_pct IS '灰度百分比 0-100';


--
-- Name: COLUMN agent_versions.grayscale_groups; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.grayscale_groups IS '灰度部门/标签';


--
-- Name: COLUMN agent_versions.notes; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.notes IS '发版说明';


--
-- Name: COLUMN agent_versions.published_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.published_by IS '发版人账号 ID';


--
-- Name: COLUMN agent_versions.published_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.published_at IS '发版时间';


--
-- Name: COLUMN agent_versions.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.created_at IS '创建时间';


--
-- Name: COLUMN agent_versions.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.agent_versions.updated_at IS '更新时间';


--
-- Name: agent_versions_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.agent_versions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.agent_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: app_category; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.app_category (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    code character varying(64) NOT NULL,
    name character varying(128) NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id bigint
);


--
-- Name: TABLE app_category; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.app_category IS '应用分类';


--
-- Name: COLUMN app_category.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_category.id IS '主键 ID';


--
-- Name: COLUMN app_category.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_category.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN app_category.code; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_category.code IS '分类编码';


--
-- Name: COLUMN app_category.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_category.name IS '名称';


--
-- Name: COLUMN app_category.sort_order; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_category.sort_order IS '排序';


--
-- Name: COLUMN app_category.is_system; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_category.is_system IS '平台预置';


--
-- Name: COLUMN app_category.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_category.created_at IS '创建时间';


--
-- Name: COLUMN app_category.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_category.tenant_id IS 'F04: NULL=平台预置分类; 非空=租户自建分类';


--
-- Name: app_category_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.app_category ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.app_category_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: app_oauth_clients; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.app_oauth_clients (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint,
    creator_id bigint NOT NULL,
    app_id bigint NOT NULL,
    client_id character varying(128) NOT NULL,
    client_secret_hash character varying(256) NOT NULL,
    redirect_uris character varying(512)[] DEFAULT '{}'::character varying[] NOT NULL,
    scopes character varying(64)[] DEFAULT '{}'::character varying[] NOT NULL,
    token_endpoint_auth_method character varying(32) DEFAULT 'client_secret_post'::character varying NOT NULL,
    access_token_ttl_seconds integer DEFAULT 7200 NOT NULL,
    refresh_token_ttl_seconds integer DEFAULT 2592000 NOT NULL,
    status character varying(32) DEFAULT 'active'::character varying NOT NULL,
    last_used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT app_oauth_clients_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('revoked'::character varying)::text]))),
    CONSTRAINT app_oauth_clients_token_endpoint_auth_method_check CHECK (((token_endpoint_auth_method)::text = ANY (ARRAY[('client_secret_post'::character varying)::text, ('client_secret_basic'::character varying)::text])))
);


--
-- Name: TABLE app_oauth_clients; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.app_oauth_clients IS 'F04: 应用 OAuth2 客户端凭证 (架构参照 agent_sdk_credentials)';


--
-- Name: COLUMN app_oauth_clients.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.id IS '主键 ID';


--
-- Name: COLUMN app_oauth_clients.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN app_oauth_clients.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.tenant_id IS '租户 ID; NULL=平台预置应用的 OAuth client';


--
-- Name: COLUMN app_oauth_clients.creator_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.creator_id IS '创建人 (admin)';


--
-- Name: COLUMN app_oauth_clients.app_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.app_id IS '关联 apps.id (1:1)';


--
-- Name: COLUMN app_oauth_clients.client_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.client_id IS 'app_<32-base62>; 永久可见';


--
-- Name: COLUMN app_oauth_clients.client_secret_hash; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.client_secret_hash IS 'sha256(明文 secret) hex; 明文仅创建时一次性返回';


--
-- Name: COLUMN app_oauth_clients.redirect_uris; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.redirect_uris IS 'exact-match 白名单, token 交换时校验';


--
-- Name: COLUMN app_oauth_clients.scopes; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.scopes IS '反向调 知办AI 时允许的能力范围';


--
-- Name: COLUMN app_oauth_clients.token_endpoint_auth_method; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.token_endpoint_auth_method IS 'OAuth2 客户端认证方法 (RFC 6749 §2.3)';


--
-- Name: COLUMN app_oauth_clients.access_token_ttl_seconds; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.access_token_ttl_seconds IS 'access_token 默认 TTL (秒)';


--
-- Name: COLUMN app_oauth_clients.refresh_token_ttl_seconds; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.refresh_token_ttl_seconds IS 'refresh_token 默认 TTL (秒)';


--
-- Name: COLUMN app_oauth_clients.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.status IS '状态 active / revoked';


--
-- Name: COLUMN app_oauth_clients.last_used_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.last_used_at IS '最近一次成功换 token 时间';


--
-- Name: COLUMN app_oauth_clients.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.created_at IS '创建时间';


--
-- Name: COLUMN app_oauth_clients.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.updated_at IS '更新时间';


--
-- Name: COLUMN app_oauth_clients.revoked_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.app_oauth_clients.revoked_at IS '撤销时间';


--
-- Name: app_oauth_clients_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.app_oauth_clients ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.app_oauth_clients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: apps; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.apps (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint,
    creator_id bigint,
    code character varying(64) NOT NULL,
    name character varying(128) NOT NULL,
    description text,
    icon_url character varying(512),
    color character varying(32),
    entry_kind character varying(32) DEFAULT 'webview'::character varying NOT NULL,
    url character varying(512),
    category_id bigint,
    sort_order integer DEFAULT 0 NOT NULL,
    bridge_scopes character varying(64)[] DEFAULT '{}'::character varying[] NOT NULL,
    status character varying(32) DEFAULT 'active'::character varying NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    display_mode character varying(32) DEFAULT 'side_panel'::character varying NOT NULL,
    launch_uri character varying(512) NOT NULL,
    oauth_client_id bigint,
    usage_scope character varying(32) DEFAULT 'all'::character varying NOT NULL,
    CONSTRAINT apps_display_mode_chk CHECK (((display_mode)::text = ANY (ARRAY[('side_panel'::character varying)::text, ('fullscreen'::character varying)::text, ('external_browser'::character varying)::text]))),
    CONSTRAINT apps_entry_kind_check CHECK (((entry_kind)::text = ANY (ARRAY[('webview'::character varying)::text, ('external'::character varying)::text, ('native'::character varying)::text, ('agent_card'::character varying)::text]))),
    CONSTRAINT apps_usage_scope_chk CHECK (((usage_scope)::text = ANY (ARRAY[('all'::character varying)::text, ('end_user'::character varying)::text, ('agent'::character varying)::text])))
);


--
-- Name: TABLE apps; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.apps IS 'H5/Native 应用';


--
-- Name: COLUMN apps.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.id IS '主键 ID';


--
-- Name: COLUMN apps.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN apps.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.tenant_id IS '租户 ID; NULL=平台预置应用, 可由平台管理员开放给租户';


--
-- Name: COLUMN apps.creator_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.creator_id IS '创建人';


--
-- Name: COLUMN apps.code; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.code IS '应用编码';


--
-- Name: COLUMN apps.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.name IS '应用名';


--
-- Name: COLUMN apps.description; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.description IS '描述';


--
-- Name: COLUMN apps.icon_url; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.icon_url IS '图标 URL';


--
-- Name: COLUMN apps.color; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.color IS '主色';


--
-- Name: COLUMN apps.entry_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.entry_kind IS 'DEPRECATED (F04): 用 display_mode 表达; v0.2 删除';


--
-- Name: COLUMN apps.url; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.url IS 'DEPRECATED (F04): 改用 launch_uri; v0.2 删除';


--
-- Name: COLUMN apps.category_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.category_id IS '分类 ID';


--
-- Name: COLUMN apps.sort_order; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.sort_order IS '排序';


--
-- Name: COLUMN apps.bridge_scopes; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.bridge_scopes IS 'DEPRECATED (F04): 用 app_oauth_clients.scopes 表达';


--
-- Name: COLUMN apps.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.status IS '状态';


--
-- Name: COLUMN apps.is_system; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.is_system IS '平台预置';


--
-- Name: COLUMN apps.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.metadata IS '元数据 JSON';


--
-- Name: COLUMN apps.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.created_at IS '创建时间';


--
-- Name: COLUMN apps.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.updated_at IS '更新时间';


--
-- Name: COLUMN apps.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.deleted_at IS '软删除时间';


--
-- Name: COLUMN apps.display_mode; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.display_mode IS 'F04: side_panel=侧边栏 (默认); fullscreen=全屏; external_browser=外部浏览器 (v0.2)';


--
-- Name: COLUMN apps.launch_uri; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.launch_uri IS 'F04: 用户点击后跳转的 H5 入口 URL (生产强制 HTTPS)';


--
-- Name: COLUMN apps.oauth_client_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.oauth_client_id IS 'F04: 对应的 app_oauth_clients.id (1:1; FK 在 000063 加)';


--
-- Name: COLUMN apps.usage_scope; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.apps.usage_scope IS 'F04: all=用户入口和数字员工装配; end_user=仅用户入口/工作台; agent=仅数字员工装配';


--
-- Name: apps_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.apps ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.apps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: audit_events; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.audit_events (
    id bigint NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    tenant_id bigint,
    account_id bigint,
    actor_kind character varying(16) NOT NULL,
    acting_as character varying(16) DEFAULT ''::character varying NOT NULL,
    domain character varying(32) NOT NULL,
    event_kind character varying(64) NOT NULL,
    severity character varying(16) DEFAULT 'info'::character varying NOT NULL,
    resource_kind character varying(32),
    resource_uuid character varying(64),
    target_account_id bigint,
    target_resource_uuid character varying(64),
    trace_id character varying(64),
    ip inet,
    ua character varying(512),
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    duration_ms integer DEFAULT 0 NOT NULL
);


--
-- Name: TABLE audit_events; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.audit_events IS 'v1 全量审计事实表（普通表；用户规模 ≤ 1000 阶段够用；超量后由 M10 分区化迁移，列名零改动）。';


--
-- Name: COLUMN audit_events.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.id IS '主键 ID';


--
-- Name: COLUMN audit_events.occurred_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.occurred_at IS '事件发生时间';


--
-- Name: COLUMN audit_events.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.tenant_id IS '租户 ID；NULL = 平台级';


--
-- Name: COLUMN audit_events.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.account_id IS '发起账号；系统事件可为 NULL';


--
-- Name: COLUMN audit_events.actor_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.actor_kind IS '执行主体类型 user/agent/system/admin/platform_admin';


--
-- Name: COLUMN audit_events.acting_as; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.acting_as IS 'impersonate 时记录实际身份（如 platform_admin 切入租户时）';


--
-- Name: COLUMN audit_events.domain; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.domain IS '事件域 auth/agent/chat/group/skill/kb/drive/cron/runtime/compliance/...';


--
-- Name: COLUMN audit_events.event_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.event_kind IS '事件名 login.success / message.created / kb.recall / ...';


--
-- Name: COLUMN audit_events.severity; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.severity IS '严重级 info/warning/error/critical';


--
-- Name: COLUMN audit_events.resource_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.resource_kind IS '主体资源类型（如 agent/conversation/skill）';


--
-- Name: COLUMN audit_events.resource_uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.resource_uuid IS '主体资源 UUID';


--
-- Name: COLUMN audit_events.target_account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.target_account_id IS '目标账号（如 impersonate 目标 / 被踢账号）';


--
-- Name: COLUMN audit_events.target_resource_uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.target_resource_uuid IS '目标资源 UUID';


--
-- Name: COLUMN audit_events.trace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.trace_id IS 'OpenTelemetry trace_id';


--
-- Name: COLUMN audit_events.ip; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.ip IS '请求来源 IP';


--
-- Name: COLUMN audit_events.ua; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.ua IS '请求 User-Agent';


--
-- Name: COLUMN audit_events.payload; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.payload IS '事件 payload（JSONB；schema 由 event_kind 决定；DLP 脱敏后入库）';


--
-- Name: COLUMN audit_events.duration_ms; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_events.duration_ms IS '事件处理耗时（ms）；非耗时事件填 0';


--
-- Name: audit_events_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.audit_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: audit_summary; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.audit_summary (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    bucket_date date NOT NULL,
    event_type character varying(64) NOT NULL,
    actor_kind character varying(16) NOT NULL,
    actor_id bigint,
    event_count integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_summary_actor_kind_check CHECK (((actor_kind)::text = ANY (ARRAY[('account'::character varying)::text, ('agent'::character varying)::text, ('system'::character varying)::text])))
);


--
-- Name: TABLE audit_summary; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.audit_summary IS '审计事件汇总(明细在 ClickHouse)';


--
-- Name: COLUMN audit_summary.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_summary.id IS '主键 ID';


--
-- Name: COLUMN audit_summary.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_summary.tenant_id IS '租户 ID';


--
-- Name: COLUMN audit_summary.bucket_date; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_summary.bucket_date IS '日期分桶';


--
-- Name: COLUMN audit_summary.event_type; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_summary.event_type IS '事件类型';


--
-- Name: COLUMN audit_summary.actor_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_summary.actor_kind IS '触发方 account/agent/system';


--
-- Name: COLUMN audit_summary.actor_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_summary.actor_id IS '触发者 ID';


--
-- Name: COLUMN audit_summary.event_count; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_summary.event_count IS '事件数';


--
-- Name: COLUMN audit_summary.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.audit_summary.created_at IS '创建时间';


--
-- Name: audit_summary_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.audit_summary ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.audit_summary_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_audit_events; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.auth_audit_events (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id bigint,
    session_id bigint,
    event_kind character varying(64) NOT NULL,
    event_status character varying(32) DEFAULT 'success'::character varying NOT NULL,
    actor_kind character varying(32),
    tenant_id bigint,
    workspace_id bigint,
    login_method character varying(32),
    target character varying(256),
    reason character varying(128),
    ip inet,
    user_agent character varying(512),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT auth_audit_events_event_status_check CHECK (((event_status)::text = ANY (ARRAY[('success'::character varying)::text, ('failure'::character varying)::text])))
);


--
-- Name: TABLE auth_audit_events; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.auth_audit_events IS '登录/撤销/锁定/scope 切换/impersonate 最小审计 (M8 接入详细审计前的过渡)';


--
-- Name: COLUMN auth_audit_events.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.id IS '主键 ID';


--
-- Name: COLUMN auth_audit_events.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN auth_audit_events.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.account_id IS '事件主体账号';


--
-- Name: COLUMN auth_audit_events.session_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.session_id IS '关联 login_sessions, 撤销/续期事件时填';


--
-- Name: COLUMN auth_audit_events.event_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.event_kind IS 'login.password / login.sms / login.oidc / logout / lock / unlock / scope.switch / impersonate.enter / impersonate.exit / role.revoke / session.revoke / password.change / mfa.enable';


--
-- Name: COLUMN auth_audit_events.event_status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.event_status IS 'success / failure';


--
-- Name: COLUMN auth_audit_events.actor_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.actor_kind IS '触发方: user / admin / system / scheduler';


--
-- Name: COLUMN auth_audit_events.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.tenant_id IS '事件发生时的租户上下文';


--
-- Name: COLUMN auth_audit_events.workspace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.workspace_id IS '事件发生时的工作区上下文';


--
-- Name: COLUMN auth_audit_events.login_method; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.login_method IS 'password / sms / oidc / refresh / impersonate (login 类事件)';


--
-- Name: COLUMN auth_audit_events.target; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.target IS '事件目标 (如 role.revoke 时填 role uuid)';


--
-- Name: COLUMN auth_audit_events.reason; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.reason IS '失败原因或撤销原因';


--
-- Name: COLUMN auth_audit_events.ip; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.ip IS '来源 IP';


--
-- Name: COLUMN auth_audit_events.user_agent; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.user_agent IS '客户端 User-Agent';


--
-- Name: COLUMN auth_audit_events.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.metadata IS '附加扩展 JSON (如 OIDC iss / scope 切换前后)';


--
-- Name: COLUMN auth_audit_events.occurred_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.auth_audit_events.occurred_at IS '事件时间';


--
-- Name: auth_audit_events_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.auth_audit_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.auth_audit_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: chat_media_refs; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.chat_media_refs (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    room_id bigint,
    sender_account_id bigint NOT NULL,
    media_kind smallint NOT NULL,
    source_kind text NOT NULL,
    drive_file_uuid uuid NOT NULL,
    storage_key text NOT NULL,
    file_name text NOT NULL,
    mime_type text DEFAULT 'application/octet-stream'::text NOT NULL,
    size_bytes bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_cmr_media_kind CHECK ((media_kind = ANY (ARRAY[2, 8]))),
    CONSTRAINT chk_cmr_source_kind CHECK ((source_kind = ANY (ARRAY['chat_upload'::text, 'drive'::text])))
);


--
-- Name: TABLE chat_media_refs; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.chat_media_refs IS 'P2.2c:聊天文件消息的会话级媒体引用;授权单元;preview/download 按 room_participants 成员鉴权后现签 302';


--
-- Name: COLUMN chat_media_refs.source_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.chat_media_refs.source_kind IS 'chat_upload=本地上传(scope=chat,uploader=sender);drive=引用云盘文件(创建时校验 sender viewer+,源 ACL 不放宽)';


--
-- Name: COLUMN chat_media_refs.storage_key; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.chat_media_refs.storage_key IS '快照 S3 key;不随源 drive 文件 move 变更;读时由 Bus 现签短 TTL,不查 drive ACL';


--
-- Name: chat_media_refs_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

CREATE SEQUENCE agent_bus.chat_media_refs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: chat_media_refs_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_bus; Owner: -
--

ALTER SEQUENCE agent_bus.chat_media_refs_id_seq OWNED BY agent_bus.chat_media_refs.id;


--
-- Name: chat_message_tasks; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.chat_message_tasks (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    conversation_uuid uuid NOT NULL,
    room_uuid text DEFAULT ''::text NOT NULL,
    agent_uuid uuid NOT NULL,
    agent_message_uuid uuid NOT NULL,
    stream_id character varying(64) NOT NULL,
    user_message_uuid uuid NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 5 NOT NULL,
    locked_by character varying(64),
    locked_until timestamp with time zone,
    next_retry_at timestamp with time zone DEFAULT now() NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT chat_message_tasks_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'done'::text, 'failed'::text, 'cancelled'::text, 'dlq'::text])))
);


--
-- Name: TABLE chat_message_tasks; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.chat_message_tasks IS 'doc-11/doc-12 Task D chat 消息队列: 发消息落库+入队, worker 异步消费调 Agent; 任务态独立于 messages.status, 同会话串行';


--
-- Name: COLUMN chat_message_tasks.agent_message_uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.chat_message_tasks.agent_message_uuid IS '已落库 agent 占位消息 uuid; 幂等键 (UNIQUE), 防 worker 崩溃重抢重复执行';


--
-- Name: COLUMN chat_message_tasks.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.chat_message_tasks.status IS 'queued|running|done|failed|cancelled|dlq (任务态, 与 messages.status 完全分离, 不污染消息枚举)';


--
-- Name: COLUMN chat_message_tasks.locked_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.chat_message_tasks.locked_by IS 'worker lease 持有者 (bus_node_id); 崩溃后 locked_until 超时由 RequeueExpired 回收';


--
-- Name: chat_message_tasks_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.chat_message_tasks ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.chat_message_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contact_policies; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.contact_policies (
    tenant_id bigint NOT NULL,
    default_landing character varying(32) DEFAULT 'org_tree'::character varying NOT NULL,
    default_show_phone character varying(16) DEFAULT 'department'::character varying NOT NULL,
    default_show_email character varying(16) DEFAULT 'department'::character varying NOT NULL,
    default_show_title character varying(16) DEFAULT 'all'::character varying NOT NULL,
    search_scope character varying(32) DEFAULT 'tenant'::character varying NOT NULL,
    who_can_create_group_with_agent character varying(32) DEFAULT 'any_member'::character varying NOT NULL,
    agents_default_invitable boolean DEFAULT false NOT NULL,
    humans_default_invitable boolean DEFAULT true NOT NULL,
    show_platform_agents boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contact_policies_default_landing_check CHECK (((default_landing)::text = ANY (ARRAY[('org_tree'::character varying)::text, ('agent_plaza'::character varying)::text]))),
    CONSTRAINT contact_policies_default_show_email_check CHECK (((default_show_email)::text = ANY (ARRAY[('all'::character varying)::text, ('department'::character varying)::text, ('self'::character varying)::text, ('hidden'::character varying)::text]))),
    CONSTRAINT contact_policies_default_show_phone_check CHECK (((default_show_phone)::text = ANY (ARRAY[('all'::character varying)::text, ('department'::character varying)::text, ('self'::character varying)::text, ('hidden'::character varying)::text]))),
    CONSTRAINT contact_policies_default_show_title_check CHECK (((default_show_title)::text = ANY (ARRAY[('all'::character varying)::text, ('department'::character varying)::text, ('self'::character varying)::text, ('hidden'::character varying)::text]))),
    CONSTRAINT contact_policies_search_scope_check CHECK (((search_scope)::text = ANY (ARRAY[('current_dept'::character varying)::text, ('tenant'::character varying)::text, ('tenant_plus_platform_agents'::character varying)::text]))),
    CONSTRAINT contact_policies_who_can_create_group_with_agent_check CHECK (((who_can_create_group_with_agent)::text = ANY (ARRAY[('tenant_admin'::character varying)::text, ('any_member'::character varying)::text, ('disabled'::character varying)::text])))
);


--
-- Name: TABLE contact_policies; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.contact_policies IS '租户级通讯录配置 (M2)';


--
-- Name: COLUMN contact_policies.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.tenant_id IS '租户 ID, 一对一';


--
-- Name: COLUMN contact_policies.default_landing; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.default_landing IS '客户端通讯录默认入口: org_tree=组织树 agent_plaza=数字员工广场';


--
-- Name: COLUMN contact_policies.default_show_phone; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.default_show_phone IS '电话字段默认可见性: all/department/self/hidden, 成员级 field_mask 优先';


--
-- Name: COLUMN contact_policies.default_show_email; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.default_show_email IS '邮箱字段默认可见性: 同上';


--
-- Name: COLUMN contact_policies.default_show_title; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.default_show_title IS '岗位字段默认可见性: 同上';


--
-- Name: COLUMN contact_policies.search_scope; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.search_scope IS '搜索范围: current_dept=当前部门 tenant=全租户 tenant_plus_platform_agents=全租户加平台预置数字员工';


--
-- Name: COLUMN contact_policies.who_can_create_group_with_agent; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.who_can_create_group_with_agent IS '谁能创建含 Agent 的群: tenant_admin=仅租户管理员 any_member=普通成员 disabled=禁用';


--
-- Name: COLUMN contact_policies.agents_default_invitable; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.agents_default_invitable IS '新建数字员工时 allow_invite_to_group 默认值兜底';


--
-- Name: COLUMN contact_policies.humans_default_invitable; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.humans_default_invitable IS '新成员 metadata.allow_invite_to_group 默认值兜底';


--
-- Name: COLUMN contact_policies.show_platform_agents; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.show_platform_agents IS '本租户客户端是否展示平台预置 Agent';


--
-- Name: COLUMN contact_policies.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.contact_policies.metadata IS '扩展配置 JSON';


--
-- Name: content_favorites; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.content_favorites (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    target_kind character varying(32) NOT NULL,
    drive_file_id bigint,
    kb_document_id bigint,
    CONSTRAINT content_favorites_soft_delete_check CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT content_favorites_target_check CHECK (((((target_kind)::text = 'drive_file'::text) AND (drive_file_id IS NOT NULL) AND (kb_document_id IS NULL)) OR (((target_kind)::text = 'kb_document'::text) AND (kb_document_id IS NOT NULL) AND (drive_file_id IS NULL)))),
    CONSTRAINT content_favorites_target_kind_check CHECK (((target_kind)::text = ANY ((ARRAY['drive_file'::character varying, 'kb_document'::character varying])::text[])))
);


--
-- Name: TABLE content_favorites; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.content_favorites IS 'F06 当前账号的文件收藏；支持 drive_file 与 kb_document，读取时必须重新校验目标资源权限';


--
-- Name: COLUMN content_favorites.target_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.content_favorites.target_kind IS '收藏目标类型：drive_file 或 kb_document';


--
-- Name: content_favorites_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.content_favorites ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.content_favorites_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: conversation_account_state; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.conversation_account_state (
    account_id bigint NOT NULL,
    conversation_uuid uuid NOT NULL,
    tenant_id bigint NOT NULL,
    hidden_at timestamp with time zone,
    last_read_message_uuid uuid,
    last_read_at timestamp with time zone,
    unread_snapshot integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    pinned_at timestamp with time zone,
    muted_at timestamp with time zone,
    marked_unread_at timestamp with time zone,
    last_read_message_seq bigint,
    cleared_at timestamp with time zone
);


--
-- Name: TABLE conversation_account_state; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.conversation_account_state IS 'module: m4 + a5; account 对 conversation 的私人视图态: hidden_at / last_read_*; 不影响全局 conversation 与 messages.';


--
-- Name: COLUMN conversation_account_state.pinned_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversation_account_state.pinned_at IS 'F09 P2 · per-account 置顶时间 (NULL=未置顶); 聚合层按此优先排序';


--
-- Name: COLUMN conversation_account_state.muted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversation_account_state.muted_at IS 'F09 P2 · per-account 免打扰时间 (NULL=未免打扰); 只影响客户端红点 / 通知, 不影响投递';


--
-- Name: COLUMN conversation_account_state.marked_unread_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversation_account_state.marked_unread_at IS 'F09 P2 · per-account 人工标为未读时间 (NULL=未标); 与 unread_count 独立, markRead / 新消息自动清';


--
-- Name: COLUMN conversation_account_state.last_read_message_seq; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversation_account_state.last_read_message_seq IS 'F09 P1 已读水位 (WuKong message_seq, per-account per-conversation). NULL=未上报过.';


--
-- Name: COLUMN conversation_account_state.cleared_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversation_account_state.cleared_at IS '当前账号清空聊天记录水位; 历史与列表摘要仅展示该时间之后的消息, 不影响其他账号.';


--
-- Name: conversation_message_files; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.conversation_message_files (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    conversation_uuid character varying(64) NOT NULL,
    message_uuid character varying(64) NOT NULL,
    account_id bigint NOT NULL,
    role character varying(16) DEFAULT 'user_input'::character varying NOT NULL,
    drive_file_uuid uuid NOT NULL,
    CONSTRAINT chk_cmf_role CHECK (((role)::text = ANY (ARRAY[('user_input'::character varying)::text, ('assistant_attachment'::character varying)::text, ('system'::character varying)::text, ('agent_output'::character varying)::text]))),
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: conversation_message_files_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.conversation_message_files ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.conversation_message_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: conversations; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.conversations (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    digital_employee_id bigint,
    room_id bigint,
    title character varying(256),
    source character varying(64),
    last_message_at timestamp with time zone,
    unread_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT conversations_check CHECK ((((digital_employee_id IS NOT NULL) AND (room_id IS NULL)) OR ((room_id IS NOT NULL) AND (digital_employee_id IS NULL))))
);


--
-- Name: TABLE conversations; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.conversations IS '会话(单聊或群聊)';


--
-- Name: COLUMN conversations.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.id IS '主键 ID';


--
-- Name: COLUMN conversations.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN conversations.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.tenant_id IS '租户 ID';


--
-- Name: COLUMN conversations.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.account_id IS '所属账号 ID';


--
-- Name: COLUMN conversations.digital_employee_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.digital_employee_id IS '单聊数字员工 ID';


--
-- Name: COLUMN conversations.room_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.room_id IS '群聊 ID';


--
-- Name: COLUMN conversations.title; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.title IS '会话别名';


--
-- Name: COLUMN conversations.source; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.source IS '来源 chat/group/api/cron';


--
-- Name: COLUMN conversations.last_message_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.last_message_at IS '最后一条消息时间';


--
-- Name: COLUMN conversations.unread_count; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.unread_count IS '未读消息数';


--
-- Name: COLUMN conversations.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.metadata IS '元数据 JSON';


--
-- Name: COLUMN conversations.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.created_at IS '创建时间';


--
-- Name: COLUMN conversations.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.updated_at IS '更新时间';


--
-- Name: COLUMN conversations.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.conversations.deleted_at IS '软删除时间';


--
-- Name: conversations_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.conversations ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.conversations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: departments; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.departments (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    parent_id bigint,
    path character varying(512) NOT NULL,
    depth smallint DEFAULT 0 NOT NULL,
    name character varying(128) NOT NULL,
    leader_id bigint,
    sort_order integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: TABLE departments; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.departments IS '部门/工作区(Workspace)树';


--
-- Name: COLUMN departments.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.id IS '主键 ID';


--
-- Name: COLUMN departments.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN departments.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.tenant_id IS '所属租户 ID';


--
-- Name: COLUMN departments.parent_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.parent_id IS '父部门 ID,NULL=根';


--
-- Name: COLUMN departments.path; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.path IS '物化路径 /a/b/c 用于子树查询';


--
-- Name: COLUMN departments.depth; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.depth IS '层级深度,根为 0';


--
-- Name: COLUMN departments.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.name IS '部门名称';


--
-- Name: COLUMN departments.leader_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.leader_id IS '负责人账号 ID';


--
-- Name: COLUMN departments.sort_order; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.sort_order IS '同级排序';


--
-- Name: COLUMN departments.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.metadata IS 'ADR-0010: external_code 跨 HR 系统对账码 (用户可选自定义, 替代之前的 code 字段)';


--
-- Name: COLUMN departments.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.created_at IS '创建时间';


--
-- Name: COLUMN departments.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.updated_at IS '更新时间';


--
-- Name: COLUMN departments.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.departments.deleted_at IS '软删除时间';


--
-- Name: departments_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.departments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.departments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: digital_employee_visibility_overrides; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.digital_employee_visibility_overrides (
    tenant_id bigint NOT NULL,
    digital_employee_id bigint NOT NULL,
    hidden boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE digital_employee_visibility_overrides; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.digital_employee_visibility_overrides IS '平台预置数字员工的租户级隐藏/排序覆盖 (M2); 仅当目标 digital_employees.source=platform 时生效';


--
-- Name: COLUMN digital_employee_visibility_overrides.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employee_visibility_overrides.tenant_id IS '租户 ID';


--
-- Name: COLUMN digital_employee_visibility_overrides.digital_employee_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employee_visibility_overrides.digital_employee_id IS '数字员工 ID, 必须 source=platform';


--
-- Name: COLUMN digital_employee_visibility_overrides.hidden; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employee_visibility_overrides.hidden IS '是否在本租户客户端隐藏';


--
-- Name: COLUMN digital_employee_visibility_overrides.sort_order; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employee_visibility_overrides.sort_order IS '展示排序, 升序; 平台默认 0';


--
-- Name: digital_employees; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.digital_employees (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint,
    creator_id bigint,
    name character varying(128) NOT NULL,
    avatar_url character varying(512),
    intro text,
    description text,
    welcome_msg text,
    recommended_questions jsonb DEFAULT '[]'::jsonb NOT NULL,
    tags character varying(32)[] DEFAULT '{}'::character varying[] NOT NULL,
    visibility character varying(32) DEFAULT 'private'::character varying NOT NULL,
    workspace_id bigint,
    is_default_for_creator boolean DEFAULT false NOT NULL,
    runtime_environment_id bigint,
    model_primary character varying(64),
    model_fallbacks character varying(64)[] DEFAULT '{}'::character varying[] NOT NULL,
    temperature real DEFAULT 0.7 NOT NULL,
    context_window integer DEFAULT 32768 NOT NULL,
    tool_allow character varying(128)[] DEFAULT '{}'::character varying[] NOT NULL,
    tool_deny character varying(128)[] DEFAULT '{}'::character varying[] NOT NULL,
    capabilities_declared jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying(32) DEFAULT 'draft'::character varying NOT NULL,
    current_version integer DEFAULT 0 NOT NULL,
    supports_group_chat boolean DEFAULT true NOT NULL,
    audit_retention_days integer DEFAULT 30 NOT NULL,
    requires_approval boolean DEFAULT false NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    position_label character varying(128),
    badges jsonb DEFAULT '[]'::jsonb NOT NULL,
    source character varying(32) DEFAULT 'enterprise'::character varying NOT NULL,
    contact_enabled boolean DEFAULT true NOT NULL,
    allow_invite_to_group boolean DEFAULT true NOT NULL,
    created_by bigint,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    callable_by_agents jsonb DEFAULT '{"mode": "all", "agent_ids": []}'::jsonb NOT NULL,
    a2a_card jsonb DEFAULT '{}'::jsonb NOT NULL,
    model_source text DEFAULT 'platform_whitelist'::text NOT NULL,
    model_service_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    model_service_api_key_ciphertext bytea,
    model_service_api_key_prefix text,
    model_service_api_key_version integer,
    execution_locus character varying(16) DEFAULT 'cloud'::character varying NOT NULL,
    local_engine character varying(24),
    CONSTRAINT chk_de_callable_mode CHECK (((callable_by_agents ->> 'mode'::text) = ANY (ARRAY['none'::text, 'all'::text, 'workspace'::text, 'explicit'::text]))),
    CONSTRAINT chk_de_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT digital_employees_execution_locus_check CHECK (((execution_locus)::text = ANY ((ARRAY['cloud'::character varying, 'local'::character varying])::text[]))),
    CONSTRAINT digital_employees_local_engine_check CHECK (((((execution_locus)::text = 'cloud'::text) AND (local_engine IS NULL)) OR (((execution_locus)::text = 'local'::text) AND (local_engine IS NOT NULL) AND ((local_engine)::text = ANY ((ARRAY['dsh'::character varying, 'codex_app_server'::character varying])::text[]))))),
    CONSTRAINT digital_employees_local_scope_check CHECK ((((execution_locus)::text <> 'local'::text) OR ((runtime_environment_id IS NULL) AND (((tenant_id IS NULL) AND ((source)::text = 'platform'::text) AND ((visibility)::text = 'platform'::text)) OR ((tenant_id IS NOT NULL) AND (creator_id IS NOT NULL) AND ((source)::text = 'personal'::text) AND ((visibility)::text = 'private'::text) AND (NULLIF((metadata ->> 'agent_key'::text), ''::text) IS NOT NULL)))))),
    CONSTRAINT digital_employees_model_source_check CHECK ((model_source = ANY (ARRAY['platform_whitelist'::text, 'byok'::text]))),
    CONSTRAINT digital_employees_private_creator_chk CHECK ((((visibility)::text <> 'private'::text) OR (creator_id IS NOT NULL))),
    CONSTRAINT digital_employees_source_chk CHECK (((source)::text = ANY (ARRAY[('enterprise'::character varying)::text, ('personal'::character varying)::text, ('platform'::character varying)::text]))),
    CONSTRAINT digital_employees_source_tenant_chk CHECK (((((source)::text = 'platform'::text) AND (tenant_id IS NULL) AND ((visibility)::text = 'platform'::text)) OR (((source)::text = ANY (ARRAY[('enterprise'::character varying)::text, ('personal'::character varying)::text])) AND (tenant_id IS NOT NULL) AND ((visibility)::text <> 'platform'::text)))),
    CONSTRAINT digital_employees_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('grayed'::character varying)::text, ('archived'::character varying)::text]))),
    CONSTRAINT digital_employees_visibility_check CHECK (((visibility)::text = ANY (ARRAY[('private'::character varying)::text, ('workspace'::character varying)::text, ('tenant'::character varying)::text, ('platform'::character varying)::text]))),
    CONSTRAINT digital_employees_workspace_dept_chk CHECK ((((visibility)::text <> 'workspace'::text) OR (workspace_id IS NOT NULL)))
);


--
-- Name: TABLE digital_employees; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.digital_employees IS '数字员工(原 openclaw_app_agents)';


--
-- Name: COLUMN digital_employees.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.id IS '主键 ID';


--
-- Name: COLUMN digital_employees.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN digital_employees.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.tenant_id IS '所属租户 ID';


--
-- Name: COLUMN digital_employees.creator_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.creator_id IS '创建人账号 ID';


--
-- Name: COLUMN digital_employees.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.name IS '数字员工名';


--
-- Name: COLUMN digital_employees.avatar_url; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.avatar_url IS '头像 URL';


--
-- Name: COLUMN digital_employees.intro; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.intro IS '一句话介绍';


--
-- Name: COLUMN digital_employees.description; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.description IS '详细描述';


--
-- Name: COLUMN digital_employees.welcome_msg; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.welcome_msg IS '欢迎语';


--
-- Name: COLUMN digital_employees.recommended_questions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.recommended_questions IS '推荐问题列表 JSON';


--
-- Name: COLUMN digital_employees.tags; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.tags IS '标签数组';


--
-- Name: COLUMN digital_employees.visibility; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.visibility IS '可见性 private=私有 workspace=部门 tenant=租户 platform=平台';


--
-- Name: COLUMN digital_employees.workspace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.workspace_id IS '可见性=workspace 时的部门 ID';


--
-- Name: COLUMN digital_employees.is_default_for_creator; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.is_default_for_creator IS '是否为创建人的默认 Agent';


--
-- Name: COLUMN digital_employees.runtime_environment_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.runtime_environment_id IS 'Runtime 类型外键';


--
-- Name: COLUMN digital_employees.model_primary; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.model_primary IS '主模型 ID';


--
-- Name: COLUMN digital_employees.model_fallbacks; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.model_fallbacks IS '备用模型 ID 数组';


--
-- Name: COLUMN digital_employees.temperature; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.temperature IS '采样温度';


--
-- Name: COLUMN digital_employees.context_window; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.context_window IS '上下文窗口大小';


--
-- Name: COLUMN digital_employees.tool_allow; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.tool_allow IS '工具白名单';


--
-- Name: COLUMN digital_employees.tool_deny; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.tool_deny IS '工具黑名单';


--
-- Name: COLUMN digital_employees.capabilities_declared; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.capabilities_declared IS '能力声明 JSON {streaming,form,chart,artifact,file,voice,video,mcp}';


--
-- Name: COLUMN digital_employees.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.status IS '状态 draft/published/grayed/archived';


--
-- Name: COLUMN digital_employees.current_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.current_version IS '当前 published 版本号';


--
-- Name: COLUMN digital_employees.supports_group_chat; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.supports_group_chat IS 'Runtime 是否声明支持群聊上下文, 默认 true';


--
-- Name: COLUMN digital_employees.audit_retention_days; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.audit_retention_days IS '审计保留天数';


--
-- Name: COLUMN digital_employees.requires_approval; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.requires_approval IS '发布是否需要审批';


--
-- Name: COLUMN digital_employees.is_system; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.is_system IS '是否平台预置模板,true=不可删';


--
-- Name: COLUMN digital_employees.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.metadata IS '元数据 JSON';


--
-- Name: COLUMN digital_employees.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.created_at IS '创建时间';


--
-- Name: COLUMN digital_employees.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.updated_at IS '更新时间';


--
-- Name: COLUMN digital_employees.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.deleted_at IS '软删除时间';


--
-- Name: COLUMN digital_employees.position_label; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.position_label IS '通讯录卡片副标题, 数字员工岗位/职责描述';


--
-- Name: COLUMN digital_employees.badges; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.badges IS '徽章数组 JSON, 例如 ["enterprise_official","beta"]';


--
-- Name: COLUMN digital_employees.source; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.source IS '来源: enterprise=企业官方 personal=个人定制 platform=平台预置';


--
-- Name: COLUMN digital_employees.contact_enabled; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.contact_enabled IS '是否进入客户端通讯录, 默认 true';


--
-- Name: COLUMN digital_employees.allow_invite_to_group; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.allow_invite_to_group IS '管理员是否允许该数字员工被拉入群聊, 默认 true';


--
-- Name: COLUMN digital_employees.callable_by_agents; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.callable_by_agents IS 'F09 §4.7.3 A2A whitelist. mode: all / none / workspace / explicit; explicit uses agent_ids.';


--
-- Name: COLUMN digital_employees.a2a_card; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.a2a_card IS 'A2A 协作卡片 (v1b, plans/2026-07-06 §8.2): summary/when_to_use/…/requires_approval; service 层校验, 空对象 = 未配置';


--
-- Name: COLUMN digital_employees.model_source; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.model_source IS 'ADR-0037: 主模型来源。platform_whitelist(默认)=走 F10 §1.5.2 服务端白名单
    +共享 AIGC 网关; byok=使用 model_service_config+加密 api_key 直连 OpenClaw。';


--
-- Name: COLUMN digital_employees.model_service_config; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.model_service_config IS 'ADR-0037: BYOK 协议(endpoint_type)/base_url/model_id, 不含密钥; 契约 §12.3。
    model_source=byok 时生效, 写入前必须过 SSRFGuard (probe_ssrf.go)。';


--
-- Name: COLUMN digital_employees.model_service_api_key_ciphertext; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.model_service_api_key_ciphertext IS 'ADR-0037: AES-256-GCM 加密后的 BYOK api_key envelope
    ([version][nonce][ciphertext][tag], aesgcm.Cipher.Encrypt 产出)。
    绝不明文落库/落日志/API 响应回显。';


--
-- Name: COLUMN digital_employees.model_service_api_key_prefix; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.model_service_api_key_prefix IS 'ADR-0037: BYOK api_key 前缀, 审计事件 payload / GET 响应可见, 不解密就能
    识别哪把 key (照抄 tenant_ragflow_bindings.api_key_prefix 语义)。';


--
-- Name: COLUMN digital_employees.model_service_api_key_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.model_service_api_key_version IS 'ADR-0037: 加密该 api_key 时使用的主密钥版本号 (aesgcm.Cipher.Version())；
    未来 M2 multi-key rotate 时按此值选对应 Cipher 解密。';


--
-- Name: COLUMN digital_employees.execution_locus; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.execution_locus IS '执行位置：cloud 云端运行环境，local 当前登录电脑；与运行方式独立';


--
-- Name: COLUMN digital_employees.local_engine; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.digital_employees.local_engine IS '本地模板的引擎配置或实际本地员工的固定引擎；云端为 NULL';


--
-- Name: CONSTRAINT digital_employees_local_scope_check ON digital_employees; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON CONSTRAINT digital_employees_local_scope_check ON agent_bus.digital_employees IS '本地蓝图仅允许平台模板；实际员工仍限定个人私有、有创建者与独立身份、无云端环境';


--
-- Name: digital_employees_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.digital_employees ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.digital_employees_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_acl_entries; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_acl_entries (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    target_kind character varying(16) NOT NULL,
    target_id bigint NOT NULL,
    subject_kind character varying(16) NOT NULL,
    subject_id bigint,
    link_token_id bigint,
    role character varying(16) NOT NULL,
    granted_by bigint NOT NULL,
    CONSTRAINT chk_acl_role CHECK (((role)::text = ANY (ARRAY[('viewer'::character varying)::text, ('editor'::character varying)::text, ('manager'::character varying)::text]))),
    CONSTRAINT chk_acl_subject CHECK (((subject_kind)::text = ANY (ARRAY[('account'::character varying)::text, ('department'::character varying)::text, ('link_token'::character varying)::text]))),
    CONSTRAINT chk_acl_subject_id CHECK (((((subject_kind)::text = ANY (ARRAY[('account'::character varying)::text, ('department'::character varying)::text])) AND (subject_id IS NOT NULL) AND (link_token_id IS NULL)) OR (((subject_kind)::text = 'link_token'::text) AND (link_token_id IS NOT NULL) AND (subject_id IS NULL)))),
    CONSTRAINT chk_acl_target CHECK (((target_kind)::text = ANY (ARRAY[('space'::character varying)::text, ('folder'::character varying)::text, ('file'::character varying)::text]))),
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: drive_acl_entries_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_acl_entries ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_acl_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_file_versions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_file_versions (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    file_id bigint NOT NULL,
    version_no integer NOT NULL,
    storage_key character varying(512) NOT NULL,
    size_bytes bigint NOT NULL,
    sha256 character varying(64),
    name character varying(255) NOT NULL,
    upload_source character varying(32) NOT NULL,
    superseded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: drive_file_versions_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_file_versions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_file_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_files; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_files (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    space_id bigint NOT NULL,
    scope character varying(16) NOT NULL,
    source character varying(32) NOT NULL,
    drive_folder_id bigint,
    storage_key character varying(512) NOT NULL,
    name character varying(255) NOT NULL,
    mime_type character varying(128) DEFAULT ''::character varying NOT NULL,
    size_bytes bigint NOT NULL,
    sha256 character varying(64),
    origin_message_file_id bigint,
    origin_conversation_uuid character varying(64),
    origin_agent_id character varying(64),
    thumbnail_key character varying(512),
    thumbnail_status character varying(16) DEFAULT 'none'::character varying NOT NULL,
    copy_status character varying(16) DEFAULT 'ready'::character varying NOT NULL,
    copy_failure_reason text,
    copy_source_file_id bigint,
    copy_started_at timestamp with time zone,
    copy_finished_at timestamp with time zone,
    CONSTRAINT chk_chat_no_folder CHECK ((((scope)::text = 'drive'::text) OR (drive_folder_id IS NULL))),
    CONSTRAINT chk_copy_failure_reason CHECK ((((copy_status)::text = 'copy_failed'::text) OR (copy_failure_reason IS NULL))),
    CONSTRAINT chk_copy_status CHECK (((copy_status)::text = ANY (ARRAY[('ready'::character varying)::text, ('copying'::character varying)::text, ('copy_failed'::character varying)::text]))),
    CONSTRAINT chk_scope CHECK (((scope)::text = ANY (ARRAY[('drive'::character varying)::text, ('chat'::character varying)::text]))),
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT chk_source CHECK (((source)::text = ANY (ARRAY[('user_upload'::character varying)::text, ('chat_upload'::character varying)::text, ('chat_import'::character varying)::text, ('agent_output'::character varying)::text, ('kb_upload'::character varying)::text]))),
    CONSTRAINT chk_thumb_status CHECK (((thumbnail_status)::text = ANY (ARRAY[('none'::character varying)::text, ('pending'::character varying)::text, ('ready'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: drive_files_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_files ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_folders; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_folders (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    space_id bigint NOT NULL,
    parent_id bigint,
    name character varying(255) NOT NULL,
    kind character varying(32) DEFAULT 'regular'::character varying NOT NULL,
    agent_id character varying(64),
    is_system boolean DEFAULT false NOT NULL,
    path character varying(1024) DEFAULT ''::character varying NOT NULL,
    sort integer DEFAULT 0 NOT NULL,
    CONSTRAINT chk_folder_kind CHECK (((kind)::text = ANY (ARRAY[('regular'::character varying)::text, ('de_root'::character varying)::text, ('de_agent'::character varying)::text, ('de_outputs'::character varying)::text]))),
    CONSTRAINT chk_folder_kind_agent CHECK (((((kind)::text = ANY (ARRAY[('regular'::character varying)::text, ('de_root'::character varying)::text])) AND (agent_id IS NULL)) OR (((kind)::text = ANY (ARRAY[('de_agent'::character varying)::text, ('de_outputs'::character varying)::text])) AND (agent_id IS NOT NULL)))),
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: drive_folders_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_folders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_folders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_quotas; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_quotas (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    subject_kind character varying(16) NOT NULL,
    subject_id bigint,
    quota_bytes bigint NOT NULL,
    used_bytes bigint DEFAULT 0 NOT NULL,
    quota_source character varying(32) DEFAULT 'manual'::character varying NOT NULL,
    CONSTRAINT chk_drive_quota_source CHECK (((quota_source)::text = ANY ((ARRAY['manual'::character varying, 'billing_projection'::character varying])::text[]))),
    CONSTRAINT chk_quota_subject CHECK (((((subject_kind)::text = 'tenant'::text) AND (subject_id IS NULL)) OR (((subject_kind)::text = 'account'::text) AND (subject_id IS NOT NULL)))),
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: drive_quotas_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_quotas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_quotas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_recycle_bin; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_recycle_bin (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    target_kind character varying(16) NOT NULL,
    target_id bigint NOT NULL,
    space_id bigint NOT NULL,
    deleted_by bigint NOT NULL,
    deleted_at_logical timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    bytes_to_reclaim bigint NOT NULL,
    CONSTRAINT chk_recycle_target CHECK (((target_kind)::text = ANY (ARRAY[('file'::character varying)::text, ('folder'::character varying)::text]))),
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: drive_recycle_bin_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_recycle_bin ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_recycle_bin_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_share_links; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_share_links (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    token character varying(64) NOT NULL,
    target_kind character varying(16) NOT NULL,
    target_id bigint NOT NULL,
    role character varying(16) DEFAULT 'viewer'::character varying NOT NULL,
    download_disabled boolean DEFAULT false NOT NULL,
    expires_at timestamp with time zone,
    max_uses integer,
    used_count integer DEFAULT 0 NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT chk_link_role CHECK (((role)::text = ANY (ARRAY[('viewer'::character varying)::text, ('editor'::character varying)::text]))),
    CONSTRAINT chk_link_target CHECK (((target_kind)::text = ANY (ARRAY[('folder'::character varying)::text, ('file'::character varying)::text]))),
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: drive_share_links_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_share_links ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_share_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_spaces; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_spaces (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    kind character varying(16) NOT NULL,
    owner_account_id bigint,
    department_id bigint,
    name character varying(128) NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    used_bytes bigint DEFAULT 0 NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT chk_space_kind_owner CHECK (((((kind)::text = 'personal'::text) AND (owner_account_id IS NOT NULL) AND (department_id IS NULL)) OR (((kind)::text = 'tenant'::text) AND (owner_account_id IS NULL) AND (department_id IS NULL)) OR (((kind)::text = 'department'::text) AND (owner_account_id IS NULL) AND (department_id IS NOT NULL)) OR (((kind)::text = 'shared'::text) AND (owner_account_id IS NOT NULL) AND (department_id IS NULL)))),
    CONSTRAINT chk_space_status CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('archived'::character varying)::text])))
);


--
-- Name: COLUMN drive_spaces.description; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_spaces.description IS '共享文件夹描述; 当前仅 kind=shared 的用户创建入口写入';


--
-- Name: drive_spaces_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_spaces ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_spaces_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_storage_defaults; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_storage_defaults (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    name character varying(128) NOT NULL,
    kind character varying(16) NOT NULL,
    region character varying(64) DEFAULT ''::character varying NOT NULL,
    endpoint character varying(256) NOT NULL,
    read_endpoint character varying(256) DEFAULT ''::character varying NOT NULL,
    bucket character varying(128) NOT NULL,
    access_key_secret_ref character varying(256) NOT NULL,
    secret_key_secret_ref character varying(256) NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT chk_storage_ak_ref CHECK ((((access_key_secret_ref)::text ~~ 'env://%'::text) OR ((access_key_secret_ref)::text ~~ 'value://%'::text) OR ((access_key_secret_ref)::text ~~ 'vault://%'::text))),
    CONSTRAINT chk_storage_kind CHECK (((kind)::text = ANY (ARRAY[('oss'::character varying)::text, ('s3'::character varying)::text, ('minio'::character varying)::text]))),
    CONSTRAINT chk_storage_sk_ref CHECK ((((secret_key_secret_ref)::text ~~ 'env://%'::text) OR ((secret_key_secret_ref)::text ~~ 'value://%'::text) OR ((secret_key_secret_ref)::text ~~ 'vault://%'::text))),
    CONSTRAINT chk_storage_status CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('degraded'::character varying)::text, ('disabled'::character varying)::text])))
);


--
-- Name: drive_storage_defaults_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_storage_defaults ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_storage_defaults_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_storage_overrides; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_storage_overrides (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    default_id bigint,
    region character varying(64),
    endpoint character varying(256),
    read_endpoint character varying(256),
    bucket character varying(128),
    access_key_secret_ref character varying(256),
    secret_key_secret_ref character varying(256),
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    CONSTRAINT chk_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT chk_storage_ak_ref CHECK (((access_key_secret_ref IS NULL) OR ((access_key_secret_ref)::text ~~ 'env://%'::text) OR ((access_key_secret_ref)::text ~~ 'value://%'::text) OR ((access_key_secret_ref)::text ~~ 'vault://%'::text))),
    CONSTRAINT chk_storage_sk_ref CHECK (((secret_key_secret_ref IS NULL) OR ((secret_key_secret_ref)::text ~~ 'env://%'::text) OR ((secret_key_secret_ref)::text ~~ 'value://%'::text) OR ((secret_key_secret_ref)::text ~~ 'vault://%'::text))),
    CONSTRAINT chk_storage_status CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('degraded'::character varying)::text, ('disabled'::character varying)::text])))
);


--
-- Name: drive_storage_overrides_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_storage_overrides ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_storage_overrides_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_upload_tickets; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_upload_tickets (
    id bigint NOT NULL,
    file_uuid uuid NOT NULL,
    account_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    folder_id bigint,
    declared_size bigint NOT NULL,
    declared_mime character varying(128) DEFAULT ''::character varying NOT NULL,
    declared_name character varying(255) NOT NULL,
    staging_key character varying(512) NOT NULL,
    final_key character varying(512) NOT NULL,
    upload_id character varying(256),
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    part_size bigint,
    source character varying(32) DEFAULT 'user_upload'::character varying NOT NULL,
    space_id bigint,
    CONSTRAINT chk_ticket_source CHECK (((source)::text = ANY (ARRAY[('user_upload'::character varying)::text, ('chat_upload'::character varying)::text, ('chat_import'::character varying)::text, ('agent_output'::character varying)::text, ('kb_upload'::character varying)::text]))),
    CONSTRAINT chk_ticket_status CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('done'::character varying)::text, ('partial'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: COLUMN drive_upload_tickets.space_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_upload_tickets.space_id IS 'F06 space-root upload target. Required for root uploads; folder uploads also set it for confirm-time ACL.';


--
-- Name: drive_upload_tickets_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_upload_tickets ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_upload_tickets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_worker_job_failures; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_worker_job_failures (
    id bigint NOT NULL,
    job character varying(32) NOT NULL,
    tenant_id bigint,
    object_kind character varying(32) NOT NULL,
    object_ref character varying(128) NOT NULL,
    reason character varying(1000) NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_drive_worker_job_failures_job CHECK (((job)::text = ANY ((ARRAY['staging_reaper'::character varying, 'recycle_cleaner'::character varying, 'version_cleaner'::character varying, 'copy_executor'::character varying, 'thumbnail'::character varying])::text[]))),
    CONSTRAINT chk_drive_worker_job_failures_object_kind CHECK (((object_kind)::text = ANY ((ARRAY['upload_ticket'::character varying, 'recycle_entry'::character varying, 'file'::character varying, 'file_version'::character varying])::text[])))
);


--
-- Name: TABLE drive_worker_job_failures; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.drive_worker_job_failures IS 'F06: drive-worker 单对象失败明细; 「最近失败对象」有界诊断数据 (每轮 <= batch 上限, 14 天滚动清理), 非完整 run history';


--
-- Name: COLUMN drive_worker_job_failures.job; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_failures.job IS 'job code: staging_reaper/recycle_cleaner/version_cleaner/copy_executor/thumbnail';


--
-- Name: COLUMN drive_worker_job_failures.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_failures.tenant_id IS '失败对象所属租户; 解析不出时为 NULL; 诊断数据不挂 FK (租户清理不应阻塞明细写入)';


--
-- Name: COLUMN drive_worker_job_failures.object_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_failures.object_kind IS '失败对象类型: upload_ticket/recycle_entry/file/file_version';


--
-- Name: COLUMN drive_worker_job_failures.object_ref; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_failures.object_ref IS '失败对象标识 (uuid 或数字 id 的文本形式), 仅供排障定位';


--
-- Name: COLUMN drive_worker_job_failures.reason; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_failures.reason IS '失败原因摘要 (错误串截断到 1000 字符)';


--
-- Name: COLUMN drive_worker_job_failures.occurred_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_failures.occurred_at IS '失败发生时间 (worker 本轮结束落库)';


--
-- Name: drive_worker_job_failures_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_worker_job_failures ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_worker_job_failures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: drive_worker_job_status; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_worker_job_status (
    job character varying(64) NOT NULL,
    status character varying(16) DEFAULT 'success'::character varying NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    last_run_at timestamp with time zone,
    last_finished_at timestamp with time zone,
    last_run_duration_ms bigint,
    last_processed bigint DEFAULT 0 NOT NULL,
    last_success bigint DEFAULT 0 NOT NULL,
    last_failed bigint DEFAULT 0 NOT NULL,
    last_error text,
    consecutive_failures integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_drive_worker_job_status_counts CHECK (((last_processed >= 0) AND (last_success >= 0) AND (last_failed >= 0) AND (consecutive_failures >= 0))),
    CONSTRAINT chk_drive_worker_job_status_status CHECK (((status)::text = ANY ((ARRAY['running'::character varying, 'success'::character varying, 'failed'::character varying, 'disabled'::character varying])::text[])))
);


--
-- Name: TABLE drive_worker_job_status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.drive_worker_job_status IS 'F06 admin observability: latest status for each drive maintenance worker job.';


--
-- Name: COLUMN drive_worker_job_status.job; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_status.job IS 'Stable job code, e.g. staging_reaper, recycle_cleaner, version_cleaner.';


--
-- Name: COLUMN drive_worker_job_status.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_status.status IS 'Latest run state: running/success/failed/disabled.';


--
-- Name: COLUMN drive_worker_job_status.last_run_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_status.last_run_at IS 'Timestamp when the latest run started.';


--
-- Name: COLUMN drive_worker_job_status.last_finished_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_status.last_finished_at IS 'Timestamp when the latest run finished.';


--
-- Name: COLUMN drive_worker_job_status.last_processed; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_status.last_processed IS 'Business objects successfully processed in the latest run.';


--
-- Name: COLUMN drive_worker_job_status.last_error; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_status.last_error IS 'Latest run error summary; cleared on full success.';


--
-- Name: drive_worker_job_triggers; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.drive_worker_job_triggers (
    id bigint NOT NULL,
    job character varying(32) NOT NULL,
    requested_by bigint NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    consumed_at timestamp with time zone,
    lock_until timestamp with time zone,
    CONSTRAINT chk_drive_worker_job_triggers_job CHECK (((job)::text = ANY ((ARRAY['staging_reaper'::character varying, 'recycle_cleaner'::character varying, 'version_cleaner'::character varying])::text[])))
);


--
-- Name: TABLE drive_worker_job_triggers; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.drive_worker_job_triggers IS 'F06: 云盘定时任务手动触发队列; admin 入队, drive-worker 每 10s 抢占消费后立即跑一轮; 每 job 同时最多 1 条未消费 (部分唯一索引兜底幂等)';


--
-- Name: COLUMN drive_worker_job_triggers.job; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_triggers.job IS '仅 3 个 enabled job 可触发: staging_reaper/recycle_cleaner/version_cleaner';


--
-- Name: COLUMN drive_worker_job_triggers.requested_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_triggers.requested_by IS '发起触发的平台管理员 accounts.id (platform.drive.manage_workers)';


--
-- Name: COLUMN drive_worker_job_triggers.consumed_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_triggers.consumed_at IS '执行完成时间 (成功或业务失败均算完成; 仅 worker 崩溃留给租约重捡); NULL = 排队中或执行中; 消费行保留 30 天由入队时顺带清理';


--
-- Name: COLUMN drive_worker_job_triggers.lock_until; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.drive_worker_job_triggers.lock_until IS '执行租约到期时间; 认领时设 now()+15min, NULL 或已过期且未消费 = 可被(重新)认领';


--
-- Name: drive_worker_job_triggers_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.drive_worker_job_triggers ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.drive_worker_job_triggers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: events_outbox; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.events_outbox (
    id bigint NOT NULL,
    topic character varying(64) NOT NULL,
    tenant_id bigint,
    trace_id character varying(64),
    payload jsonb NOT NULL,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    attempts smallint DEFAULT 0 NOT NULL,
    last_error text,
    idempotency_key character varying(128),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    picked_at timestamp with time zone,
    done_at timestamp with time zone,
    next_retry_at timestamp with time zone,
    locked_by character varying(64),
    locked_until timestamp with time zone,
    CONSTRAINT events_outbox_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('picked'::character varying)::text, ('done'::character varying)::text, ('failed'::character varying)::text, ('dlq'::character varying)::text])))
);


--
-- Name: TABLE events_outbox; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.events_outbox IS '事件总线（事务原子点）；M0 由 cmd/audit-writer 消费 → 写 audit_events。未来切 Kafka 时只换实现。';


--
-- Name: COLUMN events_outbox.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.id IS '主键 ID';


--
-- Name: COLUMN events_outbox.topic; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.topic IS 'topic 名，对齐未来 Kafka topic（audit.* / billing.* / notify.* ...）';


--
-- Name: COLUMN events_outbox.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.tenant_id IS '租户 ID；NULL = 平台级事件';


--
-- Name: COLUMN events_outbox.trace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.trace_id IS 'OpenTelemetry trace_id 关联';


--
-- Name: COLUMN events_outbox.payload; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.payload IS '事件 payload（JSONB；schema 由 topic 决定）';


--
-- Name: COLUMN events_outbox.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.status IS '状态 pending/picked/done/failed/dlq';


--
-- Name: COLUMN events_outbox.attempts; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.attempts IS '消费失败重试次数';


--
-- Name: COLUMN events_outbox.last_error; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.last_error IS '最近一次失败原因';


--
-- Name: COLUMN events_outbox.idempotency_key; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.idempotency_key IS '调用方显式提供时去重（partial UNIQUE WHERE NOT NULL）；不提供则允许合法重复';


--
-- Name: COLUMN events_outbox.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.created_at IS '入库时间';


--
-- Name: COLUMN events_outbox.picked_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.picked_at IS 'audit-writer 拉走时间';


--
-- Name: COLUMN events_outbox.done_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.done_at IS '消费完成时间';


--
-- Name: COLUMN events_outbox.next_retry_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.next_retry_at IS 'F09-A6-04: 重试调度时间. NULL = 立即可领; failed 后 dispatcher 写 now()+backoff.';


--
-- Name: COLUMN events_outbox.locked_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.locked_by IS 'F09-A6-04: 当前持锁 worker instance ID (hostname+pid+随机); SKIP LOCKED + locked_until 兜底.';


--
-- Name: COLUMN events_outbox.locked_until; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox.locked_until IS 'F09-A6-04: lock 过期时间. worker 崩溃 → 过期后其它 worker 可重新 claim 该行.';


--
-- Name: events_outbox_dlq; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.events_outbox_dlq (
    id bigint NOT NULL,
    outbox_id bigint NOT NULL,
    topic character varying(64) NOT NULL,
    tenant_id bigint,
    trace_id character varying(64),
    payload jsonb NOT NULL,
    last_error text,
    attempts smallint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    dlq_at timestamp with time zone DEFAULT now() NOT NULL,
    dlq_reason text
);


--
-- Name: TABLE events_outbox_dlq; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.events_outbox_dlq IS '死信表：events_outbox 行重试达到上限后复制到此处；原行 status=''dlq''。';


--
-- Name: COLUMN events_outbox_dlq.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.id IS '主键 ID';


--
-- Name: COLUMN events_outbox_dlq.outbox_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.outbox_id IS '原 events_outbox.id（不级联，便于追溯）';


--
-- Name: COLUMN events_outbox_dlq.topic; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.topic IS 'topic 名';


--
-- Name: COLUMN events_outbox_dlq.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.tenant_id IS '租户 ID';


--
-- Name: COLUMN events_outbox_dlq.trace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.trace_id IS 'OpenTelemetry trace_id';


--
-- Name: COLUMN events_outbox_dlq.payload; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.payload IS '事件 payload（与原 outbox 行一致）';


--
-- Name: COLUMN events_outbox_dlq.last_error; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.last_error IS '最后一次失败原因';


--
-- Name: COLUMN events_outbox_dlq.attempts; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.attempts IS '总尝试次数';


--
-- Name: COLUMN events_outbox_dlq.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.created_at IS '原 events_outbox.created_at';


--
-- Name: COLUMN events_outbox_dlq.dlq_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.dlq_at IS '进入死信表时间';


--
-- Name: COLUMN events_outbox_dlq.dlq_reason; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.events_outbox_dlq.dlq_reason IS '进入死信表原因（attempts_exhausted / non_retriable / ...）';


--
-- Name: events_outbox_dlq_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.events_outbox_dlq ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.events_outbox_dlq_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: events_outbox_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.events_outbox ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.events_outbox_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenants; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.tenants (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(128) NOT NULL,
    slug character varying(64) NOT NULL,
    display_name character varying(128),
    description text,
    icon_url character varying(512),
    industry character varying(64),
    contact_email character varying(128),
    contact_phone character varying(32),
    owner_id bigint,
    status character varying(32) DEFAULT 'trial'::character varying NOT NULL,
    plan_id bigint,
    trial_ends_at timestamp with time zone,
    data_region character varying(32) DEFAULT 'cn'::character varying,
    timezone character varying(32) DEFAULT 'Asia/Shanghai'::character varying,
    locale character varying(16) DEFAULT 'zh-CN'::character varying,
    data_retention_days integer DEFAULT 180,
    brand jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT tenants_status_check CHECK (((status)::text = ANY (ARRAY[('trial'::character varying)::text, ('active'::character varying)::text, ('suspended'::character varying)::text, ('deactivated'::character varying)::text])))
);


--
-- Name: TABLE tenants; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.tenants IS '租户/企业';


--
-- Name: COLUMN tenants.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.id IS '主键 ID';


--
-- Name: COLUMN tenants.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.uuid IS '对外暴露的业务唯一标识';


--
-- Name: COLUMN tenants.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.name IS '租户名称';


--
-- Name: COLUMN tenants.slug; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.slug IS '子域名/路径用,全局唯一';


--
-- Name: COLUMN tenants.display_name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.display_name IS '展示名,空时使用 name';


--
-- Name: COLUMN tenants.description; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.description IS '租户描述';


--
-- Name: COLUMN tenants.icon_url; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.icon_url IS '租户图标 URL';


--
-- Name: COLUMN tenants.industry; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.industry IS '行业标签';


--
-- Name: COLUMN tenants.contact_email; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.contact_email IS '联系邮箱';


--
-- Name: COLUMN tenants.contact_phone; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.contact_phone IS '联系电话';


--
-- Name: COLUMN tenants.owner_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.owner_id IS '首席管理员账号 ID,关联 accounts.id';


--
-- Name: COLUMN tenants.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.status IS '状态 trial=试用 active=正式 suspended=暂停 deactivated=已下线';


--
-- Name: COLUMN tenants.plan_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.plan_id IS '历史套餐标记（只读迁移字段）；现行租户套餐以有效 subscriptions.plan_id 为唯一口径';


--
-- Name: COLUMN tenants.trial_ends_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.trial_ends_at IS '试用到期时间';


--
-- Name: COLUMN tenants.data_region; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.data_region IS '数据驻留地区 cn=中国 hk=香港';


--
-- Name: COLUMN tenants.timezone; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.timezone IS '租户默认时区';


--
-- Name: COLUMN tenants.locale; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.locale IS '租户默认语言';


--
-- Name: COLUMN tenants.data_retention_days; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.data_retention_days IS '数据保留天数';


--
-- Name: COLUMN tenants.brand; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.brand IS '品牌定制 JSON {logo, primary_color, welcome_msg}';


--
-- Name: COLUMN tenants.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.metadata IS '业务自定义元数据 JSON';


--
-- Name: COLUMN tenants.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.created_at IS '创建时间';


--
-- Name: COLUMN tenants.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.updated_at IS '最后更新时间';


--
-- Name: COLUMN tenants.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenants.deleted_at IS '软删除时间 NULL=未删除';


--
-- Name: tenant_member_positions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.tenant_member_positions (
    id bigint NOT NULL,
    membership_id bigint NOT NULL,
    position_id bigint NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    assigned_by bigint
);


--
-- Name: TABLE tenant_member_positions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.tenant_member_positions IS 'F01 §1: 员工 ↔ 职位 N:N (兼任). is_primary=true 唯一, 用于通讯录主显示.';


--
-- Name: tenant_memberships; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.tenant_memberships (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    department_id bigint NOT NULL,
    employee_id character varying(64),
    title character varying(128),
    nickname character varying(128),
    status character varying(32) DEFAULT 'active'::character varying NOT NULL,
    invited_by bigint,
    joined_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT tenant_memberships_status_check CHECK (((status)::text = ANY (ARRAY[('invited'::character varying)::text, ('active'::character varying)::text, ('suspended'::character varying)::text, ('left'::character varying)::text])))
);


--
-- Name: TABLE tenant_memberships; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.tenant_memberships IS '账号在某租户的成员资格';


--
-- Name: COLUMN tenant_memberships.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.id IS '主键 ID';


--
-- Name: COLUMN tenant_memberships.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.account_id IS '账号 ID';


--
-- Name: COLUMN tenant_memberships.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.tenant_id IS '租户 ID';


--
-- Name: COLUMN tenant_memberships.department_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.department_id IS '所属部门 ID；必填。未显式指定时业务服务归入当前租户最早创建的有效根部门';


--
-- Name: COLUMN tenant_memberships.employee_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.employee_id IS '该租户内的工号';


--
-- Name: COLUMN tenant_memberships.title; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.title IS '岗位名';


--
-- Name: COLUMN tenant_memberships.nickname; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.nickname IS '该租户内的显示名,可覆盖 accounts.display_name';


--
-- Name: COLUMN tenant_memberships.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.status IS '状态 invited=已邀请 active=可用 suspended=暂停 left=已离开';


--
-- Name: COLUMN tenant_memberships.invited_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.invited_by IS '邀请人账号 ID';


--
-- Name: COLUMN tenant_memberships.joined_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.joined_at IS '加入时间';


--
-- Name: COLUMN tenant_memberships.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.created_at IS '创建时间';


--
-- Name: COLUMN tenant_memberships.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.updated_at IS '更新时间';


--
-- Name: COLUMN tenant_memberships.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.deleted_at IS '软删除时间';


--
-- Name: COLUMN tenant_memberships.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_memberships.metadata IS '成员级通讯录配置等扩展字段; M2 约定: hidden_in_contacts/allow_invite_to_group/field_mask{phone,email,title}/position_label_override';


--
-- Name: tenant_positions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.tenant_positions (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    name character varying(128) NOT NULL,
    description character varying(256),
    icon character varying(64),
    sort_order integer DEFAULT 0 NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: TABLE tenant_positions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.tenant_positions IS 'F01 §1: 租户级职位字典 (例 销售经理 / 客服主管 / P6 工程师). 替代旧 tenant_memberships.title 自由文本.';


--
-- Name: COLUMN tenant_positions.is_system; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_positions.is_system IS '系统 seed 标记 (新租户初始化进的 10 个默认职位 is_system=true); UI 显示徽章, 但不强制只读 — 用户可改 / 删.';


--
-- Name: COLUMN tenant_positions.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_positions.metadata IS 'F01 §1 兜底字段. seed_key 标记系统初始化职位的内部 key (例 "employee"); external_code 跨 HR 系统对账码 (用户可选自定义)';


--
-- Name: im_connection_client_metadata; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.im_connection_client_metadata (
    tenant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    device_key character varying(64) NOT NULL,
    client_version character varying(64) DEFAULT ''::character varying NOT NULL,
    platform character varying(32) DEFAULT ''::character varying NOT NULL,
    os_version character varying(64) DEFAULT ''::character varying NOT NULL,
    reported_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT im_connection_client_metadata_device_key_sha256 CHECK (((device_key)::text ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: TABLE im_connection_client_metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.im_connection_client_metadata IS 'F09 客户端通过已鉴权 /im/credentials 上报的软件版本；按租户、账号和 WuKong DeviceID 哈希关联连接。';


--
-- Name: COLUMN im_connection_client_metadata.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.tenant_id IS '租户内部 ID；从已鉴权会话获取。';


--
-- Name: COLUMN im_connection_client_metadata.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.account_id IS '账号内部 ID；从已鉴权会话获取。';


--
-- Name: COLUMN im_connection_client_metadata.device_key; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.device_key IS 'WuKong CONNECT DeviceID 的 SHA-256 hex；禁止写明文 DeviceID。';


--
-- Name: COLUMN im_connection_client_metadata.client_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.client_version IS '知办安装包版本，格式 version+buildNumber；不是 WuKong 协议版本。';


--
-- Name: COLUMN im_connection_client_metadata.platform; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.platform IS '客户端结构化平台，如 macOS/Windows/Linux/Android/iOS/Web。';


--
-- Name: COLUMN im_connection_client_metadata.os_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.os_version IS '客户端上报的操作系统版本；空表示未上报。';


--
-- Name: COLUMN im_connection_client_metadata.reported_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.reported_at IS '客户端最近一次上报元数据的时间。';


--
-- Name: COLUMN im_connection_client_metadata.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.created_at IS '记录创建时间。';


--
-- Name: COLUMN im_connection_client_metadata.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_client_metadata.updated_at IS '记录最近更新时间。';


--
-- Name: im_connection_collector_status; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.im_connection_collector_status (
    singleton boolean DEFAULT true NOT NULL,
    last_attempt_at timestamp with time zone,
    last_success_at timestamp with time zone,
    last_error text DEFAULT ''::text NOT NULL,
    connection_total integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT im_connection_collector_status_singleton_check CHECK (singleton)
);


--
-- Name: TABLE im_connection_collector_status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.im_connection_collector_status IS 'F09 WuKong /connz collector 单例状态；错误须脱敏截断，供 Admin 展示采集健康。';


--
-- Name: im_connection_events; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.im_connection_events (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    state_uuid uuid NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint,
    uid character varying(256) NOT NULL,
    subject_kind character varying(16) NOT NULL,
    subject_uuid character varying(128) DEFAULT ''::character varying NOT NULL,
    device_key character varying(80) NOT NULL,
    device_id_masked character varying(32) DEFAULT ''::character varying NOT NULL,
    device_flag integer NOT NULL,
    device_level integer DEFAULT 0 NOT NULL,
    connection_id bigint NOT NULL,
    previous_connection_id bigint,
    event_type character varying(32) NOT NULL,
    reason character varying(64) DEFAULT ''::character varying NOT NULL,
    protocol_version character varying(64) DEFAULT ''::character varying NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT im_connection_events_event_type_check CHECK (((event_type)::text = ANY ((ARRAY['connected'::character varying, 'reconnected'::character varying, 'disconnected'::character varying])::text[]))),
    CONSTRAINT im_connection_events_subject_kind_check CHECK (((subject_kind)::text = ANY ((ARRAY['human'::character varying, 'agent'::character varying, 'unknown'::character varying])::text[])))
);


--
-- Name: TABLE im_connection_events; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.im_connection_events IS 'F09 IM 连接事件（30 天保留）：连接、同设备重连、连续两个采集周期未见。无消息正文与连接密钥。';


--
-- Name: COLUMN im_connection_events.protocol_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_events.protocol_version IS '事件发生时的 WuKong CONNECT 协议版本。';


--
-- Name: im_connection_events_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.im_connection_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.im_connection_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: im_connection_states; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.im_connection_states (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint,
    uid character varying(256) NOT NULL,
    subject_kind character varying(16) NOT NULL,
    subject_uuid character varying(128) DEFAULT ''::character varying NOT NULL,
    device_key character varying(80) NOT NULL,
    device_id_masked character varying(32) DEFAULT ''::character varying NOT NULL,
    device_id_available boolean DEFAULT false NOT NULL,
    device_flag integer NOT NULL,
    device_level integer DEFAULT 0 NOT NULL,
    connection_id bigint NOT NULL,
    protocol_version character varying(64) DEFAULT ''::character varying NOT NULL,
    status character varying(16) DEFAULT 'online'::character varying NOT NULL,
    connected_at timestamp with time zone,
    last_activity_at timestamp with time zone,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_event_type character varying(32) DEFAULT 'connected'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT im_connection_states_status_check CHECK (((status)::text = ANY ((ARRAY['online'::character varying, 'offline'::character varying])::text[]))),
    CONSTRAINT im_connection_states_subject_kind_check CHECK (((subject_kind)::text = ANY ((ARRAY['human'::character varying, 'agent'::character varying, 'unknown'::character varying])::text[])))
);


--
-- Name: TABLE im_connection_states; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.im_connection_states IS 'F09 IM 在线连接最新快照；cmd/bus 从 WuKong /connz 采集，Admin 平台只读。';


--
-- Name: COLUMN im_connection_states.device_key; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_states.device_key IS '有 device_id 时为 SHA-256 hex；缺失时为 flag:<device_flag>，不得视为精确物理设备。';


--
-- Name: COLUMN im_connection_states.device_id_masked; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_states.device_id_masked IS '仅保留首尾少量字符的展示掩码；禁止写明文 DeviceID。';


--
-- Name: COLUMN im_connection_states.protocol_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.im_connection_states.protocol_version IS 'WuKong CONNECT 协议版本（/connz.version），不是知办客户端版本。';


--
-- Name: im_connection_states_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.im_connection_states ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.im_connection_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: kb_documents; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.kb_documents (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    kb_id bigint NOT NULL,
    folder_id bigint,
    title character varying(256) NOT NULL,
    source_kind character varying(32) DEFAULT 'upload'::character varying NOT NULL,
    source_url character varying(512),
    storage_key character varying(512),
    mime_type character varying(128),
    file_size bigint,
    chunk_count integer DEFAULT 0 NOT NULL,
    status character varying(32) DEFAULT 'pending'::character varying NOT NULL,
    error_message text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    provider_doc_id character varying(128),
    ragflow_document_id character varying(64),
    drive_file_uuid character varying(64),
    token_count integer DEFAULT 0 NOT NULL,
    content_sha256 character(64),
    original_name character varying(256),
    deleted_by bigint,
    upload_idempotency_key uuid,
    upload_ordinal integer,
    CONSTRAINT chk_kb_document_upload_idempotency CHECK ((((upload_idempotency_key IS NULL) AND (upload_ordinal IS NULL)) OR ((upload_idempotency_key IS NOT NULL) AND (upload_ordinal IS NOT NULL) AND (upload_ordinal >= 0)))),
    CONSTRAINT kb_documents_status_check CHECK (((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('ingesting'::character varying)::text, ('ready'::character varying)::text, ('failed'::character varying)::text, ('disabled'::character varying)::text])))
);


--
-- Name: TABLE kb_documents; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.kb_documents IS '知识库文档';


--
-- Name: COLUMN kb_documents.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.id IS '主键 ID';


--
-- Name: COLUMN kb_documents.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN kb_documents.kb_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.kb_id IS '知识库 ID';


--
-- Name: COLUMN kb_documents.folder_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.folder_id IS '目录 ID';


--
-- Name: COLUMN kb_documents.title; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.title IS '文档标题';


--
-- Name: COLUMN kb_documents.source_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.source_kind IS '数据源 upload/url/feishu/confluence/api';


--
-- Name: COLUMN kb_documents.source_url; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.source_url IS '原始 URL';


--
-- Name: COLUMN kb_documents.storage_key; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.storage_key IS '存储 Key';


--
-- Name: COLUMN kb_documents.mime_type; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.mime_type IS 'MIME';


--
-- Name: COLUMN kb_documents.file_size; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.file_size IS '大小(字节)';


--
-- Name: COLUMN kb_documents.chunk_count; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.chunk_count IS '切片数';


--
-- Name: COLUMN kb_documents.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.status IS '状态 pending/ingesting/ready/failed/disabled';


--
-- Name: COLUMN kb_documents.error_message; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.error_message IS '错误信息';


--
-- Name: COLUMN kb_documents.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.metadata IS '元数据 JSON';


--
-- Name: COLUMN kb_documents.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.created_at IS '创建时间';


--
-- Name: COLUMN kb_documents.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.updated_at IS '更新时间';


--
-- Name: COLUMN kb_documents.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.deleted_at IS '软删除时间';


--
-- Name: COLUMN kb_documents.provider_doc_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.provider_doc_id IS 'M8 Phase A · provider 内部文档 id (stub 时取 kb_documents.uuid 的字符串形式)';


--
-- Name: COLUMN kb_documents.ragflow_document_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.ragflow_document_id IS 'RAGFlow 侧 document.id, 用于轮询 run 状态';


--
-- Name: COLUMN kb_documents.drive_file_uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.drive_file_uuid IS 'source_kind=drive_sync 时关联 F06 drive_files.uuid; F06 文件变更触发重 ingest';


--
-- Name: COLUMN kb_documents.token_count; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_documents.token_count IS 'RAGFlow 返回的 token_num, 计费用';


--
-- Name: kb_documents_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.kb_documents ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.kb_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: kb_folders; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.kb_folders (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    kb_id bigint NOT NULL,
    parent_id bigint,
    path character varying(512) NOT NULL,
    name character varying(128) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: TABLE kb_folders; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.kb_folders IS '知识库目录';


--
-- Name: COLUMN kb_folders.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.id IS '主键 ID';


--
-- Name: COLUMN kb_folders.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN kb_folders.kb_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.kb_id IS '知识库 ID';


--
-- Name: COLUMN kb_folders.parent_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.parent_id IS '父目录';


--
-- Name: COLUMN kb_folders.path; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.path IS '物化路径';


--
-- Name: COLUMN kb_folders.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.name IS '目录名';


--
-- Name: COLUMN kb_folders.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.created_at IS '创建时间';


--
-- Name: COLUMN kb_folders.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.updated_at IS '更新时间';


--
-- Name: COLUMN kb_folders.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_folders.deleted_at IS '软删除时间';


--
-- Name: kb_folders_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.kb_folders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.kb_folders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: kb_provider_config; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.kb_provider_config (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_kind character varying(32) NOT NULL,
    name character varying(128) NOT NULL,
    endpoint_url character varying(512) DEFAULT ''::character varying NOT NULL,
    api_key_ref character varying(128) DEFAULT ''::character varying NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    health_checked_at timestamp with time zone,
    health_message text,
    admin_email character varying(256) DEFAULT ''::character varying NOT NULL,
    admin_pass_ciphertext bytea,
    CONSTRAINT kb_provider_config_provider_kind_check CHECK (((provider_kind)::text = ANY (ARRAY[('stub'::character varying)::text, ('dify'::character varying)::text, ('tablestore'::character varying)::text, ('ragflow'::character varying)::text]))),
    CONSTRAINT kb_provider_config_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('degraded'::character varying)::text, ('disabled'::character varying)::text])))
);


--
-- Name: TABLE kb_provider_config; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.kb_provider_config IS 'M8 Phase A 知识库 provider 配置; Phase A 只有 stub provider 一行';


--
-- Name: COLUMN kb_provider_config.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.id IS '主键 ID';


--
-- Name: COLUMN kb_provider_config.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN kb_provider_config.provider_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.provider_kind IS 'provider 实现: stub/dify/tablestore (Phase A 仅 stub)';


--
-- Name: COLUMN kb_provider_config.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.name IS '展示名';


--
-- Name: COLUMN kb_provider_config.endpoint_url; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.endpoint_url IS 'provider HTTP endpoint (stub 为空)';


--
-- Name: COLUMN kb_provider_config.api_key_ref; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.api_key_ref IS 'API key 引用 (Phase A 不用)';


--
-- Name: COLUMN kb_provider_config.settings; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.settings IS 'provider 配置 JSON (top_k / threshold 等默认)';


--
-- Name: COLUMN kb_provider_config.is_default; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.is_default IS '是否为默认 provider (partial UNIQUE 保证仅 1 行)';


--
-- Name: COLUMN kb_provider_config.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.status IS '状态 active/disabled';


--
-- Name: COLUMN kb_provider_config.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.created_at IS '创建时间';


--
-- Name: COLUMN kb_provider_config.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.updated_at IS '更新时间';


--
-- Name: COLUMN kb_provider_config.health_checked_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.health_checked_at IS 'module: m8b; 最近一次 health-check 完成时间';


--
-- Name: COLUMN kb_provider_config.health_message; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.health_message IS 'module: m8b; 最近一次 health-check 文本（失败时含 endpoint + status code）';


--
-- Name: COLUMN kb_provider_config.admin_email; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.admin_email IS 'F07 D2: ragflow admin server (9381) 登录邮箱; 仅 provider_kind=ragflow 用';


--
-- Name: COLUMN kb_provider_config.admin_pass_ciphertext; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.kb_provider_config.admin_pass_ciphertext IS 'F07 D2/D3: AES-GCM 加密 admin 密码; agent-bus 启动期 admin login 用';


--
-- Name: kb_provider_config_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.kb_provider_config ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.kb_provider_config_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: knowledge_bases; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.knowledge_bases (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint,
    creator_id bigint NOT NULL,
    space_kind character varying(32) NOT NULL,
    workspace_id bigint,
    name character varying(128) NOT NULL,
    description text,
    icon character varying(64),
    embedding_model character varying(64),
    chunk_strategy character varying(32) DEFAULT 'recursive'::character varying,
    retrieval_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    visibility character varying(32) DEFAULT 'private'::character varying NOT NULL,
    status character varying(32) DEFAULT 'active'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    provider_id bigint,
    total_documents integer DEFAULT 0 NOT NULL,
    provider_kind character varying(16) DEFAULT 'stub'::character varying NOT NULL,
    ragflow_dataset_id character varying(64),
    owner_account_id bigint,
    provision_status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    last_recall_at timestamp with time zone,
    access_mode character varying(24) DEFAULT 'workspace'::character varying NOT NULL,
    deleted_by bigint,
    provision_error text,
    CONSTRAINT chk_kb_scope_shape CHECK (((deleted_at IS NOT NULL) OR (((space_kind)::text = 'platform'::text) AND (tenant_id IS NULL) AND (owner_account_id IS NULL) AND (workspace_id IS NULL) AND ((visibility)::text = 'platform'::text) AND ((access_mode)::text = 'agent_only'::text)) OR (((space_kind)::text = 'tenant'::text) AND (tenant_id IS NOT NULL) AND (owner_account_id IS NULL) AND ((visibility)::text = 'tenant'::text)) OR (((space_kind)::text = 'personal'::text) AND (tenant_id IS NOT NULL) AND (owner_account_id IS NOT NULL) AND ((visibility)::text = 'private'::text)) OR (((space_kind)::text = 'workspace'::text) AND (tenant_id IS NOT NULL) AND (workspace_id IS NOT NULL) AND ((visibility)::text = 'workspace'::text)))),
    CONSTRAINT knowledge_bases_access_mode_check CHECK (((access_mode)::text = ANY ((ARRAY['workspace'::character varying, 'agent_only'::character varying])::text[]))),
    CONSTRAINT knowledge_bases_provider_kind_check CHECK (((provider_kind)::text = ANY (ARRAY[('ragflow'::character varying)::text, ('stub'::character varying)::text]))),
    CONSTRAINT knowledge_bases_provision_status_check CHECK (((provision_status)::text = ANY (ARRAY[('pending'::character varying)::text, ('active'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT knowledge_bases_space_kind_check CHECK (((space_kind)::text = ANY (ARRAY[('personal'::character varying)::text, ('workspace'::character varying)::text, ('tenant'::character varying)::text, ('platform'::character varying)::text]))),
    CONSTRAINT knowledge_bases_visibility_check CHECK (((visibility)::text = ANY (ARRAY[('private'::character varying)::text, ('workspace'::character varying)::text, ('tenant'::character varying)::text, ('platform'::character varying)::text])))
);


--
-- Name: TABLE knowledge_bases; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.knowledge_bases IS '知识库';


--
-- Name: COLUMN knowledge_bases.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.id IS '主键 ID';


--
-- Name: COLUMN knowledge_bases.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN knowledge_bases.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.tenant_id IS '租户 ID';


--
-- Name: COLUMN knowledge_bases.creator_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.creator_id IS '创建人';


--
-- Name: COLUMN knowledge_bases.space_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.space_kind IS '空间类型 personal/workspace/tenant/platform';


--
-- Name: COLUMN knowledge_bases.workspace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.workspace_id IS '部门 ID(workspace 空间)';


--
-- Name: COLUMN knowledge_bases.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.name IS '名称';


--
-- Name: COLUMN knowledge_bases.description; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.description IS '描述';


--
-- Name: COLUMN knowledge_bases.icon; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.icon IS '图标';


--
-- Name: COLUMN knowledge_bases.embedding_model; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.embedding_model IS 'embedding 模型';


--
-- Name: COLUMN knowledge_bases.chunk_strategy; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.chunk_strategy IS '切片策略';


--
-- Name: COLUMN knowledge_bases.retrieval_config; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.retrieval_config IS '召回配置 JSON';


--
-- Name: COLUMN knowledge_bases.visibility; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.visibility IS '可见性 private/workspace/tenant/platform';


--
-- Name: COLUMN knowledge_bases.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.status IS '状态';


--
-- Name: COLUMN knowledge_bases.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.metadata IS '元数据 JSON';


--
-- Name: COLUMN knowledge_bases.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.created_at IS '创建时间';


--
-- Name: COLUMN knowledge_bases.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.updated_at IS '更新时间';


--
-- Name: COLUMN knowledge_bases.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.deleted_at IS '软删除时间';


--
-- Name: COLUMN knowledge_bases.provider_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.provider_id IS 'M8 Phase A · 关联 kb_provider_config.id; NULL 时 service 层落到默认 provider';


--
-- Name: COLUMN knowledge_bases.total_documents; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.total_documents IS 'M8 Phase A · 文档计数 (service 层在 upload/delete 同事务维护)';


--
-- Name: COLUMN knowledge_bases.provider_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.provider_kind IS 'F07 D11: ragflow=生产 / stub=dev-only; Dify 已弃用';


--
-- Name: COLUMN knowledge_bases.ragflow_dataset_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.ragflow_dataset_id IS 'RAGFlow 侧 dataset.id, 由 lazy provision 写入';


--
-- Name: COLUMN knowledge_bases.owner_account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.owner_account_id IS 'space_kind=personal 时 = 该用户; tenant/platform 时 NULL; 加速 visibility 过滤 (D5)';


--
-- Name: COLUMN knowledge_bases.provision_status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.provision_status IS 'pending=正在 RAGFlow 那侧建 dataset; active=就绪; failed=需 reconcile (D2)';


--
-- Name: COLUMN knowledge_bases.last_recall_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.knowledge_bases.last_recall_at IS '最后一次检索时间, 用量统计';


--
-- Name: knowledge_bases_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.knowledge_bases ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.knowledge_bases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: login_sessions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.login_sessions (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id bigint NOT NULL,
    refresh_token_hash character varying(128) NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    last_used_at timestamp with time zone DEFAULT now() NOT NULL,
    act_scope_kind character varying(32) NOT NULL,
    act_tenant_id bigint,
    act_workspace_id bigint,
    acting_as character varying(64),
    user_agent character varying(512),
    ip inet,
    device_fingerprint character varying(128),
    revoked_at timestamp with time zone,
    revoke_reason character varying(64),
    device_type character varying(32),
    device_brand character varying(64),
    device_model character varying(128),
    device_system_version character varying(64),
    device_app_version character varying(32),
    prev_refresh_token_hash text,
    prev_hash_expires_at timestamp with time zone,
    CONSTRAINT login_sessions_act_scope_kind_check CHECK (((act_scope_kind)::text = ANY (ARRAY[('platform'::character varying)::text, ('tenant'::character varying)::text, ('workspace'::character varying)::text]))),
    CONSTRAINT login_sessions_check CHECK (((((act_scope_kind)::text = 'platform'::text) AND (act_tenant_id IS NULL) AND (act_workspace_id IS NULL)) OR (((act_scope_kind)::text = 'tenant'::text) AND (act_tenant_id IS NOT NULL) AND (act_workspace_id IS NULL)) OR (((act_scope_kind)::text = 'workspace'::text) AND (act_tenant_id IS NOT NULL) AND (act_workspace_id IS NOT NULL))))
);


--
-- Name: TABLE login_sessions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.login_sessions IS '活跃登录会话 (refresh token 索引), M1 身份与登录';


--
-- Name: COLUMN login_sessions.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.id IS '主键 ID';


--
-- Name: COLUMN login_sessions.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.uuid IS '对外业务唯一标识 (= JWT sid claim)';


--
-- Name: COLUMN login_sessions.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.account_id IS '账号 ID';


--
-- Name: COLUMN login_sessions.refresh_token_hash; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.refresh_token_hash IS 'refresh token sha256, 入库不存明文';


--
-- Name: COLUMN login_sessions.issued_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.issued_at IS '会话创建时间';


--
-- Name: COLUMN login_sessions.expires_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.expires_at IS 'refresh token 到期时间';


--
-- Name: COLUMN login_sessions.last_used_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.last_used_at IS '最近一次 refresh 时间';


--
-- Name: COLUMN login_sessions.act_scope_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.act_scope_kind IS '当前生效 scope: platform/tenant/workspace';


--
-- Name: COLUMN login_sessions.act_tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.act_tenant_id IS 'scope=tenant/workspace 时的租户 ID';


--
-- Name: COLUMN login_sessions.act_workspace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.act_workspace_id IS 'scope=workspace 时的部门 ID';


--
-- Name: COLUMN login_sessions.acting_as; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.acting_as IS 'impersonate 标记, 如 platform_admin (60min 内代入租户身份)';


--
-- Name: COLUMN login_sessions.user_agent; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.user_agent IS '客户端 User-Agent';


--
-- Name: COLUMN login_sessions.ip; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.ip IS '登录来源 IP';


--
-- Name: COLUMN login_sessions.device_fingerprint; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.device_fingerprint IS '设备指纹 (客户端上报)';


--
-- Name: COLUMN login_sessions.revoked_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.revoked_at IS '撤销时间 (logout/管理员强制下线/换密)';


--
-- Name: COLUMN login_sessions.revoke_reason; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.revoke_reason IS 'logout/role_revoke/password_change/admin_force';


--
-- Name: COLUMN login_sessions.device_type; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.device_type IS '客户端登录时上报的平台类型: macOS/Windows/Linux/Android/iOS/Web；NULL=旧客户端未上报';


--
-- Name: COLUMN login_sessions.device_brand; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.device_brand IS '客户端登录时上报的设备品牌（如 Apple/Samsung）；NULL=旧客户端未上报';


--
-- Name: COLUMN login_sessions.device_model; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.device_model IS '客户端登录时上报的设备型号；NULL=旧客户端未上报';


--
-- Name: COLUMN login_sessions.device_system_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.device_system_version IS '客户端登录时上报的操作系统版本；NULL=旧客户端未上报';


--
-- Name: COLUMN login_sessions.device_app_version; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.device_app_version IS '客户端登录时上报的 App 版本号；NULL=旧客户端未上报';


--
-- Name: COLUMN login_sessions.prev_refresh_token_hash; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.prev_refresh_token_hash IS '上一枚 refresh token 的 hash, 旋转宽限窗内仍可用于续期 (防响应丢失杀会话)';


--
-- Name: COLUMN login_sessions.prev_hash_expires_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.login_sessions.prev_hash_expires_at IS 'prev_refresh_token_hash 的宽限截止时间';


--
-- Name: login_sessions_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.login_sessions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.login_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: menu_permissions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.menu_permissions (
    menu_id bigint NOT NULL,
    permission_id bigint NOT NULL
);


--
-- Name: TABLE menu_permissions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.menu_permissions IS '菜单与权限点的关联,用户拥有任一权限即可见菜单';


--
-- Name: COLUMN menu_permissions.menu_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menu_permissions.menu_id IS '菜单 ID';


--
-- Name: COLUMN menu_permissions.permission_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menu_permissions.permission_id IS '权限点 ID';


--
-- Name: menus; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.menus (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    parent_id bigint,
    path character varying(512) NOT NULL,
    depth smallint DEFAULT 0 NOT NULL,
    name character varying(128) NOT NULL,
    icon character varying(64),
    route character varying(256),
    sort_order integer DEFAULT 0 NOT NULL,
    scope_kind character varying(32) NOT NULL,
    is_visible boolean DEFAULT true NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT menus_scope_kind_check CHECK (((scope_kind)::text = ANY (ARRAY[('platform'::character varying)::text, ('tenant'::character varying)::text, ('workspace'::character varying)::text, ('self'::character varying)::text, ('any'::character varying)::text])))
);


--
-- Name: TABLE menus; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.menus IS '前端菜单树(数据驱动)';


--
-- Name: COLUMN menus.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.id IS '主键 ID';


--
-- Name: COLUMN menus.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN menus.parent_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.parent_id IS '父菜单 ID';


--
-- Name: COLUMN menus.path; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.path IS '物化路径';


--
-- Name: COLUMN menus.depth; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.depth IS '层级深度';


--
-- Name: COLUMN menus.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.name IS '菜单名';


--
-- Name: COLUMN menus.icon; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.icon IS 'lucide 图标名';


--
-- Name: COLUMN menus.route; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.route IS '前端路由';


--
-- Name: COLUMN menus.sort_order; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.sort_order IS '排序';


--
-- Name: COLUMN menus.scope_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.scope_kind IS '菜单作用域: platform/tenant/workspace/self/any (M1 §3.3.4 统一菜单树)';


--
-- Name: COLUMN menus.is_visible; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.is_visible IS '是否可见';


--
-- Name: COLUMN menus.is_system; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.is_system IS '平台预置不可删';


--
-- Name: COLUMN menus.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.metadata IS '元数据 JSON(badge,beta)';


--
-- Name: COLUMN menus.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.created_at IS '创建时间';


--
-- Name: COLUMN menus.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.updated_at IS '更新时间';


--
-- Name: COLUMN menus.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.menus.deleted_at IS '软删除时间';


--
-- Name: menus_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.menus ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.menus_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: message_streams; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.message_streams (
    id bigint NOT NULL,
    stream_id character varying(64) NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    message_uuid uuid NOT NULL,
    runtime_session character varying(256),
    cancel_token character varying(64) NOT NULL,
    bus_node_id character varying(128) NOT NULL,
    state character varying(16) DEFAULT 'active'::character varying NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    last_event_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    CONSTRAINT message_streams_state_check CHECK (((state)::text = ANY (ARRAY[('active'::character varying)::text, ('done'::character varying)::text, ('cancelled'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: TABLE message_streams; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.message_streams IS 'module: m4 / batch-3b T3.5; active SSE streams routing & cancel control (see docs/modules/m4 §3.2). Row inserted before agent streaming message Append (Batch 3A fail-closed order: fanout.Register -> message_streams INSERT -> messages.Append).';


--
-- Name: COLUMN message_streams.cancel_token; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.message_streams.cancel_token IS 'opaque token included in cross-node cancel payload; future per-stream auth or idempotency uses (3B 不消费, owner 节点直接按 streamID local cancel; 字段保留以兼容 M4 §3.2 schema 和未来鉴权扩展)';


--
-- Name: COLUMN message_streams.bus_node_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.message_streams.bus_node_id IS 'matches bus_nodes.node_id and Redis Fanout meta HASH; stop path uses it to route cross-node cancel via bus:cmd:cancel:<node_id> channel';


--
-- Name: message_streams_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.message_streams ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.message_streams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: messages; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.messages (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    room_id bigint,
    role character varying(16) NOT NULL,
    sender_account_id bigint,
    sender_agent_id bigint,
    blocks jsonb DEFAULT '[]'::jsonb NOT NULL,
    status character varying(16) DEFAULT 'final'::character varying NOT NULL,
    stream_id character varying(64),
    final boolean DEFAULT false NOT NULL,
    error_code character varying(64),
    error_message text,
    parent_message_id bigint,
    trace_id character varying(64),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    event_logs jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    openim_message_ref jsonb,
    CONSTRAINT messages_role_check CHECK (((role)::text = ANY (ARRAY[('user'::character varying)::text, ('agent'::character varying)::text, ('system'::character varying)::text, ('tool'::character varying)::text]))),
    CONSTRAINT messages_status_check CHECK (((status)::text = ANY (ARRAY[('streaming'::character varying)::text, ('final'::character varying)::text, ('cancelled'::character varying)::text, ('failed'::character varying)::text, ('awaiting_user'::character varying)::text])))
)
PARTITION BY RANGE (created_at);


--
-- Name: TABLE messages; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.messages IS '消息(EMP Block 数组,按月分区)';


--
-- Name: COLUMN messages.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.id IS '主键 ID';


--
-- Name: COLUMN messages.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN messages.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.tenant_id IS '租户 ID';


--
-- Name: COLUMN messages.conversation_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.conversation_id IS '会话 ID';


--
-- Name: COLUMN messages.room_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.room_id IS '群 ID(冗余,加速群消息查询)';


--
-- Name: COLUMN messages.role; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.role IS '角色 user/agent/system/tool';


--
-- Name: COLUMN messages.sender_account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.sender_account_id IS '发送账号 ID(role=user)';


--
-- Name: COLUMN messages.sender_agent_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.sender_agent_id IS '发送 Agent ID(role=agent)';


--
-- Name: COLUMN messages.blocks; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.blocks IS 'EMP Block 数组 JSON';


--
-- Name: COLUMN messages.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.status IS '状态 streaming/final/cancelled/failed';


--
-- Name: COLUMN messages.stream_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.stream_id IS '流 ID,便于 SSE 续传';


--
-- Name: COLUMN messages.final; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.final IS '是否最终状态';


--
-- Name: COLUMN messages.error_code; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.error_code IS '错误码';


--
-- Name: COLUMN messages.error_message; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.error_message IS '错误信息';


--
-- Name: COLUMN messages.parent_message_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.parent_message_id IS '父消息 ID(A2A/handoff)';


--
-- Name: COLUMN messages.trace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.trace_id IS 'OTel trace_id';


--
-- Name: COLUMN messages.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.metadata IS '元数据 JSON';


--
-- Name: COLUMN messages.event_logs; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.event_logs IS '关键事件日志 JSON';


--
-- Name: COLUMN messages.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.created_at IS '创建时间(分区键)';


--
-- Name: COLUMN messages.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.updated_at IS '更新时间';


--
-- Name: COLUMN messages.openim_message_ref; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.messages.openim_message_ref IS 'module: m5-openim; OpenIM 投递引用 {clientMsgID, serverMsgID, im_substrate}; 仅 im_substrate=openim 时填.';


--
-- Name: messages_default; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.messages_default (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    room_id bigint,
    role character varying(16) NOT NULL,
    sender_account_id bigint,
    sender_agent_id bigint,
    blocks jsonb DEFAULT '[]'::jsonb NOT NULL,
    status character varying(16) DEFAULT 'final'::character varying NOT NULL,
    stream_id character varying(64),
    final boolean DEFAULT false NOT NULL,
    error_code character varying(64),
    error_message text,
    parent_message_id bigint,
    trace_id character varying(64),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    event_logs jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    openim_message_ref jsonb,
    CONSTRAINT messages_role_check CHECK (((role)::text = ANY (ARRAY[('user'::character varying)::text, ('agent'::character varying)::text, ('system'::character varying)::text, ('tool'::character varying)::text]))),
    CONSTRAINT messages_status_check CHECK (((status)::text = ANY (ARRAY[('streaming'::character varying)::text, ('final'::character varying)::text, ('cancelled'::character varying)::text, ('failed'::character varying)::text, ('awaiting_user'::character varying)::text])))
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.messages ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: permissions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.permissions (
    id bigint NOT NULL,
    code character varying(128) NOT NULL,
    name character varying(128) NOT NULL,
    description text,
    kind character varying(32) NOT NULL,
    scope_kind character varying(32) NOT NULL,
    resource character varying(64),
    action character varying(64),
    category character varying(64),
    is_system boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT permissions_kind_check CHECK (((kind)::text = ANY (ARRAY[('menu'::character varying)::text, ('api'::character varying)::text, ('data'::character varying)::text]))),
    CONSTRAINT permissions_scope_kind_check CHECK (((scope_kind)::text = ANY (ARRAY[('platform'::character varying)::text, ('tenant'::character varying)::text, ('workspace'::character varying)::text, ('self'::character varying)::text])))
);


--
-- Name: TABLE permissions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.permissions IS '权限点(菜单/API/数据三合一)';


--
-- Name: COLUMN permissions.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.id IS '主键 ID';


--
-- Name: COLUMN permissions.code; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.code IS '权限编码 <scope>.<resource>.<action>';


--
-- Name: COLUMN permissions.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.name IS '显示名';


--
-- Name: COLUMN permissions.description; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.description IS '描述';


--
-- Name: COLUMN permissions.kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.kind IS '种类 menu=菜单 api=接口 data=数据范围';


--
-- Name: COLUMN permissions.scope_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.scope_kind IS '作用域 platform/tenant/workspace/self';


--
-- Name: COLUMN permissions.resource; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.resource IS '资源 tenant/agent/kb';


--
-- Name: COLUMN permissions.action; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.action IS '动作 create/read/update/delete/publish';


--
-- Name: COLUMN permissions.category; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.category IS '分组,用于 UI 归类';


--
-- Name: COLUMN permissions.is_system; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.is_system IS '是否平台预置,true=不可删';


--
-- Name: COLUMN permissions.sort_order; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.sort_order IS '排序';


--
-- Name: COLUMN permissions.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.created_at IS '创建时间';


--
-- Name: COLUMN permissions.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.permissions.updated_at IS '更新时间';


--
-- Name: permissions_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.permissions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: role_assignments; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.role_assignments (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    role_id bigint NOT NULL,
    scope_kind character varying(32) NOT NULL,
    tenant_id bigint,
    workspace_id bigint,
    expires_at timestamp with time zone,
    granted_by bigint,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    granted_reason character varying(64),
    CONSTRAINT role_assignments_check CHECK (((((scope_kind)::text = 'platform'::text) AND (tenant_id IS NULL) AND (workspace_id IS NULL)) OR (((scope_kind)::text = 'tenant'::text) AND (tenant_id IS NOT NULL) AND (workspace_id IS NULL)) OR (((scope_kind)::text = 'workspace'::text) AND (tenant_id IS NOT NULL) AND (workspace_id IS NOT NULL)))),
    CONSTRAINT role_assignments_scope_kind_check CHECK (((scope_kind)::text = ANY (ARRAY[('platform'::character varying)::text, ('tenant'::character varying)::text, ('workspace'::character varying)::text])))
);


--
-- Name: TABLE role_assignments; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.role_assignments IS '账号 x scope x 角色';


--
-- Name: COLUMN role_assignments.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.id IS '主键 ID';


--
-- Name: COLUMN role_assignments.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.account_id IS '账号 ID';


--
-- Name: COLUMN role_assignments.role_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.role_id IS '角色 ID';


--
-- Name: COLUMN role_assignments.scope_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.scope_kind IS '作用域 platform/tenant/workspace';


--
-- Name: COLUMN role_assignments.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.tenant_id IS '租户 ID';


--
-- Name: COLUMN role_assignments.workspace_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.workspace_id IS '工作区(部门) ID';


--
-- Name: COLUMN role_assignments.expires_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.expires_at IS '过期时间,NULL=永久';


--
-- Name: COLUMN role_assignments.granted_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.granted_by IS '授予人账号 ID';


--
-- Name: COLUMN role_assignments.note; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.note IS '备注';


--
-- Name: COLUMN role_assignments.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.created_at IS '创建时间';


--
-- Name: COLUMN role_assignments.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.deleted_at IS '软删除时间';


--
-- Name: COLUMN role_assignments.granted_reason; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_assignments.granted_reason IS 'normal|impersonate|...; 用于区分系统临时授权 (impersonate) 和真实角色授权';


--
-- Name: role_assignments_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.role_assignments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.role_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: role_permissions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.role_permissions (
    role_id bigint NOT NULL,
    permission_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE role_permissions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.role_permissions IS '角色与权限点的关联';


--
-- Name: COLUMN role_permissions.role_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_permissions.role_id IS '角色 ID';


--
-- Name: COLUMN role_permissions.permission_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_permissions.permission_id IS '权限点 ID';


--
-- Name: COLUMN role_permissions.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.role_permissions.created_at IS '创建时间';


--
-- Name: roles; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.roles (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    scope_kind character varying(32) NOT NULL,
    tenant_id bigint,
    code character varying(64) NOT NULL,
    name character varying(128) NOT NULL,
    description text,
    is_system boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT roles_scope_kind_check CHECK (((scope_kind)::text = ANY (ARRAY[('platform'::character varying)::text, ('tenant'::character varying)::text])))
);


--
-- Name: TABLE roles; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.roles IS '角色定义,分平台域和租户域';


--
-- Name: COLUMN roles.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.id IS '主键 ID';


--
-- Name: COLUMN roles.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN roles.scope_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.scope_kind IS '作用域 platform=平台 tenant=租户';


--
-- Name: COLUMN roles.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.tenant_id IS '租户 ID, scope_kind=tenant 时必填';


--
-- Name: COLUMN roles.code; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.code IS '角色编码';


--
-- Name: COLUMN roles.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.name IS '角色名';


--
-- Name: COLUMN roles.description; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.description IS '描述';


--
-- Name: COLUMN roles.is_system; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.is_system IS '平台预置不可删';


--
-- Name: COLUMN roles.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.created_at IS '创建时间';


--
-- Name: COLUMN roles.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.updated_at IS '更新时间';


--
-- Name: COLUMN roles.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.roles.deleted_at IS '软删除时间';


--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.roles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: room_direct_pairs; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.room_direct_pairs (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    room_id bigint NOT NULL,
    account_a_id bigint NOT NULL,
    account_b_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT room_direct_pairs_check CHECK ((account_a_id < account_b_id))
);


--
-- Name: TABLE room_direct_pairs; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.room_direct_pairs IS 'module: m5-openim; direct 1v1 房间幂等键 + 业务 metadata; IM 时间线走 OpenIM C2C, 不进 openim_group_links.';


--
-- Name: room_direct_pairs_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.room_direct_pairs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.room_direct_pairs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: room_direct_pairs_with_agent; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.room_direct_pairs_with_agent (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    tenant_id bigint NOT NULL,
    room_id bigint NOT NULL,
    account_id bigint NOT NULL,
    agent_id bigint NOT NULL,
    CONSTRAINT chk_rdpwa_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: TABLE room_direct_pairs_with_agent; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.room_direct_pairs_with_agent IS 'F09 Phase C: 人聊 Agent 1v1 direct room 元数据 (与 room_direct_pairs 分离; rooms.metadata.direct_room_kind=''human-agent'' 区分).';


--
-- Name: COLUMN room_direct_pairs_with_agent.room_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_direct_pairs_with_agent.room_id IS '1:1 → rooms.id; room.room_kind=''direct'' + metadata.direct_room_kind=''human-agent''.';


--
-- Name: COLUMN room_direct_pairs_with_agent.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_direct_pairs_with_agent.account_id IS 'human 侧 account (创建对话的用户).';


--
-- Name: COLUMN room_direct_pairs_with_agent.agent_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_direct_pairs_with_agent.agent_id IS '数字员工 (digital_employees.id); 同租户; agent 必须 visible + status=published (service 层校验).';


--
-- Name: room_direct_pairs_with_agent_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.room_direct_pairs_with_agent ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.room_direct_pairs_with_agent_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: room_participants; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.room_participants (
    id bigint NOT NULL,
    room_id bigint NOT NULL,
    kind character varying(16) NOT NULL,
    account_id bigint,
    agent_id bigint,
    role_in_room character varying(32) DEFAULT 'member'::character varying NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL,
    left_at timestamp with time zone,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT room_participants_check CHECK (((((kind)::text = 'human'::text) AND (account_id IS NOT NULL) AND (agent_id IS NULL)) OR (((kind)::text = 'agent'::text) AND (agent_id IS NOT NULL) AND (account_id IS NULL)))),
    CONSTRAINT room_participants_kind_check CHECK (((kind)::text = ANY (ARRAY[('human'::character varying)::text, ('agent'::character varying)::text]))),
    CONSTRAINT room_participants_role_in_room_check CHECK (((role_in_room)::text = ANY (ARRAY[('member'::character varying)::text, ('manager'::character varying)::text, ('observer'::character varying)::text])))
);


--
-- Name: TABLE room_participants; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.room_participants IS '群成员(人 + Agent)';


--
-- Name: COLUMN room_participants.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.id IS '主键 ID';


--
-- Name: COLUMN room_participants.room_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.room_id IS '群 ID';


--
-- Name: COLUMN room_participants.kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.kind IS '类型 human/agent';


--
-- Name: COLUMN room_participants.account_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.account_id IS '账号 ID (kind=human)';


--
-- Name: COLUMN room_participants.agent_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.agent_id IS '数字员工 ID (kind=agent)';


--
-- Name: COLUMN room_participants.role_in_room; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.role_in_room IS '群内角色 member/manager/observer';


--
-- Name: COLUMN room_participants.joined_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.joined_at IS '加入时间';


--
-- Name: COLUMN room_participants.left_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.left_at IS '离开时间';


--
-- Name: COLUMN room_participants.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.room_participants.uuid IS 'module: m5 / batch-2e T2E.9; 对外 API 用此 uuid 路由, 禁止暴露 BIGINT id';


--
-- Name: room_participants_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.room_participants ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.room_participants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: rooms; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.rooms (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    creator_id bigint NOT NULL,
    title character varying(256) NOT NULL,
    goal text,
    termination jsonb DEFAULT '{}'::jsonb NOT NULL,
    speaker_policy character varying(32) DEFAULT 'manual'::character varying NOT NULL,
    speaker_policy_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    manager_agent_id bigint,
    max_round_count integer DEFAULT 100 NOT NULL,
    max_a2a_depth smallint DEFAULT 8 NOT NULL,
    room_timeout_seconds integer,
    status character varying(32) DEFAULT 'active'::character varying NOT NULL,
    completed_at timestamp with time zone,
    summary jsonb,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    room_kind character varying(16) DEFAULT 'group'::character varying NOT NULL,
    round_count integer DEFAULT 0 NOT NULL,
    wukong_channel_id character varying(128),
    wukong_channel_type smallint,
    CONSTRAINT rooms_room_kind_check CHECK (((room_kind)::text = ANY (ARRAY[('direct'::character varying)::text, ('group'::character varying)::text]))),
    CONSTRAINT rooms_speaker_policy_check CHECK (((speaker_policy)::text = ANY (ARRAY[('manual'::character varying)::text, ('round_robin'::character varying)::text, ('auto_llm'::character varying)::text, ('manager'::character varying)::text, ('parallel'::character varying)::text, ('handoff'::character varying)::text]))),
    CONSTRAINT rooms_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('paused'::character varying)::text, ('completed'::character varying)::text, ('archived'::character varying)::text])))
);


--
-- Name: TABLE rooms; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.rooms IS '群聊房间';


--
-- Name: COLUMN rooms.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.id IS '主键 ID';


--
-- Name: COLUMN rooms.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN rooms.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.tenant_id IS '租户 ID';


--
-- Name: COLUMN rooms.creator_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.creator_id IS '创建人';


--
-- Name: COLUMN rooms.title; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.title IS '群标题';


--
-- Name: COLUMN rooms.goal; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.goal IS '群目标声明';


--
-- Name: COLUMN rooms.termination; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.termination IS '终止条件 JSON(timeout/consensus/manual)';


--
-- Name: COLUMN rooms.speaker_policy; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.speaker_policy IS '调度策略 manual/round_robin/auto_llm/manager/parallel/handoff';


--
-- Name: COLUMN rooms.speaker_policy_config; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.speaker_policy_config IS '策略配置 JSON';


--
-- Name: COLUMN rooms.manager_agent_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.manager_agent_id IS 'manager 策略下的主导 Agent ID';


--
-- Name: COLUMN rooms.max_round_count; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.max_round_count IS '最大轮次';


--
-- Name: COLUMN rooms.max_a2a_depth; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.max_a2a_depth IS 'A2A 最大深度';


--
-- Name: COLUMN rooms.room_timeout_seconds; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.room_timeout_seconds IS '群超时(秒)';


--
-- Name: COLUMN rooms.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.status IS '状态 active/paused/completed/archived';


--
-- Name: COLUMN rooms.completed_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.completed_at IS '完成时间';


--
-- Name: COLUMN rooms.summary; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.summary IS '完成纪要 JSON';


--
-- Name: COLUMN rooms.metadata; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.metadata IS '元数据 JSON';


--
-- Name: COLUMN rooms.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.created_at IS '创建时间';


--
-- Name: COLUMN rooms.updated_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.updated_at IS '更新时间';


--
-- Name: COLUMN rooms.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.deleted_at IS '软删除时间';


--
-- Name: COLUMN rooms.room_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.room_kind IS 'module: m5 / batch-2e T2E.9; direct=human×human 1v1 (M5 完整版接管), group=多人/多 Agent 群 (2E 唯一允许值)';


--
-- Name: COLUMN rooms.round_count; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.round_count IS 'module: m5 / batch-2e T2E.9; user-agent 轮次累加 (仅记录, max_round_count 强制留 m5 完整版)';


--
-- Name: COLUMN rooms.wukong_channel_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.wukong_channel_id IS 'WuKongIM 频道 id(ADR-0026);direct/group 均 1:1 绑定;webhook 反查 channel→room 用';


--
-- Name: COLUMN rooms.wukong_channel_type; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.rooms.wukong_channel_type IS 'WuKongIM 频道类型;恒 2(group;direct 也用 group 建模,见 ADR-0026)';


--
-- Name: rooms_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.rooms ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.rooms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: runtime_environments; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.runtime_environments (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    scope character varying(16) NOT NULL,
    tenant_id bigint,
    name character varying(128) NOT NULL,
    description text,
    framework character varying(32) NOT NULL,
    hosting_kind character varying(32) NOT NULL,
    status character varying(32) DEFAULT 'active'::character varying NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    open_to_tenants boolean DEFAULT false NOT NULL,
    primary_endpoint character varying(512),
    api_key_secret_ref text,
    workload_api_base_url character varying(256),
    workload_api_token_secret_ref text,
    k8s_api_server_url character varying(256),
    k8s_token_secret_ref text,
    k8s_namespace character varying(64) DEFAULT 'aigc'::character varying,
    k8s_insecure_skip_verify boolean DEFAULT false NOT NULL,
    image_repository character varying(256),
    image_tag character varying(64),
    gateway_port integer DEFAULT 18789,
    mount_path character varying(128) DEFAULT '/workspace'::character varying,
    storage_class character varying(64),
    default_cpu_cores integer DEFAULT 2,
    default_memory_gb integer DEFAULT 4,
    default_disk_gb integer DEFAULT 10,
    workload_env jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_probed_at timestamp with time zone,
    last_probe_status character varying(32),
    last_probe_message text,
    last_probe_latency_ms integer,
    data_egress character varying(32) DEFAULT 'platform-only'::character varying NOT NULL,
    egress_audit_status character varying(32) DEFAULT 'approved'::character varying NOT NULL,
    egress_audit_reason text,
    egress_auditor_id bigint,
    egress_reviewed_at timestamp with time zone,
    egress_compliance_docs jsonb DEFAULT '{}'::jsonb NOT NULL,
    rate_limit jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    framework_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    llm_default_model character varying(64),
    http_proxy character varying(256),
    https_proxy character varying(256),
    no_proxy text,
    k8s_ops_kubeconfig_secret_ref text,
    external_environment_id character varying(256),
    CONSTRAINT chk_renv_hosting_kind_required_fields CHECK (((((hosting_kind)::text = 'clawmanager'::text) AND (workload_api_base_url IS NOT NULL) AND (workload_api_token_secret_ref IS NOT NULL)) OR (((hosting_kind)::text = 'k8s_native'::text) AND (k8s_api_server_url IS NOT NULL) AND (k8s_token_secret_ref IS NOT NULL)) OR (((hosting_kind)::text = 'external_endpoint'::text) AND (primary_endpoint IS NOT NULL) AND (api_key_secret_ref IS NOT NULL)) OR (((hosting_kind)::text = 'embedded'::text) AND ((framework)::text = 'generic'::text) AND (primary_endpoint IS NULL) AND (api_key_secret_ref IS NULL)))),
    CONSTRAINT chk_renv_open_only_platform CHECK (((open_to_tenants = false) OR ((scope)::text = 'platform'::text))),
    CONSTRAINT chk_renv_scope_tenant CHECK (((((scope)::text = 'platform'::text) AND (tenant_id IS NULL)) OR (((scope)::text = 'tenant'::text) AND (tenant_id IS NOT NULL)))),
    CONSTRAINT chk_renv_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL))),
    CONSTRAINT runtime_environments_egress_audit_status_check CHECK (((egress_audit_status)::text = ANY (ARRAY[('pending'::character varying)::text, ('approved'::character varying)::text, ('rejected'::character varying)::text, ('needs_revision'::character varying)::text]))),
    CONSTRAINT runtime_environments_hosting_kind_check CHECK (((hosting_kind)::text = ANY ((ARRAY['clawmanager'::character varying, 'k8s_native'::character varying, 'external_endpoint'::character varying, 'embedded'::character varying])::text[]))),
    CONSTRAINT runtime_environments_last_probe_status_check CHECK (((last_probe_status IS NULL) OR ((last_probe_status)::text = ANY (ARRAY[('ok'::character varying)::text, ('failed'::character varying)::text, ('error'::character varying)::text, ('timeout'::character varying)::text])))),
    CONSTRAINT runtime_environments_scope_check CHECK (((scope)::text = ANY (ARRAY[('platform'::character varying)::text, ('tenant'::character varying)::text]))),
    CONSTRAINT runtime_environments_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('disabled'::character varying)::text, ('archived'::character varying)::text])))
);


--
-- Name: TABLE runtime_environments; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.runtime_environments IS 'F02 v0.3: 4 层 Agent 平台模型 L2+L3 合表; scope+hosting_kind 二维区分 (platform clawmanager/k8s_native + tenant clawmanager/k8s_native + tenant external_endpoint)';


--
-- Name: COLUMN runtime_environments.scope; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.scope IS 'platform = 平台 admin 配置; tenant = 租户 admin 配置';


--
-- Name: COLUMN runtime_environments.hosting_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.hosting_kind IS 'clawmanager = 调 clawmanager 帮跑; k8s_native = 调 K8s API 直接部署; external_endpoint = 不部署只连接 (L3 租户自托管)';


--
-- Name: COLUMN runtime_environments.open_to_tenants; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.open_to_tenants IS '仅 scope=platform 有意义; true 才能被租户启用';


--
-- Name: COLUMN runtime_environments.primary_endpoint; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.primary_endpoint IS 'external_endpoint 用户填; clawmanager/k8s_native 实例 ensure 后回填';


--
-- Name: COLUMN runtime_environments.api_key_secret_ref; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.api_key_secret_ref IS 'external_endpoint or issued instance API key secret ref; env://, value:// or vault://';


--
-- Name: COLUMN runtime_environments.workload_api_token_secret_ref; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.workload_api_token_secret_ref IS 'clawmanager bearer token secret ref; may contain value:// pasted credential in admin test environments';


--
-- Name: COLUMN runtime_environments.k8s_token_secret_ref; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.k8s_token_secret_ref IS 'K8s API token secret ref; ServiceAccount JWTs can exceed 256 chars';


--
-- Name: COLUMN runtime_environments.framework_config; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.framework_config IS 'Per-framework adapter config (schema_version + framework-specific settings). Secrets must use secret_ref, never plaintext.';


--
-- Name: COLUMN runtime_environments.llm_default_model; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.llm_default_model IS 'ADR-0021: 覆盖 bus.yaml.aigc.default_model 的默认模型；留空 = 用全局默认';


--
-- Name: COLUMN runtime_environments.http_proxy; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.http_proxy IS 'ADR-0021: pod 出站 HTTP 代理 (注入 http_proxy / HTTP_PROXY)';


--
-- Name: COLUMN runtime_environments.https_proxy; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.https_proxy IS 'ADR-0021: pod 出站 HTTPS 代理 (注入 https_proxy / HTTPS_PROXY)';


--
-- Name: COLUMN runtime_environments.no_proxy; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.no_proxy IS 'ADR-0021: 跳过代理的域名/网段，逗号或换行分隔 (注入 no_proxy / NO_PROXY)';


--
-- Name: COLUMN runtime_environments.k8s_ops_kubeconfig_secret_ref; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.k8s_ops_kubeconfig_secret_ref IS 'Admin runtime monitor Kubernetes kubeconfig secret ref; only used for k8s_native restart/delete operations, not ClawManager lifecycle, workload creation, or runtime file sync';


--
-- Name: COLUMN runtime_environments.external_environment_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.runtime_environments.external_environment_id IS 'Optional operator-defined external reference for ZAP runtimes; forwarded in /instances and /sessions metadata only, never used for authorization or internal identity.';


--
-- Name: CONSTRAINT chk_renv_hosting_kind_required_fields ON runtime_environments; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON CONSTRAINT chk_renv_hosting_kind_required_fields ON agent_bus.runtime_environments IS 'Remote hosts require credentials; embedded generic adapters must not carry remote endpoint credentials (ADR-0057).';


--
-- Name: runtime_environments_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.runtime_environments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.runtime_environments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: skill_categories; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.skill_categories (
    id bigint NOT NULL,
    code character varying(64) NOT NULL,
    name character varying(128) NOT NULL,
    category_kind character varying(16) NOT NULL,
    description text,
    sort_order integer DEFAULT 0 NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by bigint,
    CONSTRAINT skill_categories_category_kind_check CHECK (((category_kind)::text = ANY (ARRAY[('foundation'::character varying)::text, ('scenario'::character varying)::text]))),
    CONSTRAINT skill_categories_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('archived'::character varying)::text])))
);


--
-- Name: TABLE skill_categories; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.skill_categories IS 'module: f03; F03 v0.9.1 技能一级分类；category_kind=foundation 基座 / scenario 场景';


--
-- Name: COLUMN skill_categories.is_deleted; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skill_categories.is_deleted IS 'module: f03; 软删除标记。删除与 status 启停分离，删除行默认不出现在 admin 字典列表。';


--
-- Name: skill_categories_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.skill_categories ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.skill_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: skill_versions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.skill_versions (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    skill_id bigint NOT NULL,
    version character varying(32) NOT NULL,
    status character varying(16) DEFAULT 'draft'::character varying NOT NULL,
    changelog text,
    package_url character varying(512),
    package_size_bytes bigint,
    package_sha256 character varying(64),
    input_chips_schema_snapshot jsonb,
    agent_compat_snapshot jsonb,
    grayscale_pct smallint DEFAULT 100 NOT NULL,
    grayscale_strategy character varying(32) DEFAULT 'tenant_hash'::character varying NOT NULL,
    grayscale_allowlist bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    published_at timestamp with time zone,
    published_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT skill_versions_grayscale_pct_check CHECK (((grayscale_pct >= 0) AND (grayscale_pct <= 100))),
    CONSTRAINT skill_versions_grayscale_strategy_check CHECK (((grayscale_strategy)::text = ANY (ARRAY[('tenant_hash'::character varying)::text, ('agent_hash'::character varying)::text, ('user_hash'::character varying)::text, ('tenant_allowlist'::character varying)::text]))),
    CONSTRAINT skill_versions_package_size_limit CHECK (((package_size_bytes IS NULL) OR (package_size_bytes <= 52428800))),
    CONSTRAINT skill_versions_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('published'::character varying)::text, ('archived'::character varying)::text])))
);


--
-- Name: TABLE skill_versions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.skill_versions IS 'module: f03; F03 v0.9.1 技能版本表（替代 M6 composer_skill_versions）';


--
-- Name: COLUMN skill_versions.package_url; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skill_versions.package_url IS 'module: f03; kind=agent 技能 SKILL.md 包 zip 的对象存储 URL；kind=builtin 必为 NULL（应用层强校）';


--
-- Name: COLUMN skill_versions.input_chips_schema_snapshot; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skill_versions.input_chips_schema_snapshot IS 'module: f03; publish 时刻的 input_chips_schema 快照，防止主表后续修改污染历史';


--
-- Name: COLUMN skill_versions.grayscale_pct; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skill_versions.grayscale_pct IS 'module: f03; 灰度百分比 0-100（100=全量）；strategy=tenant_hash 时按 tenant_id 哈希落桶';


--
-- Name: COLUMN skill_versions.grayscale_strategy; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skill_versions.grayscale_strategy IS 'module: f03; 灰度策略 tenant_hash/agent_hash/user_hash/tenant_allowlist';


--
-- Name: COLUMN skill_versions.grayscale_allowlist; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skill_versions.grayscale_allowlist IS 'module: f03; grayscale_strategy=tenant_allowlist 时生效，命中即视为灰度通过';


--
-- Name: skill_versions_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.skill_versions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.skill_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: skills; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.skills (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    code character varying(64) NOT NULL,
    name character varying(128) NOT NULL,
    description text,
    icon_url character varying(512),
    placeholder character varying(256),
    submit_label character varying(64),
    kind character varying(16) DEFAULT 'agent'::character varying NOT NULL,
    builtin_key character varying(64),
    execution_mode character varying(32) DEFAULT 'synchronous_inline'::character varying NOT NULL,
    scope_kind character varying(16) DEFAULT 'platform'::character varying NOT NULL,
    tenant_id bigint,
    source character varying(32) DEFAULT 'internal'::character varying NOT NULL,
    visibility character varying(32) DEFAULT 'platform'::character varying NOT NULL,
    category_id bigint,
    input_chips_schema jsonb DEFAULT '[]'::jsonb NOT NULL,
    hosting_modes text[] DEFAULT ARRAY['platform_managed'::text, 'hybrid'::text] NOT NULL,
    agent_compat jsonb DEFAULT '{}'::jsonb NOT NULL,
    default_attached boolean DEFAULT false NOT NULL,
    default_pinned boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    latest_version_id bigint,
    status character varying(16) DEFAULT 'draft'::character varying NOT NULL,
    install_count bigint DEFAULT 0 NOT NULL,
    created_by bigint,
    updated_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    usage_example text,
    usage_example_images jsonb DEFAULT '[]'::jsonb NOT NULL,
    billing_type character varying(8) DEFAULT 'free'::character varying NOT NULL,
    pricing_mode character varying(16) DEFAULT 'per_skill'::character varying NOT NULL,
    marketing_visible boolean DEFAULT true NOT NULL,
    CONSTRAINT skills_billing_type_check CHECK (((billing_type)::text = ANY ((ARRAY['free'::character varying, 'paid'::character varying])::text[]))),
    CONSTRAINT skills_chips_source_of_truth CHECK ((((kind)::text = 'builtin'::text) OR (input_chips_schema = '[]'::jsonb))),
    CONSTRAINT skills_execution_mode_check CHECK (((execution_mode)::text = ANY (ARRAY[('synchronous_inline'::character varying)::text, ('asynchronous_floating'::character varying)::text]))),
    CONSTRAINT skills_hosting_modes_valid CHECK ((hosting_modes <@ ARRAY['platform_managed'::text, 'hybrid'::text])),
    CONSTRAINT skills_kind_check CHECK (((kind)::text = ANY (ARRAY[('agent'::character varying)::text, ('builtin'::character varying)::text]))),
    CONSTRAINT skills_kind_consistency CHECK (((((kind)::text = 'builtin'::text) AND (builtin_key IS NOT NULL)) OR (((kind)::text = 'agent'::text) AND (builtin_key IS NULL)))),
    CONSTRAINT skills_pricing_mode_check CHECK (((pricing_mode)::text = ANY ((ARRAY['per_skill'::character varying, 'per_operation'::character varying])::text[]))),
    CONSTRAINT skills_scope_consistency CHECK (((((scope_kind)::text = 'tenant'::text) AND (tenant_id IS NOT NULL)) OR (((scope_kind)::text = 'platform'::text) AND (tenant_id IS NULL)))),
    CONSTRAINT skills_scope_kind_check CHECK (((scope_kind)::text = ANY (ARRAY[('platform'::character varying)::text, ('tenant'::character varying)::text]))),
    CONSTRAINT skills_source_check CHECK (((source)::text = ANY (ARRAY[('internal'::character varying)::text, ('open_source'::character varying)::text, ('third_party'::character varying)::text]))),
    CONSTRAINT skills_status_check CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('active'::character varying)::text, ('archived'::character varying)::text]))),
    CONSTRAINT skills_usage_example_images_array CHECK ((jsonb_typeof(usage_example_images) = 'array'::text)),
    CONSTRAINT skills_visibility_check CHECK (((visibility)::text = ANY (ARRAY[('private'::character varying)::text, ('workspace'::character varying)::text, ('tenant'::character varying)::text, ('platform'::character varying)::text])))
);


--
-- Name: TABLE skills; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.skills IS 'module: f03; F03 v0.9.1 技能主表（替代 M6 composer_skills）';


--
-- Name: COLUMN skills.kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.kind IS 'module: f03; agent=SKILL.md 包，Agent runtime 自跑；builtin=client native runner';


--
-- Name: COLUMN skills.scope_kind; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.scope_kind IS 'module: f03; platform=跨租户可见的平台技能；tenant=仅 tenant_id 对应租户可见';


--
-- Name: COLUMN skills.input_chips_schema; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.input_chips_schema IS 'module: f03; kind=builtin 在主表编辑；kind=agent 强制为 []，真值在 skill_versions.input_chips_schema_snapshot';


--
-- Name: COLUMN skills.hosting_modes; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.hosting_modes IS 'module: f03; 允许借用此技能的 Agent hosting 模式子集；self_hosted 永不在内（boundaries §2.3）';


--
-- Name: COLUMN skills.agent_compat; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.agent_compat IS 'module: f03; Agent 实现兼容矩阵 {required_models[],required_runtimes[],blocked_agent_tags[]}';


--
-- Name: COLUMN skills.latest_version_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.latest_version_id IS 'module: f03; 当前 latest published 版本 ID；按 published_at 单调比较，rollback 可指向非最大';


--
-- Name: COLUMN skills.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.status IS 'module: f03; draft=未发版；active=至少有一个 published baseline；archived=软停用，运行时不可见';


--
-- Name: COLUMN skills.usage_example; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.usage_example IS 'Markdown usage example shown in client skill detail.';


--
-- Name: COLUMN skills.usage_example_images; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.usage_example_images IS 'Array of example image refs, usually [{"storage_uri":"oss://skill-example-images/<sha>.<ext>","file_name":"..."}].';


--
-- Name: COLUMN skills.billing_type; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.billing_type IS 'free=不扣技能调用费; paid=扣积分';


--
-- Name: COLUMN skills.pricing_mode; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.pricing_mode IS 'per_skill=整技能一个价; per_operation=按 API/operation 分别定价（仅 paid 时生效）';


--
-- Name: COLUMN skills.marketing_visible; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.skills.marketing_visible IS 'module: f03; true=在对外营销官网技能商店展示（仅 scope_kind=platform 且 status=active 生效）；默认 true，由平台运营在技能管理取消勾选后隐藏';


--
-- Name: skills_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.skills ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.skills_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenant_agent_positions; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.tenant_agent_positions (
    id bigint NOT NULL,
    agent_id bigint NOT NULL,
    position_id bigint NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE tenant_agent_positions; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.tenant_agent_positions IS 'F01 §1: 数字员工 ↔ 职位 N:N. 跟人类员工同一份 tenant_positions 词典.';


--
-- Name: tenant_agent_positions_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.tenant_agent_positions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenant_agent_positions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenant_member_positions_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.tenant_member_positions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenant_member_positions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenant_memberships_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.tenant_memberships ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenant_memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenant_positions_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.tenant_positions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenant_positions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenant_runtime_enablements; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.tenant_runtime_enablements (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    runtime_environment_id bigint NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    created_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by bigint,
    is_deleted boolean DEFAULT false NOT NULL,
    CONSTRAINT chk_tre_soft_delete CHECK (((is_deleted = false) OR (deleted_at IS NOT NULL)))
);


--
-- Name: TABLE tenant_runtime_enablements; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.tenant_runtime_enablements IS 'module: m3-tenant-runtime-environments; 租户启用的 Agent 平台环境多对多 + 默认标记';


--
-- Name: COLUMN tenant_runtime_enablements.id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_runtime_enablements.id IS '主键 ID';


--
-- Name: COLUMN tenant_runtime_enablements.uuid; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_runtime_enablements.uuid IS '对外业务唯一标识';


--
-- Name: COLUMN tenant_runtime_enablements.tenant_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_runtime_enablements.tenant_id IS '租户 ID';


--
-- Name: COLUMN tenant_runtime_enablements.runtime_environment_id; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_runtime_enablements.runtime_environment_id IS 'Runtime 类型外键';


--
-- Name: COLUMN tenant_runtime_enablements.is_default; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_runtime_enablements.is_default IS '是否本租户默认环境';


--
-- Name: COLUMN tenant_runtime_enablements.created_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_runtime_enablements.created_by IS '启用操作账号 ID';


--
-- Name: COLUMN tenant_runtime_enablements.created_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_runtime_enablements.created_at IS '启用时间';


--
-- Name: COLUMN tenant_runtime_enablements.deleted_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_runtime_enablements.deleted_at IS '软删除时间';


--
-- Name: tenant_runtime_enablements_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.tenant_runtime_enablements ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenant_runtime_enablements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenant_webhook_configs; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.tenant_webhook_configs (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id bigint NOT NULL,
    callback_url character varying(2048) NOT NULL,
    signing_secret character varying(256) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    event_types character varying(64)[] DEFAULT '{}'::character varying[] NOT NULL,
    description character varying(256),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    name character varying(128) DEFAULT ''::character varying NOT NULL
);


--
-- Name: TABLE tenant_webhook_configs; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.tenant_webhook_configs IS 'F01: 租户级 webhook 推送配置。外部系统注册 callback_url 接收组织架构变更通知 (org.member.*/org.department.*/org.position.*)';


--
-- Name: COLUMN tenant_webhook_configs.signing_secret; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_webhook_configs.signing_secret IS 'HMAC-SHA256 签名密钥原文。投递时用此值计算 HMAC-SHA256(timestamp+body), 结果放 X-Zhiban-Signature header';


--
-- Name: COLUMN tenant_webhook_configs.event_types; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_webhook_configs.event_types IS '事件类型白名单; 空数组 = 接收所有 org.* 事件; 非空 = 仅接收列出的类型';


--
-- Name: COLUMN tenant_webhook_configs.name; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.tenant_webhook_configs.name IS 'F01 §3.5.1: 租户后台组织同步 webhook 展示名';


--
-- Name: tenant_webhook_configs_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.tenant_webhook_configs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenant_webhook_configs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenant_webhook_deliveries; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.tenant_webhook_deliveries (
    id bigint NOT NULL,
    outbox_id bigint NOT NULL,
    webhook_config_id bigint NOT NULL,
    callback_url character varying(2048) NOT NULL,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    attempts smallint DEFAULT 0 NOT NULL,
    next_retry_at timestamp with time zone,
    picked_at timestamp with time zone,
    last_error text,
    done_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE tenant_webhook_deliveries; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.tenant_webhook_deliveries IS 'F01: per-event per-webhook-config 独立投递状态。dispatcher 先 fan-out outbox → deliveries, 再逐行投递+重试';


--
-- Name: tenant_webhook_deliveries_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.tenant_webhook_deliveries ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenant_webhook_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tenants_id_seq; Type: SEQUENCE; Schema: agent_bus; Owner: -
--

ALTER TABLE agent_bus.tenants ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wukong_send_outbox; Type: TABLE; Schema: agent_bus; Owner: -
--

CREATE TABLE agent_bus.wukong_send_outbox (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    channel_id text NOT NULL,
    channel_type integer NOT NULL,
    from_uid text NOT NULL,
    msg_type integer NOT NULL,
    payload jsonb NOT NULL,
    dedup_key text NOT NULL,
    source text DEFAULT 'generic'::text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    max_retries integer DEFAULT 10 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    sent_at timestamp with time zone,
    last_error text,
    locked_by text,
    lock_expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT wukong_send_outbox_source_chk CHECK ((source = ANY (ARRAY['group_agent_reply'::text, 'agent_direct_user_final'::text, 'agent_direct_agent_final'::text, 'revoke_cmd'::text, 'generic'::text]))),
    CONSTRAINT wukong_send_outbox_status_chk CHECK ((status = ANY (ARRAY['pending'::text, 'sending'::text, 'sent'::text, 'failed'::text])))
);


--
-- Name: TABLE wukong_send_outbox; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON TABLE agent_bus.wukong_send_outbox IS 'module: ADR-0026 P0 前置; WuKong 外部写入可靠投递 outbox; 幂等键=(tenant_id,dedup_key); worker 异步 SendMessage + capped backoff 重试, 超 max_retries→failed 终态(不静默吞); lease(lock_expires_at) 防 sending 卡死; 投递=at-least-once; 本轮不切流量(方案 A).';


--
-- Name: COLUMN wukong_send_outbox.dedup_key; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.wukong_send_outbox.dedup_key IS '业务幂等键, 与 tenant_id 组成唯一约束; 同键重复 enqueue 不产生第二行(返回现有行). at-least-once 下下游须用它去重.';


--
-- Name: COLUMN wukong_send_outbox.source; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.wukong_send_outbox.source IS 'group_agent_reply | agent_direct_user_final | agent_direct_agent_final | revoke_cmd | generic';


--
-- Name: COLUMN wukong_send_outbox.status; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.wukong_send_outbox.status IS 'pending | sending | sent | failed; failed 且 retry_count>=max_retries = 终态(不再 claim).';


--
-- Name: COLUMN wukong_send_outbox.next_attempt_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.wukong_send_outbox.next_attempt_at IS 'worker 下次可 claim 时间; 失败后按 capped backoff(1s/5s/15s/1m/5m) 后移.';


--
-- Name: COLUMN wukong_send_outbox.locked_by; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.wukong_send_outbox.locked_by IS '持租 worker id(诊断用); reclaim 判定只看 lock_expires_at, 不依赖 locked_by 唯一.';


--
-- Name: COLUMN wukong_send_outbox.lock_expires_at; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON COLUMN agent_bus.wukong_send_outbox.lock_expires_at IS 'lease 到期时间; status=sending 且 lock_expires_at<=now → 视为 worker 崩溃, 重新 claim 重投(at-least-once). mark 时置空.';


--
-- Name: messages_default; Type: TABLE ATTACH; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.messages ATTACH PARTITION agent_bus.messages_default DEFAULT;


--
-- Name: chat_media_refs id; Type: DEFAULT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_media_refs ALTER COLUMN id SET DEFAULT nextval('agent_bus.chat_media_refs_id_seq'::regclass);


--
-- Name: account_identities account_identities_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.account_identities
    ADD CONSTRAINT account_identities_pkey PRIMARY KEY (id);


--
-- Name: account_identities account_identities_provider_provider_uid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.account_identities
    ADD CONSTRAINT account_identities_provider_provider_uid_key UNIQUE (provider, provider_uid);


--
-- Name: accounts accounts_email_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.accounts
    ADD CONSTRAINT accounts_email_key UNIQUE (email);


--
-- Name: accounts accounts_phone_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.accounts
    ADD CONSTRAINT accounts_phone_key UNIQUE (phone);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_username_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.accounts
    ADD CONSTRAINT accounts_username_key UNIQUE (username);


--
-- Name: accounts accounts_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.accounts
    ADD CONSTRAINT accounts_uuid_key UNIQUE (uuid);


--
-- Name: admin_accounts admin_accounts_account_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.admin_accounts
    ADD CONSTRAINT admin_accounts_account_id_key UNIQUE (account_id);


--
-- Name: admin_accounts admin_accounts_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.admin_accounts
    ADD CONSTRAINT admin_accounts_pkey PRIMARY KEY (id);


--
-- Name: agent_app_bindings agent_app_bindings_agent_id_app_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_app_bindings
    ADD CONSTRAINT agent_app_bindings_agent_id_app_id_key UNIQUE (agent_id, app_id);


--
-- Name: agent_app_bindings agent_app_bindings_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_app_bindings
    ADD CONSTRAINT agent_app_bindings_pkey PRIMARY KEY (id);


--
-- Name: agent_kb_bindings agent_kb_bindings_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_kb_bindings
    ADD CONSTRAINT agent_kb_bindings_pkey PRIMARY KEY (id);


--
-- Name: agent_skill_bindings agent_skill_bindings_agent_id_skill_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_skill_bindings
    ADD CONSTRAINT agent_skill_bindings_agent_id_skill_id_key UNIQUE (agent_id, skill_id);


--
-- Name: agent_skill_bindings agent_skill_bindings_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_skill_bindings
    ADD CONSTRAINT agent_skill_bindings_pkey PRIMARY KEY (id);


--
-- Name: agent_trigger_log agent_trigger_log_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_trigger_log
    ADD CONSTRAINT agent_trigger_log_pkey PRIMARY KEY (id);


--
-- Name: agent_trigger_log agent_trigger_log_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_trigger_log
    ADD CONSTRAINT agent_trigger_log_uuid_key UNIQUE (uuid);


--
-- Name: agent_versions agent_versions_digital_employee_id_version_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_versions
    ADD CONSTRAINT agent_versions_digital_employee_id_version_key UNIQUE (digital_employee_id, version);


--
-- Name: agent_versions agent_versions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_versions
    ADD CONSTRAINT agent_versions_pkey PRIMARY KEY (id);


--
-- Name: app_category app_category_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_category
    ADD CONSTRAINT app_category_pkey PRIMARY KEY (id);


--
-- Name: app_category app_category_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_category
    ADD CONSTRAINT app_category_uuid_key UNIQUE (uuid);


--
-- Name: app_oauth_clients app_oauth_clients_app_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_oauth_clients
    ADD CONSTRAINT app_oauth_clients_app_id_key UNIQUE (app_id);


--
-- Name: app_oauth_clients app_oauth_clients_client_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_oauth_clients
    ADD CONSTRAINT app_oauth_clients_client_id_key UNIQUE (client_id);


--
-- Name: app_oauth_clients app_oauth_clients_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_oauth_clients
    ADD CONSTRAINT app_oauth_clients_pkey PRIMARY KEY (id);


--
-- Name: app_oauth_clients app_oauth_clients_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_oauth_clients
    ADD CONSTRAINT app_oauth_clients_uuid_key UNIQUE (uuid);


--
-- Name: apps apps_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.apps
    ADD CONSTRAINT apps_pkey PRIMARY KEY (id);


--
-- Name: apps apps_tenant_id_code_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.apps
    ADD CONSTRAINT apps_tenant_id_code_key UNIQUE (tenant_id, code);


--
-- Name: apps apps_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.apps
    ADD CONSTRAINT apps_uuid_key UNIQUE (uuid);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: audit_summary audit_summary_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.audit_summary
    ADD CONSTRAINT audit_summary_pkey PRIMARY KEY (id);


--
-- Name: audit_summary audit_summary_tenant_id_bucket_date_event_type_actor_kind_a_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.audit_summary
    ADD CONSTRAINT audit_summary_tenant_id_bucket_date_event_type_actor_kind_a_key UNIQUE (tenant_id, bucket_date, event_type, actor_kind, actor_id);


--
-- Name: auth_audit_events auth_audit_events_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.auth_audit_events
    ADD CONSTRAINT auth_audit_events_pkey PRIMARY KEY (id);


--
-- Name: auth_audit_events auth_audit_events_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.auth_audit_events
    ADD CONSTRAINT auth_audit_events_uuid_key UNIQUE (uuid);


--
-- Name: chat_media_refs chat_media_refs_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_media_refs
    ADD CONSTRAINT chat_media_refs_pkey PRIMARY KEY (id);


--
-- Name: chat_message_tasks chat_message_tasks_agent_msg_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_message_tasks
    ADD CONSTRAINT chat_message_tasks_agent_msg_key UNIQUE (agent_message_uuid);


--
-- Name: chat_message_tasks chat_message_tasks_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_message_tasks
    ADD CONSTRAINT chat_message_tasks_pkey PRIMARY KEY (id);


--
-- Name: chat_message_tasks chat_message_tasks_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_message_tasks
    ADD CONSTRAINT chat_message_tasks_uuid_key UNIQUE (uuid);


--
-- Name: contact_policies contact_policies_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.contact_policies
    ADD CONSTRAINT contact_policies_pkey PRIMARY KEY (tenant_id);


--
-- Name: content_favorites content_favorites_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.content_favorites
    ADD CONSTRAINT content_favorites_pkey PRIMARY KEY (id);


--
-- Name: content_favorites content_favorites_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.content_favorites
    ADD CONSTRAINT content_favorites_uuid_key UNIQUE (uuid);


--
-- Name: conversation_account_state conversation_account_state_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversation_account_state
    ADD CONSTRAINT conversation_account_state_pkey PRIMARY KEY (account_id, conversation_uuid);


--
-- Name: conversation_message_files conversation_message_files_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversation_message_files
    ADD CONSTRAINT conversation_message_files_pkey PRIMARY KEY (id);


--
-- Name: conversation_message_files conversation_message_files_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversation_message_files
    ADD CONSTRAINT conversation_message_files_uuid_key UNIQUE (uuid);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversations
    ADD CONSTRAINT conversations_uuid_key UNIQUE (uuid);


--
-- Name: departments departments_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.departments
    ADD CONSTRAINT departments_pkey PRIMARY KEY (id);


--
-- Name: departments departments_tenant_id_parent_id_name_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.departments
    ADD CONSTRAINT departments_tenant_id_parent_id_name_key UNIQUE (tenant_id, parent_id, name);


--
-- Name: departments departments_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.departments
    ADD CONSTRAINT departments_uuid_key UNIQUE (uuid);


--
-- Name: digital_employee_visibility_overrides digital_employee_visibility_overrides_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employee_visibility_overrides
    ADD CONSTRAINT digital_employee_visibility_overrides_pkey PRIMARY KEY (tenant_id, digital_employee_id);


--
-- Name: digital_employees digital_employees_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employees
    ADD CONSTRAINT digital_employees_pkey PRIMARY KEY (id);


--
-- Name: digital_employees digital_employees_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employees
    ADD CONSTRAINT digital_employees_uuid_key UNIQUE (uuid);


--
-- Name: drive_acl_entries drive_acl_entries_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_acl_entries
    ADD CONSTRAINT drive_acl_entries_pkey PRIMARY KEY (id);


--
-- Name: drive_acl_entries drive_acl_entries_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_acl_entries
    ADD CONSTRAINT drive_acl_entries_uuid_key UNIQUE (uuid);


--
-- Name: drive_file_versions drive_file_versions_file_id_version_no_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_file_versions
    ADD CONSTRAINT drive_file_versions_file_id_version_no_key UNIQUE (file_id, version_no);


--
-- Name: drive_file_versions drive_file_versions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_file_versions
    ADD CONSTRAINT drive_file_versions_pkey PRIMARY KEY (id);


--
-- Name: drive_file_versions drive_file_versions_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_file_versions
    ADD CONSTRAINT drive_file_versions_uuid_key UNIQUE (uuid);


--
-- Name: drive_files drive_files_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_files
    ADD CONSTRAINT drive_files_pkey PRIMARY KEY (id);


--
-- Name: drive_files drive_files_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_files
    ADD CONSTRAINT drive_files_uuid_key UNIQUE (uuid);


--
-- Name: drive_folders drive_folders_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_folders
    ADD CONSTRAINT drive_folders_pkey PRIMARY KEY (id);


--
-- Name: drive_folders drive_folders_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_folders
    ADD CONSTRAINT drive_folders_uuid_key UNIQUE (uuid);


--
-- Name: drive_quotas drive_quotas_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_quotas
    ADD CONSTRAINT drive_quotas_pkey PRIMARY KEY (id);


--
-- Name: drive_quotas drive_quotas_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_quotas
    ADD CONSTRAINT drive_quotas_uuid_key UNIQUE (uuid);


--
-- Name: drive_recycle_bin drive_recycle_bin_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_recycle_bin
    ADD CONSTRAINT drive_recycle_bin_pkey PRIMARY KEY (id);


--
-- Name: drive_recycle_bin drive_recycle_bin_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_recycle_bin
    ADD CONSTRAINT drive_recycle_bin_uuid_key UNIQUE (uuid);


--
-- Name: drive_share_links drive_share_links_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_share_links
    ADD CONSTRAINT drive_share_links_pkey PRIMARY KEY (id);


--
-- Name: drive_share_links drive_share_links_token_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_share_links
    ADD CONSTRAINT drive_share_links_token_key UNIQUE (token);


--
-- Name: drive_share_links drive_share_links_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_share_links
    ADD CONSTRAINT drive_share_links_uuid_key UNIQUE (uuid);


--
-- Name: drive_spaces drive_spaces_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_spaces
    ADD CONSTRAINT drive_spaces_pkey PRIMARY KEY (id);


--
-- Name: drive_spaces drive_spaces_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_spaces
    ADD CONSTRAINT drive_spaces_uuid_key UNIQUE (uuid);


--
-- Name: drive_storage_defaults drive_storage_defaults_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_defaults
    ADD CONSTRAINT drive_storage_defaults_pkey PRIMARY KEY (id);


--
-- Name: drive_storage_defaults drive_storage_defaults_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_defaults
    ADD CONSTRAINT drive_storage_defaults_uuid_key UNIQUE (uuid);


--
-- Name: drive_storage_overrides drive_storage_overrides_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_overrides
    ADD CONSTRAINT drive_storage_overrides_pkey PRIMARY KEY (id);


--
-- Name: drive_storage_overrides drive_storage_overrides_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_overrides
    ADD CONSTRAINT drive_storage_overrides_uuid_key UNIQUE (uuid);


--
-- Name: drive_upload_tickets drive_upload_tickets_file_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_upload_tickets
    ADD CONSTRAINT drive_upload_tickets_file_uuid_key UNIQUE (file_uuid);


--
-- Name: drive_upload_tickets drive_upload_tickets_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_upload_tickets
    ADD CONSTRAINT drive_upload_tickets_pkey PRIMARY KEY (id);


--
-- Name: drive_worker_job_failures drive_worker_job_failures_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_worker_job_failures
    ADD CONSTRAINT drive_worker_job_failures_pkey PRIMARY KEY (id);


--
-- Name: drive_worker_job_status drive_worker_job_status_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_worker_job_status
    ADD CONSTRAINT drive_worker_job_status_pkey PRIMARY KEY (job);


--
-- Name: drive_worker_job_triggers drive_worker_job_triggers_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_worker_job_triggers
    ADD CONSTRAINT drive_worker_job_triggers_pkey PRIMARY KEY (id);


--
-- Name: events_outbox_dlq events_outbox_dlq_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.events_outbox_dlq
    ADD CONSTRAINT events_outbox_dlq_pkey PRIMARY KEY (id);


--
-- Name: events_outbox events_outbox_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.events_outbox
    ADD CONSTRAINT events_outbox_pkey PRIMARY KEY (id);


--
-- Name: im_connection_client_metadata im_connection_client_metadata_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_client_metadata
    ADD CONSTRAINT im_connection_client_metadata_pkey PRIMARY KEY (tenant_id, account_id, device_key);


--
-- Name: im_connection_collector_status im_connection_collector_status_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_collector_status
    ADD CONSTRAINT im_connection_collector_status_pkey PRIMARY KEY (singleton);


--
-- Name: im_connection_events im_connection_events_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_events
    ADD CONSTRAINT im_connection_events_pkey PRIMARY KEY (id);


--
-- Name: im_connection_events im_connection_events_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_events
    ADD CONSTRAINT im_connection_events_uuid_key UNIQUE (uuid);


--
-- Name: im_connection_states im_connection_states_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_states
    ADD CONSTRAINT im_connection_states_pkey PRIMARY KEY (id);


--
-- Name: im_connection_states im_connection_states_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_states
    ADD CONSTRAINT im_connection_states_uuid_key UNIQUE (uuid);


--
-- Name: kb_documents kb_documents_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_documents
    ADD CONSTRAINT kb_documents_pkey PRIMARY KEY (id);


--
-- Name: kb_documents kb_documents_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_documents
    ADD CONSTRAINT kb_documents_uuid_key UNIQUE (uuid);


--
-- Name: kb_folders kb_folders_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_folders
    ADD CONSTRAINT kb_folders_pkey PRIMARY KEY (id);


--
-- Name: kb_folders kb_folders_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_folders
    ADD CONSTRAINT kb_folders_uuid_key UNIQUE (uuid);


--
-- Name: kb_provider_config kb_provider_config_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_provider_config
    ADD CONSTRAINT kb_provider_config_pkey PRIMARY KEY (id);


--
-- Name: kb_provider_config kb_provider_config_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_provider_config
    ADD CONSTRAINT kb_provider_config_uuid_key UNIQUE (uuid);


--
-- Name: knowledge_bases knowledge_bases_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.knowledge_bases
    ADD CONSTRAINT knowledge_bases_pkey PRIMARY KEY (id);


--
-- Name: knowledge_bases knowledge_bases_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.knowledge_bases
    ADD CONSTRAINT knowledge_bases_uuid_key UNIQUE (uuid);


--
-- Name: login_sessions login_sessions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.login_sessions
    ADD CONSTRAINT login_sessions_pkey PRIMARY KEY (id);


--
-- Name: login_sessions login_sessions_refresh_token_hash_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.login_sessions
    ADD CONSTRAINT login_sessions_refresh_token_hash_key UNIQUE (refresh_token_hash);


--
-- Name: login_sessions login_sessions_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.login_sessions
    ADD CONSTRAINT login_sessions_uuid_key UNIQUE (uuid);


--
-- Name: menu_permissions menu_permissions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.menu_permissions
    ADD CONSTRAINT menu_permissions_pkey PRIMARY KEY (menu_id, permission_id);


--
-- Name: menus menus_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.menus
    ADD CONSTRAINT menus_pkey PRIMARY KEY (id);


--
-- Name: menus menus_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.menus
    ADD CONSTRAINT menus_uuid_key UNIQUE (uuid);


--
-- Name: message_streams message_streams_message_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.message_streams
    ADD CONSTRAINT message_streams_message_uuid_key UNIQUE (message_uuid);


--
-- Name: message_streams message_streams_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.message_streams
    ADD CONSTRAINT message_streams_pkey PRIMARY KEY (id);


--
-- Name: message_streams message_streams_stream_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.message_streams
    ADD CONSTRAINT message_streams_stream_id_key UNIQUE (stream_id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id, created_at);


--
-- Name: messages_default messages_default_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.messages_default
    ADD CONSTRAINT messages_default_pkey PRIMARY KEY (id, created_at);


--
-- Name: permissions permissions_code_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.permissions
    ADD CONSTRAINT permissions_code_key UNIQUE (code);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (id);


--
-- Name: role_assignments role_assignments_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_assignments
    ADD CONSTRAINT role_assignments_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_id, permission_id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: roles roles_scope_kind_tenant_id_code_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.roles
    ADD CONSTRAINT roles_scope_kind_tenant_id_code_key UNIQUE (scope_kind, tenant_id, code);


--
-- Name: roles roles_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.roles
    ADD CONSTRAINT roles_uuid_key UNIQUE (uuid);


--
-- Name: room_direct_pairs room_direct_pairs_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs
    ADD CONSTRAINT room_direct_pairs_pkey PRIMARY KEY (id);


--
-- Name: room_direct_pairs room_direct_pairs_room_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs
    ADD CONSTRAINT room_direct_pairs_room_id_key UNIQUE (room_id);


--
-- Name: room_direct_pairs room_direct_pairs_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs
    ADD CONSTRAINT room_direct_pairs_uuid_key UNIQUE (uuid);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_pkey PRIMARY KEY (id);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_room_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_room_id_key UNIQUE (room_id);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_uuid_key UNIQUE (uuid);


--
-- Name: room_participants room_participants_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_participants
    ADD CONSTRAINT room_participants_pkey PRIMARY KEY (id);


--
-- Name: room_participants room_participants_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_participants
    ADD CONSTRAINT room_participants_uuid_key UNIQUE (uuid);


--
-- Name: rooms rooms_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.rooms
    ADD CONSTRAINT rooms_pkey PRIMARY KEY (id);


--
-- Name: rooms rooms_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.rooms
    ADD CONSTRAINT rooms_uuid_key UNIQUE (uuid);


--
-- Name: runtime_environments runtime_environments_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.runtime_environments
    ADD CONSTRAINT runtime_environments_pkey PRIMARY KEY (id);


--
-- Name: runtime_environments runtime_environments_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.runtime_environments
    ADD CONSTRAINT runtime_environments_uuid_key UNIQUE (uuid);


--
-- Name: skill_categories skill_categories_code_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skill_categories
    ADD CONSTRAINT skill_categories_code_key UNIQUE (code);


--
-- Name: skill_categories skill_categories_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skill_categories
    ADD CONSTRAINT skill_categories_pkey PRIMARY KEY (id);


--
-- Name: skill_versions skill_versions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skill_versions
    ADD CONSTRAINT skill_versions_pkey PRIMARY KEY (id);


--
-- Name: skill_versions skill_versions_skill_id_version_uniq; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skill_versions
    ADD CONSTRAINT skill_versions_skill_id_version_uniq UNIQUE (skill_id, version);


--
-- Name: skill_versions skill_versions_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skill_versions
    ADD CONSTRAINT skill_versions_uuid_key UNIQUE (uuid);


--
-- Name: skills skills_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skills
    ADD CONSTRAINT skills_pkey PRIMARY KEY (id);


--
-- Name: skills skills_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skills
    ADD CONSTRAINT skills_uuid_key UNIQUE (uuid);


--
-- Name: tenant_agent_positions tenant_agent_positions_agent_id_position_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_agent_positions
    ADD CONSTRAINT tenant_agent_positions_agent_id_position_id_key UNIQUE (agent_id, position_id);


--
-- Name: tenant_agent_positions tenant_agent_positions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_agent_positions
    ADD CONSTRAINT tenant_agent_positions_pkey PRIMARY KEY (id);


--
-- Name: tenant_member_positions tenant_member_positions_membership_id_position_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_member_positions
    ADD CONSTRAINT tenant_member_positions_membership_id_position_id_key UNIQUE (membership_id, position_id);


--
-- Name: tenant_member_positions tenant_member_positions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_member_positions
    ADD CONSTRAINT tenant_member_positions_pkey PRIMARY KEY (id);


--
-- Name: tenant_memberships tenant_memberships_account_id_tenant_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_memberships
    ADD CONSTRAINT tenant_memberships_account_id_tenant_id_key UNIQUE (account_id, tenant_id);


--
-- Name: tenant_memberships tenant_memberships_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_memberships
    ADD CONSTRAINT tenant_memberships_pkey PRIMARY KEY (id);


--
-- Name: tenant_positions tenant_positions_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_positions
    ADD CONSTRAINT tenant_positions_pkey PRIMARY KEY (id);


--
-- Name: tenant_positions tenant_positions_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_positions
    ADD CONSTRAINT tenant_positions_uuid_key UNIQUE (uuid);


--
-- Name: tenant_runtime_enablements tenant_runtime_enablements_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_runtime_enablements
    ADD CONSTRAINT tenant_runtime_enablements_pkey PRIMARY KEY (id);


--
-- Name: tenant_runtime_enablements tenant_runtime_enablements_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_runtime_enablements
    ADD CONSTRAINT tenant_runtime_enablements_uuid_key UNIQUE (uuid);


--
-- Name: tenant_webhook_configs tenant_webhook_configs_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_webhook_configs
    ADD CONSTRAINT tenant_webhook_configs_pkey PRIMARY KEY (id);


--
-- Name: tenant_webhook_configs tenant_webhook_configs_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_webhook_configs
    ADD CONSTRAINT tenant_webhook_configs_uuid_key UNIQUE (uuid);


--
-- Name: tenant_webhook_deliveries tenant_webhook_deliveries_outbox_id_webhook_config_id_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_webhook_deliveries
    ADD CONSTRAINT tenant_webhook_deliveries_outbox_id_webhook_config_id_key UNIQUE (outbox_id, webhook_config_id);


--
-- Name: tenant_webhook_deliveries tenant_webhook_deliveries_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_webhook_deliveries
    ADD CONSTRAINT tenant_webhook_deliveries_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_name_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenants
    ADD CONSTRAINT tenants_name_key UNIQUE (name);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_slug_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenants
    ADD CONSTRAINT tenants_slug_key UNIQUE (slug);


--
-- Name: tenants tenants_uuid_key; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenants
    ADD CONSTRAINT tenants_uuid_key UNIQUE (uuid);


--
-- Name: chat_media_refs uq_chat_media_refs_uuid; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_media_refs
    ADD CONSTRAINT uq_chat_media_refs_uuid UNIQUE (uuid);


--
-- Name: im_connection_states uq_im_connection_states_uid_device; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_states
    ADD CONSTRAINT uq_im_connection_states_uid_device UNIQUE (uid, device_key);


--
-- Name: wukong_send_outbox wukong_send_outbox_dedup_uniq; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.wukong_send_outbox
    ADD CONSTRAINT wukong_send_outbox_dedup_uniq UNIQUE (tenant_id, dedup_key);


--
-- Name: wukong_send_outbox wukong_send_outbox_pkey; Type: CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.wukong_send_outbox
    ADD CONSTRAINT wukong_send_outbox_pkey PRIMARY KEY (id);


--
-- Name: content_favorites_account_list_idx; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX content_favorites_account_list_idx ON agent_bus.content_favorites USING btree (tenant_id, account_id, created_at DESC) WHERE (is_deleted = false);


--
-- Name: content_favorites_active_drive_file_uq; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX content_favorites_active_drive_file_uq ON agent_bus.content_favorites USING btree (tenant_id, account_id, drive_file_id) WHERE (((target_kind)::text = 'drive_file'::text) AND (is_deleted = false));


--
-- Name: content_favorites_active_kb_document_uq; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX content_favorites_active_kb_document_uq ON agent_bus.content_favorites USING btree (tenant_id, account_id, kb_document_id) WHERE (((target_kind)::text = 'kb_document'::text) AND (is_deleted = false));


--
-- Name: idx_accounts_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_accounts_status ON agent_bus.accounts USING btree (status) WHERE (deleted_at IS NULL);


--
-- Name: idx_acl_subject; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_acl_subject ON agent_bus.drive_acl_entries USING btree (subject_kind, subject_id) WHERE (is_deleted = false);


--
-- Name: idx_acl_target; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_acl_target ON agent_bus.drive_acl_entries USING btree (target_kind, target_id) WHERE (is_deleted = false);


--
-- Name: idx_agent_app_bindings_agent; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_agent_app_bindings_agent ON agent_bus.agent_app_bindings USING btree (agent_id);


--
-- Name: idx_agent_kb_bindings_agent; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_agent_kb_bindings_agent ON agent_bus.agent_kb_bindings USING btree (agent_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_agent_kb_bindings_kb; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_agent_kb_bindings_kb ON agent_bus.agent_kb_bindings USING btree (kb_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_agent_positions_position; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_agent_positions_position ON agent_bus.tenant_agent_positions USING btree (position_id);


--
-- Name: idx_agent_primary_position; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX idx_agent_primary_position ON agent_bus.tenant_agent_positions USING btree (agent_id) WHERE (is_primary = true);


--
-- Name: idx_agent_skill_bindings_agent; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_agent_skill_bindings_agent ON agent_bus.agent_skill_bindings USING btree (agent_id, sort_order);


--
-- Name: idx_agent_skill_bindings_skill; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_agent_skill_bindings_skill ON agent_bus.agent_skill_bindings USING btree (skill_id);


--
-- Name: idx_app_category_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_app_category_tenant ON agent_bus.app_category USING btree (tenant_id, sort_order, id);


--
-- Name: idx_app_oauth_clients_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_app_oauth_clients_tenant ON agent_bus.app_oauth_clients USING btree (tenant_id) WHERE ((status)::text = 'active'::text);


--
-- Name: idx_apps_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_apps_tenant ON agent_bus.apps USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_apps_tenant_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_apps_tenant_status ON agent_bus.apps USING btree (tenant_id, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_atl_tenant_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_atl_tenant_time ON agent_bus.agent_trigger_log USING btree (tenant_id, received_at DESC);


--
-- Name: idx_audit_events_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_audit_events_account ON agent_bus.audit_events USING btree (account_id, occurred_at DESC) WHERE (account_id IS NOT NULL);


--
-- Name: idx_audit_events_domain_kind; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_audit_events_domain_kind ON agent_bus.audit_events USING btree (domain, event_kind, occurred_at DESC);


--
-- Name: idx_audit_events_payload_gin; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_audit_events_payload_gin ON agent_bus.audit_events USING gin (payload jsonb_path_ops);


--
-- Name: idx_audit_events_tenant_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_audit_events_tenant_time ON agent_bus.audit_events USING btree (tenant_id, occurred_at DESC);


--
-- Name: idx_audit_events_trace; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_audit_events_trace ON agent_bus.audit_events USING btree (trace_id) WHERE (trace_id IS NOT NULL);


--
-- Name: idx_audit_summary_tenant_date; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_audit_summary_tenant_date ON agent_bus.audit_summary USING btree (tenant_id, bucket_date);


--
-- Name: idx_auth_audit_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_auth_audit_account ON agent_bus.auth_audit_events USING btree (account_id, occurred_at DESC);


--
-- Name: idx_auth_audit_event; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_auth_audit_event ON agent_bus.auth_audit_events USING btree (event_kind, occurred_at DESC);


--
-- Name: idx_auth_audit_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_auth_audit_tenant ON agent_bus.auth_audit_events USING btree (tenant_id, occurred_at DESC) WHERE (tenant_id IS NOT NULL);


--
-- Name: idx_av_de_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_av_de_status ON agent_bus.agent_versions USING btree (digital_employee_id, status);


--
-- Name: idx_av_one_grayed; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX idx_av_one_grayed ON agent_bus.agent_versions USING btree (digital_employee_id) WHERE ((status)::text = 'grayed'::text);


--
-- Name: idx_cas_account_hidden; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cas_account_hidden ON agent_bus.conversation_account_state USING btree (account_id, hidden_at);


--
-- Name: idx_cas_account_pinned; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cas_account_pinned ON agent_bus.conversation_account_state USING btree (account_id, pinned_at DESC NULLS LAST) WHERE (pinned_at IS NOT NULL);


--
-- Name: idx_cas_tenant_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cas_tenant_account ON agent_bus.conversation_account_state USING btree (tenant_id, account_id);


--
-- Name: idx_cmf_conv_msg; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cmf_conv_msg ON agent_bus.conversation_message_files USING btree (conversation_uuid, message_uuid) WHERE (is_deleted = false);


--
-- Name: idx_cmf_drive_file; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cmf_drive_file ON agent_bus.conversation_message_files USING btree (drive_file_uuid) WHERE (is_deleted = false);


--
-- Name: idx_cmr_conversation; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cmr_conversation ON agent_bus.chat_media_refs USING btree (conversation_id);


--
-- Name: idx_cmr_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cmr_tenant ON agent_bus.chat_media_refs USING btree (tenant_id);


--
-- Name: idx_cmt_claim; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cmt_claim ON agent_bus.chat_message_tasks USING btree (status, next_retry_at);


--
-- Name: idx_cmt_conv; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cmt_conv ON agent_bus.chat_message_tasks USING btree (conversation_id, status);


--
-- Name: idx_cmt_lease; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cmt_lease ON agent_bus.chat_message_tasks USING btree (status, locked_until) WHERE (status = 'running'::text);


--
-- Name: idx_cmt_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_cmt_tenant ON agent_bus.chat_message_tasks USING btree (tenant_id, status);


--
-- Name: idx_conv_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_conv_account ON agent_bus.conversations USING btree (account_id, last_message_at DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_conv_room_active_v2e; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX idx_conv_room_active_v2e ON agent_bus.conversations USING btree (room_id) WHERE ((room_id IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: INDEX idx_conv_room_active_v2e; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON INDEX agent_bus.idx_conv_room_active_v2e IS 'module: m4 / batch-2e T2E.9; 每个 room 唯一活跃 conversation; 防并发 POST /rooms 双写';


--
-- Name: idx_conv_single_active_v2d; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX idx_conv_single_active_v2d ON agent_bus.conversations USING btree (tenant_id, account_id, digital_employee_id) WHERE ((room_id IS NULL) AND (digital_employee_id IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: INDEX idx_conv_single_active_v2d; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON INDEX agent_bus.idx_conv_single_active_v2d IS 'module: m4 / batch-2d T2D.9; 同 (tenant, account, agent) 仅一条活跃 single-chat conversation; service 层捕 23505 后回查 FindActiveSingle 复用';


--
-- Name: idx_conv_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_conv_tenant ON agent_bus.conversations USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_conversation_account_state_cleared; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_conversation_account_state_cleared ON agent_bus.conversation_account_state USING btree (account_id, conversation_uuid, cleared_at) WHERE (cleared_at IS NOT NULL);


--
-- Name: idx_de_creator; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_de_creator ON agent_bus.digital_employees USING btree (creator_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_de_status_visibility; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_de_status_visibility ON agent_bus.digital_employees USING btree (status, visibility) WHERE (deleted_at IS NULL);


--
-- Name: idx_de_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_de_tenant ON agent_bus.digital_employees USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_de_workspace; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_de_workspace ON agent_bus.digital_employees USING btree (workspace_id) WHERE ((deleted_at IS NULL) AND ((visibility)::text = 'workspace'::text));


--
-- Name: idx_departments_name; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX idx_departments_name ON agent_bus.departments USING btree (tenant_id, COALESCE(parent_id, (0)::bigint), name) WHERE (deleted_at IS NULL);


--
-- Name: idx_departments_path; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_departments_path ON agent_bus.departments USING btree (tenant_id, path text_pattern_ops);


--
-- Name: idx_departments_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_departments_tenant ON agent_bus.departments USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_des_source_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_des_source_status ON agent_bus.digital_employees USING btree (source, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_des_tenant_visibility; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_des_tenant_visibility ON agent_bus.digital_employees USING btree (tenant_id, visibility, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_devo_tenant_hidden; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_devo_tenant_hidden ON agent_bus.digital_employee_visibility_overrides USING btree (tenant_id, hidden);


--
-- Name: idx_dfile_copying; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dfile_copying ON agent_bus.drive_files USING btree (copy_status, copy_started_at) WHERE (((copy_status)::text = ANY (ARRAY[('copying'::character varying)::text, ('copy_failed'::character varying)::text])) AND (is_deleted = false));


--
-- Name: idx_dfile_folder; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dfile_folder ON agent_bus.drive_files USING btree (drive_folder_id) WHERE ((drive_folder_id IS NOT NULL) AND (is_deleted = false));


--
-- Name: idx_dfile_name_fulltext; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dfile_name_fulltext ON agent_bus.drive_files USING gin (to_tsvector('simple'::regconfig, (name)::text)) WHERE (is_deleted = false);


--
-- Name: idx_dfile_name_tsv; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dfile_name_tsv ON agent_bus.drive_files USING gin (to_tsvector('simple'::regconfig, (name)::text)) WHERE (is_deleted = false);


--
-- Name: idx_dfile_origin_conv; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dfile_origin_conv ON agent_bus.drive_files USING btree (origin_conversation_uuid) WHERE (origin_conversation_uuid IS NOT NULL);


--
-- Name: idx_dfile_space_scope_folder; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dfile_space_scope_folder ON agent_bus.drive_files USING btree (space_id, scope, drive_folder_id) WHERE (is_deleted = false);


--
-- Name: idx_dfv_file; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dfv_file ON agent_bus.drive_file_versions USING btree (file_id) WHERE (is_deleted = false);


--
-- Name: idx_dfv_superseded; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dfv_superseded ON agent_bus.drive_file_versions USING btree (superseded_at);


--
-- Name: idx_drive_worker_job_failures_job_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_drive_worker_job_failures_job_time ON agent_bus.drive_worker_job_failures USING btree (job, occurred_at DESC);


--
-- Name: idx_dsd_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dsd_status ON agent_bus.drive_storage_defaults USING btree (status) WHERE (is_deleted = false);


--
-- Name: idx_dspace_tenant_kind; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_dspace_tenant_kind ON agent_bus.drive_spaces USING btree (tenant_id, kind) WHERE (is_deleted = false);


--
-- Name: idx_folder_agent; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_folder_agent ON agent_bus.drive_folders USING btree (agent_id) WHERE (((kind)::text = ANY (ARRAY[('de_agent'::character varying)::text, ('de_outputs'::character varying)::text])) AND (is_deleted = false));


--
-- Name: idx_folder_space_parent; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_folder_space_parent ON agent_bus.drive_folders USING btree (space_id, parent_id) WHERE (is_deleted = false);


--
-- Name: idx_identities_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_identities_account ON agent_bus.account_identities USING btree (account_id);


--
-- Name: idx_im_connection_client_metadata_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_client_metadata_account ON agent_bus.im_connection_client_metadata USING btree (account_id, reported_at DESC);


--
-- Name: idx_im_connection_events_account_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_events_account_time ON agent_bus.im_connection_events USING btree (account_id, occurred_at DESC) WHERE (account_id IS NOT NULL);


--
-- Name: idx_im_connection_events_reconnect_device; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_events_reconnect_device ON agent_bus.im_connection_events USING btree (tenant_id, account_id, device_key, occurred_at DESC) WHERE ((event_type)::text = 'reconnected'::text);


--
-- Name: idx_im_connection_events_state_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_events_state_time ON agent_bus.im_connection_events USING btree (state_uuid, occurred_at DESC);


--
-- Name: idx_im_connection_events_tenant_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_events_tenant_time ON agent_bus.im_connection_events USING btree (tenant_id, occurred_at DESC);


--
-- Name: idx_im_connection_events_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_events_time ON agent_bus.im_connection_events USING btree (occurred_at DESC);


--
-- Name: idx_im_connection_states_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_states_account ON agent_bus.im_connection_states USING btree (account_id, last_seen_at DESC) WHERE (account_id IS NOT NULL);


--
-- Name: idx_im_connection_states_status_seen; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_states_status_seen ON agent_bus.im_connection_states USING btree (status, last_seen_at DESC);


--
-- Name: idx_im_connection_states_tenant_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_im_connection_states_tenant_status ON agent_bus.im_connection_states USING btree (tenant_id, status, last_seen_at DESC);


--
-- Name: idx_kb_doc_kb; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kb_doc_kb ON agent_bus.kb_documents USING btree (kb_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_kb_doc_provider_doc; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kb_doc_provider_doc ON agent_bus.kb_documents USING btree (provider_doc_id) WHERE (provider_doc_id IS NOT NULL);


--
-- Name: idx_kb_owner_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kb_owner_account ON agent_bus.knowledge_bases USING btree (owner_account_id) WHERE (((space_kind)::text = 'personal'::text) AND (deleted_at IS NULL));


--
-- Name: idx_kb_provider_kind; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kb_provider_kind ON agent_bus.kb_provider_config USING btree (provider_kind);


--
-- Name: idx_kb_ragflow_dataset; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kb_ragflow_dataset ON agent_bus.knowledge_bases USING btree (ragflow_dataset_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_kb_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kb_tenant ON agent_bus.knowledge_bases USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_kbdoc_drive; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kbdoc_drive ON agent_bus.kb_documents USING btree (drive_file_uuid) WHERE ((source_kind)::text = 'drive_sync'::text);


--
-- Name: idx_kbdoc_pending; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kbdoc_pending ON agent_bus.kb_documents USING btree (kb_id, status) WHERE ((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('ingesting'::character varying)::text]));


--
-- Name: idx_kbdoc_ragflow; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_kbdoc_ragflow ON agent_bus.kb_documents USING btree (ragflow_document_id);


--
-- Name: idx_link_target; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_link_target ON agent_bus.drive_share_links USING btree (target_kind, target_id) WHERE (is_deleted = false);


--
-- Name: idx_link_token; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_link_token ON agent_bus.drive_share_links USING btree (token) WHERE ((is_deleted = false) AND (revoked_at IS NULL));


--
-- Name: idx_login_sessions_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_login_sessions_account ON agent_bus.login_sessions USING btree (account_id, expires_at) WHERE (revoked_at IS NULL);


--
-- Name: idx_login_sessions_expires; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_login_sessions_expires ON agent_bus.login_sessions USING btree (expires_at) WHERE (revoked_at IS NULL);


--
-- Name: idx_login_sessions_prev_refresh_hash; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_login_sessions_prev_refresh_hash ON agent_bus.login_sessions USING btree (prev_refresh_token_hash) WHERE (prev_refresh_token_hash IS NOT NULL);


--
-- Name: idx_member_positions_position; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_member_positions_position ON agent_bus.tenant_member_positions USING btree (position_id);


--
-- Name: idx_member_primary_position; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX idx_member_primary_position ON agent_bus.tenant_member_positions USING btree (membership_id) WHERE (is_primary = true);


--
-- Name: idx_memberships_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_memberships_account ON agent_bus.tenant_memberships USING btree (account_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_memberships_dept; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_memberships_dept ON agent_bus.tenant_memberships USING btree (department_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_memberships_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_memberships_tenant ON agent_bus.tenant_memberships USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_menus_parent; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_menus_parent ON agent_bus.menus USING btree (parent_id);


--
-- Name: idx_menus_scope; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_menus_scope ON agent_bus.menus USING btree (scope_kind) WHERE ((deleted_at IS NULL) AND (is_visible = true));


--
-- Name: idx_messages_conv_ts; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_messages_conv_ts ON ONLY agent_bus.messages USING btree (conversation_id, created_at DESC);


--
-- Name: idx_messages_room; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_messages_room ON ONLY agent_bus.messages USING btree (room_id, created_at DESC) WHERE (room_id IS NOT NULL);


--
-- Name: idx_messages_stream; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_messages_stream ON ONLY agent_bus.messages USING btree (stream_id) WHERE (stream_id IS NOT NULL);


--
-- Name: idx_messages_tenant_created_overview; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_messages_tenant_created_overview ON ONLY agent_bus.messages USING btree (tenant_id, created_at DESC) INCLUDE (conversation_id, role, sender_account_id);


--
-- Name: idx_messages_trace; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_messages_trace ON ONLY agent_bus.messages USING btree (trace_id) WHERE (trace_id IS NOT NULL);


--
-- Name: idx_ms_active; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_ms_active ON agent_bus.message_streams USING btree (bus_node_id) WHERE ((state)::text = 'active'::text);


--
-- Name: idx_ms_conv; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_ms_conv ON agent_bus.message_streams USING btree (conversation_id);


--
-- Name: idx_ms_tenant_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_ms_tenant_account ON agent_bus.message_streams USING btree (tenant_id, account_id, started_at DESC);


--
-- Name: idx_outbox_consume; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_outbox_consume ON agent_bus.events_outbox USING btree (status, created_at) WHERE ((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('failed'::character varying)::text]));


--
-- Name: idx_outbox_dispatch; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_outbox_dispatch ON agent_bus.events_outbox USING btree (status, next_retry_at NULLS FIRST, created_at) WHERE ((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('picked'::character varying)::text]));


--
-- Name: idx_outbox_dlq_outbox; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_outbox_dlq_outbox ON agent_bus.events_outbox_dlq USING btree (outbox_id);


--
-- Name: idx_outbox_dlq_topic_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_outbox_dlq_topic_time ON agent_bus.events_outbox_dlq USING btree (topic, dlq_at DESC);


--
-- Name: idx_outbox_topic_time; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_outbox_topic_time ON agent_bus.events_outbox USING btree (topic, created_at DESC);


--
-- Name: idx_outbox_trace; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_outbox_trace ON agent_bus.events_outbox USING btree (trace_id) WHERE (trace_id IS NOT NULL);


--
-- Name: idx_permissions_category; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_permissions_category ON agent_bus.permissions USING btree (category);


--
-- Name: idx_permissions_kind_scope; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_permissions_kind_scope ON agent_bus.permissions USING btree (kind, scope_kind);


--
-- Name: idx_rdpwa_tenant_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_rdpwa_tenant_account ON agent_bus.room_direct_pairs_with_agent USING btree (tenant_id, account_id) WHERE (is_deleted = false);


--
-- Name: idx_rdpwa_tenant_agent; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_rdpwa_tenant_agent ON agent_bus.room_direct_pairs_with_agent USING btree (tenant_id, agent_id) WHERE (is_deleted = false);


--
-- Name: idx_recycle_expires; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_recycle_expires ON agent_bus.drive_recycle_bin USING btree (expires_at) WHERE (is_deleted = false);


--
-- Name: idx_recycle_space; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_recycle_space ON agent_bus.drive_recycle_bin USING btree (space_id, deleted_at_logical DESC) WHERE (is_deleted = false);


--
-- Name: idx_renv_framework; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_renv_framework ON agent_bus.runtime_environments USING btree (framework) WHERE (is_deleted = false);


--
-- Name: idx_renv_open_platform; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_renv_open_platform ON agent_bus.runtime_environments USING btree (open_to_tenants) WHERE (((scope)::text = 'platform'::text) AND (enabled = true) AND (is_deleted = false));


--
-- Name: idx_renv_scope_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_renv_scope_tenant ON agent_bus.runtime_environments USING btree (scope, tenant_id) WHERE (is_deleted = false);


--
-- Name: idx_renv_tenant_active; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_renv_tenant_active ON agent_bus.runtime_environments USING btree (tenant_id) WHERE (((scope)::text = 'tenant'::text) AND (is_deleted = false));


--
-- Name: idx_role_assignments_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_role_assignments_account ON agent_bus.role_assignments USING btree (account_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_role_assignments_impersonate; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_role_assignments_impersonate ON agent_bus.role_assignments USING btree (granted_reason, expires_at) WHERE (((granted_reason)::text = 'impersonate'::text) AND (deleted_at IS NULL));


--
-- Name: idx_role_assignments_scope; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_role_assignments_scope ON agent_bus.role_assignments USING btree (scope_kind, tenant_id, workspace_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_roles_scope; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_roles_scope ON agent_bus.roles USING btree (scope_kind, tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_rooms_tenant_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_rooms_tenant_status ON agent_bus.rooms USING btree (tenant_id, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_rooms_wukong_channel_id; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_rooms_wukong_channel_id ON agent_bus.rooms USING btree (wukong_channel_id) WHERE ((wukong_channel_id IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: idx_rp_room; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_rp_room ON agent_bus.room_participants USING btree (room_id) WHERE (left_at IS NULL);


--
-- Name: idx_skill_categories_not_deleted; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_skill_categories_not_deleted ON agent_bus.skill_categories USING btree (status, sort_order, id) WHERE (is_deleted = false);


--
-- Name: idx_skill_versions_published_at; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_skill_versions_published_at ON agent_bus.skill_versions USING btree (published_at DESC) WHERE ((status)::text = 'published'::text);


--
-- Name: idx_skill_versions_skill_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_skill_versions_skill_status ON agent_bus.skill_versions USING btree (skill_id, status);


--
-- Name: idx_skills_builtin_key; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_skills_builtin_key ON agent_bus.skills USING btree (builtin_key) WHERE ((kind)::text = 'builtin'::text);


--
-- Name: idx_skills_category; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_skills_category ON agent_bus.skills USING btree (category_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_skills_install_count; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_skills_install_count ON agent_bus.skills USING btree (install_count DESC) WHERE ((status)::text = 'active'::text);


--
-- Name: idx_skills_kind_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_skills_kind_status ON agent_bus.skills USING btree (kind, status);


--
-- Name: idx_skills_scope_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_skills_scope_tenant ON agent_bus.skills USING btree (scope_kind, tenant_id) WHERE (((status)::text = 'active'::text) AND (deleted_at IS NULL));


--
-- Name: idx_tenant_positions_name; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX idx_tenant_positions_name ON agent_bus.tenant_positions USING btree (tenant_id, name) WHERE (deleted_at IS NULL);


--
-- Name: idx_tenant_positions_sort; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_tenant_positions_sort ON agent_bus.tenant_positions USING btree (tenant_id, sort_order, id) WHERE (deleted_at IS NULL);


--
-- Name: idx_tenant_webhook_configs_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_tenant_webhook_configs_tenant ON agent_bus.tenant_webhook_configs USING btree (tenant_id) WHERE ((deleted_at IS NULL) AND (enabled = true));


--
-- Name: idx_tenants_owner; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_tenants_owner ON agent_bus.tenants USING btree (owner_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_tenants_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_tenants_status ON agent_bus.tenants USING btree (status) WHERE (deleted_at IS NULL);


--
-- Name: idx_ticket_expires_status; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_ticket_expires_status ON agent_bus.drive_upload_tickets USING btree (expires_at) WHERE ((status)::text <> 'done'::text);


--
-- Name: idx_tre_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_tre_tenant ON agent_bus.tenant_runtime_enablements USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_webhook_deliveries_pending; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_webhook_deliveries_pending ON agent_bus.tenant_webhook_deliveries USING btree (next_retry_at NULLS FIRST, created_at) WHERE ((status)::text = ANY ((ARRAY['pending'::character varying, 'failed'::character varying])::text[]));


--
-- Name: idx_wukong_send_outbox_due; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_wukong_send_outbox_due ON agent_bus.wukong_send_outbox USING btree (next_attempt_at) WHERE (status = ANY (ARRAY['pending'::text, 'failed'::text]));


--
-- Name: idx_wukong_send_outbox_lease; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX idx_wukong_send_outbox_lease ON agent_bus.wukong_send_outbox USING btree (lock_expires_at) WHERE (status = 'sending'::text);


--
-- Name: ix_apps_platform_code; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX ix_apps_platform_code ON agent_bus.apps USING btree (code) WHERE ((tenant_id IS NULL) AND (deleted_at IS NULL));


--
-- Name: messages_default_conversation_id_created_at_idx; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX messages_default_conversation_id_created_at_idx ON agent_bus.messages_default USING btree (conversation_id, created_at DESC);


--
-- Name: messages_default_room_id_created_at_idx; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX messages_default_room_id_created_at_idx ON agent_bus.messages_default USING btree (room_id, created_at DESC) WHERE (room_id IS NOT NULL);


--
-- Name: messages_default_stream_id_idx; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX messages_default_stream_id_idx ON agent_bus.messages_default USING btree (stream_id) WHERE (stream_id IS NOT NULL);


--
-- Name: messages_default_tenant_id_created_at_conversation_id_role__idx; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX messages_default_tenant_id_created_at_conversation_id_role__idx ON agent_bus.messages_default USING btree (tenant_id, created_at DESC) INCLUDE (conversation_id, role, sender_account_id);


--
-- Name: messages_default_trace_id_idx; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE INDEX messages_default_trace_id_idx ON agent_bus.messages_default USING btree (trace_id) WHERE (trace_id IS NOT NULL);


--
-- Name: uq_accounts_email_active; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_accounts_email_active ON agent_bus.accounts USING btree (lower((email)::text)) WHERE ((email IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: uq_acl_grant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_acl_grant ON agent_bus.drive_acl_entries USING btree (target_kind, target_id, subject_kind, COALESCE(subject_id, (0)::bigint), COALESCE(link_token_id, (0)::bigint)) WHERE (is_deleted = false);


--
-- Name: uq_agent_kb_bindings; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_agent_kb_bindings ON agent_bus.agent_kb_bindings USING btree (agent_id, kb_id) WHERE (deleted_at IS NULL);


--
-- Name: uq_atl_dedup_room; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_atl_dedup_room ON agent_bus.agent_trigger_log USING btree (tenant_id, room_id, substrate, openim_client_msg_id);


--
-- Name: uq_cmf_msg_file; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_cmf_msg_file ON agent_bus.conversation_message_files USING btree (conversation_uuid, message_uuid, drive_file_uuid) WHERE (is_deleted = false);


--
-- Name: uq_cmt_running_conv; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_cmt_running_conv ON agent_bus.chat_message_tasks USING btree (conversation_id) WHERE (status = 'running'::text);


--
-- Name: uq_departments_external_code; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_departments_external_code ON agent_bus.departments USING btree (tenant_id, ((metadata ->> 'external_code'::text))) WHERE ((deleted_at IS NULL) AND ((metadata ->> 'external_code'::text) IS NOT NULL));


--
-- Name: uq_departments_id_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_departments_id_tenant ON agent_bus.departments USING btree (id, tenant_id);


--
-- Name: uq_dfile_folder_name; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_dfile_folder_name ON agent_bus.drive_files USING btree (drive_folder_id, name) WHERE ((is_deleted = false) AND (drive_folder_id IS NOT NULL));


--
-- Name: uq_dfile_space_root_name; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_dfile_space_root_name ON agent_bus.drive_files USING btree (space_id, name) WHERE ((is_deleted = false) AND ((scope)::text = 'drive'::text) AND (drive_folder_id IS NULL));


--
-- Name: uq_drive_worker_job_triggers_pending; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_drive_worker_job_triggers_pending ON agent_bus.drive_worker_job_triggers USING btree (job) WHERE (consumed_at IS NULL);


--
-- Name: uq_dsd_default; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_dsd_default ON agent_bus.drive_storage_defaults USING btree (is_default) WHERE ((is_default = true) AND (is_deleted = false));


--
-- Name: uq_dso_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_dso_tenant ON agent_bus.drive_storage_overrides USING btree (tenant_id) WHERE (is_deleted = false);


--
-- Name: uq_dspace_department; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_dspace_department ON agent_bus.drive_spaces USING btree (tenant_id, department_id) WHERE (((kind)::text = 'department'::text) AND (is_deleted = false));


--
-- Name: uq_dspace_personal; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_dspace_personal ON agent_bus.drive_spaces USING btree (tenant_id, owner_account_id) WHERE (((kind)::text = 'personal'::text) AND (is_deleted = false));


--
-- Name: uq_dspace_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_dspace_tenant ON agent_bus.drive_spaces USING btree (tenant_id) WHERE (((kind)::text = 'tenant'::text) AND (is_deleted = false));


--
-- Name: uq_folder_sibling; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_folder_sibling ON agent_bus.drive_folders USING btree (space_id, COALESCE(parent_id, (0)::bigint), name) WHERE (is_deleted = false);


--
-- Name: uq_kb_document_name_in_folder; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_kb_document_name_in_folder ON agent_bus.kb_documents USING btree (kb_id, COALESCE(folder_id, (0)::bigint), lower((title)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_kb_document_upload_idempotency; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_kb_document_upload_idempotency ON agent_bus.kb_documents USING btree (kb_id, upload_idempotency_key, upload_ordinal) WHERE (upload_idempotency_key IS NOT NULL);


--
-- Name: uq_kb_folder_name_in_parent; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_kb_folder_name_in_parent ON agent_bus.kb_folders USING btree (kb_id, COALESCE(parent_id, (0)::bigint), lower((name)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_kb_provider_default; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_kb_provider_default ON agent_bus.kb_provider_config USING btree (is_default) WHERE (is_default = true);


--
-- Name: uq_local_agent_key; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_local_agent_key ON agent_bus.digital_employees USING btree (tenant_id, creator_id, lower((metadata ->> 'agent_key'::text))) WHERE (((execution_locus)::text = 'local'::text) AND (NOT is_deleted) AND (deleted_at IS NULL));


--
-- Name: INDEX uq_local_agent_key; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON INDEX agent_bus.uq_local_agent_key IS '本地员工身份按租户、创建者、agent_key 唯一，不依赖 nullable 云端环境索引';


--
-- Name: uq_outbox_idemp_key; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_outbox_idemp_key ON agent_bus.events_outbox USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: uq_platform_kb_name; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_platform_kb_name ON agent_bus.knowledge_bases USING btree (lower((name)::text)) WHERE (((space_kind)::text = 'platform'::text) AND (deleted_at IS NULL));


--
-- Name: uq_quota_account; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_quota_account ON agent_bus.drive_quotas USING btree (tenant_id, subject_id) WHERE (((subject_kind)::text = 'account'::text) AND (is_deleted = false));


--
-- Name: uq_quota_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_quota_tenant ON agent_bus.drive_quotas USING btree (tenant_id) WHERE (((subject_kind)::text = 'tenant'::text) AND (is_deleted = false));


--
-- Name: uq_rdp_tenant_pair_active; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_rdp_tenant_pair_active ON agent_bus.room_direct_pairs USING btree (tenant_id, account_a_id, account_b_id) WHERE (deleted_at IS NULL);


--
-- Name: uq_rdpwa_tenant_account_agent_active; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_rdpwa_tenant_account_agent_active ON agent_bus.room_direct_pairs_with_agent USING btree (tenant_id, account_id, agent_id) WHERE (is_deleted = false);


--
-- Name: uq_rp_room_agent_active; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_rp_room_agent_active ON agent_bus.room_participants USING btree (room_id, agent_id) WHERE (((kind)::text = 'agent'::text) AND (left_at IS NULL));


--
-- Name: INDEX uq_rp_room_agent_active; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON INDEX agent_bus.uq_rp_room_agent_active IS 'module: m5 / batch-2e T2E.9; 同 (room, agent) 仅 1 条 active; left_at 后可重邀';


--
-- Name: uq_rp_room_human_active; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_rp_room_human_active ON agent_bus.room_participants USING btree (room_id, account_id) WHERE (((kind)::text = 'human'::text) AND (left_at IS NULL));


--
-- Name: INDEX uq_rp_room_human_active; Type: COMMENT; Schema: agent_bus; Owner: -
--

COMMENT ON INDEX agent_bus.uq_rp_room_human_active IS 'module: m5 / batch-2e T2E.9; 同 (room, human account) 仅 1 条 active; left_at 后可重邀';


--
-- Name: uq_skills_code_platform; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_skills_code_platform ON agent_bus.skills USING btree (code) WHERE (((scope_kind)::text = 'platform'::text) AND (deleted_at IS NULL));


--
-- Name: uq_skills_code_tenant; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_skills_code_tenant ON agent_bus.skills USING btree (tenant_id, code) WHERE (((scope_kind)::text = 'tenant'::text) AND (deleted_at IS NULL));


--
-- Name: uq_tenant_kb_name; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_tenant_kb_name ON agent_bus.knowledge_bases USING btree (tenant_id, lower((name)::text)) WHERE (((space_kind)::text = 'tenant'::text) AND (deleted_at IS NULL));


--
-- Name: uq_tenant_positions_external_code; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_tenant_positions_external_code ON agent_bus.tenant_positions USING btree (tenant_id, ((metadata ->> 'external_code'::text))) WHERE ((deleted_at IS NULL) AND ((metadata ->> 'external_code'::text) IS NOT NULL));


--
-- Name: uq_tre_active_pair; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_tre_active_pair ON agent_bus.tenant_runtime_enablements USING btree (tenant_id, runtime_environment_id) WHERE (is_deleted = false);


--
-- Name: uq_tre_default; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX uq_tre_default ON agent_bus.tenant_runtime_enablements USING btree (tenant_id) WHERE ((is_default = true) AND (is_deleted = false));


--
-- Name: ux_app_category_platform_code; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX ux_app_category_platform_code ON agent_bus.app_category USING btree (code) WHERE (tenant_id IS NULL);


--
-- Name: ux_app_category_tenant_code; Type: INDEX; Schema: agent_bus; Owner: -
--

CREATE UNIQUE INDEX ux_app_category_tenant_code ON agent_bus.app_category USING btree (tenant_id, code) WHERE (tenant_id IS NOT NULL);


--
-- Name: messages_default_conversation_id_created_at_idx; Type: INDEX ATTACH; Schema: agent_bus; Owner: -
--

ALTER INDEX agent_bus.idx_messages_conv_ts ATTACH PARTITION agent_bus.messages_default_conversation_id_created_at_idx;


--
-- Name: messages_default_pkey; Type: INDEX ATTACH; Schema: agent_bus; Owner: -
--

ALTER INDEX agent_bus.messages_pkey ATTACH PARTITION agent_bus.messages_default_pkey;


--
-- Name: messages_default_room_id_created_at_idx; Type: INDEX ATTACH; Schema: agent_bus; Owner: -
--

ALTER INDEX agent_bus.idx_messages_room ATTACH PARTITION agent_bus.messages_default_room_id_created_at_idx;


--
-- Name: messages_default_stream_id_idx; Type: INDEX ATTACH; Schema: agent_bus; Owner: -
--

ALTER INDEX agent_bus.idx_messages_stream ATTACH PARTITION agent_bus.messages_default_stream_id_idx;


--
-- Name: messages_default_tenant_id_created_at_conversation_id_role__idx; Type: INDEX ATTACH; Schema: agent_bus; Owner: -
--

ALTER INDEX agent_bus.idx_messages_tenant_created_overview ATTACH PARTITION agent_bus.messages_default_tenant_id_created_at_conversation_id_role__idx;


--
-- Name: messages_default_trace_id_idx; Type: INDEX ATTACH; Schema: agent_bus; Owner: -
--

ALTER INDEX agent_bus.idx_messages_trace ATTACH PARTITION agent_bus.messages_default_trace_id_idx;


--
-- Name: tenants tenant_after_insert_seed_positions; Type: TRIGGER; Schema: agent_bus; Owner: -
--

CREATE TRIGGER tenant_after_insert_seed_positions AFTER INSERT ON agent_bus.tenants FOR EACH ROW EXECUTE FUNCTION agent_bus.trg_tenant_seed_positions();


--
-- Name: digital_employees trg_de_touch_updated_at; Type: TRIGGER; Schema: agent_bus; Owner: -
--

CREATE TRIGGER trg_de_touch_updated_at BEFORE UPDATE ON agent_bus.digital_employees FOR EACH ROW EXECUTE FUNCTION agent_bus.touch_updated_at();


--
-- Name: digital_employees trg_digital_employees_zap_agent_key_unique; Type: TRIGGER; Schema: agent_bus; Owner: -
--

CREATE TRIGGER trg_digital_employees_zap_agent_key_unique BEFORE INSERT OR UPDATE OF tenant_id, runtime_environment_id, metadata, is_deleted, deleted_at ON agent_bus.digital_employees FOR EACH ROW EXECUTE FUNCTION agent_bus.enforce_zap_digital_employee_agent_key_unique();


--
-- Name: events_outbox trg_prevent_org_outbox_done_without_delivery; Type: TRIGGER; Schema: agent_bus; Owner: -
--

CREATE TRIGGER trg_prevent_org_outbox_done_without_delivery BEFORE UPDATE OF status ON agent_bus.events_outbox FOR EACH ROW EXECUTE FUNCTION agent_bus.prevent_org_outbox_done_without_delivery();


--
-- Name: runtime_environments trg_renv_touch_updated_at; Type: TRIGGER; Schema: agent_bus; Owner: -
--

CREATE TRIGGER trg_renv_touch_updated_at BEFORE UPDATE ON agent_bus.runtime_environments FOR EACH ROW EXECUTE FUNCTION agent_bus.touch_updated_at();


--
-- Name: tenant_runtime_enablements trg_tre_touch_updated_at; Type: TRIGGER; Schema: agent_bus; Owner: -
--

CREATE TRIGGER trg_tre_touch_updated_at BEFORE UPDATE ON agent_bus.tenant_runtime_enablements FOR EACH ROW EXECUTE FUNCTION agent_bus.touch_updated_at();


--
-- Name: account_identities account_identities_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.account_identities
    ADD CONSTRAINT account_identities_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: admin_accounts admin_accounts_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.admin_accounts
    ADD CONSTRAINT admin_accounts_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: agent_app_bindings agent_app_bindings_agent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_app_bindings
    ADD CONSTRAINT agent_app_bindings_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agent_bus.digital_employees(id);


--
-- Name: agent_app_bindings agent_app_bindings_app_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_app_bindings
    ADD CONSTRAINT agent_app_bindings_app_id_fkey FOREIGN KEY (app_id) REFERENCES agent_bus.apps(id);


--
-- Name: agent_kb_bindings agent_kb_bindings_agent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_kb_bindings
    ADD CONSTRAINT agent_kb_bindings_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agent_bus.digital_employees(id) ON DELETE CASCADE;


--
-- Name: agent_kb_bindings agent_kb_bindings_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_kb_bindings
    ADD CONSTRAINT agent_kb_bindings_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: agent_kb_bindings agent_kb_bindings_kb_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_kb_bindings
    ADD CONSTRAINT agent_kb_bindings_kb_id_fkey FOREIGN KEY (kb_id) REFERENCES agent_bus.knowledge_bases(id) ON DELETE CASCADE;


--
-- Name: agent_skill_bindings agent_skill_bindings_agent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_skill_bindings
    ADD CONSTRAINT agent_skill_bindings_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agent_bus.digital_employees(id) ON DELETE CASCADE;


--
-- Name: agent_skill_bindings agent_skill_bindings_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_skill_bindings
    ADD CONSTRAINT agent_skill_bindings_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: agent_skill_bindings agent_skill_bindings_pinned_version_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_skill_bindings
    ADD CONSTRAINT agent_skill_bindings_pinned_version_id_fkey FOREIGN KEY (pinned_version_id) REFERENCES agent_bus.skill_versions(id);


--
-- Name: agent_skill_bindings agent_skill_bindings_skill_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_skill_bindings
    ADD CONSTRAINT agent_skill_bindings_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES agent_bus.skills(id);


--
-- Name: agent_skill_bindings agent_skill_bindings_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_skill_bindings
    ADD CONSTRAINT agent_skill_bindings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: agent_trigger_log agent_trigger_log_agent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_trigger_log
    ADD CONSTRAINT agent_trigger_log_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agent_bus.digital_employees(id);


--
-- Name: agent_trigger_log agent_trigger_log_room_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_trigger_log
    ADD CONSTRAINT agent_trigger_log_room_id_fkey FOREIGN KEY (room_id) REFERENCES agent_bus.rooms(id);


--
-- Name: agent_trigger_log agent_trigger_log_sender_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_trigger_log
    ADD CONSTRAINT agent_trigger_log_sender_account_id_fkey FOREIGN KEY (sender_account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: agent_trigger_log agent_trigger_log_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_trigger_log
    ADD CONSTRAINT agent_trigger_log_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: agent_versions agent_versions_digital_employee_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_versions
    ADD CONSTRAINT agent_versions_digital_employee_id_fkey FOREIGN KEY (digital_employee_id) REFERENCES agent_bus.digital_employees(id);


--
-- Name: agent_versions agent_versions_published_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.agent_versions
    ADD CONSTRAINT agent_versions_published_by_fkey FOREIGN KEY (published_by) REFERENCES agent_bus.accounts(id);


--
-- Name: app_category app_category_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_category
    ADD CONSTRAINT app_category_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: app_oauth_clients app_oauth_clients_app_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_oauth_clients
    ADD CONSTRAINT app_oauth_clients_app_id_fkey FOREIGN KEY (app_id) REFERENCES agent_bus.apps(id);


--
-- Name: app_oauth_clients app_oauth_clients_creator_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_oauth_clients
    ADD CONSTRAINT app_oauth_clients_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES agent_bus.accounts(id);


--
-- Name: app_oauth_clients app_oauth_clients_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.app_oauth_clients
    ADD CONSTRAINT app_oauth_clients_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: apps apps_category_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.apps
    ADD CONSTRAINT apps_category_id_fkey FOREIGN KEY (category_id) REFERENCES agent_bus.app_category(id);


--
-- Name: apps apps_creator_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.apps
    ADD CONSTRAINT apps_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES agent_bus.accounts(id);


--
-- Name: apps apps_oauth_client_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.apps
    ADD CONSTRAINT apps_oauth_client_id_fkey FOREIGN KEY (oauth_client_id) REFERENCES agent_bus.app_oauth_clients(id);


--
-- Name: apps apps_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.apps
    ADD CONSTRAINT apps_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: audit_summary audit_summary_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.audit_summary
    ADD CONSTRAINT audit_summary_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: auth_audit_events auth_audit_events_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.auth_audit_events
    ADD CONSTRAINT auth_audit_events_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: auth_audit_events auth_audit_events_session_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.auth_audit_events
    ADD CONSTRAINT auth_audit_events_session_id_fkey FOREIGN KEY (session_id) REFERENCES agent_bus.login_sessions(id);


--
-- Name: auth_audit_events auth_audit_events_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.auth_audit_events
    ADD CONSTRAINT auth_audit_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: auth_audit_events auth_audit_events_workspace_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.auth_audit_events
    ADD CONSTRAINT auth_audit_events_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES agent_bus.departments(id);


--
-- Name: contact_policies contact_policies_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.contact_policies
    ADD CONSTRAINT contact_policies_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: content_favorites content_favorites_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.content_favorites
    ADD CONSTRAINT content_favorites_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id) ON DELETE CASCADE;


--
-- Name: content_favorites content_favorites_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.content_favorites
    ADD CONSTRAINT content_favorites_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: content_favorites content_favorites_drive_file_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.content_favorites
    ADD CONSTRAINT content_favorites_drive_file_id_fkey FOREIGN KEY (drive_file_id) REFERENCES agent_bus.drive_files(id) ON DELETE CASCADE;


--
-- Name: content_favorites content_favorites_kb_document_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.content_favorites
    ADD CONSTRAINT content_favorites_kb_document_id_fkey FOREIGN KEY (kb_document_id) REFERENCES agent_bus.kb_documents(id) ON DELETE CASCADE;


--
-- Name: content_favorites content_favorites_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.content_favorites
    ADD CONSTRAINT content_favorites_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id) ON DELETE CASCADE;


--
-- Name: content_favorites content_favorites_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.content_favorites
    ADD CONSTRAINT content_favorites_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: conversation_account_state conversation_account_state_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversation_account_state
    ADD CONSTRAINT conversation_account_state_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: conversation_message_files conversation_message_files_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversation_message_files
    ADD CONSTRAINT conversation_message_files_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: conversation_message_files conversation_message_files_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversation_message_files
    ADD CONSTRAINT conversation_message_files_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: conversation_message_files conversation_message_files_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversation_message_files
    ADD CONSTRAINT conversation_message_files_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: conversation_message_files conversation_message_files_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversation_message_files
    ADD CONSTRAINT conversation_message_files_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: conversations conversations_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversations
    ADD CONSTRAINT conversations_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: conversations conversations_digital_employee_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversations
    ADD CONSTRAINT conversations_digital_employee_id_fkey FOREIGN KEY (digital_employee_id) REFERENCES agent_bus.digital_employees(id);


--
-- Name: conversations conversations_room_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversations
    ADD CONSTRAINT conversations_room_id_fkey FOREIGN KEY (room_id) REFERENCES agent_bus.rooms(id);


--
-- Name: conversations conversations_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.conversations
    ADD CONSTRAINT conversations_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: departments departments_parent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.departments
    ADD CONSTRAINT departments_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES agent_bus.departments(id);


--
-- Name: departments departments_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.departments
    ADD CONSTRAINT departments_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: digital_employee_visibility_overrides digital_employee_visibility_overrides_digital_employee_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employee_visibility_overrides
    ADD CONSTRAINT digital_employee_visibility_overrides_digital_employee_id_fkey FOREIGN KEY (digital_employee_id) REFERENCES agent_bus.digital_employees(id);


--
-- Name: digital_employee_visibility_overrides digital_employee_visibility_overrides_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employee_visibility_overrides
    ADD CONSTRAINT digital_employee_visibility_overrides_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: digital_employees digital_employees_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employees
    ADD CONSTRAINT digital_employees_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: digital_employees digital_employees_creator_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employees
    ADD CONSTRAINT digital_employees_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES agent_bus.accounts(id);


--
-- Name: digital_employees digital_employees_runtime_environment_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employees
    ADD CONSTRAINT digital_employees_runtime_environment_id_fkey FOREIGN KEY (runtime_environment_id) REFERENCES agent_bus.runtime_environments(id);


--
-- Name: digital_employees digital_employees_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employees
    ADD CONSTRAINT digital_employees_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: digital_employees digital_employees_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employees
    ADD CONSTRAINT digital_employees_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: digital_employees digital_employees_workspace_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.digital_employees
    ADD CONSTRAINT digital_employees_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES agent_bus.departments(id);


--
-- Name: drive_acl_entries drive_acl_entries_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_acl_entries
    ADD CONSTRAINT drive_acl_entries_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_acl_entries drive_acl_entries_granted_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_acl_entries
    ADD CONSTRAINT drive_acl_entries_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_acl_entries drive_acl_entries_link_token_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_acl_entries
    ADD CONSTRAINT drive_acl_entries_link_token_id_fkey FOREIGN KEY (link_token_id) REFERENCES agent_bus.drive_share_links(id);


--
-- Name: drive_acl_entries drive_acl_entries_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_acl_entries
    ADD CONSTRAINT drive_acl_entries_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: drive_acl_entries drive_acl_entries_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_acl_entries
    ADD CONSTRAINT drive_acl_entries_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_file_versions drive_file_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_file_versions
    ADD CONSTRAINT drive_file_versions_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_file_versions drive_file_versions_file_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_file_versions
    ADD CONSTRAINT drive_file_versions_file_id_fkey FOREIGN KEY (file_id) REFERENCES agent_bus.drive_files(id);


--
-- Name: drive_file_versions drive_file_versions_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_file_versions
    ADD CONSTRAINT drive_file_versions_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_files drive_files_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_files
    ADD CONSTRAINT drive_files_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_files drive_files_drive_folder_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_files
    ADD CONSTRAINT drive_files_drive_folder_id_fkey FOREIGN KEY (drive_folder_id) REFERENCES agent_bus.drive_folders(id);


--
-- Name: drive_files drive_files_space_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_files
    ADD CONSTRAINT drive_files_space_id_fkey FOREIGN KEY (space_id) REFERENCES agent_bus.drive_spaces(id);


--
-- Name: drive_files drive_files_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_files
    ADD CONSTRAINT drive_files_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_folders drive_folders_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_folders
    ADD CONSTRAINT drive_folders_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_folders drive_folders_parent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_folders
    ADD CONSTRAINT drive_folders_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES agent_bus.drive_folders(id);


--
-- Name: drive_folders drive_folders_space_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_folders
    ADD CONSTRAINT drive_folders_space_id_fkey FOREIGN KEY (space_id) REFERENCES agent_bus.drive_spaces(id);


--
-- Name: drive_folders drive_folders_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_folders
    ADD CONSTRAINT drive_folders_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_quotas drive_quotas_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_quotas
    ADD CONSTRAINT drive_quotas_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_quotas drive_quotas_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_quotas
    ADD CONSTRAINT drive_quotas_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: drive_quotas drive_quotas_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_quotas
    ADD CONSTRAINT drive_quotas_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_recycle_bin drive_recycle_bin_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_recycle_bin
    ADD CONSTRAINT drive_recycle_bin_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_recycle_bin drive_recycle_bin_deleted_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_recycle_bin
    ADD CONSTRAINT drive_recycle_bin_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_recycle_bin drive_recycle_bin_space_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_recycle_bin
    ADD CONSTRAINT drive_recycle_bin_space_id_fkey FOREIGN KEY (space_id) REFERENCES agent_bus.drive_spaces(id);


--
-- Name: drive_recycle_bin drive_recycle_bin_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_recycle_bin
    ADD CONSTRAINT drive_recycle_bin_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: drive_recycle_bin drive_recycle_bin_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_recycle_bin
    ADD CONSTRAINT drive_recycle_bin_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_share_links drive_share_links_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_share_links
    ADD CONSTRAINT drive_share_links_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_share_links drive_share_links_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_share_links
    ADD CONSTRAINT drive_share_links_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: drive_share_links drive_share_links_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_share_links
    ADD CONSTRAINT drive_share_links_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_spaces drive_spaces_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_spaces
    ADD CONSTRAINT drive_spaces_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_spaces drive_spaces_department_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_spaces
    ADD CONSTRAINT drive_spaces_department_id_fkey FOREIGN KEY (department_id) REFERENCES agent_bus.departments(id);


--
-- Name: drive_spaces drive_spaces_owner_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_spaces
    ADD CONSTRAINT drive_spaces_owner_account_id_fkey FOREIGN KEY (owner_account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_spaces drive_spaces_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_spaces
    ADD CONSTRAINT drive_spaces_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: drive_spaces drive_spaces_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_spaces
    ADD CONSTRAINT drive_spaces_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_storage_defaults drive_storage_defaults_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_defaults
    ADD CONSTRAINT drive_storage_defaults_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_storage_defaults drive_storage_defaults_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_defaults
    ADD CONSTRAINT drive_storage_defaults_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_storage_overrides drive_storage_overrides_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_overrides
    ADD CONSTRAINT drive_storage_overrides_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_storage_overrides drive_storage_overrides_default_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_overrides
    ADD CONSTRAINT drive_storage_overrides_default_id_fkey FOREIGN KEY (default_id) REFERENCES agent_bus.drive_storage_defaults(id);


--
-- Name: drive_storage_overrides drive_storage_overrides_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_overrides
    ADD CONSTRAINT drive_storage_overrides_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: drive_storage_overrides drive_storage_overrides_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_storage_overrides
    ADD CONSTRAINT drive_storage_overrides_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_upload_tickets drive_upload_tickets_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_upload_tickets
    ADD CONSTRAINT drive_upload_tickets_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: drive_upload_tickets drive_upload_tickets_folder_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_upload_tickets
    ADD CONSTRAINT drive_upload_tickets_folder_id_fkey FOREIGN KEY (folder_id) REFERENCES agent_bus.drive_folders(id);


--
-- Name: drive_upload_tickets drive_upload_tickets_space_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_upload_tickets
    ADD CONSTRAINT drive_upload_tickets_space_id_fkey FOREIGN KEY (space_id) REFERENCES agent_bus.drive_spaces(id);


--
-- Name: drive_upload_tickets drive_upload_tickets_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_upload_tickets
    ADD CONSTRAINT drive_upload_tickets_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: drive_worker_job_triggers drive_worker_job_triggers_requested_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.drive_worker_job_triggers
    ADD CONSTRAINT drive_worker_job_triggers_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES agent_bus.accounts(id);


--
-- Name: chat_media_refs fk_cmr_conversation; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_media_refs
    ADD CONSTRAINT fk_cmr_conversation FOREIGN KEY (conversation_id) REFERENCES agent_bus.conversations(id) ON DELETE CASCADE;


--
-- Name: chat_media_refs fk_cmr_room; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_media_refs
    ADD CONSTRAINT fk_cmr_room FOREIGN KEY (room_id) REFERENCES agent_bus.rooms(id) ON DELETE CASCADE;


--
-- Name: chat_media_refs fk_cmr_sender; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_media_refs
    ADD CONSTRAINT fk_cmr_sender FOREIGN KEY (sender_account_id) REFERENCES agent_bus.accounts(id) ON DELETE CASCADE;


--
-- Name: chat_message_tasks fk_cmt_account; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_message_tasks
    ADD CONSTRAINT fk_cmt_account FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id) ON DELETE CASCADE;


--
-- Name: chat_message_tasks fk_cmt_conv; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_message_tasks
    ADD CONSTRAINT fk_cmt_conv FOREIGN KEY (conversation_id) REFERENCES agent_bus.conversations(id) ON DELETE CASCADE;


--
-- Name: chat_message_tasks fk_cmt_tenant; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.chat_message_tasks
    ADD CONSTRAINT fk_cmt_tenant FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id) ON DELETE CASCADE;


--
-- Name: skills fk_skills_category; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skills
    ADD CONSTRAINT fk_skills_category FOREIGN KEY (category_id) REFERENCES agent_bus.skill_categories(id);


--
-- Name: skills fk_skills_latest_version; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skills
    ADD CONSTRAINT fk_skills_latest_version FOREIGN KEY (latest_version_id) REFERENCES agent_bus.skill_versions(id);


--
-- Name: im_connection_client_metadata im_connection_client_metadata_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_client_metadata
    ADD CONSTRAINT im_connection_client_metadata_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id) ON DELETE CASCADE;


--
-- Name: im_connection_client_metadata im_connection_client_metadata_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_client_metadata
    ADD CONSTRAINT im_connection_client_metadata_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id) ON DELETE CASCADE;


--
-- Name: im_connection_events im_connection_events_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_events
    ADD CONSTRAINT im_connection_events_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id) ON DELETE SET NULL;


--
-- Name: im_connection_events im_connection_events_state_uuid_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_events
    ADD CONSTRAINT im_connection_events_state_uuid_fkey FOREIGN KEY (state_uuid) REFERENCES agent_bus.im_connection_states(uuid) ON DELETE CASCADE;


--
-- Name: im_connection_events im_connection_events_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_events
    ADD CONSTRAINT im_connection_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id) ON DELETE CASCADE;


--
-- Name: im_connection_states im_connection_states_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_states
    ADD CONSTRAINT im_connection_states_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id) ON DELETE SET NULL;


--
-- Name: im_connection_states im_connection_states_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.im_connection_states
    ADD CONSTRAINT im_connection_states_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id) ON DELETE CASCADE;


--
-- Name: kb_documents kb_documents_deleted_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_documents
    ADD CONSTRAINT kb_documents_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES agent_bus.accounts(id);


--
-- Name: kb_documents kb_documents_folder_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_documents
    ADD CONSTRAINT kb_documents_folder_id_fkey FOREIGN KEY (folder_id) REFERENCES agent_bus.kb_folders(id);


--
-- Name: kb_documents kb_documents_kb_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_documents
    ADD CONSTRAINT kb_documents_kb_id_fkey FOREIGN KEY (kb_id) REFERENCES agent_bus.knowledge_bases(id);


--
-- Name: kb_folders kb_folders_kb_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_folders
    ADD CONSTRAINT kb_folders_kb_id_fkey FOREIGN KEY (kb_id) REFERENCES agent_bus.knowledge_bases(id);


--
-- Name: kb_folders kb_folders_parent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.kb_folders
    ADD CONSTRAINT kb_folders_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES agent_bus.kb_folders(id);


--
-- Name: knowledge_bases knowledge_bases_creator_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.knowledge_bases
    ADD CONSTRAINT knowledge_bases_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES agent_bus.accounts(id);


--
-- Name: knowledge_bases knowledge_bases_deleted_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.knowledge_bases
    ADD CONSTRAINT knowledge_bases_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES agent_bus.accounts(id);


--
-- Name: knowledge_bases knowledge_bases_owner_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.knowledge_bases
    ADD CONSTRAINT knowledge_bases_owner_account_id_fkey FOREIGN KEY (owner_account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: knowledge_bases knowledge_bases_provider_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.knowledge_bases
    ADD CONSTRAINT knowledge_bases_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES agent_bus.kb_provider_config(id);


--
-- Name: knowledge_bases knowledge_bases_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.knowledge_bases
    ADD CONSTRAINT knowledge_bases_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: knowledge_bases knowledge_bases_workspace_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.knowledge_bases
    ADD CONSTRAINT knowledge_bases_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES agent_bus.departments(id);


--
-- Name: login_sessions login_sessions_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.login_sessions
    ADD CONSTRAINT login_sessions_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: login_sessions login_sessions_act_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.login_sessions
    ADD CONSTRAINT login_sessions_act_tenant_id_fkey FOREIGN KEY (act_tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: login_sessions login_sessions_act_workspace_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.login_sessions
    ADD CONSTRAINT login_sessions_act_workspace_id_fkey FOREIGN KEY (act_workspace_id) REFERENCES agent_bus.departments(id);


--
-- Name: menu_permissions menu_permissions_menu_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.menu_permissions
    ADD CONSTRAINT menu_permissions_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES agent_bus.menus(id) ON DELETE CASCADE;


--
-- Name: menu_permissions menu_permissions_permission_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.menu_permissions
    ADD CONSTRAINT menu_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES agent_bus.permissions(id) ON DELETE CASCADE;


--
-- Name: menus menus_parent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.menus
    ADD CONSTRAINT menus_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES agent_bus.menus(id);


--
-- Name: message_streams message_streams_conversation_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.message_streams
    ADD CONSTRAINT message_streams_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES agent_bus.conversations(id);


--
-- Name: role_assignments role_assignments_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_assignments
    ADD CONSTRAINT role_assignments_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: role_assignments role_assignments_granted_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_assignments
    ADD CONSTRAINT role_assignments_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES agent_bus.accounts(id);


--
-- Name: role_assignments role_assignments_role_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_assignments
    ADD CONSTRAINT role_assignments_role_id_fkey FOREIGN KEY (role_id) REFERENCES agent_bus.roles(id);


--
-- Name: role_assignments role_assignments_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_assignments
    ADD CONSTRAINT role_assignments_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: role_assignments role_assignments_workspace_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_assignments
    ADD CONSTRAINT role_assignments_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES agent_bus.departments(id);


--
-- Name: role_permissions role_permissions_permission_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_permissions
    ADD CONSTRAINT role_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES agent_bus.permissions(id) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.role_permissions
    ADD CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES agent_bus.roles(id) ON DELETE CASCADE;


--
-- Name: roles roles_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.roles
    ADD CONSTRAINT roles_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: room_direct_pairs room_direct_pairs_account_a_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs
    ADD CONSTRAINT room_direct_pairs_account_a_id_fkey FOREIGN KEY (account_a_id) REFERENCES agent_bus.accounts(id);


--
-- Name: room_direct_pairs room_direct_pairs_account_b_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs
    ADD CONSTRAINT room_direct_pairs_account_b_id_fkey FOREIGN KEY (account_b_id) REFERENCES agent_bus.accounts(id);


--
-- Name: room_direct_pairs room_direct_pairs_room_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs
    ADD CONSTRAINT room_direct_pairs_room_id_fkey FOREIGN KEY (room_id) REFERENCES agent_bus.rooms(id);


--
-- Name: room_direct_pairs room_direct_pairs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs
    ADD CONSTRAINT room_direct_pairs_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_agent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agent_bus.digital_employees(id);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_room_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_room_id_fkey FOREIGN KEY (room_id) REFERENCES agent_bus.rooms(id);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: room_direct_pairs_with_agent room_direct_pairs_with_agent_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_direct_pairs_with_agent
    ADD CONSTRAINT room_direct_pairs_with_agent_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: room_participants room_participants_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_participants
    ADD CONSTRAINT room_participants_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: room_participants room_participants_agent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_participants
    ADD CONSTRAINT room_participants_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agent_bus.digital_employees(id);


--
-- Name: room_participants room_participants_room_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.room_participants
    ADD CONSTRAINT room_participants_room_id_fkey FOREIGN KEY (room_id) REFERENCES agent_bus.rooms(id) ON DELETE CASCADE;


--
-- Name: rooms rooms_creator_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.rooms
    ADD CONSTRAINT rooms_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES agent_bus.accounts(id);


--
-- Name: rooms rooms_manager_agent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.rooms
    ADD CONSTRAINT rooms_manager_agent_id_fkey FOREIGN KEY (manager_agent_id) REFERENCES agent_bus.digital_employees(id);


--
-- Name: rooms rooms_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.rooms
    ADD CONSTRAINT rooms_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: runtime_environments runtime_environments_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.runtime_environments
    ADD CONSTRAINT runtime_environments_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: runtime_environments runtime_environments_egress_auditor_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.runtime_environments
    ADD CONSTRAINT runtime_environments_egress_auditor_id_fkey FOREIGN KEY (egress_auditor_id) REFERENCES agent_bus.accounts(id);


--
-- Name: runtime_environments runtime_environments_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.runtime_environments
    ADD CONSTRAINT runtime_environments_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: runtime_environments runtime_environments_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.runtime_environments
    ADD CONSTRAINT runtime_environments_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: skill_categories skill_categories_deleted_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skill_categories
    ADD CONSTRAINT skill_categories_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES agent_bus.accounts(id);


--
-- Name: skill_versions skill_versions_published_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skill_versions
    ADD CONSTRAINT skill_versions_published_by_fkey FOREIGN KEY (published_by) REFERENCES agent_bus.accounts(id);


--
-- Name: skill_versions skill_versions_skill_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skill_versions
    ADD CONSTRAINT skill_versions_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES agent_bus.skills(id) ON DELETE CASCADE;


--
-- Name: skills skills_created_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skills
    ADD CONSTRAINT skills_created_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: skills skills_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skills
    ADD CONSTRAINT skills_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: skills skills_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.skills
    ADD CONSTRAINT skills_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: tenant_agent_positions tenant_agent_positions_agent_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_agent_positions
    ADD CONSTRAINT tenant_agent_positions_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agent_bus.digital_employees(id) ON DELETE CASCADE;


--
-- Name: tenant_agent_positions tenant_agent_positions_position_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_agent_positions
    ADD CONSTRAINT tenant_agent_positions_position_id_fkey FOREIGN KEY (position_id) REFERENCES agent_bus.tenant_positions(id);


--
-- Name: tenant_member_positions tenant_member_positions_assigned_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_member_positions
    ADD CONSTRAINT tenant_member_positions_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES agent_bus.accounts(id);


--
-- Name: tenant_member_positions tenant_member_positions_membership_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_member_positions
    ADD CONSTRAINT tenant_member_positions_membership_id_fkey FOREIGN KEY (membership_id) REFERENCES agent_bus.tenant_memberships(id) ON DELETE CASCADE;


--
-- Name: tenant_member_positions tenant_member_positions_position_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_member_positions
    ADD CONSTRAINT tenant_member_positions_position_id_fkey FOREIGN KEY (position_id) REFERENCES agent_bus.tenant_positions(id);


--
-- Name: tenant_memberships tenant_memberships_account_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_memberships
    ADD CONSTRAINT tenant_memberships_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);


--
-- Name: tenant_memberships tenant_memberships_department_tenant_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_memberships
    ADD CONSTRAINT tenant_memberships_department_tenant_fkey FOREIGN KEY (department_id, tenant_id) REFERENCES agent_bus.departments(id, tenant_id);


--
-- Name: tenant_memberships tenant_memberships_invited_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_memberships
    ADD CONSTRAINT tenant_memberships_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES agent_bus.accounts(id);


--
-- Name: tenant_memberships tenant_memberships_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_memberships
    ADD CONSTRAINT tenant_memberships_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: tenant_positions tenant_positions_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_positions
    ADD CONSTRAINT tenant_positions_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: tenant_runtime_enablements tenant_runtime_enablements_enabled_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_runtime_enablements
    ADD CONSTRAINT tenant_runtime_enablements_enabled_by_fkey FOREIGN KEY (created_by) REFERENCES agent_bus.accounts(id);


--
-- Name: tenant_runtime_enablements tenant_runtime_enablements_runtime_environment_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_runtime_enablements
    ADD CONSTRAINT tenant_runtime_enablements_runtime_environment_id_fkey FOREIGN KEY (runtime_environment_id) REFERENCES agent_bus.runtime_environments(id);


--
-- Name: tenant_runtime_enablements tenant_runtime_enablements_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_runtime_enablements
    ADD CONSTRAINT tenant_runtime_enablements_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: tenant_runtime_enablements tenant_runtime_enablements_updated_by_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_runtime_enablements
    ADD CONSTRAINT tenant_runtime_enablements_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES agent_bus.accounts(id);


--
-- Name: tenant_webhook_configs tenant_webhook_configs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_webhook_configs
    ADD CONSTRAINT tenant_webhook_configs_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);


--
-- Name: tenant_webhook_deliveries tenant_webhook_deliveries_webhook_config_id_fkey; Type: FK CONSTRAINT; Schema: agent_bus; Owner: -
--

ALTER TABLE ONLY agent_bus.tenant_webhook_deliveries
    ADD CONSTRAINT tenant_webhook_deliveries_webhook_config_id_fkey FOREIGN KEY (webhook_config_id) REFERENCES agent_bus.tenant_webhook_configs(id);


--
-- PostgreSQL database dump complete
--
