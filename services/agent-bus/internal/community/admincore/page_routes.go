package admincore

import (
	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"net/http"
)

func (h *Handlers) registerPages(mux *http.ServeMux, adminAuth func(http.Handler) http.Handler, platformPerm, tenantPerm func(string, http.Handler) http.Handler) {
	if h.KBProviderRepo != nil {
		mux.Handle("GET /api/admin/v1/platform/kb-providers",
			platformPerm("platform.kb_provider.read", http.HandlerFunc(h.listKBProviders)))
		if h.KBHealthChecker != nil {
			mux.Handle("POST /api/admin/v1/platform/kb-providers/{provider_uuid}/health-check",
				platformPerm("platform.kb_provider.probe", http.HandlerFunc(h.healthCheckKBProvider)))
		}
		// Codex round-4 P1-3: CRUD + set-default.
		mux.Handle("POST /api/admin/v1/platform/kb-providers",
			platformPerm("platform.kb_provider.create", http.HandlerFunc(h.createKBProvider)))
		mux.Handle("PATCH /api/admin/v1/platform/kb-providers/{provider_uuid}",
			platformPerm("platform.kb_provider.update", http.HandlerFunc(h.patchKBProvider)))
		mux.Handle("DELETE /api/admin/v1/platform/kb-providers/{provider_uuid}",
			platformPerm("platform.kb_provider.delete", http.HandlerFunc(h.deleteKBProvider)))
		mux.Handle("POST /api/admin/v1/platform/kb-providers/{provider_uuid}/set-default",
			platformPerm("platform.kb_provider.set_default", http.HandlerFunc(h.setDefaultKBProvider)))
	}
	if h.AdminAgentA2AInvoke != nil {
		mux.Handle("GET /api/admin/v1/tenant/agents/{agent_id}/a2a-invoke-capability",
			tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminAgentA2AInvoke.Get)))
		mux.Handle("PUT /api/admin/v1/tenant/agents/{agent_id}/a2a-invoke-capability",
			tenantPerm("tenant.agent.update", h.requireTenantEditableAgent(http.HandlerFunc(h.AdminAgentA2AInvoke.Update))))
	}
	if h.AgentKBBindings != nil {
		mux.Handle("GET /api/admin/v1/tenant/agents/{agent_uuid}/kb-bindings",
			tenantPerm("tenant.agent.read", http.HandlerFunc(h.AgentKBBindings.List)))
		mux.Handle("POST /api/admin/v1/tenant/agents/{agent_uuid}/kb-bindings",
			tenantPerm("tenant.agent.update", h.requireTenantEditableAgent(http.HandlerFunc(h.AgentKBBindings.Attach))))
		mux.Handle("DELETE /api/admin/v1/tenant/agents/{agent_uuid}/kb-bindings/{kb_uuid}",
			tenantPerm("tenant.agent.update", h.requireTenantEditableAgent(http.HandlerFunc(h.AgentKBBindings.Detach))))
	}
	if h.AgentKBBindings != nil {
		mux.Handle("GET /api/admin/v1/platform/preset-agents/{uuid}/kb-bindings",
			platformPerm("platform.preset_agent.read", http.HandlerFunc(h.AgentKBBindings.ListPlatformPreset)))
		mux.Handle("PUT /api/admin/v1/platform/preset-agents/{uuid}/kb-bindings",
			platformPerm("platform.preset_agent.update", http.HandlerFunc(h.AgentKBBindings.ReplacePlatformPreset)))
	}
	if h.AdminAgentA2ACard != nil {
		mux.Handle("GET /api/admin/v1/tenant/agents/{agent_id}/a2a-card",
			tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminAgentA2ACard.Get)))
		mux.Handle("PUT /api/admin/v1/tenant/agents/{agent_id}/a2a-card",
			tenantPerm("tenant.agent.update", h.requireTenantEditableAgent(http.HandlerFunc(h.AdminAgentA2ACard.Update))))
	}
	if h.AdminAgentA2ACard != nil {
		mux.Handle("GET /api/admin/v1/platform/preset-agents/{agent_id}/a2a-card",
			platformPerm("platform.preset_agent.read", http.HandlerFunc(h.AdminAgentA2ACard.GetPlatformPreset)))
		mux.Handle("PUT /api/admin/v1/platform/preset-agents/{agent_id}/a2a-card",
			platformPerm("platform.preset_agent.update", http.HandlerFunc(h.AdminAgentA2ACard.UpdatePlatformPreset)))
	}
	if h.ClientBuild != nil {
		mux.Handle("GET /api/admin/v1/platform/client-build-jobs", platformPerm("platform.client_version.read", http.HandlerFunc(h.listClientBuildJobs)))
		mux.Handle("POST /api/admin/v1/platform/client-build-jobs", platformPerm("platform.client_version.create", http.HandlerFunc(h.createClientBuildJob)))
		mux.Handle("GET /api/admin/v1/platform/client-build-jobs/{uuid}", platformPerm("platform.client_version.read", http.HandlerFunc(h.getClientBuildJob)))
		mux.Handle("GET /api/admin/v1/platform/client-build-jobs/{uuid}/logs", platformPerm("platform.client_version.read", http.HandlerFunc(h.listClientBuildJobLogs)))
		mux.Handle("POST /api/admin/v1/platform/client-build-jobs/{uuid}/retry", platformPerm("platform.client_version.create", http.HandlerFunc(h.retryClientBuildJob)))
		mux.Handle("DELETE /api/admin/v1/platform/client-build-jobs/{uuid}", platformPerm("platform.client_version.update", http.HandlerFunc(h.stopClientBuildJob)))
	}
	if h.Skill != nil {
		mux.Handle("POST /api/admin/v1/platform/skills", platformPerm("platform.skill.create", http.HandlerFunc(h.createPlatformSkill)))
		mux.Handle("GET /api/admin/v1/platform/skills", platformPerm("platform.skill.read", http.HandlerFunc(h.listPlatformSkills)))
		mux.Handle("GET /api/admin/v1/platform/skills/{uuid}", platformPerm("platform.skill.read", http.HandlerFunc(h.getPlatformSkill)))
		mux.Handle("PATCH /api/admin/v1/platform/skills/{uuid}", platformPerm("platform.skill.update", http.HandlerFunc(h.patchPlatformSkill)))
		mux.Handle("DELETE /api/admin/v1/platform/skills/{uuid}", platformPerm("platform.skill.delete", http.HandlerFunc(h.deletePlatformSkill)))
		mux.Handle("GET /api/admin/v1/platform/skills/{uuid}/versions", platformPerm("platform.skill.read", http.HandlerFunc(h.listSkillVersions)))
		mux.Handle("POST /api/admin/v1/platform/skills/{uuid}/versions", platformPerm("platform.skill.create", http.HandlerFunc(h.createAgentVersion)))
		mux.Handle("POST /api/admin/v1/platform/skills/{uuid}/builtin-versions", platformPerm("platform.skill.create", http.HandlerFunc(h.createBuiltinVersion)))
		mux.Handle("PATCH /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}", platformPerm("platform.skill.update", http.HandlerFunc(h.patchVersion)))
		mux.Handle("POST /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/publish", platformPerm("platform.skill.publish", http.HandlerFunc(h.publishVersion)))
		mux.Handle("POST /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/archive", platformPerm("platform.skill.publish", http.HandlerFunc(h.archiveVersion)))
		mux.Handle("POST /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/rollback", platformPerm("platform.skill.publish", http.HandlerFunc(h.rollbackVersion)))
		mux.Handle("GET /api/admin/v1/platform/skill-categories", platformPerm("platform.skill.read", http.HandlerFunc(h.listSkillCategories)))
		mux.Handle("GET /api/admin/v1/platform/skill-labels", platformPerm("platform.skill.read", http.HandlerFunc(h.listSkillLabels)))
		mux.Handle("GET /api/admin/v1/platform/builtin-skill-keys", platformPerm("platform.skill.read", http.HandlerFunc(h.listBuiltinSkillKeys)))
		mux.Handle("GET /api/admin/v1/tenant/skill-categories", tenantPerm("tenant.skill.read", http.HandlerFunc(h.listSkillCategories)))
		mux.Handle("GET /api/admin/v1/tenant/skill-labels", tenantPerm("tenant.skill.read", http.HandlerFunc(h.listSkillLabels)))
		mux.Handle("GET /api/admin/v1/tenant/builtin-skill-keys", tenantPerm("tenant.skill.read", http.HandlerFunc(h.listBuiltinSkillKeys)))
	}
	if h.Skill != nil {
		mux.Handle("GET /api/admin/v1/tenant/skills", tenantPerm("tenant.skill.read", http.HandlerFunc(h.tenantListSkills)))
		mux.Handle("GET /api/admin/v1/tenant/skills/{uuid}/versions", tenantPerm("tenant.skill.read", http.HandlerFunc(h.tenantListSkillVersions)))
		mux.Handle("POST /api/admin/v1/tenant/skills/{uuid}/disable", tenantPerm("tenant.skill.enable", http.HandlerFunc(h.tenantDisableSkill)))
		mux.Handle("DELETE /api/admin/v1/tenant/skills/{uuid}/disable", tenantPerm("tenant.skill.enable", http.HandlerFunc(h.tenantEnableSkill)))
		mux.Handle("POST /api/admin/v1/tenant/skills", tenantPerm("tenant.skill.create", http.HandlerFunc(h.tenantCreateSkill)))
		mux.Handle("GET /api/admin/v1/tenant/skills/{uuid}", tenantPerm("tenant.skill.read", http.HandlerFunc(h.tenantGetSkill)))
		mux.Handle("PATCH /api/admin/v1/tenant/skills/{uuid}", tenantPerm("tenant.skill.update", http.HandlerFunc(h.tenantPatchSkill)))
		mux.Handle("DELETE /api/admin/v1/tenant/skills/{uuid}", tenantPerm("tenant.skill.delete", http.HandlerFunc(h.tenantDeleteSkill)))
		mux.Handle("POST /api/admin/v1/tenant/skills/{uuid}/versions", tenantPerm("tenant.skill.create", http.HandlerFunc(h.tenantCreateAgentVersion)))
		mux.Handle("POST /api/admin/v1/tenant/skills/{uuid}/builtin-versions", tenantPerm("tenant.skill.create", http.HandlerFunc(h.tenantCreateBuiltinVersion)))
		mux.Handle("POST /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}/publish", tenantPerm("tenant.skill.publish", http.HandlerFunc(h.tenantPublishVersion)))
		mux.Handle("GET /api/admin/v1/tenant/skill-preferences", tenantPerm("tenant.skill.read", http.HandlerFunc(h.tenantListPreferences)))
		mux.Handle("PUT /api/admin/v1/tenant/skill-preferences/{uuid}", tenantPerm("tenant.skill.update", http.HandlerFunc(h.tenantSetPreference)))
		mux.Handle("DELETE /api/admin/v1/tenant/skill-preferences/{uuid}", tenantPerm("tenant.skill.update", http.HandlerFunc(h.tenantClearPreference)))
		mux.Handle("GET /api/admin/v1/tenant/agents/{agent_uuid}/skills", tenantPerm("tenant.skill.read", http.HandlerFunc(h.tenantListAgentSkills)))
		mux.Handle("GET /api/admin/v1/tenant/agents/{agent_uuid}/skills/available", tenantPerm("tenant.skill.read", http.HandlerFunc(h.tenantListAvailableSkills)))
	}
	if h.Skill != nil {
		mux.Handle("POST /api/admin/v1/platform/skill-categories", platformPerm("platform.skill.create", http.HandlerFunc(h.createSkillCategory)))
		mux.Handle("PATCH /api/admin/v1/platform/skill-categories/{id}", platformPerm("platform.skill.update", http.HandlerFunc(h.patchSkillCategory)))
		mux.Handle("DELETE /api/admin/v1/platform/skill-categories/{id}", platformPerm("platform.skill.delete", http.HandlerFunc(h.deleteSkillCategory)))
		mux.Handle("POST /api/admin/v1/platform/skill-labels", platformPerm("platform.skill.create", http.HandlerFunc(h.createSkillLabel)))
		mux.Handle("PATCH /api/admin/v1/platform/skill-labels/{id}", platformPerm("platform.skill.update", http.HandlerFunc(h.patchSkillLabel)))
		mux.Handle("DELETE /api/admin/v1/platform/skill-labels/{id}", platformPerm("platform.skill.delete", http.HandlerFunc(h.deleteSkillLabel)))
		mux.Handle("POST /api/admin/v1/platform/builtin-skill-keys", platformPerm("platform.skill.create", http.HandlerFunc(h.createBuiltinSkillKey)))
		mux.Handle("PATCH /api/admin/v1/platform/builtin-skill-keys/{id}", platformPerm("platform.skill.update", http.HandlerFunc(h.patchBuiltinSkillKey)))
		mux.Handle("DELETE /api/admin/v1/platform/builtin-skill-keys/{id}", platformPerm("platform.skill.delete", http.HandlerFunc(h.deleteBuiltinSkillKey)))
		mux.Handle("POST /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/upload-package", platformPerm("platform.skill.upload", http.HandlerFunc(h.uploadSkillPackage)))
		mux.Handle("POST /api/admin/v1/platform/skills/upload-icon", platformPerm("platform.skill.upload", http.HandlerFunc(h.uploadSkillIcon)))
		mux.Handle("GET /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/files", platformPerm("platform.skill.read", http.HandlerFunc(h.listSkillVersionFiles)))
		mux.Handle("GET /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/file-content", platformPerm("platform.skill.read", http.HandlerFunc(h.getSkillVersionFileContent)))
		mux.Handle("GET /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/download-url", platformPerm("platform.skill.read", http.HandlerFunc(h.getSkillVersionDownloadURL)))
		mux.Handle("POST /api/admin/v1/platform/skills/{uuid}/preview", platformPerm("platform.skill.preview", http.HandlerFunc(h.previewSkill)))
		mux.Handle("POST /api/admin/v1/tenant/skills/upload-icon", tenantPerm("tenant.skill.upload", http.HandlerFunc(h.uploadSkillIcon)))
	}
	if h.Cron != nil {
		mux.Handle("GET /api/admin/v1/tenant/cron-jobs", tenantPerm("tenant.agent.read", http.HandlerFunc(h.listTenantCronJobs)))
		mux.Handle("GET /api/admin/v1/tenant/cron-jobs/{uuid}", tenantPerm("tenant.agent.read", http.HandlerFunc(h.getTenantCronJobDetail)))
		mux.Handle("POST /api/admin/v1/tenant/cron-jobs/{uuid}/force-disable", tenantPerm("tenant.agent.update", http.HandlerFunc(h.adminForceDisableCron)))
		mux.Handle("POST /api/admin/v1/tenant/cron-jobs/{uuid}/clear-admin-flag", tenantPerm("tenant.agent.update", http.HandlerFunc(h.adminClearCronAdminFlag)))
		mux.Handle("GET /api/admin/v1/platform/cron/capability-dry-run", platformPerm("platform.cron.read", http.HandlerFunc(h.adminCronCapabilityDryRun)))
		mux.Handle("GET /api/admin/v1/platform/cron-jobs/overview", platformPerm("platform.cron.read", http.HandlerFunc(h.platformCronOverview)))
		mux.Handle("GET /api/admin/v1/platform/cron-jobs", platformPerm("platform.cron.read", http.HandlerFunc(h.platformListCronJobs)))
		mux.Handle("GET /api/admin/v1/platform/cron-jobs/{uuid}", platformPerm("platform.cron.read", http.HandlerFunc(h.platformGetCronJob)))
		mux.Handle("GET /api/admin/v1/tenant/cron-prompt-templates", tenantPerm("tenant.agent.read", http.HandlerFunc(h.adminListTenantPromptTemplates)))
		mux.Handle("GET /api/admin/v1/tenant/cron-prompt-templates/{uuid}", tenantPerm("tenant.agent.read", http.HandlerFunc(h.adminGetTenantPromptTemplate)))
		mux.Handle("POST /api/admin/v1/tenant/cron-prompt-templates", tenantPerm("tenant.agent.update", http.HandlerFunc(h.adminCreateTenantPromptTemplate)))
		mux.Handle("PATCH /api/admin/v1/tenant/cron-prompt-templates/{uuid}", tenantPerm("tenant.agent.update", http.HandlerFunc(h.adminPatchTenantPromptTemplate)))
		mux.Handle("DELETE /api/admin/v1/tenant/cron-prompt-templates/{uuid}", tenantPerm("tenant.agent.update", http.HandlerFunc(h.adminDeleteTenantPromptTemplate)))
		mux.Handle("GET /api/admin/v1/platform/cron-prompt-templates", platformPerm("platform.cron.read", http.HandlerFunc(h.adminListPlatformPromptTemplates)))
		mux.Handle("GET /api/admin/v1/platform/cron-prompt-templates/{uuid}", platformPerm("platform.cron.read", http.HandlerFunc(h.adminGetPlatformPromptTemplate)))
		mux.Handle("POST /api/admin/v1/platform/cron-prompt-templates", platformPerm("platform.cron.create", http.HandlerFunc(h.adminCreatePlatformPromptTemplate)))
		mux.Handle("PATCH /api/admin/v1/platform/cron-prompt-templates/{uuid}", platformPerm("platform.cron.update", http.HandlerFunc(h.adminPatchPlatformPromptTemplate)))
		mux.Handle("DELETE /api/admin/v1/platform/cron-prompt-templates/{uuid}", platformPerm("platform.cron.delete", http.HandlerFunc(h.adminDeletePlatformPromptTemplate)))
	}
	if h.DriveBrowse != nil {
		mux.Handle("GET /api/admin/v1/tenant/drive/spaces", tenantPerm("tenant.drive.read_metadata", http.HandlerFunc(h.listTenantDriveSpaces)))
		mux.Handle("GET /api/admin/v1/tenant/drive/spaces/{uuid}/files", tenantPerm("tenant.drive.read_metadata", http.HandlerFunc(h.listTenantDriveFiles)))
	}
	if h.DriveStorage != nil {
		mux.Handle("GET    /api/admin/v1/platform/drive/storage-defaults", platformPerm("platform.drive.manage_storage", http.HandlerFunc(h.listStorageDefaults)))
		mux.Handle("POST   /api/admin/v1/platform/drive/storage-defaults", platformPerm("platform.drive.manage_storage", http.HandlerFunc(h.createStorageDefault)))
		mux.Handle("PATCH  /api/admin/v1/platform/drive/storage-defaults/{uuid}", platformPerm("platform.drive.manage_storage", http.HandlerFunc(h.patchStorageDefault)))
		mux.Handle("DELETE /api/admin/v1/platform/drive/storage-defaults/{uuid}", platformPerm("platform.drive.manage_storage", http.HandlerFunc(h.deleteStorageDefault)))
		mux.Handle("POST   /api/admin/v1/platform/drive/storage-defaults/{uuid}/set-default", platformPerm("platform.drive.manage_storage", http.HandlerFunc(h.setStorageDefault)))
		mux.Handle("POST   /api/admin/v1/platform/drive/storage-defaults/{uuid}/test-connection", platformPerm("platform.drive.manage_storage", http.HandlerFunc(h.testStorageDefault)))
		mux.Handle("GET    /api/admin/v1/tenant/drive/storage-override", tenantPerm("tenant.drive.manage_storage", http.HandlerFunc(h.getTenantStorageOverride)))
		mux.Handle("PUT    /api/admin/v1/tenant/drive/storage-override", tenantPerm("tenant.drive.manage_storage", http.HandlerFunc(h.putTenantStorageOverride)))
		mux.Handle("DELETE /api/admin/v1/tenant/drive/storage-override", tenantPerm("tenant.drive.manage_storage", http.HandlerFunc(h.deleteTenantStorageOverride)))
		mux.Handle("POST   /api/admin/v1/tenant/drive/storage-override/test-connection", tenantPerm("tenant.drive.manage_storage", http.HandlerFunc(h.testTenantStorageOverride)))
	}
	if h.DriveQuotaAdmin != nil {
		mux.Handle("GET /api/admin/v1/tenant/drive/quotas", tenantPerm("tenant.drive.manage_quota", http.HandlerFunc(h.getTenantDriveQuotas)))
		mux.Handle("PUT /api/admin/v1/tenant/drive/quotas/accounts/{account_id}", tenantPerm("tenant.drive.manage_quota", http.HandlerFunc(h.putTenantDriveAccountQuota)))
	}
	if h.DriveUsageAdmin != nil {
		mux.Handle("GET /api/admin/v1/platform/drive/usage", platformPerm("platform.drive.read_usage", http.HandlerFunc(h.listPlatformDriveUsage)))
		mux.Handle("GET /api/admin/v1/platform/drive/usage/summary", platformPerm("platform.drive.read_usage", http.HandlerFunc(h.getPlatformDriveUsageSummary)))
	}
	if h.DriveRecycleAdmin != nil {
		mux.Handle("GET    /api/admin/v1/tenant/drive/recycle", tenantPerm("tenant.drive.manage_recycle", http.HandlerFunc(h.listTenantDriveRecycle)))
		mux.Handle("POST   /api/admin/v1/tenant/drive/recycle/{uuid}/restore", tenantPerm("tenant.drive.manage_recycle", http.HandlerFunc(h.restoreTenantDriveRecycle)))
		mux.Handle("DELETE /api/admin/v1/tenant/drive/recycle/{uuid}/purge", tenantPerm("tenant.drive.manage_recycle", http.HandlerFunc(h.purgeTenantDriveRecycle)))
	}
	if h.Media != nil {
		mux.Handle("POST /api/admin/v1/tenant/media/agent-avatars/upload", adminAuth(middleware.RequirePasswordValid(middleware.RequireTenant(middleware.RequirePermission("tenant.agent.create", "tenant.agent.update")(http.HandlerFunc(h.uploadAgentAvatarMedia))))))
		mux.Handle("POST /api/admin/v1/platform/media/agent-avatars/upload", adminAuth(middleware.RequirePasswordValid(middleware.RequirePlatform(middleware.RequirePermission("platform.preset_agent.create", "platform.preset_agent.update")(http.HandlerFunc(h.uploadAgentAvatarMedia))))))
		mux.Handle("POST /api/admin/v1/tenant/media/preview", tenantPerm("tenant.agent.read", http.HandlerFunc(h.previewMedia)))
		mux.Handle("POST /api/admin/v1/platform/media/skill-icons/upload", platformPerm("platform.skill.upload", http.HandlerFunc(h.uploadSkillIconMedia)))
		mux.Handle("POST /api/admin/v1/platform/media/skill-example-images/upload", platformPerm("platform.skill.upload", http.HandlerFunc(h.uploadSkillExampleImageMedia)))
		mux.Handle("POST /api/admin/v1/platform/media/preview", platformPerm("platform.skill.read", http.HandlerFunc(h.previewMedia)))
		mux.Handle("POST /api/admin/v1/tenant/media/skill-icons/upload", tenantPerm("tenant.skill.upload", http.HandlerFunc(h.uploadSkillIconMedia)))
		mux.Handle("POST /api/admin/v1/tenant/media/skill-example-images/upload", tenantPerm("tenant.skill.upload", http.HandlerFunc(h.uploadSkillExampleImageMedia)))
	}
	if h.ContactPolicy != nil {
		mux.Handle("GET /api/admin/v1/tenant/contact-policy", tenantPerm("tenant.member.read", http.HandlerFunc(h.getContactPolicy)))
		mux.Handle("PUT /api/admin/v1/tenant/contact-policy", tenantPerm("tenant.member.update", http.HandlerFunc(h.updateContactPolicy)))
	}
	if h.Audit != nil {
		mux.Handle("GET /api/admin/v1/platform/audit-summary", platformPerm("platform.audit.read", http.HandlerFunc(h.Audit.getPlatformAuditSummary)))
		mux.Handle("GET /api/admin/v1/platform/audit-events", platformPerm("platform.audit.read", http.HandlerFunc(h.Audit.listPlatformAuditEvents)))
		mux.Handle("GET /api/admin/v1/platform/audit-outbox-dlq", platformPerm("platform.audit.read", http.HandlerFunc(h.Audit.listAuditDLQ)))
		mux.Handle("POST /api/admin/v1/platform/audit-outbox-dlq/{id}/retry", platformPerm("platform.audit.read", http.HandlerFunc(h.Audit.retryAuditDLQ)))
		mux.Handle("POST /api/admin/v1/platform/audit-outbox-dlq/{id}/ignore", platformPerm("platform.audit.read", http.HandlerFunc(h.Audit.ignoreAuditDLQ)))
		mux.Handle("GET /api/admin/v1/tenant/audit-summary", tenantPerm("tenant.audit.read", http.HandlerFunc(h.Audit.getTenantAuditSummary)))
		mux.Handle("GET /api/admin/v1/tenant/audit-events", tenantPerm("tenant.audit.read", http.HandlerFunc(h.Audit.listTenantAuditEvents)))
	}
	if h.Rooms != nil {
		mux.Handle("GET /api/admin/v1/tenant/rooms", tenantPerm("tenant.agent.read", http.HandlerFunc(h.Rooms.List)))
		mux.Handle("GET /api/admin/v1/tenant/rooms/{uuid}", tenantPerm("tenant.agent.read", http.HandlerFunc(h.Rooms.Get)))
		mux.Handle("GET /api/admin/v1/tenant/rooms/{uuid}/speaker-decisions", tenantPerm("tenant.agent.read", http.HandlerFunc(h.Rooms.SpeakerDecisions)))
		mux.Handle("GET /api/admin/v1/tenant/rooms/{uuid}/triggers", tenantPerm("tenant.agent.read", http.HandlerFunc(h.Rooms.Triggers)))
		mux.Handle("PUT /api/admin/v1/tenant/rooms/{uuid}/speaker-policy", tenantPerm("tenant.agent.update", http.HandlerFunc(h.Rooms.ApplySpeaker)))
		mux.Handle("POST /api/admin/v1/tenant/rooms/{uuid}/freeze", tenantPerm("tenant.agent.update", http.HandlerFunc(h.Rooms.Freeze)))
		mux.Handle("POST /api/admin/v1/tenant/rooms/{uuid}/unfreeze", tenantPerm("tenant.agent.update", http.HandlerFunc(h.Rooms.Unfreeze)))
	}
	if h.Auth != nil {
		mux.Handle("GET /api/admin/v1/me/sessions", adminAuth(http.HandlerFunc(h.listMySessions)))
		mux.Handle("DELETE /api/admin/v1/me/sessions/{uuid}", adminAuth(http.HandlerFunc(h.revokeMySession)))
	}
	if h.DriveWorkersAdmin != nil {
		mux.Handle("GET /api/admin/v1/platform/drive/workers", platformPerm("platform.drive.read_workers", http.HandlerFunc(h.listPlatformDriveWorkers)))
		mux.Handle("GET /api/admin/v1/platform/drive/workers/{job}/failures", platformPerm("platform.drive.read_workers", http.HandlerFunc(h.listPlatformDriveWorkerFailures)))
		mux.Handle("POST /api/admin/v1/platform/drive/workers/{job}/trigger", platformPerm("platform.drive.manage_workers", http.HandlerFunc(h.triggerPlatformDriveWorker)))
	}
	if h.DrivePlatformQuota != nil {
		mux.Handle("PUT /api/admin/v1/platform/drive/tenants/{tenant_id}/quota", platformPerm("platform.drive.manage_quota", http.HandlerFunc(h.putPlatformDriveTenantQuota)))
	}
	if h.Observability != nil {

	}
	if h.ObservabilityAgentRuns != nil {
		mux.Handle("GET /api/admin/v1/platform/observability/agent-runs", platformPerm("platform.observability.read", http.HandlerFunc(h.ObservabilityAgentRuns.listPlatformRuns)))
		mux.Handle("GET /api/admin/v1/platform/observability/agent-runs/stats", platformPerm("platform.observability.read", http.HandlerFunc(h.ObservabilityAgentRuns.getPlatformRunStats)))
		mux.Handle("GET /api/admin/v1/platform/observability/agent-runs/{uuid}", platformPerm("platform.observability.read", http.HandlerFunc(h.ObservabilityAgentRuns.getPlatformRunDetail)))
		mux.Handle("GET /api/admin/v1/platform/observability/agent-runs/{uuid}/chain", platformPerm("platform.observability.read", http.HandlerFunc(h.ObservabilityAgentRuns.getPlatformRunChain)))
		mux.Handle("GET /api/admin/v1/platform/observability/conversations", platformPerm("platform.observability.content.read", http.HandlerFunc(h.ObservabilityAgentRuns.listPlatformConversations)))
		mux.Handle("GET /api/admin/v1/platform/observability/conversations/{uuid}/messages", platformPerm("platform.observability.content.read", http.HandlerFunc(h.ObservabilityAgentRuns.getPlatformConversationMessages)))
		mux.Handle("GET /api/admin/v1/tenant/observability/agent-runs", tenantPerm("tenant.observability.read", http.HandlerFunc(h.ObservabilityAgentRuns.listTenantRuns)))
		mux.Handle("GET /api/admin/v1/tenant/observability/agent-runs/stats", tenantPerm("tenant.observability.read", http.HandlerFunc(h.ObservabilityAgentRuns.getTenantRunStats)))
		mux.Handle("GET /api/admin/v1/tenant/observability/agent-runs/{uuid}", tenantPerm("tenant.observability.read", http.HandlerFunc(h.ObservabilityAgentRuns.getTenantRunDetail)))
		mux.Handle("GET /api/admin/v1/tenant/observability/agent-runs/{uuid}/chain", tenantPerm("tenant.observability.read", http.HandlerFunc(h.ObservabilityAgentRuns.getTenantRunChain)))
		mux.Handle("GET /api/admin/v1/tenant/observability/conversations", tenantPerm("tenant.observability.content.read", http.HandlerFunc(h.ObservabilityAgentRuns.listTenantConversations)))
		mux.Handle("GET /api/admin/v1/tenant/observability/conversations/{uuid}/messages", tenantPerm("tenant.observability.content.read", http.HandlerFunc(h.ObservabilityAgentRuns.getTenantConversationMessages)))
	}
	if h.AdminA2A != nil {
		mux.Handle("GET /api/admin/v1/tenant/a2a", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminA2A.List)))
		mux.Handle("GET /api/admin/v1/tenant/a2a/agents", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminA2A.AgentNodes)))
		mux.Handle("GET /api/admin/v1/tenant/a2a/{edge_id}", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminA2A.Get)))
	}
	if h.AdminOrchestrations != nil {
		mux.Handle("GET /api/admin/v1/tenant/orchestrations", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminOrchestrations.List)))
		mux.Handle("GET /api/admin/v1/tenant/orchestrations/{uuid}", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminOrchestrations.Get)))
	}
	if h.AdminSpeakerPolicies != nil {
		mux.Handle("GET /api/admin/v1/tenant/speaker-policies", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminSpeakerPolicies.List)))
		mux.Handle("POST /api/admin/v1/tenant/speaker-policies", tenantPerm("tenant.agent.update", http.HandlerFunc(h.AdminSpeakerPolicies.Create)))
		mux.Handle("GET /api/admin/v1/tenant/speaker-policies/{uuid}", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminSpeakerPolicies.Get)))
		mux.Handle("PUT /api/admin/v1/tenant/speaker-policies/{uuid}", tenantPerm("tenant.agent.update", http.HandlerFunc(h.AdminSpeakerPolicies.Update)))
		mux.Handle("DELETE /api/admin/v1/tenant/speaker-policies/{uuid}", tenantPerm("tenant.agent.update", http.HandlerFunc(h.AdminSpeakerPolicies.Delete)))
	}
	if h.PlatformType != nil {
		mux.Handle("GET /api/admin/v1/runtime/platform-types", adminAuth(middleware.RequirePasswordValid(http.HandlerFunc(h.listPlatformTypes))))
	}
	if h.UserKBInspect != nil {
		mux.Handle("GET /api/admin/v1/tenant/users/{user_uuid}/knowledge-bases", tenantPerm("tenant.kb.read_user_private", http.HandlerFunc(h.UserKBInspect.List)))
	}
	if h.Knowledge != nil {
		mux.Handle("GET /api/admin/v1/platform/knowledge-bases", platformPerm("platform.kb.read", h.listManagedKnowledgeBases(domkb.ScopePlatform)))
		mux.Handle("POST /api/admin/v1/platform/knowledge-bases", platformPerm("platform.kb.create", h.createManagedKnowledgeBase(domkb.ScopePlatform)))
		mux.Handle("GET /api/admin/v1/platform/knowledge-bases/{uuid}", platformPerm("platform.kb.read", h.getManagedKnowledgeBase(domkb.ScopePlatform)))
		mux.Handle("PATCH /api/admin/v1/platform/knowledge-bases/{uuid}", platformPerm("platform.kb.update", h.patchManagedKnowledgeBase(domkb.ScopePlatform)))
		mux.Handle("DELETE /api/admin/v1/platform/knowledge-bases/{uuid}", platformPerm("platform.kb.delete", h.deleteManagedKnowledgeBase(domkb.ScopePlatform)))
		mux.Handle("GET /api/admin/v1/platform/knowledge-bases/{uuid}/references", platformPerm("platform.kb.read", h.managedKnowledgeBaseReferences(domkb.ScopePlatform)))
		mux.Handle("POST /api/admin/v1/platform/knowledge-bases/{uuid}/recall-test", platformPerm("platform.kb.recall", h.recallManagedKnowledgeBase(domkb.ScopePlatform)))
		mux.Handle("GET /api/admin/v1/platform/knowledge-bases/{uuid}/folders", platformPerm("platform.kb.read", h.listManagedFolders(domkb.ScopePlatform)))
		mux.Handle("POST /api/admin/v1/platform/knowledge-bases/{uuid}/folders", platformPerm("platform.kb.update", h.createManagedFolder(domkb.ScopePlatform)))
		mux.Handle("PATCH /api/admin/v1/platform/knowledge-bases/{uuid}/folders/{folder_uuid}", platformPerm("platform.kb.update", h.patchManagedFolder(domkb.ScopePlatform)))
		mux.Handle("DELETE /api/admin/v1/platform/knowledge-bases/{uuid}/folders/{folder_uuid}", platformPerm("platform.kb.update", h.deleteManagedFolder(domkb.ScopePlatform)))
		mux.Handle("GET /api/admin/v1/platform/knowledge-bases/{uuid}/documents", platformPerm("platform.kb.read", h.listManagedDocuments(domkb.ScopePlatform)))
		mux.Handle("POST /api/admin/v1/platform/knowledge-bases/{uuid}/documents/upload", platformPerm("platform.kb.update", h.uploadManagedDocuments(domkb.ScopePlatform)))
		mux.Handle("PATCH /api/admin/v1/platform/knowledge-bases/{uuid}/documents/{document_uuid}", platformPerm("platform.kb.update", h.patchManagedDocument(domkb.ScopePlatform)))
		mux.Handle("DELETE /api/admin/v1/platform/knowledge-bases/{uuid}/documents/{document_uuid}", platformPerm("platform.kb.update", h.deleteManagedDocument(domkb.ScopePlatform)))
		mux.Handle("POST /api/admin/v1/platform/knowledge-bases/{uuid}/documents/{document_uuid}/retry", platformPerm("platform.kb.update", h.retryManagedDocument(domkb.ScopePlatform)))
		mux.Handle("GET /api/admin/v1/platform/knowledge-bases/{uuid}/documents/{document_uuid}/download", platformPerm("platform.kb.read", h.managedDocumentDownload(domkb.ScopePlatform)))

		mux.Handle("GET /api/admin/v1/tenant/knowledge-bases", tenantPerm("tenant.kb.read", h.listManagedKnowledgeBases(domkb.ScopeTenant)))
		mux.Handle("POST /api/admin/v1/tenant/knowledge-bases", tenantPerm("tenant.kb.create", h.createManagedKnowledgeBase(domkb.ScopeTenant)))
		mux.Handle("GET /api/admin/v1/tenant/knowledge-bases/{uuid}", tenantPerm("tenant.kb.read", h.getManagedKnowledgeBase(domkb.ScopeTenant)))
		mux.Handle("PATCH /api/admin/v1/tenant/knowledge-bases/{uuid}", tenantPerm("tenant.kb.update", h.patchManagedKnowledgeBase(domkb.ScopeTenant)))
		mux.Handle("DELETE /api/admin/v1/tenant/knowledge-bases/{uuid}", tenantPerm("tenant.kb.delete", h.deleteManagedKnowledgeBase(domkb.ScopeTenant)))
		mux.Handle("GET /api/admin/v1/tenant/knowledge-bases/{uuid}/references", tenantPerm("tenant.kb.read", h.managedKnowledgeBaseReferences(domkb.ScopeTenant)))
		mux.Handle("POST /api/admin/v1/tenant/knowledge-bases/{uuid}/recall-test", tenantPerm("tenant.kb.recall", h.recallManagedKnowledgeBase(domkb.ScopeTenant)))
		mux.Handle("GET /api/admin/v1/tenant/knowledge-bases/{uuid}/folders", tenantPerm("tenant.kb.read", h.listManagedFolders(domkb.ScopeTenant)))
		mux.Handle("POST /api/admin/v1/tenant/knowledge-bases/{uuid}/folders", tenantPerm("tenant.kb.update", h.createManagedFolder(domkb.ScopeTenant)))
		mux.Handle("PATCH /api/admin/v1/tenant/knowledge-bases/{uuid}/folders/{folder_uuid}", tenantPerm("tenant.kb.update", h.patchManagedFolder(domkb.ScopeTenant)))
		mux.Handle("DELETE /api/admin/v1/tenant/knowledge-bases/{uuid}/folders/{folder_uuid}", tenantPerm("tenant.kb.update", h.deleteManagedFolder(domkb.ScopeTenant)))
		mux.Handle("GET /api/admin/v1/tenant/knowledge-bases/{uuid}/documents", tenantPerm("tenant.kb.read", h.listManagedDocuments(domkb.ScopeTenant)))
		mux.Handle("POST /api/admin/v1/tenant/knowledge-bases/{uuid}/documents/upload", tenantPerm("tenant.kb.update", h.uploadManagedDocuments(domkb.ScopeTenant)))
		mux.Handle("PATCH /api/admin/v1/tenant/knowledge-bases/{uuid}/documents/{document_uuid}", tenantPerm("tenant.kb.update", h.patchManagedDocument(domkb.ScopeTenant)))
		mux.Handle("DELETE /api/admin/v1/tenant/knowledge-bases/{uuid}/documents/{document_uuid}", tenantPerm("tenant.kb.update", h.deleteManagedDocument(domkb.ScopeTenant)))
		mux.Handle("POST /api/admin/v1/tenant/knowledge-bases/{uuid}/documents/{document_uuid}/retry", tenantPerm("tenant.kb.update", h.retryManagedDocument(domkb.ScopeTenant)))
		mux.Handle("GET /api/admin/v1/tenant/knowledge-bases/{uuid}/documents/{document_uuid}/download", tenantPerm("tenant.kb.read", h.managedDocumentDownload(domkb.ScopeTenant)))
	}

	if h.Observability != nil {
		mux.Handle("GET /api/admin/v1/platform/observability/call-logs", platformPerm("platform.observability.read", http.HandlerFunc(h.Observability.listPlatformCallLogs)))
		mux.Handle("GET /api/admin/v1/platform/observability/call-log-timeline", platformPerm("platform.observability.read", http.HandlerFunc(h.Observability.getPlatformCallLogTimeline)))
		mux.Handle("GET /api/admin/v1/platform/observability/call-logs/{uuid}", platformPerm("platform.observability.read", http.HandlerFunc(h.Observability.getPlatformCallLogDetail)))
		mux.Handle("GET /api/admin/v1/tenant/observability/call-logs", tenantPerm("tenant.observability.read", http.HandlerFunc(h.Observability.listTenantCallLogs)))
		mux.Handle("GET /api/admin/v1/tenant/observability/call-log-timeline", tenantPerm("tenant.observability.read", http.HandlerFunc(h.Observability.getTenantCallLogTimeline)))
		mux.Handle("GET /api/admin/v1/tenant/observability/call-logs/{uuid}", tenantPerm("tenant.observability.read", http.HandlerFunc(h.Observability.getTenantCallLogDetail)))
	}
	if h.OrgWebhook != nil {
		mux.Handle("GET /api/admin/v1/tenant/org-webhooks", tenantPerm("tenant.org_webhook.read", http.HandlerFunc(h.listOrgWebhooks)))
		mux.Handle("POST /api/admin/v1/tenant/org-webhooks", tenantPerm("tenant.org_webhook.create", http.HandlerFunc(h.createOrgWebhook)))
		mux.Handle("PATCH /api/admin/v1/tenant/org-webhooks/{uuid}", tenantPerm("tenant.org_webhook.update", http.HandlerFunc(h.patchOrgWebhook)))
		mux.Handle("DELETE /api/admin/v1/tenant/org-webhooks/{uuid}", tenantPerm("tenant.org_webhook.delete", http.HandlerFunc(h.deleteOrgWebhook)))
		mux.Handle("POST /api/admin/v1/tenant/org-webhooks/{uuid}/rotate-secret", tenantPerm("tenant.org_webhook.update", http.HandlerFunc(h.rotateOrgWebhookSecret)))
		mux.Handle("POST /api/admin/v1/tenant/org-webhooks/{uuid}/test", tenantPerm("tenant.org_webhook.update", http.HandlerFunc(h.testOrgWebhook)))
		mux.Handle("GET /api/admin/v1/tenant/org-webhooks/{uuid}/deliveries", tenantPerm("tenant.org_webhook.read", http.HandlerFunc(h.listOrgWebhookDeliveries)))
	}
	if h.SysUser != nil {
		mux.Handle("GET /api/admin/v1/platform/sys-users", platformPerm("platform.sysuser.read", http.HandlerFunc(h.listSysUsers)))
		mux.Handle("POST /api/admin/v1/platform/sys-users", platformPerm("platform.sysuser.create", http.HandlerFunc(h.createSysUser)))
		mux.Handle("GET /api/admin/v1/platform/sys-users/{id}", platformPerm("platform.sysuser.read", http.HandlerFunc(h.getSysUser)))
		mux.Handle("PUT /api/admin/v1/platform/sys-users/{id}", platformPerm("platform.sysuser.update", http.HandlerFunc(h.updateSysUser)))
		mux.Handle("DELETE /api/admin/v1/platform/sys-users/{id}", platformPerm("platform.sysuser.suspend", http.HandlerFunc(h.suspendSysUser)))
	}
	if h.Skill != nil {
		mux.Handle("PATCH /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}", tenantPerm("tenant.skill.update", h.requireTenantOwnedSkill(http.HandlerFunc(h.patchVersion))))
	}
	if h.Skill != nil {
		mux.Handle("POST /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}/archive", tenantPerm("tenant.skill.publish", h.requireTenantOwnedSkill(http.HandlerFunc(h.archiveVersion))))
	}
	if h.Skill != nil {
		mux.Handle("POST /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}/rollback", tenantPerm("tenant.skill.publish", h.requireTenantOwnedSkill(http.HandlerFunc(h.rollbackVersion))))
	}
	if h.Skill != nil {
		mux.Handle("POST /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}/upload-package", tenantPerm("tenant.skill.upload", h.requireTenantOwnedSkill(http.HandlerFunc(h.uploadSkillPackage))))
	}
	if h.Skill != nil {
		mux.Handle("GET /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}/files", tenantPerm("tenant.skill.read", h.requireTenantOwnedSkill(http.HandlerFunc(h.listSkillVersionFiles))))
	}
	if h.Skill != nil {
		mux.Handle("GET /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}/file-content", tenantPerm("tenant.skill.read", h.requireTenantOwnedSkill(http.HandlerFunc(h.getSkillVersionFileContent))))
	}
	if h.Skill != nil {
		mux.Handle("GET /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}/download-url", tenantPerm("tenant.skill.read", h.requireTenantOwnedSkill(http.HandlerFunc(h.getSkillVersionDownloadURL))))
	}
	if h.Skill != nil {
		mux.Handle("POST /api/admin/v1/tenant/agents/{agent_uuid}/skills", tenantPerm("tenant.skill.agent_bind", h.requireTenantEditableAgent(http.HandlerFunc(h.tenantAttachAgentSkill))))
	}
	if h.Skill != nil {
		mux.Handle("PATCH /api/admin/v1/tenant/agents/{agent_uuid}/skills/{binding_id}", tenantPerm("tenant.skill.agent_bind", h.requireTenantEditableAgent(http.HandlerFunc(h.tenantPatchAgentBinding))))
	}
	if h.Skill != nil {
		mux.Handle("DELETE /api/admin/v1/tenant/agents/{agent_uuid}/skills/{binding_id}", tenantPerm("tenant.skill.agent_bind", h.requireTenantEditableAgent(http.HandlerFunc(h.tenantDetachAgentSkill))))
	}
	if h.ApiKey != nil {
		mux.Handle("GET /api/admin/v1/tenant/api-keys", tenantPerm("tenant.api_key.read", http.HandlerFunc(h.listApiKeys)))
		mux.Handle("POST /api/admin/v1/tenant/api-keys", tenantPerm("tenant.api_key.create", http.HandlerFunc(h.createApiKey)))
		mux.Handle("PATCH /api/admin/v1/tenant/api-keys/{uuid}", tenantPerm("tenant.api_key.update", http.HandlerFunc(h.patchApiKey)))
		mux.Handle("DELETE /api/admin/v1/tenant/api-keys/{uuid}", tenantPerm("tenant.api_key.revoke", http.HandlerFunc(h.revokeApiKey)))
	}
	if h.Alerts != nil {
		h.Alerts.RegisterAlertsRoutes(mux, platformPerm, tenantPerm)
	}
	if h.AgentSDK != nil {
		mux.Handle("GET /api/admin/v1/platform/agent-sdk-credentials",
			platformPerm("platform.agent_sdk.read", http.HandlerFunc(h.listPlatformAgentSDKCredentials)))
		mux.Handle("POST /api/admin/v1/platform/agent-sdk-credentials",
			platformPerm("platform.agent_sdk.create", http.HandlerFunc(h.createPlatformAgentSDKCredential)))
		mux.Handle("DELETE /api/admin/v1/platform/agent-sdk-credentials/{uuid}",
			platformPerm("platform.agent_sdk.revoke", http.HandlerFunc(h.revokePlatformAgentSDKCredential)))

		mux.Handle("GET /api/admin/v1/tenant/agent-sdk-credentials",
			tenantPerm("tenant.agent_sdk.read", http.HandlerFunc(h.listAgentSDKCredentials)))
		mux.Handle("POST /api/admin/v1/tenant/agent-sdk-credentials",
			tenantPerm("tenant.agent_sdk.create", http.HandlerFunc(h.createAgentSDKCredential)))
		mux.Handle("PATCH /api/admin/v1/tenant/agent-sdk-credentials/{uuid}",
			tenantPerm("tenant.agent_sdk.update", http.HandlerFunc(h.patchAgentSDKCredential)))
		mux.Handle("DELETE /api/admin/v1/tenant/agent-sdk-credentials/{uuid}",
			tenantPerm("tenant.agent_sdk.revoke", http.HandlerFunc(h.revokeAgentSDKCredential)))
	}
	if h.WuKongStatus != nil {
		mux.Handle("GET /api/admin/v1/platform/wukong/config",
			platformPerm("platform.im_monitor.read", http.HandlerFunc(h.WuKongStatus.Config)))
		mux.Handle("POST /api/admin/v1/platform/wukong/probe",
			platformPerm("platform.im_monitor.read", http.HandlerFunc(h.WuKongStatus.Probe)))
		mux.Handle("GET /api/admin/v1/platform/wukong/stats",
			platformPerm("platform.im_monitor.read", http.HandlerFunc(h.WuKongStatus.Stats)))
		mux.Handle("GET /api/admin/v1/platform/wukong/overview",
			platformPerm("platform.im_monitor.read", http.HandlerFunc(h.WuKongStatus.Overview)))
		mux.Handle("GET /api/admin/v1/platform/wukong/connections",
			platformPerm("platform.im_monitor.read", http.HandlerFunc(h.WuKongStatus.ConnectionsList)))
		mux.Handle("GET /api/admin/v1/platform/wukong/connections/{uuid}",
			platformPerm("platform.im_monitor.read", http.HandlerFunc(h.WuKongStatus.ConnectionDetail)))
		mux.Handle("GET /api/admin/v1/platform/wukong/events",
			platformPerm("platform.im_monitor.read", http.HandlerFunc(h.WuKongStatus.Events)))
	}
	if h.AdminA2AApprovals != nil {
		mux.Handle("GET /api/admin/v1/tenant/a2a/approvals", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminA2AApprovals.List)))
		mux.Handle("GET /api/admin/v1/tenant/a2a/approvals/{approval_request_id}", tenantPerm("tenant.agent.read", http.HandlerFunc(h.AdminA2AApprovals.Get)))
		mux.Handle("POST /api/admin/v1/tenant/a2a/approvals/{approval_request_id}/decide", tenantPerm("tenant.a2a_approval.decide", http.HandlerFunc(h.AdminA2AApprovals.Decide)))
	}
	if h.SupportFeedback != nil {
		mux.Handle("GET /api/admin/v1/platform/support-feedback",
			platformPerm("platform.support_feedback.read", http.HandlerFunc(h.listSupportFeedback)))
		mux.Handle("PATCH /api/admin/v1/platform/support-feedback/{uuid}",
			platformPerm("platform.support_feedback.update", http.HandlerFunc(h.patchSupportFeedback)))
	}
	if h.MarketingLead != nil {
		mux.Handle("GET /api/admin/v1/platform/marketing-leads",
			platformPerm("platform.marketing_lead.read", http.HandlerFunc(h.listMarketingLeads)))
		mux.Handle("PATCH /api/admin/v1/platform/marketing-leads/{uuid}",
			platformPerm("platform.marketing_lead.manage", http.HandlerFunc(h.patchMarketingLead)))
	}
	if h.ClientVersion != nil {
		mux.Handle("GET /api/admin/v1/platform/client-versions",
			platformPerm("platform.client_version.read", http.HandlerFunc(h.listClientVersions)))
		mux.Handle("POST /api/admin/v1/platform/client-versions",
			platformPerm("platform.client_version.create", http.HandlerFunc(h.createClientVersion)))
		mux.Handle("GET /api/admin/v1/platform/client-versions/{uuid}",
			platformPerm("platform.client_version.read", http.HandlerFunc(h.getClientVersion)))
		mux.Handle("PATCH /api/admin/v1/platform/client-versions/{uuid}",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.patchClientVersion)))
		mux.Handle("POST /api/admin/v1/platform/client-versions/{uuid}/upload-package",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.uploadClientVersionInstaller)))
		mux.Handle("POST /api/admin/v1/platform/client-versions/{uuid}/upload-appcast",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.uploadClientVersionAppcast)))
		mux.Handle("POST /api/admin/v1/platform/client-versions/{uuid}/upload-delta",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.uploadClientVersionDelta)))
		mux.Handle("GET /api/admin/v1/platform/client-versions/{uuid}/download-package",
			platformPerm("platform.client_version.read", http.HandlerFunc(h.downloadClientVersionPackage)))
		mux.Handle("DELETE /api/admin/v1/platform/client-versions/{uuid}",
			platformPerm("platform.client_version.delete", http.HandlerFunc(h.deleteClientVersion)))
	}
	if h.DownloadChannel != nil {
		mux.Handle("GET /api/admin/v1/platform/share-growth",
			platformPerm("platform.share_growth.read", http.HandlerFunc(h.listShareGrowth)))
		mux.Handle("GET /api/admin/v1/platform/share-growth/stats",
			platformPerm("platform.share_growth.read", http.HandlerFunc(h.getShareGrowthStats)))
		mux.Handle("GET /api/admin/v1/platform/download-channels",
			platformPerm("platform.download_channel.read", http.HandlerFunc(h.listDownloadChannels)))
		mux.Handle("GET /api/admin/v1/platform/download-channels/stats",
			platformPerm("platform.download_channel.read", http.HandlerFunc(h.getDownloadChannelStats)))
		mux.Handle("POST /api/admin/v1/platform/download-channels",
			platformPerm("platform.download_channel.manage", http.HandlerFunc(h.createDownloadChannel)))
		mux.Handle("GET /api/admin/v1/platform/download-channels/{uuid}",
			platformPerm("platform.download_channel.read", http.HandlerFunc(h.getDownloadChannel)))
		mux.Handle("PATCH /api/admin/v1/platform/download-channels/{uuid}",
			platformPerm("platform.download_channel.manage", http.HandlerFunc(h.patchDownloadChannel)))
		mux.Handle("DELETE /api/admin/v1/platform/download-channels/{uuid}",
			platformPerm("platform.download_channel.manage", http.HandlerFunc(h.deleteDownloadChannel)))
	}
	if h.EMP != nil {
		mux.Handle("GET /api/admin/v1/platform/emp-blocks", platformPerm("platform.emp.read", http.HandlerFunc(h.listEMPBlocks)))
		mux.Handle("POST /api/admin/v1/platform/emp-blocks", platformPerm("platform.emp.create", http.HandlerFunc(h.createEMPBlock)))
		mux.Handle("PATCH /api/admin/v1/platform/emp-blocks/{id}", platformPerm("platform.emp.update", http.HandlerFunc(h.updateEMPBlock)))
		mux.Handle("GET /api/admin/v1/platform/emp-blocks/{id}", platformPerm("platform.emp.read", http.HandlerFunc(h.getEMPBlock)))
	}
	mux.Handle("GET /api/admin/v1/platform/client-analytics/overview", platformPerm("platform.overview.read", http.HandlerFunc(h.clientAnalyticsOverview)))
	mux.Handle("GET /api/admin/v1/platform/client-analytics/errors/{fingerprint}", platformPerm("platform.overview.read", http.HandlerFunc(h.clientAnalyticsErrorDetail)))
	mux.Handle("POST /api/admin/v1/platform/client-analytics/errors/{fingerprint}/archive", platformPerm("platform.client_analytics.manage_errors", http.HandlerFunc(h.clientAnalyticsArchiveError)))
	mux.Handle("POST /api/admin/v1/platform/client-analytics/errors/{fingerprint}/unarchive", platformPerm("platform.client_analytics.manage_errors", http.HandlerFunc(h.clientAnalyticsUnarchiveError)))
	if h.TenantIDP != nil {
		mux.Handle("GET /api/admin/v1/tenant/identity-providers",
			tenantPerm("tenant.identity_provider.read", http.HandlerFunc(h.listTenantIDP)))
		if h.SecretSealer != nil {
			mux.Handle("POST /api/admin/v1/tenant/identity-providers",
				tenantPerm("tenant.identity_provider.create", http.HandlerFunc(h.createTenantIDP)))
			mux.Handle("PATCH /api/admin/v1/tenant/identity-providers/{uuid}",
				tenantPerm("tenant.identity_provider.update", http.HandlerFunc(h.patchTenantIDP)))
			mux.Handle("DELETE /api/admin/v1/tenant/identity-providers/{uuid}",
				tenantPerm("tenant.identity_provider.delete", http.HandlerFunc(h.deleteTenantIDP)))
		}
	}

	if h.Agent != nil {
		mux.Handle("GET /api/admin/v1/platform/agent-model-options", platformPerm("platform.preset_agent.read", http.HandlerFunc(h.listAgentModelOptions)))
		mux.Handle("GET /api/admin/v1/platform/preset-agents", platformPerm("platform.preset_agent.read", http.HandlerFunc(h.listPlatformPresetAgents)))
		mux.Handle("POST /api/admin/v1/platform/preset-agents", platformPerm("platform.preset_agent.create", http.HandlerFunc(h.createPlatformPresetAgent)))
		mux.Handle("GET /api/admin/v1/platform/preset-agents/{uuid}", platformPerm("platform.preset_agent.read", http.HandlerFunc(h.getPlatformPresetAgent)))
		mux.Handle("PUT /api/admin/v1/platform/preset-agents/{uuid}", platformPerm("platform.preset_agent.update", http.HandlerFunc(h.updatePlatformPresetAgent)))
		mux.Handle("DELETE /api/admin/v1/platform/preset-agents/{uuid}", platformPerm("platform.preset_agent.delete", http.HandlerFunc(h.deletePlatformPresetAgent)))
		mux.Handle("POST /api/admin/v1/platform/preset-agents/{uuid}/publish", platformPerm("platform.preset_agent.publish", http.HandlerFunc(h.publishPlatformPresetAgent)))
		mux.Handle("POST /api/admin/v1/platform/preset-agents/{uuid}/unpublish", platformPerm("platform.preset_agent.publish", http.HandlerFunc(h.unpublishPlatformPresetAgent)))
	}

	if h.LocalCodingCatalog != nil {
		// F31 版本目录：复用 platform.client_version.* 权限（同一"平台发布物"家族）。
		mux.Handle("GET /api/admin/v1/platform/local-coding-tool-versions",
			platformPerm("platform.client_version.read", http.HandlerFunc(h.listLocalCodingToolVersions)))
		mux.Handle("POST /api/admin/v1/platform/local-coding-tool-versions",
			platformPerm("platform.client_version.create", http.HandlerFunc(h.createLocalCodingToolVersion)))
		mux.Handle("GET /api/admin/v1/platform/local-coding-tool-versions/{uuid}",
			platformPerm("platform.client_version.read", http.HandlerFunc(h.getLocalCodingToolVersion)))
		mux.Handle("PATCH /api/admin/v1/platform/local-coding-tool-versions/{uuid}",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.patchLocalCodingToolVersion)))
		mux.Handle("POST /api/admin/v1/platform/local-coding-tool-versions/{uuid}/upload-package",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.uploadLocalCodingToolPackage)))
		mux.Handle("POST /api/admin/v1/platform/local-coding-tool-versions/{uuid}/publish",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.publishLocalCodingToolVersion)))
		mux.Handle("POST /api/admin/v1/platform/local-coding-tool-versions/{uuid}/deprecate",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.deprecateLocalCodingToolVersion)))
		mux.Handle("GET /api/admin/v1/platform/local-coding-tool-versions/{uuid}/download-package",
			platformPerm("platform.client_version.read", http.HandlerFunc(h.downloadLocalCodingToolPackage)))
		mux.Handle("POST /api/admin/v1/platform/local-coding-tool-versions/{uuid}/mirror-package",
			platformPerm("platform.client_version.update", http.HandlerFunc(h.mirrorLocalCodingToolPackage)))
		mux.Handle("DELETE /api/admin/v1/platform/local-coding-tool-versions/{uuid}",
			platformPerm("platform.client_version.delete", http.HandlerFunc(h.deleteLocalCodingToolVersion)))
		// 命令行工具版本自动同步（计划 §2.2）：状态只读；「立即检查」会录入并灰度，按新建权限。
		mux.Handle("GET /api/admin/v1/platform/local-coding-tool-auto-sync",
			platformPerm("platform.client_version.read", http.HandlerFunc(h.getLocalCodingAutoSync)))
		mux.Handle("POST /api/admin/v1/platform/local-coding-tool-auto-sync",
			platformPerm("platform.client_version.create", http.HandlerFunc(h.startLocalCodingAutoSync)))
	}
}
