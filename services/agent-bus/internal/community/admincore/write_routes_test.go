package admincore

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	memory "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/memory/clientbuild"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	buildsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientbuild"
	kbsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
	localsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localcodingcatalog"
	membersvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/membership"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/platform"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/position"
	rbacsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/rbac"
	runtimeenvsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtimeenv"
)

func writeTestMux(t *testing.T, h *Handlers) (*http.ServeMux, *jwt.Issuer) {
	t.Helper()
	priv, _, err := jwt.GenerateDevKeypair()
	if err != nil {
		t.Fatal(err)
	}
	issuer, err := jwt.New(priv, "", "write-test", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	auth := func(next http.Handler) http.Handler {
		return middleware.Auth(issuer, nil, false)(middleware.RequireAdmin(nil)(next))
	}
	guard := func(scope string) func(string, http.Handler) http.Handler {
		return func(code string, next http.Handler) http.Handler {
			next = middleware.RequirePermission(code)(next)
			if scope == "platform" {
				next = middleware.RequirePlatform(next)
			} else {
				next = middleware.RequireTenant(next)
			}
			return auth(middleware.RequirePasswordValid(next))
		}
	}
	mux := http.NewServeMux()
	h.Register(mux, auth, guard("platform"), guard("tenant"))
	return mux, issuer
}

func writeTestCore() *Handlers {
	return &Handlers{Knowledge: struct{ kbsvc.Service }{}, KBProviderRepo: struct{ KBProviderRepo }{}, Membership: struct{ membersvc.Service }{}, Platform: struct{ platform.Service }{}, Position: struct{ position.Service }{}, RBAC: struct{ rbacsvc.Service }{}, RuntimeEnv: struct{ runtimeenvsvc.Service }{}, Agent: struct{ agentsvc.Service }{}, ClientBuild: struct{ buildsvc.Service }{}, LocalCodingCatalog: struct{ localsvc.Service }{}, AdminAgentA2AInvoke: &AdminAgentA2AInvokeHandler{}, AdminAgentA2ACard: &AdminAgentA2ACardHandler{}, AgentKBBindings: &AgentKBBindingsHandler{}}
}

// Exercise real middleware, including the correct permission on the wrong scope.
func TestRestoredWritesRequireAdminScopeAndPermission(t *testing.T) {
	mux, issuer := writeTestMux(t, writeTestCore())
	for _, tc := range []struct{ method, path, scope, permission string }{
		{"POST", "/tenant/knowledge-bases/example/documents/doc/retry", "tenant", "tenant.kb.update"},
		{"POST", "/tenant/knowledge-bases/example/recall-test", "tenant", "tenant.kb.recall"},
		{"POST", "/platform/kb-providers", "platform", "platform.kb_provider.create"},
		{"PATCH", "/platform/kb-providers/example", "platform", "platform.kb_provider.update"},
		{"DELETE", "/platform/kb-providers/example", "platform", "platform.kb_provider.delete"},
		{"POST", "/platform/kb-providers/example/set-default", "platform", "platform.kb_provider.set_default"},
		{"POST", "/platform/client-build-jobs", "platform", "platform.client_version.create"},
		{"POST", "/platform/client-build-jobs/example/retry", "platform", "platform.client_version.create"},
		{"DELETE", "/platform/client-build-jobs/example", "platform", "platform.client_version.update"},
		{"POST", "/platform/preset-agents", "platform", "platform.preset_agent.create"},
		{"PUT", "/platform/preset-agents/example", "platform", "platform.preset_agent.update"},
		{"DELETE", "/platform/preset-agents/example", "platform", "platform.preset_agent.delete"},
		{"POST", "/platform/preset-agents/example/publish", "platform", "platform.preset_agent.publish"},
		{"POST", "/platform/preset-agents/example/unpublish", "platform", "platform.preset_agent.publish"},
		{"PUT", "/platform/preset-agents/example/kb-bindings", "platform", "platform.preset_agent.update"},
		{"PUT", "/platform/preset-agents/example/a2a-card", "platform", "platform.preset_agent.update"},
		{"PUT", "/tenant/agents/example/a2a-card", "tenant", "tenant.agent.update"},
		{"PUT", "/tenant/agents/example/a2a-invoke-capability", "tenant", "tenant.agent.update"},
		{"POST", "/tenant/agents/example/kb-bindings", "tenant", "tenant.agent.update"},
		{"DELETE", "/tenant/agents/example/kb-bindings/kb", "tenant", "tenant.agent.update"},
		{"DELETE", "/platform/runtime-environments/example", "platform", "platform.runtime.delete"},
		{"POST", "/platform/runtimes/example/set-as-default", "platform", "platform.runtime.set_default"},
		{"POST", "/tenant/runtime-environments/probe", "tenant", "tenant.runtime_env.probe"},
		{"POST", "/tenant/runtime-environments/enablements", "tenant", "tenant.runtime_env.enable"},
		{"DELETE", "/tenant/runtime-environments/enablements/example", "tenant", "tenant.runtime_env.enable"},
		{"POST", "/tenant/runtime-environments/enablements/example/set-default", "tenant", "tenant.runtime_env.set_default"},
		{"POST", "/tenant/runtime-environments/custom", "tenant", "tenant.runtime_env.create"},
		{"PATCH", "/tenant/runtime-environments/custom/example", "tenant", "tenant.runtime_env.update"},
		{"DELETE", "/tenant/runtime-environments/custom/example", "tenant", "tenant.runtime_env.delete"},
		{"POST", "/platform/local-coding-tool-versions", "platform", "platform.client_version.create"},
		{"PATCH", "/platform/local-coding-tool-versions/example", "platform", "platform.client_version.update"},
		{"POST", "/platform/local-coding-tool-versions/example/upload-package", "platform", "platform.client_version.update"},
		{"POST", "/platform/local-coding-tool-versions/example/publish", "platform", "platform.client_version.update"},
		{"POST", "/platform/local-coding-tool-versions/example/deprecate", "platform", "platform.client_version.update"},
		{"POST", "/platform/local-coding-tool-versions/example/mirror-package", "platform", "platform.client_version.update"},
		{"DELETE", "/platform/local-coding-tool-versions/example", "platform", "platform.client_version.delete"},
		{"POST", "/platform/local-coding-tool-auto-sync", "platform", "platform.client_version.create"},
	} {
		t.Run(tc.method+tc.path, func(t *testing.T) {
			for _, mode := range []string{"anonymous", "missing_permission", "wrong_scope", "member", "must_change"} {
				req := httptest.NewRequest(tc.method, "/api/admin/v1"+tc.path, strings.NewReader("{}"))
				want := http.StatusForbidden
				if mode == "anonymous" {
					want = http.StatusUnauthorized
				} else {
					scope := tc.scope
					perms := []string{tc.permission}
					if mode == "missing_permission" {
						perms = nil
					}
					if mode == "wrong_scope" {
						if scope == "tenant" {
							scope = "platform"
						} else {
							scope = "tenant"
						}
					}
					token, err := issuer.Issue(jwt.IssueOptions{AccountID: 5, ActScope: scope, ActTenantID: 10, Admin: mode != "member", MustChange: mode == "must_change", Perms: perms})
					if err != nil {
						t.Fatal(err)
					}
					req.Header.Set("Authorization", "Bearer "+token)
				}
				w := httptest.NewRecorder()
				mux.ServeHTTP(w, req)
				if w.Code != want {
					t.Fatalf("mode=%s status=%d want=%d body=%s", mode, w.Code, want, w.Body.String())
				}
			}
		})
	}
}

func TestBuildCreateWithoutRunnerDoesNotQueueJob(t *testing.T) {
	h := writeTestCore()
	h.ClientBuild = buildsvc.New(context.Background(), memory.New(), buildsvc.Config{})
	mux, issuer := writeTestMux(t, h)
	token, err := issuer.Issue(jwt.IssueOptions{AccountID: 5, ActScope: "platform", Admin: true, Perms: []string{"platform.client_version.read", "platform.client_version.create"}})
	if err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{`{}`, `{"platform":"macos","arch":"arm64","version":"1.0.0","build_number":"10000"}`} {
		req := httptest.NewRequest("POST", "/api/admin/v1/platform/client-build-jobs", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if body == "{}" && w.Code != 400 {
			t.Fatalf("invalid input status=%d body=%s", w.Code, w.Body.String())
		}
		if body != "{}" && (w.Code != 502 || !strings.Contains(w.Body.String(), "client_build.runner_not_configured")) {
			t.Fatalf("missing runner status=%d body=%s", w.Code, w.Body.String())
		}
	}
	req := httptest.NewRequest("GET", "/api/admin/v1/platform/client-build-jobs", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	var body struct {
		Data struct {
			Total int
			Items []json.RawMessage
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || body.Data.Total != 0 || len(body.Data.Items) != 0 {
		t.Fatalf("unexpected jobs: %s", w.Body.String())
	}
}
