package admincore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	domrbac "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/rbac"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
	membersvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/membership"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/platform"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/position"
	rbacsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/rbac"
	runtimeenvsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtimeenv"
)

type platformStub struct{ platform.Service }

func (platformStub) PlatformStats(context.Context) (*platform.PlatformStats, error) {
	return &platform.PlatformStats{Tenants: 2}, nil
}

type positionStub struct{ position.Service }

func (positionStub) List(_ context.Context, tenantID int64, _ string, _, _ int) ([]position.Position, int64, error) {
	return []position.Position{{ID: 7, TenantID: tenantID}}, 1, nil
}

type rbacStub struct{ rbacsvc.Service }

func (rbacStub) GetRole(_ context.Context, id int64) (*rbacsvc.RoleWithPerms, error) {
	tenantID := int64(10)
	if id == 2 {
		tenantID = 20
	}
	role := &domrbac.Role{ID: id, ScopeKind: "tenant", TenantID: &tenantID}
	if id == 3 {
		role.ScopeKind, role.TenantID = "platform", nil
	}
	return &rbacsvc.RoleWithPerms{Role: role}, nil
}

type membershipStub struct{ membersvc.Service }

func (membershipStub) Get(_ context.Context, tenantID, membershipID int64) (*membersvc.Member, error) {
	return &membersvc.Member{MembershipID: membershipID, AccountID: 5}, nil
}

func TestCoreRoutesAuthorizationAndRoleIsolation(t *testing.T) {
	priv, _, err := jwt.GenerateDevKeypair()
	if err != nil {
		t.Fatal(err)
	}
	issuer, err := jwt.New(priv, "", "core-test", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	adminAuth := func(next http.Handler) http.Handler {
		return middleware.Auth(issuer, nil, false)(middleware.RequireAdmin(nil)(next))
	}
	platformPerm := func(code string, next http.Handler) http.Handler {
		return adminAuth(middleware.RequirePasswordValid(middleware.RequirePlatform(middleware.RequirePermission(code)(next))))
	}
	tenantPerm := func(code string, next http.Handler) http.Handler {
		return adminAuth(middleware.RequirePasswordValid(middleware.RequireTenant(middleware.RequirePermission(code)(next))))
	}
	h := &Handlers{Membership: membershipStub{}, Platform: platformStub{}, Position: positionStub{}, RBAC: rbacStub{}, RuntimeEnv: struct{ runtimeenvsvc.Service }{}, Agent: struct{ agentsvc.Service }{}}
	h.Register(mux, adminAuth, platformPerm, tenantPerm)
	for _, tc := range []struct {
		name, method, path, scope, permission string
		admin, mustChange, anonymous          bool
		want                                  int
	}{
		{"anonymous employee create", "POST", "/tenant/agents", "tenant", "tenant.agent.create", true, false, true, 401},
		{"ordinary member employee create", "POST", "/tenant/agents", "tenant", "tenant.agent.create", false, false, false, 403},
		{"missing employee write permission", "PUT", "/tenant/agents/test", "tenant", "tenant.agent.read", true, false, false, 403},
		{"wrong employee scope", "POST", "/tenant/agents", "platform", "tenant.agent.create", true, false, false, 403},
		{"anonymous overview", "GET", "/platform/overview", "platform", "platform.overview.read", true, false, true, 401},
		{"ordinary member", "GET", "/tenant/positions", "tenant", "tenant.position.read", false, false, false, 403},
		{"missing permission", "GET", "/tenant/positions", "tenant", "", true, false, false, 403},
		{"platform cannot use tenant path", "GET", "/tenant/positions", "platform", "tenant.position.read", true, false, false, 403},
		{"tenant cannot use platform path", "GET", "/platform/menus", "tenant", "platform.menu.read", true, false, false, 403},
		{"password gate", "GET", "/permissions", "tenant", "tenant.role.read", true, true, false, 403},
		{"runtime permission", "GET", "/tenant/runtime-environments", "tenant", "", true, false, false, 403},
		{"platform stats", "GET", "/platform/stats", "platform", "platform.overview.read", true, false, false, 200},
		{"positions", "GET", "/tenant/positions", "tenant", "tenant.position.read", true, false, false, 200},
		{"own role", "GET", "/tenant/roles/1", "tenant", "tenant.role.read", true, false, false, 200},
		{"other tenant role read", "GET", "/tenant/roles/2", "tenant", "tenant.role.read", true, false, false, 403},
		{"other tenant role update", "PUT", "/tenant/roles/2", "tenant", "tenant.role.update", true, false, false, 403},
		{"other tenant role delete", "DELETE", "/tenant/roles/2", "tenant", "tenant.role.delete", true, false, false, 403},
		{"cannot revoke other tenant role", "DELETE", "/tenant/members/1/roles/2", "tenant", "tenant.role.update", true, false, false, 403},
		{"cannot revoke platform role", "DELETE", "/tenant/members/1/roles/3", "tenant", "tenant.role.update", true, false, false, 403},
		{"tenant cannot read platform role", "GET", "/tenant/roles/3", "tenant", "tenant.role.read", true, false, false, 403},
		{"platform cannot read tenant role", "GET", "/platform/roles/1", "platform", "platform.role.read", true, false, false, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, "/api/admin/v1"+tc.path, nil)
			if !tc.anonymous {
				token, err := issuer.Issue(jwt.IssueOptions{AccountID: 5, ActScope: tc.scope, ActTenantID: 10, Admin: tc.admin, MustChange: tc.mustChange, Perms: []string{tc.permission}})
				if err != nil {
					t.Fatal(err)
				}
				r.Header.Set("Authorization", "Bearer "+token)
			}
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Fatalf("status=%d want=%d body=%s", w.Code, tc.want, w.Body.String())
			}
		})
	}
}
