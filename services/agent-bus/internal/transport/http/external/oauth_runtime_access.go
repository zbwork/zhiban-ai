package external

import (
	"net/http"
	"strings"
	"time"

	domagentsdk "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type runtimeAccessResp struct {
	AccessToken       string `json:"access_token"`
	TokenType         string `json:"token_type"`
	ExpiresIn         int    `json:"expires_in"`
	Scope             string `json:"scope"`
	SessionTokenID    string `json:"session_token_id"`
	BoundTenantID     int64  `json:"bound_tenant_id"`
	BoundRuntimeEnvID int64  `json:"bound_runtime_environment_id"`
	// canonical 字段回显经过同一 credential / tenant scope 校验后的请求值。
	BoundAgentID   string `json:"bound_agent_id,omitempty"`
	BoundAccountID string `json:"bound_account_id,omitempty"`
}

func (h *Handlers) oauthRuntimeAccessGrant(w http.ResponseWriter, r *http.Request, req oauthTokenReq) {
	if h.AgentSDK == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("agent sdk not enabled"))
		return
	}
	cred, err := h.AgentSDK.ValidateClientCredentials(r.Context(), req.ClientID, req.ClientSecret)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	agentUUID := strings.TrimSpace(req.AgentID)
	accountUUID := strings.TrimSpace(req.AccountID)
	tok, plaintext, err := h.AgentSDK.IssueRuntimeAccessToken(r.Context(), cred.ID, domagentsdk.RuntimeAccessRequest{
		TenantID:    strings.TrimSpace(req.TenantID.String()),
		AgentUUID:   agentUUID,
		AccountUUID: accountUUID,
		TTL:         time.Duration(req.TTLSeconds) * time.Second,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var runtimeID int64
	if tok.RuntimeEnvironmentID != nil {
		runtimeID = *tok.RuntimeEnvironmentID
	}
	resp := runtimeAccessResp{
		AccessToken:       plaintext,
		TokenType:         "Bearer",
		ExpiresIn:         int(time.Until(tok.ExpiresAt).Seconds()),
		Scope:             strings.Join(tok.CapabilityBindings, " "),
		SessionTokenID:    tok.UUID,
		BoundTenantID:     tok.TenantID,
		BoundRuntimeEnvID: runtimeID,
	}
	if tok.AgentID != nil {
		resp.BoundAgentID = agentUUID
	}
	if tok.AccountID != nil {
		resp.BoundAccountID = accountUUID
	}
	writeOAuthTokenJSON(w, resp)
}
