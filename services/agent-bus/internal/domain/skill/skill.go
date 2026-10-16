// Package skill 定义 F03 v0.9.1 技能领域模型 — 数字员工能挂的「技能」（豆包式参数化对话工具
// + 内置 native 能力包）的定义、组织、版本管理、绑定、调用、可见性控制。
//
// 此包**仅**承载领域类型 + 接口契约；SQL 实现在 internal/repository/postgres/skill；
// 业务编排在 internal/service/skill；HTTP 路由在 internal/transport/http/admin (平台 admin)
// + internal/transport/http/bus (客户端 / 租户 admin)。
//
// 详见 docs/features/F03-skills.md §2 / §3。
package skill

import (
	"context"
	"time"
)

// ----------------------------------------------------------------------------
// 枚举（跟 SQL CHECK 约束 + spec §2 一致；任何新增值必须同步改 migration + 这里）
// ----------------------------------------------------------------------------

// Kind 取值（spec §1.2）。
const (
	KindAgent   = "agent"   // SKILL.md 包，Agent runtime 加载并自跑（同步内联）
	KindBuiltin = "builtin" // client native runner，平台仅配 metadata + builtin_key
)

// ExecutionMode 取值（spec §1.2）。
const (
	ExecutionSyncInline    = "synchronous_inline"
	ExecutionAsyncFloating = "asynchronous_floating"
)

// ScopeKind 取值（spec §1.2）。
const (
	ScopePlatform = "platform"
	ScopeTenant   = "tenant"
)

// Source 取值（spec §1.2）。
const (
	SourceInternal   = "internal"
	SourceOpenSource = "open_source"
	SourceThirdParty = "third_party"
)

// Visibility 取值，对齐 boundaries §2.3（spec §1.2 D27 决议）。
const (
	VisibilityPrivate   = "private"
	VisibilityWorkspace = "workspace"
	VisibilityTenant    = "tenant"
	VisibilityPlatform  = "platform"
)

// Status 取值（skills.status，spec §3.1.0.A）。
const (
	StatusDraft    = "draft"
	StatusActive   = "active"
	StatusArchived = "archived"
)

// VersionStatus 取值（skill_versions.status，spec §3.1.0.B）。
const (
	VersionStatusDraft     = "draft"
	VersionStatusPublished = "published"
	VersionStatusArchived  = "archived"
)

// HostingMode 取值（spec §1.2 / boundaries §2.3）。self_hosted 永不出现在 skills.hosting_modes。
const (
	HostingPlatformManaged = "platform_managed"
	HostingHybrid          = "hybrid"
)

// GrayscaleStrategy 取值（spec §2.3.A）。
const (
	GrayscaleTenantHash      = "tenant_hash"
	GrayscaleAgentHash       = "agent_hash"
	GrayscaleUserHash        = "user_hash"
	GrayscaleTenantAllowlist = "tenant_allowlist"
)

// CategoryKind 取值（spec §1.2）。
const (
	CategoryFoundation = "foundation"
	CategoryScenario   = "scenario"
)

// BindingSource 取值（agent_skill_bindings.source，spec §2.3.C）。
const (
	BindingSourceDefaultInherit = "default_inherit"
	BindingSourceManualAttach   = "manual_attach"
	BindingSourceAIRecommend    = "ai_recommend"
)

// PreferenceBehavior 取值（tenant_skill_preferences.behavior，spec §2.3.D）。
const (
	PreferenceForceOn  = "force_on"
	PreferenceForceOff = "force_off"
)

// OverrideBehavior 取值（user_agent_skill_overrides.behavior，spec §2.3.E）。
const (
	OverrideTemporaryAttach = "temporary_attach"
	OverrideTemporaryDetach = "temporary_detach"
)

// BuiltinKeyStatus 取值（builtin_skill_keys.status，spec §2.3.F）。
const (
	BuiltinKeyActive     = "active"
	BuiltinKeyDeprecated = "deprecated"
)

// ClientPlatform 取值（client_builtin_handshakes.client_platform，spec §2.3.H）。
const (
	ClientPlatformIOS     = "ios"
	ClientPlatformAndroid = "android"
	ClientPlatformMacOS   = "macos"
	ClientPlatformWindows = "windows"
	ClientPlatformWeb     = "web"
)

// PackageMaxBytes 是 SKILL.md zip 包硬上限 50MB（spec §1.2）。
const PackageMaxBytes int64 = 52428800

// BillingType 取值（F11 §3.1.7）。
const (
	BillingTypeFree = "free"
	BillingTypePaid = "paid"
)

// PricingMode 取值（F11 §3.1.7）。
const (
	PricingModePerSkill     = "per_skill"
	PricingModePerOperation = "per_operation"
)

// ----------------------------------------------------------------------------
// 领域类型（跟 SQL DDL 字段一一映射）
// ----------------------------------------------------------------------------

// Skill 是 skills 表的领域映射（spec §2.3.A）。
type Skill struct {
	ID                 int64
	UUID               string
	Code               string
	Name               string
	Description        string
	UsageExample       string
	UsageExampleImages []byte
	IconURL            string
	Placeholder        string
	SubmitLabel        string

	Kind          string  // KindAgent / KindBuiltin
	BuiltinKey    *string // kind=builtin 必填，FK builtin_skill_keys.code
	ExecutionMode string  // ExecutionSyncInline / ExecutionAsyncFloating

	ScopeKind string // ScopePlatform / ScopeTenant
	TenantID  *int64 // scope=tenant 必填

	Source     string // SourceInternal / SourceOpenSource / SourceThirdParty
	Visibility string // VisibilityPrivate / Workspace / Tenant / Platform

	CategoryID *int64

	InputChipsSchema []byte // 原始 JSON；agent 类强制 []，builtin 类在主表编辑（spec §1.2 D27）
	HostingModes     []string
	AgentCompat      []byte // 原始 JSON

	DefaultAttached bool
	DefaultPinned   bool
	SortOrder       int

	LatestVersionID *int64

	Status       string // StatusDraft / Active / Archived
	InstallCount int64

	MarketingVisible bool // true=对外营销官网技能商店展示（仅 scope_kind=platform 且 status=active 生效）；见 marketing-skill-showcase 契约

	BillingType           string // BillingTypeFree / BillingTypePaid
	PricingMode           string // PricingModePerSkill / PricingModePerOperation
	DefaultCreditsPerCall *int64
	OperationCount        int64

	CreatedBy *int64
	UpdatedBy *int64
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt *time.Time
}

// SkillVersion 是 skill_versions 表的领域映射（spec §2.3.A）。
type SkillVersion struct {
	ID        int64
	UUID      string
	SkillID   int64
	Version   string // semver: "1.0.0"
	Status    string // VersionStatusDraft / Published / Archived
	Changelog string

	PackageURL       string
	PackageSizeBytes *int64
	PackageSHA256    string

	InputChipsSchemaSnapshot []byte // 原始 JSON；publish 时刻 snapshot
	AgentCompatSnapshot      []byte // 原始 JSON

	GrayscalePct       int
	GrayscaleStrategy  string
	GrayscaleAllowlist []int64 // tenant_id 数组

	PublishedAt *time.Time
	PublishedBy *int64
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// Category 是 skill_categories 表的领域映射（spec §2.3.B）。
type Category struct {
	ID           int64
	Code         string
	Name         string
	CategoryKind string // CategoryFoundation / CategoryScenario
	Description  string
	SortOrder    int
	Status       string // StatusActive / Archived（跟 skills.status 共用枚举值集子集）
	CreatedAt    time.Time
	UpdatedAt    time.Time
	IsDeleted    bool
	DeletedAt    *time.Time
	DeletedBy    *int64
}

// Label 是 skill_labels 表的领域映射（仅一组「技能标签」，spec §2.3.B）。
type Label struct {
	ID          int64
	Code        string
	Name        string
	Description string
	SortOrder   int
	Status      string
	CreatedAt   time.Time
	UpdatedAt   time.Time
	IsDeleted   bool
	DeletedAt   *time.Time
	DeletedBy   *int64
}

// VersionFile 是 skill_version_files 表的领域映射（spec §4.7 R1）。
//
// OSS zip 是真值源，本表为投影：上传时解析 zip，文本文件 ≤1MB 写 ContentText，
// 否则 IsBinary 或 Truncated 为 true 且 ContentText 留空。
type VersionFile struct {
	ID          int64
	VersionID   int64
	Path        string
	SizeBytes   int64
	SHA256      string
	ContentType string
	IsBinary    bool
	Truncated   bool
	ContentText string // is_binary=true 或 truncated=true 时为空字符串
	CreatedAt   time.Time
}

// AgentBinding 是 agent_skill_bindings 表的领域映射（spec §2.3.C）。
type AgentBinding struct {
	ID              int64
	AgentID         int64
	SkillID         int64
	Pinned          bool
	SortOrder       int
	PinnedVersionID *int64 // NULL = latest published
	DefaultParams   []byte // 原始 JSON
	Source          string // BindingSource*
	CreatedBy       *int64
	UpdatedBy       *int64
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// TenantPreference 是 tenant_skill_preferences 表的领域映射（spec §2.3.D）。
type TenantPreference struct {
	TenantID  int64
	SkillID   int64
	Behavior  string // PreferenceForceOn / ForceOff
	Note      string
	CreatedBy *int64
	UpdatedBy *int64
	CreatedAt time.Time
	UpdatedAt time.Time
}

// TenantDisable 是 tenant_skill_disables 表的领域映射（spec §2.3.D）。
type TenantDisable struct {
	TenantID      int64
	SkillID       int64
	DisableReason string
	DisabledAt    time.Time
	DisabledBy    *int64
}

// UserOverride 是 user_agent_skill_overrides 表的领域映射（spec §2.3.E）。
type UserOverride struct {
	ID        int64
	AccountID int64
	TenantID  int64
	AgentID   int64
	SkillID   int64
	Behavior  string // OverrideTemporaryAttach / Detach
	ExpiresAt *time.Time
	CreatedAt time.Time
	UpdatedAt time.Time
}

// BuiltinKey 是 builtin_skill_keys 表的领域映射（spec §2.3.F）。
type BuiltinKey struct {
	ID                        int64
	Code                      string
	Name                      string
	Description               string
	SupportedPlatforms        []string
	MinClientVersions         []byte // 原始 JSON: {"ios":"1.5.0",...}
	DefaultExecutionMode      string
	DefaultNativeCapabilities []string
	RegisteredBy              *int64
	RegisteredAt              time.Time
	UpdatedAt                 time.Time
	Status                    string // BuiltinKeyActive / Deprecated
	IsDeleted                 bool
	DeletedAt                 *time.Time
	DeletedBy                 *int64
}

// ClientHandshake 是 client_builtin_handshakes 表的领域映射（spec §2.3.H）。
type ClientHandshake struct {
	AccountID            int64
	ClientPlatform       string
	DeviceID             string
	ClientVersion        string
	SupportedBuiltinKeys []string
	LastReportedAt       time.Time
}

// ----------------------------------------------------------------------------
// 查询过滤器
// ----------------------------------------------------------------------------

// ListFilter 是平台/租户技能列表的多维筛选（spec §3.1 / §3.2）。
type ListFilter struct {
	ScopeKind      string // 空 = 不过滤
	TenantID       *int64 // ScopeKind=tenant 时强制带（service 层填）
	Kind           string
	Status         string
	CategoryID     *int64
	LabelIDs       []int64 // AND 语义
	Source         string
	Visibility     string
	BillingType    string
	PricingMode    string
	DefaultPrice   string // configured / missing
	Operations     string // has_operations / no_operations
	Keyword        string // 在 code/name/description 上模糊匹配
	IncludeDeleted bool
	Limit          int
	Offset         int
}

// DictListFilter 是技能中心字典类列表筛选。
type DictListFilter struct {
	Status        string
	Keyword       string
	ExecutionMode string
	Limit         int
	Offset        int
}

// ShowcaseItem 是官网技能商店（对外营销）展示投影行，仅含平台精选技能的公开字段。
// Source/InstallCount 保留原始值，营销口径映射（标签、取整）在 transport 层完成。
// 见 docs/contracts/marketing-skill-showcase.md。
type ShowcaseItem struct {
	Name         string
	Description  string
	Source       string // SourceInternal / SourceOpenSource / SourceThirdParty
	CategoryName string // skill_categories.name，可能为空
	InstallCount int64
	IconURL      string // 原始 icon_url（多为 oss:// 内部 URI）；transport 层现签为短时效 URL 供官网构建期下载，绝不裸吐
}

// ----------------------------------------------------------------------------
// 仓储 / 服务接口
// ----------------------------------------------------------------------------

// Repository 仓储接口；仅实现可触碰 SQL。
//
// 已实现：skills + skill_versions + 字典 + agent_skill_bindings + tenant_*  +
// user_agent_skill_overrides + client_builtin_handshakes（覆盖 spec §2.3 全部 12 表）。
type Repository interface {
	// ----- skills -----
	CreateSkill(ctx context.Context, s *Skill) error
	GetSkillByUUID(ctx context.Context, uuid string, includeDeleted bool) (*Skill, error)
	GetSkillByID(ctx context.Context, id int64) (*Skill, error)
	ListSkills(ctx context.Context, f ListFilter) ([]Skill, int64, error)
	PatchSkill(ctx context.Context, uuid string, fields map[string]any, updatedBy *int64) (*Skill, error)
	// ListMarketingShowcase 官网技能商店：平台精选(marketing_visible)且 active 技能的公开投影（join 有效分类名）。
	ListMarketingShowcase(ctx context.Context, limit int) ([]ShowcaseItem, error)
	SoftDeleteSkill(ctx context.Context, uuid string) error
	// BatchSoftDeletePlatformSkills 原子软删除明确 UUID 指定的平台技能。
	// 任一目标不存在、已删除或非平台域时整批不写入。
	BatchSoftDeletePlatformSkills(ctx context.Context, uuids []string) ([]Skill, error)
	UpdateSkillStatus(ctx context.Context, id int64, status string) error
	UpdateSkillLatestVersion(ctx context.Context, id, versionID int64) error

	// ----- skill_versions -----
	CreateVersion(ctx context.Context, v *SkillVersion) error
	GetVersionByUUID(ctx context.Context, uuid string) (*SkillVersion, error)
	GetVersionByID(ctx context.Context, id int64) (*SkillVersion, error)
	ListVersions(ctx context.Context, skillID int64) ([]SkillVersion, error)
	// ListVersionNamesByIDs 批量取版本号字符串（§3.3.C 客户端广场 latest_version 直显，
	// 一条 SQL 避免逐 skill GetVersionByID 的 N+1，见 pitfalls/client-api-list-hydrate-n-plus-one-remote-db-latency.md）。
	ListVersionNamesByIDs(ctx context.Context, ids []int64) (map[int64]string, error)
	GetLatestPublishedVersion(ctx context.Context, skillID int64) (*SkillVersion, error)
	UpdateVersion(ctx context.Context, uuid string, fields map[string]any) (*SkillVersion, error)
	UpdateVersionStatus(ctx context.Context, id int64, status string) error
	// PublishVersionAtomic 把 publish 流合成 2 条 SQL（替代 UpdateVersion+UpdateVersionStatus+
	// GetLatestPublishedVersion+UpdateSkillLatestVersion+UpdateSkillStatus 的 5 条串行调用）。
	PublishVersionAtomic(ctx context.Context, uuid string, pct int, strategy string, allowlist []int64) (*SkillVersion, error)
	CountPublishedFullBaselineExcluding(ctx context.Context, skillID, excludeID int64) (int64, error)

	// ----- skill_version_files (§4.7 R1: zip 解析后的 manifest + 文本预览) -----
	ReplaceVersionFiles(ctx context.Context, versionID int64, files []VersionFile) error
	ListVersionFiles(ctx context.Context, versionID int64) ([]VersionFile, error)
	GetVersionFile(ctx context.Context, versionID int64, path string) (*VersionFile, error)

	// ----- skill_label_bindings -----
	ReplaceSkillLabels(ctx context.Context, skillID int64, labelIDs []int64) error
	ListSkillLabels(ctx context.Context, skillID int64) ([]Label, error)
	ListLabelIDsBySkillIDs(ctx context.Context, skillIDs []int64) (map[int64][]int64, error)

	// ----- 字典 -----
	ListCategories(ctx context.Context, f DictListFilter) ([]Category, int64, error)
	CreateCategory(ctx context.Context, c *Category) error
	PatchCategory(ctx context.Context, id int64, fields map[string]any) (*Category, error)
	DeleteCategory(ctx context.Context, id int64, deletedBy *int64) error

	ListLabels(ctx context.Context, f DictListFilter) ([]Label, int64, error)
	CreateLabel(ctx context.Context, l *Label) error
	PatchLabel(ctx context.Context, id int64, fields map[string]any) (*Label, error)
	DeleteLabel(ctx context.Context, id int64, deletedBy *int64) error

	ListBuiltinKeys(ctx context.Context, f DictListFilter) ([]BuiltinKey, int64, error)
	CreateBuiltinKey(ctx context.Context, b *BuiltinKey) error
	PatchBuiltinKey(ctx context.Context, id int64, fields map[string]any) (*BuiltinKey, error)
	DeleteBuiltinKey(ctx context.Context, id int64, deletedBy *int64) error
	GetBuiltinKeyByCode(ctx context.Context, code string) (*BuiltinKey, error)

	// ----- agent_skill_bindings -----
	UpsertAgentBinding(ctx context.Context, b *AgentBinding) error
	GetAgentBinding(ctx context.Context, agentID, skillID int64) (*AgentBinding, error)
	GetAgentBindingByID(ctx context.Context, id int64) (*AgentBinding, error)
	ListAgentBindings(ctx context.Context, agentID int64) ([]AgentBinding, error)
	// ListAgentBindingViewsByAgentIDs 批量版 ListAgentBindings+GetSkillByID（客户端 /agents 列表
	// hydrate 用，见 pitfalls/client-api-list-hydrate-n-plus-one-remote-db-latency.md）。
	// tenantID 经 digital_employees 联表强制过滤（跨租户 agentID 静默不返回）；
	// 与逐条路径同语义：技能行物理缺失时跳过该绑定，软删技能不过滤（对齐 GetSkillByID）。
	// 返回 map 按 agent_id 分桶，桶内保持 sort_order DESC, id DESC。
	ListAgentBindingViewsByAgentIDs(ctx context.Context, tenantID int64, agentIDs []int64) (map[int64][]AgentBindingView, error)
	PatchAgentBinding(ctx context.Context, id int64, fields map[string]any) (*AgentBinding, error)
	DeleteAgentBinding(ctx context.Context, id int64) error

	// ----- tenant_skill_preferences -----
	UpsertTenantPreference(ctx context.Context, p *TenantPreference) error
	DeleteTenantPreference(ctx context.Context, tenantID, skillID int64) error
	ListTenantPreferences(ctx context.Context, tenantID int64) ([]TenantPreference, error)
	GetTenantPreference(ctx context.Context, tenantID, skillID int64) (*TenantPreference, error)

	// ----- tenant_skill_disables -----
	UpsertTenantDisable(ctx context.Context, d *TenantDisable) error
	DeleteTenantDisable(ctx context.Context, tenantID, skillID int64) error
	ListTenantDisables(ctx context.Context, tenantID int64) ([]TenantDisable, error)
	IsTenantSkillDisabled(ctx context.Context, tenantID, skillID int64) (bool, error)

	// ----- user_agent_skill_overrides -----
	UpsertUserOverride(ctx context.Context, o *UserOverride) error
	DeleteUserOverride(ctx context.Context, accountID, agentID, skillID int64) error
	ListUserOverrides(ctx context.Context, accountID, agentID int64) ([]UserOverride, error)
	PurgeExpiredUserOverrides(ctx context.Context) (int64, error)
	// RecomputeInstallCounts 用 agent_skill_bindings 全表 distinct agent 数刷新 skills.install_count（spec §4.8）。
	RecomputeInstallCounts(ctx context.Context) error

	// ----- client_builtin_handshakes -----
	UpsertHandshake(ctx context.Context, h *ClientHandshake) error
	GetHandshakesForAccount(ctx context.Context, accountID int64) ([]ClientHandshake, error)
	PurgeStaleHandshakes(ctx context.Context, before time.Time) (int64, error)

	// ----- 跨进程事件（spec §2.5 / §4.6）-----
	NotifyConfigChange(ctx context.Context, payload string) error
}

// Service 业务层接口（spec §3 各 endpoint 编排）。覆盖平台 admin / 租户 admin / 客户端三端。
type Service interface {
	// ----- 平台 admin 域 (§3.1) -----
	CreateSkill(ctx context.Context, in CreateSkillInput) (*Skill, *SkillVersion, error)
	GetSkill(ctx context.Context, uuid string) (*Skill, error)
	ListSkills(ctx context.Context, f ListFilter) ([]Skill, int64, error)
	PatchSkill(ctx context.Context, uuid string, in PatchSkillInput) (*Skill, error)
	SoftDeleteSkill(ctx context.Context, uuid string, accountID int64) error
	BatchSoftDeleteSkills(ctx context.Context, uuids []string, accountID int64) ([]Skill, error)

	CreateAgentVersion(ctx context.Context, in CreateAgentVersionInput) (*SkillVersion, error)
	CreateBuiltinVersion(ctx context.Context, in CreateBuiltinVersionInput) (*SkillVersion, error)
	PatchVersion(ctx context.Context, uuid string, in PatchVersionInput) (*SkillVersion, error)
	PublishVersion(ctx context.Context, uuid string, in PublishVersionInput) (*SkillVersion, error)
	ArchiveVersion(ctx context.Context, uuid string) (*SkillVersion, error)
	RollbackLatest(ctx context.Context, uuid string) (*SkillVersion, error)
	ListVersions(ctx context.Context, skillUUID string) ([]SkillVersion, error)

	ListCategories(ctx context.Context, f DictListFilter) ([]Category, int64, error)
	CreateCategory(ctx context.Context, c *Category) error
	PatchCategory(ctx context.Context, id int64, fields map[string]any) (*Category, error)
	DeleteCategory(ctx context.Context, id int64, deletedBy *int64) error

	ListLabels(ctx context.Context, f DictListFilter) ([]Label, int64, error)
	CreateLabel(ctx context.Context, l *Label) error
	PatchLabel(ctx context.Context, id int64, fields map[string]any) (*Label, error)
	DeleteLabel(ctx context.Context, id int64, deletedBy *int64) error

	ListBuiltinKeys(ctx context.Context, f DictListFilter) ([]BuiltinKey, int64, error)
	CreateBuiltinKey(ctx context.Context, b *BuiltinKey) error
	PatchBuiltinKey(ctx context.Context, id int64, fields map[string]any) (*BuiltinKey, error)
	DeleteBuiltinKey(ctx context.Context, id int64, deletedBy *int64) error

	PreviewSkill(ctx context.Context, in PreviewSkillInput) (*PreviewSkillOutput, error)

	// ApplyDefaultBindings — agent 创建钩子（spec §2.4 / §4.3）。
	// 将 default_attached=true 的 active+published skill 装配到新 agent，
	// 装配源记 source=default_inherit。返回装配数量。
	ApplyDefaultBindings(ctx context.Context, agentID, accountID int64) (int, error)

	// ----- 租户 admin 域 (§3.2) -----
	DisableTenantSkill(ctx context.Context, in DisableTenantSkillInput) (*TenantDisable, error)
	EnableTenantSkill(ctx context.Context, tenantID int64, skillUUID string) error
	ListTenantPreferences(ctx context.Context, tenantID int64) ([]TenantPreference, []Skill, error)
	SetTenantPreference(ctx context.Context, in SetTenantPreferenceInput) (*TenantPreference, error)
	ClearTenantPreference(ctx context.Context, tenantID int64, skillUUID string) error

	AttachAgentSkill(ctx context.Context, in AttachAgentSkillInput) (*AgentBinding, error)
	PatchAgentBinding(ctx context.Context, in PatchAgentBindingInput) (*AgentBinding, error)
	DetachAgentSkill(ctx context.Context, tenantID int64, agentUUID string, bindingID int64) error
	ListAgentBindings(ctx context.Context, tenantID int64, agentUUID string) ([]AgentBindingView, error)
	ListAvailableForAgent(ctx context.Context, tenantID int64, agentUUID string) ([]AvailableSkillView, error)
	ReplaceClientAgentSkillBindings(ctx context.Context, in ReplaceClientAgentSkillBindingsInput) error

	// ----- 客户端域 (§3.3) -----
	GetSkillRail(ctx context.Context, in GetSkillRailInput) (*SkillRail, error)
	UpsertUserOverride(ctx context.Context, in UpsertUserOverrideInput) (*UserOverride, error)
	DeleteUserOverride(ctx context.Context, accountID, tenantID int64, agentUUID, skillUUID string) error
	UpsertHandshake(ctx context.Context, in UpsertHandshakeInput) error
	ListClientSkills(ctx context.Context, in ListClientSkillsInput) ([]ClientSkillView, int64, error)
}

// ----------------------------------------------------------------------------
// Service 输入参数（DTO 转 domain，避免 transport 层直接拼裸字段）
// ----------------------------------------------------------------------------

// CreateSkillInput 对应 §3.1.A POST /platform/skills body。
//
// 平台 admin 调用：ScopeKind=ScopePlatform，TenantID 必为 nil；service 强制赋值。
// 租户 admin 调用（§3.2 PATCH 留扩展）：ScopeKind=ScopeTenant，TenantID 必填。
type CreateSkillInput struct {
	Code               string
	Name               string
	Description        string
	UsageExample       string
	UsageExampleImages []byte
	IconURL            string
	Placeholder        string
	SubmitLabel        string
	Kind               string
	BuiltinKey         *string
	ExecutionMode      string
	ScopeKind          string
	TenantID           *int64
	Source             string
	Visibility         string
	CategoryID         *int64
	LabelIDs           []int64
	HostingModes       []string
	AgentCompat        []byte // 原始 JSON
	InputChipsSchema   []byte // 仅 kind=builtin 接受非空数组
	DefaultAttached    bool
	DefaultPinned      bool
	SortOrder          int
	CreatedBy          *int64
}

// PatchSkillInput 对应 §3.1 PATCH 元字段（不含版本字段）。
type PatchSkillInput struct {
	Name               *string
	Description        *string
	UsageExample       *string
	UsageExampleImages []byte // nil = 不动；非 nil = 全量替换
	IconURL            *string
	Placeholder        *string
	SubmitLabel        *string
	ExecutionMode      *string
	Visibility         *string
	Source             *string
	CategoryID         *int64
	ClearCategory      bool     // true = 显式清空 category_id；与 CategoryID 互斥
	LabelIDs           *[]int64 // nil = 不动；非 nil = 全量替换
	HostingModes       *[]string
	AgentCompat        []byte // nil = 不动；非 nil = 全量替换
	InputChipsSchema   []byte // 仅 kind=builtin 可改；agent 类强制 []
	DefaultAttached    *bool
	DefaultPinned      *bool
	SortOrder          *int
	Status             *string
	MarketingVisible   *bool
	UpdatedBy          *int64
}

// CreateAgentVersionInput 对应 §3.1.B POST /skills/{u}/versions（kind=agent）。
//
// 注：v0.9.1 spec 走 multipart/form-data 上传 zip。本实现接受已上传到对象存储的 URL +
// sha256 + size + 解析后的 frontmatter（input_chips_schema / agent_compat），把 zip 解析
// 与上传的责任交给上游（admin web 直传 OSS，再调本接口）。SKILL.md 真实文件解析在
// 后续切片接入 Drive 后再补。
type CreateAgentVersionInput struct {
	SkillUUID                string
	Version                  string
	Changelog                string
	PackageURL               string
	PackageSHA256            string
	PackageSizeBytes         int64
	InputChipsSchemaSnapshot []byte
	AgentCompatSnapshot      []byte
}

// CreateBuiltinVersionInput 对应 §3.1.C.3 POST /skills/{u}/builtin-versions。
type CreateBuiltinVersionInput struct {
	SkillUUID          string
	Version            string
	Changelog          string
	GrayscalePct       int
	GrayscaleStrategy  string
	GrayscaleAllowlist []int64
}

// PatchVersionInput 对应 §3.1.C.2 PATCH /versions/{vid}。
type PatchVersionInput struct {
	Changelog          *string
	GrayscalePct       *int
	GrayscaleStrategy  *string
	GrayscaleAllowlist *[]int64
}

// PublishVersionInput 对应 §3.1.C POST /versions/{vid}/publish。
type PublishVersionInput struct {
	GrayscalePct       *int
	GrayscaleStrategy  *string
	GrayscaleAllowlist []int64
	PublishedBy        *int64
}

// ----------------------------------------------------------------------------
// 租户 admin / 客户端 域 输入参数（§3.2 / §3.3）
// ----------------------------------------------------------------------------

// DisableTenantSkillInput 对应 §3.2.A POST /tenant/skills/{platform_uuid}/disable。
type DisableTenantSkillInput struct {
	TenantID      int64
	SkillUUID     string // 必须为 platform skill
	DisableReason string
	DisabledBy    *int64
}

// SetTenantPreferenceInput 对应 §3.2 PUT /tenant/skill-preferences/{skill_uuid}。
type SetTenantPreferenceInput struct {
	TenantID  int64
	SkillUUID string
	Behavior  string // PreferenceForceOn / ForceOff
	Note      string
	UpdatedBy *int64
}

// AttachAgentSkillInput 对应 §3.2.B POST /tenant/agents/{agent_uuid}/skills。
type AttachAgentSkillInput struct {
	TenantID        int64
	AgentUUID       string
	SkillUUID       string
	Pinned          bool
	SortOrder       int
	PinnedVersionID *int64
	DefaultParams   []byte // JSON
	Source          string // 默认 manual_attach
	CreatedBy       *int64
}

// PatchAgentBindingInput 对应 §3.2 PATCH /tenant/agents/{agent_uuid}/skills/{binding_id}。
type PatchAgentBindingInput struct {
	TenantID        int64
	AgentUUID       string
	BindingID       int64
	Pinned          *bool
	SortOrder       *int
	PinnedVersionID *int64
	ClearPinnedVer  bool   // 显式清掉 pinned_version_id
	DefaultParams   []byte // nil = 不动；非 nil = 全量替换
	UpdatedBy       *int64
}

// ReplaceClientAgentSkillBindingsInput 对应客户端 PUT /agents/{u}/skill-bindings。
// SkillCodes 使用客户端广场下发的 code/slug，不暴露平台 admin skill_uuid 细节给表单。
type ReplaceClientAgentSkillBindingsInput struct {
	AccountID  int64
	TenantID   int64
	AgentUUID  string
	SkillCodes []string
	UpdatedBy  *int64
}

// AgentBindingView 是 GET /tenant/agents/{u}/skills 返回项（binding + skill 元）。
type AgentBindingView struct {
	Binding *AgentBinding
	Skill   *Skill
}

// AvailableSkillView 是 GET /tenant/agents/{u}/skills/available 返回项。
type AvailableSkillView struct {
	Skill             *Skill
	IsAttached        bool
	IsDefaultAttached bool
	TenantPreference  string // ""/force_on/force_off
}

// TenantSkillView 是 GET /api/admin/v1/tenant/skills 返回项 — 平台技能 + 本租户技能 + tenant 侧覆盖。
//
// 用途：让租户 admin 在不持有 platform.skill.read 权限的情况下，看到自己能管理的所有技能（平台 + 自有），
// 并知道本租户当前的禁用状态 / 偏好。
type TenantSkillView struct {
	Skill            *Skill
	TenantDisabled   bool
	DisableReason    string
	TenantPreference string // ""/force_on/force_off
}

// GetSkillRailInput 对应 §3.3.A GET /conversations/{uuid}/skill-rail-config 入参。
type GetSkillRailInput struct {
	AccountID      int64
	TenantID       int64
	AgentUUID      string // 由 conversation → agent_uuid 解出后传入
	AcceptLanguage string
	ClientPlatform string // 由 client header 推断（可空 → 不做 builtin 兼容裁剪）
	ClientVersion  string
	DeviceID       string
}

// SkillRail 对应 §3.3.A 返回 body。
type SkillRail struct {
	AgentUUID       string
	ChipRail        []SkillRailItem
	MoreDrawer      []SkillRailItem
	ConfigVersion   string
	CacheTTLSeconds int
}

// SkillRailItem 单技能 chip rail 项。
type SkillRailItem struct {
	SkillUUID        string
	Code             string
	Name             string
	IconURL          string
	Kind             string
	ExecutionMode    string
	Pinned           bool
	SortOrder        int
	Source           string // default_inherit / manual_attach / temporary_attach
	DefaultParams    []byte // JSON
	Version          string
	VersionUUID      string
	InputChipsSchema []byte // JSON snapshot
	BillingType      string
	PricingMode      string
}

// UpsertUserOverrideInput 对应 §3.3.B POST /agents/{u}/skill-overrides。
type UpsertUserOverrideInput struct {
	AccountID int64
	TenantID  int64
	AgentUUID string
	SkillUUID string
	Behavior  string // OverrideTemporaryAttach / Detach
	ExpiresAt *time.Time
}

// UpsertHandshakeInput 对应 §3.3.D POST /builtin-skills/handshake。
type UpsertHandshakeInput struct {
	AccountID            int64
	ClientPlatform       string
	DeviceID             string
	ClientVersion        string
	SupportedBuiltinKeys []string
}

// PreviewSkillInput / Output 对应 §3.7 SkillHub sandbox preview。
//
// 仅做"按 input_chips_schema 校验 params 合法性 + 渲染示例 user message metadata"，
// 不真实调 agent runtime（v0.9.1 sandbox 阶段）。
type PreviewSkillInput struct {
	SkillUUID   string
	VersionUUID string // 可空 → 用 latest_version_id
	Params      map[string]any
}

type PreviewSkillOutput struct {
	SkillUUID         string         `json:"skill_uuid"`
	Version           string         `json:"version"`
	VersionUUID       string         `json:"version_uuid,omitempty"`
	UserMessageSample map[string]any `json:"user_message_metadata_sample"`
	ValidationErrors  []string       `json:"validation_errors,omitempty"`
}

// ListClientSkillsInput 对应 §3.3.C GET /skills 入参。
type ListClientSkillsInput struct {
	AccountID  int64
	TenantID   int64
	AgentUUID  string // 可选；空=全租户视图
	CategoryID *int64
	Keyword    string
	Source     string
	SortBy     string
	SortOrder  string
	Limit      int
	Offset     int
}

// ClientSkillView 客户端广场视图。
type ClientSkillView struct {
	Skill               *Skill
	IsAttachedToAgent   bool
	IsTemporaryAttached bool
	// LatestVersion latest published 版本号字符串（§1.5.4 详情元信息展示）；无已发布版本时为空。
	LatestVersion string
}
