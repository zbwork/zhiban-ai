package external

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	userjwt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
)

type introspectLoginTokenRequest struct {
	Token string `json:"token"`
}

type introspectLoginTokenResponse struct {
	Active             bool     `json:"active"`
	AccountID          int64    `json:"account_id,omitempty"`
	AccountUUID        string   `json:"account_uuid,omitempty"`
	TenantID           int64    `json:"tenant_id,omitempty"`
	WorkspaceID        int64    `json:"workspace_id,omitempty"`
	ActScope           string   `json:"act_scope,omitempty"`
	SessionUUID        string   `json:"session_uuid,omitempty"`
	Perms              []string `json:"perms,omitempty"`
	PermsHash          string   `json:"perms_hash,omitempty"`
	MustChangePassword bool     `json:"must_change_password,omitempty"`
	Admin              bool     `json:"admin,omitempty"`
	ActingAs           string   `json:"acting_as,omitempty"`
	Kind               string   `json:"kind,omitempty"`
	Issuer             string   `json:"issuer,omitempty"`
	Subject            string   `json:"subject,omitempty"`
	IssuedAt           int64    `json:"issued_at,omitempty"`
	ExpiresAt          int64    `json:"expires_at,omitempty"`
	CacheTTLSeconds    int      `json:"cache_ttl_seconds,omitempty"`
}

func (h *Handlers) introspectLoginToken(w http.ResponseWriter, r *http.Request) {
	if h.LoginIssuer == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("login token introspection is not configured"))
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8*1024)
	var req introspectLoginTokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid json body"))
		return
	}
	if req.Token == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("token required"))
		return
	}

	claims, err := h.LoginIssuer.Verify(req.Token)
	if err != nil {
		encode.JSON(w, introspectLoginTokenResponse{Active: false})
		return
	}

	revoked, err := h.loginTokenRevoked(r, claims)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("token revocation check failed"))
		return
	}
	if revoked {
		encode.JSON(w, introspectLoginTokenResponse{Active: false})
		return
	}

	tenantID := middleware.APIKeyTenantID(r.Context())
	if tenantID <= 0 || claims.ActTenantID <= 0 || claims.ActTenantID != tenantID {
		encode.JSON(w, introspectLoginTokenResponse{Active: false})
		return
	}

	encode.JSON(w, activeLoginTokenResponse(claims))
}

func (h *Handlers) loginTokenRevoked(r *http.Request, claims *userjwt.Claims) (bool, error) {
	if h.LoginRevoker == nil {
		return false, nil
	}
	if claims.SessionUUID != "" {
		revoked, err := h.LoginRevoker.IsSessionRevoked(r.Context(), claims.SessionUUID)
		if err != nil || revoked {
			return revoked, err
		}
	}
	if claims.IssuedAt != nil {
		revoked, err := h.LoginRevoker.IsAccountRevoked(r.Context(), claims.AccountID, claims.IssuedAt.Time)
		if err != nil || revoked {
			return revoked, err
		}
	}
	return false, nil
}

func activeLoginTokenResponse(claims *userjwt.Claims) introspectLoginTokenResponse {
	resp := introspectLoginTokenResponse{
		Active:             true,
		AccountID:          claims.AccountID,
		AccountUUID:        claims.AccountUUID,
		TenantID:           claims.ActTenantID,
		WorkspaceID:        claims.ActWorkspaceID,
		ActScope:           claims.ActScope,
		SessionUUID:        claims.SessionUUID,
		Perms:              append([]string(nil), claims.Perms...),
		PermsHash:          claims.PermsHash,
		MustChangePassword: claims.MustChange,
		Admin:              claims.Admin,
		ActingAs:           claims.ActingAs,
		Kind:               claims.Kind,
		Issuer:             claims.Issuer,
		Subject:            claims.Subject,
	}
	if claims.IssuedAt != nil {
		resp.IssuedAt = claims.IssuedAt.Time.Unix()
	}
	if claims.ExpiresAt != nil {
		resp.ExpiresAt = claims.ExpiresAt.Time.Unix()
		resp.CacheTTLSeconds = cacheTTLSeconds(claims.ExpiresAt.Time)
	}
	return resp
}

func cacheTTLSeconds(expiresAt time.Time) int {
	ttl := time.Until(expiresAt)
	if ttl <= 0 {
		return 0
	}
	if ttl > time.Minute {
		return 60
	}
	return int(ttl.Seconds())
}
