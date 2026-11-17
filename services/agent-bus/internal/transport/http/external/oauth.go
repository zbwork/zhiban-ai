// oauth.go — F01 + F04 OAuth2 token endpoint。
//
// 接口: POST /api/external/v1/oauth/token
//
// 按 grant_type 分发:
//   - client_credentials  (F01 §3.6, Agent SDK)        → oauth_client_credentials.go
//   - authorization_code  (F04 §3.5, 应用接入)         → oauth_authorization_code.go
//   - refresh_token       (F04 §3.5)                    → oauth_refresh_token.go
//
// 不属于"鉴权后" endpoint, 自身就是鉴权 — 用 client_id+secret 校验后颁发 token。
// 失败统一返 401 "invalid client credentials" 或 invalid_grant (防探测)。
package external

import (
	"encoding/json"
	"fmt"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	oauth2rl "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/ratelimit"
)

// /oauth/token 防滥用:
//
//   - oauthBodyMaxBytes 限请求体大小 (codex challenge #3)
//   - defaultOAuthLimiter per-client_id 限速 (token-bucket; pkg/oauth2/ratelimit, 三 grant 共用)
const oauthBodyMaxBytes = 4 * 1024 // 4KB

// 全局单例; F04 §4.1 抽到 pkg/oauth2/ratelimit 后 F01 + F04 共用同一份限流, 防 client_id 撞库。
//
// 多实例部署仍是 N 倍 (单进程 map); 真生产换 Redis token-bucket 时改这一行即可。
var defaultOAuthLimiter = oauth2rl.NewClientIDLimiter(5, 1)

type stringOrNumber string

func (s *stringOrNumber) UnmarshalJSON(b []byte) error {
	raw := strings.TrimSpace(string(b))
	if raw == "" || raw == "null" {
		*s = ""
		return nil
	}
	if raw[0] == '"' {
		var v string
		if err := json.Unmarshal(b, &v); err != nil {
			return err
		}
		*s = stringOrNumber(strings.TrimSpace(v))
		return nil
	}
	*s = stringOrNumber(raw)
	return nil
}

func (s stringOrNumber) String() string {
	return string(s)
}

// oauthTokenReq 是三种 grant 共用的请求体超集; 各 grant 各取自己需要的字段。
type oauthTokenReq struct {
	GrantType    string `json:"grant_type"`
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`

	// === client_credentials (F01 Agent SDK) ===
	CapabilityBindings []string       `json:"capability_bindings,omitempty"`
	TTLSeconds         int            `json:"ttl_seconds,omitempty"`
	TenantID           stringOrNumber `json:"tenant_id,omitempty"`

	// === runtime_access 专用 (A2A v1a, ADR-0030 修订记录) ===
	// 可选: 把换出的 st_ 绑定到发起方数字员工 (opaque string, 当前值为 UUID)。
	AgentID string `json:"agent_id,omitempty"`
	// 可选: 把换出的 st_ 绑定到用户账号范围, 用于自定义 Agent 调平台托管 OpenClaw/Hermes。
	AccountID string `json:"account_id,omitempty"`

	// === authorization_code (F04 应用) ===
	Code        string `json:"code,omitempty"`
	RedirectURI string `json:"redirect_uri,omitempty"`

	// === refresh_token (F04 应用) ===
	RefreshToken string `json:"refresh_token,omitempty"`
}

// oauthToken 是 POST /api/external/v1/oauth/token 的统一入口; 按 grant_type 分发。
func (h *Handlers) oauthToken(w http.ResponseWriter, r *http.Request) {
	// codex challenge #3: 限请求体大小, 防 JSON Bomb。
	r.Body = http.MaxBytesReader(w, r.Body, oauthBodyMaxBytes)
	var req oauthTokenReq
	if err := decodeOAuthTokenRequest(r, &req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if id, secret, ok := r.BasicAuth(); ok {
		req.ClientID = id
		req.ClientSecret = secret
	}
	// 限流: 即便 client_id 不存在也消耗桶 (防"无 client_id 撞库")
	if !defaultOAuthLimiter.Allow(req.ClientID, time.Now()) {
		encode.JSONError(w, apperr.New(apperr.TooManyRequests, "rate_limited").
			Withf("too many oauth/token requests for this client_id"))
		return
	}
	switch req.GrantType {
	case "client_credentials":
		h.oauthClientCredentialsGrant(w, r, req)
	case "runtime_access":
		h.oauthRuntimeAccessGrant(w, r, req)
	case "authorization_code":
		h.oauthAuthorizationCodeGrant(w, r, req)
	case "refresh_token":
		h.oauthRefreshTokenGrant(w, r, req)
	default:
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("unsupported grant_type %q", req.GrantType))
	}
}

func decodeOAuthTokenRequest(r *http.Request, req *oauthTokenReq) error {
	mediaType := strings.TrimSpace(r.Header.Get("Content-Type"))
	if mediaType != "" {
		parsed, _, err := mime.ParseMediaType(mediaType)
		if err != nil {
			return fmt.Errorf("invalid Content-Type: %w", err)
		}
		mediaType = parsed
	}

	switch mediaType {
	case "", "application/json":
		return decodeStrictJSON(r.Body, req)
	case "application/x-www-form-urlencoded":
		if err := r.ParseForm(); err != nil {
			return fmt.Errorf("parse form: %w", err)
		}
		req.GrantType = strings.TrimSpace(r.PostForm.Get("grant_type"))
		req.ClientID = strings.TrimSpace(r.PostForm.Get("client_id"))
		req.ClientSecret = r.PostForm.Get("client_secret")
		req.CapabilityBindings = append([]string(nil), r.PostForm["capability_bindings"]...)
		req.TenantID = stringOrNumber(strings.TrimSpace(r.PostForm.Get("tenant_id")))
		req.AgentID = strings.TrimSpace(r.PostForm.Get("agent_id"))
		req.AccountID = strings.TrimSpace(r.PostForm.Get("account_id"))
		req.Code = r.PostForm.Get("code")
		req.RedirectURI = r.PostForm.Get("redirect_uri")
		req.RefreshToken = r.PostForm.Get("refresh_token")
		if rawTTL := strings.TrimSpace(r.PostForm.Get("ttl_seconds")); rawTTL != "" {
			ttl, err := strconv.Atoi(rawTTL)
			if err != nil {
				return fmt.Errorf("ttl_seconds must be an integer: %w", err)
			}
			req.TTLSeconds = ttl
		}
		return nil
	default:
		return fmt.Errorf("unsupported Content-Type %q", mediaType)
	}
}

// writeOAuthTokenJSON writes RFC/OIDC token responses without the Bus business
// envelope. Standard OAuth clients expect access_token/id_token at top level.
func writeOAuthTokenJSON(w http.ResponseWriter, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(body)
}
