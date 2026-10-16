// session_token_auth.go — F01 §3.6 自定义 Agent SDK 短期 session_token 中间件。
//
// 与 APIKeyAuth 设计对称, 用独立 ctx 命名空间; 不复用 JWT 也不复用 API Key:
//   - 前缀 `st_`  → SessionToken (本中间件)
//   - 前缀 `ek_`  → API Key (APIKeyAuth)
//   - JWT       → Auth
//
// 路由层可独立挂在 /api/external/v1/* (Agent SDK 反向调 Bus 借数据) 或经
// CompositeExternalAuth 由前缀自动分发。
package middleware

import (
	"context"
	"net/http"
	"strconv"
	"strings"

	domagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	domapikey "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// SessionTokenValidator 中间件依赖的最小接口。
type SessionTokenValidator interface {
	ValidateSessionToken(ctx context.Context, raw string) (*domagentsdk.Identity, error)
}

type sessionTokenCtxKey int

const (
	ctxSessionTokenID sessionTokenCtxKey = iota
	ctxSessionCredentialID
	ctxSessionTenantID
	ctxSessionCaps
	ctxSessionConvID
	ctxSessionAgentID
	ctxSessionAccountID
	ctxSessionRuntimeEnvID
)

// SessionTokenAuth 强校验 Bearer st_*; 失败 401。
//
// 与 APIKeyAuth 分开是因为 ctx 取值方式不同 (没有 creator_id; 多出 conversation/agent 绑定)。
func SessionTokenAuth(v SessionTokenValidator) func(http.Handler) http.Handler {
	if v == nil {
		panic("middleware.SessionTokenAuth: validator must not be nil")
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw := extractSessionToken(r)
			if raw == "" {
				encode.JSONError(w, apperr.ErrUnauthorized.Withf("missing session token"))
				return
			}
			id, err := v.ValidateSessionToken(r.Context(), raw)
			if err != nil {
				encode.JSONError(w, err)
				return
			}
			setInternalIdentityHeaders(r, id.TenantID, 0)
			ctx := contextWithSessionToken(r.Context(), id)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// CompositeExternalAuth 同时支持 ek_ (API Key) / st_ (SessionToken) / eyJ (JWT, F04 应用) 三路复合鉴权。
//
// 用于 /api/external/v1/* 给"外部系统 + 自定义 Agent SDK + 租户自建应用"共用 — 区别仅在 Bearer 前缀。
// 任一通过即放行; 前缀不识别返 401 (防扫描)。
//
// 业务 handler 可同时读三种 *TenantID 取值, 或经统一访问器 ExternalTenantID / ExternalScopes。
//
// jwt 参数为 nil 时不接受 eyJ token (F04 未启用); 三个 validator 都为 nil 时 panic。
func CompositeExternalAuth(apiKey ApiKeyValidator, sessionToken SessionTokenValidator, jwt JWTVerifier, jwtIssuer string) func(http.Handler) http.Handler {
	if apiKey == nil && sessionToken == nil && jwt == nil {
		panic("middleware.CompositeExternalAuth: at least one validator must be non-nil")
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw := extractAnyBearer(r)
			if raw == "" {
				encode.JSONError(w, apperr.ErrUnauthorized.Withf("missing bearer token"))
				return
			}
			switch {
			case strings.HasPrefix(raw, "ek_"):
				if apiKey == nil {
					encode.JSONError(w, apperr.ErrUnauthorized.Withf("api key auth not enabled"))
					return
				}
				id, err := apiKey.Validate(r.Context(), raw)
				if err != nil {
					encode.JSONError(w, err)
					return
				}
				ctx := r.Context()
				ctx = context.WithValue(ctx, ctxAPIKeyID, id.APIKeyID)
				ctx = context.WithValue(ctx, ctxAPIKeyTenantID, id.TenantID)
				ctx = context.WithValue(ctx, ctxAPIKeyCreator, id.CreatorID)
				ctx = context.WithValue(ctx, ctxAPIKeyScopes, id.Scopes)
				setInternalIdentityHeaders(r, id.TenantID, id.CreatorID)
				next.ServeHTTP(w, r.WithContext(ctx))
			case strings.HasPrefix(raw, "st_"):
				if sessionToken == nil {
					encode.JSONError(w, apperr.ErrUnauthorized.Withf("session token auth not enabled"))
					return
				}
				id, err := sessionToken.ValidateSessionToken(r.Context(), raw)
				if err != nil {
					encode.JSONError(w, err)
					return
				}
				setInternalIdentityHeaders(r, id.TenantID, 0)
				next.ServeHTTP(w, r.WithContext(contextWithSessionToken(r.Context(), id)))
			case strings.HasPrefix(raw, "eyJ"):
				if jwt == nil {
					encode.JSONError(w, apperr.ErrUnauthorized.Withf("jwt auth not enabled"))
					return
				}
				claims, err := jwt.VerifyAccessToken(r.Context(), raw, jwtIssuer)
				if err != nil {
					encode.JSONError(w, apperr.ErrUnauthorized.Wrap(err))
					return
				}
				setInternalIdentityHeaders(r, claims.TenantID, 0)
				next.ServeHTTP(w, r.WithContext(contextWithJWT(r.Context(), claims)))
			default:
				encode.JSONError(w, apperr.ErrUnauthorized.Withf("unsupported bearer scheme"))
			}
		})
	}
}

// RequireExternalScope 验证当前请求 (ek_ / st_ / eyJ 三种鉴权之一) 含给定 scope。
//
// 内部读取顺序: API Key scopes → session_token capability_bindings → JWT scopes。
func RequireExternalScope(scope string) func(http.Handler) http.Handler {
	if scope == "" {
		panic("middleware.RequireExternalScope: scope must not be empty")
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx := r.Context()
			if scopes := APIKeyScopes(ctx); len(scopes) > 0 {
				if domapikey.HasScope(scopes, scope) {
					next.ServeHTTP(w, r)
					return
				}
				encode.JSONError(w, apperr.ErrForbidden.Withf("scope_denied: requires %q", scope))
				return
			}
			if caps := SessionTokenCapabilities(ctx); len(caps) > 0 {
				if domagentsdk.HasCapability(caps, scope) {
					next.ServeHTTP(w, r)
					return
				}
				encode.JSONError(w, apperr.ErrForbidden.Withf("scope_denied: requires %q", scope))
				return
			}
			if JWTClientID(ctx) != "" {
				scopes := JWTScopes(ctx)
				if appJWTAllowsExternalScope(scopes, scope) {
					next.ServeHTTP(w, r)
					return
				}
				encode.JSONError(w, apperr.ErrForbidden.Withf("scope_denied: requires %q", scope))
				return
			}
			encode.JSONError(w, apperr.ErrUnauthorized)
		})
	}
}

// appJWTAllowsExternalScope 是应用授权到租户资源服务的唯一白名单。
// 不做同名放行，确保 JWT 即使被错误签入 tenant.* 也不能获得写权限。
func appJWTAllowsExternalScope(scopes []string, required string) bool {
	var delegated string
	switch required {
	case domapikey.ScopeTenantKBRead:
		delegated = domapp.ScopeKBRead
	case domapikey.ScopeTenantOrgRead:
		delegated = domapp.ScopeContactsRead
	default:
		return false
	}
	for _, scope := range scopes {
		if scope == delegated {
			return true
		}
	}
	return false
}

// ExternalTenantID 取当前外部调用者的 tenant_id (api_key / session_token / JWT 三种来源择优)。
func ExternalTenantID(ctx context.Context) int64 {
	if t := APIKeyTenantID(ctx); t > 0 {
		return t
	}
	if t := SessionTokenTenantID(ctx); t > 0 {
		return t
	}
	return JWTTenantID(ctx)
}

// ExternalAccountID 取"代表的人/创建者" - api_key.creator_id / session_token.account_id / 0。
func ExternalAccountID(ctx context.Context) int64 {
	if v := APIKeyCreatorID(ctx); v > 0 {
		return v
	}
	if v := SessionTokenAccountID(ctx); v > 0 {
		return v
	}
	return 0
}

// SessionTokenID 取 ctx 中的 session_tokens.id (0 = 当前不是 SessionToken 鉴权)。
func SessionTokenID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxSessionTokenID).(int64)
	return v
}

// SessionCredentialID 取 ctx 中的 agent_sdk_credentials.id (0 = 当前不是 SessionToken 鉴权)。
func SessionCredentialID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxSessionCredentialID).(int64)
	return v
}

// SessionTokenTenantID 取 ctx 中的 session_token.tenant_id (0 = 当前不是 SessionToken 鉴权)。
func SessionTokenTenantID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxSessionTenantID).(int64)
	return v
}

// SessionTokenCapabilities 取 session_token.capability_bindings (nil 安全)。
func SessionTokenCapabilities(ctx context.Context) []string {
	v, _ := ctx.Value(ctxSessionCaps).([]string)
	return v
}

// SessionTokenConversationID 取绑定会话 ID (0 = 通用)。
func SessionTokenConversationID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxSessionConvID).(int64)
	return v
}

// SessionTokenAgentID 取绑定数字员工 ID (0 = 通用)。
func SessionTokenAgentID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxSessionAgentID).(int64)
	return v
}

// SessionTokenAccountID 取绑定账号 ID (0 = 未绑定)。
func SessionTokenAccountID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxSessionAccountID).(int64)
	return v
}

// SessionTokenRuntimeEnvironmentID 取绑定 runtime_environment_id (0 = 未绑定)。
func SessionTokenRuntimeEnvironmentID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxSessionRuntimeEnvID).(int64)
	return v
}

// ContextWithSessionTokenForTest 测试用。
func ContextWithSessionTokenForTest(ctx context.Context, id *domagentsdk.Identity) context.Context {
	return contextWithSessionToken(ctx, id)
}

func contextWithSessionToken(ctx context.Context, id *domagentsdk.Identity) context.Context {
	ctx = context.WithValue(ctx, ctxSessionTokenID, id.SessionTokenID)
	ctx = context.WithValue(ctx, ctxSessionCredentialID, id.CredentialID)
	ctx = context.WithValue(ctx, ctxSessionTenantID, id.TenantID)
	ctx = context.WithValue(ctx, ctxSessionCaps, append([]string(nil), id.CapabilityBindings...))
	ctx = context.WithValue(ctx, ctxSessionConvID, id.ConversationID)
	ctx = context.WithValue(ctx, ctxSessionAgentID, id.AgentID)
	ctx = context.WithValue(ctx, ctxSessionAccountID, id.AccountID)
	ctx = context.WithValue(ctx, ctxSessionRuntimeEnvID, id.RuntimeEnvironmentID)
	return ctx
}

func setInternalIdentityHeaders(r *http.Request, tenantID, accountID int64) {
	if r == nil {
		return
	}
	if tenantID > 0 {
		r.Header.Set("X-EasyO-Tenant-ID", strconv.FormatInt(tenantID, 10))
	}
	if accountID > 0 {
		r.Header.Set("X-EasyO-Account-ID", strconv.FormatInt(accountID, 10))
	}
}

func extractSessionToken(r *http.Request) string {
	raw := extractAnyBearer(r)
	if !strings.HasPrefix(raw, "st_") {
		return ""
	}
	return raw
}

// extractAnyBearer 不前缀过滤的 Bearer 提取 (CompositeExternalAuth 自己分发)。
func extractAnyBearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if h == "" {
		return ""
	}
	parts := strings.SplitN(h, " ", 2)
	if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
		return strings.TrimSpace(parts[1])
	}
	return strings.TrimSpace(h)
}
