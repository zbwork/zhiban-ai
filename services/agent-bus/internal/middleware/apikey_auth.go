// apikey_auth.go — F01 §3.5 外部 API Key 鉴权中间件。
//
// 与 Auth (JWT) 完全分离:
//   - JWT 用 ctxAccountID/ctxTenantID/ctxClaims (人会话, 短期)
//   - API Key 用 ctxAPIKeyID/ctxAPIKeyTenantID/ctxAPIKeyScopes (机器长期凭证)
//
// 不复用 perm.RequirePermission, 而是新写 RequireApiKeyScope — API Key 不带 RBAC perms,
// 只有自带的 scopes 白名单 (kb.read / drive.read / ...)。
package middleware

import (
	"context"
	"net/http"
	"strings"

	domapikey "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ApiKeyValidator 中间件依赖的最小接口; 满足 service/apikey.Service。
type ApiKeyValidator interface {
	Validate(ctx context.Context, raw string) (*domapikey.Identity, error)
}

// 单独的 ctxKey 命名空间, 不复用 JWT 的 ctxAccountID/ctxTenantID。
type apiKeyCtxKey int

const (
	ctxAPIKeyID apiKeyCtxKey = iota
	ctxAPIKeyTenantID
	ctxAPIKeyCreator
	ctxAPIKeyScopes
)

// APIKeyAuth 解析 `Authorization: Bearer ek_<prefix>_<secret>`, 调 validator,
// 把 (id, tenantID, scopes) 写入 ctx。失败返 401 (统一不区分原因)。
//
// 调用方: 仅挂在 /api/external/v1/* 路由前; 不要挂在 /api/agent-bus/v1 或 /api/admin/v1。
func APIKeyAuth(validator ApiKeyValidator) func(http.Handler) http.Handler {
	if validator == nil {
		panic("middleware.APIKeyAuth: validator must not be nil")
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw := extractAPIKey(r)
			if raw == "" {
				encode.JSONError(w, apperr.ErrUnauthorized.Withf("missing api key"))
				return
			}
			id, err := validator.Validate(r.Context(), raw)
			if err != nil {
				encode.JSONError(w, err) // service 已包成 ErrUnauthorized
				return
			}
			ctx := r.Context()
			ctx = context.WithValue(ctx, ctxAPIKeyID, id.APIKeyID)
			ctx = context.WithValue(ctx, ctxAPIKeyTenantID, id.TenantID)
			ctx = context.WithValue(ctx, ctxAPIKeyCreator, id.CreatorID)
			ctx = context.WithValue(ctx, ctxAPIKeyScopes, id.Scopes)
			setInternalIdentityHeaders(r, id.TenantID, id.CreatorID)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// RequireApiKeyScope 校验当前请求的 API Key scope 集合至少含给定 scope。
// 与 RequirePermission (JWT) 设计对称; 但读取的是 API Key 的 scopes, 不是 RBAC perms。
func RequireApiKeyScope(scope string) func(http.Handler) http.Handler {
	if scope == "" {
		panic("middleware.RequireApiKeyScope: scope must not be empty")
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			scopes := APIKeyScopes(r.Context())
			if !domapikey.HasScope(scopes, scope) {
				encode.JSONError(w, apperr.ErrForbidden.Withf("scope_denied: requires %q", scope))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// APIKeyTenantID 取当前 API Key 关联的租户 ID (0 = 无 API Key)。
func APIKeyTenantID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxAPIKeyTenantID).(int64)
	return v
}

// APIKeyScopes 取当前 API Key 的 scopes (nil 安全)。
func APIKeyScopes(ctx context.Context) []string {
	v, _ := ctx.Value(ctxAPIKeyScopes).([]string)
	return v
}

// APIKeyID 取当前 API Key 主键 ID (供 audit / rate-limit 用)。
func APIKeyID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxAPIKeyID).(int64)
	return v
}

// APIKeyCreatorID 取 api_keys.creator_id 快照, 业务层做 visibility=private KB 时当 acting account。
func APIKeyCreatorID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxAPIKeyCreator).(int64)
	return v
}

// ContextWithAPIKeyForTest 仅供测试; 绕过 Validator 直接注入身份。
func ContextWithAPIKeyForTest(ctx context.Context, apiKeyID, tenantID, creatorID int64, scopes []string) context.Context {
	ctx = context.WithValue(ctx, ctxAPIKeyID, apiKeyID)
	ctx = context.WithValue(ctx, ctxAPIKeyTenantID, tenantID)
	ctx = context.WithValue(ctx, ctxAPIKeyCreator, creatorID)
	ctx = context.WithValue(ctx, ctxAPIKeyScopes, append([]string(nil), scopes...))
	return ctx
}

// extractAPIKey 从 Authorization 头取 Bearer; 仅在前缀为 ek_ 时返回 (不抢 JWT 的 token)。
//
// 设计: 同一请求的 Authorization 不会同时是 JWT 和 API Key (两种中间件各挂各的路由);
// 这里仍做一次 ek_ 前缀守卫, 防止挂错路由时把 JWT 错当 API Key 算 401。
func extractAPIKey(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if h == "" {
		return ""
	}
	parts := strings.SplitN(h, " ", 2)
	var tok string
	if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
		tok = strings.TrimSpace(parts[1])
	} else {
		tok = strings.TrimSpace(h)
	}
	if !strings.HasPrefix(tok, "ek_") {
		return ""
	}
	return tok
}
