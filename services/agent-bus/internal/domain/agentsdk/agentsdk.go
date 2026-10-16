// Package agentsdk 是 F01 §3.6 场景 6 自定义 Agent SDK 接入的领域模型。
//
// 两张表领域映射:
//   - Credential ↔ agent_sdk_credentials (长期 client_id+secret)
//   - SessionToken ↔ session_tokens (短期会话凭证 st_<prefix>_<secret>)
//
// 设计要点:
//   - capability_bindings 是 scope 白名单列表; session_token 拷自 credential, 可缩。
//   - 明文 secret / session_token 只在 Issue 时一次性返回; 入库前 sha256。
//   - 与 apikey 完全分离: client_id 前缀 `agentsdk_`; session token 前缀 `st_`。
package agentsdk

import (
	"context"
	"errors"
	"time"
)

// Credential ↔ agent_sdk_credentials 一行。
type Credential struct {
	ID                   int64
	UUID                 string
	TenantID             int64 // 0 = platform-scoped credential, tenant_id IS NULL in DB
	CreatorID            int64
	Name                 string
	ClientID             string
	ClientSecretHash     string
	CapabilityBindings   []string
	RuntimeEnvironmentID *int64
	Scope                string // tenant / platform
	LastUsedAt           *time.Time
	Status               string
	CreatedAt            time.Time
	UpdatedAt            time.Time
	RevokedAt            *time.Time
	TenantGrantMode      string  // platform credential only: all_enabled / allowlist
	AllowedTenantIDs     []int64 // platform credential only: explicit tenant allowlist snapshot
}

const (
	PlatformTenantGrantAllEnabled = "all_enabled"
	PlatformTenantGrantAllowlist  = "allowlist"
)

// SessionToken ↔ session_tokens 一行。
//
// F01 §3.6.3 (F09 Phase B PR4.5): ParentSessionID 非 nil 表示该 token 由
// 一条父 session 派生而来 (A2A 调用场景); nil 表示直接由 credential 颁发 (master session).
type SessionToken struct {
	ID                   int64
	UUID                 string
	CredentialID         int64
	TenantID             int64
	AccountID            *int64
	ConversationID       *int64
	AgentID              *int64
	RuntimeEnvironmentID *int64
	ParentSessionID      *int64 // F09 PR4.5: 派生链锚点; NULL = master session
	TokenPrefix          string
	TokenHash            string
	CapabilityBindings   []string
	IssuedAt             time.Time
	ExpiresAt            time.Time
	LastUsedAt           *time.Time
	Status               string
	RevokedAt            *time.Time
}

// CredentialRepo ↔ agent_sdk_credentials 仓储。
type CredentialRepo interface {
	Insert(ctx context.Context, c *Credential) error
	SetTenantGrants(ctx context.Context, credentialID int64, mode string, tenantIDs []int64) error
	FindByClientID(ctx context.Context, clientID string) (*Credential, error)
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*Credential, error)
	GetPlatformByUUID(ctx context.Context, uuid string) (*Credential, error)
	GetByID(ctx context.Context, id int64) (*Credential, error)
	ListByTenant(ctx context.Context, tenantID int64) ([]Credential, error)
	ListPlatform(ctx context.Context) ([]Credential, error)
	IsTenantAllowedForPlatformCredential(ctx context.Context, credentialID, tenantID int64) (bool, string, error)
	Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*Credential, error)
	Revoke(ctx context.Context, tenantID int64, uuid string) error
	RevokePlatform(ctx context.Context, uuid string) error
	TouchLastUsed(ctx context.Context, id int64, ts time.Time) error
}

// SessionTokenRepo ↔ session_tokens 仓储。
type SessionTokenRepo interface {
	Insert(ctx context.Context, t *SessionToken) error
	FindByPrefix(ctx context.Context, prefix string) (*SessionToken, error)
	// GetByID 按主键查; F01 §3.6.3 链路 validate 沿 parent_session_id 回溯时用.
	GetByID(ctx context.Context, id int64) (*SessionToken, error)
	Revoke(ctx context.Context, uuid string) error
	// RevokeByCredential 级联撤销该 credential 颁发的所有 active session_tokens
	// (F01 §3.6 D8a: revoke credential 必须杀掉已发的 token, 防"撤销 credential 但 token 还能用"语义漏洞)。
	RevokeByCredential(ctx context.Context, credentialID int64) (int64, error)
	// RevokeByRuntimeEnvironment 级联撤销某 runtime 环境下所有 active session_tokens。
	RevokeByRuntimeEnvironment(ctx context.Context, runtimeEnvironmentID int64) (int64, error)
	// RevokeChain (F01 §3.6.3 / F09 PR4.5) 沿 parent_session_id 正向 cascade 撤销
	// 给定 root session 自己 + 所有 descendants (派生子孙 session). 返撤销行数.
	RevokeChain(ctx context.Context, rootID int64) (int64, error)
	// RevokeChainByUUID 是 RevokeChain 的 UUID 入口 (chat 服务 / admin revoke endpoint 用).
	// 行为同 RevokeChain: 同时 cascade 给所有 descendants.
	RevokeChainByUUID(ctx context.Context, uuid string) (int64, error)
	// CleanupExpired 删 expires_at <= now() + (revoked_at IS NOT NULL AND revoked_at < now() - 7d) 的行。
	CleanupExpired(ctx context.Context) (int64, error)
	TouchLastUsed(ctx context.Context, id int64, ts time.Time) error
}

// Identity 中间件 ValidateSessionToken 通过后返回给业务层。
//
// 注意: tenant-scoped Agent SDK token 可不带 AccountID; Runtime Access Token
// 绑定 TenantID / RuntimeEnvironmentID。具体 agent/user 由业务接口入参校验。
type Identity struct {
	SessionTokenID       int64
	CredentialID         int64
	TenantID             int64
	AccountID            int64 // 0 = 未绑定用户
	ConversationID       int64 // 0 = 通用
	AgentID              int64 // 0 = 通用
	RuntimeEnvironmentID int64 // 0 = 未绑定 runtime
	CapabilityBindings   []string
}

const (
	CredentialScopeTenant   = "tenant"
	CredentialScopePlatform = "platform"
)

type RuntimeAccessRequest struct {
	TenantID string
	// AgentUUID (A2A v1a, ADR-0030 修订记录) 可选: 换发时把 st_ 绑定到发起方数字员工。
	// 对外一律 UUID; 内部解析成 bigint 后写 session_tokens.agent_id。空串 = 不绑定 (旧行为)。
	AgentUUID string
	// AccountUUID (A2A v1m): 可选, 外部自定义 Agent 在用户会话上下文中调用平台托管
	// OpenClaw/Hermes 时用于绑定用户账号范围。resolver 必须校验账号属于目标租户 active membership。
	AccountUUID string
	// AccountID / ConversationID 仅供 Bus 内部 runtime 工具代理填充。
	AccountID      *int64
	ConversationID *int64
	TTL            time.Duration
}

type RuntimeAccessResolution struct {
	TenantID             int64
	RuntimeEnvironmentID int64
	// AccountID 仅当请求带 AccountUUID 且通过租户成员校验时非 nil。
	AccountID *int64
	// AgentID 仅当请求带 AgentUUID 且通过 ValidateRuntimeAccessAgentBinding 时非 nil。
	AgentID *int64
}

// ErrRuntimeAccessAgentNotAllowed 换发期 agent 绑定校验失败的统一哨兵 (防探测: 不区分不存在/跨租户/未发布/跨 runtime)。
// repo/transport 层映射为 Forbidden。
var ErrRuntimeAccessAgentNotAllowed = errors.New("agentsdk: runtime access agent not allowed")

// RuntimeAccessAgentFacts 是 resolver 从 digital_employees 取出的、用于换发期 agent 绑定校验的事实子集。
type RuntimeAccessAgentFacts struct {
	ID                   int64
	TenantID             int64
	RuntimeEnvironmentID *int64
	Status               string
	IsDeleted            bool
}

// ValidateRuntimeAccessAgentBinding (A2A v1a) 校验换发请求里的 agent 绑定。纯函数, 便于单测;
// PG resolver 取行后调用。fail-closed: 任一不满足即拒, 错误统一模糊 (不做存在性 oracle)。
//
//  1. agent 未软删且属于目标 tenant;
//  2. agent status='published';
//  3. agent 绑定的 runtime_environment_id == 换发凭证解析出的 runtime env。
func ValidateRuntimeAccessAgentBinding(f RuntimeAccessAgentFacts, tenantID, runtimeEnvironmentID int64) error {
	if f.ID <= 0 || f.IsDeleted || f.TenantID != tenantID {
		return ErrRuntimeAccessAgentNotAllowed
	}
	if f.Status != "published" {
		return ErrRuntimeAccessAgentNotAllowed
	}
	if f.RuntimeEnvironmentID == nil || *f.RuntimeEnvironmentID != runtimeEnvironmentID {
		return ErrRuntimeAccessAgentNotAllowed
	}
	return nil
}

type RuntimeAccessResolver interface {
	ResolveRuntimeAccess(ctx context.Context, cred *Credential, req RuntimeAccessRequest) (*RuntimeAccessResolution, error)
	ResolveRuntimeAccessAgent(ctx context.Context, agentUUID string, tenantID, runtimeEnvironmentID int64) (int64, error)
}

// Service 业务层接口。
type Service interface {
	// IssueCredential 颁发 client_id+secret; 一次性返回明文 secret。
	IssueCredential(ctx context.Context, tenantID, creatorID int64, name string, capabilities []string, runtimeRegistrationID *int64) (*Credential, string, error)
	// IssuePlatformCredential 颁发 platform-scoped runtime 换发凭证; tenant_id 为 NULL, 必须绑定 runtime_environment_id。
	IssuePlatformCredential(ctx context.Context, creatorID int64, name string, capabilities []string, runtimeEnvironmentID int64, tenantGrantMode string, allowedTenantIDs []int64) (*Credential, string, error)
	// ListCredentials 租户视角列表 (不返 hash, 不返明文)。
	ListCredentials(ctx context.Context, tenantID int64) ([]Credential, error)
	// ListPlatformCredentials 平台视角列表 (不返 hash, 不返明文)。
	ListPlatformCredentials(ctx context.Context) ([]Credential, error)
	GetCredential(ctx context.Context, tenantID int64, uuid string) (*Credential, error)
	// PatchCredential 修改 name / capability_bindings。
	PatchCredential(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*Credential, error)
	RevokeCredential(ctx context.Context, tenantID int64, uuid string) error
	RevokePlatformCredential(ctx context.Context, uuid string) error
	// ValidateClientCredentials 校验 client_id + client_secret; 通过返 Credential。
	ValidateClientCredentials(ctx context.Context, clientID, clientSecret string) (*Credential, error)
	// IssueSessionToken 用 Credential 颁发短期 token (默认 60min)。capabilities 必须是 credential.capability_bindings 子集。
	IssueSessionToken(ctx context.Context, credentialID int64, conversationID, agentID *int64, capabilities []string, ttl time.Duration) (*SessionToken, string, error)
	// IssueRuntimeAccessToken 颁发平台/租户 Runtime backchannel 短期 token。
	IssueRuntimeAccessToken(ctx context.Context, credentialID int64, req RuntimeAccessRequest) (*SessionToken, string, error)
	// ResolveRuntimeAccessAgent 在业务请求期按 token tenant/runtime 校验动态 agent_id。
	ResolveRuntimeAccessAgent(ctx context.Context, agentUUID string, tenantID, runtimeEnvironmentID int64) (int64, error)
	// IssueDerivedSessionToken (F01 §3.6.3 / F09 PR4.5) 用一条 active session_token 派生子 session.
	//
	// 规则:
	//   - parent 必须 active 且未过期 + 链路上所有 ancestor 也都 active
	//   - 顶层 credential 必须 active
	//   - child capabilities ⊆ parent.capability_bindings (允许等集; IsSubset)
	//   - child TTL ≤ min(MaxSessionTokenTTL, parent 剩余 TTL)
	//   - child tenant_id 强制 = parent.tenant_id (跨租户立即 ErrForbidden)
	//   - child agent_id = targetAgentID (调用方指定; 用于 A2A "调谁")
	//   - child conversation_id 继承 parent.conversation_id
	IssueDerivedSessionToken(ctx context.Context, parentSessionTokenID int64, targetAgentID int64, capabilities []string, ttl time.Duration) (*SessionToken, string, error)
	// ValidateSessionToken 解析 Bearer st_*; 失败统一返 ErrUnauthorized (防探测)。
	ValidateSessionToken(ctx context.Context, raw string) (*Identity, error)
	// RevokeSessionToken 主动撤销 (chat 服务在会话结束时调).
	// F01 §3.6.3 (F09 PR4.5): 撤销时沿 parent_session_id 正向级联撤销所有 descendant.
	RevokeSessionToken(ctx context.Context, uuid string) error
}

// HasCapability 检查 capability_bindings 是否含给定 scope。
func HasCapability(caps []string, want string) bool {
	for _, c := range caps {
		if c == want || capabilityAliasMatches(c, want) {
			return true
		}
	}
	return false
}

func capabilityAliasMatches(have, want string) bool {
	switch want {
	case "tenant.kb.read":
		return have == "kb.read" || have == "zhiban.kb.search"
	case "tenant.notification.write":
		return have == "notification.write"
	case "tenant.chat.message.write":
		return have == "chat.message.write"
	case "tenant.chat.file.read":
		return have == "chat.file.read"
	case "tenant.a2a.invoke":
		return have == "a2a.invoke"
	case "tenant.org.read":
		return have == "org.read"
	case "tenant.memory.read", "memory.read":
		return have == "memory.read" || have == "memory.recall" || have == "memory:*"
	case "tenant.memory.write", "memory.write":
		return have == "memory.write" || have == "memory:*"
	}
	return false
}

// IsSubset 校验 sub ⊆ super (用于颁发 session_token 时确保 caps 不越界)。
func IsSubset(sub, super []string) bool {
	for _, s := range sub {
		if !HasCapability(super, s) {
			return false
		}
	}
	return true
}

const (
	// DefaultSessionTokenTTL session_token 默认 60min, F01 §1 场景 6 一致。
	DefaultSessionTokenTTL = 60 * time.Minute
	// MaxSessionTokenTTL caller 最大可申请 TTL; 防止 client 拿一个 100 年 token (codex challenge #2)。
	// 60min 上限故意贴齐 default —— 不给 caller 撑大空间, 真要长用就反复 exchange。
	MaxSessionTokenTTL = 60 * time.Minute
)
