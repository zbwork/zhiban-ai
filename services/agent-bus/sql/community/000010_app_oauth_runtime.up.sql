-- Restore F04 tables required by community application composition.
SET LOCAL search_path=agent_bus,public;

CREATE TABLE agent_bus.tenant_app_settings (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    app_id bigint NOT NULL,
    is_universal boolean DEFAULT false NOT NULL,
    is_enabled boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE agent_bus.tenant_app_settings ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.tenant_app_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY agent_bus.tenant_app_settings
    ADD CONSTRAINT tenant_app_settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.tenant_app_settings
    ADD CONSTRAINT tenant_app_settings_tenant_id_app_id_key UNIQUE (tenant_id, app_id);

ALTER TABLE ONLY agent_bus.tenant_app_settings
    ADD CONSTRAINT tenant_app_settings_app_id_fkey FOREIGN KEY (app_id) REFERENCES agent_bus.apps(id);

ALTER TABLE ONLY agent_bus.tenant_app_settings
    ADD CONSTRAINT tenant_app_settings_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);

CREATE INDEX idx_tenant_app_settings_universal ON agent_bus.tenant_app_settings USING btree (tenant_id) WHERE ((is_universal = true) AND (is_enabled = true));

CREATE TABLE agent_bus.app_oauth_refresh_tokens (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    token_hash character varying(256) NOT NULL,
    oauth_client_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    scopes character varying(64)[] DEFAULT '{}'::character varying[] NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    revoke_reason character varying(32)
);

ALTER TABLE agent_bus.app_oauth_refresh_tokens ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.app_oauth_refresh_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY agent_bus.app_oauth_refresh_tokens
    ADD CONSTRAINT app_oauth_refresh_tokens_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.app_oauth_refresh_tokens
    ADD CONSTRAINT app_oauth_refresh_tokens_token_hash_key UNIQUE (token_hash);

ALTER TABLE ONLY agent_bus.app_oauth_refresh_tokens
    ADD CONSTRAINT app_oauth_refresh_tokens_uuid_key UNIQUE (uuid);

ALTER TABLE ONLY agent_bus.app_oauth_refresh_tokens
    ADD CONSTRAINT app_oauth_refresh_tokens_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.app_oauth_refresh_tokens
    ADD CONSTRAINT app_oauth_refresh_tokens_oauth_client_id_fkey FOREIGN KEY (oauth_client_id) REFERENCES agent_bus.app_oauth_clients(id);

ALTER TABLE ONLY agent_bus.app_oauth_refresh_tokens
    ADD CONSTRAINT app_oauth_refresh_tokens_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);

CREATE INDEX idx_app_oauth_refresh_tokens_account ON agent_bus.app_oauth_refresh_tokens USING btree (account_id, issued_at DESC) WHERE (revoked_at IS NULL);

CREATE INDEX idx_app_oauth_refresh_tokens_client ON agent_bus.app_oauth_refresh_tokens USING btree (oauth_client_id) WHERE (revoked_at IS NULL);

CREATE INDEX idx_app_oauth_refresh_tokens_expires ON agent_bus.app_oauth_refresh_tokens USING btree (expires_at) WHERE (revoked_at IS NULL);

CREATE TABLE agent_bus.oauth_signing_keys (
    id bigint NOT NULL,
    kid character varying(64) NOT NULL,
    algorithm character varying(16) DEFAULT 'RS256'::character varying NOT NULL,
    public_jwk jsonb NOT NULL,
    private_pem_enc text NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    activated_at timestamp with time zone DEFAULT now() NOT NULL,
    retiring_at timestamp with time zone,
    retired_at timestamp with time zone,
    CONSTRAINT oauth_signing_keys_algorithm_check CHECK (((algorithm)::text = ANY (ARRAY[('RS256'::character varying)::text, ('ES256'::character varying)::text, ('EdDSA'::character varying)::text]))),
    CONSTRAINT oauth_signing_keys_status_check CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('retiring'::character varying)::text, ('retired'::character varying)::text])))
);

ALTER TABLE agent_bus.oauth_signing_keys ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.oauth_signing_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY agent_bus.oauth_signing_keys
    ADD CONSTRAINT oauth_signing_keys_kid_key UNIQUE (kid);

ALTER TABLE ONLY agent_bus.oauth_signing_keys
    ADD CONSTRAINT oauth_signing_keys_pkey PRIMARY KEY (id);

CREATE INDEX idx_oauth_signing_keys_status ON agent_bus.oauth_signing_keys USING btree (status, activated_at DESC);

CREATE UNIQUE INDEX uq_oauth_signing_keys_active_singleton ON agent_bus.oauth_signing_keys USING btree (status) WHERE ((status)::text = 'active'::text);
COMMENT ON TABLE agent_bus.tenant_app_settings IS 'F04: 租户对应用的开关 / 通用标记 / 排序';
COMMENT ON COLUMN agent_bus.tenant_app_settings.id IS '主键 ID';
COMMENT ON COLUMN agent_bus.tenant_app_settings.tenant_id IS '租户 ID';
COMMENT ON COLUMN agent_bus.tenant_app_settings.app_id IS '应用 ID';
COMMENT ON COLUMN agent_bus.tenant_app_settings.is_universal IS 'true=出现在所有 conversation composer (agent_chat / dm / group 通吃)';
COMMENT ON COLUMN agent_bus.tenant_app_settings.is_enabled IS 'false=该租户停用此应用 (即使 is_universal=true 也不显示)';
COMMENT ON COLUMN agent_bus.tenant_app_settings.sort_order IS '通用应用在 composer 的展示顺序';
COMMENT ON COLUMN agent_bus.tenant_app_settings.created_at IS '创建时间';
COMMENT ON COLUMN agent_bus.tenant_app_settings.updated_at IS '更新时间';
COMMENT ON TABLE agent_bus.app_oauth_refresh_tokens IS 'F04: 应用 OAuth2 refresh token (30d TTL, rotation 时旧的 revoked)';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.id IS '主键 ID';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.uuid IS '对外业务唯一标识';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.token_hash IS 'sha256(明文 rt_<32-base62>) hex';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.oauth_client_id IS '所属 client';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.tenant_id IS '租户 ID (= client.tenant_id)';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.account_id IS '用户 ID (= 当初 authorization_code 的 account_id)';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.scopes IS '继承自前次 grant 的 scope';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.issued_at IS '颁发时间';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.expires_at IS '过期时间 (硬保证)';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.last_used_at IS '最近一次用此 refresh_token 换 access_token 的时间';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.revoked_at IS 'rotate / 撤销 时间';
COMMENT ON COLUMN agent_bus.app_oauth_refresh_tokens.revoke_reason IS 'rotate / manual / client_revoked';
COMMENT ON TABLE agent_bus.oauth_signing_keys IS 'F04: JWT 签名密钥 (active→retiring→retired 三态; 支持 zero-downtime 轮转)';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.id IS '主键 ID';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.kid IS 'JWKS kid; "k-" + short uuid';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.algorithm IS 'JWT 签名算法; v0.1 仅 RS256';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.public_jwk IS '公钥 JWK (kty/use/alg/kid + n/e); 直接 serve 给 /.well-known/jwks.json';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.private_pem_enc IS 'PKCS#8 PEM 私钥, AES-256-GCM 加密 (pkg/secretbox)';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.status IS 'active=签新; retiring=只验不签; retired=已 JWKS 移除';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.activated_at IS '激活时间';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.retiring_at IS '进入 retiring 时间';
COMMENT ON COLUMN agent_bus.oauth_signing_keys.retired_at IS '进入 retired 时间 (从 JWKS 移除)';

CREATE TABLE agent_bus.app_oauth_codes (
    id bigint NOT NULL,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    code_hash character varying(256) NOT NULL,
    oauth_client_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    conversation_id bigint,
    redirect_uri character varying(512) NOT NULL,
    scopes character varying(64)[] DEFAULT '{}'::character varying[] NOT NULL,
    state text,
    nonce text,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone
);

ALTER TABLE agent_bus.app_oauth_codes ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME agent_bus.app_oauth_codes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY agent_bus.app_oauth_codes
    ADD CONSTRAINT app_oauth_codes_code_hash_key UNIQUE (code_hash);

ALTER TABLE ONLY agent_bus.app_oauth_codes
    ADD CONSTRAINT app_oauth_codes_pkey PRIMARY KEY (id);

ALTER TABLE ONLY agent_bus.app_oauth_codes
    ADD CONSTRAINT app_oauth_codes_uuid_key UNIQUE (uuid);

ALTER TABLE ONLY agent_bus.app_oauth_codes
    ADD CONSTRAINT app_oauth_codes_account_id_fkey FOREIGN KEY (account_id) REFERENCES agent_bus.accounts(id);

ALTER TABLE ONLY agent_bus.app_oauth_codes
    ADD CONSTRAINT app_oauth_codes_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES agent_bus.conversations(id);

ALTER TABLE ONLY agent_bus.app_oauth_codes
    ADD CONSTRAINT app_oauth_codes_oauth_client_id_fkey FOREIGN KEY (oauth_client_id) REFERENCES agent_bus.app_oauth_clients(id);

ALTER TABLE ONLY agent_bus.app_oauth_codes
    ADD CONSTRAINT app_oauth_codes_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES agent_bus.tenants(id);

COMMENT ON TABLE agent_bus.app_oauth_codes IS 'F04: 一次性 authorization_code (TTL 60s; consumed_at 防一码多换)';

COMMENT ON COLUMN agent_bus.app_oauth_codes.id IS '主键 ID';

COMMENT ON COLUMN agent_bus.app_oauth_codes.uuid IS '对外业务唯一标识';

COMMENT ON COLUMN agent_bus.app_oauth_codes.code_hash IS 'sha256(明文 code) hex';

COMMENT ON COLUMN agent_bus.app_oauth_codes.oauth_client_id IS '颁发给哪个 app_oauth_clients';

COMMENT ON COLUMN agent_bus.app_oauth_codes.tenant_id IS '租户 ID';

COMMENT ON COLUMN agent_bus.app_oauth_codes.account_id IS '用户 ID (= 当前 zhiban-app 登录人)';

COMMENT ON COLUMN agent_bus.app_oauth_codes.conversation_id IS '启动时所在会话; NULL = conversation 外启动 (v0.2)';

COMMENT ON COLUMN agent_bus.app_oauth_codes.redirect_uri IS '颁发时锁定的 redirect_uri (exact match)';

COMMENT ON COLUMN agent_bus.app_oauth_codes.scopes IS '本次 code 承载的 scope';

COMMENT ON COLUMN agent_bus.app_oauth_codes.state IS '客户端请求关联值 (透传); 当前无应用侧验证者';

COMMENT ON COLUMN agent_bus.app_oauth_codes.nonce IS 'OIDC 兼容字段 (透传); 当前无应用侧验证者';

COMMENT ON COLUMN agent_bus.app_oauth_codes.issued_at IS '颁发时间';

COMMENT ON COLUMN agent_bus.app_oauth_codes.expires_at IS '过期时间 (硬保证)';

COMMENT ON COLUMN agent_bus.app_oauth_codes.consumed_at IS '消费时间; NOT NULL 后续拒绝';

CREATE INDEX idx_app_oauth_codes_account ON agent_bus.app_oauth_codes USING btree (account_id, issued_at DESC);

CREATE INDEX idx_app_oauth_codes_expires ON agent_bus.app_oauth_codes USING btree (expires_at) WHERE (consumed_at IS NULL);
