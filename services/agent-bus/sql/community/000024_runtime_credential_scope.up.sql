-- Reuse original 000050 and 000053, matching the exported credential repository.
-- ADR-0030 Runtime Access Token context.
-- Backward compatible: existing credentials default to tenant scope and existing
-- session tokens keep account/runtime bindings NULL.

ALTER TABLE agent_bus.agent_sdk_credentials
    ADD COLUMN IF NOT EXISTS scope VARCHAR(16) NOT NULL DEFAULT 'tenant';

ALTER TABLE agent_bus.agent_sdk_credentials
    ALTER COLUMN tenant_id DROP NOT NULL;

ALTER TABLE agent_bus.agent_sdk_credentials
    ADD CONSTRAINT chk_agent_sdk_credentials_scope
    CHECK (
        (scope = 'tenant' AND tenant_id IS NOT NULL)
        OR
        (scope = 'platform' AND tenant_id IS NULL AND runtime_environment_id IS NOT NULL)
    );

COMMENT ON COLUMN agent_bus.agent_sdk_credentials.scope IS
    'tenant=租户自建 Runtime 换发凭证; platform=平台托管多租户 Runtime 换发凭证, 只能换短期 st_';

ALTER TABLE agent_bus.session_tokens
    ADD COLUMN IF NOT EXISTS account_id BIGINT REFERENCES agent_bus.accounts(id),
    ADD COLUMN IF NOT EXISTS runtime_environment_id BIGINT REFERENCES agent_bus.runtime_environments(id);

COMMENT ON COLUMN agent_bus.session_tokens.account_id IS
    'Runtime Access Token 绑定账号; NULL=实例级/未绑定用户';
COMMENT ON COLUMN agent_bus.session_tokens.runtime_environment_id IS
    'Runtime Access Token 绑定 runtime_environment_id; NULL=旧 Agent SDK session token';

CREATE INDEX IF NOT EXISTS idx_session_tokens_account
    ON agent_bus.session_tokens(account_id)
    WHERE account_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_session_tokens_runtime_environment
    ON agent_bus.session_tokens(runtime_environment_id)
    WHERE runtime_environment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_agent_sdk_credentials_scope
    ON agent_bus.agent_sdk_credentials(scope);

-- ADR-0030 hardening: constrain platform-scoped Runtime credentials by tenant.
-- A platform credential can either target all tenants that have enabled the
-- bound runtime, or an explicit allowlist. Runtime enablement is still checked
-- during /oauth/token runtime_access exchange.

CREATE TABLE IF NOT EXISTS agent_bus.agent_sdk_credential_tenant_grants (
    id BIGSERIAL PRIMARY KEY,
    credential_id BIGINT NOT NULL REFERENCES agent_bus.agent_sdk_credentials(id) ON DELETE CASCADE,
    tenant_id BIGINT REFERENCES agent_bus.tenants(id) ON DELETE CASCADE,
    grant_mode VARCHAR(16) NOT NULL DEFAULT 'allowlist',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (grant_mode IN ('all_enabled', 'allowlist')),
    CHECK (
        (grant_mode = 'all_enabled' AND tenant_id IS NULL)
        OR
        (grant_mode = 'allowlist' AND tenant_id IS NOT NULL)
    )
);

COMMENT ON TABLE agent_bus.agent_sdk_credential_tenant_grants IS
    'ADR-0030: platform-scoped Runtime credential tenant blast-radius guard';
COMMENT ON COLUMN agent_bus.agent_sdk_credential_tenant_grants.credential_id IS
    'agent_sdk_credentials.id; must be scope=platform by service invariant';
COMMENT ON COLUMN agent_bus.agent_sdk_credential_tenant_grants.tenant_id IS
    'allowlist target tenant; NULL only when grant_mode=all_enabled';
COMMENT ON COLUMN agent_bus.agent_sdk_credential_tenant_grants.grant_mode IS
    'all_enabled=all tenants that enabled this runtime; allowlist=explicit tenant_id rows';

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_sdk_credential_tenant_grants_allowlist
    ON agent_bus.agent_sdk_credential_tenant_grants(credential_id, tenant_id)
    WHERE tenant_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_sdk_credential_tenant_grants_all_enabled
    ON agent_bus.agent_sdk_credential_tenant_grants(credential_id)
    WHERE tenant_id IS NULL AND grant_mode = 'all_enabled';

CREATE INDEX IF NOT EXISTS idx_agent_sdk_credential_tenant_grants_tenant
    ON agent_bus.agent_sdk_credential_tenant_grants(tenant_id)
    WHERE tenant_id IS NOT NULL;

INSERT INTO agent_bus.agent_sdk_credential_tenant_grants (credential_id, tenant_id, grant_mode)
SELECT c.id, NULL, 'all_enabled'
  FROM agent_bus.agent_sdk_credentials c
 WHERE c.scope = 'platform'
   AND c.tenant_id IS NULL
   AND c.status = 'active'
   AND NOT EXISTS (
        SELECT 1 FROM agent_bus.agent_sdk_credential_tenant_grants g
         WHERE g.credential_id = c.id
   );
