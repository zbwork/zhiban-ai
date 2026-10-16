// Package cron 是 M9 Agent 定时任务的领域类型 (Phase A).
//
// Phase A 范围 (见 docs/tasks/m9-agent-tasks-cron.md):
//   - scheduler_kind 固定 'bus' (Phase B 扩 'openclaw')
//   - delivery 仅支持指定 single-chat conversation; group/room 拒
//   - executor 投 system role trigger message → 复用 chat.RunAgentForConversation
//   - 失败重试单次; consecutive_failures 达阈值 → status='error'
//
// 不变量:
//   - admin 强制 pause 走 enabled=false + status='paused' + metadata.admin_disabled=true
//     (不再用 status='disabled')
//   - cron worker 多副本通过 cron_dispatch_locks 互斥
package cron

import (
	"time"
)

// Status 任务生命周期 (与 000010 CHECK 一致).
const (
	StatusActive   = "active"
	StatusPaused   = "paused"
	StatusError    = "error"
	StatusArchived = "archived"
)

// RunStatus agent_cron_runs.status (与 000010 CHECK 一致).
const (
	RunStatusQueued    = "queued"
	RunStatusRunning   = "running"
	RunStatusSucceeded = "succeeded"
	RunStatusFailed    = "failed"
	RunStatusCancelled = "cancelled"
)

// TriggerKind agent_cron_runs.trigger_kind.
const (
	TriggerKindCron   = "cron"
	TriggerKindManual = "manual"
	TriggerKindAdmin  = "admin"
)

// Scheduler backend.
const (
	SchedulerBus     = "bus"
	SchedulerRuntime = "runtime"
)

// Runtime projection constants.
const (
	RuntimeAdapterOpenClaw = "openclaw"

	RuntimeSyncPending  = "pending"
	RuntimeSyncSyncing  = "syncing"
	RuntimeSyncSynced   = "synced"
	RuntimeSyncDrift    = "drift"
	RuntimeSyncError    = "error"
	RuntimeSyncDeleting = "deleting"
)

// Job 一行 agent_cron_jobs.
type Job struct {
	ID                  int64
	UUID                string
	TenantID            int64
	AccountID           int64
	AgentID             int64
	AgentUUID           string // join 后填; repo 不强求每次填
	AgentName           string // 批查后填 (admin 列表显示名); repo 不强求每次填
	OwnerDisplayName    string // 批查后填 (admin 列表显示名); repo 不强求每次填
	TenantName          string // 批查后填 (platform 跨租户运营列表显示名); repo 不强求每次填
	Name                string
	Description         string
	ScheduleCron        string
	Timezone            string
	Payload             map[string]any
	Delivery            map[string]any
	Enabled             bool
	Status              string
	SchedulerKind       string
	ConcurrentPolicy    string
	HistoryLimit        int
	ConsecutiveFailures int
	FailureThreshold    int
	LastRunAt           *time.Time
	LastRunStatus       string
	LastRunSummary      string
	NextRunAt           *time.Time
	Metadata            map[string]any
	CreatedAt           time.Time
	UpdatedAt           time.Time
	// F08 §8.2 #4 / R9 prompt 模板; 老 cron 这两列分别是 NULL / '{}'.
	PromptTemplateID        *int64
	PromptTemplateVariables map[string]any
	// L 增量: F08 §5.1 admin 列表需要的 schema 字段;
	// 之前 scanJob 没读, admin web 拿不到 pause_reason / delivery_kind 列.
	// DeliveryKind: 'direct' | 'group' (老行 backfill 'direct'; 空串视作未知).
	// PauseReason: 可空 ('admin_disabled' / 'owner_inactive' / 'quota_exceeded' / 'user_paused').
	// OwnerInactiveAt: pause_reason='owner_inactive' 时填.
	DeliveryKind    string
	PauseReason     string
	OwnerInactiveAt *time.Time
}

// Run 一行 agent_cron_runs.
type Run struct {
	ID              int64
	UUID            string
	JobID           int64
	TenantID        int64
	AccountID       int64
	AgentID         int64
	ConversationID  *int64
	MessageUUID     string
	StartedAt       time.Time
	FinishedAt      *time.Time
	Status          string
	DurationMs      int64
	Summary         string
	ErrorMessage    string
	TriggerKind     string
	RetryCount      int
	TraceID         string
	PayloadSnapshot map[string]any
	CreatedAt       time.Time
	// F08 §8.2 #4 / R9: 触发时渲染后的 prompt 全文; nil/空 = 老 payload.prompt 路径或还没渲染.
	// R12 ② 仅 owner 可见 (admin 路径不暴露 RunDTO 详情).
	RenderedPromptSnapshot string
}

// RuntimeBinding tracks one Bus cron job projection into a runtime-native scheduler.
// Bus agent_cron_jobs remains the desired-state authority.
type RuntimeBinding struct {
	ID                   int64
	UUID                 string
	CronJobID            int64
	TenantID             int64
	AccountID            int64
	AgentID              int64
	RuntimeEnvironmentID int64
	AdapterKind          string
	Framework            string
	RemoteJobID          string
	DesiredRevision      string
	RemoteRevision       string
	SyncStatus           string
	LastSyncError        string
	LastSyncedAt         *time.Time
	LastSeenAt           *time.Time
	SourceSnapshot       map[string]any
	CreatedAt            time.Time
	UpdatedAt            time.Time
	DeletedAt            *time.Time
}

// CreateJobInput service → repo.
type CreateJobInput struct {
	TenantID     int64
	AccountID    int64
	AgentID      int64
	Name         string
	Description  string
	ScheduleCron string
	Timezone     string
	Payload      map[string]any
	Delivery     map[string]any
	NextRunAt    *time.Time
	// F08 §8.2 #4 / R9: 模板 (可选; nil 代表沿用老 payload.prompt 路径).
	PromptTemplateID        *int64
	PromptTemplateVariables map[string]any
	// M 返修 · F08 R4 · agent_cron_jobs.delivery_kind NOT NULL CHECK direct/group.
	// service 必须从 resolveDelivery (conv + room kind) 推导后填入; 不接受前端裸值.
	// 空串 → repo INSERT 会被 PG CHECK 拒掉.
	DeliveryKind  string
	SchedulerKind string
	// RunOnce · 客户端"单次执行"变通实现: 标准 5 字段 cron 无年字段, 落库的 ScheduleCron
	// 只能表达"每年这个月这天这个时间点", 不能表达真正的"只触发一次"。RunOnce=true 时
	// repo 把 metadata.run_once=true 写进 agent_cron_jobs.metadata; finalizeRun 在任务
	// 第一次跑到终态 (succeeded/failed/cancelled 任一) 后立即 Enabled=false + 停用该任务,
	// 阻止它在下一年同一时刻再次触发。不是新增 schema 列, 复用既有 metadata JSONB。
	RunOnce bool
}

// PatchJobInput nil 字段不改.
type PatchJobInput struct {
	Name           *string
	Description    *string
	ScheduleCron   *string
	Timezone       *string
	Payload        map[string]any
	Delivery       map[string]any
	Enabled        *bool
	Status         *string
	NextRunAt      *time.Time
	ClearAdminFlag bool // 清 metadata.admin_disabled
	SetAdminFlag   bool // 设 metadata.admin_disabled=true (admin force-disable)
	ResetFailures  bool // resume 时清 consecutive_failures
	IncFailures    bool // 失败时 +1
	SetLastRun     *RunSummary
	// F08 §8.2 #4 / R9: 模板 (nil 不改; SetPromptTemplate=true + ID=nil → 清掉模板退回老 payload).
	SetPromptTemplate       bool
	PromptTemplateID        *int64
	PromptTemplateVariables map[string]any
	// M 返修 · F08 R4 · PatchJob 改 conversation_uuid 时同步重算 delivery_kind;
	// nil → 不改 (避免无关 patch 误覆盖列).
	DeliveryKind  *string
	SchedulerKind *string
	// M 返修 · F08 R6 / R10 · pause_reason 列同步:
	//   - PauseReason != nil + non-empty → SET pause_reason=$
	//   - ClearPauseReason = true → SET pause_reason=NULL
	//   - 两者都不动 → no-op
	// admin force-disable: PauseReason='admin_disabled'.
	// admin clear-admin-flag: 如果当前 pause_reason='admin_disabled' 则 ClearPauseReason=true.
	// owner_inactive / quota_exceeded 由各自路径维护, 不归 admin flag 清除范围.
	PauseReason      *string
	ClearPauseReason bool
	// SetRunOnce · nil = 不改; *true = 写 metadata.run_once=true; *false = 清掉该 key。
	// 编辑已有任务把重复方式从"单次执行"切到别的档位时必须显式传 *false, 否则旧
	// metadata.run_once 残留会让 finalizeRun 在下次成功执行后误把任务自动停用。
	SetRunOnce *bool
}

// UpsertRuntimeBindingInput service/adapter → repo.
type UpsertRuntimeBindingInput struct {
	CronJobID            int64
	TenantID             int64
	AccountID            int64
	AgentID              int64
	RuntimeEnvironmentID int64
	AdapterKind          string
	Framework            string
	RemoteJobID          string
	DesiredRevision      string
	RemoteRevision       string
	SyncStatus           string
	LastSyncError        string
	SourceSnapshot       map[string]any
	LastSyncedAt         *time.Time
}

// RunSummary 写 agent_cron_jobs.last_run_*.
type RunSummary struct {
	At      time.Time
	Status  string
	Summary string
}

// CreateRunInput service → repo.
type CreateRunInput struct {
	JobID           int64
	TenantID        int64
	AccountID       int64
	AgentID         int64
	TriggerKind     string
	PayloadSnapshot map[string]any
	TraceID         string
}

// UpdateRunInput nil 字段不改.
type UpdateRunInput struct {
	Status         *string
	FinishedAt     *time.Time
	DurationMs     *int64
	Summary        *string
	ErrorMessage   *string
	ConversationID *int64
	MessageUUID    *string
	// F08 §8.2 #4 / R9: 渲染后 prompt 快照 (run 写时如有则落 agent_cron_runs.rendered_prompt_snapshot).
	RenderedPromptSnapshot *string
}

// ListJobsFilter caller-facing 过滤.
type ListJobsFilter struct {
	TenantID  int64
	AccountID int64
	Limit     int
}

// ListRunsFilter run 列表.
type ListRunsFilter struct {
	TenantID   int64
	AccountID  int64
	JobID      int64 // 0 = all
	Status     string
	Limit      int
	BeforeUUID string
}

// ---- F08 §5.1 platform 跨租户运营监控 (只读) ----

// PlatformJobsFilter · platform /cron-jobs 跨租户列表过滤 (后端分页).
//
// 显式跨租户: repo 不从 ctx 取 tenant, 平台 permission guard 由 transport 层保证.
type PlatformJobsFilter struct {
	TenantKeyword          string // 匹配 tenant.name ILIKE 或 tenant_id 精确
	TaskKeyword            string // 匹配 agent_cron_jobs.name ILIKE
	Status                 string // '' | active | paused | error | archived
	LastResult             string // '' | succeeded | failed | running | none(未运行)
	OnlyConsecutiveFailure bool   // 只看 consecutive_failures > 0
	Limit                  int
	Offset                 int
}

// PlatformOverviewCounts · /cron-jobs/overview 顶部统计的原始计数 (service 再算成功率)。
type PlatformOverviewCounts struct {
	TotalJobs              int64
	ActiveJobs             int64      // enabled=true AND status='active'
	ConsecutiveFailureJobs int64      // consecutive_failures > 0
	LastRunAt              *time.Time // MAX(last_run_at)
	Runs24hSucceeded       int64
	Runs24hFailed          int64
	LastFailureAt          *time.Time // MAX(started_at) WHERE status='failed'
}

// FailureReasonStat / FailureTenantStat / ConsecutiveFailureStat · 轻量失败统计行 (§5.3 失败排行)。
type FailureReasonStat struct {
	Reason string
	Count  int64
}
type FailureTenantStat struct {
	TenantID   int64
	TenantName string // 批查后填
	Count      int64
}
type ConsecutiveFailureStat struct {
	JobUUID             string
	Name                string
	TenantID            int64
	TenantName          string // 批查后填
	ConsecutiveFailures int
}

// ---- F08 §8.2 #4 / R9 prompt template ----

// TemplateScope cron_prompt_templates.scope_kind.
const (
	TemplateScopePlatform = "platform"
	TemplateScopeTenant   = "tenant"
)

// TemplateStatus cron_prompt_templates.status.
const (
	TemplateStatusDraft    = "draft"
	TemplateStatusActive   = "active"
	TemplateStatusArchived = "archived"
)

// TemplateVarType cron_prompt_template_variables.var_type.
const (
	VarTypeString   = "string"
	VarTypeEnum     = "enum"
	VarTypeInt      = "int"
	VarTypeDateTime = "datetime"
	VarTypeList     = "list"
)

// PauseReason agent_cron_jobs.pause_reason CHECK 取值
// (与 sql/postgres/000001_init_schema.up.sql chk_cron_jobs_pause_reason 对齐).
const (
	PauseReasonAdminDisabled = "admin_disabled"
	PauseReasonOwnerInactive = "owner_inactive"
	PauseReasonQuotaExceeded = "quota_exceeded"
	PauseReasonUserPaused    = "user_paused"
)

// TenantMembershipStatusChangedEvent · F01 publish 事件; F08 §4.4 listener 消费.
//
// F08 §0.2 / §4.4 v0.4.3: F01 当前尚未对外开放该事件; 这里只是定义 payload 结构,
// cmd/bus 装配 listener 时绑定到具体事件源 (PG NOTIFY / events_outbox subscriber 等),
// **不**在 F08 写死 topic 字符串.
type TenantMembershipStatusChangedEvent struct {
	AccountID int64
	TenantID  int64
	OldStatus string
	NewStatus string
}

// PromptTemplate · cron_prompt_templates 行的领域模型 (R9).
//
// J 返修: 增加 Description (列在 schema 早就有, 早期 model 漏读, 导致 admin 编辑
// drawer 拿不回 description, 保存时被空 state 抹掉. 见 F08 §3.1.2 / §5.2).
//
// K 增量: 加 UpdatedAt 供 admin 列表展示"上次更新时间"; CreatedAt 也一并放出来,
// 后续如需排序 / 审计可直接复用 (本期只用到 UpdatedAt).
type PromptTemplate struct {
	ID           int64
	UUID         string
	ScopeKind    string // "platform" | "tenant"
	TenantID     *int64 // scope=tenant 必填; scope=platform 必 NULL
	Code         string
	Name         string
	Description  string // 模板说明 (NULL → ""); admin 编辑 drawer 需要回填
	TemplateBody string
	IsSystem     bool
	Status       string    // "draft" | "active" | "archived"
	CreatedAt    time.Time // 入库时间; admin 视角排序 / 审计可用
	UpdatedAt    time.Time // 最近一次更新时间; admin 列表展示"上次更新"
}

// PromptTemplateVariable · cron_prompt_template_variables 行的领域模型 (R9).
type PromptTemplateVariable struct {
	ID           int64
	TemplateID   int64
	VarName      string
	VarType      string // "string" | "enum" | "int" | "datetime" | "list"
	Required     bool
	DefaultValue any   // 来自 jsonb (number / string / array / map / null)
	Options      []any // var_type='enum' 时填可选值数组 (其它类型可 nil)
	DisplayName  string
	OrderIndex   int
}

// ---- G4 / F08 §5.2 admin CRUD inputs ----

// CreatePromptTemplateInput · admin 建租户模板 (scope='tenant' 强制).
type CreatePromptTemplateInput struct {
	TenantID     int64
	Code         string
	Name         string
	Description  string
	TemplateBody string
	Status       string // "draft" / "active" / "archived"; service 默认 active
	Variables    []PromptTemplateVariable
	CreatedBy    int64
}

// PatchPromptTemplateInput · nil 字段不改; Variables nil 不动 (要清空请传 []).
type PatchPromptTemplateInput struct {
	Name         *string
	Description  *string
	TemplateBody *string
	Status       *string
	Variables    []PromptTemplateVariable
	ReplaceVars  bool // true 表示按 Variables 全量替换 (含清空)
	UpdatedBy    int64
}
