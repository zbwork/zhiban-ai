// jwt_auth.go — F04 §4.2 应用 OAuth2 access_token (JWT) 中间件。
//
// 跟 APIKeyAuth (ek_) / SessionTokenAuth (st_) 平行; 由 CompositeExternalAuth 按前缀 "eyJ" 分发。
// 验签走 pkg/oauth2/jwt.Verifier (kid → keys.Manager 查公钥 → RS256 verify)。
//
// 校验通过后注入 ctx:
//   - JWT account_id (sub claim → accounts.uuid → 反查 — 这里简化只塞 UUID, 业务自己 GetByUUID)
//   - JWT tenant_id (数值)
//   - JWT client_id (app_xxx)
//   - JWT scopes ([]string)
//
// 失败统一返 401 (防探测)。
package middleware

import (
	"context"
	"net/http"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	pkgjwt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/jwt"
)

// JWTVerifier 中间件依赖的最小接口 (避免直接绑 pkgjwt.Verifier, 便于测试 mock)。
type JWTVerifier interface {
	VerifyAccessToken(ctx context.Context, raw, expectedIssuer string) (*pkgjwt.AccessTokenClaims, error)
}

type jwtCtxKey int

const (
	ctxJWTAccountUUID jwtCtxKey = iota
	ctxJWTTenantID
	ctxJWTClientID
	ctxJWTScopes
)

// JWTAccountUUID 取 ctx 中 sub claim (空串 = 当前非 JWT 鉴权)。
func JWTAccountUUID(ctx context.Context) string {
	v, _ := ctx.Value(ctxJWTAccountUUID).(string)
	return v
}

// JWTTenantID 取 ctx 中 tenant_id (0 = 当前非 JWT 鉴权)。
func JWTTenantID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxJWTTenantID).(int64)
	return v
}

// JWTClientID 取 ctx 中 client_id (空串 = 当前非 JWT 鉴权)。
func JWTClientID(ctx context.Context) string {
	v, _ := ctx.Value(ctxJWTClientID).(string)
	return v
}

// JWTScopes 取 ctx 中 scopes (nil 安全)。
func JWTScopes(ctx context.Context) []string {
	v, _ := ctx.Value(ctxJWTScopes).([]string)
	return v
}

// JWTAuth 强校验 Bearer eyJ*; 失败 401。
//
// expectedIssuer 强校 (生产推荐传 issuer); 空串 = 不校 iss claim。
func JWTAuth(v JWTVerifier, expectedIssuer string) func(http.Handler) http.Handler {
	if v == nil {
		panic("middleware.JWTAuth: verifier must not be nil")
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw := extractAnyBearer(r)
			if !strings.HasPrefix(raw, "eyJ") {
				encode.JSONError(w, apperr.ErrUnauthorized.Withf("missing or non-JWT bearer"))
				return
			}
			claims, err := v.VerifyAccessToken(r.Context(), raw, expectedIssuer)
			if err != nil {
				encode.JSONError(w, apperr.ErrUnauthorized.Wrap(err))
				return
			}
			next.ServeHTTP(w, r.WithContext(contextWithJWT(r.Context(), claims)))
		})
	}
}

func contextWithJWT(ctx context.Context, claims *pkgjwt.AccessTokenClaims) context.Context {
	ctx = context.WithValue(ctx, ctxJWTAccountUUID, claims.Subject)
	ctx = context.WithValue(ctx, ctxJWTTenantID, claims.TenantID)
	ctx = context.WithValue(ctx, ctxJWTClientID, claims.ClientID)
	ctx = context.WithValue(ctx, ctxJWTScopes, append([]string(nil), claims.Scopes...))
	return ctx
}

// ContextWithJWTForTest 测试用。
func ContextWithJWTForTest(ctx context.Context, claims *pkgjwt.AccessTokenClaims) context.Context {
	return contextWithJWT(ctx, claims)
}
