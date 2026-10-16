// Package apikey 定义外部系统调用 Bus 的 API Key 领域模型 (F01 §3.5 场景 5)。
//
// Key 格式: ek_<prefix>_<secret>
//   - prefix: 8 字符 hex, 入库 api_keys.key_prefix, uq_api_keys_prefix 唯一索引
//   - secret: 32 字符 base62, 仅在 Issue 时一次性返回; 入库前 sha256 存 key_hash
//
// 校验流程见 F01 §3.5; 中间件 internal/middleware/apikey_auth.go。
package apikey

import (
	"context"
	"time"
)

// ApiKey 是 api_keys 表的领域映射。
type ApiKey struct {
	ID         int64
	UUID       string
	TenantID   int64
	CreatorID  int64
	Name       string
	KeyPrefix  string
	KeyHash    string
	Scopes     []string
	LastUsedAt *time.Time
	ExpiresAt  *time.Time
	Status     string // active / revoked / expired
	CreatedAt  time.Time
	UpdatedAt  time.Time
	RevokedAt  *time.Time
}

// ListFilter 是租户后台 API Key 列表筛选与分页条件。
type ListFilter struct {
	Status  string // "" / active / revoked / expired
	Keyword string
	Limit   int
	Offset  int
}

// Repository 仓储接口; 仅实现可触碰 SQL。
type Repository interface {
	// Insert 写入新 key 并回填 ID / UUID / CreatedAt。
	Insert(ctx context.Context, k *ApiKey) error
	// FindByPrefix 按 key_prefix 查 active+expires 校验前的原始行 (中间件热路径)。
	FindByPrefix(ctx context.Context, prefix string) (*ApiKey, error)
	// GetByUUID 取单条 (限定 tenantID 以做租户隔离)。
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*ApiKey, error)
	// ListByTenant 列出某租户下 key (含 revoked; 支持状态筛选与分页)。
	ListByTenant(ctx context.Context, tenantID int64, filter ListFilter) ([]ApiKey, int64, error)
	// Patch 增量更新 (name / scopes / expires_at), 仅限同 tenant。
	Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*ApiKey, error)
	// Revoke 把 status 改成 revoked + 设 revoked_at。
	Revoke(ctx context.Context, tenantID int64, uuid string) error
	// TouchLastUsed 异步更新 last_used_at; 中间件命中后调。
	TouchLastUsed(ctx context.Context, id int64, ts time.Time) error
}

// Identity 是中间件 Validate 通过后返回给业务层的最小信息。
//
// 注意: scopes 是 key 自己的可用范围 (kb.read / drive.read / ...), 与 RBAC 的 perms 完全独立。
//
// CreatorID 是 api_keys.creator_id 的快照, 仅用于业务层 "可见性" 视角 (例: KB visibility=private
// 时把 creator_id 当成 acting account 判断)。**不要**把它当成真实人会话身份做 RBAC。
type Identity struct {
	APIKeyID  int64
	TenantID  int64
	CreatorID int64
	Scopes    []string
}

// Service 业务层接口; 中间件只调 Validate, 其它给 admin handler 用。
type Service interface {
	// Issue 创建 key, 返回 (持久化记录, 一次性明文, error)。明文格式 ek_<prefix>_<secret>。
	Issue(ctx context.Context, tenantID, creatorID int64, name string, scopes []string, expiresAt *time.Time) (*ApiKey, string, error)
	// List 租户视角列表 (不返回明文)。
	List(ctx context.Context, tenantID int64, filter ListFilter) ([]ApiKey, int64, error)
	// Get 单条 (含 prefix + scope, 不含 hash)。
	Get(ctx context.Context, tenantID int64, uuid string) (*ApiKey, error)
	// Patch 修改 name / scopes / expires_at。
	Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*ApiKey, error)
	// Revoke 撤销 (软撤销, status=revoked)。
	Revoke(ctx context.Context, tenantID int64, uuid string) error
	// Validate 解析原始 Bearer 串并返回身份; 失败统一回 ErrUnauthorized (不区分 prefix 不存在 vs secret 错, 防探测)。
	Validate(ctx context.Context, raw string) (*Identity, error)
}

// 内置 scope 常量。
//
// F01 §3.5 原 (向后兼容, M1 已有 ek_xxx 仍可用):
//   - ScopeKBRead / ScopeDriveRead
//
// F07 D14 新增 (粗颗粒 3 档 + 2 敏感独立):
//   - ScopeTenantKBRead             — 列租户级 KB + retrieve
//   - ScopeTenantKBWrite            — 上传/删 KB/文档
//   - ScopeTenantKBAdmin            — = read + write + user_private 全集
//   - ScopeTenantKBListUserPrivate  — 跨 user 查私有 KB metadata (审计)
//   - ScopeTenantKBReadUserPrivate  — 跨 user 读私有 KB 内容 (最敏感, 审计)
const (
	ScopeKBRead    = "kb.read"
	ScopeDriveRead = "drive.read"

	ScopeTenantKBRead            = "tenant.kb.read"
	ScopeTenantKBWrite           = "tenant.kb.write"
	ScopeTenantKBAdmin           = "tenant.kb.admin"
	ScopeTenantKBListUserPrivate = "tenant.kb.list_user_private"
	ScopeTenantKBReadUserPrivate = "tenant.kb.read_user_private"

	ScopeTenantOrgRead  = "tenant.org.read"
	ScopeTenantOrgWrite = "tenant.org.write"
	ScopeTenantOrgAdmin = "tenant.org.admin"

	// F17 记忆中台对外 scope (集团自研 agent 经 ek_ 调记忆)。
	ScopeTenantMemoryRead  = "tenant.memory.read"
	ScopeTenantMemoryWrite = "tenant.memory.write"

	// 用户登录 token introspection (业务方系统间调用鉴权)。
	ScopeTenantAuthIntrospect = "tenant.auth.introspect"

	ScopeTenantNotificationWrite = "tenant.notification.write"

	// F24 拍板 5 履约交接: 平台/外部 runtime 下载会话附件 (message-files 文件体)。
	ScopeTenantChatFileRead = "tenant.chat.file.read"
	ScopeTenantChatMessageWrite  = "tenant.chat.message.write"

	// 平台级 scope(唯一一个非 tenant.* 的):允许可信自营服务代企业开通知办租户。
	// 目前只发给 talentos-agent(OPC 自注册企业 → 知办一等租户,spec
	// docs/superpowers/specs/2026-08-17-opc-native-tenant-provision.md)。
	// ⚠️ 授予即可建租户;端点侧另有 slug 白名单正则收敛爆炸半径。
	ScopePlatformTenantProvision = "platform.tenant.provision"
)

// IsValidScope 校验单个 scope 字符串是否在允许集合内。
func IsValidScope(s string) bool {
	switch s {
	case ScopeKBRead, ScopeDriveRead,
		ScopeTenantKBRead, ScopeTenantKBWrite, ScopeTenantKBAdmin,
		ScopeTenantKBListUserPrivate, ScopeTenantKBReadUserPrivate,
		ScopeTenantOrgRead, ScopeTenantOrgWrite, ScopeTenantOrgAdmin,
		ScopeTenantMemoryRead, ScopeTenantMemoryWrite,
		ScopeTenantAuthIntrospect,
		ScopeTenantNotificationWrite, ScopeTenantChatMessageWrite,
		ScopePlatformTenantProvision:
		return true
	}
	return false
}

// HasScope 在 key 的 scopes 列表中匹配是否含给定 scope。
//
// 层级语义 (F07 D14): ScopeTenantKBAdmin 是 read + write + user_private 的全集,
// 所以持有 admin 的 key 自动满足 read / write / list_user_private / read_user_private 子 scope。
// 这跟注释里写的语义一致 (避免运维只给 key 配了 admin 还被 403 卡掉)。
func HasScope(scopes []string, want string) bool {
	for _, s := range scopes {
		if s == want {
			return true
		}
		if s == ScopeTenantKBAdmin && isKBChildScope(want) {
			return true
		}
		if s == ScopeTenantOrgAdmin && isOrgChildScope(want) {
			return true
		}
	}
	return false
}

// isKBChildScope 判断给定 scope 是否是 tenant.kb.admin 应当覆盖的子 scope。
func isKBChildScope(s string) bool {
	switch s {
	case ScopeTenantKBRead, ScopeTenantKBWrite,
		ScopeTenantKBListUserPrivate, ScopeTenantKBReadUserPrivate:
		return true
	}
	return false
}

func isOrgChildScope(s string) bool {
	switch s {
	case ScopeTenantOrgRead, ScopeTenantOrgWrite:
		return true
	}
	return false
}
