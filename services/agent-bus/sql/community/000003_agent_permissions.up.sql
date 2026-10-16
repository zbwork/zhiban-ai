SET LOCAL search_path=agent_bus,public;
INSERT INTO permissions(code,name,kind,scope_kind,resource,action,is_system)
SELECT 'tenant.agent.' || action, 'tenant.agent.' || action,'api','tenant','agent',action,true
FROM unnest(ARRAY['read','create','update','delete','publish']) AS action;
INSERT INTO role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM roles r CROSS JOIN permissions p
WHERE r.code='tenant.admin' AND r.scope_kind='tenant' AND p.code LIKE 'tenant.agent.%'
ON CONFLICT DO NOTHING;
