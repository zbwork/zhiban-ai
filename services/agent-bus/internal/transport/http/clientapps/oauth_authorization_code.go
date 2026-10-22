// oauth_authorization_code.go — F04 §3.5 应用 OAuth2 token endpoint 的 authorization_code 分支。
//
//	Body  : { grant_type:"authorization_code", code, client_id, client_secret, redirect_uri }
//	Return: { access_token (JWT), id_token (JWT), refresh_token (rt_*), token_type:"Bearer", expires_in, scope }
//
// 安全约束:
//   - redirect_uri exact match (跟 app_oauth_codes 落库的一致)
//   - code 一次性消费 (UPDATE ... WHERE consumed_at IS NULL RETURNING 原子化)
//   - 跨 client_id 拿别人 code → ConsumeAuthorizationCode 内部强校 oauth_client_id 一致
package clientapps

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2/jwt"
)

type oauthTokenAppResp struct {
	AccessToken  string `json:"access_token"`
	IDToken      string `json:"id_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	Scope        string `json:"scope"`
}

func (h *Handlers) oauthAuthorizationCodeGrant(w http.ResponseWriter, r *http.Request, req oauthTokenReq) {
	if h.App == nil || h.JWTSigner == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("app oauth not wired"))
		return
	}
	if req.Code == "" || req.RedirectURI == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("code/redirect_uri required"))
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

	// 2. 消费 code (原子化, 校 redirect_uri exact match + client 一致)
	code, err := h.App.ConsumeAuthorizationCode(r.Context(), req.Code, req.RedirectURI, oc.ID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}

	// 3. 拼 id_token 用户身份 claims。授权码已绑定并校验 conversation_id，
	// 由应用服务在同租户、同账号范围内回读会话，补齐 zhiban_context。
	uc, err := h.App.IDTokenUserClaims(r.Context(), code.AccountID, code.TenantID, code.ConversationID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}

	now := time.Now()
	accessTTL := time.Duration(oc.AccessTokenTTLSeconds) * time.Second
	if accessTTL <= 0 {
		accessTTL = 2 * time.Hour
	}

	// 4. 签 access_token (JWT)
	accessClaims := jwt.NewAccessTokenClaims(
		now,
		h.Issuer,                // iss
		jwt.AccessTokenAudience, // aud
		uc.AccountUUID,          // sub
		oc.ClientID,             // client_id
		code.TenantID,           // tenant_id
		code.Scopes,             // scopes
		accessTTL,
	)
	accessToken, err := h.JWTSigner.SignAccessToken(r.Context(), accessClaims)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	// 5. 签 id_token (JWT)
	idClaims := jwt.NewIDTokenClaims(now, h.Issuer, oc.ClientID, uc.AccountUUID, accessTTL)
	idClaims.Email = uc.Email
	if uc.Email != "" {
		idClaims.EmailVerified = &uc.EmailVerified
	}
	idClaims.Name = uc.Name
	idClaims.PhoneNumber = uc.PhoneNumber
	idClaims.Nonce = code.Nonce
	if uc.TenantUUID != "" {
		idClaims.Tenant = &jwt.TenantClaim{UUID: uc.TenantUUID, Name: uc.TenantName}
	}
	if uc.EmployeeNo != "" || uc.Title != "" || uc.Department != "" {
		idClaims.Membership = &jwt.MembershipClaim{
			EmployeeNo: uc.EmployeeNo, Title: uc.Title, Department: uc.Department,
		}
	}
	if uc.ConversationID != "" || uc.PeerKind != "" {
		zc := &jwt.ZhibanContext{
			ConversationID:   uc.ConversationID,
			ConversationKind: uc.ConversationKind,
		}
		if uc.PeerKind != "" {
			zc.Peer = &jwt.PeerRef{Kind: uc.PeerKind, UUID: uc.PeerUUID, Name: uc.PeerName}
		}
		idClaims.ZhibanContext = zc
	}
	idToken, err := h.JWTSigner.SignIDToken(r.Context(), idClaims)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}

	// 6. 颁 refresh_token
	refreshTTL := time.Duration(oc.RefreshTokenTTLSeconds) * time.Second
	plaintextRefresh, err := h.App.IssueRefreshToken(r.Context(), oc.ID, code.TenantID, code.AccountID, code.Scopes, refreshTTL)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if auditor, ok := h.App.(interface {
		AuditOAuthToken(ctx context.Context, tenantID int64, clientID, grantType, accountUUID string)
	}); ok {
		auditor.AuditOAuthToken(r.Context(), code.TenantID, oc.ClientID, "authorization_code", uc.AccountUUID)
	}

	writeOAuthTokenJSON(w, oauthTokenAppResp{
		AccessToken:  accessToken,
		IDToken:      idToken,
		RefreshToken: plaintextRefresh,
		TokenType:    "Bearer",
		ExpiresIn:    int(accessTTL.Seconds()),
		Scope:        strings.Join(code.Scopes, " "),
	})
}
