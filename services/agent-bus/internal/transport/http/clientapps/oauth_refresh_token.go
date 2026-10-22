// oauth_refresh_token.go — F04 §3.5 refresh_token grant: rotate refresh + 重签 access_token/id_token。
//
//	Body  : { grant_type:"refresh_token", refresh_token, client_id, client_secret }
//	Return: { access_token, id_token, refresh_token (NEW), token_type:"Bearer", expires_in, scope }
//
// 安全: 老 refresh_token 一次性 (consumed_at=now() + revoked_at=now()), 新 refresh_token rotate 出去。
package clientapps

import (
	"context"
	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	"net/http"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/jwt"
)

func (h *Handlers) oauthRefreshTokenGrant(w http.ResponseWriter, r *http.Request, req oauthTokenReq) {
	if h.App == nil || h.JWTSigner == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app oauth not wired"))
		return
	}
	if req.RefreshToken == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("refresh_token required"))
		return
	}

	// 1. 校 client
	oc, err := h.App.ValidateClientCredentials(r.Context(), req.ClientID, req.ClientSecret)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if oc.Status != "active" {
		encode.JSONError(w, apperr.ErrUnauthorized.Withf("client revoked"))
		return
	}

	// 2. 消费老 refresh_token (rotate)
	scoped, ok := h.App.(interface {
		ConsumeRefreshTokenForClient(context.Context, string, int64) (*domapp.RefreshToken, error)
	})
	if !ok {
		encode.JSONError(w, apperr.ErrInternal)
		return
	}
	row, err := scoped.ConsumeRefreshTokenForClient(r.Context(), req.RefreshToken, oc.ID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// 校 row.oauth_client_id 一致 (防 cross-client 用别人的 refresh_token)
	if row.OAuthClientID != oc.ID {
		encode.JSONError(w, apperr.ErrUnauthorized.Withf("invalid_grant"))
		return
	}

	// 3. 重拼 id_token claims (此时没有 conversation 上下文; refresh 走业务静态身份就行)
	uc, err := h.App.IDTokenUserClaims(r.Context(), row.AccountID, row.TenantID, nil)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	now := time.Now()
	accessTTL := time.Duration(oc.AccessTokenTTLSeconds) * time.Second
	if accessTTL <= 0 {
		accessTTL = 2 * time.Hour
	}

	accessClaims := jwt.NewAccessTokenClaims(now, h.Issuer, jwt.AccessTokenAudience, uc.AccountUUID, oc.ClientID, row.TenantID, row.Scopes, accessTTL)
	accessToken, err := h.JWTSigner.SignAccessToken(r.Context(), accessClaims)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	idClaims := jwt.NewIDTokenClaims(now, h.Issuer, oc.ClientID, uc.AccountUUID, accessTTL)
	idClaims.Email = uc.Email
	if uc.Email != "" {
		idClaims.EmailVerified = &uc.EmailVerified
	}
	idClaims.Name = uc.Name
	idClaims.PhoneNumber = uc.PhoneNumber
	if uc.TenantUUID != "" {
		idClaims.Tenant = &jwt.TenantClaim{UUID: uc.TenantUUID, Name: uc.TenantName}
	}
	if uc.EmployeeNo != "" || uc.Title != "" || uc.Department != "" {
		idClaims.Membership = &jwt.MembershipClaim{
			EmployeeNo: uc.EmployeeNo, Title: uc.Title, Department: uc.Department,
		}
	}
	idToken, err := h.JWTSigner.SignIDToken(r.Context(), idClaims)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	// 4. 新 refresh_token (TTL 继承 client 配置)
	refreshTTL := time.Duration(oc.RefreshTokenTTLSeconds) * time.Second
	newRefresh, err := h.App.IssueRefreshToken(r.Context(), oc.ID, row.TenantID, row.AccountID, row.Scopes, refreshTTL)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if auditor, ok := h.App.(interface {
		AuditOAuthToken(ctx context.Context, tenantID int64, clientID, grantType, accountUUID string)
	}); ok {
		auditor.AuditOAuthToken(r.Context(), row.TenantID, oc.ClientID, "refresh_token", uc.AccountUUID)
	}

	writeOAuthTokenJSON(w, oauthTokenAppResp{
		AccessToken:  accessToken,
		IDToken:      idToken,
		RefreshToken: newRefresh,
		TokenType:    "Bearer",
		ExpiresIn:    int(accessTTL.Seconds()),
		Scope:        strings.Join(row.Scopes, " "),
	})
}
