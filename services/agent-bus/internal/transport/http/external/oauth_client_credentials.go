// oauth_client_credentials.go — F01 §3.6 链路 B: Agent SDK 用 client_credentials 换 session_token。
//
// 不动 F01 现有语义 — PR1 把 ratelimit + grant 分发抽到 oauth.go 之后, 本文件是原 handler body 的搬家。
//
//	Body  : { grant_type:"client_credentials", client_id, client_secret, capability_bindings?, ttl_seconds? }
//	Return: { access_token (st_*), token_type:"Bearer", expires_in, scope, session_token_id }
package external

import (
	"net/http"
	"strings"
	"time"

	domagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// clientCredentialsResp Agent SDK 路径专属响应; 跟 F04 grant 不共结构 (F04 是 JWT, 这里是 opaque)。
type clientCredentialsResp struct {
	AccessToken    string `json:"access_token"` // st_<prefix>_<secret>
	TokenType      string `json:"token_type"`
	ExpiresIn      int    `json:"expires_in"`
	Scope          string `json:"scope"`
	SessionTokenID string `json:"session_token_id"`
}

func (h *Handlers) oauthClientCredentialsGrant(w http.ResponseWriter, r *http.Request, req oauthTokenReq) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk not enabled"))
		return
	}
	cred, err := h.AgentSDK.ValidateClientCredentials(r.Context(), req.ClientID, req.ClientSecret)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// codex challenge #2: TTL server-side clamp; caller 给的 > MaxSessionTokenTTL 就 cap。
	ttl := time.Duration(req.TTLSeconds) * time.Second
	if ttl <= 0 || ttl > domagentsdk.MaxSessionTokenTTL {
		ttl = domagentsdk.DefaultSessionTokenTTL
	}
	tok, plaintext, err := h.AgentSDK.IssueSessionToken(r.Context(), cred.ID, nil, nil, req.CapabilityBindings, ttl)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	writeOAuthTokenJSON(w, clientCredentialsResp{
		AccessToken:    plaintext,
		TokenType:      "Bearer",
		ExpiresIn:      int(time.Until(tok.ExpiresAt).Seconds()),
		Scope:          strings.Join(tok.CapabilityBindings, " "),
		SessionTokenID: tok.UUID,
	})
}
