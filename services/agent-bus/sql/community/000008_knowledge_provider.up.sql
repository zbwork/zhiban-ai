-- Community uses the existing PostgreSQL text chunk provider.
INSERT INTO agent_bus.kb_provider_config(provider_kind,name,is_default,status)
SELECT 'stub','Community PostgreSQL',true,'active'
WHERE NOT EXISTS (SELECT 1 FROM agent_bus.kb_provider_config WHERE is_default);
