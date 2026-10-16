// Package middleware 提供 HTTP 中间件：日志/恢复/CORS/JWT 鉴权/租户注入。
package middleware

import (
	"bufio"
	"context"
	"errors"
	"net"
	"net/http"
	"strings"
	"time"

	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

type ctxKey int

const (
	ctxAccountID ctxKey = iota
	ctxTenantID
	ctxClaims
	ctxSessionUUID
	ctxActScope
	ctxWorkspaceID
)

// Revoker 检查指定 session 是否已被撤销 (Redis 黑名单)。
// 实现由 service/auth 提供; 这里接受 nil 表示不做撤销校验 (dev)。
type Revoker interface {
	IsSessionRevoked(ctx context.Context, sessionUUID string) (bool, error)
	IsAccountRevoked(ctx context.Context, accountID int64, issuedAt time.Time) (bool, error)
}

// Recovery 兜底 panic。
func Recovery(logger *log.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					logger.Error(r.Context(), "panic", "rec", rec, "path", r.URL.Path)
					encode.JSONError(w, apperr.ErrInternal.Withf("internal panic"))
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// Logging 简易请求日志。
func Logging(logger *log.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rw := &responseWriter{ResponseWriter: w, status: 200}
			next.ServeHTTP(rw, r)
			logger.Info(r.Context(), "http",
				"method", r.Method, "path", r.URL.Path, "status", rw.status,
				"took_ms", time.Since(start).Milliseconds())
		})
	}
}

// TraceHTTP creates one OTel server span per inbound HTTP request.
// It intentionally does not capture request/response bodies; body-level audit
// belongs to runtime_call_logs or domain audit tables.
func TraceHTTP(service string) func(http.Handler) http.Handler {
	tracerName := "agent-bus/http"
	if strings.TrimSpace(service) != "" {
		tracerName += "/" + strings.TrimSpace(service)
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			parent := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
			spanName := r.Method + " " + r.URL.Path
			ctx, span := otel.Tracer(tracerName).Start(parent, spanName,
				trace.WithSpanKind(trace.SpanKindServer),
				trace.WithAttributes(
					attribute.String("http.request.method", r.Method),
					attribute.String("url.path", r.URL.Path),
					attribute.String("url.scheme", requestScheme(r)),
					attribute.String("user_agent.original", r.UserAgent()),
					attribute.String("network.peer.address", r.RemoteAddr),
				),
			)
			if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
				w.Header().Set("X-Trace-Id", sc.TraceID().String())
			}
			rw := &traceResponseWriter{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rw, r.WithContext(ctx))

			status := rw.status
			span.SetAttributes(
				attribute.Int("http.response.status_code", status),
				attribute.Int64("http.server.duration_ms", time.Since(start).Milliseconds()),
			)
			if status >= http.StatusInternalServerError {
				span.SetStatus(codes.Error, http.StatusText(status))
			} else {
				span.SetStatus(codes.Ok, "")
			}
			span.End()
		})
	}
}

type traceResponseWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

// Preserve optional HTTP capabilities through instrumentation wrappers.
func (rw *traceResponseWriter) Unwrap() http.ResponseWriter { return rw.ResponseWriter }

func (rw *traceResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, buffer, err := http.NewResponseController(rw.ResponseWriter).Hijack()
	if err == nil {
		rw.status = http.StatusSwitchingProtocols
		rw.wrote = true
	}
	return conn, buffer, err
}

func (rw *traceResponseWriter) WriteHeader(status int) {
	if rw.wrote {
		return
	}
	rw.wrote = true
	rw.status = status
	rw.ResponseWriter.WriteHeader(status)
}

func (rw *traceResponseWriter) Write(b []byte) (int, error) {
	if !rw.wrote {
		rw.wrote = true
	}
	return rw.ResponseWriter.Write(b)
}

func (rw *traceResponseWriter) Flush() {
	if f, ok := rw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func requestScheme(r *http.Request) string {
	if r.TLS != nil {
		return "https"
	}
	if proto := strings.TrimSpace(r.Header.Get("X-Forwarded-Proto")); proto != "" {
		return proto
	}
	return "http"
}

type responseWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

// Preserve optional HTTP capabilities through instrumentation wrappers.
func (rw *responseWriter) Unwrap() http.ResponseWriter { return rw.ResponseWriter }

func (rw *responseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, buffer, err := http.NewResponseController(rw.ResponseWriter).Hijack()
	if err == nil {
		rw.status = http.StatusSwitchingProtocols
		rw.wrote = true
	}
	return conn, buffer, err
}

func (rw *responseWriter) WriteHeader(s int) {
	if rw.wrote {
		return
	}
	rw.wrote = true
	rw.status = s
	rw.ResponseWriter.WriteHeader(s)
}

func (rw *responseWriter) Write(b []byte) (int, error) {
	if !rw.wrote {
		rw.wrote = true
	}
	return rw.ResponseWriter.Write(b)
}

// Flush forwards to underlying flusher so SSE works behind the middleware.
func (rw *responseWriter) Flush() {
	if f, ok := rw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// CORS 简单允许所有来源（开发期）。生产可在 ingress 层做。
func CORS() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS,PATCH")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization,Content-Type,X-Tenant-Id")
			w.Header().Set("Access-Control-Expose-Headers", "X-Trace-Id")
			if r.Method == http.MethodOptions {
				w.WriteHeader(204)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// Auth 解析 Bearer 并把 accountID / act_tenant / session_uuid / act_scope 放进 context。
// optional=true 时缺少/无效 token 不报错, 仅不注入身份。
// revoker 非 nil 时, 校验 token 未被撤销 (Redis 黑名单, M1 §8 跨进程撤销立即生效)。
func Auth(issuer *jwt.Issuer, revoker Revoker, optional bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			tok := extractToken(r)
			if tok == "" {
				if optional {
					next.ServeHTTP(w, r)
					return
				}
				encode.JSONError(w, apperr.ErrUnauthorized)
				return
			}
			c, err := issuer.Verify(tok)
			if err != nil {
				if optional {
					next.ServeHTTP(w, r)
					return
				}
				encode.JSONError(w, apperr.ErrUnauthorized.Wrap(err))
				return
			}

			// 撤销校验
			if revoker != nil {
				if c.SessionUUID != "" {
					if revoked, err := revoker.IsSessionRevoked(r.Context(), c.SessionUUID); err != nil || revoked {
						encode.JSONError(w, apperr.ErrUnauthorized.Withf("session revoked"))
						return
					}
				}
				if c.IssuedAt != nil {
					if revoked, _ := revoker.IsAccountRevoked(r.Context(), c.AccountID, c.IssuedAt.Time); revoked {
						encode.JSONError(w, apperr.ErrUnauthorized.Withf("session revoked"))
						return
					}
				}
			}

			// 严格按 JWT claims 注入身份。X-Tenant-Id header 不再被接受作为跨 scope 的"软切换"——
			// platform admin 想操作目标租户必须显式调 /platform/tenants/{id}/impersonate
			// 拿到 act_scope=tenant 的新 token (M1 §5.5 审计要求)。
			tid := c.ActTenantID
			ctx := context.WithValue(r.Context(), ctxAccountID, c.AccountID)
			ctx = context.WithValue(ctx, ctxTenantID, tid)
			ctx = context.WithValue(ctx, ctxWorkspaceID, c.ActWorkspaceID)
			ctx = context.WithValue(ctx, ctxSessionUUID, c.SessionUUID)
			ctx = context.WithValue(ctx, ctxActScope, c.ActScope)
			ctx = context.WithValue(ctx, ctxClaims, c)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// ContextWithIdentityForTest · round-8 测试辅助: 把 (accountID, tenantID) 注入 ctx,
// 供 transport/http 包的 handler 测试在不走真实 Auth middleware 的情况下复用 MustAccountID /
// MustTenantID 读路径. **仅供测试**; 生产路径仍由 Auth middleware 注入.
//
// 起名 "ForTest" 是因为它绕过了真实 JWT / scope 校验; 任何 prod code 直接调用都会暴露在
// reviewer 视野里.
func ContextWithIdentityForTest(ctx context.Context, accountID, tenantID int64) context.Context {
	ctx = context.WithValue(ctx, ctxAccountID, accountID)
	ctx = context.WithValue(ctx, ctxTenantID, tenantID)
	return ctx
}

// ContextWithClaimsForTest · F28 测试辅助: 把 *jwt.Claims 注入 ctx, 供 handler 内
// middleware.Claims 读路径（如 Bus 端 tenant.member.invite 权限校验）在单测中复用。
// **仅供测试**, 同 ContextWithIdentityForTest 的约定。
func ContextWithClaimsForTest(ctx context.Context, c *jwt.Claims) context.Context {
	return context.WithValue(ctx, ctxClaims, c)
}

// MustAccountID 取 accountID, 不存在则返回 0。
func MustAccountID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxAccountID).(int64)
	return v
}

// MustTenantID 取 tenantID (可能为 0, 由调用方判断)。
func MustTenantID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxTenantID).(int64)
	return v
}

// WorkspaceID 取当前 act_workspace_id (可能为 0)。
func WorkspaceID(ctx context.Context) int64 {
	v, _ := ctx.Value(ctxWorkspaceID).(int64)
	return v
}

// SessionUUID 取当前 session uuid (可能为空)。
func SessionUUID(ctx context.Context) string {
	v, _ := ctx.Value(ctxSessionUUID).(string)
	return v
}

// ActScope 取当前 act_scope ("platform" / "tenant" / "workspace")。
func ActScope(ctx context.Context) string {
	v, _ := ctx.Value(ctxActScope).(string)
	return v
}

// Claims 取 claims。
func Claims(ctx context.Context) (*jwt.Claims, bool) {
	c, ok := ctx.Value(ctxClaims).(*jwt.Claims)
	return c, ok
}

// RequirePlatform 要求当前 act_scope=platform。
func RequirePlatform(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ActScope(r.Context()) != "platform" {
			encode.JSONError(w, apperr.ErrForbidden.Withf("need act_scope=platform"))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// AdminGate 校验账号是否拥有后台管理资格。
//
// 这是 admin 端的 RBAC 总闸: 普通成员即使持有有效 token, 也被拦在 /api/admin/v1/* 之外。
// 用法: middleware 在 Auth 之后注入; 缺少 accountID 时直接 401。
//
// 后台资格在登录 / scope switch 时写入签名 JWT claims，角色变更通过 auth_revoke 撤销旧 token。
// 因此这里不再每请求回查 role_assignments，避免后台页面列表请求被远端 PG 往返拖慢。
type AdminChecker interface {
	HasAdminRole(ctx context.Context, accountID int64) (bool, error)
}

func RequireAdmin(_ AdminChecker) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			aid := MustAccountID(r.Context())
			if aid <= 0 {
				encode.JSONError(w, apperr.ErrUnauthorized)
				return
			}
			claims, ok := Claims(r.Context())
			if !ok || claims == nil {
				encode.JSONError(w, apperr.ErrUnauthorized)
				return
			}
			if !claims.Admin {
				encode.JSONError(w, apperr.ErrForbidden.Withf("账号无后台管理权限"))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// extractToken 从 Header / Query 提取 token。
func extractToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if h != "" {
		parts := strings.SplitN(h, " ", 2)
		if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
			return strings.TrimSpace(parts[1])
		}
		return strings.TrimSpace(h)
	}
	return r.URL.Query().Get("token")
}

// RequireTenant 要求当前 act_scope=tenant 或 workspace 且 tenantID>0。
//
// 严格语义: act_scope=platform 即使带 X-Tenant-Id 也被拒, 必须先走 /platform/tenants/{id}/impersonate
// 切换到 tenant scope 才能访问 /tenant/* (M1 §5.5 跨租户审计要求)。
func RequireTenant(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		scope := ActScope(r.Context())
		if scope != "tenant" && scope != "workspace" {
			encode.JSONError(w, apperr.ErrForbidden.Withf("need act_scope=tenant; got %q", scope))
			return
		}
		if MustTenantID(r.Context()) <= 0 {
			encode.JSONError(w, apperr.ErrForbidden.Withf("missing tenant"))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// TenantMembershipReader resolves the caller's current tenant membership.
// JWT act_tenant_id proves the scope selected when the token was issued; it
// does not prove that the membership is still active now.
type TenantMembershipReader interface {
	GetMembership(ctx context.Context, accountID, tenantID int64) (*domaccount.Membership, error)
}

// RequireActiveTenantMembership makes membership lifecycle changes effective
// for existing access tokens. It must run after Auth + RequireTenant.
func RequireActiveTenantMembership(reader TenantMembershipReader) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if reader == nil {
				encode.JSONError(w, apperr.ErrInternal.Withf("tenant membership reader not wired"))
				return
			}
			accountID := MustAccountID(r.Context())
			tenantID := MustTenantID(r.Context())
			membership, err := reader.GetMembership(r.Context(), accountID, tenantID)
			if err != nil {
				if appErr, ok := apperr.AsError(err); !ok || appErr.Code != apperr.NotFound {
					encode.JSONError(w, apperr.ErrInternal.Withf("tenant membership lookup failed"))
					return
				}
			}
			if membership == nil || membership.Status != "active" {
				encode.JSONError(w, apperr.ErrForbidden.Withf("membership.inactive"))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// Chain 工具：按从外到内的顺序组合中间件。
func Chain(mws ...func(http.Handler) http.Handler) func(http.Handler) http.Handler {
	return func(h http.Handler) http.Handler {
		for i := len(mws) - 1; i >= 0; i-- {
			h = mws[i](h)
		}
		return h
	}
}

// Sentinel errors（保留备用）。
var ErrNoAccount = errors.New("no account in context")
