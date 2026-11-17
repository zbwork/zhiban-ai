-- Existing permission for original employee application binding endpoints.
SET LOCAL search_path=agent_bus,public;
INSERT INTO permissions(code,name,kind,scope_kind,resource,action,is_system)
VALUES ('tenant.app.agent_bind','数字员工应用装配','api','tenant','app','agent_bind',true)
ON CONFLICT(code) DO NOTHING;
INSERT INTO role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM roles r JOIN permissions p ON p.code='tenant.app.agent_bind'
WHERE r.scope_kind='tenant' AND r.code='tenant.admin' AND r.is_system=true
ON CONFLICT DO NOTHING;
