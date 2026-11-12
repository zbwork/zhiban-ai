package admincore

import (
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
)

// Register preserves the original admin URLs and permission codes.
func (h *Handlers) Register(mux *http.ServeMux, adminAuth func(http.Handler) http.Handler, platformPerm, tenantPerm func(string, http.Handler) http.Handler) {
	h.registerPages(mux, adminAuth, platformPerm, tenantPerm)
	if h.Platform == nil || h.Position == nil || h.RBAC == nil || h.RuntimeEnv == nil || h.Agent == nil || h.Membership == nil {
		panic("community admin core dependencies required")
	}
	for _, route := range []struct {
		pattern string
		perm    string
		handler http.HandlerFunc
	}{
		{"GET /api/admin/v1/platform/stats", "platform.overview.read", h.platformStats},
		{"GET /api/admin/v1/platform/overview", "platform.overview.read", h.platformOverview},
		{"GET /api/admin/v1/platform/runtime-environments", "platform.runtime.read", h.listPlatformRuntimeEnvs},
		{"DELETE /api/admin/v1/platform/runtime-environments/{uuid}", "platform.runtime.delete", h.deletePlatformRuntimeEnv},
		{"POST /api/admin/v1/platform/runtimes/{uuid}/set-as-default", "platform.runtime.set_default", h.setPlatformDefault},
		{"GET /api/admin/v1/platform/roles", "platform.role.read", h.listPlatformRoles},
		{"POST /api/admin/v1/platform/roles", "platform.role.create", h.createPlatformRole},
		{"GET /api/admin/v1/platform/roles/{id}", "platform.role.read", h.getRole},
		{"PUT /api/admin/v1/platform/roles/{id}", "platform.role.update", h.updateRole},
		{"DELETE /api/admin/v1/platform/roles/{id}", "platform.role.delete", h.deleteRole},
		{"GET /api/admin/v1/platform/menus", "platform.menu.read", h.listAllMenus},
		{"POST /api/admin/v1/platform/menus", "platform.menu.create", h.createMenu},
		{"GET /api/admin/v1/platform/menus/{id}", "platform.menu.read", h.getMenu},
		{"PUT /api/admin/v1/platform/menus/{id}", "platform.menu.update", h.updateMenu},
		{"DELETE /api/admin/v1/platform/menus/{id}", "platform.menu.delete", h.deleteMenu},
	} {
		mux.Handle(route.pattern, platformPerm(route.perm, route.handler))
	}
	for _, route := range []struct {
		pattern string
		perm    string
		handler http.HandlerFunc
	}{
		{"GET /api/admin/v1/tenant/stats", "tenant.overview.read", h.tenantStats},
		{"GET /api/admin/v1/tenant/overview", "tenant.overview.read", h.tenantOverview},
		{"GET /api/admin/v1/tenant/conversations", "tenant.audit.read", h.recentConvos},
		{"GET /api/admin/v1/tenant/runtime-environments", "tenant.runtime_env.read", h.listTenantRuntimeEnvs},
		{"POST /api/admin/v1/tenant/runtime-environments/probe", "tenant.runtime_env.probe", h.tenantProbe},
		{"POST /api/admin/v1/tenant/runtime-environments/enablements", "tenant.runtime_env.enable", h.enableTenantRuntime},
		{"DELETE /api/admin/v1/tenant/runtime-environments/enablements/{uuid}", "tenant.runtime_env.enable", h.disableTenantRuntime},
		{"POST /api/admin/v1/tenant/runtime-environments/enablements/{uuid}/set-default", "tenant.runtime_env.set_default", h.setTenantEnablementDefault},
		{"POST /api/admin/v1/tenant/runtime-environments/custom", "tenant.runtime_env.create", h.createTenantCustomEnv},
		{"PATCH /api/admin/v1/tenant/runtime-environments/custom/{uuid}", "tenant.runtime_env.update", h.patchTenantCustomEnv},
		{"DELETE /api/admin/v1/tenant/runtime-environments/custom/{uuid}", "tenant.runtime_env.delete", h.deleteTenantCustomEnv},
		{"GET /api/admin/v1/tenant/positions", "tenant.position.read", h.listPositions},
		{"POST /api/admin/v1/tenant/positions", "tenant.position.create", h.createPosition},
		{"GET /api/admin/v1/tenant/positions/{id}", "tenant.position.read", h.getPosition},
		{"PATCH /api/admin/v1/tenant/positions/{id}", "tenant.position.update", h.updatePosition},
		{"DELETE /api/admin/v1/tenant/positions/{id}", "tenant.position.delete", h.deletePosition},
		{"GET /api/admin/v1/tenant/members/{id}/positions", "tenant.position.read", h.listMemberPositions},
		{"PUT /api/admin/v1/tenant/members/{id}/positions", "tenant.position.assign", h.assignMemberPositions},
		{"GET /api/admin/v1/tenant/agents/{id}/positions", "tenant.position.read", h.listAgentPositions},
		{"GET /api/admin/v1/tenant/members/{id}/roles", "tenant.role.read", h.listMemberRoles},
		{"POST /api/admin/v1/tenant/members/{id}/roles", "tenant.role.update", h.assignMemberRole},
		{"DELETE /api/admin/v1/tenant/members/{id}/roles/{roleId}", "tenant.role.update", h.revokeMemberRole},
		{"GET /api/admin/v1/tenant/roles", "tenant.role.read", h.listTenantRoles},
		{"POST /api/admin/v1/tenant/roles", "tenant.role.create", h.createTenantRole},
		{"GET /api/admin/v1/tenant/roles/{id}", "tenant.role.read", h.getRole},
		{"PUT /api/admin/v1/tenant/roles/{id}", "tenant.role.update", h.updateRole},
		{"DELETE /api/admin/v1/tenant/roles/{id}", "tenant.role.delete", h.deleteRole},
	} {
		mux.Handle(route.pattern, tenantPerm(route.perm, route.handler))
	}
	mux.Handle("PUT /api/admin/v1/tenant/agents/{id}/positions", tenantPerm("tenant.position.assign", h.requireTenantEditableAgent(http.HandlerFunc(h.assignAgentPositions))))
	mux.Handle("GET /api/admin/v1/permissions", adminAuth(middleware.RequirePasswordValid(middleware.RequirePermission("platform.role.read", "tenant.role.read")(http.HandlerFunc(h.listPermissions)))))
}
