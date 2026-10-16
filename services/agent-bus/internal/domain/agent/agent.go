package agent

import (
	"context"
	"time"
)

// DigitalEmployee 数字员工。
type DigitalEmployee struct {
	ID                   int64
	UUID                 string
	TenantID             int64
	CreatorID            int64
	CreatorName          string
	Name                 string
	AvatarURL            string
	Intro                string
	Description          string
	WelcomeMsg           string
	RecommendedQuestions []string
	Tags                 []string
	Visibility           string // private/workspace/tenant/platform
	WorkspaceID          *int64
	IsDefaultForCreator  bool
	RuntimeEnvironmentID *int64 // F02 v0.3 FK → runtime_environments(id)
	ExecutionLocus       string `json:"execution_locus"`        // cloud/local; separate from runtime framework
	LocalEngine          string `json:"local_engine,omitempty"` // ADR-0049/0051; local only, immutable on employee instances
	ModelPrimary         string
	// ModelSource ADR-0037: platform_whitelist(默认)/byok。byok 时 ModelPrimary
	// 不生效, 改由 ModelServiceConfigJSON 描述的用户自带模型服务直连 OpenClaw。
	ModelSource string
	// ModelServiceConfigJSON digital_employees.model_service_config 的原始 JSON
	// 字符串 (协议/base_url/model_id, 不含密钥); shape 见契约 §12.3。
	ModelServiceConfigJSON string
	// ModelServiceAPIKeyPrefix BYOK api_key 前缀 (审计/GET 响应可见, 不解密就
	// 能识别哪把 key); 空 = 未配置 BYOK key。真正的密文不进这个 struct,
	// 解密只在 Phase 3 下发给 runtime 的窄路径里现查现用。
	ModelServiceAPIKeyPrefix string
	ModelFallbacks           []string
	Temperature              float32
	ContextWindow            int
	ToolAllow                []string
	ToolDeny                 []string
	CapabilitiesDeclared     map[string]any
	Status                   string // draft/published/grayed/archived
	CurrentVersion           int
	// CallableByAgentsJSON 是 digital_employees.callable_by_agents 字段的原始 JSON 字符串.
	// F09 Phase B PR4 把字段从 BOOLEAN 切到 JSONB; shape: {"mode": "none|all|workspace|explicit", "agent_ids": [...]}.
	// 解析见 internal/service/a2a/whitelist.go ParseCallablePolicy.
	CallableByAgentsJSON string
	// A2ACardJSON 是 digital_employees.a2a_card 的原始 JSON 字符串 (A2A v1b, migration 000067).
	// 读路径用 ParseA2ACardLenient (a2acard.go) 解析, 非法值按空卡处理。
	A2ACardJSON       string
	SupportsGroupChat bool
	IsSystem          bool
	Metadata          map[string]any
	CreatedAt         time.Time
	CreatedBy         *int64 // ADR-0011 8 字段审计; migration 000060 backfill = creator_id
	UpdatedAt         time.Time
	UpdatedBy         *int64
	IsDeleted         bool
	DeletedAt         *time.Time

	// M2 通讯录字段, 详见 docs/modules/m2-contacts-and-visibility.md §3.2
	PositionLabel      string   // 通讯录卡片副标题
	Badges             []string // 徽章, 例如 ["enterprise_official","beta"]
	Source             string   // enterprise / personal / platform
	ContactEnabled     bool     // 是否进入客户端通讯录
	AllowInviteToGroup bool     // 管理员是否允许该数字员工被拉入群聊
	TenantHidden       bool     // 平台预置在当前租户是否被隐藏/禁用 (digital_employee_visibility_overrides.hidden)
	TenantSortOrder    int      // 平台预置在当前租户的排序覆盖

	// DepartmentName 数字员工归属部门名称, 由 workspace_id → departments.name 解析;
	// 仅读路径填充 (List/Get), Create/Update RETURNING 不带, 调用方按需 refetch.
	// 客户端聊天顶栏副标题展示「部门 · 职位」。
	DepartmentName string
}

// CapabilityBinding Agent 装配的能力。
type CapabilityBinding struct {
	ID             int64
	DigitalEmpID   int64
	AgentVersionID *int64
	CapabilityKind string // composer_skill / background_skill / external_skill / mcp / knowledge_base / app
	CapabilityUUID string
	Source         string // self / borrow
	GrantedTools   []string
	GrantedScopes  []string
	SortOrder      int
	Pinned         bool
	RecallConfig   map[string]any
	CreatedAt      time.Time
}

// Filter 列表过滤器。
type Filter struct {
	ExecutionLocus   string
	AgentKind        string
	TemplateTenantID int64 // Client catalogue: only local blueprints or authorized platform runtimes.
	TenantID         int64
	CreatorID        int64
	Source           string
	Visibility       string
	Status           string
	WorkspaceID      *int64
	Keyword          string
	Limit            int
	Offset           int
	// ExcludeTenantInitSeeds hides retired automatic copies created before ADR-0052.
	// Historical rows stay queryable by UUID/ID for conversation references.
	ExcludeTenantInitSeeds bool
	// IncludePlatformPresets 是旧合并列表兼容开关。ADR-0052 后租户后台按 source 分栏：
	// source=platform 直接读取共享平台员工，enterprise/personal 读取当前租户行；当前路由不再使用此开关。
	IncludePlatformPresets bool
}

type CreatorDistributionItem struct {
	CreatorID   int64  `json:"creator_id"`
	CreatorName string `json:"creator_name"`
	Count       int64  `json:"count"`
}

// M3 §3 Agent 版本快照
type Version struct {
	ID              int64
	DigitalEmpID    int64
	Version         int
	Snapshot        map[string]any
	Status          string
	GrayscalePct    int
	GrayscaleGroups []string
	Notes           string
	PublishedBy     *int64
	PublishedAt     *time.Time
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// M3 §6 A2A 调用白名单
type CalleeWhitelistEntry struct {
	ID         int64
	CalleeID   int64
	CallerID   int64
	GrantedBy  *int64
	Note       string
	CreatedAt  time.Time
	CallerUUID string
	CallerName string
}

type Repository interface {
	GetByID(ctx context.Context, id int64) (*DigitalEmployee, error)
	GetByUUID(ctx context.Context, uuid string) (*DigitalEmployee, error)
	// FindByTemplateSource (doc-15) 按 tenant_id + metadata.template_source_uuid 精确查租户副本（幂等用）；无命中 ErrNotFound。
	FindByTemplateSource(ctx context.Context, tenantID int64, templateUUID string) (*DigitalEmployee, error)
	CountCustom(ctx context.Context, tenantID int64) (int64, error)
	Create(ctx context.Context, e *DigitalEmployee) (*DigitalEmployee, error)
	Update(ctx context.Context, e *DigitalEmployee) (*DigitalEmployee, error)
	Delete(ctx context.Context, id int64) error
	List(ctx context.Context, f Filter) ([]DigitalEmployee, int64, error)
	CreatorDistribution(ctx context.Context, tenantID int64) ([]CreatorDistributionItem, error)

	// M2 §5
	Publish(ctx context.Context, id int64) (*DigitalEmployee, error)
	// Batch 2C T2C.3 unpublish: status published/grayed -> archived; 幂等。
	Archive(ctx context.Context, id int64) (*DigitalEmployee, error)
	// Batch 2C T2C.3 publish 阶段 3 乐观锁: draft -> published, 要求 current_version 等于 expectedVersion。
	// 返回更新后行; 0 行 -> 调用方走补偿。
	SetPublishedFromDraft(ctx context.Context, id int64, expectedVersion int) (*DigitalEmployee, error)
	UpsertVisibilityOverride(ctx context.Context, tenantID, agentID int64, hidden bool, sortOrder int) error
	// M2 §8: 发 PG NOTIFY (channel=config_change), payload 由调用方拼。
	Notify(ctx context.Context, channel, payload string) error

	// ListBindings returns the current editable bindings only (agent_version_id IS NULL).
	// Published version snapshots are immutable and must be read through version-specific paths.
	ListBindings(ctx context.Context, deID int64) ([]CapabilityBinding, error)
	AddBinding(ctx context.Context, b *CapabilityBinding) (*CapabilityBinding, error)
	RemoveBinding(ctx context.Context, bindingID int64) error

	// M3 §3 版本: PublishVersion 在事务内做 (写 agent_versions + 复制草稿 bindings + 更新 current_version)
	PublishVersion(ctx context.Context, deID int64, snapshot map[string]any, publishedBy int64, notes string) (*Version, error)
	ListVersions(ctx context.Context, deID int64) ([]Version, error)
	GetVersion(ctx context.Context, deID int64, version int) (*Version, error)
	// SetGrayscale 切目标版本到 grayed + 设置百分比/部门; DB partial unique 保证同 Agent 仅 1 个 grayed。
	SetGrayscale(ctx context.Context, deID int64, version int, pct int, groups []string) (*Version, error)
	// Rollback 把 current_version 指回旧版本, 任何 grayed 版本 → rolled_back
	Rollback(ctx context.Context, deID int64, version int) (*DigitalEmployee, error)

	// M3 §6 A2A 白名单
	ListCallableWhitelist(ctx context.Context, calleeID int64) ([]CalleeWhitelistEntry, error)
	AddCallableWhitelist(ctx context.Context, calleeID, callerID int64, grantedBy *int64, note string) (*CalleeWhitelistEntry, error)
	DeleteCallableWhitelist(ctx context.Context, entryID int64) error

	// ADR-0037 BYOK: api_key 密文列单独走这一对方法, 不并进通用 Update
	// (避免"忘了传密钥字段"被通用 Update 误判成"要清空密钥")。
	// SetModelServiceAPIKey 写入/轮转 BYOK api_key 密文; prefix 供审计/GET 响应展示。
	SetModelServiceAPIKey(ctx context.Context, id int64, ciphertext []byte, prefix string, version int) error
	// ClearModelServiceAPIKey 清空 BYOK api_key 密文三列 (数字员工删除或 model_source 切回 platform_whitelist 时)。
	ClearModelServiceAPIKey(ctx context.Context, id int64) error
}
