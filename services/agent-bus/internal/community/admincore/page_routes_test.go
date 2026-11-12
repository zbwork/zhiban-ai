package admincore

import (
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	svcclientanalytics "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientanalytics"
	svcclientbuild "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientbuild"
	svcclientversion "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientversion"
	svcdownloadchannel "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/downloadchannel"
	svcemp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/emp"
	localsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localcodingcatalog"
	svcmarketinglead "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/marketinglead"
	svcsupportfeedback "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/supportfeedback"

	"context"
	domapproval "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2aapproval"
	domagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	domapikey "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	domorgwebhook "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/orgwebhook"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	svca2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/a2a"
	kbsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	mediasvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/media"
	typesvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtimetype"
	sysusersvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/sysuser"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	authsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/auth"
	contactsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contactpolicy"
	cronsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/cron"
	skillsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
)

// Register all modules together: ServeMux rejects ambiguous wildcard patterns at startup.
func TestPageModulesRegisterTogetherAndRequireAuthorization(t *testing.T) {
	h := &Handlers{KBProviderRepo: struct{ KBProviderRepo }{}, AdminAgentA2AInvoke: &AdminAgentA2AInvokeHandler{}, AdminAgentA2ACard: &AdminAgentA2ACardHandler{}, AgentKBBindings: &AgentKBBindingsHandler{}, ClientBuild: struct{ svcclientbuild.Service }{}, LocalCodingCatalog: struct{ localsvc.Service }{}, Agent: struct{ agentsvc.Service }{},
		SupportFeedback: struct{ svcsupportfeedback.Service }{}, MarketingLead: struct{ svcmarketinglead.Service }{}, ClientVersion: struct{ svcclientversion.Service }{}, DownloadChannel: struct{ svcdownloadchannel.Service }{},
		EMP: struct{ svcemp.Service }{}, TenantIDP: struct{ TenantIDPStore }{}, ClientAnalyticsOverview: struct {
			svcclientanalytics.OverviewService
		}{}, ClientAnalyticsErrors: struct {
			svcclientanalytics.ErrorAdminService
		}{},
		Knowledge: struct{ kbsvc.Service }{}, SysUser: struct{ sysusersvc.Service }{}, PlatformType: typesvc.New(), Media: &mediasvc.Service{},
		ApiKey: struct{ domapikey.Service }{}, AgentSDK: struct{ domagentsdk.Service }{}, OrgWebhook: struct{ domorgwebhook.Service }{}, Alerts: &AlertsAdminHandler{}, WuKongStatus: &WuKongStatusHandler{},
		Observability: &ObservabilityCallLogsHandler{}, ObservabilityAgentRuns: &ObservabilityAgentRunsHandler{},
		AdminA2A: &AdminA2AHandler{}, AdminOrchestrations: &AdminOrchestrationsHandler{}, AdminSpeakerPolicies: &AdminSpeakerPoliciesHandler{}, AdminA2AApprovals: &AdminA2AApprovalHandler{},
		Auth: struct{ authsvc.Service }{}, ContactPolicy: struct{ contactsvc.Service }{},
		Cron: struct{ cronsvc.Service }{}, Skill: skillsvc.New(nil),
		DriveStorage: struct{ StorageAdminService }{}, DriveBrowse: struct{ DriveBrowseService }{},
		DriveQuotaAdmin: struct{ DriveQuotaAdminService }{}, DriveRecycleAdmin: struct{ DriveRecycleAdminService }{},
		DriveUsageAdmin: struct{ DriveUsageAdminService }{}, DriveWorkersAdmin: struct{ DriveWorkersAdminService }{},
		DrivePlatformQuota: struct{ DrivePlatformQuotaService }{}, Audit: &AuditAdminHandler{}, Rooms: &AdminRoomsHandler{},
	}
	mux := http.NewServeMux()
	priv, _, err := jwt.GenerateDevKeypair()
	if err != nil {
		t.Fatal(err)
	}
	issuer, err := jwt.New(priv, "", "page-test", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	auth := func(next http.Handler) http.Handler {
		return middleware.Auth(issuer, nil, false)(middleware.RequireAdmin(nil)(next))
	}
	perm := func(scope string) func(string, http.Handler) http.Handler {
		return func(code string, next http.Handler) http.Handler {
			next = middleware.RequirePermission(code)(next)
			if scope == "tenant" {
				next = middleware.RequireTenant(next)
			} else {
				next = middleware.RequirePlatform(next)
			}
			return auth(middleware.RequirePasswordValid(next))
		}
	}
	h.registerPages(mux, auth, perm("platform"), perm("tenant"))
	for _, path := range []string{
		"/platform/kb-providers", "/tenant/agents/example/a2a-card", "/tenant/agents/example/a2a-invoke-capability", "/tenant/agents/example/kb-bindings", "/platform/preset-agents/example/a2a-card", "/platform/preset-agents/example/kb-bindings", "/platform/client-build-jobs", "/platform/local-coding-tool-versions", "/platform/local-coding-tool-auto-sync", "/platform/preset-agents", "/platform/agent-model-options", "/tenant/identity-providers", "/platform/emp-blocks", "/platform/support-feedback", "/platform/marketing-leads", "/platform/client-versions", "/platform/download-channels", "/platform/share-growth", "/platform/client-analytics/overview",
		"/tenant/knowledge-bases", "/platform/knowledge-bases", "/tenant/org-webhooks", "/tenant/api-keys", "/platform/sys-users",
		"/tenant/agent-sdk-credentials", "/platform/agent-sdk-credentials", "/platform/wukong/overview", "/platform/wukong/connections",
		"/tenant/alerts", "/platform/alerts", "/tenant/a2a/approvals", "/tenant/a2a", "/tenant/orchestrations", "/tenant/speaker-policies",
		"/tenant/observability/agent-runs", "/platform/observability/conversations", "/tenant/observability/call-logs",
		"/tenant/skills", "/platform/skills", "/platform/skill-categories", "/tenant/contact-policy",
		"/tenant/drive/spaces", "/tenant/drive/quotas", "/tenant/drive/recycle", "/platform/drive/workers",
		"/tenant/cron-jobs", "/tenant/cron-prompt-templates", "/tenant/audit-events", "/platform/audit-summary", "/tenant/rooms", "/me/sessions",
	} {
		t.Run(path, func(t *testing.T) {
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/admin/v1"+path, nil))
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
			if path == "/me/sessions" {
				return
			}
			for _, scope := range []string{"platform", "tenant"} {
				token, err := issuer.Issue(jwt.IssueOptions{AccountID: 5, ActScope: scope, ActTenantID: 10, Admin: true})
				if err != nil {
					t.Fatal(err)
				}
				r := httptest.NewRequest("GET", "/api/admin/v1"+path, nil)
				r.Header.Set("Authorization", "Bearer "+token)
				w := httptest.NewRecorder()
				mux.ServeHTTP(w, r)
				if w.Code != http.StatusForbidden {
					t.Fatalf("scope=%s status=%d body=%s", scope, w.Code, w.Body.String())
				}
			}
		})
	}
}

type approvalReadStub struct{ AdminA2AApprovalService }

func (approvalReadStub) ListApprovalViewsForAdmin(context.Context, int64, domapproval.Status, int, int) ([]svca2a.ApprovalView, int, error) {
	return nil, 0, nil
}

// A literal approval path must win over the A2A edge wildcard.
func TestApprovalListDoesNotMatchEdgeDetail(t *testing.T) {
	mux := http.NewServeMux()
	h := &Handlers{AdminA2A: &AdminA2AHandler{}, AdminA2AApprovals: &AdminA2AApprovalHandler{Service: approvalReadStub{}}}
	pass := func(next http.Handler) http.Handler { return next }
	perm := func(_ string, next http.Handler) http.Handler { return next }
	h.registerPages(mux, pass, perm, perm)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/admin/v1/tenant/a2a/approvals", nil))
	if w.Code != 200 {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}
