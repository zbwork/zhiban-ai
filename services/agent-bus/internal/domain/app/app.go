// Package app 是 F04 (apps) 的领域模型。
//
// 五个核心实体:
//   - App                 ↔ apps 表 (租户自建应用主表)
//   - TenantAppSetting    ↔ tenant_app_settings 表 (租户对应用的开关 / 通用标记 / 排序)
//   - AgentAppBinding     ↔ agent_app_bindings 表 (数字员工挂业务应用)
//   - OAuthClient         ↔ app_oauth_clients 表 (应用 OAuth2 凭证)
//   - OAuthCode           ↔ app_oauth_codes 表 (一次性 authorization_code, TTL 60s)
//
// app_category 表 (应用分类字典) 用现有 m6 设计, 本包加 Category 轻量类型 + 仓储。
//
// 跟 internal/domain/agentsdk 平行 — 两个 OAuth2 用例独立, 但底层 pkg/oauth2 公共代码共用。
package app

import (
	"context"
	"time"

	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
)

// =====================================================
// App ↔ apps 表
// =====================================================

// App apps 表一行。TenantID=0 表示平台预置应用 (apps.tenant_id IS NULL)。
type App struct {
	ID            int64
	UUID          string
	TenantID      int64
	CreatorID     int64
	Code          string // 租户内唯一编码 (小写字母数字下划线)
	Name          string
	Description   string
	IconURL       string
	Color         string
	DisplayMode   string // side_panel | fullscreen | external_browser
	UsageScope    string // all | end_user | agent
	LaunchURI     string
	OAuthClientID *int64
	CategoryID    *int64
	CategoryUUID  string
	SortOrder     int
	Status        string // active | disabled | revoked
	IsSystem      bool
	OpenToTenants bool
	IsUniversal   bool
	IsEnabled     bool
	Metadata      map[string]any
	CreatedAt     time.Time
	UpdatedAt     time.Time
	DeletedAt     *time.Time
}

// AppRepo apps 表仓储。
type AppRepo interface {
	Insert(ctx context.Context, a *App) error
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*App, error)
	GetByID(ctx context.Context, id int64) (*App, error)
	// ListByIDs 批量取未软删 app（与 GetByID 同口径 deleted_at IS NULL；缺失/软删的 id 不返回）。
	// 客户端 /agents 列表批量 hydrate 用，避免逐 app GetByID。
	ListByIDs(ctx context.Context, ids []int64) ([]App, error)
	ListByTenant(ctx context.Context, tenantID int64, filter AppListFilter) ([]App, int64, error)
	Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*App, error)
	SoftDelete(ctx context.Context, tenantID int64, uuid string) error
	SetOAuthClientID(ctx context.Context, appID, clientID int64) error
}

// AppListFilter ListByTenant 过滤条件。
type AppListFilter struct {
	CategoryID *int64 // 可选: 限定分类
	Status     string // 可选: 仅返指定 status
	Keyword    string // 可选: 模糊匹配 name / code
	UsageScope string // 可选: all | end_user | agent
	Limit      int
	Offset     int
}

// =====================================================
// TenantAppSetting ↔ tenant_app_settings 表
// =====================================================

type TenantAppSetting struct {
	ID          int64
	TenantID    int64
	AppID       int64
	IsUniversal bool
	IsEnabled   bool
	SortOrder   int
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// TenantAppSettingRepo tenant_app_settings 表仓储。
type TenantAppSettingRepo interface {
	Upsert(ctx context.Context, s *TenantAppSetting) error
	GetByTenantApp(ctx context.Context, tenantID, appID int64) (*TenantAppSetting, error)
	ListUniversalByTenant(ctx context.Context, tenantID int64) ([]TenantAppSetting, error)
}

// =====================================================
// AgentAppBinding ↔ agent_app_bindings 表
// =====================================================

type AgentAppBinding struct {
	ID        int64
	AgentID   int64
	AppID     int64
	SortOrder int
	CreatedAt time.Time
	UpdatedAt time.Time
}

// AgentAppBindingRepo agent_app_bindings 表仓储。
type AgentAppBindingRepo interface {
	ListByAgent(ctx context.Context, agentID int64) ([]AgentAppBinding, error)
	// ListByAgents 批量版 ListByAgent（客户端 /agents 列表批量 hydrate 用）。
	// 排序 agent_id, sort_order, id —— 单 agent 内与 ListByAgent/ListAppIDsByAgent 一致。
	ListByAgents(ctx context.Context, agentIDs []int64) ([]AgentAppBinding, error)
	ListAppIDsByAgent(ctx context.Context, agentID int64) ([]int64, error)
	// ReplaceForAgent diff + apply: 一次性把 agent 的绑定列表替换为 appIDs (按顺序记 sort_order)。
	ReplaceForAgent(ctx context.Context, agentID int64, appIDs []int64) error
}

// =====================================================
// OAuthClient ↔ app_oauth_clients 表
// =====================================================

type OAuthClient struct {
	ID                      int64
	UUID                    string
	TenantID                int64
	CreatorID               int64
	AppID                   int64
	ClientID                string
	ClientSecretHash        string
	RedirectURIs            []string
	Scopes                  []string
	TokenEndpointAuthMethod string // client_secret_post | client_secret_basic
	AccessTokenTTLSeconds   int
	RefreshTokenTTLSeconds  int
	Status                  string // active | revoked
	LastUsedAt              *time.Time
	CreatedAt               time.Time
	UpdatedAt               time.Time
	RevokedAt               *time.Time
}

// 应用 OAuth scope 与 API Key 的 tenant.* scope 分开建模。资源服务只通过
// 显式映射授予应用 JWT 对应的只读能力，避免应用自行提交 tenant.* 提权。
const (
	ScopeKBRead       = "kb.read"
	ScopeContactsRead = "contacts.read"
)

func IsSupportedOAuthScope(scope string) bool {
	switch scope {
	case ScopeKBRead, ScopeContactsRead:
		return true
	default:
		return false
	}
}

// OAuthClientRepo app_oauth_clients 表仓储。
type OAuthClientRepo interface {
	Insert(ctx context.Context, c *OAuthClient) error
	GetByID(ctx context.Context, id int64) (*OAuthClient, error)
	GetByAppID(ctx context.Context, appID int64) (*OAuthClient, error)
	FindByClientID(ctx context.Context, clientID string) (*OAuthClient, error)
	RotateSecret(ctx context.Context, id int64, newHash string) error
	Revoke(ctx context.Context, id int64) error
	TouchLastUsed(ctx context.Context, id int64, ts time.Time) error
	Patch(ctx context.Context, id int64, fields map[string]any) (*OAuthClient, error)
}

// =====================================================
// OAuthCode ↔ app_oauth_codes 表
// =====================================================

type OAuthCode struct {
	ID             int64
	UUID           string
	CodeHash       string
	OAuthClientID  int64
	TenantID       int64
	AccountID      int64
	ConversationID *int64
	RedirectURI    string
	Scopes         []string
	State          string
	Nonce          string
	IssuedAt       time.Time
	ExpiresAt      time.Time
	ConsumedAt     *time.Time
}

// OAuthCodeRepo app_oauth_codes 表仓储。
type OAuthCodeRepo interface {
	Insert(ctx context.Context, c *OAuthCode) error
	// Consume 原子化消费 (UPDATE ... WHERE consumed_at IS NULL AND expires_at > now() RETURNING ...);
	// 仅当行还可用时返回 *OAuthCode + nil; 否则返 ErrCodeUsedOrExpired。
	Consume(ctx context.Context, codeHash, redirectURI string, oauthClientID int64) (*OAuthCode, error)
	// CleanupExpired 删 expires_at < now() - 1h 且已消费 / 1d 前 unconsumed 的行 (审计期 1d)。
	CleanupExpired(ctx context.Context) (int64, error)
}

// =====================================================
// RefreshToken ↔ app_oauth_refresh_tokens 表
// =====================================================

type RefreshToken struct {
	ID            int64
	UUID          string
	TokenHash     string
	OAuthClientID int64
	TenantID      int64
	AccountID     int64
	Scopes        []string
	IssuedAt      time.Time
	ExpiresAt     time.Time
	LastUsedAt    *time.Time
	RevokedAt     *time.Time
	RevokeReason  string
}

// RefreshTokenRepo app_oauth_refresh_tokens 表仓储。
type RefreshTokenRepo interface {
	Insert(ctx context.Context, t *RefreshToken) error
	// ConsumeAndRotate 一次性查 + 撤销 + 返出原信息 (给上层签新 token);
	// 原子化保证一个 refresh_token 只能换一次新的。
	ConsumeAndRotate(ctx context.Context, tokenHash string) (*RefreshToken, error)
	// CleanupExpired 删 7d 前的 revoked 行 + 已过期未撤销的行。
	CleanupExpired(ctx context.Context) (int64, error)
}

// =====================================================
// Category ↔ app_category 表 (m6 老表, 字段够用直接复用)
// =====================================================

type Category struct {
	ID        int64
	UUID      string
	TenantID  *int64
	Code      string
	Name      string
	SortOrder int
	IsSystem  bool
	CreatedAt time.Time
}

// CategoryRepo app_category 表仓储。
type CategoryRepo interface {
	List(ctx context.Context, tenantID int64, limit, offset int) ([]Category, int64, error)
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*Category, error)
	Insert(ctx context.Context, tenantID int64, c *Category) error
	Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*Category, error)
	Delete(ctx context.Context, tenantID int64, uuid string) error
}

// =====================================================
// Service 业务层接口
// =====================================================

// CreateAppInput 应用创建参数。
type CreateAppInput struct {
	Code                   string
	Name                   string
	Description            string
	IconURL                string
	Color                  string
	DisplayMode            string
	UsageScope             string // all | end_user | agent; 空=all
	LaunchURI              string
	RedirectURIs           []string // 至少 1, 最多 5; 生产强制 HTTPS
	Scopes                 []string // 允许的 capability scope
	CategoryUUID           string   // 可选
	OpenToTenants          bool     // 平台预置应用: 是否开放给租户管理页可见
	AccessTokenTTLSeconds  int      // 0 = 默认 7200
	RefreshTokenTTLSeconds int      // 0 = 默认 2592000 (30d)
}

// CreatedAppResult 创建成功后返回; 含一次性可见的明文 client_secret。
type CreatedAppResult struct {
	App             *App
	OAuthClient     *OAuthClient
	PlaintextSecret string // 一次性可见, 关闭后 DB 只存 hash
	TokenEndpoint   string // 由 service 拼好返出去
	Issuer          string
	JWKSURI         string
	DiscoveryURI    string
}

// LaunchInput 用户点应用启动参数。
type LaunchInput struct {
	AppUUID          string
	AccountID        int64
	TenantID         int64
	ConversationUUID string // 可选; 空 = conversation 外启动
	State            string // 请求关联/兼容字段, 透传
	Nonce            string // OIDC 兼容字段, 写入 id_token
}

// LaunchResult 启动结果。
type LaunchResult struct {
	LaunchURL   string // = app.launch_uri + ?code=...&state=...&iss=...
	DisplayMode string
	ExpiresIn   int // code TTL 秒
}

// ConversationAppListInput 客户端列会话内应用参数。
type ConversationAppListInput struct {
	ConversationUUID string
	AccountID        int64
	TenantID         int64
}

// ConversationAppItem 客户端 composer 渲染用单元。
type ConversationAppItem struct {
	UUID         string
	Name         string
	IconURL      string
	Color        string
	DisplayMode  string
	CategoryUUID string
	CategoryName string
	BindingKind  string // universal | agent_bound
	AgentUUID    string // agent_bound 时填
	SortOrder    int
}

// ConversationRoomReader 是 F04 解析 room-backed agent-direct 绑定关系所需的窄读端口。
// 实现必须只返回 active participants；app service 仍会复核 room tenant/kind/status/metadata
// 和唯一 Agent，不能把客户端展示态当作授权来源。
type ConversationRoomReader interface {
	GetByID(ctx context.Context, roomID int64) (*domroom.Room, error)
	ListParticipants(ctx context.Context, roomID int64) ([]domroom.Participant, error)
}

// Service F04 (apps) 业务接口。
type Service interface {
	// admin CRUD
	CreateApp(ctx context.Context, tenantID, creatorID int64, in CreateAppInput) (*CreatedAppResult, error)
	GetApp(ctx context.Context, tenantID int64, uuid string) (*App, *OAuthClient, error)
	ListApps(ctx context.Context, tenantID int64, filter AppListFilter) ([]App, int64, error)
	PatchApp(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*App, error)
	DeleteApp(ctx context.Context, tenantID int64, uuid string) error
	RotateSecret(ctx context.Context, tenantID int64, uuid string) (string, error) // 返新明文 secret 一次

	// admin 通用应用开关 + 业务应用绑定
	SetUniversal(ctx context.Context, tenantID int64, appUUID string, isUniversal bool, sortOrder int) error
	SetEnabled(ctx context.Context, tenantID int64, appUUID string, isEnabled bool) error
	BindAgentApps(ctx context.Context, tenantID, agentID int64, appUUIDs []string) error
	ListAgentApps(ctx context.Context, tenantID, agentID int64) ([]App, error)

	// 应用分类
	ListCategories(ctx context.Context, tenantID int64, limit, offset int) ([]Category, int64, error)
	CreateCategory(ctx context.Context, tenantID int64, code, name string, sortOrder int) (*Category, error)
	PatchCategory(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*Category, error)
	DeleteCategory(ctx context.Context, tenantID int64, uuid string) error

	// client 侧 (会话内应用列表 + 启动)
	ListConversationApps(ctx context.Context, in ConversationAppListInput) ([]ConversationAppItem, error)
	Launch(ctx context.Context, in LaunchInput) (*LaunchResult, error)

	// OAuth2 token endpoint 调用
	ConsumeAuthorizationCode(ctx context.Context, plaintextCode, redirectURI string, oauthClientID int64) (*OAuthCode, error)
	ValidateClientCredentials(ctx context.Context, clientID, clientSecret string) (*OAuthClient, error)
	// IssueRefreshToken 颁发 refresh_token 长期凭证 (落库 + 返明文 一次性)。
	IssueRefreshToken(ctx context.Context, clientID, tenantID, accountID int64, scopes []string, ttl time.Duration) (plaintext string, err error)
	// ConsumeRefreshToken 一次性消费 (rotate) refresh_token; 返原信息供上层签新 token。
	ConsumeRefreshToken(ctx context.Context, plaintextRefreshToken string) (*RefreshToken, error)

	// IDTokenUserClaims 给 token endpoint 拼 id_token 用; JOIN accounts + memberships + tenants + departments。
	// conversationID 为空时 zhibanContext.ConversationID 留空。
	IDTokenUserClaims(ctx context.Context, accountID, tenantID int64, conversationID *int64) (*IDTokenUserClaims, error)
}

// IDTokenUserClaims id_token 里的用户身份相关 claim 打包。
type IDTokenUserClaims struct {
	AccountUUID      string
	Email            string
	EmailVerified    bool
	Name             string
	PhoneNumber      string
	TenantUUID       string
	TenantName       string
	EmployeeNo       string
	Title            string
	Department       string // department 全名 (含路径)
	ConversationID   string // = conversations.uuid; 没传 conversationUUID 时空
	ConversationKind string // agent_chat | dm | group | ""
	PeerKind         string // agent | account | group | ""
	PeerUUID         string
	PeerName         string
}
