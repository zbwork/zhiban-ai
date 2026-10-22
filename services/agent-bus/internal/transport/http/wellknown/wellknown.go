// Package wellknown 是 F04 OAuth2 / OIDC 的发现 endpoints。
//
// 两条路径 (按 RFC 8414 + OpenID Connect Discovery 1.0):
//
//	GET /.well-known/openid-configuration    → 静态 + 动态拼接的发现文档
//	GET /.well-known/jwks.json                → 公钥集 (active + retiring keys)
//
// 调用方:
//   - 应用后端启动时拉 discovery, 拿 token_endpoint / jwks_uri
//   - 应用后端 verify id_token 时拉 jwks 抓公钥
//   - 主流 OIDC SDK (coreos/go-oidc, openid-client.js, python-jose) 自动按这套发现
//
// 安全:
//   - 完全无鉴权 (公开 endpoint)
//   - Cache-Control: max-age=3600 让 CDN/客户端缓存 (推荐 OIDC 实践)
//   - Rate limit 留给 reverse proxy (Nginx / ELB) 层加, 本层不重做
package wellknown

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/keys"
)

// Config 是 discovery 文档的静态部分。
//
// 由 cmd/bus 在启动时填好 (issuer/endpoints 等), 注册 Handlers 时注入。
// 这部分一旦上线就不该改 — issuer URL 改了所有应用都得重新配。
type Config struct {
	// Issuer 必填; OIDC iss claim 来源, 应用 verify 时强校。
	// 例: "https://example.org"
	Issuer string

	// AuthorizationEndpoint 应用启动 URL; F04 路径是 /api/agent-bus/v1/apps/{uuid}/launch
	// (注意: 不是标准 OAuth2 /authorize, 因为 F04 走自定义 launch 流程, 用户已在 zhiban-app 内登录)
	AuthorizationEndpoint string

	// TokenEndpoint /api/external/v1/oauth/token (扩了 authorization_code grant 后)
	TokenEndpoint string

	// JwksURI /.well-known/jwks.json 完整 URL
	JwksURI string

	// 静态 capability 列表 (合规要求)
	ResponseTypesSupported            []string // ["code"]
	GrantTypesSupported               []string // ["authorization_code","refresh_token","client_credentials"]
	SubjectTypesSupported             []string // ["public"]
	IDTokenSigningAlgValuesSupported  []string // ["RS256"]
	TokenEndpointAuthMethodsSupported []string // ["client_secret_post","client_secret_basic"]
	ScopesSupported                   []string // ["openid","email","profile","kb.read","contacts.read"]
	ClaimsSupported                   []string // ["sub","email",...]
}

// DefaultConfig 用合理默认填; caller 只需要传 issuer 和 base URL。
//
// baseURL 例 "https://example.org" — 各 endpoint 在此基础上拼。
func DefaultConfig(issuer, baseURL string) Config {
	return Config{
		Issuer:                            issuer,
		AuthorizationEndpoint:             baseURL + "/api/agent-bus/v1/apps/{uuid}/launch",
		TokenEndpoint:                     baseURL + "/api/external/v1/oauth/token",
		JwksURI:                           baseURL + "/.well-known/jwks.json",
		ResponseTypesSupported:            []string{"code"},
		GrantTypesSupported:               []string{"authorization_code", "refresh_token", "client_credentials"},
		SubjectTypesSupported:             []string{"public"},
		IDTokenSigningAlgValuesSupported:  []string{"RS256"},
		TokenEndpointAuthMethodsSupported: []string{"client_secret_post", "client_secret_basic"},
		ScopesSupported:                   []string{"openid", "email", "profile", "kb.read", "contacts.read"},
		ClaimsSupported: []string{
			"sub", "email", "email_verified", "name", "phone_number",
			"tenant", "membership", "zhiban_context", "nonce",
		},
	}
}

// Handlers 装配 wellknown 路由的依赖。
type Handlers struct {
	Config  Config
	KeysMgr keys.Manager
}

// Register 把路由挂到给定 mux。
//
// 调用方: cmd/bus/main.go 在共享 mux 上调一次即可; 路径前缀 /.well-known/ 唯一,
// 不会和 bus / admin / external 冲突。
func (h *Handlers) Register(mux *http.ServeMux) {
	if h == nil || h.KeysMgr == nil {
		return
	}
	mux.HandleFunc("GET /.well-known/openid-configuration", h.openidConfiguration)
	mux.HandleFunc("GET /.well-known/jwks.json", h.jwks)
}

// openidConfiguration 返回 OIDC discovery 文档。
func (h *Handlers) openidConfiguration(w http.ResponseWriter, r *http.Request) {
	doc := map[string]any{
		"issuer":                                h.Config.Issuer,
		"authorization_endpoint":                h.Config.AuthorizationEndpoint,
		"token_endpoint":                        h.Config.TokenEndpoint,
		"jwks_uri":                              h.Config.JwksURI,
		"response_types_supported":              h.Config.ResponseTypesSupported,
		"grant_types_supported":                 h.Config.GrantTypesSupported,
		"subject_types_supported":               h.Config.SubjectTypesSupported,
		"id_token_signing_alg_values_supported": h.Config.IDTokenSigningAlgValuesSupported,
		"token_endpoint_auth_methods_supported": h.Config.TokenEndpointAuthMethodsSupported,
		"scopes_supported":                      h.Config.ScopesSupported,
		"claims_supported":                      h.Config.ClaimsSupported,
	}
	writeJSON(w, doc)
}

// jwks 返回当前 active+retiring 的所有公钥 (JWKS Set)。
//
// active 通常 1 个; retiring 通常 0-2 个 (依轮转节奏); 总大小 < 5KB。
func (h *Handlers) jwks(w http.ResponseWriter, r *http.Request) {
	ks, err := h.KeysMgr.JWKSKeys(r.Context())
	if err != nil {
		http.Error(w, `{"error":"keys_unavailable"}`, http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, map[string]any{"keys": ks})
}

func writeJSON(w http.ResponseWriter, body any) {
	w.Header().Set("Content-Type", "application/json")
	// 鼓励 CDN / 客户端缓存; 密钥轮转时旧 jwks 仍含老 kid, 等过 1h 自动刷新。
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_ = json.NewEncoder(w).Encode(body)
}

// _ ensures keys.Manager interface stays in scope (no compiler error if removed elsewhere).
var _ context.Context = nil
