-- Original tenant KB recall-test permission; do not grant to ordinary members.
SET LOCAL search_path=agent_bus,public;
INSERT INTO permissions(code,name,kind,scope_kind,resource,action,is_system)
VALUES ('tenant.kb.recall','知识库召回测试','api','tenant','kb','recall',true)
ON CONFLICT(code) DO NOTHING;
INSERT INTO role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM roles r JOIN permissions p ON p.code='tenant.kb.recall'
WHERE r.scope_kind='tenant' AND r.code='tenant.admin' AND r.is_system=true
ON CONFLICT DO NOTHING;
