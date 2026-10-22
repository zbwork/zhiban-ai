// Package adminrouter registers the community administrator API without private HTTP packages.
package adminrouter

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminapps"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminorg"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/adminsession"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/admintenant"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/communityagent"
	"net/http"
)

type Handlers struct {
	Apps    *adminapps.Handlers
	Session *adminsession.Handlers
	Tenant  *admintenant.Handlers
	Org     *adminorg.Handlers
	Agents  *communityagent.Handlers
}

func (h Handlers) Register(mux *http.ServeMux, authMw func(http.Handler) http.Handler) {
	if authMw == nil || h.Session == nil || h.Tenant == nil || h.Org == nil {
		panic("community admin dependencies required")
	}
	adminAuth := func(handler http.Handler) http.Handler { return authMw(middleware.RequireAdmin(nil)(handler)) }
	platformPerm := func(code string, handler http.Handler) http.Handler {
		return adminAuth(middleware.RequirePasswordValid(middleware.RequirePlatform(middleware.RequirePermission(code)(handler))))
	}
	tenantPerm := func(code string, handler http.Handler) http.Handler {
		return adminAuth(middleware.RequirePasswordValid(middleware.RequireTenant(middleware.RequirePermission(code)(handler))))
	}
	if h.Apps != nil {
		h.Apps.Register(mux, tenantPerm)
	}
	if h.Agents != nil {
		mux.Handle("GET /api/admin/v1/tenant/agents", tenantPerm("tenant.agent.read", http.HandlerFunc(h.Agents.List)))
		mux.Handle("POST /api/admin/v1/tenant/agents", tenantPerm("tenant.agent.create", http.HandlerFunc(h.Agents.Create)))
		mux.Handle("GET /api/admin/v1/tenant/agents/{uuid}", tenantPerm("tenant.agent.read", http.HandlerFunc(h.Agents.Get)))
		mux.Handle("PUT /api/admin/v1/tenant/agents/{uuid}", tenantPerm("tenant.agent.update", http.HandlerFunc(h.Agents.Update)))
		mux.Handle("DELETE /api/admin/v1/tenant/agents/{uuid}", tenantPerm("tenant.agent.delete", http.HandlerFunc(h.Agents.Delete)))
		mux.Handle("POST /api/admin/v1/tenant/agents/{uuid}/publish", tenantPerm("tenant.agent.publish", http.HandlerFunc(h.Agents.Publish)))
		mux.Handle("GET /api/admin/v1/tenant/agent-model-options", tenantPerm("tenant.agent.read", http.HandlerFunc(h.Agents.ModelOptions)))
	}
	mux.HandleFunc("POST /api/admin/v1/auth/login", h.Session.LoginPassword)
	mux.HandleFunc("POST /api/admin/v1/auth/login/password", h.Session.LoginPassword)
	mux.HandleFunc("GET  /api/admin/v1/auth/captcha", h.Session.Captcha)
	mux.HandleFunc("POST /api/admin/v1/auth/token/refresh", h.Session.Refresh)
	mux.Handle("POST /api/admin/v1/auth/logout", adminAuth(http.HandlerFunc(h.Session.Logout)))
	mux.Handle("POST /api/admin/v1/auth/scope/switch", adminAuth(http.HandlerFunc(h.Session.SwitchScope)))
	mux.Handle("POST /api/admin/v1/auth/password/change", adminAuth(http.HandlerFunc(h.Session.ChangePassword)))
	mux.Handle("GET /api/admin/v1/me", adminAuth(http.HandlerFunc(h.Session.Me)))
	mux.Handle("GET /api/admin/v1/me/menus", adminAuth(http.HandlerFunc(h.Session.Menus)))
	mux.Handle("GET /api/admin/v1/me/permissions", adminAuth(http.HandlerFunc(h.Session.Permissions)))
	mux.Handle("GET /api/admin/v1/platform/tenants", platformPerm("platform.tenant.read", http.HandlerFunc(h.Tenant.ListTenants)))
	mux.Handle("POST /api/admin/v1/platform/tenants", platformPerm("platform.tenant.create", http.HandlerFunc(h.Tenant.CreateTenant)))
	mux.Handle("GET /api/admin/v1/platform/tenants/{id}", platformPerm("platform.tenant.read", http.HandlerFunc(h.Tenant.GetTenant)))
	mux.Handle("PUT /api/admin/v1/platform/tenants/{id}", platformPerm("platform.tenant.update", http.HandlerFunc(h.Tenant.UpdateTenant)))
	mux.Handle("DELETE /api/admin/v1/platform/tenants/{id}", platformPerm("platform.tenant.suspend", http.HandlerFunc(h.Tenant.DeleteTenant)))
	mux.Handle("GET /api/admin/v1/tenant/members", tenantPerm("tenant.member.read", http.HandlerFunc(h.Org.ListMembers)))
	mux.Handle("GET /api/admin/v1/tenant/members/{id}", tenantPerm("tenant.member.read", http.HandlerFunc(h.Org.GetMember)))
	mux.Handle("PUT /api/admin/v1/tenant/members/{id}", tenantPerm("tenant.member.update", http.HandlerFunc(h.Org.UpdateMember)))
	mux.Handle("DELETE /api/admin/v1/tenant/members/{id}", tenantPerm("tenant.member.remove", http.HandlerFunc(h.Org.RemoveMember)))
	mux.Handle("PATCH /api/admin/v1/tenant/members/{id}/contact-fields", tenantPerm("tenant.member.update", http.HandlerFunc(h.Org.PatchMemberContactFields)))
	mux.Handle("GET /api/admin/v1/tenant/departments", tenantPerm("tenant.department.read", http.HandlerFunc(h.Org.ListDepartments)))
	mux.Handle("POST /api/admin/v1/tenant/departments", tenantPerm("tenant.department.create", http.HandlerFunc(h.Org.CreateDepartment)))
	mux.Handle("GET /api/admin/v1/tenant/departments/{id}", tenantPerm("tenant.department.read", http.HandlerFunc(h.Org.GetDepartment)))
	mux.Handle("PUT /api/admin/v1/tenant/departments/{id}", tenantPerm("tenant.department.update", http.HandlerFunc(h.Org.UpdateDepartment)))
	mux.Handle("DELETE /api/admin/v1/tenant/departments/{id}", tenantPerm("tenant.department.delete", http.HandlerFunc(h.Org.DeleteDepartment)))
}
