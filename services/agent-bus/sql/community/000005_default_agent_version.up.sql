-- Default community employees must satisfy the same published-version gate as
-- manually published employees; preserve existing versions and private runtimes.
INSERT INTO agent_bus.agent_versions
 (digital_employee_id,version,snapshot,status,published_by,published_at,notes)
SELECT d.id,1,to_jsonb(d),'published',d.creator_id,now(),'Community bootstrap version repair'
FROM agent_bus.digital_employees d
JOIN agent_bus.runtime_environments r ON r.id=d.runtime_environment_id
WHERE d.status='published' AND COALESCE(d.current_version,0)=0
 AND r.framework='generic' AND r.hosting_kind='embedded'
 AND NOT EXISTS (SELECT 1 FROM agent_bus.agent_versions v WHERE v.digital_employee_id=d.id)
ON CONFLICT DO NOTHING;

UPDATE agent_bus.digital_employees d SET current_version=1,updated_at=now()
FROM agent_bus.runtime_environments r
WHERE r.id=d.runtime_environment_id AND r.framework='generic' AND r.hosting_kind='embedded'
 AND d.status='published' AND COALESCE(d.current_version,0)=0
 AND EXISTS (SELECT 1 FROM agent_bus.agent_versions v WHERE v.digital_employee_id=d.id AND v.version=1 AND v.status='published');
