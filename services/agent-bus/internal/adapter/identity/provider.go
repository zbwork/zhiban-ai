// Package identity 是企业 SSO / 自动 provisioning 适配层 (F01 §4.3 + §10.1)。
//
// 设计目标:
//   - 解耦 OIDC / SAML / LDAP / SCIM 协议差异; auth service 只跟 Provider 接口对话
//   - 多租户: tenant_identity_providers 表 (M4 migration 000054) 记录每租户的 IdP 配置
//   - 单一登录 endpoint /api/agent-bus/v1/auth/login/oidc/callback 仍是入口,
//     handler 内按 issuer 反查租户 + Provider, 用 adapter 校验后落 acct/session
//
// M4 落地范围:
//   - oidc/ 子包接入 coreos/go-oidc v3 (实现 Provider 接口)
//   - saml/ ldap/ scim/ 留接口预留, 实际落地到 M4.x / M8+
package identity

import (
	"context"
	"time"
)

// ProviderKind 区分协议类型, 与 tenant_identity_providers.kind 列同源。
type ProviderKind string

const (
	KindOIDC ProviderKind = "oidc"
	KindSAML ProviderKind = "saml"
	KindLDAP ProviderKind = "ldap"
	KindSCIM ProviderKind = "scim"
)

// Profile 是从外部 IdP 拿到 (已校验) 的用户信息标准映射。
//
// 不同协议字段差很大, 这里取 LCS:
//   - Subject     用户在 IdP 侧的稳定唯一标识 (OIDC: sub; SAML: NameID; LDAP: DN)
//   - Email/Name  常见
//   - Groups      可选, 用于 group 同步 / role 自动绑定
//   - Raw         保留原始 claims 供 admin 调试
type Profile struct {
	Subject string         `json:"subject"`
	Email   string         `json:"email,omitempty"`
	Name    string         `json:"name,omitempty"`
	Phone   string         `json:"phone,omitempty"`
	Groups  []string       `json:"groups,omitempty"`
	Raw     map[string]any `json:"raw,omitempty"`
}

// Config 是租户配 IdP 时录入的字段; provider-agnostic 形式。
//
// 不同 ProviderKind 各取所需 (例 OIDC 用 Issuer/ClientID/Secret;
// SAML 用 Metadata XML; LDAP 用 BindDN/BindPassword/BaseDN)。
type Config struct {
	TenantID    int64          `json:"tenant_id"`
	Kind        ProviderKind   `json:"kind"`
	Name        string         `json:"name"`             // 显示名 "招行 SSO"
	Issuer      string         `json:"issuer,omitempty"` // OIDC discovery 起点 / SAML EntityID
	ClientID    string         `json:"client_id,omitempty"`
	ClientSec   string         `json:"client_secret,omitempty"`
	RedirectURI string         `json:"redirect_uri,omitempty"`
	Scopes      []string       `json:"scopes,omitempty"`
	Settings    map[string]any `json:"settings,omitempty"` // 协议私有字段; OIDC 也可放 acr_values 等
}

// Provider 是协议适配器统一接口; 不同 ProviderKind 实现各自版本。
//
// OIDC 实现重点: ExchangeCode + Verify ID Token; 不强行让 LDAP 同款返回 (LDAP 走密码绑定)。
// 对于 callback handler, 只用 ExchangeCode 这一条路径; 其它扩展点 (LDAP 直连鉴权) 走另外的接口。
type Provider interface {
	Kind() ProviderKind
	// ExchangeCode 完成 OIDC authorization_code grant 或 SAML AssertionConsumerService 的等价交换。
	// 不适用的 provider (如 LDAP) 返回 ErrNotSupported。
	ExchangeCode(ctx context.Context, code, state string) (*Profile, error)
}

// LeasedProvider 是从 Registry 取到的"租约期内有效的 Provider" — 注意 Provider
// 可能内含网络资源 (OIDC discovery 缓存), 在租期外不应继续持有。
type LeasedProvider struct {
	Cfg      Config
	Provider Provider
	LeaseEnd time.Time
}

// Registry 给 callback handler 用: 按 issuer / tenant 拿 Provider。
//
// M4 实现见 internal/service/identity/registry.go (M4 落地后补)。
type Registry interface {
	// ResolveByIssuer 用 issuer (OIDC) 反查; LDAP/SAML 走其它路径。
	ResolveByIssuer(ctx context.Context, issuer string) (*LeasedProvider, error)
	// ResolveByTenant 单租户场景直接拿。
	ResolveByTenant(ctx context.Context, tenantID int64) (*LeasedProvider, error)
}

// ErrNotSupported 由 provider 抛出, 表示当前协议不支持该方法。
type providerError string

func (e providerError) Error() string { return string(e) }

const (
	ErrNotSupported  providerError = "identity provider: operation not supported by this kind"
	ErrNotConfigured providerError = "identity provider: tenant not configured"
)
