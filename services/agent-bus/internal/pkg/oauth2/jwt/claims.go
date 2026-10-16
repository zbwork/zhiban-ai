// Package jwt 是 F04 OAuth2 / OIDC 的 RS256 JWT 签验。
//
// 跟 internal/pkg/jwt/ (Ed25519, 用户登录) 不同:
//   - 算法 RS256 (OIDC 生态标准, 业内 SDK 都直接 verify; Ed25519 支持度参差)
//   - 走 keys.Manager 多 kid (active + retiring 共存, 支持 zero-downtime rotation)
//   - claim 结构是 OAuth2 / OIDC 标准 (sub/aud/iss/exp/iat + zhiban 扩展)
//
// 用户登录 JWT 走 internal/pkg/jwt; 应用 OAuth JWT 走本包。两者签名密钥独立, 用途独立。
//
// 实现库: github.com/go-jose/go-jose/v4 (Ory hydra / kubernetes 主流, 跟 coreos/go-oidc 同一系)。
package jwt

import (
	"time"
)

const (
	AccessTokenAudience = "zhiban-agent-bus"
	AccessTokenKind     = "app_oauth"

	LocalCodingTokenAudience = "zhiban-model-gateway"
	LocalCodingTokenKind     = "local_coding_tool"
	LocalCodingTokenMaxTTL   = 15 * time.Minute
)

// IDTokenClaims 是 F04 id_token 的 claim 集合 (OIDC 标准 + zhiban 扩展)。
//
// 由 token endpoint 在 authorization_code grant 成功后填充。
//
// 序列化后字段名 (按 go-jose 默认 + json tag):
//
//	iss, aud, sub, iat, exp, nonce, email, email_verified,
//	name, phone_number, tenant, membership, zhiban_context
type IDTokenClaims struct {
	// 标准 RFC 7519 claims
	Issuer    string `json:"iss"`
	Audience  string `json:"aud"` // = client_id (单值)
	Subject   string `json:"sub"` // accounts.uuid
	IssuedAt  int64  `json:"iat"`
	ExpiresAt int64  `json:"exp"`
	Nonce     string `json:"nonce,omitempty"`

	// OIDC standard claims
	Email         string `json:"email,omitempty"`
	EmailVerified *bool  `json:"email_verified,omitempty"`
	Name          string `json:"name,omitempty"`
	PhoneNumber   string `json:"phone_number,omitempty"`

	// F04 扩展: tenant + membership (从 tenant_memberships JOIN 出来)
	Tenant     *TenantClaim     `json:"tenant,omitempty"`
	Membership *MembershipClaim `json:"membership,omitempty"`

	// F04 扩展: zhiban_context (会话上下文; 详见 F04 §3.5 + §14 D10)
	ZhibanContext *ZhibanContext `json:"zhiban_context,omitempty"`
}

// AccessTokenClaims 是 F04 access_token 的 claim 集合 (应用反向调 Bus 时出示)。
//
// 用 JWT 而不是 opaque token, 让 Bus middleware 自包含验证 (不查 DB), F04 §14 D11 决策。
type AccessTokenClaims struct {
	Issuer    string   `json:"iss"`
	Audience  []string `json:"aud"` // ["zhiban-agent-bus"]
	Subject   string   `json:"sub"` // accounts.uuid
	IssuedAt  int64    `json:"iat"`
	ExpiresAt int64    `json:"exp"`
	JWTID     string   `json:"jti,omitempty"` // 防 replay 黑名单 (v0.2)

	ClientID string   `json:"client_id"` // app_xxx
	TenantID int64    `json:"tenant_id"` // 数值 ID, 跟 F01 JWT 同款
	Scopes   []string `json:"scopes"`    // 改成 array 比 OAuth2 标准 "scope" 字符串更易解析
	Kind     string   `json:"kind"`      // "app_oauth"; middleware 分发用
}

// LocalCodingAccessTokenClaims 是 F31 本地编程工具访问模型网关的短期 JWT。
//
// 它复用 F04 的 RS256 多 kid/JWKS 密钥基础设施，但通过独立 audience、kind、target
// 和单一 scope 与应用 OAuth token 隔离。设备交换授权本身不能作为该 token 使用。
type LocalCodingAccessTokenClaims struct {
	Issuer    string   `json:"iss"`
	Audience  []string `json:"aud"`
	Subject   string   `json:"sub"` // accounts.uuid
	IssuedAt  int64    `json:"iat"`
	ExpiresAt int64    `json:"exp"`
	JWTID     string   `json:"jti"`

	TenantID       string   `json:"tenant_id"`
	DeviceID       string   `json:"device_id"`
	TargetID       string   `json:"target_id"`
	ProfileVersion string   `json:"profile_version"`
	Scopes         []string `json:"scope"`
	Kind           string   `json:"kind"`
}

// TenantClaim id_token 内 tenant 子结构。
type TenantClaim struct {
	UUID string `json:"uuid"`
	Name string `json:"name"`
}

// MembershipClaim id_token 内 membership 子结构 (从 tenant_memberships + departments JOIN)。
type MembershipClaim struct {
	EmployeeNo string `json:"employee_no,omitempty"`
	Title      string `json:"title,omitempty"`
	Department string `json:"department,omitempty"`
}

// ZhibanContext id_token 内 F04 专属扩展 (会话上下文)。
type ZhibanContext struct {
	ConversationID   string   `json:"conversation_id,omitempty"`
	ConversationKind string   `json:"conversation_kind,omitempty"` // agent_chat | dm | group
	Peer             *PeerRef `json:"peer,omitempty"`
}

// PeerRef 对话另一方 (dm / group 时有; agent_chat 时是 agent).
type PeerRef struct {
	Kind string `json:"kind,omitempty"` // agent | account | group
	UUID string `json:"uuid,omitempty"`
	Name string `json:"name,omitempty"`
}

// =====================================================
// 构造帮助函数
// =====================================================

// NewIDTokenClaims 用当前时间 + TTL 构造一份 base claim。
//
// 调用方填好其余字段后, 用 Signer.SignID 出 JWT。
func NewIDTokenClaims(now time.Time, issuer, audience, subject string, ttl time.Duration) IDTokenClaims {
	return IDTokenClaims{
		Issuer:    issuer,
		Audience:  audience,
		Subject:   subject,
		IssuedAt:  now.Unix(),
		ExpiresAt: now.Add(ttl).Unix(),
	}
}

// NewAccessTokenClaims 同上。
func NewAccessTokenClaims(now time.Time, issuer, audience, subject, clientID string, tenantID int64, scopes []string, ttl time.Duration) AccessTokenClaims {
	return AccessTokenClaims{
		Issuer:    issuer,
		Audience:  []string{audience},
		Subject:   subject,
		IssuedAt:  now.Unix(),
		ExpiresAt: now.Add(ttl).Unix(),
		ClientID:  clientID,
		TenantID:  tenantID,
		Scopes:    scopes,
		Kind:      AccessTokenKind,
	}
}

// NewLocalCodingAccessTokenClaims 构造目标和 scope 固定绑定的短期模型网关 token。
// 调用方不能自行传 scope，避免把设备授权升级为任意模型网关权限。
func NewLocalCodingAccessTokenClaims(
	now time.Time,
	issuer, subject, tenantID, deviceID, targetID, profileVersion, jwtID string,
	ttl time.Duration,
) (LocalCodingAccessTokenClaims, error) {
	scope, ok := localCodingScopeForTarget(targetID)
	if !ok || issuer == "" || !isSafeLocalCodingIdentifier(subject) ||
		!isSafeLocalCodingIdentifier(tenantID) || !isSafeLocalCodingIdentifier(deviceID) ||
		!isSafeLocalCodingIdentifier(profileVersion) || !isSafeLocalCodingIdentifier(jwtID) ||
		ttl <= 0 || ttl > LocalCodingTokenMaxTTL {
		return LocalCodingAccessTokenClaims{}, ErrInvalidLocalCodingTokenClaims
	}
	return LocalCodingAccessTokenClaims{
		Issuer:         issuer,
		Audience:       []string{LocalCodingTokenAudience},
		Subject:        subject,
		IssuedAt:       now.Unix(),
		ExpiresAt:      now.Add(ttl).Unix(),
		JWTID:          jwtID,
		TenantID:       tenantID,
		DeviceID:       deviceID,
		TargetID:       targetID,
		ProfileVersion: profileVersion,
		Scopes:         []string{scope},
		Kind:           LocalCodingTokenKind,
	}, nil
}

func isSafeLocalCodingIdentifier(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '-' || char == '_' || char == '.' || char == ':' {
			continue
		}
		return false
	}
	return true
}

func localCodingScopeForTarget(targetID string) (string, bool) {
	switch targetID {
	case "codex_cli":
		return "responses:invoke", true
	case "claude_cli":
		return "messages:invoke", true
	default:
		return "", false
	}
}
