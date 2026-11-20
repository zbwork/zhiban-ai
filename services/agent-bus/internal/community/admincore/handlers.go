// Package admincore adapts the existing admin services without schema changes.
package admincore

import (
	"context"
	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	domdrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	svcclientanalytics "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientanalytics"
	svcclientbuild "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientbuild"
	svcclientversion "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientversion"
	svcdownloadchannel "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/downloadchannel"
	svcemp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/emp"
	svclocalcodingcatalog "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localcodingcatalog"
	svcmarketinglead "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/marketinglead"
	svcruntime "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtime"
	svcsupportfeedback "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/supportfeedback"

	domagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	domapikey "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	domorgwebhook "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orgwebhook"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	authsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
	contactsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contactpolicy"
	cronsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/cron"
	kbsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	mediasvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/media"
	membersvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/membership"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/platform"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/position"
	rbacsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/rbac"
	runtimeenvsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtimeenv"
	typesvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtimetype"
	skillsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
	sysusersvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/sysuser"
	"net/http"
)

type Handlers struct {
	KBProviderRepo          KBProviderRepo
	KBHealthChecker         KBHealthChecker
	KBProviderResolver      interface{ Invalidate(int64) }
	AdminAgentA2AInvoke     *AdminAgentA2AInvokeHandler
	AgentKBBindings         *AgentKBBindingsHandler
	AdminAgentA2ACard       *AdminAgentA2ACardHandler
	App                     domapp.Service
	RuntimeProbe            svcruntime.ProbeService
	ClientBuild             svcclientbuild.Service
	LocalCodingCatalog      svclocalcodingcatalog.Service
	AgentModelOptions       []string
	TenantIDP               TenantIDPStore
	SecretSealer            SecretSealer
	ClientAnalyticsOverview svcclientanalytics.OverviewService
	ClientAnalyticsErrors   svcclientanalytics.ErrorAdminService
	SupportFeedback         svcsupportfeedback.Service
	MarketingLead           svcmarketinglead.Service
	ClientVersion           svcclientversion.Service
	DownloadChannel         svcdownloadchannel.Service
	EMP                     svcemp.Service

	AgentSDK               domagentsdk.Service
	RuntimeChecker         AgentSDKRuntimeChecker
	WuKongStatus           *WuKongStatusHandler
	AdminA2AApprovals      *AdminA2AApprovalHandler
	ApiKey                 domapikey.Service
	Alerts                 *AlertsAdminHandler
	OrgWebhook             domorgwebhook.Service
	SysUser                sysusersvc.Service
	Knowledge              kbsvc.Service
	UserKBInspect          *UserKBInspectHandler
	PlatformType           typesvc.Service
	Observability          *ObservabilityCallLogsHandler
	ObservabilityAgentRuns *ObservabilityAgentRunsHandler
	AdminA2A               *AdminA2AHandler
	AdminOrchestrations    *AdminOrchestrationsHandler
	AdminSpeakerPolicies   *AdminSpeakerPoliciesHandler
	Auth                   authsvc.Service
	ContactPolicy          contactsvc.Service
	Cron                   cronsvc.Service
	Skill                  *skillsvc.Service
	Media                  *mediasvc.Service
	DriveStorage           StorageAdminService
	DriveEffectiveBucket   func(*domdrive.StorageOverride) string
	DriveBrowse            DriveBrowseService
	DriveQuotaAdmin        DriveQuotaAdminService
	DriveRecycleAdmin      DriveRecycleAdminService
	DriveUsageAdmin        DriveUsageAdminService
	DriveWorkersAdmin      DriveWorkersAdminService
	DrivePlatformQuota     DrivePlatformQuotaService
	Audit                  *AuditAdminHandler
	Rooms                  *AdminRoomsHandler
	Membership             membersvc.Service
	Agent                  agentsvc.Service
	Platform               platform.Service
	Position               position.Service
	RBAC                   rbacsvc.Service
	RuntimeEnv             runtimeenvsvc.Service
}

// The shared RBAC service resolves IDs globally. Check ownership before details or mutations.
func (h *Handlers) requireRoleScope(w http.ResponseWriter, r *http.Request, id int64) bool {
	role, err := h.RBAC.GetRole(r.Context(), id)
	if err != nil {
		encode.JSONError(w, err)
		return false
	}
	scope := middleware.ActScope(r.Context())
	allowed := scope == "platform" && role.Role.ScopeKind == "platform"
	if scope == "tenant" || scope == "workspace" {
		allowed = role.Role.ScopeKind == "tenant" && role.Role.TenantID != nil && *role.Role.TenantID == middleware.MustTenantID(r.Context())
	}
	if !allowed {
		encode.JSONError(w, apperr.ErrForbidden)
	}
	return allowed
}

// KBProviderRepo · admin /platform/kb-providers 用窄抽象 (避免直接 import repo).
type KBProviderRepo interface {
	ListProviders(ctx context.Context) ([]domkb.ProviderConfig, error)
	GetProviderByID(ctx context.Context, id int64) (*domkb.ProviderConfig, error)
	UpdateProviderHealth(ctx context.Context, id int64, status, message string) error
}

// KBHealthChecker · admin health-check 真探测 (Codex 第二轮 P1 闭环).
//
// 实现职责:
//  1. 按 providerID 反查 kb_provider_config + settings;
//  2. 通过 Resolver 构造对应 Provider (Stub/Dify);
//  3. Dify: 调其 HealthCheck() (GET /v1/datasets);
//  4. Stub: 视为永远 active;
//  5. 探测成功 → 写 status='active' + message="..."; 失败 → 写 status='degraded' + 错误文本.
//
// 返回最终 status / message 给 handler 用于 JSON 响应.
type KBHealthChecker interface {
	Check(ctx context.Context, providerID int64) (status, message string, err error)
}
