-- Community H5 application management uses the same permission contract as F04.
SET LOCAL search_path=agent_bus,public;
INSERT INTO permissions(code,name,kind,scope_kind,resource,action,is_system)
SELECT 'tenant.app.' || action,'tenant.app.' || action,'api','tenant','app',action,true
FROM unnest(ARRAY['read','create','update','delete','rotate_secret','universal_toggle','enable']) AS action
ON CONFLICT (code) DO NOTHING;
INSERT INTO role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM roles r CROSS JOIN permissions p
WHERE r.code='tenant.admin' AND r.scope_kind='tenant' AND p.code LIKE 'tenant.app.%'
ON CONFLICT DO NOTHING;
