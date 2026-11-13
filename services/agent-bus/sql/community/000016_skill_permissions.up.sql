-- Existing upstream skill RBAC seeds omitted by the community export.
-- Only system administrators receive their own scope permissions.
SET LOCAL search_path = agent_bus, public;
INSERT INTO permissions(code,name,description,kind,scope_kind,resource,action,category,is_system,sort_order) VALUES
('platform.skill.read','平台-技能-查看','查看平台 SkillHub 库','api','platform','skill','read',NULL,'true','1080'),
('tenant.skill.read','租户-技能-查看','查看本租户 SkillHub','api','tenant','skill','read',NULL,'true','1082'),
('platform.skill.create','平台-技能-创建','创建平台技能、版本和技能字典项','api','platform','skill','create','skill','true','1081'),
('platform.skill.update','平台-技能-编辑','编辑平台技能、版本和技能字典项','api','platform','skill','update','skill','true','1082'),
('platform.skill.delete','平台-技能-删除','删除平台技能或技能字典项','api','platform','skill','delete','skill','true','1083'),
('platform.skill.publish','平台-技能-发布','发布、归档或回滚平台技能版本','api','platform','skill','publish','skill','true','1084'),
('platform.skill.upload','平台-技能-上传','上传技能包、图标和示例图','api','platform','skill','upload','skill','true','1085'),
('platform.skill.preview','平台-技能-预览','执行平台技能预览','api','platform','skill','preview','skill','true','1086'),
('tenant.skill.create','租户-技能-创建','创建租户技能和版本','api','tenant','skill','create','skill','true','1083'),
('tenant.skill.update','租户-技能-编辑','编辑租户技能、版本和偏好','api','tenant','skill','update','skill','true','1084'),
('tenant.skill.delete','租户-技能-删除','删除租户技能','api','tenant','skill','delete','skill','true','1085'),
('tenant.skill.publish','租户-技能-发布','发布、归档或回滚租户技能版本','api','tenant','skill','publish','skill','true','1086'),
('tenant.skill.enable','租户-平台技能-启停','启用或禁用平台技能在本租户可用性','api','tenant','skill','enable','skill','true','1087'),
('tenant.skill.upload','租户-技能-上传','上传租户技能包、图标和示例图','api','tenant','skill','upload','skill','true','1088'),
('tenant.skill.agent_bind','租户-技能-数字员工绑定','给数字员工挂载或移除技能','api','tenant','skill','agent_bind','skill','true','1089')
ON CONFLICT (code) DO NOTHING;
INSERT INTO role_permissions(role_id,permission_id)
SELECT r.id,p.id FROM roles r JOIN permissions p ON p.scope_kind=r.scope_kind
WHERE r.deleted_at IS NULL AND r.is_system AND
 ((r.code='platform.admin' AND r.scope_kind='platform' AND p.code LIKE 'platform.skill.%')
 OR (r.code='tenant.admin' AND r.scope_kind='tenant' AND p.code LIKE 'tenant.skill.%'))
ON CONFLICT DO NOTHING;
