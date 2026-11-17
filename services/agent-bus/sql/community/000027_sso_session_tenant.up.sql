-- A tenant-configured identity provider authenticates only that tenant.
-- NULL preserves existing password and pre-migration sessions.
ALTER TABLE agent_bus.login_sessions ADD COLUMN IF NOT EXISTS auth_tenant_id bigint REFERENCES agent_bus.tenants(id);
COMMENT ON COLUMN agent_bus.login_sessions.auth_tenant_id IS 'Tenant authentication boundary for OIDC sessions; refresh and scope switching must preserve it';
ALTER TABLE agent_bus.login_sessions ADD CONSTRAINT login_sessions_auth_tenant_positive CHECK (auth_tenant_id IS NULL OR auth_tenant_id > 0);
