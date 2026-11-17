-- Organization local employees run on each authorized member's own desktop.
-- Preserve existing personal-private and platform-template branches and every engine constraint.
SET LOCAL search_path=agent_bus,public;
ALTER TABLE agent_bus.digital_employees DROP CONSTRAINT digital_employees_local_scope_check;
ALTER TABLE agent_bus.digital_employees ADD CONSTRAINT digital_employees_local_scope_check
CHECK (execution_locus <> 'local' OR (
 runtime_environment_id IS NULL AND (
  (tenant_id IS NULL AND source='platform' AND visibility='platform') OR
  (tenant_id IS NOT NULL AND creator_id IS NOT NULL AND NULLIF(metadata->>'agent_key','') IS NOT NULL AND (
   (source='personal' AND visibility='private') OR
   (source='enterprise' AND visibility IN ('tenant','workspace','private'))
  ))
 )
));
COMMENT ON CONSTRAINT digital_employees_local_scope_check ON agent_bus.digital_employees IS
 'Local employee scope: personal creator-only, authorized tenant organization members, or shared platform template; no cloud runtime binding';
