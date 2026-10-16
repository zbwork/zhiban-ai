// internal/middleware/perm.go
//
// RequirePermission 中间件 —— 用于 Admin API 服务端权限闸门。
//
// 设计要点（见 docs/tasks/README.md §D + docs/tasks/m1-identity-and-login.md T1.1）：
//
//   - **仅用于 Admin API**（/api/admin/v1/*）。Bus Client API 不挂；普通员工没有"角色 / 权限点"概念，
//     依赖 Auth + RequireTenant + Service 层数据隔离。
//
//   - perms 集合从 JWT claims 读取（Issue 时已注入 jwt.Claims.Perms），避免每请求查 PG。
//
//   - 校验只看当前 act_scope 下的 perms 集合，不允许跨 scope union。
//
//   - 路由侧用法（M3 / M2 / M1 等任务清单提供完整映射表）：
//
//     mux.Handle("POST /api/admin/v1/tenant/agents/{uuid}/publish",
//     adminAuth(requireTenant(requirePermission("tenant.agent.publish")(http.HandlerFunc(h.publishAgent)))))
//
//   - codes 多个时为 OR：命中任一即放行（用于"读 / 管理"复用同一路由的场景，详见 T1.4 角色 UX 抽象）。
package middleware

import (
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// RequirePermission 返回一个中间件，校验当前请求的 act_scope perms 集合至少命中 codes 中一项。
//
// codes 为空时直接 panic（防止挂错）。codes 全部缺失返回 403 permission_denied，
// 错误信息含被要求的 code 集合，方便前端调试。
func RequirePermission(codes ...string) func(http.Handler) http.Handler {
	if len(codes) == 0 {
		panic("middleware.RequirePermission: codes must not be empty")
	}
	required := make(map[string]struct{}, len(codes))
	for _, c := range codes {
		required[c] = struct{}{}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := Claims(r.Context())
			if !ok || claims == nil {
				encode.JSONError(w, apperr.ErrUnauthorized)
				return
			}
			for _, p := range claims.Perms {
				if _, hit := required[p]; hit {
					next.ServeHTTP(w, r)
					return
				}
			}
			encode.JSONError(w, apperr.ErrForbidden.Withf("permission_denied: requires one of %v", codes))
		})
	}
}

// RequirePasswordValid 拦截 must_change_password=true 的 token 访问业务接口。
//
// 调用方：用于"业务路由 chain"（白名单接口如 /me /auth/password/change /auth/logout 不挂）。
//
// 返回 412 precondition_failed 含错误码 "must_change_password"，admin web 据此跳改密页。
func RequirePasswordValid(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, ok := Claims(r.Context())
		if !ok || c == nil {
			encode.JSONError(w, apperr.ErrUnauthorized)
			return
		}
		if c.MustChange {
			encode.JSONError(w, apperr.ErrForbidden.Withf("must_change_password: change password before accessing business APIs"))
			return
		}
		next.ServeHTTP(w, r)
	})
}
