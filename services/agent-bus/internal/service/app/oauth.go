// oauth.go — F04 §3.5 OAuth2 token endpoint 业务支持。
//
// 提供给 transport/http/external/oauth_authorization_code.go (PR3 加) 用:
//   - ValidateClientCredentials: 校 client_id + client_secret 是否匹配
//   - ConsumeAuthorizationCode: 一次性消费 code (原子化, 防并发重放)
package app

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	pkgoauth2 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2"
)

// ValidateClientCredentials 校 client_id + client_secret; 失败返 ErrUnauthorized (防探测)。
//
// 同时更新 last_used_at (异步, 不阻塞主路径; v0.1 同步更新, v0.2 接 touch debounce)。
func (s *Service) ValidateClientCredentials(ctx context.Context, clientID, clientSecret string) (*dom.OAuthClient, error) {
	if clientID == "" || clientSecret == "" {
		return nil, apperr.ErrUnauthorized.Withf("client credentials required")
	}
	c, err := s.deps.OAuthClients.FindByClientID(ctx, clientID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.ErrUnauthorized.Withf("invalid client credentials")
		}
		return nil, err
	}
	if c.Status != "active" {
		return nil, apperr.ErrUnauthorized.Withf("client revoked")
	}
	if !pkgoauth2.VerifySecret(clientSecret, c.ClientSecretHash) {
		return nil, apperr.ErrUnauthorized.Withf("invalid client credentials")
	}
	// touch last_used_at (best-effort, 不报错)
	_ = s.deps.OAuthClients.TouchLastUsed(ctx, c.ID, s.now())
	return c, nil
}

// ConsumeAuthorizationCode 原子化消费 code (delegate to repo); 失败映射成 invalid_grant 语义。
//
// 调用方传 plaintext code (含 "ac_" 前缀); 本函数内部 hash 后查 + 消费。
func (s *Service) ConsumeAuthorizationCode(ctx context.Context, plaintextCode, redirectURI string, oauthClientID int64) (*dom.OAuthCode, error) {
	if plaintextCode == "" {
		return nil, apperr.ErrInvalidParams.Withf("code required")
	}
	codeHash := pkgoauth2.HashSecret(plaintextCode)
	row, err := s.deps.OAuthCodes.Consume(ctx, codeHash, redirectURI, oauthClientID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			// 一次性消费失败: code 不存在 / 已用 / 已过期 / redirect_uri 不匹配 / client_id 不匹配
			return nil, apperr.ErrUnauthorized.Withf("invalid_grant")
		}
		return nil, err
	}
	return row, nil
}

// IssueRefreshToken 颁发 refresh_token 长期凭证, 一次性返回明文 (含 "rt_" 前缀)。
//
// 调用方应在调 IssueRefreshToken 时确保 access_token 也已签发 (顺序: code 消费 → access_token + id_token + refresh_token 一组返出)。
func (s *Service) IssueRefreshToken(ctx context.Context, clientID, tenantID, accountID int64, scopes []string, ttl time.Duration) (string, error) {
	if s.deps.RefreshTokens == nil {
		return "", apperr.ErrInternal.Withf("refresh_tokens repo not wired")
	}
	if ttl <= 0 {
		ttl = s.deps.DefaultRefreshTokenTTL
	}
	body, err := pkgoauth2.GenRandomCode(32)
	if err != nil {
		return "", fmt.Errorf("gen refresh body: %w", err)
	}
	plaintext := "rt_" + body
	row := &dom.RefreshToken{
		TokenHash:     pkgoauth2.HashSecret(plaintext),
		OAuthClientID: clientID,
		TenantID:      tenantID,
		AccountID:     accountID,
		Scopes:        scopes,
		ExpiresAt:     s.now().Add(ttl),
	}
	if err := s.deps.RefreshTokens.Insert(ctx, row); err != nil {
		return "", fmt.Errorf("insert refresh_token: %w", err)
	}
	return plaintext, nil
}

// ConsumeRefreshToken 一次性消费 (rotate) refresh_token; 返原信息供上层签新 access_token + 新 refresh_token。
//
// 失败 (token 不存在 / 已撤销 / 已过期) 统一返 ErrUnauthorized invalid_grant。
func (s *Service) ConsumeRefreshToken(ctx context.Context, plaintextRefreshToken string) (*dom.RefreshToken, error) {
	if s.deps.RefreshTokens == nil {
		return nil, apperr.ErrInternal.Withf("refresh_tokens repo not wired")
	}
	if plaintextRefreshToken == "" {
		return nil, apperr.ErrInvalidParams.Withf("refresh_token required")
	}
	row, err := s.deps.RefreshTokens.ConsumeAndRotate(ctx, pkgoauth2.HashSecret(plaintextRefreshToken))
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.ErrUnauthorized.Withf("invalid_grant")
		}
		return nil, err
	}
	return row, nil
}

// IDTokenUserClaims JOIN 出 token endpoint 需要的用户身份 + tenant + conversation context。
//
// conversationID 为空时不查 conversations 表, ConversationID/Kind/Peer 全空。
func (s *Service) IDTokenUserClaims(ctx context.Context, accountID, tenantID int64, conversationID *int64) (*dom.IDTokenUserClaims, error) {
	if s.deps.Accounts == nil || s.deps.Tenants == nil {
		return nil, apperr.ErrInternal.Withf("accounts/tenants repo not wired")
	}
	acc, err := s.deps.Accounts.GetByID(ctx, accountID)
	if err != nil {
		return nil, err
	}
	tn, err := s.deps.Tenants.GetByID(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	claims := &dom.IDTokenUserClaims{
		AccountUUID:   acc.UUID,
		Email:         acc.Email,
		EmailVerified: acc.Email != "" && acc.EmailVerifiedAt != nil,
		Name:          acc.DisplayName,
		PhoneNumber:   acc.Phone,
		TenantUUID:    tn.UUID,
		TenantName:    tn.Name,
	}
	// membership (employee_no / title / department)
	mem, err := s.deps.Accounts.GetMembership(ctx, accountID, tenantID)
	if err != nil && !errors.Is(err, apperr.ErrNotFound) {
		return nil, err
	}
	if mem != nil {
		claims.EmployeeNo = mem.EmployeeID
		claims.Title = mem.Title
		claims.Department = displayDepartmentPath(mem.DepartmentPath)
	}
	// conversation context
	if conversationID != nil {
		if s.deps.Conversations == nil {
			return nil, apperr.ErrInternal.Withf("conversations repo not wired")
		}
		conv, err := s.deps.Conversations.GetByID(ctx, *conversationID)
		if err != nil {
			return nil, err
		}
		if conv == nil || conv.TenantID != tenantID || conv.AccountID != accountID {
			return nil, apperr.ErrUnauthorized.Withf("conversation scope mismatch")
		}
		claims.ConversationID = conv.UUID
		if conv.DigitalEmployeeID != nil {
			if s.deps.Agents == nil {
				return nil, apperr.ErrInternal.Withf("agents repo not wired")
			}
			agent, err := s.deps.Agents.GetByID(ctx, *conv.DigitalEmployeeID)
			if err != nil {
				return nil, err
			}
			claims.ConversationKind = "agent_chat"
			claims.PeerKind = "agent"
			claims.PeerUUID = agent.UUID
			claims.PeerName = agent.Name
		} else if conv.RoomID != nil {
			// dm / group 区分: 当前 conversations schema 没有显式 kind, 暂归 "group" (F09 完善时再细化)
			claims.ConversationKind = "group"
		}
	}
	return claims, nil
}

func displayDepartmentPath(path string) string {
	parts := strings.FieldsFunc(path, func(r rune) bool { return r == '/' })
	return strings.Join(parts, " / ")
}

// ConsumeRefreshTokenForClient atomically scopes refresh rotation to the authenticated client.
func (s *Service) ConsumeRefreshTokenForClient(ctx context.Context, plaintext string, clientID int64) (*dom.RefreshToken, error) {
	repo, ok := s.deps.RefreshTokens.(interface {
		ConsumeAndRotateForClient(context.Context, string, int64) (*dom.RefreshToken, error)
	})
	if !ok {
		return nil, apperr.ErrInternal.Withf("client-scoped refresh repository required")
	}
	if plaintext == "" || clientID <= 0 {
		return nil, apperr.ErrUnauthorized.Withf("invalid_grant")
	}
	row, err := repo.ConsumeAndRotateForClient(ctx, pkgoauth2.HashSecret(plaintext), clientID)
	if errors.Is(err, apperr.ErrNotFound) {
		return nil, apperr.ErrUnauthorized.Withf("invalid_grant")
	}
	return row, err
}
