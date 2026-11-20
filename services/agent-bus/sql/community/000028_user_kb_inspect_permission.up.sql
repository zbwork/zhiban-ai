-- Restore the Admin-only personal knowledge-base metadata inspection permission.
SET LOCAL search_path=agent_bus,public;
INSERT INTO permissions(code,name,kind,scope_kind,resource,action,is_system)
VALUES ('tenant.kb.read_user_private','用户知识库审计查询','api','tenant','kb','read_user_private',true)
ON CONFLICT(code) DO NOTHING;
INSERT INTO role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM roles r JOIN permissions p ON p.code='tenant.kb.read_user_private'
WHERE r.scope_kind='tenant' AND r.code='tenant.admin' AND r.is_system=true
ON CONFLICT DO NOTHING;
