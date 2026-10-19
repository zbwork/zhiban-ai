// Package cron 是 M9 Agent 定时任务的应用服务 (Phase A).
//
// 范围 (docs/tasks/m9-agent-tasks-cron.md):
//   - Bus client CRUD + pause/resume + immediate run + history + open-chat
//   - Admin tenant list + force-disable + clear-admin-flag
//   - Scheduler dispatcher (30s 扫描 + cron_dispatch_locks 互斥)
//   - Executor (复用 chat.RunAgentForConversation + system role trigger message)
//
// 严格按 docs/tasks/m9-agent-tasks-cron.md §4:
//   - scheduler_kind 固定 'bus'
//   - delivery 仅 single-chat conversation; group/room 拒
//   - admin force-disable 走 enabled=false + status='paused' + metadata.admin_disabled=true
//   - 失败 consecutive_failures+1; 达阈值 → status='error' 暂停调度
package cron

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	rcron "github.com/robfig/cron/v3"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	dombilling "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/billing"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	domcron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/cron"
	domevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	domlocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	domnotification "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/mobilepush"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	repocron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/cron"
	repoevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

// Phase A 错误码 (docs/tasks/m9-agent-tasks-cron.md §4).
const (
	ErrCodeCronExprInvalid               = "cron.expression_invalid"
	ErrCodeCronFrequencyBelowMin         = "cron.frequency_below_min"
	ErrCodeCronTimezoneInvalid           = "cron.timezone_invalid"
	ErrCodeCronJobNotFound               = "cron.job_not_found"
	ErrCodeCronRunNotFound               = "cron.run_not_found"
	ErrCodeCronDeliveryConvNotFound      = "cron.delivery_conversation_not_found"
	ErrCodeCronDirectDeliveryUnavailable = "cron.direct_delivery_unavailable"
	ErrCodeCronGroupDeliveryUnsupported  = "cron.group_delivery_not_supported"
	ErrCodeCronDeliveryStrategyUnsup     = "cron.delivery_strategy_unsupported"
	ErrCodeCronResumeBlockedByAdmin      = "cron.resume_blocked_by_admin"
	ErrCodeCronAgentNotFound             = "cron.agent_not_found"
	ErrCodeCronAgentNotVisible           = "cron.agent_not_visible"
	ErrCodeCronVisibilityNotWired        = "cron.visibility_not_wired"
	ErrCodeCronPayloadTooLarge           = "cron.payload_too_large"
	ErrCodeCronStaleRunFailed            = "cron.worker_stale_running_timeout"
	// Bus-scheduled tasks support the same runtime frameworks as the unified
	// chat runner. Native runtime cron projection is an optional capability.
	ErrCodeCronAgentNotSupported = "cron.agent_not_supported"
	// F08 §8.2 #7 / R7: 限额错误码 (账号 ≤ 20, 租户 ≤ 500; 全局可配, 不读 overrides 表).
	ErrCodeCronAccountJobLimit = "cron.account_job_limit_reached"
	ErrCodeCronTenantJobLimit  = "cron.tenant_job_limit_reached"
	// F08 §8.2 #4 / R9 prompt 模板: 错误码.
	ErrCodeCronTemplateNotFound       = "cron.prompt_template_not_found"
	ErrCodeCronTemplateVarMissing     = "cron.prompt_template_variable_missing"
	ErrCodeCronTemplateVarTypeBad     = "cron.prompt_template_variable_type_mismatch"
	ErrCodeCronTemplateCreateConflict = "cron.prompt_template_payload_conflict"
	// F08 §8.2 #2 / R4 群投递 + R8 双向校验: 错误码.
	ErrCodeCronGroupMemberNotIn = "cron.group_member_not_in"
	ErrCodeCronAgentNotInGroup  = "cron.agent_not_in_group"
	// G4 / F08 §5.2 admin prompt-template CRUD: 错误码.
	ErrCodeCronTemplateReadonly     = "cron.prompt_template_readonly"
	ErrCodeCronTemplateInUse        = "cron.prompt_template_in_use"
	ErrCodeCronTemplateCodeConflict = "cron.prompt_template_code_conflict"
)

// 默认值 (env / config 覆盖).
const (
	DefaultMinFrequency = 5 * time.Minute
	// 5s (原 30s): DueJobs 用 now+DispatchInterval 前瞻选 job, 轮询越密最多提前触发的
	// 误差窗口越小 (原 30s 上限收窄到 5s)。代价是空轮询的 DB 往返更频繁, 单机场景可接受。
	DefaultDispatchInterval = 5 * time.Second
	DefaultLockTTL          = 5 * time.Minute
	DefaultFailureThreshold = 3
	DefaultPayloadMaxBytes  = 16 * 1024
	DefaultTimezone         = "Asia/Shanghai"
	// DefaultRunStaleTimeout Codex P1#3: running run 在 executor 崩溃后超过该阈值即被
	// reaper 标 failed (避免 concurrent_policy=forbid 永久阻塞新触发).
	DefaultRunStaleTimeout = 2 * time.Hour
	// F08 §8.2 #7 / R7 v0.4.3 默认上限. 0 不是"禁用限额"语义, 仅表示"上层未注入,
	// 兜底为这个默认". 如需事实上无上限, 设置为足够大的整数 (如 1_000_000).
	DefaultAccountJobLimit = 20
	DefaultTenantJobLimit  = 500
	// SSE event kinds.
	EventCronRunStarted  = "cron.run.started"
	EventCronRunFinished = "cron.run.finished"
	EventCronJobUpdated  = "cron.job.updated"
)

// Service 对外接口.
type Service interface {
	// Client API ----
	ListJobs(ctx context.Context, accountID, tenantID int64) ([]JobDTO, error)
	CreateJob(ctx context.Context, accountID, tenantID int64, req CreateJobReq) (*JobDTO, error)
	GetJob(ctx context.Context, accountID, tenantID int64, jobUUID string) (*JobDTO, error)
	PatchJob(ctx context.Context, accountID, tenantID int64, jobUUID string, req PatchJobReq) (*JobDTO, error)
	DeleteJob(ctx context.Context, accountID, tenantID int64, jobUUID string) error
	RunNow(ctx context.Context, accountID, tenantID int64, jobUUID string) (*RunDTO, error)
	Pause(ctx context.Context, accountID, tenantID int64, jobUUID string) (*JobDTO, error)
	Resume(ctx context.Context, accountID, tenantID int64, jobUUID string) (*JobDTO, error)

	ListRunsForJob(ctx context.Context, accountID, tenantID int64, jobUUID string, before string, limit int) ([]RunDTO, error)
	ListRuns(ctx context.Context, accountID, tenantID int64, before string, limit int) ([]RunDTO, error)
	GetRun(ctx context.Context, accountID, tenantID int64, runUUID string) (*RunDTO, error)
	OpenChat(ctx context.Context, accountID, tenantID int64, runUUID string) (*OpenChatResp, error)

	// F08 §3.1.1 R9 client 可见 prompt-template (只读): platform active + 本租户 active.
	ListVisiblePromptTemplates(ctx context.Context, tenantID int64) ([]PromptTemplateDTO, error)
	GetVisiblePromptTemplateVariables(ctx context.Context, tenantID int64, tplUUID string) (*PromptTemplateDetailDTO, error)

	// Admin API ----
	AdminListTenantJobs(ctx context.Context, tenantID int64) ([]JobDTO, error)
	// AdminGetTenantJob F25 返修: 租户 admin 单任务详情 + 净化运行记录（无 payload/prompt 正文）。
	AdminGetTenantJob(ctx context.Context, tenantID int64, jobUUID string, runLimit int) (*AdminTenantCronJobDetailDTO, error)
	AdminForceDisable(ctx context.Context, tenantID, actorID int64, jobUUID string) (*JobDTO, error)
	AdminClearAdminFlag(ctx context.Context, tenantID, actorID int64, jobUUID string) (*JobDTO, error)

	// AdminCapabilityDryRun · Phase 4 M9G dry-run 工具.
	//
	// 扫所有 enabled cron job, 按当前 capability gating (protocol + integration_mode)
	// 判定是否仍允许. 返回**不允许**但仍 enabled 的 row 列表; **不**自动 disable.
	// 上线 enforcement 前由 admin 走 admin web 决议 (T-M9G-W2). limit 上限 5000.
	AdminCapabilityDryRun(ctx context.Context, limit int) (*DryRunReport, error)

	// Platform 跨租户运营监控 (F08 §5.1/§5.3, 只读). 显式跨租户, 走 platform.cron.read guard。
	PlatformCronOverview(ctx context.Context) (*PlatformCronOverviewDTO, error)
	PlatformListCronJobs(ctx context.Context, f PlatformCronListReq) (*PlatformCronListDTO, error)
	PlatformGetCronJob(ctx context.Context, jobUUID string, runLimit int) (*PlatformCronJobDetailDTO, error)

	// G4 / F08 §5.2: tenant admin prompt-template CRUD (platform 模板对租户只读).
	AdminListTenantPromptTemplates(ctx context.Context, tenantID int64) ([]PromptTemplateAdminDTO, error)
	// I 增量: admin 视角的 detail GET (含 body + variables); 与 client 路径区分,
	// 本租户 draft/active/archived 全可读, 不复检 status. admin web 编辑 drawer 用.
	AdminGetTenantPromptTemplate(ctx context.Context, tenantID int64, tplUUID string) (*PromptTemplateDetailDTO, error)
	AdminCreateTenantPromptTemplate(ctx context.Context, tenantID, actorID int64, req CreatePromptTemplateReq) (*PromptTemplateDetailDTO, error)
	AdminPatchTenantPromptTemplate(ctx context.Context, tenantID, actorID int64, tplUUID string, req PatchPromptTemplateReq) (*PromptTemplateDetailDTO, error)
	AdminDeleteTenantPromptTemplate(ctx context.Context, tenantID, actorID int64, tplUUID string) error

	// 平台控制台 · 平台模板 CRUD (scope=platform, tenant_id NULL)。
	// 租户后台对这些模板只读 (isTemplateReadonlyForTenant), 客户端只消费 active。
	AdminListPlatformPromptTemplates(ctx context.Context) ([]PromptTemplateAdminDTO, error)
	AdminGetPlatformPromptTemplate(ctx context.Context, tplUUID string) (*PromptTemplateDetailDTO, error)
	AdminCreatePlatformPromptTemplate(ctx context.Context, actorID int64, req CreatePromptTemplateReq) (*PromptTemplateDetailDTO, error)
	AdminPatchPlatformPromptTemplate(ctx context.Context, actorID int64, tplUUID string, req PatchPromptTemplateReq) (*PromptTemplateDetailDTO, error)
	AdminDeletePlatformPromptTemplate(ctx context.Context, actorID int64, tplUUID string) error

	// Internal (Dispatcher + Executor + Reaper) ----
	DispatchTick(ctx context.Context) (int, error)
	ProcessQueuedRuns(ctx context.Context) (int, error)
	// ReapStaleRuns Codex P1#3: 标 running 但超过 RunStaleTimeout 的 run 为 failed.
	// 返回处理行数. 应当与 DispatchTick 同频调用 (Loop 内已串联).
	ReapStaleRuns(ctx context.Context) (int, error)

	// HandleTenantMembershipStatusChanged · F08 §8.2 #10 / R10 listener 纯方法.
	//
	// 监听 F01 提供的事件 account.tenant_membership_status_changed (当前 F01 未对外开放, 见 §4.4);
	// 由 cmd/bus 装配 listener 时绑定具体事件源 (PG NOTIFY / events_outbox).
	//
	// 行为:
	//   - NewStatus ∈ {suspended, left}: 一次性 paused 该 (tenant, account) 名下所有 active cron
	//     + pause_reason=owner_inactive + owner_inactive_at=now.
	//   - 其它 NewStatus (含 active 反向回归): 直接 return 0, nil (不 resume 老 cron, 符合 §1.2 US-C).
	//   - 不做移交 / 不做 30 天 archive (F08 v0.4.3 决议).
	//   - 不写死 runtime release intent topic; 调用方负责把"用户实例释放 intent"派发出去.
	//
	// 返回受影响 cron 数 + error.
	HandleTenantMembershipStatusChanged(ctx context.Context, evt domcron.TenantMembershipStatusChangedEvent) (int, error)

	// OpenClaw native cron backchannel.
	HandleOpenClawCronDone(ctx context.Context, in OpenClawCronDoneInput) error
	HandleOpenClawCronEvents(ctx context.Context, in OpenClawCronEventsInput) (*OpenClawCronEventsResult, error)
	HandleCronCommand(ctx context.Context, in CronCommandInput) (*CronCommandResult, error)
	ReconcileRuntimeProjections(ctx context.Context, limit int) (int, error)

	// HandleRunStreamTerminal · 2026-06-12 run 终态语义: runner 桥接层 (cmd/bus) 在
	// agent 回复流终态时回调, 把 running 的 run 收敛为 succeeded/failed/cancelled, 并把
	// cron_run_status 回写 trigger 消息 metadata (客户端卡片/历史状态一致)。幂等:
	// run 已是终态时 no-op。
	HandleRunStreamTerminal(ctx context.Context, runUUID, triggerMessageUUID, status, errMsg string)
}

type OpenClawCronDoneInput struct {
	RunID         string
	AgentID       string
	JobID         string
	SessionKey    string
	Trigger       string
	Success       bool
	DurationMs    int64
	LastAssistant string
	AccountNo     string
	AccountIDText string
}

type OpenClawCronEventsInput struct {
	Op            string
	Jobs          []map[string]any
	AccountNo     string
	AccountIDText string
	// TenantIDText pod 自报租户 (AI_OFFICE_TENANT_ID env 注入); 收编时与会话归属交叉校验.
	TenantIDText string
}

type OpenClawCronEventsResult struct {
	Seen     int `json:"seen"`
	Matched  int `json:"matched"`
	Drifted  int `json:"drifted"`
	Rejected int `json:"rejected"`
	// Adopted 收编数: 数字员工对话内用原生 cron 工具自建、bus 侧补建权威行的任务.
	Adopted int `json:"adopted"`
	// Deleted runtime 侧删除回流软删 bus 任务数.
	Deleted int `json:"deleted"`
}

type CronCommandInput struct {
	Source           string         `json:"source"`
	Operation        string         `json:"operation"`
	TenantID         int64          `json:"tenant_id"`
	AccountID        int64          `json:"account_id"`
	AgentUUID        string         `json:"agent_uuid"`
	ConversationUUID string         `json:"conversation_uuid"`
	JobUUID          string         `json:"job_uuid,omitempty"`
	Name             string         `json:"name,omitempty"`
	Description      string         `json:"description,omitempty"`
	ScheduleCron     string         `json:"schedule_cron,omitempty"`
	Timezone         string         `json:"timezone,omitempty"`
	Prompt           string         `json:"prompt,omitempty"`
	Enabled          *bool          `json:"enabled,omitempty"`
	Patch            map[string]any `json:"patch,omitempty"`
	IdemKey          string         `json:"idem_key,omitempty"`
}

type CronCommandResult struct {
	Operation string  `json:"operation"`
	Job       *JobDTO `json:"job,omitempty"`
	Deleted   bool    `json:"deleted,omitempty"`
}

// AgentLookup composer/agent 借用.
type AgentLookup interface {
	GetByUUID(ctx context.Context, agentUUID string) (*domagent.DigitalEmployee, error)
}

// ContactsVisibility Codex P1#1: 复用 contacts service 的可见性收口接口.
//
// 与 svcchat.ContactsVisibility / svccontacts.Service.AssertAgentVisible 同款窄抽象;
// 不直接 import contacts 包 (避免循环依赖 + 让单测能 mock).
//
// nil → cron 全链路 fail-closed (CreateJob / executeRun 都直接拒).
//
// 该接口必须**同时**覆盖以下场景 (与 contacts §可见性闸口一致):
//   - agent 是否仍 active (未下架 / 未软删)
//   - agent.visibility (tenant / workspace) 是否与 caller 兼容
//   - tenant_memberships.contact_enabled / contact_overrides 是否拒绝
//   - 跨租户 (agent.tenant_id != caller.tenant_id) 必拒
type ContactsVisibility interface {
	AssertAgentVisible(ctx context.Context, accountID, tenantID int64, agentUUID string) error
}

// ConversationLookup 复用 chat 已有的 GetByUUID.
type ConversationLookup interface {
	GetByUUID(ctx context.Context, uuid string) (*domconv.Conversation, error)
}

// RuntimeLookup · Phase 4 capability gating 用; 查 runtime_registrations.framework.
//
// nil 时 cron 服务对 capability gating fail-open (向后兼容); 生产应必填.
// admin / cmd/bus 装配 cron service 时显式注入。
type RuntimeLookup interface {
	GetFrameworkByID(ctx context.Context, registrationID int64) (string, error)
}

// RuntimeProjector projects Bus-authoritative cron specs into a runtime-native scheduler.
type RuntimeProjector interface {
	Kind() string
	Upsert(ctx context.Context, in RuntimeProjectionInput) (RuntimeProjectionResult, error)
	Delete(ctx context.Context, in RuntimeProjectionDeleteInput) error
}

type RuntimeProjectionInput struct {
	JobID                int64
	TenantID             int64
	AccountID            int64
	AgentID              int64
	AgentUUID            string
	RuntimeEnvironmentID int64
	RemoteJobID          string
	Name                 string
	Description          string
	ScheduleCron         string
	Timezone             string
	Prompt               string
	Enabled              bool
	Status               string
	Revision             string
}

type RuntimeProjectionResult struct {
	RemoteJobID    string
	RemoteRevision string
}

type RuntimeProjectionDeleteInput struct {
	JobID                int64
	TenantID             int64
	AccountID            int64
	AgentID              int64
	RuntimeEnvironmentID int64
	RemoteJobID          string
}

// TenantLookup · F08 R11 · cron job 时区 fallback 用; 查 tenants.timezone.
//
// nil 时 cron 服务 fallback 直接退到 cfg.DefaultTimezone (向后兼容);
// 生产应必填以走 job → tenant → global 三层 fallback (F08 §4.8).
type TenantLookup interface {
	GetTimezone(ctx context.Context, tenantID int64) (string, error)
}

// RoomLookup · F08 §8.2 #2 / R4+R8 · 取 conversations.room_id → rooms 行 + 成员列表.
//
// 用于 cron 投递时判定 direct/group + R8 双向校验.
// nil 时 cron 群投递整段关闭 (resolveDelivery 拒所有 RoomID 非空的 conversation, 回退老硬拒语义).
//
// 生产应注入 *roomrepo.Repo (它实现下面两个方法).
type RoomLookup interface {
	GetByID(ctx context.Context, roomID int64) (*domroom.Room, error)
	ListParticipants(ctx context.Context, roomID int64) ([]domroom.Participant, error)
}

// PromptTemplateLookup · F08 §8.2 #4 / R9 · 读 cron_prompt_templates + variables.
//
// nil 时 R9 模板路径被关闭: CreateJob 提供 prompt_template_uuid 会被当作模板缺失;
// 老 payload.prompt 路径不受影响.
//
// 生产 cmd/bus 装配应注入 *repocron.Repo (它实现了下面两个方法).
type PromptTemplateLookup interface {
	GetPromptTemplateByUUID(ctx context.Context, uuid string) (*domcron.PromptTemplate, error)
	// E4 / R9: runtime executor 拿到 job.PromptTemplateID 时反查模板. *repocron.Repo 已实现.
	GetPromptTemplateByID(ctx context.Context, id int64) (*domcron.PromptTemplate, error)
	ListPromptTemplateVariables(ctx context.Context, templateID int64) ([]domcron.PromptTemplateVariable, error)
	// G3 / F08 §3.1.1: client 可见模板列表 (platform + 本租户). *repocron.Repo 已实现.
	ListVisiblePromptTemplates(ctx context.Context, tenantID int64, limit int) ([]domcron.PromptTemplate, error)
	// G4 / F08 §5.2: admin 视角 (含 draft / 本租户软删前所有).
	ListAdminTenantPromptTemplates(ctx context.Context, tenantID int64, limit int) ([]domcron.PromptTemplate, error)
	// 平台控制台视角: scope='platform' 全状态 (排软删)。*repocron.Repo 已实现.
	ListAdminPlatformPromptTemplates(ctx context.Context, limit int) ([]domcron.PromptTemplate, error)
	CountActiveJobsUsingTemplate(ctx context.Context, templateID int64) (int, error)
	// K / F08 §5.2: admin 列表批量引用数, 按 caller tenant 过滤; 用于 active_job_count 列展示.
	// 与 CountActiveJobsUsingTemplate 的差异: 单条 SQL 避免 N+1, 且按 tenant 限定可见范围.
	CountActiveJobsByTemplateIDs(ctx context.Context, tenantID int64, templateIDs []int64) (map[int64]int, error)
}

// ChatRunner 抽象 chat.Service 的 RunAgentForConversation; 避免循环 import.
type ChatRunner interface {
	RunAgentForConversation(ctx context.Context, in ChatRunInput) (*ChatRunOutput, error)
}

// ChatRunInput 与 svcchat.RunAgentInput 同款字段, cmd/bus 桥接.
type ChatRunInput struct {
	AccountID          int64
	TenantID           int64
	Conversation       *domconv.Conversation
	Agent              *domagent.DigitalEmployee
	PromptText         string
	TriggerMessageUUID string // 非空: 强制以该 system trigger message 为本轮 prompt 起点
	// RunUUID · 2026-06-12 run 终态语义改造: runner 桥接层据此订阅流终态后回调
	// HandleRunStreamTerminal 把 run 收敛到 succeeded/failed/cancelled。
	RunUUID string
}

// ChatRunOutput 桥接.
type ChatRunOutput struct {
	StreamID         string
	AgentMessageUUID string
	// FinalizeDeferred · runner 已挂流终态 watcher, run 终态由 HandleRunStreamTerminal
	// 收敛; executor 不再立即标 succeeded。false = watcher 未接线/订阅失败, executor
	// 回退旧语义 (启动即 succeeded), 保证 run 不会卡在 running (另有 RunStaleTimeout 兜底)。
	FinalizeDeferred bool
}

// MessageWriter 抽象写 messages.Append; cron executor 用来写 system trigger message,
// run 终态时 PatchMetadata 回写 trigger 消息 cron_run_status (客户端卡片状态源)。
type MessageWriter interface {
	Append(ctx context.Context, m *dommsg.Message) (*dommsg.Message, error)
	PatchMetadata(ctx context.Context, uuid string, patch map[string]any) error
}

// EventPublisher 账号级 SSE publish (cron.run.* / cron.job.updated).
type EventPublisher interface {
	PublishAccountEvent(ctx context.Context, accountID, tenantID int64, payload map[string]any) error
}

// DirectConversationEnsurer 按 (tenant, account, agent) 幂等确保 human-agent
// canonical direct conversation。cron 只依赖最终 conversation UUID，不感知
// WuKong channel / room 的具体创建细节。
type DirectConversationEnsurer interface {
	EnsureDirectConversation(ctx context.Context, tenantID, accountID, agentID int64, agentUUID string) (conversationUUID string, err error)
}

type ScheduledDesktopResolver interface {
	ResolveScheduledDesktop(context.Context, int64, int64) (*domlocal.Device, error)
}

// Deps 构造依赖.
type Deps struct {
	Logger        *log.Logger
	Repo          *repocron.Repo
	Pool          *pgxpool.Pool
	Agents        AgentLookup
	Conversations ConversationLookup
	Messages      MessageWriter
	Runner        ChatRunner
	LocalDesktop  ScheduledDesktopResolver
	Audit         domevent.Publisher
	Events        EventPublisher
	Notifications interface {
		Enqueue(context.Context, domnotification.EnqueueInput) (bool, error)
	}
	// Visibility Codex P1#1: contacts 可见性闸口. **必填**: nil → CreateJob / RunNow / executor
	// 全部 fail-closed (返 cron.visibility_not_wired). admin 进程构造 cron service 时若不需要
	// 触发 (仅 list / force-disable), 可以传 nil 但不允许调那两条入口.
	Visibility ContactsVisibility
	// Runtime · Phase 4 capability gating: 决定 agent 是否允许建 cron job.
	// nil 时 cron capability gating 失效 (fail-open, 仅向后兼容; 生产必填).
	Runtime RuntimeLookup
	// Tenants · F08 R11: cron job 时区 fallback (job → tenant → cfg 三层).
	// nil 时直接退到 cfg.DefaultTimezone (向后兼容; 生产必填).
	Tenants TenantLookup
	// PromptTemplates · F08 §8.2 #4 / R9: cron_prompt_templates 读取入口.
	// nil 时 R9 路径关闭 (caller 提供模板 uuid → ErrCodeCronTemplateNotFound; 老 payload.prompt 仍可用).
	PromptTemplates PromptTemplateLookup
	// Rooms · F08 §8.2 #2 / R4+R8: 群投递 + 双向成员校验.
	// nil 时群投递整段关闭, 回退到老的"硬拒 group/room conversation"语义.
	Rooms RoomLookup
	// DirectConversations · F08 v0.4.7: 客户端选择“逻辑单聊目标”但尚无真实
	// conversation_uuid 时，在所有无副作用校验通过后按需 ensure canonical direct。
	DirectConversations DirectConversationEnsurer
	Projectors          []RuntimeProjector
	Quota               dombilling.EntitlementChecker
	NodeID              string
	Config              Config
}

// Config service 配置.
type Config struct {
	MinFrequency     time.Duration
	DispatchInterval time.Duration
	LockTTL          time.Duration
	FailureThreshold int
	PayloadMaxBytes  int
	DefaultTimezone  string
	// DisableRuntimeProjection 2026-06-12: true → 跳过 runtime native cron 投影,
	// 任务保持 scheduler_kind='bus' 由 Bus 调度/投递 (dev: pod→bus 回推不通 + pod
	// 重建清空运行时注册表, 投影只会让任务消失)。
	DisableRuntimeProjection bool

	// RunStaleTimeout Codex P1#3: running run 持续超过该时长即被 reaper 标 failed.
	// 防 executor 崩溃后 concurrent_policy=forbid 任务永久卡住. 默认 2h.
	RunStaleTimeout time.Duration
	// F08 §8.2 #7 / R7 v0.4.3: 全局 active cron 上限. 0 (未注入) → New() 兜底为 Default*JobLimit.
	// 想"放宽到事实上无限"请显式设置为足够大的整数.
	AccountJobLimit int
	TenantJobLimit  int
}

func New(deps Deps) Service {
	if deps.Logger == nil {
		deps.Logger = log.Default()
	}
	if deps.Repo == nil {
		panic("cron.New: repo required")
	}
	if deps.Pool == nil {
		deps.Pool = deps.Repo.Pool()
	}
	if deps.Pool == nil {
		panic("cron.New: pool required")
	}
	cfg := deps.Config
	if cfg.MinFrequency <= 0 {
		cfg.MinFrequency = DefaultMinFrequency
	}
	if cfg.DispatchInterval <= 0 {
		cfg.DispatchInterval = DefaultDispatchInterval
	}
	if cfg.LockTTL <= 0 {
		cfg.LockTTL = DefaultLockTTL
	}
	if cfg.FailureThreshold <= 0 {
		cfg.FailureThreshold = DefaultFailureThreshold
	}
	if cfg.PayloadMaxBytes <= 0 {
		cfg.PayloadMaxBytes = DefaultPayloadMaxBytes
	}
	if strings.TrimSpace(cfg.DefaultTimezone) == "" {
		cfg.DefaultTimezone = DefaultTimezone
	}
	if cfg.RunStaleTimeout <= 0 {
		cfg.RunStaleTimeout = DefaultRunStaleTimeout
	}
	if cfg.AccountJobLimit == 0 {
		cfg.AccountJobLimit = DefaultAccountJobLimit
	}
	if cfg.TenantJobLimit == 0 {
		cfg.TenantJobLimit = DefaultTenantJobLimit
	}
	return &impl{
		logger:        deps.Logger,
		repo:          deps.Repo,
		pool:          deps.Pool,
		agents:        deps.Agents,
		convs:         deps.Conversations,
		messages:      deps.Messages,
		runner:        deps.Runner,
		localDesktop:  deps.LocalDesktop,
		audit:         deps.Audit,
		events:        deps.Events,
		notifications: deps.Notifications,
		visibility:    deps.Visibility,
		runtime:       deps.Runtime,
		tenants:       deps.Tenants,
		templates:     deps.PromptTemplates,
		rooms:         deps.Rooms,
		directConvs:   deps.DirectConversations,
		projectors:    deps.Projectors,
		quota:         deps.Quota,
		nodeID:        deps.NodeID,
		cfg:           cfg,
	}
}

type impl struct {
	logger        *log.Logger
	repo          *repocron.Repo
	pool          *pgxpool.Pool
	agents        AgentLookup
	convs         ConversationLookup
	messages      MessageWriter
	runner        ChatRunner
	localDesktop  ScheduledDesktopResolver
	audit         domevent.Publisher
	events        EventPublisher
	notifications interface {
		Enqueue(context.Context, domnotification.EnqueueInput) (bool, error)
	}
	visibility  ContactsVisibility
	runtime     RuntimeLookup
	tenants     TenantLookup
	templates   PromptTemplateLookup
	rooms       RoomLookup
	directConvs DirectConversationEnsurer
	projectors  []RuntimeProjector
	quota       dombilling.EntitlementChecker
	nodeID      string
	cfg         Config
}

func (s *impl) SetEntitlementChecker(q dombilling.EntitlementChecker) { s.quota = q }

func SetEntitlementCheckerOnService(svc Service, q dombilling.EntitlementChecker) {
	if im, ok := svc.(*impl); ok {
		im.SetEntitlementChecker(q)
	}
}

// validateRenderedPromptSize · E6 / F08 §3.2.1 · executor 写 trigger message 前的二次长度校验.
//
// CreateJob 已校 legacy prompt 长度, 但模板渲染后体积可能膨胀 (e.g. list 变量替换);
// 这里二次拦截避免超长 trigger message 落 PG / 推到 chat runner.
//
// 错误码沿用 cron.payload_too_large; max <= 0 表示关掉本检查.
func validateRenderedPromptSize(prompt string, max int) error {
	if max <= 0 {
		return nil
	}
	if len(prompt) > max {
		return apperr.New(apperr.InvalidParams, ErrCodeCronPayloadTooLarge).
			Withf("rendered prompt %d > max %d", len(prompt), max)
	}
	return nil
}

// validatePatchPromptMutex · E5 · PatchJob 中"prompt vs template_uuid 互斥"前置校验.
//
// 不变量:
//   - 同时传 prompt + 非空 template_uuid → cron.prompt_template_payload_conflict.
//   - 仅 template_uuid="" 清模板: caller 必须 (a) 同步传非空 prompt, 或
//     (b) job 原 payload.prompt 不空; 否则 prompt invalid.
//   - 其余组合 (仅 prompt / 仅 template_uuid / 仅 variables / 都不传) → nil.
//
// 纯函数, 便于单测.
func validatePatchPromptMutex(req PatchJobReq, currentLegacyPrompt string) error {
	if req.Prompt != nil && req.PromptTemplateUUID != nil &&
		strings.TrimSpace(*req.PromptTemplateUUID) != "" {
		return apperr.New(apperr.InvalidParams, ErrCodeCronTemplateCreateConflict).
			Withf("prompt and prompt_template_uuid are mutually exclusive on patch")
	}
	if req.PromptTemplateUUID != nil && strings.TrimSpace(*req.PromptTemplateUUID) == "" {
		// 清模板时必须有可用 prompt fallback.
		hasIncomingPrompt := req.Prompt != nil && strings.TrimSpace(*req.Prompt) != ""
		if !hasIncomingPrompt && strings.TrimSpace(currentLegacyPrompt) == "" {
			return apperr.ErrInvalidParams.
				Withf("clearing prompt_template requires non-empty prompt (req or job.payload.prompt)")
		}
	}
	return nil
}

// validatePatchSchedule · F08 §3.2.2 · PatchJob 改 schedule_cron / timezone 时复算 next_run_at + 复查频率下限.
//
// 行为:
//   - req.ScheduleCron 非空 → 用 req.ScheduleCron + tz 调 parseCron (含 R7 频率下限校验).
//   - 仅 req.Timezone 非 nil → 用 currentScheduleCron + 新 tz 复算 next_run_at + 复查频率 (tz 改可能踩频率边界).
//   - 显式启用/恢复 → 复查频率并从现在安排未来窗口，不补跑暂停期间的旧窗口。
//   - 都没改 → 返 (nil, nil), caller 不动 next_run_at.
//
// 错误码沿用 parseCron: cron.expression_invalid / cron.timezone_invalid / cron.frequency_below_min.
//
// 抽出便于单测; impl 持有 s.parseCron 的访问.
func (s *impl) validatePatchSchedule(req PatchJobReq, currentScheduleCron, effectiveTZ string) (*time.Time, error) {
	if req.ScheduleCron != nil && strings.TrimSpace(*req.ScheduleCron) != "" {
		sched, loc, err := s.parseCron(*req.ScheduleCron, effectiveTZ)
		if err != nil {
			return nil, err
		}
		n := sched.Next(time.Now().In(loc))
		return &n, nil
	}
	if req.Timezone != nil || (req.Enabled != nil && *req.Enabled) {
		// 恢复时也重算未来窗口；仅改 tz 也需要重算 + 复查 (新 tz 下原 schedule 可能踩频率边界).
		sched, loc, err := s.parseCron(currentScheduleCron, effectiveTZ)
		if err != nil {
			return nil, err
		}
		n := sched.Next(time.Now().In(loc))
		return &n, nil
	}
	return nil, nil
}

// resolveJobTimezone · F08 R11 · 三层 fallback: job 显式传 → tenant 默认 → cfg 全局默认.
// 用在 CreateJob 入库前; PatchJob 已存的 job.Timezone 直接读, 不走此函数.
//
// 关键 invariant: 落库的 agent_cron_jobs.timezone 永远是 effective tz (非空 IANA name),
// 这样运行时 (parseCron / executor) 不需要再 fallback, 避免现网租户改默认 tz 导致老 cron 漂移.
func (s *impl) resolveJobTimezone(ctx context.Context, jobTZ string, tenantID int64) string {
	if v := strings.TrimSpace(jobTZ); v != "" {
		return v
	}
	if s.tenants != nil {
		if tz, err := s.tenants.GetTimezone(ctx, tenantID); err == nil {
			if v := strings.TrimSpace(tz); v != "" {
				return v
			}
		}
		// GetTimezone 失败: 不阻塞 cron 创建, 退到 cfg 默认.
	}
	return s.cfg.DefaultTimezone
}

// =====================================================
// DTOs
// =====================================================

// AdminTenantCronJobDetailDTO F25 返修：租户 admin 任务详情 = 任务字段 + 最近运行记录（净化）。
type AdminTenantCronJobDetailDTO struct {
	Job  JobDTO               `json:"job"`
	Runs []PlatformCronRunDTO `json:"runs"`
}

type JobDTO struct {
	UUID                string         `json:"uuid"`
	Name                string         `json:"name"`
	Description         string         `json:"description,omitempty"`
	AgentUUID           string         `json:"agent_uuid"`
	ScheduleCron        string         `json:"schedule_cron"`
	Timezone            string         `json:"timezone"`
	Payload             map[string]any `json:"payload,omitempty"`
	Delivery            map[string]any `json:"delivery"`
	Enabled             bool           `json:"enabled"`
	Status              string         `json:"status"`
	SchedulerKind       string         `json:"scheduler_kind"`
	ConsecutiveFailures int            `json:"consecutive_failures"`
	FailureThreshold    int            `json:"failure_threshold"`
	LastRunAt           *time.Time     `json:"last_run_at,omitempty"`
	LastRunStatus       string         `json:"last_run_status,omitempty"`
	LastRunSummary      string         `json:"last_run_summary,omitempty"`
	NextRunAt           *time.Time     `json:"next_run_at,omitempty"`
	AdminDisabled       bool           `json:"admin_disabled"`
	// RunOnce · 客户端"单次执行"变通实现回显 (metadata.run_once); 编辑已有任务时前端据此
	// 判断是否回显"单次执行"档位。见 domain/cron.CreateJobInput.RunOnce 注释。
	RunOnce   bool      `json:"run_once,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	// L 增量 · F08 §5.1 admin 列表必须的字段:
	//   - OwnerAccountID: cron 拥有者 account id; admin 列表"owner"列.
	//   - PauseReason: 'admin_disabled' | 'owner_inactive' | 'quota_exceeded' | 'user_paused' | '';
	//     run-time 自动停时表明原因, admin 用来过滤 + 决策 (清强停标 / 移交).
	//   - DeliveryKind: 'direct' | 'group' | '' (老行 backfill 'direct'); admin 视图区分单聊/群聊.
	//   - OwnerInactiveAt: pause_reason='owner_inactive' 时填; admin 排序"最久未恢复"用.
	OwnerAccountID  int64      `json:"owner_account_id"`
	PauseReason     string     `json:"pause_reason,omitempty"`
	DeliveryKind    string     `json:"delivery_kind,omitempty"`
	OwnerInactiveAt *time.Time `json:"owner_inactive_at,omitempty"`
	// admin 列表显示名 (2026-06-12): 运营看名字不看 id/uuid; 批查回填, 查不到留空由前端回退.
	OwnerDisplayName string `json:"owner_display_name,omitempty"`
	AgentName        string `json:"agent_name,omitempty"`
}

type RunDTO struct {
	UUID             string     `json:"uuid"`
	JobUUID          string     `json:"job_uuid"`
	Status           string     `json:"status"`
	TriggerKind      string     `json:"trigger_kind"`
	ConversationUUID string     `json:"conversation_uuid,omitempty"`
	MessageUUID      string     `json:"message_uuid,omitempty"`
	StartedAt        time.Time  `json:"started_at"`
	FinishedAt       *time.Time `json:"finished_at,omitempty"`
	DurationMs       int64      `json:"duration_ms,omitempty"`
	Summary          string     `json:"summary,omitempty"`
	ErrorMessage     string     `json:"error_message,omitempty"`
	// F08 §3.2.4 / R9: 触发时渲染后的 prompt 全文; 仅 owner 可见 (admin 路径不暴露 RunDTO).
	RenderedPromptSnapshot string `json:"rendered_prompt_snapshot,omitempty"`
}

type CreateJobReq struct {
	Name         string `json:"name"`
	Description  string `json:"description,omitempty"`
	AgentUUID    string `json:"agent_uuid"`
	ScheduleCron string `json:"schedule_cron"`
	Timezone     string `json:"timezone,omitempty"`
	// 触发载荷: legacy 裸 prompt 与 R9 模板互斥 (同时给二者 → cron.prompt_template_payload_conflict).
	Prompt                  string         `json:"prompt,omitempty"`
	PromptTemplateUUID      string         `json:"prompt_template_uuid,omitempty"`
	PromptTemplateVariables map[string]any `json:"prompt_template_variables,omitempty"`
	// DeliveryKind 仅在 ConversationUUID 为空时生效；当前只接受 direct，
	// 由 Bus 按需 ensure canonical direct conversation。已有会话仍走原 UUID 契约。
	DeliveryKind     string `json:"delivery_kind,omitempty"`
	ConversationUUID string `json:"conversation_uuid,omitempty"`
	// RunOnce · 客户端"单次执行"(选日期时间) 变通实现; 见 domain/cron.CreateJobInput.RunOnce 注释。
	RunOnce bool `json:"run_once,omitempty"`
}

type PatchJobReq struct {
	Name         *string `json:"name,omitempty"`
	Description  *string `json:"description,omitempty"`
	ScheduleCron *string `json:"schedule_cron,omitempty"`
	Timezone     *string `json:"timezone,omitempty"`
	Prompt       *string `json:"prompt,omitempty"`
	// R9 模板修改; UUID 空串视作 "清掉模板退回老 prompt 路径"; non-nil 视作 "切到模板".
	PromptTemplateUUID      *string        `json:"prompt_template_uuid,omitempty"`
	PromptTemplateVariables map[string]any `json:"prompt_template_variables,omitempty"`
	DeliveryKind            *string        `json:"delivery_kind,omitempty"`
	ConversationUUID        *string        `json:"conversation_uuid,omitempty"`
	Enabled                 *bool          `json:"enabled,omitempty"`
	// RunOnce · 编辑表单必须显式传 true/false（不能省略）：省略在 CreateJob 语义下代表
	// "不是单次执行"没问题，但在 PATCH 场景省略会被当成"不改"，导致把任务从"单次执行"
	// 切回"固定频率/Cron"保存后旧 metadata.run_once 标记没清掉。见 domain/cron.PatchJobInput.SetRunOnce。
	RunOnce *bool `json:"run_once,omitempty"`
}

type OpenChatResp struct {
	ConversationUUID string `json:"conversation_uuid"`
	MessageUUID      string `json:"message_uuid,omitempty"`
}

// PromptTemplateDTO · G3 / F08 §3.1.1 R9 client 模板列表 DTO.
//
// 列表场景**不**返回 template_body, 避免跨租户/客户端泄露完整 prompt 正文; 详情接口
// (PromptTemplateDetailDTO) 才返回 body + 变量 schema, 但仍在可见性闸口内.
type PromptTemplateDTO struct {
	UUID       string `json:"uuid"`
	ScopeKind  string `json:"scope_kind"` // "platform" | "tenant"
	Code       string `json:"code"`
	Name       string `json:"name"`
	IsSystem   bool   `json:"is_system"`
	Status     string `json:"status"`
	IsReadonly bool   `json:"is_readonly"` // platform 模板对租户来说只读, 列表也标出
}

// PromptTemplateVariableDTO · G3 · 变量 schema (UI 表单生成用).
type PromptTemplateVariableDTO struct {
	VarName      string `json:"var_name"`
	VarType      string `json:"var_type"`
	Required     bool   `json:"required"`
	DefaultValue any    `json:"default_value,omitempty"`
	Options      []any  `json:"options,omitempty"`
	DisplayName  string `json:"display_name,omitempty"`
	OrderIndex   int    `json:"order_index"`
}

// PromptTemplateDetailDTO · G3 · 模板详情 + 变量 schema (variables 接口返回).
//
// J 返修: 加 Description; client `GetVisiblePromptTemplateVariables` 与 admin
// `AdminGetTenantPromptTemplate` 共享本 DTO, 二者都填 description (admin 编辑
// drawer 需要回填; client 只读侧 omitempty 不暴露空串).
type PromptTemplateDetailDTO struct {
	UUID         string                      `json:"uuid"`
	ScopeKind    string                      `json:"scope_kind"`
	Code         string                      `json:"code"`
	Name         string                      `json:"name"`
	Description  string                      `json:"description,omitempty"`
	TemplateBody string                      `json:"template_body"`
	IsSystem     bool                        `json:"is_system"`
	Status       string                      `json:"status"`
	IsReadonly   bool                        `json:"is_readonly"`
	Variables    []PromptTemplateVariableDTO `json:"variables"`
}

// PromptTemplateAdminDTO · G4 · admin 视角 list DTO (含 draft + 引用计数提示).
//
// K 增量:
//   - ActiveJobCount: 本租户 active cron 引用本模板的数量, 列表展示 + 删除前提示.
//     语义见 repo CountActiveJobsByTemplateIDs (deleted_at IS NULL, 按 caller tenant).
//   - UpdatedAt: 模板最近一次更新时间, 列表展示"上次更新".
type PromptTemplateAdminDTO struct {
	UUID           string    `json:"uuid"`
	ScopeKind      string    `json:"scope_kind"`
	Code           string    `json:"code"`
	Name           string    `json:"name"`
	IsSystem       bool      `json:"is_system"`
	Status         string    `json:"status"`
	IsReadonly     bool      `json:"is_readonly"`
	ActiveJobCount int       `json:"active_job_count"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// CreatePromptTemplateReq · G4 · admin 建租户模板请求体.
type CreatePromptTemplateReq struct {
	Code         string                      `json:"code"`
	Name         string                      `json:"name"`
	Description  string                      `json:"description,omitempty"`
	TemplateBody string                      `json:"template_body"`
	Status       string                      `json:"status,omitempty"` // 默认 active
	Variables    []PromptTemplateVariableDTO `json:"variables,omitempty"`
}

// PatchPromptTemplateReq · G4 · admin 改租户模板; nil 不改; Variables nil 不动, 非 nil 全替换.
type PatchPromptTemplateReq struct {
	Name         *string                      `json:"name,omitempty"`
	Description  *string                      `json:"description,omitempty"`
	TemplateBody *string                      `json:"template_body,omitempty"`
	Status       *string                      `json:"status,omitempty"`
	Variables    *[]PromptTemplateVariableDTO `json:"variables,omitempty"` // *slice → 区分"未传"和"清空"
}

// =====================================================
// validation helpers
// =====================================================

var cronParser = rcron.NewParser(rcron.Minute | rcron.Hour | rcron.Dom | rcron.Month | rcron.Dow)

// parseCron 校验 cron 表达式 + 频率下限.
func (s *impl) parseCron(expr, tz string) (rcron.Schedule, *time.Location, error) {
	loc, err := time.LoadLocation(tz)
	if err != nil {
		return nil, nil, apperr.New(apperr.InvalidParams, ErrCodeCronTimezoneInvalid).
			Withf("timezone %q invalid: %v", tz, err)
	}
	sched, err := cronParser.Parse(expr)
	if err != nil {
		return nil, nil, apperr.New(apperr.InvalidParams, ErrCodeCronExprInvalid).
			Withf("cron %q invalid: %v", expr, err)
	}
	// 频率下限: 取最近 10 次间隔最小值.
	now := time.Now().In(loc)
	prev := sched.Next(now)
	if prev.IsZero() {
		return nil, nil, apperr.New(apperr.InvalidParams, ErrCodeCronExprInvalid).Withf("schedule has no future occurrence")
	}
	for i := 0; i < 10; i++ {
		next := sched.Next(prev)
		if d := next.Sub(prev); d > 0 && d < s.cfg.MinFrequency {
			return nil, nil, apperr.New(apperr.InvalidParams, ErrCodeCronFrequencyBelowMin).
				Withf("frequency %s < min %s", d, s.cfg.MinFrequency)
		}
		prev = next
	}
	return sched, loc, nil
}

// resolveDelivery 校验 conversation ownership + agent 归属; 返回 conversation (强引用).
//
// 路径 (F08 §1.3 / §4.3 概念表对齐):
//   - legacy direct (conv.RoomID == nil): caller 必须是 conv.AccountID + 跨 agent 归属校验 (Codex P1#2).
//   - WuKong direct (conv.RoomID != nil + rooms.room_kind='direct'): caller-owns-conversation 已在
//     conv.TenantID/AccountID 校验里覆盖; 不走 R8.
//   - group (conv.RoomID != nil + rooms.room_kind='group'): 走 R8 双向校验
//     (caller human 在群 + 数字员工 agent 在群); 失败返语义错误码 group_member_not_in / agent_not_in_group.
//
// Codex P1#2: legacy direct 必须传 expectedAgentID; conv.digital_employee_id 与之不匹配时拒,
// 防止"拿 Agent A 的 conversation 给 Agent B 创建/触发 cron"导致跨 agent 串台.
//
// Rooms lookup 未注入 → 退回 v0.4 之前的硬拒语义 (cron.group_delivery_not_supported),
// 保持向后兼容; 生产 cmd/bus 装配应必填.
// resolveDelivery · F08 §1.3 / §4.3 · 校验 conversation ownership + agent 归属 + R8 群成员.
//
// 返回 (conv, deliveryKind, err):
//   - deliveryKind ∈ {"direct", "group"}; 落 agent_cron_jobs.delivery_kind NOT NULL.
//   - legacy direct (conv.RoomID == nil) → "direct"
//   - WuKong direct room → "direct"
//   - group room → "group"
//   - 其余 room.kind → cron.delivery_strategy_unsupported
//
// 调用方:
//   - CreateJob / PatchJob (conversation_uuid 改) 用 deliveryKind 落库.
//   - dispatcher (touchJobNext / runJobNow) 不需要 deliveryKind, 直接 `_` 忽略.
func (s *impl) resolveRequestedDelivery(
	ctx context.Context,
	accountID, tenantID, expectedAgentID int64,
	agentUUID, conversationUUID, requestedKind string,
) (*domconv.Conversation, string, error) {
	convUUID := strings.TrimSpace(conversationUUID)
	if convUUID != "" {
		return s.resolveDelivery(ctx, accountID, tenantID, expectedAgentID,
			map[string]any{"conversation_uuid": convUUID})
	}

	if strings.TrimSpace(requestedKind) != DeliveryKindDirect {
		return nil, "", apperr.New(apperr.InvalidParams, ErrCodeCronDeliveryStrategyUnsup).
			Withf("conversation_uuid required unless delivery_kind=direct")
	}
	if s.directConvs == nil {
		return nil, "", apperr.New(apperr.UpstreamUnavailable, ErrCodeCronDirectDeliveryUnavailable).
			Withf("direct conversation ensure not wired")
	}
	ensuredUUID, err := s.directConvs.EnsureDirectConversation(
		ctx, tenantID, accountID, expectedAgentID, strings.TrimSpace(agentUUID),
	)
	if err != nil {
		// 可见性/权限类业务错误保持原语义；WuKong/room ensure 失败统一收口为
		// 可重试的 direct_delivery_unavailable，避免把底层实现细节泄漏给客户端。
		if e, ok := apperr.AsError(err); ok &&
			(e.Code == apperr.Forbidden || e.Code == apperr.NotFound) {
			return nil, "", e
		}
		return nil, "", apperr.New(apperr.UpstreamUnavailable, ErrCodeCronDirectDeliveryUnavailable).Wrap(err)
	}
	ensuredUUID = strings.TrimSpace(ensuredUUID)
	if ensuredUUID == "" {
		return nil, "", apperr.New(apperr.UpstreamUnavailable, ErrCodeCronDirectDeliveryUnavailable).
			Withf("direct conversation ensure returned empty uuid")
	}
	// ensure 的输出仍走统一 resolveDelivery，不能绕过 tenant/account/agent 归属校验。
	return s.resolveDelivery(ctx, accountID, tenantID, expectedAgentID,
		map[string]any{"conversation_uuid": ensuredUUID})
}

func (s *impl) resolveDelivery(ctx context.Context, accountID, tenantID, expectedAgentID int64, delivery map[string]any) (*domconv.Conversation, string, error) {
	convUUID, _ := delivery["conversation_uuid"].(string)
	if strings.TrimSpace(convUUID) == "" {
		return nil, "", apperr.New(apperr.InvalidParams, ErrCodeCronDeliveryStrategyUnsup).
			Withf("Phase A 仅支持 delivery.conversation_uuid; 其他策略未实现")
	}
	conv, err := s.convs.GetByUUID(ctx, convUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, "", apperr.New(apperr.NotFound, ErrCodeCronDeliveryConvNotFound).
				Withf("conversation %s not found", convUUID)
		}
		return nil, "", apperr.ErrInternal.Wrap(err)
	}
	if conv.TenantID != tenantID || conv.AccountID != accountID {
		// 不暴露存在性, 统一返 not_found.
		return nil, "", apperr.New(apperr.NotFound, ErrCodeCronDeliveryConvNotFound).
			Withf("conversation %s not found", convUUID)
	}
	if conv.RoomID == nil {
		// legacy direct (conversations.digital_employee_id 必填); 走 Codex P1#2 agent 归属校验.
		if expectedAgentID > 0 {
			if conv.DigitalEmployeeID == nil || *conv.DigitalEmployeeID != expectedAgentID {
				return nil, "", apperr.New(apperr.NotFound, ErrCodeCronDeliveryConvNotFound).
					Withf("conversation %s not bound to agent %d", convUUID, expectedAgentID)
			}
		}
		return conv, DeliveryKindDirect, nil
	}
	// conv.RoomID != nil → 走 room.kind 分支.
	if s.rooms == nil {
		// Rooms 未装配: 退回 v0.4 前的硬拒语义.
		return nil, "", apperr.New(apperr.InvalidParams, ErrCodeCronGroupDeliveryUnsupported).
			Withf("rooms lookup not wired; group/room conversation delivery disabled")
	}
	room, err := s.rooms.GetByID(ctx, *conv.RoomID)
	if err != nil {
		return nil, "", apperr.New(apperr.NotFound, ErrCodeCronDeliveryConvNotFound).
			Withf("room id=%d not found", *conv.RoomID)
	}
	switch room.RoomKind {
	case domroom.KindDirect:
		// WuKong 人↔Agent direct: 不暴露群成员错误码 (避免泄露 room agent 归属),
		// 但仍需查 room_participants: caller human + expectedAgentID agent 都必须 active.
		// 任一缺失统一返 cron.delivery_conversation_not_found.
		if expectedAgentID > 0 {
			if err := s.assertDirectRoomBinding(ctx, room, accountID, expectedAgentID, convUUID); err != nil {
				return nil, "", err
			}
		}
		return conv, DeliveryKindDirect, nil
	case domroom.KindGroup:
		// R8: 双向群成员校验 (会暴露 group_member_not_in / agent_not_in_group 语义错误码).
		if expectedAgentID > 0 {
			if err := s.assertGroupMembership(ctx, room, accountID, expectedAgentID); err != nil {
				return nil, "", err
			}
		}
		return conv, DeliveryKindGroup, nil
	default:
		return nil, "", apperr.New(apperr.InvalidParams, ErrCodeCronDeliveryStrategyUnsup).
			Withf("unsupported room.kind %q", room.RoomKind)
	}
}

// DeliveryKind 枚举值 (agent_cron_jobs.delivery_kind CHECK direct/group).
const (
	DeliveryKindDirect = "direct"
	DeliveryKindGroup  = "group"
)

// assertDirectRoomBinding · F08 §1.3 / E3 · WuKong 人↔Agent direct room 的窄校验.
//
// 与 group R8 不同点:
//   - 失败统一返 cron.delivery_conversation_not_found, 不区分"caller 不在"vs"agent 不在",
//     避免对 caller 泄露其他 agent 在不在这个 direct room.
//   - 仍然查 room_participants active 行 (避免拿别人的 direct room 给自己的 agent 串 cron).
func (s *impl) assertDirectRoomBinding(ctx context.Context, room *domroom.Room, callerAccountID, agentID int64, convUUID string) error {
	parts, err := s.rooms.ListParticipants(ctx, room.ID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	humanIn, agentIn := false, false
	for i := range parts {
		p := &parts[i]
		if p.LeftAt != nil {
			continue
		}
		if p.Kind == domroom.ParticipantHuman && p.AccountID != nil && *p.AccountID == callerAccountID {
			humanIn = true
		}
		if p.Kind == domroom.ParticipantAgent && p.AgentID != nil && *p.AgentID == agentID {
			agentIn = true
		}
	}
	if !humanIn || !agentIn {
		return apperr.New(apperr.NotFound, ErrCodeCronDeliveryConvNotFound).
			Withf("conversation %s not bound to caller/agent in direct room", convUUID)
	}
	return nil
}

// assertGroupMembership · F08 §8.2 #2 / R8 · 创建 / 触发 cron 投群聊时的双向成员校验.
//
// 现态: room_participants 没有按 (room, kind, account/agent) 唯一查询的窄方法;
// 走 ListParticipants 一次扫整个房间 (active only) 然后扫描两个目标.
// 房间成员上限 50 (domroom.MaxParticipants), 扫描成本可忽略.
func (s *impl) assertGroupMembership(ctx context.Context, room *domroom.Room, callerAccountID, agentID int64) error {
	parts, err := s.rooms.ListParticipants(ctx, room.ID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	humanIn, agentIn := false, false
	for i := range parts {
		p := &parts[i]
		if p.LeftAt != nil {
			continue
		}
		if p.Kind == domroom.ParticipantHuman && p.AccountID != nil && *p.AccountID == callerAccountID {
			humanIn = true
		}
		if p.Kind == domroom.ParticipantAgent && p.AgentID != nil && *p.AgentID == agentID {
			agentIn = true
		}
	}
	if !humanIn {
		return apperr.New(apperr.Forbidden, ErrCodeCronGroupMemberNotIn).
			Withf("caller account %d not in room %d", callerAccountID, room.ID)
	}
	if !agentIn {
		return apperr.New(apperr.Forbidden, ErrCodeCronAgentNotInGroup).
			Withf("agent %d not in room %d", agentID, room.ID)
	}
	return nil
}

// assertAgentVisible Codex P1#1: 走 contacts 可见性收口.
//
// nil visibility → fail-closed (生产配置错误必须立刻暴露; 不要"宽容跳过").
// 失败统一返 cron.agent_not_visible (不区分原因, 与 contacts 错误保留细节但 cron 层抹平).
func (s *impl) assertAgentVisible(ctx context.Context, accountID, tenantID int64, agentUUID string) error {
	if s.visibility == nil {
		return apperr.New(apperr.Forbidden, ErrCodeCronVisibilityNotWired).
			Withf("contacts visibility not wired; cron entry fail-closed")
	}
	if err := s.visibility.AssertAgentVisible(ctx, accountID, tenantID, agentUUID); err != nil {
		return apperr.New(apperr.Forbidden, ErrCodeCronAgentNotVisible).
			Withf("agent %s not visible: %v", agentUUID, err)
	}
	return nil
}

// ---- G4 / F08 §5.2 admin tenant prompt-template CRUD ----

// validateCreatePromptTemplateReq · G4 · 入参语义校验; 纯函数, 便于单测.
func validateCreatePromptTemplateReq(req CreatePromptTemplateReq) error {
	if strings.TrimSpace(req.Code) == "" {
		return apperr.ErrInvalidParams.Withf("code required")
	}
	if strings.TrimSpace(req.Name) == "" {
		return apperr.ErrInvalidParams.Withf("name required")
	}
	if strings.TrimSpace(req.TemplateBody) == "" {
		return apperr.ErrInvalidParams.Withf("template_body required")
	}
	status := strings.TrimSpace(req.Status)
	if status != "" && status != domcron.TemplateStatusDraft &&
		status != domcron.TemplateStatusActive && status != domcron.TemplateStatusArchived {
		return apperr.ErrInvalidParams.Withf("status invalid")
	}
	if err := validatePromptTemplateVarDefs(req.Variables); err != nil {
		return err
	}
	return nil
}

// validatePromptTemplateVarDefs · 检查变量 schema (var_name + var_type 必填).
func validatePromptTemplateVarDefs(vars []PromptTemplateVariableDTO) error {
	seen := map[string]bool{}
	for i := range vars {
		v := &vars[i]
		if strings.TrimSpace(v.VarName) == "" {
			return apperr.ErrInvalidParams.Withf("variables[%d].var_name required", i)
		}
		if seen[v.VarName] {
			return apperr.ErrInvalidParams.Withf("variables[%d].var_name duplicated: %q", i, v.VarName)
		}
		seen[v.VarName] = true
		switch v.VarType {
		case domcron.VarTypeString, domcron.VarTypeEnum, domcron.VarTypeInt,
			domcron.VarTypeDateTime, domcron.VarTypeList:
		default:
			return apperr.ErrInvalidParams.Withf("variables[%d].var_type invalid: %q", i, v.VarType)
		}
	}
	return nil
}

// toDomainTemplateVariables · DTO → domain (用于 CreatePromptTemplateInput / PatchPromptTemplateInput.Variables).
func toDomainTemplateVariables(vars []PromptTemplateVariableDTO) []domcron.PromptTemplateVariable {
	out := make([]domcron.PromptTemplateVariable, 0, len(vars))
	for i := range vars {
		v := &vars[i]
		out = append(out, domcron.PromptTemplateVariable{
			VarName:      v.VarName,
			VarType:      v.VarType,
			Required:     v.Required,
			DefaultValue: v.DefaultValue,
			Options:      v.Options,
			DisplayName:  v.DisplayName,
			OrderIndex:   v.OrderIndex,
		})
	}
	return out
}

// AdminListTenantPromptTemplates · G4 + K · admin 视角 list.
//
// K 增量: 给每行带:
//   - ActiveJobCount: 本租户 active cron 引用本模板数, 单条 SQL 批量获取 (避免 N+1).
//   - UpdatedAt: 模板最近一次更新时间.
//
// active 计数失败不阻塞列表返回 (best-effort): 列表本身已经成功就先返回, count map
// 用空 map 兜底, 每行落 ActiveJobCount=0; 日志 warn. 这避免 cron_jobs 子表抖动时
// admin 完全打不开模板管理页.
func (s *impl) AdminListTenantPromptTemplates(ctx context.Context, tenantID int64) ([]PromptTemplateAdminDTO, error) {
	if s.templates == nil {
		return []PromptTemplateAdminDTO{}, nil
	}
	rows, err := s.templates.ListAdminTenantPromptTemplates(ctx, tenantID, 200)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 批量取本租户 active cron 引用数; 失败不阻塞.
	ids := make([]int64, 0, len(rows))
	for i := range rows {
		ids = append(ids, rows[i].ID)
	}
	counts := map[int64]int{}
	if len(ids) > 0 {
		got, cerr := s.templates.CountActiveJobsByTemplateIDs(ctx, tenantID, ids)
		if cerr != nil {
			// best-effort: count 查 DB 抖动不阻塞列表; 落 warn 给运营追踪.
			// nil 守护: 部分单测 helper 不注入 logger, 不要因日志缺失 panic.
			if s.logger != nil {
				s.logger.Warn(ctx, "cron: admin list template count failed; falling back to 0",
					"tenant_id", tenantID, "err", cerr)
			}
		} else {
			counts = got
		}
	}
	out := make([]PromptTemplateAdminDTO, 0, len(rows))
	for i := range rows {
		t := &rows[i]
		out = append(out, PromptTemplateAdminDTO{
			UUID:           t.UUID,
			ScopeKind:      t.ScopeKind,
			Code:           t.Code,
			Name:           t.Name,
			IsSystem:       t.IsSystem,
			Status:         t.Status,
			IsReadonly:     isTemplateReadonlyForTenant(t, tenantID),
			ActiveJobCount: counts[t.ID], // 不存在的 key map 返回 0, 与"无引用"语义一致
			UpdatedAt:      t.UpdatedAt,
		})
	}
	return out, nil
}

// AdminGetTenantPromptTemplate · I 增量 · admin scope 模板详情 (含 body + variables).
//
// admin-web 编辑 drawer 需要在打开时拉 body + variables; list DTO 没有这两个字段.
// 走 admin resolver: 本租户 draft/active/archived 全可见; platform 只 active 可读;
// 跨租户 / 软删 / 不存在 → cron.prompt_template_not_found.
//
// 与 client `GetVisiblePromptTemplateVariables` 严格区分: 后者是 active-only,
// 用在 client API; 不要让 admin 路径误复用.
func (s *impl) AdminGetTenantPromptTemplate(ctx context.Context, tenantID int64, tplUUID string) (*PromptTemplateDetailDTO, error) {
	tpl, vars, err := s.resolveAdminTenantPromptTemplate(ctx, tenantID, tplUUID)
	if err != nil {
		return nil, err
	}
	return adminTemplateDetailDTO(tpl, vars, tenantID), nil
}

// AdminCreateTenantPromptTemplate · G4 · 建租户模板 (scope=tenant 强制).
//
// 规则:
//   - tenant_id 从 session 取, 不信任 body.
//   - (scope=tenant, tenant_id, code) 唯一: 冲突 → cron.prompt_template_code_conflict.
//   - 默认 status='active'; admin 也允许显式 draft / archived (本租户管控范围).
//
// H 返修: create 成功后直接走 admin detail DTO builder, 不再借道 client visible resolver,
// 否则 draft/archived 的初始状态会被 client active-only 闸口拒回 not_found.
func (s *impl) AdminCreateTenantPromptTemplate(ctx context.Context, tenantID, actorID int64, req CreatePromptTemplateReq) (*PromptTemplateDetailDTO, error) {
	if err := validateCreatePromptTemplateReq(req); err != nil {
		return nil, err
	}
	in := domcron.CreatePromptTemplateInput{
		TenantID:     tenantID,
		Code:         strings.TrimSpace(req.Code),
		Name:         strings.TrimSpace(req.Name),
		Description:  strings.TrimSpace(req.Description),
		TemplateBody: req.TemplateBody,
		Status:       strings.TrimSpace(req.Status),
		Variables:    toDomainTemplateVariables(req.Variables),
		CreatedBy:    actorID,
	}
	var created *domcron.PromptTemplate
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		t, err := s.repo.CreateTenantPromptTemplate(ctx, tx, in)
		if err != nil {
			if isUniqueViolation(err) {
				return apperr.New(apperr.Conflict, ErrCodeCronTemplateCodeConflict).
					Withf("template code %q already exists in tenant", in.Code)
			}
			return err
		}
		created = t
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return nil, e
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 直接用 admin resolver 拉刚 insert 的 row + 变量, 走 admin-scope DTO builder.
	// 注意: 这里不能复用 client `s.GetVisiblePromptTemplateVariables`, 因为它对
	// 非 active 模板会一律返 not_found, 把 caller 误导成 "create 失败".
	tpl, vars, err := s.resolveAdminTenantPromptTemplate(ctx, tenantID, created.UUID)
	if err != nil {
		return nil, err
	}
	return adminTemplateDetailDTO(tpl, vars, tenantID), nil
}

// AdminPatchTenantPromptTemplate · G4 · 改租户模板; platform / is_system 拒绝.
//
// H 返修: 走 admin resolver, 允许 draft/active/archived 任一状态的本租户模板被 patch;
// 返回详情也走 admin DTO builder, 避免 active→archived 之后 client resolver 把响应抹成 not_found.
func (s *impl) AdminPatchTenantPromptTemplate(ctx context.Context, tenantID, actorID int64, tplUUID string, req PatchPromptTemplateReq) (*PromptTemplateDetailDTO, error) {
	tpl, _, err := s.resolveAdminTenantPromptTemplate(ctx, tenantID, tplUUID)
	if err != nil {
		return nil, err
	}
	if isTemplateReadonlyForTenant(tpl, tenantID) {
		return nil, apperr.New(apperr.Forbidden, ErrCodeCronTemplateReadonly).
			Withf("template %s is readonly (platform/is_system)", tplUUID)
	}

	if req.Variables != nil {
		if err := validatePromptTemplateVarDefs(*req.Variables); err != nil {
			return nil, err
		}
	}
	if req.Status != nil {
		st := strings.TrimSpace(*req.Status)
		if st != domcron.TemplateStatusDraft && st != domcron.TemplateStatusActive &&
			st != domcron.TemplateStatusArchived {
			return nil, apperr.ErrInvalidParams.Withf("status invalid")
		}
	}

	in := domcron.PatchPromptTemplateInput{
		Name:         req.Name,
		Description:  req.Description,
		TemplateBody: req.TemplateBody,
		Status:       req.Status,
		UpdatedBy:    actorID,
	}
	if req.Variables != nil {
		in.ReplaceVars = true
		in.Variables = toDomainTemplateVariables(*req.Variables)
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		return s.repo.PatchAdminPromptTemplate(ctx, tx, tpl.ID, in)
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 重新 resolve 拿到最新 row + 变量 (status / body / 变量可能都改了).
	updated, vars, err := s.resolveAdminTenantPromptTemplate(ctx, tenantID, tplUUID)
	if err != nil {
		return nil, err
	}
	return adminTemplateDetailDTO(updated, vars, tenantID), nil
}

// AdminDeleteTenantPromptTemplate · G4 · 删租户模板; platform / is_system / 被引用拒.
//
// H 返修: 走 admin resolver, 允许 draft/archived 状态的本租户模板被删除
// (前提仍是非 is_system、非 platform、未被 active cron 引用).
func (s *impl) AdminDeleteTenantPromptTemplate(ctx context.Context, tenantID, actorID int64, tplUUID string) error {
	_ = actorID // 当前不在 audit 上独立用 actor; 留作未来扩展
	tpl, _, err := s.resolveAdminTenantPromptTemplate(ctx, tenantID, tplUUID)
	if err != nil {
		return err
	}
	if isTemplateReadonlyForTenant(tpl, tenantID) {
		return apperr.New(apperr.Forbidden, ErrCodeCronTemplateReadonly).
			Withf("template %s is readonly", tplUUID)
	}
	if s.templates != nil {
		n, err := s.templates.CountActiveJobsUsingTemplate(ctx, tpl.ID)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if n > 0 {
			return apperr.New(apperr.Conflict, ErrCodeCronTemplateInUse).
				Withf("template %s still referenced by %d active cron(s)", tplUUID, n)
		}
	}
	return s.runTx(ctx, func(tx pgx.Tx) error {
		return s.repo.SoftDeletePromptTemplate(ctx, tx, tpl.ID)
	})
}

// resolveAdminPlatformPromptTemplate · 平台控制台 resolver: 仅 scope='platform',
// 任意 status (draft/active/archived) 可见。tenant 模板对平台控制台不可见——
// 平台不代管租户私有模板, 避免越权面。
func (s *impl) resolveAdminPlatformPromptTemplate(ctx context.Context, tplUUID string) (*domcron.PromptTemplate, []domcron.PromptTemplateVariable, error) {
	tplUUID = strings.TrimSpace(tplUUID)
	if tplUUID == "" || s.templates == nil {
		return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("template uuid empty or lookup not wired")
	}
	tpl, err := s.templates.GetPromptTemplateByUUID(ctx, tplUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
				Withf("template %s not found", tplUUID)
		}
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	if tpl.ScopeKind != domcron.TemplateScopePlatform {
		return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("template %s not visible to platform console", tplUUID)
	}
	vars, err := s.templates.ListPromptTemplateVariables(ctx, tpl.ID)
	if err != nil {
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	return tpl, vars, nil
}

// platformTemplateDetailDTO · 平台控制台详情 DTO: 与 adminTemplateDetailDTO 同款字段,
// 但 is_readonly 只看 is_system (平台超管自建模板可改; 内置种子只读), 不按 tenant 视角算。
func platformTemplateDetailDTO(tpl *domcron.PromptTemplate, vars []domcron.PromptTemplateVariable) *PromptTemplateDetailDTO {
	out := adminTemplateDetailDTO(tpl, vars, 0)
	if out != nil {
		out.IsReadonly = tpl.IsSystem
	}
	return out
}

// AdminListPlatformPromptTemplates · 平台模板列表 (全状态)。
// 引用数为跨租户口径 (平台模板被所有租户的 active cron 引用都计入);
// 平台模板量级小 (LIMIT 200), 逐条 count 可接受, 失败不阻塞列表。
func (s *impl) AdminListPlatformPromptTemplates(ctx context.Context) ([]PromptTemplateAdminDTO, error) {
	if s.templates == nil {
		return []PromptTemplateAdminDTO{}, nil
	}
	rows, err := s.templates.ListAdminPlatformPromptTemplates(ctx, 200)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]PromptTemplateAdminDTO, 0, len(rows))
	for i := range rows {
		t := &rows[i]
		count := 0
		if n, cerr := s.templates.CountActiveJobsUsingTemplate(ctx, t.ID); cerr == nil {
			count = n
		} else if s.logger != nil {
			s.logger.Warn(ctx, "cron: platform template count failed; falling back to 0",
				"template_uuid", t.UUID, "err", cerr)
		}
		out = append(out, PromptTemplateAdminDTO{
			UUID:           t.UUID,
			ScopeKind:      t.ScopeKind,
			Code:           t.Code,
			Name:           t.Name,
			IsSystem:       t.IsSystem,
			Status:         t.Status,
			IsReadonly:     t.IsSystem,
			ActiveJobCount: count,
			UpdatedAt:      t.UpdatedAt,
		})
	}
	return out, nil
}

// AdminGetPlatformPromptTemplate · 平台模板详情 (含 body + variables, 全状态可读)。
func (s *impl) AdminGetPlatformPromptTemplate(ctx context.Context, tplUUID string) (*PromptTemplateDetailDTO, error) {
	tpl, vars, err := s.resolveAdminPlatformPromptTemplate(ctx, tplUUID)
	if err != nil {
		return nil, err
	}
	return platformTemplateDetailDTO(tpl, vars), nil
}

// AdminCreatePlatformPromptTemplate · 建平台模板 (scope=platform 强制, code 平台内唯一)。
func (s *impl) AdminCreatePlatformPromptTemplate(ctx context.Context, actorID int64, req CreatePromptTemplateReq) (*PromptTemplateDetailDTO, error) {
	if err := validateCreatePromptTemplateReq(req); err != nil {
		return nil, err
	}
	in := domcron.CreatePromptTemplateInput{
		Code:         strings.TrimSpace(req.Code),
		Name:         strings.TrimSpace(req.Name),
		Description:  strings.TrimSpace(req.Description),
		TemplateBody: req.TemplateBody,
		Status:       strings.TrimSpace(req.Status),
		Variables:    toDomainTemplateVariables(req.Variables),
		CreatedBy:    actorID,
	}
	var created *domcron.PromptTemplate
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		t, err := s.repo.CreatePlatformPromptTemplate(ctx, tx, in)
		if err != nil {
			if isUniqueViolation(err) {
				return apperr.New(apperr.Conflict, ErrCodeCronTemplateCodeConflict).
					Withf("template code %q already exists in platform scope", in.Code)
			}
			return err
		}
		created = t
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return nil, e
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	tpl, vars, err := s.resolveAdminPlatformPromptTemplate(ctx, created.UUID)
	if err != nil {
		return nil, err
	}
	return platformTemplateDetailDTO(tpl, vars), nil
}

// AdminPatchPlatformPromptTemplate · 改平台模板; is_system 内置种子拒改。
func (s *impl) AdminPatchPlatformPromptTemplate(ctx context.Context, actorID int64, tplUUID string, req PatchPromptTemplateReq) (*PromptTemplateDetailDTO, error) {
	tpl, _, err := s.resolveAdminPlatformPromptTemplate(ctx, tplUUID)
	if err != nil {
		return nil, err
	}
	if tpl.IsSystem {
		return nil, apperr.New(apperr.Forbidden, ErrCodeCronTemplateReadonly).
			Withf("template %s is readonly (is_system)", tplUUID)
	}
	if req.Variables != nil {
		if err := validatePromptTemplateVarDefs(*req.Variables); err != nil {
			return nil, err
		}
	}
	if req.Status != nil {
		st := strings.TrimSpace(*req.Status)
		if st != domcron.TemplateStatusDraft && st != domcron.TemplateStatusActive &&
			st != domcron.TemplateStatusArchived {
			return nil, apperr.ErrInvalidParams.Withf("status invalid")
		}
	}
	in := domcron.PatchPromptTemplateInput{
		Name:         req.Name,
		Description:  req.Description,
		TemplateBody: req.TemplateBody,
		Status:       req.Status,
		UpdatedBy:    actorID,
	}
	if req.Variables != nil {
		in.ReplaceVars = true
		in.Variables = toDomainTemplateVariables(*req.Variables)
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		return s.repo.PatchAdminPromptTemplate(ctx, tx, tpl.ID, in)
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	updated, vars, err := s.resolveAdminPlatformPromptTemplate(ctx, tplUUID)
	if err != nil {
		return nil, err
	}
	return platformTemplateDetailDTO(updated, vars), nil
}

// AdminDeletePlatformPromptTemplate · 删平台模板; is_system / 仍被任意租户 active cron 引用拒。
func (s *impl) AdminDeletePlatformPromptTemplate(ctx context.Context, actorID int64, tplUUID string) error {
	_ = actorID // 与租户路径一致: 暂不单独 audit actor, 留扩展
	tpl, _, err := s.resolveAdminPlatformPromptTemplate(ctx, tplUUID)
	if err != nil {
		return err
	}
	if tpl.IsSystem {
		return apperr.New(apperr.Forbidden, ErrCodeCronTemplateReadonly).
			Withf("template %s is readonly (is_system)", tplUUID)
	}
	if s.templates != nil {
		n, err := s.templates.CountActiveJobsUsingTemplate(ctx, tpl.ID)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if n > 0 {
			return apperr.New(apperr.Conflict, ErrCodeCronTemplateInUse).
				Withf("template %s still referenced by %d active cron(s)", tplUUID, n)
		}
	}
	return s.runTx(ctx, func(tx pgx.Tx) error {
		return s.repo.SoftDeletePromptTemplate(ctx, tx, tpl.ID)
	})
}

// adminTemplateDetailDTO · H 返修 · admin-scope 详情 DTO builder (纯函数).
//
// 与 client `GetVisiblePromptTemplateVariables` 不同: 本 builder **不**复检 status,
// 因此 draft / archived 模板也能返回完整 body + 变量, 让 admin 路径在 create/patch
// 后能拿到真实 detail. is_readonly 仍按 caller tenant 计算 (platform / is_system /
// 跨租户 → readonly).
func adminTemplateDetailDTO(tpl *domcron.PromptTemplate, vars []domcron.PromptTemplateVariable, callerTenantID int64) *PromptTemplateDetailDTO {
	if tpl == nil {
		return nil
	}
	varDTOs := make([]PromptTemplateVariableDTO, 0, len(vars))
	for i := range vars {
		v := &vars[i]
		varDTOs = append(varDTOs, PromptTemplateVariableDTO{
			VarName:      v.VarName,
			VarType:      v.VarType,
			Required:     v.Required,
			DefaultValue: v.DefaultValue,
			Options:      v.Options,
			DisplayName:  v.DisplayName,
			OrderIndex:   v.OrderIndex,
		})
	}
	return &PromptTemplateDetailDTO{
		UUID:         tpl.UUID,
		ScopeKind:    tpl.ScopeKind,
		Code:         tpl.Code,
		Name:         tpl.Name,
		Description:  tpl.Description,
		TemplateBody: tpl.TemplateBody,
		IsSystem:     tpl.IsSystem,
		Status:       tpl.Status,
		IsReadonly:   isTemplateReadonlyForTenant(tpl, callerTenantID),
		Variables:    varDTOs,
	}
}

// resolveAdminTenantPromptTemplate · H 返修 · admin-scope 模板查找.
//
// 与 client `resolvePromptTemplate` 的差异:
//   - tenant scope + tenant_id == caller: **任意 status** (draft/active/archived) 都 OK,
//     admin 需要管控本租户所有状态的模板.
//   - platform scope: 仍仅 active 可见 (admin 只能只读浏览 platform 模板; 不能跨 scope 改).
//   - 跨租户 / 软删 / 不存在: 统一 not_found, 不泄露存在性.
//   - 模板 lookup 未注入: not_found (生产装配应必填).
//
// 复用现有 PromptTemplateLookup 接口的 GetPromptTemplateByUUID + ListPromptTemplateVariables,
// 不需要新加 repo 方法 (repo 的 GetPromptTemplateByUUID 已经只按 is_deleted=false 过滤,
// 返回任意 status 的 row, 正是 admin-scope 需要的范围).
func (s *impl) resolveAdminTenantPromptTemplate(ctx context.Context, tenantID int64, tplUUID string) (*domcron.PromptTemplate, []domcron.PromptTemplateVariable, error) {
	tplUUID = strings.TrimSpace(tplUUID)
	if tplUUID == "" {
		return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("template uuid empty")
	}
	if s.templates == nil {
		return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("prompt template lookup not wired")
	}
	tpl, err := s.templates.GetPromptTemplateByUUID(ctx, tplUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
				Withf("template %s not found", tplUUID)
		}
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	switch tpl.ScopeKind {
	case domcron.TemplateScopePlatform:
		// admin 只读浏览 platform 模板; archived 不暴露 (与 client 一致), 上层 readonly 拦截 patch/delete.
		if tpl.Status != domcron.TemplateStatusActive {
			return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
				Withf("template %s not visible", tplUUID)
		}
	case domcron.TemplateScopeTenant:
		if tpl.TenantID == nil || *tpl.TenantID != tenantID {
			return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
				Withf("template %s not visible to tenant", tplUUID)
		}
		// admin 可见任意 status (draft/active/archived).
	default:
		return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("template %s scope %q unknown", tplUUID, tpl.ScopeKind)
	}
	vars, err := s.templates.ListPromptTemplateVariables(ctx, tpl.ID)
	if err != nil {
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	return tpl, vars, nil
}

// isUniqueViolation · 检测 PG 23505; 不依赖 pgx 直接 import, 用 error string 兜底.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "23505") || strings.Contains(msg, "unique_violation") ||
		strings.Contains(msg, "duplicate key")
}

// ListVisiblePromptTemplates · G3 / F08 §3.1.1 · 客户端可见模板列表.
//
// 直接走 PromptTemplateLookup.ListVisiblePromptTemplates (repo 内已加可见性 WHERE);
// service 在 DTO 层把 platform 模板对 caller 标 IsReadonly=true (caller 视角下不可编辑).
// 列表**不**返回 template_body.
func (s *impl) ListVisiblePromptTemplates(ctx context.Context, tenantID int64) ([]PromptTemplateDTO, error) {
	if s.templates == nil {
		// R9 路径关闭: 返回空列表 (非错误), 让客户端走 legacy prompt 路径.
		return []PromptTemplateDTO{}, nil
	}
	rows, err := s.templates.ListVisiblePromptTemplates(ctx, tenantID, 100)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]PromptTemplateDTO, 0, len(rows))
	for i := range rows {
		t := &rows[i]
		out = append(out, PromptTemplateDTO{
			UUID:       t.UUID,
			ScopeKind:  t.ScopeKind,
			Code:       t.Code,
			Name:       t.Name,
			IsSystem:   t.IsSystem,
			Status:     t.Status,
			IsReadonly: isTemplateReadonlyForTenant(t, tenantID),
		})
	}
	return out, nil
}

// GetVisiblePromptTemplateVariables · G3 / F08 §3.1.1 · 变量 schema 详情.
//
// 跨可见范围统一返 cron.prompt_template_not_found (与 R9 其他错误码一致, 不区分
// "不存在"/"跨租户"/"已 archived", 避免泄露存在性).
func (s *impl) GetVisiblePromptTemplateVariables(ctx context.Context, tenantID int64, tplUUID string) (*PromptTemplateDetailDTO, error) {
	tpl, vars, err := s.resolvePromptTemplate(ctx, tenantID, tplUUID)
	if err != nil {
		return nil, err
	}
	if tpl == nil {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("template %s not visible", tplUUID)
	}
	varDTOs := make([]PromptTemplateVariableDTO, 0, len(vars))
	for i := range vars {
		v := &vars[i]
		varDTOs = append(varDTOs, PromptTemplateVariableDTO{
			VarName:      v.VarName,
			VarType:      v.VarType,
			Required:     v.Required,
			DefaultValue: v.DefaultValue,
			Options:      v.Options,
			DisplayName:  v.DisplayName,
			OrderIndex:   v.OrderIndex,
		})
	}
	return &PromptTemplateDetailDTO{
		UUID:         tpl.UUID,
		ScopeKind:    tpl.ScopeKind,
		Code:         tpl.Code,
		Name:         tpl.Name,
		Description:  tpl.Description,
		TemplateBody: tpl.TemplateBody,
		IsSystem:     tpl.IsSystem,
		Status:       tpl.Status,
		IsReadonly:   isTemplateReadonlyForTenant(tpl, tenantID),
		Variables:    varDTOs,
	}, nil
}

// isTemplateReadonlyForTenant · 当 caller tenant 不是 owner 时模板只读.
// platform 模板对所有 tenant 只读; tenant 模板对本租户可改 (admin 路径), 对 client
// 只读由 client UI 决定 (这里只标 platform).
func isTemplateReadonlyForTenant(t *domcron.PromptTemplate, callerTenantID int64) bool {
	if t.ScopeKind == domcron.TemplateScopePlatform {
		return true
	}
	if t.TenantID == nil || *t.TenantID != callerTenantID {
		return true
	}
	if t.IsSystem {
		return true
	}
	return false
}

// resolveRuntimePrompt · F08 §8.2 #4 / R9 · executor 拿到要触发的 prompt 文本.
//
// 路径:
//   - job.PromptTemplateID 非 nil → 拉模板 + 变量定义 → renderPromptTemplate(body, vars, defs)
//   - 否则 → fallback 老 payload.prompt
//
// 注意: 触发时**不**复校变量是否仍合法 (CreateJob/PatchJob 已经把当时的变量值落库;
// 若模板后续改了 schema 或下架, render 仍走 default_value + 字面 "" 兜底; 由 §5.3
// 健康面板观察 / admin 决定是否手动 patch cron). 不让模板变更瞬间挂掉历史 cron.
func (s *impl) resolveRuntimePrompt(ctx context.Context, j *domcron.Job) (string, error) {
	if j.PromptTemplateID == nil {
		// 老 payload.prompt 路径.
		p, _ := j.Payload["prompt"].(string)
		return p, nil
	}
	if s.templates == nil {
		return "", apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("prompt template lookup not wired at runtime")
	}
	tpl, err := s.lookupTemplateByID(ctx, *j.PromptTemplateID)
	if err != nil {
		return "", err
	}
	if tpl == nil {
		return "", apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("template id=%d not found", *j.PromptTemplateID)
	}
	vars, err := s.templates.ListPromptTemplateVariables(ctx, tpl.ID)
	if err != nil {
		return "", apperr.ErrInternal.Wrap(err)
	}
	return renderPromptTemplate(tpl.TemplateBody, j.PromptTemplateVariables, vars), nil
}

func (s *impl) projectorFor(kind string) RuntimeProjector {
	kind = strings.ToLower(strings.TrimSpace(kind))
	for _, p := range s.projectors {
		if p != nil && strings.EqualFold(p.Kind(), kind) {
			return p
		}
	}
	return nil
}

func (s *impl) runtimeFramework(ctx context.Context, runtimeEnvID *int64) (string, error) {
	if runtimeEnvID == nil || *runtimeEnvID == 0 || s.runtime == nil {
		return "", nil
	}
	fw, err := s.runtime.GetFrameworkByID(ctx, *runtimeEnvID)
	if err != nil {
		return "", err
	}
	return strings.ToLower(strings.TrimSpace(fw)), nil
}

func (s *impl) projectJobBestEffort(ctx context.Context, j *domcron.Job, agentUUID string) {
	if j == nil || s.repo == nil || s.agents == nil {
		return
	}
	if s.cfg.DisableRuntimeProjection {
		return // dev 姿势: 任务保持 scheduler_kind='bus', Bus 自己调度/投递
	}
	ag, err := s.agents.GetByUUID(ctx, agentUUID)
	if err != nil || ag == nil || ag.RuntimeEnvironmentID == nil || *ag.RuntimeEnvironmentID == 0 {
		return
	}
	framework, err := s.runtimeFramework(ctx, ag.RuntimeEnvironmentID)
	if err != nil || framework != "openclaw" {
		return
	}
	projector := s.projectorFor(domcron.RuntimeAdapterOpenClaw)
	if projector == nil {
		return
	}
	prompt, err := s.resolveRuntimePrompt(ctx, j)
	if err != nil {
		s.recordProjectionError(ctx, j, ag, framework, "", err, nil)
		return
	}
	binding, _ := s.repo.GetRuntimeBindingByJob(ctx, j.ID, *ag.RuntimeEnvironmentID, domcron.RuntimeAdapterOpenClaw)
	remoteJobID := ""
	if binding != nil {
		remoteJobID = binding.RemoteJobID
	}
	snapshot := map[string]any{
		"job_uuid":      j.UUID,
		"name":          j.Name,
		"description":   j.Description,
		"schedule_cron": j.ScheduleCron,
		"timezone":      j.Timezone,
		"enabled":       j.Enabled,
		"status":        j.Status,
		"agent_uuid":    agentUUID,
		"remote_job_id": remoteJobID,
	}
	now := time.Now().UTC()
	result, err := projector.Upsert(ctx, RuntimeProjectionInput{
		JobID: j.ID, TenantID: j.TenantID, AccountID: j.AccountID, AgentID: j.AgentID,
		AgentUUID: agentUUID, RuntimeEnvironmentID: *ag.RuntimeEnvironmentID,
		RemoteJobID: remoteJobID, Name: j.Name, Description: j.Description,
		ScheduleCron: j.ScheduleCron, Timezone: j.Timezone, Prompt: prompt,
		Enabled: j.Enabled && j.Status == domcron.StatusActive, Status: j.Status,
		Revision: j.UpdatedAt.UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		s.recordProjectionError(ctx, j, ag, framework, remoteJobID, err, snapshot)
		return
	}
	if result.RemoteJobID == "" {
		result.RemoteJobID = remoteJobID
	}
	if _, err := s.repo.UpsertRuntimeBinding(ctx, domcron.UpsertRuntimeBindingInput{
		CronJobID: j.ID, TenantID: j.TenantID, AccountID: j.AccountID, AgentID: j.AgentID,
		RuntimeEnvironmentID: *ag.RuntimeEnvironmentID, AdapterKind: domcron.RuntimeAdapterOpenClaw,
		Framework: framework, RemoteJobID: result.RemoteJobID,
		DesiredRevision: j.UpdatedAt.UTC().Format(time.RFC3339Nano), RemoteRevision: result.RemoteRevision,
		SyncStatus: domcron.RuntimeSyncSynced, SourceSnapshot: snapshot, LastSyncedAt: &now,
	}); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "cron runtime projection binding upsert failed", "job_id", j.ID, "err", err)
	}
	runtimeKind := domcron.SchedulerRuntime
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		return s.repo.PatchJob(ctx, tx, j.ID, domcron.PatchJobInput{SchedulerKind: &runtimeKind})
	}); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "cron runtime projection scheduler_kind patch failed", "job_id", j.ID, "err", err)
	} else {
		j.SchedulerKind = runtimeKind
	}
}

func (s *impl) recordProjectionError(ctx context.Context, j *domcron.Job, ag *domagent.DigitalEmployee, framework, remoteJobID string, cause error, snapshot map[string]any) {
	if j == nil || ag == nil || ag.RuntimeEnvironmentID == nil || s.repo == nil {
		return
	}
	if snapshot == nil {
		snapshot = map[string]any{"job_uuid": j.UUID, "remote_job_id": remoteJobID}
	}
	if _, err := s.repo.UpsertRuntimeBinding(ctx, domcron.UpsertRuntimeBindingInput{
		CronJobID: j.ID, TenantID: j.TenantID, AccountID: j.AccountID, AgentID: j.AgentID,
		RuntimeEnvironmentID: *ag.RuntimeEnvironmentID, AdapterKind: domcron.RuntimeAdapterOpenClaw,
		Framework: framework, RemoteJobID: remoteJobID,
		DesiredRevision: j.UpdatedAt.UTC().Format(time.RFC3339Nano),
		SyncStatus:      domcron.RuntimeSyncError,
		LastSyncError:   cause.Error(),
		SourceSnapshot:  snapshot,
	}); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "cron runtime projection error binding upsert failed", "job_id", j.ID, "err", err)
	}
}

func (s *impl) deleteRuntimeProjectionBestEffort(ctx context.Context, j *domcron.Job) {
	if j == nil || s.repo == nil || s.agents == nil {
		return
	}
	if s.cfg.DisableRuntimeProjection {
		return
	}
	agentUUID, _ := s.fetchAgentUUID(ctx, j.AgentID)
	if agentUUID == "" {
		return
	}
	ag, err := s.agents.GetByUUID(ctx, agentUUID)
	if err != nil || ag == nil || ag.RuntimeEnvironmentID == nil || *ag.RuntimeEnvironmentID == 0 {
		return
	}
	binding, err := s.repo.GetRuntimeBindingByJob(ctx, j.ID, *ag.RuntimeEnvironmentID, domcron.RuntimeAdapterOpenClaw)
	if err != nil || binding == nil {
		return
	}
	projector := s.projectorFor(binding.AdapterKind)
	if projector != nil {
		if err := projector.Delete(ctx, RuntimeProjectionDeleteInput{
			JobID: j.ID, TenantID: j.TenantID, AccountID: j.AccountID, AgentID: j.AgentID,
			RuntimeEnvironmentID: *ag.RuntimeEnvironmentID, RemoteJobID: binding.RemoteJobID,
		}); err != nil && s.logger != nil {
			s.logger.Warn(ctx, "cron runtime projection delete failed", "job_id", j.ID, "remote_job_id", binding.RemoteJobID, "err", err)
		}
	}
	if err := s.repo.SoftDeleteRuntimeBindingByJob(ctx, j.ID); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "cron runtime projection binding soft-delete failed", "job_id", j.ID, "err", err)
	}
}

func (s *impl) ReconcileRuntimeProjections(ctx context.Context, limit int) (int, error) {
	bindings, err := s.repo.ListRuntimeBindingsForRetry(ctx, limit)
	if err != nil {
		return 0, apperr.ErrInternal.Wrap(err)
	}
	n := 0
	for i := range bindings {
		b := bindings[i]
		if b.AdapterKind != domcron.RuntimeAdapterOpenClaw {
			continue
		}
		j, err := s.repo.GetJobByID(ctx, b.CronJobID)
		if err != nil {
			if s.logger != nil {
				s.logger.Warn(ctx, "cron projection reconcile: job lookup failed", "job_id", b.CronJobID, "err", err)
			}
			continue
		}
		agentUUID, _ := s.fetchAgentUUID(ctx, j.AgentID)
		if agentUUID == "" {
			continue
		}
		s.projectJobBestEffort(ctx, j, agentUUID)
		n++
	}
	return n, nil
}

// lookupTemplateByID · E4 · 通过 PromptTemplateLookup.GetPromptTemplateByID 拿模板.
//
// 之前的实现直接在 service 拼 SQL + pool.QueryRow, 违背 "service 不直接碰 SQL/pool" 分层约束;
// E4 改为通过接口下沉到 repo. 模板不存在 / 已软删 → 返 (nil, nil), 由 caller resolveRuntimePrompt
// 转成 cron.prompt_template_not_found.
func (s *impl) lookupTemplateByID(ctx context.Context, id int64) (*domcron.PromptTemplate, error) {
	if s.templates == nil {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("prompt template lookup not wired at runtime")
	}
	tpl, err := s.templates.GetPromptTemplateByID(ctx, id)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, nil // caller (resolveRuntimePrompt) 决定如何报错
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return tpl, nil
}

// resolvePromptTemplate · F08 §8.2 #4 / R9 · 拉模板 + 校 scope/status + 拉变量定义.
//
// 行为:
//   - templateUUID 空 → 返回 (nil, nil, nil) (caller 走老 payload.prompt 路径).
//   - PromptTemplates lookup 缺失 / 模板不存在 / 软删 → cron.prompt_template_not_found.
//   - 模板 status != 'active' → cron.prompt_template_not_found (caller 不区分原因).
//   - scope='tenant' 但 tenant_id != caller tenant → cron.prompt_template_not_found (跨租户屏蔽).
//   - scope='platform' 任意 tenant caller 都可用.
func (s *impl) resolvePromptTemplate(ctx context.Context, tenantID int64, templateUUID string) (*domcron.PromptTemplate, []domcron.PromptTemplateVariable, error) {
	templateUUID = strings.TrimSpace(templateUUID)
	if templateUUID == "" {
		return nil, nil, nil
	}
	if s.templates == nil {
		return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("prompt template lookup not wired")
	}
	tpl, err := s.templates.GetPromptTemplateByUUID(ctx, templateUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
				Withf("template %s not found", templateUUID)
		}
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	if tpl.Status != domcron.TemplateStatusActive {
		return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("template %s not active", templateUUID)
	}
	switch tpl.ScopeKind {
	case domcron.TemplateScopePlatform:
		// 任意 tenant 可见.
	case domcron.TemplateScopeTenant:
		if tpl.TenantID == nil || *tpl.TenantID != tenantID {
			return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
				Withf("template %s not visible to tenant", templateUUID)
		}
	default:
		return nil, nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
			Withf("template %s scope %q unknown", templateUUID, tpl.ScopeKind)
	}
	vars, err := s.templates.ListPromptTemplateVariables(ctx, tpl.ID)
	if err != nil {
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	return tpl, vars, nil
}

// bulkPauseForOwnerInactiveRepo · 抽出窄接口便于单测注入 (impl 默认走 *repocron.Repo).
//
// 与 jobLimitCounter 同款风格; *repocron.Repo 隐式满足.
type bulkPauseForOwnerInactiveRepo interface {
	BulkPauseForOwnerInactive(ctx context.Context, tx pgx.Tx, tenantID, accountID int64, now time.Time) (int, error)
}

// applyOwnerInactivePause · F08 §4.4 / R10 listener 主逻辑. 抽出便于单测.
func applyOwnerInactivePause(ctx context.Context, repo bulkPauseForOwnerInactiveRepo,
	evt domcron.TenantMembershipStatusChangedEvent, now time.Time) (int, error) {
	switch evt.NewStatus {
	case "suspended", "left":
	default:
		// invited/active 都不触发 (包括从 suspended/left 回到 active 也不 resume).
		return 0, nil
	}
	if evt.AccountID == 0 || evt.TenantID == 0 {
		return 0, nil
	}
	// 不走 tx (单 UPDATE 已经原子); 调用方需要事务时自行外包.
	return repo.BulkPauseForOwnerInactive(ctx, nil, evt.TenantID, evt.AccountID, now)
}

func (s *impl) HandleTenantMembershipStatusChanged(ctx context.Context, evt domcron.TenantMembershipStatusChangedEvent) (int, error) {
	n, err := applyOwnerInactivePause(ctx, s.repo, evt, time.Now())
	if err != nil {
		return 0, apperr.ErrInternal.Wrap(err)
	}
	if n > 0 {
		// audit 与 admin SSE 计数; release intent topic 不在此固化, 留给 cmd/bus 装配.
		s.bestEffortAudit(ctx, "audit.cron.owner_inactive_paused", evt.TenantID, map[string]any{
			"resource_kind":  "agent_cron_job_batch",
			"account_id":     evt.AccountID,
			"new_status":     evt.NewStatus,
			"old_status":     evt.OldStatus,
			"affected_count": n,
		})
	}
	return n, nil
}

// jobLimitCounter · 抽出窄接口便于单测注入 (impl 默认走 *repocron.Repo).
//
// F08 §8.2 #7 / R7 v0.4.3: 全局可配最小间隔 + 账号/租户数量限额, **不读** cron_min_interval_overrides.
type jobLimitCounter interface {
	CountActiveJobsForAccount(ctx context.Context, tenantID, accountID int64) (int, error)
	CountActiveJobsForTenant(ctx context.Context, tenantID int64) (int, error)
}

// assertJobLimits · F08 §8.2 #7 / R7 v0.4.3 限额校验.
//
// 仅在 CreateJob 入口调用 (新建会增加 active cron 数). Patch/Pause/Resume 不改总数,
// 不需要复查; 但若未来 admin 允许从 archived 转回 active (本期不做), 也要进这条.
//
// **0 limit 的语义边界**:
//   - **外部生产配置层面 (CronConfig.AccountJobLimit / TenantJobLimit)**: 0 表示
//     "未注入", svccron.New() 会兜底为 DefaultAccountJobLimit / DefaultTenantJobLimit
//     (20 / 500). 同时 internal/pkg/config.CronConfig 的 fillDefaults 已经先一步把
//     0 归一为 20 / 500. 所以**生产链路不会有 "0 = 禁用限额"** 这个语义.
//   - **本 helper 的 accountLimit/tenantLimit 参数**: 仍允许 0 作为 "对应维度 no-op"
//     语义, 仅用于单测 / 内部组合场景 (例如要验证只触发 tenant 维度时, 把 accountLimit
//     传 0 短路掉 account 维度的 DB 查询). 不能被生产 cmd/bus 路径达到, 因为上游 New
//     已经把 cfg.AccountJobLimit/TenantJobLimit 兜底过.
//
// 错误码与 F08 §3.4.2 对齐:
//   - cron.account_job_limit_reached
//   - cron.tenant_job_limit_reached
//
// **Fail-closed 语义**: counter 查 DB 失败 → 拒绝创建 (返 apperr.ErrInternal.Wrap).
// 理由: 单点 DB 抖动期 fail-open 会让攻击/异常账号绕过限额; 阻断单条 CreateJob 比让
// 整张表"超过 20 / 500"安全得多. caller 拿到 5xx 后会重试或退避.
func assertJobLimits(ctx context.Context, counter jobLimitCounter, tenantID, accountID int64,
	accountLimit, tenantLimit int) error {
	if counter == nil {
		return nil
	}
	if accountLimit > 0 {
		n, err := counter.CountActiveJobsForAccount(ctx, tenantID, accountID)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if n >= accountLimit {
			return apperr.New(apperr.InvalidParams, ErrCodeCronAccountJobLimit).
				Withf("account %d already has %d active cron jobs (limit %d)", accountID, n, accountLimit)
		}
	}
	if tenantLimit > 0 {
		n, err := counter.CountActiveJobsForTenant(ctx, tenantID)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if n >= tenantLimit {
			return apperr.New(apperr.InvalidParams, ErrCodeCronTenantJobLimit).
				Withf("tenant %d already has %d active cron jobs (limit %d)", tenantID, n, tenantLimit)
		}
	}
	return nil
}

func (s *impl) assertPlanJobLimit(ctx context.Context, tenantID int64) error {
	if s.quota == nil {
		return nil
	}
	n, err := s.repo.CountActiveJobsForTenant(ctx, tenantID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	return s.quota.EnsureWithinLimit(ctx, tenantID, "automation_task_limit", int64(n), 1)
}

// assertCronCapability checks whether the agent can be invoked by the Bus cron
// executor through chat.RunAgentForConversation.
//
// Bus 调度放行:
//   - framework ∈ {openclaw, hermes, zap} (来源: runtime_environments.framework)
//
// ZAP 标准任务保持 scheduler_kind='bus'，到点复用统一 chat runner；是否支持
// runtime native cron / 专用 backchannel 是独立的 projection 能力，不在此处判断。
// 其它未知 framework → cron.agent_not_supported.
//
// 设计:
//   - 不读 AgentCard `capabilities_declared.supports_cron`：目标只需支持一轮对话，
//     调度、锁、run 状态和失败收敛由 Bus 持有
//   - runtime lookup 为 nil 时跳过 gating (fail-open, 仅向后兼容; 生产 cmd/bus 装配应必填)
//   - 错误 message 含明确原因, 客户端可拿来在任务页提示
//
// 调用位置 (与 docs/tasks/agent-bus-admin-backend-completion-before-zhiban-app-cutover.md §A4.2 对齐):
//   - CreateJob 入口
//   - PatchJob 当 enabled 切 true 时 (防止"先建 disabled 再 enable" 绕过)
//   - RunNow 入口
func (s *impl) assertCronCapability(ctx context.Context, ag *domagent.DigitalEmployee) error {
	if ag == nil {
		return apperr.New(apperr.NotFound, ErrCodeCronAgentNotFound).Withf("agent nil")
	}
	if ag.ExecutionLocus == "local" {
		if ag.LocalEngine != "" && ag.LocalEngine != domlocal.EngineDSH && ag.LocalEngine != domlocal.EngineCodex {
			return apperr.New(apperr.Forbidden, ErrCodeCronAgentNotSupported)
		}
		if s.localDesktop == nil {
			return apperr.New(apperr.PreconditionFailed, "cron.local_unavailable")
		}
		return nil
	}
	// F02 v0.3: agent.integration_mode 列已删; gating 改用 runtime_environments.framework
	// + scope 派生 (下面的 framework 检查已能区分 openclaw/hermes vs eap/外部; self_hosted
	// 改由 scope=tenant + hosting_kind=external_endpoint 判定)。
	if s.runtime == nil {
		// fail-open: 仅向后兼容; 生产应在 cmd/bus 装配阶段就把 Runtime 注入.
		if s.logger != nil {
			s.logger.Warn(ctx, "cron capability gating fail-open: runtime lookup not wired (set cron.Deps.Runtime to enforce)")
		}
		return nil
	}
	if ag.RuntimeEnvironmentID == nil || *ag.RuntimeEnvironmentID == 0 {
		return apperr.New(apperr.Forbidden, ErrCodeCronAgentNotSupported).
			Withf("cron requires runtime_environment binding; agent %s has none", ag.UUID)
	}
	framework, err := s.runtime.GetFrameworkByID(ctx, *ag.RuntimeEnvironmentID)
	if err != nil {
		// Unable to resolve runtime → fail-closed.
		return apperr.New(apperr.Forbidden, ErrCodeCronAgentNotSupported).
			Withf("cron runtime lookup failed for agent %s: %v", ag.UUID, err)
	}
	framework = strings.ToLower(strings.TrimSpace(framework))
	if framework != "openclaw" && framework != "hermes" && framework != "zap" && framework != "dsh" && framework != "generic" {
		return apperr.New(apperr.Forbidden, ErrCodeCronAgentNotSupported).
			Withf("cron requires a chat-capable runtime; agent %s runtime framework=%q",
				ag.UUID, framework)
	}
	return nil
}

// =====================================================
// DTO 转换
// =====================================================

func (s *impl) toJobDTO(j *domcron.Job, agentUUID string) JobDTO {
	dto := JobDTO{
		UUID: j.UUID, Name: j.Name, Description: j.Description,
		AgentUUID: agentUUID, ScheduleCron: j.ScheduleCron, Timezone: j.Timezone,
		Payload: j.Payload, Delivery: j.Delivery,
		Enabled: j.Enabled, Status: j.Status, SchedulerKind: j.SchedulerKind,
		ConsecutiveFailures: j.ConsecutiveFailures, FailureThreshold: j.FailureThreshold,
		LastRunAt: j.LastRunAt, LastRunStatus: j.LastRunStatus, LastRunSummary: j.LastRunSummary,
		NextRunAt: j.NextRunAt,
		CreatedAt: j.CreatedAt, UpdatedAt: j.UpdatedAt,
		// L 增量: admin 列表用字段; client 路径走相同 DTO, owner/pause/delivery 字段
		// 都对自己可见, 不存在跨账号泄露.
		OwnerAccountID:  j.AccountID,
		PauseReason:     j.PauseReason,
		DeliveryKind:    j.DeliveryKind,
		OwnerInactiveAt: j.OwnerInactiveAt,
	}
	if v, ok := j.Metadata["admin_disabled"].(bool); ok && v {
		dto.AdminDisabled = true
	}
	if v, ok := j.Metadata["run_once"].(bool); ok && v {
		dto.RunOnce = true
	}
	// Old rows can retain enabled=true after the failure threshold stopped them.
	dto.Enabled = j.Enabled && j.Status == domcron.StatusActive && !dto.AdminDisabled
	if !dto.Enabled {
		dto.NextRunAt = nil
	}
	return dto
}

func toRunDTO(r *domcron.Run, jobUUID, convUUID string) RunDTO {
	return RunDTO{
		UUID: r.UUID, JobUUID: jobUUID, Status: r.Status, TriggerKind: r.TriggerKind,
		ConversationUUID: convUUID, MessageUUID: r.MessageUUID,
		StartedAt: r.StartedAt, FinishedAt: r.FinishedAt, DurationMs: r.DurationMs,
		Summary: r.Summary, ErrorMessage: r.ErrorMessage,
		// F08 §3.2.4 / R9: 触发时渲染后的 prompt; owner DTO 出口直透; admin 路径不走此函数.
		RenderedPromptSnapshot: r.RenderedPromptSnapshot,
	}
}

// =====================================================
// runTx helper
// =====================================================

func (s *impl) runTx(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *impl) publishAuditTx(ctx context.Context, tx pgx.Tx, topic string, tenantID int64, payload map[string]any) {
	if s.audit == nil {
		return
	}
	body, _ := json.Marshal(payload)
	if err := s.audit.Publish(ctx, repoevent.WrapTx(tx), domevent.Event{
		Topic: topic, TenantID: tenantID, Payload: body,
	}); err != nil && !errors.Is(err, domevent.ErrDuplicate) {
		s.logger.Warn(ctx, "cron: audit publish failed", "topic", topic, "err", err)
	}
}

func (s *impl) bestEffortAudit(ctx context.Context, topic string, tenantID int64, payload map[string]any) {
	if s.audit == nil {
		return
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return
	}
	defer func() { _ = tx.Rollback(ctx) }()
	body, _ := json.Marshal(payload)
	if err := s.audit.Publish(ctx, repoevent.WrapTx(tx), domevent.Event{
		Topic: topic, TenantID: tenantID, Payload: body,
	}); err != nil && !errors.Is(err, domevent.ErrDuplicate) {
		return
	}
	_ = tx.Commit(ctx)
}

func (s *impl) notify(ctx context.Context, payload string) {
	if _, err := s.pool.Exec(ctx, `SELECT pg_notify($1, $2)`, "config_change", payload); err != nil {
		s.logger.Warn(ctx, "cron: pg_notify failed", "payload", payload, "err", err)
	}
}

// =====================================================
// CRUD
// =====================================================

func (s *impl) ListJobs(ctx context.Context, accountID, tenantID int64) ([]JobDTO, error) {
	rows, err := s.repo.ListJobs(ctx, domcron.ListJobsFilter{TenantID: tenantID, AccountID: accountID, Limit: 200})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]JobDTO, 0, len(rows))
	for i := range rows {
		uuid, _ := s.fetchAgentUUID(ctx, rows[i].AgentID)
		out = append(out, s.toJobDTO(&rows[i], uuid))
	}
	return out, nil
}

func (s *impl) fetchAgentUUID(ctx context.Context, agentID int64) (string, error) {
	if s.agents == nil {
		return "", nil
	}
	// best-effort: 拿不到也不阻断 list (DTO 仅 metadata).
	row := s.pool.QueryRow(ctx, `SELECT uuid::text FROM digital_employees WHERE id=$1`, agentID)
	var u string
	if err := row.Scan(&u); err != nil {
		return "", err
	}
	return u, nil
}

func (s *impl) CreateJob(ctx context.Context, accountID, tenantID int64, req CreateJobReq) (*JobDTO, error) {
	name := strings.TrimSpace(req.Name)
	if name == "" {
		return nil, apperr.ErrInvalidParams.Withf("name required")
	}
	// F08 §8.2 #4 / R9: legacy prompt 与 prompt_template_uuid 互斥.
	prompt := strings.TrimSpace(req.Prompt)
	tplUUID := strings.TrimSpace(req.PromptTemplateUUID)
	if prompt != "" && tplUUID != "" {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeCronTemplateCreateConflict).
			Withf("prompt and prompt_template_uuid are mutually exclusive")
	}
	if prompt == "" && tplUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("prompt or prompt_template_uuid required")
	}
	// R9: 解析模板 + 校变量 (在 frequency / agent 校验之前; 失败立刻返语义错误码).
	tpl, tplVars, err := s.resolvePromptTemplate(ctx, tenantID, tplUUID)
	if err != nil {
		return nil, err
	}
	if tpl != nil {
		if err := validatePromptTemplateVariables(req.PromptTemplateVariables, tplVars); err != nil {
			return nil, err
		}
	} else if len(prompt) > s.cfg.PayloadMaxBytes {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeCronPayloadTooLarge).
			Withf("prompt %d > max %d", len(prompt), s.cfg.PayloadMaxBytes)
	}
	// F08 R11: 三层 fallback (job → tenant → cfg); 落库前解析成 effective tz,
	// 避免现网租户改默认 tz 导致老 cron 漂移 (parseCron / executor 不再 fallback).
	tz := s.resolveJobTimezone(ctx, req.Timezone, tenantID)
	sched, loc, err := s.parseCron(req.ScheduleCron, tz)
	if err != nil {
		return nil, err
	}
	// agent 查找 + tenant 隔离.
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	ag, err := s.agents.GetByUUID(ctx, req.AgentUUID)
	if err != nil || ag == nil {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronAgentNotFound).Withf("agent %s not found", req.AgentUUID)
	}
	if !cronAgentInScope(ag, accountID, tenantID) {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronAgentNotFound).Withf("agent cross tenant")
	}
	// Codex P1#1: contacts 可见性闸口 (与 chat.Send 同款).
	if err := s.assertAgentVisible(ctx, accountID, tenantID, ag.UUID); err != nil {
		return nil, err
	}
	// Bus-scheduled capability gating: OpenClaw / Hermes / ZAP.
	if err := s.assertCronCapability(ctx, ag); err != nil {
		return nil, err
	}
	// F08 §8.2 #7 / R7 v0.4.3: 账号 / 租户 active cron 数量限额 (不读 cron_min_interval_overrides).
	// 注: parseCron 已经在上面拒过频率下限 (cron.frequency_below_min); 限额是另一维度.
	if err := assertJobLimits(ctx, s.repo, tenantID, accountID, s.cfg.AccountJobLimit, s.cfg.TenantJobLimit); err != nil {
		return nil, err
	}
	if err := s.assertPlanJobLimit(ctx, tenantID); err != nil {
		return nil, err
	}
	// delivery ownership + agent 归属 (Codex P1#2)。F08 v0.4.9: 新建单聊尚无
	// conversation_uuid 时，所有提示/调度/agent/配额校验已在上面通过，此处才按需
	// ensure canonical direct，避免无效任务请求制造空会话。
	conv, deliveryKind, err := s.resolveRequestedDelivery(
		ctx, accountID, tenantID, ag.ID, ag.UUID, req.ConversationUUID, req.DeliveryKind,
	)
	if err != nil {
		return nil, err
	}
	if err := assertLocalDelivery(ag, conv, deliveryKind); err != nil {
		return nil, err
	}
	delivery := map[string]any{"conversation_uuid": conv.UUID}
	// M 返修: schema agent_cron_jobs.delivery_kind NOT NULL CHECK direct/group.
	// 必须以 resolveDelivery 的推导为准 (conv.RoomID==nil → direct; room.kind 分发).
	// 前端可传 hint 但不可信; 这里**不读** req 任何字段.
	if deliveryKind == "" {
		// 兜底: resolveDelivery 返回 (conv, "", nil) 不应发生; 若发生则 PG CHECK 会拒.
		// 这里抛错避免暗藏漏写.
		return nil, apperr.ErrInternal.Withf("delivery_kind unresolved (cron schema requires direct/group)")
	}
	next := sched.Next(time.Now().In(loc))
	payloadJSON := map[string]any{}
	if prompt != "" {
		payloadJSON["prompt"] = prompt
	}
	var tplID *int64
	var tplVarsToPersist map[string]any
	if tpl != nil {
		id := tpl.ID
		tplID = &id
		if req.PromptTemplateVariables != nil {
			tplVarsToPersist = req.PromptTemplateVariables
		} else {
			tplVarsToPersist = map[string]any{}
		}
	}

	var created *domcron.Job
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		j, err := s.repo.CreateJob(ctx, tx, domcron.CreateJobInput{
			TenantID: tenantID, AccountID: accountID, AgentID: ag.ID,
			Name: name, Description: req.Description,
			ScheduleCron: req.ScheduleCron, Timezone: tz,
			Payload: payloadJSON, Delivery: delivery,
			NextRunAt:               &next,
			PromptTemplateID:        tplID,
			PromptTemplateVariables: tplVarsToPersist,
			DeliveryKind:            deliveryKind, // M 返修: 写入 NOT NULL 列
			RunOnce:                 req.RunOnce,
		})
		if err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.cron.job_created", tenantID, map[string]any{
			"resource_kind": "agent_cron_job",
			"resource_uuid": j.UUID,
			"account_id":    accountID,
			"agent_uuid":    ag.UUID,
		})
		created = j
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return nil, e
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "agent_cron_jobs:"+strconv.FormatInt(created.ID, 10))
	s.projectJobBestEffort(ctx, created, ag.UUID)
	dto := s.toJobDTO(created, ag.UUID)
	return &dto, nil
}

func (s *impl) GetJob(ctx context.Context, accountID, tenantID int64, jobUUID string) (*JobDTO, error) {
	j, err := s.resolveOwnedJob(ctx, jobUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	uuid, _ := s.fetchAgentUUID(ctx, j.AgentID)
	dto := s.toJobDTO(j, uuid)
	return &dto, nil
}

func (s *impl) resolveOwnedJob(ctx context.Context, jobUUID string, accountID, tenantID int64) (*domcron.Job, error) {
	j, err := s.repo.GetJobByUUID(ctx, jobUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeCronJobNotFound).Withf("job %s not found", jobUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if j.TenantID != tenantID || j.AccountID != accountID {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronJobNotFound).Withf("job %s not found", jobUUID)
	}
	return j, nil
}

func (s *impl) PatchJob(ctx context.Context, accountID, tenantID int64, jobUUID string, req PatchJobReq) (*JobDTO, error) {
	j, err := s.resolveOwnedJob(ctx, jobUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	in := domcron.PatchJobInput{}
	if req.Name != nil {
		n := strings.TrimSpace(*req.Name)
		if n == "" {
			return nil, apperr.ErrInvalidParams.Withf("name invalid")
		}
		in.Name = &n
	}
	if req.Description != nil {
		d := *req.Description
		in.Description = &d
	}
	// schedule_cron / timezone 修改时重新校验 + 重算 next_run_at (F08 §3.2.2 / R7 频率下限沿用 parseCron).
	tz := j.Timezone
	if req.Timezone != nil && strings.TrimSpace(*req.Timezone) != "" {
		tz = *req.Timezone
		in.Timezone = &tz
	}
	if nextRunAt, err := s.validatePatchSchedule(req, j.ScheduleCron, tz); err != nil {
		return nil, err
	} else if nextRunAt != nil {
		if req.ScheduleCron != nil && strings.TrimSpace(*req.ScheduleCron) != "" {
			in.ScheduleCron = req.ScheduleCron
		}
		in.NextRunAt = nextRunAt
	}
	// E5: prompt vs template 互斥闭环 (与 CreateJob 同款约束).
	//   - 同时提供 prompt + 非空 template_uuid → cron.prompt_template_payload_conflict
	//   - 仅 prompt → 自动清掉当前 template (切回 legacy payload.prompt 路径)
	//   - 仅 template_uuid="" 清模板 → caller 必须 (a) 同步传非空 prompt, 或
	//     (b) job 原本 payload.prompt 不空; 否则 prompt invalid
	currentLegacyPrompt, _ := j.Payload["prompt"].(string)
	if err := validatePatchPromptMutex(req, currentLegacyPrompt); err != nil {
		return nil, err
	}
	// PATCH 仅传 prompt 时, 隐式切回 legacy: 同时清当前 template_id + variables.
	patchPromptOnlySwitchesToLegacy := req.Prompt != nil && req.PromptTemplateUUID == nil

	if req.Prompt != nil {
		p := strings.TrimSpace(*req.Prompt)
		if p == "" {
			return nil, apperr.ErrInvalidParams.Withf("prompt invalid")
		}
		if len(p) > s.cfg.PayloadMaxBytes {
			return nil, apperr.New(apperr.InvalidParams, ErrCodeCronPayloadTooLarge).Withf("prompt too large")
		}
		newPayload := map[string]any{}
		for k, v := range j.Payload {
			newPayload[k] = v
		}
		newPayload["prompt"] = p
		in.Payload = newPayload
		// 隐式切回 legacy: 当前 job 有 template, patch 只传 prompt → 自动清掉 template.
		if patchPromptOnlySwitchesToLegacy && j.PromptTemplateID != nil {
			in.SetPromptTemplate = true
			in.PromptTemplateID = nil
			in.PromptTemplateVariables = map[string]any{}
		}
	}

	// R9 模板切换 / 变量更新.
	if req.PromptTemplateUUID != nil {
		tplUUID := strings.TrimSpace(*req.PromptTemplateUUID)
		in.SetPromptTemplate = true
		if tplUUID == "" {
			// 清掉模板, 退回老 payload.prompt 路径; mutex helper 已校验存在可用 prompt.
			in.PromptTemplateID = nil
			in.PromptTemplateVariables = map[string]any{}
		} else {
			tpl, tplVars, err := s.resolvePromptTemplate(ctx, tenantID, tplUUID)
			if err != nil {
				return nil, err
			}
			if tpl == nil {
				return nil, apperr.New(apperr.NotFound, ErrCodeCronTemplateNotFound).
					Withf("template %s not resolvable", tplUUID)
			}
			varsToUse := req.PromptTemplateVariables
			if varsToUse == nil {
				varsToUse = j.PromptTemplateVariables
			}
			if err := validatePromptTemplateVariables(varsToUse, tplVars); err != nil {
				return nil, err
			}
			id := tpl.ID
			in.PromptTemplateID = &id
			if varsToUse == nil {
				varsToUse = map[string]any{}
			}
			in.PromptTemplateVariables = varsToUse
		}
	} else if req.PromptTemplateVariables != nil {
		// 仅改变量 (不切模板); 必须当前 job 有 template_id, 否则没意义.
		if j.PromptTemplateID == nil {
			return nil, apperr.New(apperr.InvalidParams, ErrCodeCronTemplateNotFound).
				Withf("cannot patch prompt_template_variables: job has no template")
		}
		// 复查变量与当前模板 schema (拉模板定义复查类型).
		if s.templates != nil {
			vars, err := s.templates.ListPromptTemplateVariables(ctx, *j.PromptTemplateID)
			if err != nil {
				return nil, apperr.ErrInternal.Wrap(err)
			}
			if err := validatePromptTemplateVariables(req.PromptTemplateVariables, vars); err != nil {
				return nil, err
			}
		}
		in.PromptTemplateVariables = req.PromptTemplateVariables
	}
	if req.ConversationUUID != nil || req.DeliveryKind != nil {
		// Codex P1#2: 改 delivery 时也必须重新校验 conv 归属 agent.
		// M 返修: 同步重算 delivery_kind 列; 否则列表 / executor 走老值会陈旧.
		conversationUUID := ""
		if req.ConversationUUID != nil {
			conversationUUID = *req.ConversationUUID
		}
		requestedKind := ""
		if req.DeliveryKind != nil {
			requestedKind = *req.DeliveryKind
		}
		agentUUID := ""
		if strings.TrimSpace(conversationUUID) == "" {
			agentUUID, err = s.fetchAgentUUID(ctx, j.AgentID)
			if err != nil || strings.TrimSpace(agentUUID) == "" {
				return nil, apperr.New(apperr.NotFound, ErrCodeCronAgentNotFound).
					Withf("job agent not found")
			}
		}
		conv, deliveryKind, err := s.resolveRequestedDelivery(
			ctx, accountID, tenantID, j.AgentID, agentUUID, conversationUUID, requestedKind,
		)
		if err != nil {
			return nil, err
		}
		if deliveryKind == "" {
			return nil, apperr.ErrInternal.Withf("delivery_kind unresolved (cron schema requires direct/group)")
		}
		deliveryAgent, err := s.jobAgent(ctx, j)
		if err != nil {
			return nil, err
		}
		if err := assertLocalDelivery(deliveryAgent, conv, deliveryKind); err != nil {
			return nil, err
		}
		in.Delivery = map[string]any{"conversation_uuid": conv.UUID}
		in.DeliveryKind = &deliveryKind
	}
	if req.Enabled != nil {
		if j.Status == domcron.StatusArchived {
			return nil, apperr.ErrForbidden.Withf("cron.job_archived")
		}
		// 用户直接 toggle enabled 不能 override admin force-disable.
		if *req.Enabled && j.Metadata != nil {
			if v, ok := j.Metadata["admin_disabled"].(bool); ok && v {
				return nil, apperr.New(apperr.Forbidden, ErrCodeCronResumeBlockedByAdmin).
					Withf("admin disabled; user cannot enable")
			}
		}
		// enabled=true 时复查 capability (防"先建 disabled 再 enable"绕过).
		if *req.Enabled && s.agents != nil {
			agentUUID, _ := s.fetchAgentUUID(ctx, j.AgentID)
			if agentUUID != "" {
				if ag, err := s.agents.GetByUUID(ctx, agentUUID); err == nil && ag != nil {
					if err := s.assertCronCapability(ctx, ag); err != nil {
						return nil, err
					}
				}
			}
		}
		in.Enabled = req.Enabled
		if *req.Enabled {
			activeStatus := domcron.StatusActive
			in.Status = &activeStatus
			in.ResetFailures = true
			in.ClearPauseReason = true
		} else {
			paused := domcron.StatusPaused
			in.Status = &paused
			reason := domcron.PauseReasonUserPaused
			in.PauseReason = &reason
		}
	}
	if req.RunOnce != nil {
		in.SetRunOnce = req.RunOnce
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.PatchJob(ctx, tx, j.ID, in); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.cron.job_updated", tenantID, map[string]any{
			"resource_kind": "agent_cron_job",
			"resource_uuid": j.UUID,
			"account_id":    accountID,
		})
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return nil, e
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "agent_cron_jobs:"+strconv.FormatInt(j.ID, 10))
	updated, _ := s.repo.GetJobByID(ctx, j.ID)
	uuid, _ := s.fetchAgentUUID(ctx, updated.AgentID)
	s.projectJobBestEffort(ctx, updated, uuid)
	dto := s.toJobDTO(updated, uuid)
	// SSE cron.job.updated.
	s.publishJobEvent(ctx, updated, EventCronJobUpdated)
	return &dto, nil
}

func (s *impl) DeleteJob(ctx context.Context, accountID, tenantID int64, jobUUID string) error {
	j, err := s.resolveOwnedJob(ctx, jobUUID, accountID, tenantID)
	if err != nil {
		return err
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.SoftDeleteJob(ctx, tx, j.ID); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.cron.job_deleted", tenantID, map[string]any{
			"resource_kind": "agent_cron_job",
			"resource_uuid": j.UUID,
			"account_id":    accountID,
		})
		return nil
	}); err != nil {
		var e *apperr.Error
		if errors.As(err, &e) {
			return e
		}
		return apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "agent_cron_jobs:"+strconv.FormatInt(j.ID, 10))
	s.deleteRuntimeProjectionBestEffort(ctx, j)
	return nil
}

func (s *impl) Pause(ctx context.Context, accountID, tenantID int64, jobUUID string) (*JobDTO, error) {
	off := false
	return s.PatchJob(ctx, accountID, tenantID, jobUUID, PatchJobReq{Enabled: &off})
}

func (s *impl) Resume(ctx context.Context, accountID, tenantID int64, jobUUID string) (*JobDTO, error) {
	on := true
	return s.PatchJob(ctx, accountID, tenantID, jobUUID, PatchJobReq{Enabled: &on})
}

// Pausing the schedule alone does not prohibit an explicit manual run.
func manualRunStateError(j *domcron.Job) error {
	if j.Status == domcron.StatusArchived {
		return apperr.ErrForbidden.Withf("cron.job_archived")
	}
	if disabled, _ := j.Metadata["admin_disabled"].(bool); disabled {
		return apperr.New(apperr.Forbidden, ErrCodeCronResumeBlockedByAdmin)
	}
	if j.Status == domcron.StatusError {
		return apperr.New(apperr.PreconditionFailed, "cron.job_requires_resume")
	}
	return nil
}

func (s *impl) RunNow(ctx context.Context, accountID, tenantID int64, jobUUID string) (*RunDTO, error) {
	j, err := s.resolveOwnedJob(ctx, jobUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := manualRunStateError(j); err != nil {
		return nil, err
	}
	ag, err := s.jobAgent(ctx, j)
	if err != nil {
		return nil, err
	}
	if !cronAgentInScope(ag, accountID, tenantID) {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronAgentNotFound)
	}
	if err := s.assertAgentVisible(ctx, accountID, tenantID, ag.UUID); err != nil {
		return nil, err
	}
	if err := s.assertCronCapability(ctx, ag); err != nil {
		return nil, err
	}
	if err := s.localDesktopReady(ctx, j, ag); err != nil {
		return nil, err
	}
	acquired, err := s.repo.AcquireLock(ctx, j.ID, s.nodeID, s.cfg.LockTTL)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !acquired {
		return nil, apperr.New(apperr.PreconditionFailed, "cron.run_active")
	}
	defer s.repo.ReleaseLock(ctx, j.ID, s.nodeID)
	// Another request can change the job while readiness/lock acquisition waits.
	j, err = s.resolveOwnedJob(ctx, jobUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	if err := manualRunStateError(j); err != nil {
		return nil, err
	}
	active, err := s.repo.HasActiveRun(ctx, j.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if active {
		return nil, apperr.New(apperr.PreconditionFailed, "cron.run_active")
	}
	var run *domcron.Run
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		r, err := s.repo.CreateRun(ctx, tx, domcron.CreateRunInput{
			JobID: j.ID, TenantID: tenantID, AccountID: accountID, AgentID: j.AgentID,
			TriggerKind:     domcron.TriggerKindManual,
			PayloadSnapshot: j.Payload,
		})
		if err != nil {
			return err
		}
		run = r
		s.publishAuditTx(ctx, tx, "audit.cron.run_started", tenantID, map[string]any{
			"resource_kind": "agent_cron_run",
			"resource_uuid": r.UUID,
			"job_uuid":      j.UUID,
			"trigger_kind":  domcron.TriggerKindManual,
		})
		return nil
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 通知 executor 立即处理 (Phase A 走 goroutine + PickQueuedRunForUpdate).
	if s.runner != nil {
		go func() {
			bg := context.WithoutCancel(ctx)
			if _, err := s.ProcessQueuedRuns(bg); err != nil {
				s.logger.Warn(bg, "cron: process queued runs (manual) failed", "err", err)
			}
		}()
	}
	dto := toRunDTO(run, j.UUID, "")
	return &dto, nil
}

func (s *impl) HandleOpenClawCronDone(ctx context.Context, in OpenClawCronDoneInput) error {
	remoteJobID := strings.TrimSpace(in.JobID)
	if remoteJobID == "" && strings.Contains(in.SessionKey, ":cron:") {
		remoteJobID = strings.TrimSpace(in.SessionKey[strings.LastIndex(in.SessionKey, ":cron:")+len(":cron:"):])
	}
	if remoteJobID == "" {
		return apperr.ErrInvalidParams.Withf("openclaw cron-done jobId required")
	}
	binding, err := s.repo.GetRuntimeBindingByRemoteJobID(ctx, domcron.RuntimeAdapterOpenClaw, remoteJobID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return apperr.New(apperr.NotFound, ErrCodeCronJobNotFound).Withf("openclaw remote job %s not bound", remoteJobID)
		}
		return apperr.ErrInternal.Wrap(err)
	}
	j, err := s.repo.GetJobByID(ctx, binding.CronJobID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	convUUID, _ := j.Delivery["conversation_uuid"].(string)
	if strings.TrimSpace(convUUID) == "" {
		return apperr.New(apperr.NotFound, ErrCodeCronDeliveryConvNotFound).Withf("cron job delivery conversation missing")
	}
	if s.convs == nil || s.messages == nil {
		return apperr.ErrInternal.Withf("cron openclaw backchannel dependencies not wired")
	}
	conv, err := s.convs.GetByUUID(ctx, convUUID)
	if err != nil || conv == nil || conv.TenantID != j.TenantID || conv.AccountID != j.AccountID {
		return apperr.New(apperr.NotFound, ErrCodeCronDeliveryConvNotFound).Withf("conversation not found")
	}
	text := strings.TrimSpace(in.LastAssistant)
	status := domcron.RunStatusSucceeded
	errMsg := ""
	if !in.Success {
		status = domcron.RunStatusFailed
		errMsg = "openclaw cron run failed"
		if text != "" {
			errMsg = text
		}
	}
	msgUUID := ""
	if text != "" {
		agentID := j.AgentID
		msg, err := s.messages.Append(ctx, &dommsg.Message{
			TenantID:       j.TenantID,
			ConversationID: conv.ID,
			Role:           "agent",
			SenderAgentID:  &agentID,
			Blocks:         []map[string]any{{"kind": "markdown", "text": text}},
			Status:         "final",
			Final:          true,
			Metadata: map[string]any{
				"triggered_by":          "cron",
				"acting_as":             "openclaw_native_cron",
				"cron_job_uuid":         j.UUID,
				"openclaw_job_id":       remoteJobID,
				"openclaw_run_id":       strings.TrimSpace(in.RunID),
				"cron_owner_account_id": j.AccountID,
				"cron_agent_id":         j.AgentID,
			},
		})
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		msgUUID = msg.UUID
	}
	now := time.Now().UTC()
	var run *domcron.Run
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		r, err := s.repo.CreateRun(ctx, tx, domcron.CreateRunInput{
			JobID: j.ID, TenantID: j.TenantID, AccountID: j.AccountID, AgentID: j.AgentID,
			TriggerKind: domcron.TriggerKindCron,
			PayloadSnapshot: map[string]any{
				"source":          "openclaw_native_cron",
				"openclaw_job_id": remoteJobID,
				"openclaw_run_id": strings.TrimSpace(in.RunID),
			},
		})
		if err != nil {
			return err
		}
		run = r
		update := domcron.UpdateRunInput{
			Status:         &status,
			FinishedAt:     &now,
			ConversationID: &conv.ID,
		}
		if in.DurationMs > 0 {
			update.DurationMs = &in.DurationMs
		}
		if msgUUID != "" {
			update.MessageUUID = &msgUUID
		}
		if text != "" {
			update.Summary = &text
		}
		if errMsg != "" {
			update.ErrorMessage = &errMsg
		}
		if err := s.repo.UpdateRun(ctx, tx, r.ID, update); err != nil {
			return err
		}
		if status == domcron.RunStatusSucceeded {
			if err := s.repo.PatchJob(ctx, tx, j.ID, domcron.PatchJobInput{SetLastRun: &domcron.RunSummary{At: now, Status: status, Summary: text}}); err != nil {
				return err
			}
		}
		s.publishAuditTx(ctx, tx, "audit.cron.openclaw_run_finished", j.TenantID, map[string]any{
			"resource_kind":   "agent_cron_run",
			"resource_uuid":   r.UUID,
			"job_uuid":        j.UUID,
			"openclaw_job_id": remoteJobID,
		})
		return nil
	}); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if run != nil {
		run.Status = status
		run.FinishedAt = &now
		run.ConversationID = &conv.ID
		run.MessageUUID = msgUUID
		run.Summary = text
		s.publishRunEvent(ctx, j, run, EventCronRunFinished)
	}
	return nil
}

func (s *impl) HandleOpenClawCronEvents(ctx context.Context, in OpenClawCronEventsInput) (*OpenClawCronEventsResult, error) {
	res := &OpenClawCronEventsResult{Seen: len(in.Jobs)}
	op := strings.ToLower(strings.TrimSpace(in.Op))
	for _, job := range in.Jobs {
		remoteID := stringFromMap(job, "id", "jobId", "job_id")
		if remoteID == "" {
			res.Rejected++
			continue
		}
		binding, err := s.repo.GetRuntimeBindingByRemoteJobID(ctx, domcron.RuntimeAdapterOpenClaw, remoteID)
		if err != nil && !errors.Is(err, apperr.ErrNotFound) {
			res.Rejected++
			if s.logger != nil {
				s.logger.Warn(ctx, "cron openclaw event binding lookup failed", "remote_job_id", remoteID, "err", err)
			}
			continue
		}
		notFound := err != nil // 仅剩 ErrNotFound 一种
		// runtime 侧删除 (对话里让员工删 / jobs.json 条目消失) → 软删对应 bus 任务.
		// 只认显式 delete op; bootstrap 缺席不推断删除 (对齐 legacy ai-office 的安全对账策略).
		if op == "delete" {
			if notFound {
				res.Matched++ // 未绑定的 runtime 任务被删: 与 bus 无关, 直接认掉
				continue
			}
			if s.deleteJobFromRuntimeEvent(ctx, binding) {
				res.Deleted++
			} else {
				res.Rejected++
			}
			continue
		}
		// 收编: 数字员工在对话里用原生 cron 工具自建的任务 (sessionKey="agent:<uuid>:<conv>")
		// 在 bus 没有权威行; 补建 agent_cron_jobs + 绑定既有 remote job, 让它进「自动任务」
		// 列表并复用 cron-done 结果投递链路. bus 自己投影出去的任务不会带这种 sessionKey,
		// 且绑定先于事件写入, 不会误收编.
		if notFound {
			if s.adoptOpenClawRuntimeJob(ctx, in, job, remoteID) {
				res.Adopted++
			} else {
				res.Rejected++
			}
			continue
		}
		status := domcron.RuntimeSyncSynced
		msg := ""
		if openClawJobDrifted(binding.SourceSnapshot, job) {
			status = domcron.RuntimeSyncDrift
			msg = "cron.runtime_drift_detected"
			res.Drifted++
		} else {
			res.Matched++
		}
		_, err = s.repo.UpsertRuntimeBinding(ctx, domcron.UpsertRuntimeBindingInput{
			CronJobID: binding.CronJobID, TenantID: binding.TenantID, AccountID: binding.AccountID, AgentID: binding.AgentID,
			RuntimeEnvironmentID: binding.RuntimeEnvironmentID, AdapterKind: binding.AdapterKind,
			Framework: binding.Framework, RemoteJobID: binding.RemoteJobID,
			DesiredRevision: binding.DesiredRevision, RemoteRevision: binding.RemoteRevision,
			SyncStatus: status, LastSyncError: msg, SourceSnapshot: binding.SourceSnapshot,
		})
		if err != nil && s.logger != nil {
			s.logger.Warn(ctx, "cron openclaw event binding update failed", "remote_job_id", remoteID, "err", err)
		}
	}
	return res, nil
}

// adoptOpenClawRuntimeJob F08 收编桥: 数字员工在对话里用 OpenClaw 原生 cron 工具
// 自建的任务回流成 bus 权威行。
//
// 候选判定: jobs.json 条目 sessionKey="agent:<agent_uuid>:<conversation_uuid>" ——
// 这是 OpenClaw cron 工具在 agent 会话内创建任务时记录的形状; bus 自己投影出去的
// 任务 (cronprojection.Upsert) 不带它, 天然不是候选, 也避免了"投影刚建还没写绑定
// 就收到 events"的竞态误收编。
//
// 归属链: agentId/sessionKey 给出 agent + 会话 → 会话 owner 即任务 owner;
// pod 自报身份 (AI_OFFICE_ACCOUNT_ID/TENANT_ID) 仅做交叉校验, 不一致宁可拒
// (legacy ai-office 2026-05 #8421 跨账号串号事故的同款防御)。
//
// 校验与 CreateJob 同栈: 可见性 / capability / 限额 / 频率下限 (everyMs 低于下限
// 钳到下限而非丢弃); 落库后绑定既有 remote job, 再 best-effort 投影 normalize,
// 把规约后的 schedule 写回运行时, 双边一致。失败路径删除刚建行保证幂等。
func (s *impl) adoptOpenClawRuntimeJob(ctx context.Context, in OpenClawCronEventsInput, job map[string]any, remoteID string) bool {
	warn := func(reason string, err error) {
		if s.logger != nil {
			s.logger.Warn(ctx, "cron runtime job adopt skipped",
				"remote_job_id", remoteID, "reason", reason, "err", err)
		}
	}
	agentUUID, convUUID := parseAgentSessionKey(stringFromMap(job, "sessionKey", "session_key"))
	if agentUUID == "" || convUUID == "" {
		return false // 非 agent 会话自建形状: 不是收编候选 (维持 rejected 口径, 不告警)
	}
	if s.agents == nil || s.convs == nil || s.repo == nil {
		warn("deps_not_wired", nil)
		return false
	}
	ag, err := s.agents.GetByUUID(ctx, agentUUID)
	if err != nil || ag == nil {
		warn("agent_not_found", err)
		return false
	}
	if ag.RuntimeEnvironmentID == nil || *ag.RuntimeEnvironmentID == 0 {
		warn("agent_runtime_env_missing", nil)
		return false
	}
	conv, err := s.convs.GetByUUID(ctx, convUUID)
	if err != nil || conv == nil {
		warn("conversation_not_found", err)
		return false
	}
	if conv.TenantID != ag.TenantID {
		warn("conversation_tenant_mismatch", nil)
		return false
	}
	tenantID, accountID := ag.TenantID, conv.AccountID
	if v := int64FromText(in.AccountIDText); v > 0 && v != accountID {
		warn("pod_account_mismatch", nil)
		return false
	}
	if v := int64FromText(in.TenantIDText); v > 0 && v != tenantID {
		warn("pod_tenant_mismatch", nil)
		return false
	}
	payload, _ := job["payload"].(map[string]any)
	prompt := strings.TrimSpace(stringFromMap(payload, "message", "text"))
	if prompt == "" {
		warn("payload_empty", nil)
		return false
	}
	// OpenClaw delivery.mode=announce 的 payload 是"要播给用户的提醒文案"而非给
	// agent 的指令; 收编后由 bus 喂给 agent 执行, 裸文案会让 agent 随机沉默
	// (2026-06-13 实测: 饮水提醒 final 为空 → WuKong skip → 无任何推送)。
	// 包一层"原样转达"指令, 保住 announce 语义。
	if deliv, _ := job["delivery"].(map[string]any); deliv != nil {
		if strings.EqualFold(strings.TrimSpace(stringFromMap(deliv, "mode")), "announce") {
			prompt = "请把下面这条提醒原样转达给用户，不要追问、不要扩写：\n" + prompt
		}
	}
	if len(prompt) > s.cfg.PayloadMaxBytes {
		warn("payload_too_large", nil)
		return false
	}
	schedMap, _ := job["schedule"].(map[string]any)
	// tz 先于换算解析: every+anchorMs 折算成"几点几分"依赖任务时区。
	tz := s.resolveJobTimezone(ctx, "", tenantID)
	tzLoc, tzErr := time.LoadLocation(tz)
	if tzErr != nil {
		tzLoc = time.UTC
	}
	expr, ok := openClawScheduleToCron(schedMap, s.cfg.MinFrequency, tzLoc)
	if !ok {
		warn("schedule_unmappable", nil)
		return false
	}
	sched, loc, err := s.parseCron(expr, tz)
	if err != nil {
		warn("schedule_invalid", err)
		return false
	}
	if err := s.assertAgentVisible(ctx, accountID, tenantID, ag.UUID); err != nil {
		warn("agent_not_visible", err)
		return false
	}
	if err := s.assertCronCapability(ctx, ag); err != nil {
		warn("capability_gated", err)
		return false
	}
	if err := assertJobLimits(ctx, s.repo, tenantID, accountID, s.cfg.AccountJobLimit, s.cfg.TenantJobLimit); err != nil {
		warn("job_limit_reached", err)
		return false
	}
	if err := s.assertPlanJobLimit(ctx, tenantID); err != nil {
		warn("plan_job_limit_reached", err)
		return false
	}
	delivery := map[string]any{"conversation_uuid": convUUID}
	_, deliveryKind, err := s.resolveDelivery(ctx, accountID, tenantID, ag.ID, delivery)
	if err != nil || deliveryKind == "" {
		warn("delivery_unresolvable", err)
		return false
	}
	name := strings.TrimSpace(stringFromMap(job, "name"))
	if name == "" {
		name = "对话创建的定时任务"
	}
	enabled := true
	if v, ok := job["enabled"].(bool); ok {
		enabled = v
	}
	next := sched.Next(time.Now().In(loc))
	// 防双触发: 任务只能有一个调度方。投影模式 → runtime 原生 cron 自动触发, bus 只记账;
	// 投影禁用 (dev) → bus 接管调度, 收编后还要把 runtime 原生那份删掉 (见下), 否则
	// bus 跑一份 + OpenClaw 自己再跑一份 = 重复推送。
	schedKind := domcron.SchedulerRuntime
	if s.cfg.DisableRuntimeProjection {
		schedKind = domcron.SchedulerBus
	}
	var created *domcron.Job
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		j, err := s.repo.CreateJob(ctx, tx, domcron.CreateJobInput{
			TenantID: tenantID, AccountID: accountID, AgentID: ag.ID,
			Name: name, Description: strings.TrimSpace(stringFromMap(job, "description")),
			ScheduleCron: expr, Timezone: tz,
			Payload: map[string]any{"prompt": prompt}, Delivery: delivery,
			NextRunAt: &next, DeliveryKind: deliveryKind,
			SchedulerKind: schedKind,
		})
		if err != nil {
			return err
		}
		if !enabled {
			off := false
			if err := s.repo.PatchJob(ctx, tx, j.ID, domcron.PatchJobInput{Enabled: &off}); err != nil {
				return err
			}
			j.Enabled = false
		}
		s.publishAuditTx(ctx, tx, "audit.cron.job_adopted", tenantID, map[string]any{
			"resource_kind": "agent_cron_job",
			"resource_uuid": j.UUID,
			"account_id":    accountID,
			"agent_uuid":    ag.UUID,
			"remote_job_id": remoteID,
			"source":        "openclaw_agent_tool",
		})
		created = j
		return nil
	}); err != nil {
		warn("create_failed", err)
		return false
	}
	framework, ferr := s.runtimeFramework(ctx, ag.RuntimeEnvironmentID)
	if ferr != nil || framework == "" {
		framework = "openclaw"
	}
	now := time.Now().UTC()
	binding, err := s.repo.UpsertRuntimeBinding(ctx, domcron.UpsertRuntimeBindingInput{
		CronJobID: created.ID, TenantID: tenantID, AccountID: accountID, AgentID: ag.ID,
		RuntimeEnvironmentID: *ag.RuntimeEnvironmentID, AdapterKind: domcron.RuntimeAdapterOpenClaw,
		Framework: framework, RemoteJobID: remoteID,
		DesiredRevision: created.UpdatedAt.UTC().Format(time.RFC3339Nano),
		SyncStatus:      domcron.RuntimeSyncSynced, SourceSnapshot: job, LastSyncedAt: &now,
	})
	if err != nil {
		// 绑定是收编的幂等键: 写不进去必须把刚建的行删掉, 否则下一轮 events 重复收编.
		warn("binding_upsert_failed_rollback", err)
		_ = s.runTx(ctx, func(tx pgx.Tx) error { return s.repo.SoftDeleteJob(ctx, tx, created.ID) })
		return false
	}
	if binding != nil && binding.CronJobID != created.ID {
		// 并发 upsert 已经收编过同一个 remote job。保留先到的权威行, 回滚本次刚建的重复行。
		warn("binding_already_adopted_rollback_duplicate", nil)
		_ = s.runTx(ctx, func(tx pgx.Tx) error { return s.repo.SoftDeleteJob(ctx, tx, created.ID) })
		return true
	}
	s.notify(ctx, "agent_cron_jobs:"+strconv.FormatInt(created.ID, 10))
	if s.cfg.DisableRuntimeProjection {
		// bus 接管调度: 把 runtime 原生那份**停用而非删除** (enabled=false)。
		//  - 停用 → 原生 cron 不触发, 防双触发 (bus 一份 + OpenClaw 一份);
		//  - 保留 → 用户在对话里说"取消任务"时 agent 仍能找到并删除它,
		//    删除经 cron-events op=delete 回流, bus 同步软删本行 (取消闭环)。
		// best-effort: 失败不阻塞收编 (原生份会双触发, 但 events 对账可重试)。
		if projector := s.projectorFor(domcron.RuntimeAdapterOpenClaw); projector != nil {
			if _, uerr := projector.Upsert(ctx, RuntimeProjectionInput{
				JobID: created.ID, TenantID: tenantID, AccountID: accountID, AgentID: ag.ID,
				AgentUUID: ag.UUID, RuntimeEnvironmentID: *ag.RuntimeEnvironmentID,
				RemoteJobID: remoteID, Name: created.Name, Description: created.Description,
				ScheduleCron: created.ScheduleCron, Timezone: created.Timezone, Prompt: prompt,
				Enabled: false, Status: created.Status,
				Revision: created.UpdatedAt.UTC().Format(time.RFC3339Nano),
			}); uerr != nil && s.logger != nil {
				s.logger.Warn(ctx, "cron adopt: disable runtime native job failed",
					"remote_job_id", remoteID, "err", uerr)
			}
		}
	} else {
		s.projectJobBestEffort(ctx, created, ag.UUID)
	}
	if s.logger != nil {
		s.logger.Info(ctx, "cron runtime job adopted",
			"job_uuid", created.UUID, "remote_job_id", remoteID,
			"agent_uuid", ag.UUID, "conversation_uuid", convUUID,
			"schedule_cron", expr, "scheduler_kind", schedKind)
	}
	return true
}

// deleteJobFromRuntimeEvent runtime 侧删除回流 (op=delete): 软删对应 bus 行。
// 不走 DeleteJob —— 那会再反向投影一次 cron.remove, 远端已不存在, 徒增一条注定
// 失败的投影错误绑定。
func (s *impl) deleteJobFromRuntimeEvent(ctx context.Context, binding *domcron.RuntimeBinding) bool {
	j, err := s.repo.GetJobByID(ctx, binding.CronJobID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return true // 已删: 幂等认掉
		}
		if s.logger != nil {
			s.logger.Warn(ctx, "cron runtime delete event: job lookup failed",
				"cron_job_id", binding.CronJobID, "err", err)
		}
		return false
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.SoftDeleteJob(ctx, tx, j.ID); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.cron.job_deleted", j.TenantID, map[string]any{
			"resource_kind": "agent_cron_job",
			"resource_uuid": j.UUID,
			"account_id":    j.AccountID,
			"source":        "openclaw_runtime_event",
		})
		return nil
	}); err != nil {
		if s.logger != nil {
			s.logger.Warn(ctx, "cron runtime delete event: soft delete failed", "job_uuid", j.UUID, "err", err)
		}
		return false
	}
	// 绑定一并软删, 否则孤儿绑定让投影 reconciler 每分钟 job lookup not found
	// (2026-06-13 实测 probe-delete-roundtrip 遗留)。失败不回滚 job 删除: 下次
	// 事件幂等路径还会再试。
	if err := s.repo.SoftDeleteRuntimeBindingByJob(ctx, j.ID); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "cron runtime delete event: binding soft delete failed", "job_uuid", j.UUID, "err", err)
	}
	s.notify(ctx, "agent_cron_jobs:"+strconv.FormatInt(j.ID, 10))
	return true
}

// parseAgentSessionKey 解析 OpenClaw cron 工具在 agent 会话里自建任务时记录的
// sessionKey ("agent:<agent_uuid>:<conversation_uuid>"); 形状不符返回空串。
func parseAgentSessionKey(key string) (agentUUID, convUUID string) {
	parts := strings.SplitN(strings.TrimSpace(key), ":", 3)
	if len(parts) != 3 || parts[0] != "agent" {
		return "", ""
	}
	a, c := strings.TrimSpace(parts[1]), strings.TrimSpace(parts[2])
	if a == "" || c == "" || strings.Contains(c, ":") {
		return "", ""
	}
	return a, c
}

// openClawScheduleToCron 把 OpenClaw 原生 schedule 规约成 bus schedule_cron。
//   - kind=cron  → expr 原样 (合法性 / 频率下限交给 parseCron 把关).
//   - kind=every → everyMs 先钳到平台频率下限 (agent 自由创建不能因低于下限而
//     掉进黑洞), 再映射: <60min 取整到 60 的因数分钟 ("*/N * * * *", 间隔均匀,
//     整点边界不会踩出低于下限的碎间隔); 整/进位小时 "M */H * * *";
//     ≥24h "M H */N * *"。
//   - anchorMs (OpenClaw every 的纪元锚点, 触发时刻 t ≡ anchorMs mod everyMs):
//     小时/天级映射用它在 loc 时区折算"几点几分", 保持与 runtime 原生触发点一致
//     (2026-06-13 实测: every 1d anchor 3000000 原生 nextRun=08:50+08, 旧映射
//     硬编码 09:00 丢锚点)。无 anchor 时沿用旧默认 (分钟 0 / 天级 09:00)。
func openClawScheduleToCron(sched map[string]any, minFloor time.Duration, loc *time.Location) (string, bool) {
	if sched == nil {
		return "", false
	}
	if loc == nil {
		loc = time.UTC
	}
	switch strings.ToLower(stringFromMap(sched, "kind")) {
	case "cron":
		expr := stringFromMap(sched, "expr")
		return expr, expr != ""
	case "every":
		ms := int64FromMap(sched, "everyMs", "every_ms")
		if ms <= 0 {
			return "", false
		}
		// 任一触发时刻在 loc 时区的时分 (everyMs 为整天倍数时各次触发时分恒定;
		// 整小时倍数时分钟恒定)。anchorMs 缺省时 hasAnchor=false 走旧默认。
		anchor := int64FromMap(sched, "anchorMs", "anchor_ms")
		hasAnchor := anchor > 0
		anchorAt := time.UnixMilli(anchor).In(loc)
		d := time.Duration(ms) * time.Millisecond
		if d < minFloor {
			d = minFloor
		}
		mins := int64((d + time.Minute - 1) / time.Minute)
		switch {
		case mins < 60:
			for _, n := range []int64{1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30} {
				if mins <= n {
					if n == 1 {
						return "* * * * *", true
					}
					return fmt.Sprintf("*/%d * * * *", n), true
				}
			}
			return "0 * * * *", true
		case mins < 24*60:
			h := (mins + 59) / 60
			minute := int64(0)
			if hasAnchor {
				minute = int64(anchorAt.Minute())
			}
			if h <= 1 {
				return fmt.Sprintf("%d * * * *", minute), true
			}
			if h >= 24 {
				if hasAnchor {
					return fmt.Sprintf("%d %d * * *", minute, anchorAt.Hour()), true
				}
				return "0 9 * * *", true
			}
			return fmt.Sprintf("%d */%d * * *", minute, h), true
		default:
			days := (mins + 24*60 - 1) / (24 * 60)
			hour, minute := int64(9), int64(0)
			if hasAnchor {
				hour, minute = int64(anchorAt.Hour()), int64(anchorAt.Minute())
			}
			if days <= 1 {
				return fmt.Sprintf("%d %d * * *", minute, hour), true
			}
			return fmt.Sprintf("%d %d */%d * *", minute, hour, days), true
		}
	}
	return "", false
}

// int64FromMap 容忍 JSON 解码的多种数值形态 (float64 / 字符串数字 / 整型)。
func int64FromMap(m map[string]any, keys ...string) int64 {
	for _, k := range keys {
		switch v := m[k].(type) {
		case float64:
			if v > 0 {
				return int64(v)
			}
		case int64:
			if v > 0 {
				return v
			}
		case int:
			if v > 0 {
				return int64(v)
			}
		case json.Number:
			if n, err := v.Int64(); err == nil && n > 0 {
				return n
			}
		case string:
			if n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil && n > 0 {
				return n
			}
		}
	}
	return 0
}

func int64FromText(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func (s *impl) HandleCronCommand(ctx context.Context, in CronCommandInput) (*CronCommandResult, error) {
	if in.TenantID <= 0 || in.AccountID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id/account_id required")
	}
	op := strings.ToLower(strings.TrimSpace(in.Operation))
	switch op {
	case "create":
		job, err := s.CreateJob(ctx, in.AccountID, in.TenantID, CreateJobReq{
			Name: in.Name, Description: in.Description, AgentUUID: in.AgentUUID,
			ConversationUUID: in.ConversationUUID, ScheduleCron: in.ScheduleCron,
			Timezone: in.Timezone, Prompt: in.Prompt,
		})
		if err != nil {
			return nil, err
		}
		return &CronCommandResult{Operation: op, Job: job}, nil
	case "update":
		if strings.TrimSpace(in.JobUUID) == "" {
			return nil, apperr.ErrInvalidParams.Withf("job_uuid required")
		}
		req := PatchJobReq{}
		if v, ok := in.Patch["name"].(string); ok {
			req.Name = &v
		}
		if v, ok := in.Patch["description"].(string); ok {
			req.Description = &v
		}
		if v, ok := in.Patch["schedule_cron"].(string); ok {
			req.ScheduleCron = &v
		}
		if v, ok := in.Patch["timezone"].(string); ok {
			req.Timezone = &v
		}
		if v, ok := in.Patch["prompt"].(string); ok {
			req.Prompt = &v
		}
		if v, ok := in.Patch["conversation_uuid"].(string); ok {
			req.ConversationUUID = &v
		}
		if v, ok := in.Patch["enabled"].(bool); ok {
			req.Enabled = &v
		}
		job, err := s.PatchJob(ctx, in.AccountID, in.TenantID, in.JobUUID, req)
		if err != nil {
			return nil, err
		}
		return &CronCommandResult{Operation: op, Job: job}, nil
	case "delete":
		if strings.TrimSpace(in.JobUUID) == "" {
			return nil, apperr.ErrInvalidParams.Withf("job_uuid required")
		}
		if err := s.DeleteJob(ctx, in.AccountID, in.TenantID, in.JobUUID); err != nil {
			return nil, err
		}
		return &CronCommandResult{Operation: op, Deleted: true}, nil
	case "pause":
		job, err := s.Pause(ctx, in.AccountID, in.TenantID, in.JobUUID)
		if err != nil {
			return nil, err
		}
		return &CronCommandResult{Operation: op, Job: job}, nil
	case "resume":
		job, err := s.Resume(ctx, in.AccountID, in.TenantID, in.JobUUID)
		if err != nil {
			return nil, err
		}
		return &CronCommandResult{Operation: op, Job: job}, nil
	default:
		return nil, apperr.ErrInvalidParams.Withf("operation must be create/update/delete/pause/resume")
	}
}

func stringFromMap(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok && strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func openClawJobDrifted(desired map[string]any, actual map[string]any) bool {
	if len(desired) == 0 || len(actual) == 0 {
		return false
	}
	if want := strings.TrimSpace(anyString(desired["name"])); want != "" && want != strings.TrimSpace(anyString(actual["name"])) {
		return true
	}
	if want, ok := desired["enabled"].(bool); ok {
		if got, ok := actual["enabled"].(bool); ok && got != want {
			return true
		}
	}
	wantCron := strings.TrimSpace(anyString(desired["schedule_cron"]))
	if wantCron == "" {
		return false
	}
	if sched, ok := actual["schedule"].(map[string]any); ok {
		return strings.TrimSpace(anyString(sched["expr"])) != "" && strings.TrimSpace(anyString(sched["expr"])) != wantCron
	}
	return false
}

func anyString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func (s *impl) ListRunsForJob(ctx context.Context, accountID, tenantID int64, jobUUID, before string, limit int) ([]RunDTO, error) {
	j, err := s.resolveOwnedJob(ctx, jobUUID, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	rows, err := s.repo.ListRuns(ctx, domcron.ListRunsFilter{
		TenantID: tenantID, AccountID: accountID, JobID: j.ID,
		Limit: limit, BeforeUUID: before,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]RunDTO, 0, len(rows))
	for i := range rows {
		convUUID := s.lookupConvUUID(ctx, rows[i].ConversationID)
		out = append(out, toRunDTO(&rows[i], j.UUID, convUUID))
	}
	return out, nil
}

func (s *impl) ListRuns(ctx context.Context, accountID, tenantID int64, before string, limit int) ([]RunDTO, error) {
	rows, err := s.repo.ListRuns(ctx, domcron.ListRunsFilter{
		TenantID: tenantID, AccountID: accountID,
		Limit: limit, BeforeUUID: before,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]RunDTO, 0, len(rows))
	for i := range rows {
		// 拿 job uuid (best-effort).
		var jobUUID string
		row := s.pool.QueryRow(ctx, `SELECT uuid::text FROM agent_cron_jobs WHERE id=$1`, rows[i].JobID)
		_ = row.Scan(&jobUUID)
		convUUID := s.lookupConvUUID(ctx, rows[i].ConversationID)
		out = append(out, toRunDTO(&rows[i], jobUUID, convUUID))
	}
	return out, nil
}

func (s *impl) GetRun(ctx context.Context, accountID, tenantID int64, runUUID string) (*RunDTO, error) {
	r, err := s.repo.GetRunByUUID(ctx, runUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeCronRunNotFound).Withf("run %s not found", runUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if r.TenantID != tenantID || r.AccountID != accountID {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronRunNotFound).Withf("run %s not found", runUUID)
	}
	var jobUUID string
	row := s.pool.QueryRow(ctx, `SELECT uuid::text FROM agent_cron_jobs WHERE id=$1`, r.JobID)
	_ = row.Scan(&jobUUID)
	convUUID := s.lookupConvUUID(ctx, r.ConversationID)
	dto := toRunDTO(r, jobUUID, convUUID)
	return &dto, nil
}

func (s *impl) OpenChat(ctx context.Context, accountID, tenantID int64, runUUID string) (*OpenChatResp, error) {
	dto, err := s.GetRun(ctx, accountID, tenantID, runUUID)
	if err != nil {
		return nil, err
	}
	if dto.ConversationUUID == "" {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronRunNotFound).Withf("run %s not bound to conversation yet", runUUID)
	}
	return &OpenChatResp{ConversationUUID: dto.ConversationUUID, MessageUUID: dto.MessageUUID}, nil
}

func (s *impl) lookupConvUUID(ctx context.Context, convID *int64) string {
	if convID == nil {
		return ""
	}
	var u string
	_ = s.pool.QueryRow(ctx, `SELECT uuid::text FROM conversations WHERE id=$1`, *convID).Scan(&u)
	return u
}

// =====================================================
// Admin API
// =====================================================

// DryRunConflict · 单条不再满足 Bus-scheduled capability gating 但仍 enabled 的 row.
type DryRunConflict struct {
	JobUUID   string `json:"job_uuid"`
	AccountID int64  `json:"account_id"`
	TenantID  int64  `json:"tenant_id"`
	AgentUUID string `json:"agent_uuid"`
	Name      string `json:"name"`
	Reason    string `json:"reason"`
	NextRunAt string `json:"next_run_at,omitempty"`
}

// DryRunReport · M9G dry-run 输出. **不**修改任何 row, 只列举.
type DryRunReport struct {
	Total     int              `json:"total_enabled"`
	Conflicts []DryRunConflict `json:"conflicts"`
}

// AdminCapabilityDryRun 详见 Service.AdminCapabilityDryRun 注释.
func (s *impl) AdminCapabilityDryRun(ctx context.Context, limit int) (*DryRunReport, error) {
	if limit <= 0 || limit > 5000 {
		limit = 1000
	}
	jobs, err := s.repo.ListEnabledJobs(ctx, limit)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := buildDryRunReport(ctx, jobs, dryRunDeps{
		agents:       s.agents,
		fetchUUID:    s.fetchAgentUUID,
		assertGating: s.assertCronCapability,
	})
	if s.logger != nil {
		s.logger.Info(ctx, "cron capability dry-run done",
			"total", out.Total, "conflicts", len(out.Conflicts))
	}
	return out, nil
}

// dryRunDeps · 抽出便于单测注入 (Codex 第二轮 P1 闭环).
type dryRunDeps struct {
	agents       AgentLookup
	fetchUUID    func(ctx context.Context, agentID int64) (string, error)
	assertGating func(ctx context.Context, ag *domagent.DigitalEmployee) error
}

// buildDryRunReport · 纯函数: jobs → DryRunReport. 单测可直接传 fake deps.
func buildDryRunReport(ctx context.Context, jobs []domcron.Job, deps dryRunDeps) *DryRunReport {
	out := &DryRunReport{Total: len(jobs), Conflicts: make([]DryRunConflict, 0)}
	if deps.agents == nil {
		return out
	}
	for i := range jobs {
		agentUUID := ""
		if deps.fetchUUID != nil {
			agentUUID, _ = deps.fetchUUID(ctx, jobs[i].AgentID)
		}
		var ag *domagent.DigitalEmployee
		if agentUUID != "" {
			ag, _ = deps.agents.GetByUUID(ctx, agentUUID)
		}
		if ag == nil {
			out.Conflicts = append(out.Conflicts, DryRunConflict{
				JobUUID:   jobs[i].UUID,
				AccountID: jobs[i].AccountID,
				TenantID:  jobs[i].TenantID,
				AgentUUID: agentUUID,
				Name:      jobs[i].Name,
				Reason:    "agent not found (likely soft-deleted)",
			})
			continue
		}
		if err := deps.assertGating(ctx, ag); err != nil {
			next := ""
			if jobs[i].NextRunAt != nil {
				next = jobs[i].NextRunAt.UTC().Format("2006-01-02T15:04:05Z07:00")
			}
			out.Conflicts = append(out.Conflicts, DryRunConflict{
				JobUUID:   jobs[i].UUID,
				AccountID: jobs[i].AccountID,
				TenantID:  jobs[i].TenantID,
				AgentUUID: ag.UUID,
				Name:      jobs[i].Name,
				Reason:    err.Error(),
				NextRunAt: next,
			})
		}
	}
	return out
}

func (s *impl) AdminListTenantJobs(ctx context.Context, tenantID int64) ([]JobDTO, error) {
	rows, err := s.repo.ListTenantJobs(ctx, tenantID, 200)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 批量回填显示名 (agent uuid/name + owner display name); 失败仅缺显示名, 不阻塞列表.
	if err := s.repo.FillJobDisplayMeta(ctx, rows); err != nil && s.logger != nil {
		s.logger.Warn(ctx, "cron admin list: fill display meta failed", "err", err)
	}
	out := make([]JobDTO, 0, len(rows))
	for i := range rows {
		uuid := rows[i].AgentUUID
		if uuid == "" {
			uuid, _ = s.fetchAgentUUID(ctx, rows[i].AgentID)
		}
		dto := s.toJobDTO(&rows[i], uuid)
		// admin 视图不暴露 payload 详情 (仅 metadata).
		dto.Payload = nil
		dto.OwnerDisplayName = rows[i].OwnerDisplayName
		dto.AgentName = rows[i].AgentName
		out = append(out, dto)
	}
	return out, nil
}

func (s *impl) AdminForceDisable(ctx context.Context, tenantID, actorID int64, jobUUID string) (*JobDTO, error) {
	j, err := s.repo.GetJobByUUID(ctx, jobUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeCronJobNotFound).Withf("job %s not found", jobUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if j.TenantID != tenantID {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronJobNotFound).Withf("job %s not found", jobUUID)
	}
	off := false
	paused := domcron.StatusPaused
	pauseReason := domcron.PauseReasonAdminDisabled
	in := domcron.PatchJobInput{
		Enabled:      &off,
		Status:       &paused,
		SetAdminFlag: true,
		// M 返修 · F08 §5.1 / R10: 同时写 pause_reason 列 (老实现只动 metadata,
		// admin 列表 / executor 看不到原因, 排查只能查 audit log).
		PauseReason: &pauseReason,
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.PatchJob(ctx, tx, j.ID, in); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.cron.force_disabled", tenantID, map[string]any{
			"resource_kind":     "agent_cron_job",
			"resource_uuid":     j.UUID,
			"actor_id":          actorID,
			"target_account_id": j.AccountID,
		})
		return nil
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "agent_cron_jobs:"+strconv.FormatInt(j.ID, 10))
	updated, _ := s.repo.GetJobByID(ctx, j.ID)
	uuid, _ := s.fetchAgentUUID(ctx, updated.AgentID)
	dto := s.toJobDTO(updated, uuid)
	s.publishJobEvent(ctx, updated, EventCronJobUpdated)
	return &dto, nil
}

// buildClearAdminFlagPatch · M 返修 · admin "清除强停标" 的 patch 计算 (纯函数, 便于单测).
//
// 行为:
//   - 永远清 metadata.admin_disabled (兼容 m9 老路径只看 metadata 的客户端).
//   - 仅当当前 j.PauseReason='admin_disabled' 时同步清 pause_reason 列;
//     **不**误清 owner_inactive / quota_exceeded / user_paused (这些由其他路径维护).
//   - **不**自动 resume (不动 Enabled / Status) — F08 §5.1 决议: 清标后所有者自行恢复.
func buildClearAdminFlagPatch(j *domcron.Job) domcron.PatchJobInput {
	in := domcron.PatchJobInput{ClearAdminFlag: true}
	if j != nil && j.PauseReason == domcron.PauseReasonAdminDisabled {
		in.ClearPauseReason = true
	}
	return in
}

func (s *impl) AdminClearAdminFlag(ctx context.Context, tenantID, actorID int64, jobUUID string) (*JobDTO, error) {
	j, err := s.repo.GetJobByUUID(ctx, jobUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, apperr.New(apperr.NotFound, ErrCodeCronJobNotFound).Withf("job %s not found", jobUUID)
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if j.TenantID != tenantID {
		return nil, apperr.New(apperr.NotFound, ErrCodeCronJobNotFound).Withf("job %s not found", jobUUID)
	}
	in := buildClearAdminFlagPatch(j)
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.PatchJob(ctx, tx, j.ID, in); err != nil {
			return err
		}
		s.publishAuditTx(ctx, tx, "audit.cron.admin_flag_cleared", tenantID, map[string]any{
			"resource_kind": "agent_cron_job",
			"resource_uuid": j.UUID,
			"actor_id":      actorID,
		})
		return nil
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	s.notify(ctx, "agent_cron_jobs:"+strconv.FormatInt(j.ID, 10))
	updated, _ := s.repo.GetJobByID(ctx, j.ID)
	uuid, _ := s.fetchAgentUUID(ctx, updated.AgentID)
	dto := s.toJobDTO(updated, uuid)
	return &dto, nil
}

// =====================================================
// SSE
// =====================================================

func (s *impl) publishJobEvent(ctx context.Context, j *domcron.Job, kind string) {
	if s.events == nil || j == nil {
		return
	}
	payload := map[string]any{
		"kind":     kind,
		"job_uuid": j.UUID,
		"enabled":  j.Enabled,
		"status":   j.Status,
		"ts":       time.Now().UTC().Format(time.RFC3339),
	}
	if j.NextRunAt != nil {
		payload["next_run_at"] = j.NextRunAt.UTC().Format(time.RFC3339)
	}
	if err := s.events.PublishAccountEvent(ctx, j.AccountID, j.TenantID, payload); err != nil {
		s.logger.Warn(ctx, "cron: publish job event failed", "kind", kind, "err", err)
	}
}

func (s *impl) publishRunEvent(ctx context.Context, j *domcron.Job, r *domcron.Run, kind string) {
	if s.events == nil {
		return
	}
	payload := map[string]any{
		"kind":     kind,
		"job_uuid": j.UUID,
		"run_uuid": r.UUID,
		"status":   r.Status,
		"trigger":  r.TriggerKind,
		"ts":       time.Now().UTC().Format(time.RFC3339),
	}
	convUUID := s.lookupConvUUID(ctx, r.ConversationID)
	if convUUID != "" {
		payload["conversation_uuid"] = convUUID
	}
	if r.MessageUUID != "" {
		payload["message_uuid"] = r.MessageUUID
	}
	if r.Summary != "" {
		payload["summary"] = r.Summary
	}
	if r.ErrorMessage != "" {
		payload["error_message"] = r.ErrorMessage
	}
	if err := s.events.PublishAccountEvent(ctx, j.AccountID, j.TenantID, payload); err != nil {
		s.logger.Warn(ctx, "cron: publish run event failed", "kind", kind, "err", err)
	}
	// 2026-08-25 用户拍板: 定时任务执行结果(成功/失败)都不推送系统通知/未读——
	// 结果本身进对话历史 + 任务卡片状态即可, 通知只会打扰用户。仍然
	// PublishAccountEvent(SSE), 保留任务页/对话页的实时刷新。
}

// =====================================================
// Stale-running reaper (Codex P1#3)
// =====================================================

func (s *impl) ReapStaleRuns(ctx context.Context) (int, error) {
	if s.cfg.RunStaleTimeout <= 0 {
		return 0, nil
	}
	cutoff := time.Now().Add(-s.cfg.RunStaleTimeout)
	stale, err := s.repo.ReapStaleRunningRuns(ctx, cutoff, ErrCodeCronStaleRunFailed)
	if err != nil {
		s.logger.Warn(ctx, "cron: reap stale runs failed", "err", err)
		return 0, err
	}
	for i := range stale {
		r := &stale[i]
		s.bestEffortAudit(ctx, "audit.cron.stale_run_failed", r.TenantID, map[string]any{
			"resource_kind": "agent_cron_run",
			"resource_uuid": r.UUID,
			"job_id":        r.JobID,
			"started_at":    r.StartedAt.UTC().Format(time.RFC3339),
			"duration_ms":   r.DurationMs,
			"error_code":    ErrCodeCronStaleRunFailed,
		})
		// 同时 +1 consecutive_failures (与正常失败一致); 阈值判定借 GetJobByID 拿 j.
		j, jerr := s.repo.GetJobByID(ctx, r.JobID)
		if jerr != nil || j == nil {
			continue
		}
		summary := &domcron.RunSummary{At: time.Now(), Status: domcron.RunStatusFailed, Summary: ""}
		patch := domcron.PatchJobInput{IncFailures: true, SetLastRun: summary}
		if j.ConsecutiveFailures+1 >= j.FailureThreshold {
			errState := domcron.StatusError
			patch.Status = &errState
			disabled := false
			patch.Enabled = &disabled
		}
		_ = s.runTx(ctx, func(tx pgx.Tx) error {
			return s.repo.PatchJob(ctx, tx, j.ID, patch)
		})
		// SSE 终态.
		s.publishRunEvent(ctx, j, r, EventCronRunFinished)
	}
	return len(stale), nil
}

// =====================================================
// Dispatcher (DispatchInterval 扫描 + 抢锁 + 创建 run + 重算 next_run_at)
// =====================================================

func (s *impl) DispatchTick(ctx context.Context) (int, error) {
	// 不用 now+DispatchInterval 前瞻: 前瞻会让任务在 next_run_at 之前提前触发
	// (最多提前一个 DispatchInterval)。这里只挑 next_run_at<=now 的行, 触发时刻
	// 只会等于或略晚于（最多晚一个 DispatchInterval）用户设定的时间, 不会早。
	horizon := time.Now()
	jobs, err := s.repo.DueJobs(ctx, horizon, 100)
	if err != nil {
		return 0, fmt.Errorf("due jobs: %w", err)
	}
	dispatched := 0
	for i := range jobs {
		j := &jobs[i]
		acquired, err := s.repo.AcquireLock(ctx, j.ID, s.nodeID, s.cfg.LockTTL)
		if err != nil {
			s.logger.Warn(ctx, "cron: acquire lock failed", "job_uuid", j.UUID, "err", err)
			continue
		}
		if !acquired {
			continue
		}
		// The original due list can be stale after another node releases this job lock.
		current, err := s.repo.GetJobByID(ctx, j.ID)
		if err != nil || !current.Enabled || current.Status != domcron.StatusActive || current.NextRunAt == nil || current.NextRunAt.After(horizon) {
			_ = s.repo.ReleaseLock(ctx, j.ID, s.nodeID)
			continue
		}
		j = current
		// 抢锁成功 → concurrent_policy=forbid 时若已有 queued/running 直接 skip.
		if j.ConcurrentPolicy == "forbid" {
			active, err := s.repo.HasActiveRun(ctx, j.ID)
			if err != nil || active {
				s.bestEffortAudit(ctx, "audit.cron.misfire_skipped", j.TenantID, map[string]any{
					"resource_kind": "agent_cron_job",
					"resource_uuid": j.UUID,
					"reason":        "concurrent_policy=forbid",
				})
				_ = s.repo.ReleaseLock(ctx, j.ID, s.nodeID)
				continue
			}
		}
		// 创建 run + 重算 next_run_at + 释放锁.
		next, nerr := s.computeNextRun(j)
		if nerr != nil {
			s.logger.Warn(ctx, "cron: compute next_run_at failed", "job_uuid", j.UUID, "err", nerr)
			disabled, invalid := false, domcron.StatusError
			if err := s.runTx(ctx, func(tx pgx.Tx) error {
				if err := s.repo.PatchJob(ctx, tx, j.ID, domcron.PatchJobInput{Enabled: &disabled, Status: &invalid}); err != nil {
					return err
				}
				s.publishAuditTx(ctx, tx, "audit.cron.schedule_invalid", j.TenantID, map[string]any{
					"resource_kind": "agent_cron_job", "resource_uuid": j.UUID, "reason": nerr.Error(),
				})
				return nil
			}); err != nil {
				s.logger.Warn(ctx, "cron: disable invalid schedule failed", "job_uuid", j.UUID, "err", err)
			} else if updated, err := s.repo.GetJobByID(ctx, j.ID); err == nil {
				s.publishJobEvent(ctx, updated, EventCronJobUpdated)
			}
			_ = s.repo.ReleaseLock(ctx, j.ID, s.nodeID)
			continue
		}
		// F08 §4.2 R5 catch-up=last: 显式审计本次合并的窗口数, 方便运营在 §5.3 健康面板
		// 看到"过去 N 个窗口被合并补跑 1 次"; 不影响触发逻辑, 也不改 run.status (仍然只有 1 个 run).
		if sched, _, perr := s.parseCron(j.ScheduleCron, j.Timezone); perr == nil {
			var anchor time.Time
			if j.LastRunAt != nil {
				anchor = *j.LastRunAt
			} else {
				anchor = j.CreatedAt
			}
			if merged := catchUpMergedCount(sched, anchor, time.Now()); merged > 0 {
				s.bestEffortAudit(ctx, "audit.cron.catchup_last_merged", j.TenantID, map[string]any{
					"resource_kind":  "agent_cron_job",
					"resource_uuid":  j.UUID,
					"merged_windows": merged,
					"last_run_at":    formatTimePtr(j.LastRunAt),
				})
				if s.logger != nil && merged > 1 {
					s.logger.Info(ctx, "cron: catch-up=last merged windows",
						"job_uuid", j.UUID, "merged", merged)
				}
			}
		}
		if err := s.runTx(ctx, func(tx pgx.Tx) error {
			r, err := s.repo.CreateRun(ctx, tx, domcron.CreateRunInput{
				JobID: j.ID, TenantID: j.TenantID, AccountID: j.AccountID, AgentID: j.AgentID,
				TriggerKind:     domcron.TriggerKindCron,
				PayloadSnapshot: j.Payload,
			})
			if err != nil {
				return err
			}
			_ = r
			if next != nil {
				if err := s.repo.PatchJob(ctx, tx, j.ID, domcron.PatchJobInput{NextRunAt: next}); err != nil {
					return err
				}
			}
			return nil
		}); err != nil {
			s.logger.Warn(ctx, "cron: dispatch tx failed", "job_uuid", j.UUID, "err", err)
		} else {
			dispatched++
		}
		_ = s.repo.ReleaseLock(ctx, j.ID, s.nodeID)
	}
	if dispatched > 0 && s.runner != nil {
		// 立即 kick executor.
		go func() {
			bg := context.WithoutCancel(ctx)
			_, _ = s.ProcessQueuedRuns(bg)
		}()
	}
	return dispatched, nil
}

func (s *impl) computeNextRun(j *domcron.Job) (*time.Time, error) {
	sched, loc, err := s.parseCron(j.ScheduleCron, j.Timezone)
	if err != nil {
		return nil, err
	}
	n := nextRunAfter(sched, time.Now().In(loc), j.NextRunAt)
	if n.IsZero() {
		return nil, apperr.New(apperr.InvalidParams, ErrCodeCronExprInvalid).Withf("schedule has no future occurrence")
	}
	return &n, nil
}

// nextRunAfter · 触发后重算 next_run_at 的锚点规则.
//
// 历史背景 (2026-06-12 实测双发 bug): DueJobs 曾用 now+DispatchInterval 前瞻选
// job, 窗口点之前的最后一个 tick 会提前触发; 若直接 sched.Next(now) 会把**同一
// 个窗口**再算出来 → 下个 tick 再触发一次, 每个窗口稳定双发。修正: 锚点取
// max(now, 被触发的 next_run_at); cron Next 严格大于锚点, 因此提前触发也会越
// 过本窗口。v0.4.14 起 DueJobs 已不再前瞻 (horizon=now, 只选 next_run_at<=now
// 的行), 这个 max() 现在主要是防御 catch-up / 时钟抖动等边界场景的兜底, 不再是
// 双发的第一道防线。catch-up 场景 next_run_at 在过去, 锚点退回 now, 维持
// catch-up=last 合并语义不变。纯函数便于单测。
func nextRunAfter(sched rcron.Schedule, now time.Time, currentNext *time.Time) time.Time {
	anchor := now
	if currentNext != nil && currentNext.After(anchor) {
		anchor = currentNext.In(now.Location())
	}
	return sched.Next(anchor)
}

// catchUpMergedCount · F08 §4.2 R5 catch-up=last 显式语义.
//
// 不变量 (与 docs/features/F08-agent-tasks-cron.md §4.2 对齐):
//   - 返回值 = "本次 dispatch 之前已经错过、但被合并到这一次执行里的窗口数"
//   - 0 → 没有错过窗口 (正常按时触发)
//   - N ≥ 1 → scheduler 宕机 / cron job paused 期间错过了 N 个窗口, 醒来时被合并补跑 1 次
//
// 算法:
//   - 锚点 lastFired (= job.LastRunAt, 没有就 job.CreatedAt; 由 caller 提供)
//   - 沿着 sched.Next() 一步一步走, 数有几个 "Next(prev) < now" 命中
//   - 终止条件 = "Next(prev) >= now" (这次走出未来), 返回累计的 N
//
// 与 DueJobs 行为的关系:
//   - DueJobs 已经按 next_run_at <= horizon (now+30s) 把"已经过期"的 job 选出来
//   - DispatchTick 对每个选中的 job **只 CreateRun 一次** + 重新 sched.Next(now) 推 next_run_at 到未来
//   - 所以 catch-up=last 的"合并补跑 1 次"语义已经在 DueJobs + computeNextRun 上隐式达成;
//     本函数仅产出 audit 可见的合并窗口数, 方便运营在 §5.3 健康面板看到
//
// 纯函数, 便于单测 (caller 负责传 sched + lastFired + now).
func catchUpMergedCount(sched rcron.Schedule, lastFired, now time.Time) int {
	if sched == nil || lastFired.IsZero() {
		return 0
	}
	next := sched.Next(lastFired)
	if !next.Before(now) {
		// 下一窗口尚未到 → 没错过任何窗口.
		return 0
	}
	// 至少错过 1 个 (next < now), 继续往前找.
	n := 1
	prev := next
	for {
		nn := sched.Next(prev)
		if !nn.Before(now) {
			return n
		}
		prev = nn
		n++
		// 防御性上限: 避免极端 schedule 把 loop 跑炸.
		if n > 100000 {
			return n
		}
	}
}

// =====================================================
// Executor (queued → running → succeeded/failed/cancelled)
// =====================================================

func (s *impl) ProcessQueuedRuns(ctx context.Context) (int, error) {
	if s.runner == nil {
		// 单测 / smoke 没装 runner 时直接跳过 (caller 应感知).
		return 0, nil
	}
	// 一次拉至多 5 行 queued; 单事务把它们升 running 后释放, 然后逐个执行.
	var picked []domcron.Run
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		rows, err := s.repo.PickQueuedRunForUpdate(ctx, tx, 5)
		if err != nil {
			return err
		}
		picked = rows
		return nil
	}); err != nil {
		return 0, fmt.Errorf("pick queued: %w", err)
	}
	processed := 0
	for i := range picked {
		s.executeRun(ctx, &picked[i])
		processed++
	}
	return processed, nil
}

func (s *impl) executeRun(ctx context.Context, r *domcron.Run) {
	j, err := s.repo.GetJobByID(ctx, r.JobID)
	if err != nil {
		s.markRunFailed(ctx, r, "job lookup failed: "+err.Error())
		return
	}
	if err := manualRunStateError(j); err != nil {
		s.markRunCancelled(ctx, r, err.Error())
		return
	}
	if r.TriggerKind != domcron.TriggerKindManual && (!j.Enabled || j.Status != domcron.StatusActive) {
		s.markRunCancelled(ctx, r, "cron.job_paused")
		return
	}
	// agent.
	if s.agents == nil {
		s.markRunFailed(ctx, r, "agent lookup not wired")
		return
	}
	// 直接走 SELECT (而非 GetByUUID) 因为我们有 agent_id.
	var agentUUID string
	if err := s.pool.QueryRow(ctx, `SELECT uuid::text FROM digital_employees WHERE id=$1`, j.AgentID).Scan(&agentUUID); err != nil {
		s.markRunFailed(ctx, r, "agent uuid lookup failed: "+err.Error())
		return
	}
	ag, err := s.agents.GetByUUID(ctx, agentUUID)
	if err != nil || ag == nil {
		s.markRunFailed(ctx, r, "agent not found")
		return
	}
	if !cronAgentInScope(ag, j.AccountID, j.TenantID) {
		s.markRunFailed(ctx, r, "agent tenant mismatch")
		return
	}
	// Codex P1#1: 重跑 contacts visibility 闸口 (覆盖 agent 后续被隐藏 / 下架 / contact_enabled=false /
	// workspace 不可见等情况; CreateJob 时的检查不延续到 cron 触发时).
	if err := s.assertAgentVisible(ctx, j.AccountID, j.TenantID, agentUUID); err != nil {
		s.markRunFailed(ctx, r, "visibility: "+err.Error())
		return
	}
	// delivery — Codex P1#2: 也走 agent 归属校验, 防 agent / conversation 后续不一致.
	// F08 §8.2 #2 / R8 触发时复校 group room 成员关系 (caller / agent 中途退群).
	conv, deliveryKind, err := s.resolveDelivery(ctx, j.AccountID, j.TenantID, j.AgentID, j.Delivery)
	if err != nil {
		// R8 复校失败 (caller/agent 退群): 走 cancelled 终态, 不增 consecutive_failures.
		if isR8MembershipError(err) {
			s.markRunCancelled(ctx, r, err.Error())
			return
		}
		s.markRunFailed(ctx, r, "delivery: "+err.Error())
		return
	}
	if err := s.assertCronCapability(ctx, ag); err != nil {
		s.markRunFailed(ctx, r, err.Error())
		return
	}
	if err := assertLocalDelivery(ag, conv, deliveryKind); err != nil {
		s.markRunFailed(ctx, r, err.Error())
		return
	}
	if err := s.localDesktopReady(ctx, j, ag); err != nil {
		if isLocalDesktopWaiting(err) {
			if err := s.repo.RequeueUnstartedRun(ctx, r.ID); err != nil {
				s.logger.Warn(ctx, "cron: requeue before start failed", "err", err)
			}
		} else {
			s.markRunFailed(ctx, r, err.Error())
		}
		return
	}
	// F08 §8.2 #4 / R9: 优先用 prompt_template (模板渲染); fallback 老 payload.prompt.
	prompt, renderErr := s.resolveRuntimePrompt(ctx, j)
	if renderErr != nil {
		s.markRunFailed(ctx, r, renderErr.Error())
		return
	}
	if strings.TrimSpace(prompt) == "" {
		s.markRunFailed(ctx, r, "empty prompt")
		return
	}
	// E6 / F08 §3.2.1: 渲染后 prompt 必须 ≤ PayloadMaxBytes; 不然 markRunFailed +
	// error_message 含 cron.payload_too_large, **不**把超长 trigger message 落 PG / 推 chat runner.
	if err := validateRenderedPromptSize(prompt, s.cfg.PayloadMaxBytes); err != nil {
		s.markRunFailed(ctx, r, err.Error())
		return
	}
	// A queued local run may have waited through further windows. Merge them before
	// starting this one, so recovery does not immediately dispatch a second catch-up.
	if ag.ExecutionLocus == "local" && r.TriggerKind == domcron.TriggerKindCron && j.NextRunAt != nil && !j.NextRunAt.After(time.Now()) {
		next, err := s.computeNextRun(j)
		if err != nil {
			s.markRunFailed(ctx, r, err.Error())
			return
		}
		if err := s.runTx(ctx, func(tx pgx.Tx) error { return s.repo.PatchJob(ctx, tx, j.ID, domcron.PatchJobInput{NextRunAt: next}) }); err != nil {
			s.markRunFailed(ctx, r, err.Error())
			return
		}
	}
	// 把渲染后 prompt 暂存到 r.PayloadSnapshot, finalizeRun 取出落 rendered_prompt_snapshot 列.
	if r.PayloadSnapshot == nil {
		r.PayloadSnapshot = map[string]any{}
	}
	r.PayloadSnapshot["_rendered_prompt"] = prompt
	// 写 system trigger message.
	if s.messages == nil {
		s.markRunFailed(ctx, r, "message writer not wired")
		return
	}
	triggerMsg, err := s.messages.Append(ctx, &dommsg.Message{
		TenantID:       j.TenantID,
		ConversationID: conv.ID,
		Role:           "system",
		Blocks:         []map[string]any{{"kind": "markdown", "text": prompt}},
		Status:         "final",
		Final:          true,
		Metadata:       buildTriggerMessageMetadata(j, r, ag.UUID),
	})
	if err != nil {
		s.markRunFailed(ctx, r, "trigger message insert failed: "+err.Error())
		return
	}
	// SSE cron.run.started.
	r.ConversationID = &conv.ID
	r.MessageUUID = triggerMsg.UUID
	s.publishRunEvent(ctx, j, r, EventCronRunStarted)

	// 调 chat runner.
	out, runErr := s.runner.RunAgentForConversation(ctx, ChatRunInput{
		AccountID:          j.AccountID,
		TenantID:           j.TenantID,
		Conversation:       conv,
		Agent:              ag,
		PromptText:         prompt,
		TriggerMessageUUID: triggerMsg.UUID,
		RunUUID:            r.UUID,
	})
	finishedAt := time.Now()
	duration := finishedAt.Sub(r.StartedAt).Milliseconds()
	if runErr != nil {
		s.finalizeRun(ctx, j, r, &finishedAt, duration, "", "", domcron.RunStatusFailed, runErr.Error())
		s.patchTriggerRunStatus(ctx, triggerMsg.UUID, domcron.RunStatusFailed)
		return
	}
	summary := truncate(prompt, 500)
	// 2026-06-12 run 终态语义改造 (用户拍板): 执行成功/失败以 agent 回复流终态为准。
	// runner 桥接层挂了 watcher (FinalizeDeferred=true) 时, 这里只把终态所需上下文落
	// run 行, 状态保持 running; 终态由 HandleRunStreamTerminal 收敛。watcher 15min
	// 超时标 failed; 进程崩溃由 RunStaleTimeout reaper (默认 2h) 兜底。
	deferred := out != nil && out.FinalizeDeferred
	if deferred {
		s.persistRunProgress(ctx, r, out.AgentMessageUUID, summary)
		return
	}
	// fallback: watcher 未接线 (测试/降级环境) → 维持旧语义, 启动即 succeeded。
	s.finalizeRun(ctx, j, r, &finishedAt, duration, out.AgentMessageUUID, summary, domcron.RunStatusSucceeded, "")
	s.patchTriggerRunStatus(ctx, triggerMsg.UUID, domcron.RunStatusSucceeded)
}

// persistRunProgress 终态前把已知上下文写进 run 行 (status 不动, 仍 running)。
func (s *impl) persistRunProgress(ctx context.Context, r *domcron.Run, agentMsgUUID, summary string) {
	in := domcron.UpdateRunInput{Summary: &summary}
	if agentMsgUUID != "" {
		in.MessageUUID = &agentMsgUUID
	}
	if r.ConversationID != nil {
		in.ConversationID = r.ConversationID
	}
	if v, ok := r.PayloadSnapshot["_rendered_prompt"].(string); ok && v != "" {
		in.RenderedPromptSnapshot = &v
	}
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		return s.repo.UpdateRun(ctx, tx, r.ID, in)
	}); err != nil {
		s.logger.Warn(ctx, "cron: persist run progress failed", "run_uuid", r.UUID, "err", err)
	}
}

// patchTriggerRunStatus trigger 消息 metadata.cron_run_status 回写 (best-effort)。
// 客户端定时任务卡片状态 (执行中/已推送/执行失败) 以此为准, 与历史执行结果一致。
func (s *impl) patchTriggerRunStatus(ctx context.Context, triggerMsgUUID, status string) {
	if s.messages == nil || strings.TrimSpace(triggerMsgUUID) == "" {
		return
	}
	if err := s.messages.PatchMetadata(ctx, triggerMsgUUID, map[string]any{"cron_run_status": status}); err != nil {
		s.logger.Warn(ctx, "cron: patch trigger run status failed",
			"message_uuid", triggerMsgUUID, "status", status, "err", err)
	}
}

// HandleRunStreamTerminal · runner 桥接层在 agent 回复流终态时回调 (契约见 Service 接口注释)。
func (s *impl) HandleRunStreamTerminal(ctx context.Context, runUUID, triggerMessageUUID, status, errMsg string) {
	r, err := s.repo.GetRunByUUID(ctx, runUUID)
	if err != nil || r == nil {
		s.logger.Warn(ctx, "cron: stream terminal run lookup failed", "run_uuid", runUUID, "err", err)
		return
	}
	if r.Status != domcron.RunStatusRunning && r.Status != domcron.RunStatusQueued {
		return // 已终态 (重复回调 / reaper 先到): 幂等放弃
	}
	j, err := s.repo.GetJobByID(ctx, r.JobID)
	if err != nil || j == nil {
		s.logger.Warn(ctx, "cron: stream terminal job lookup failed", "run_uuid", runUUID, "err", err)
		return
	}
	now := time.Now()
	duration := now.Sub(r.StartedAt).Milliseconds()
	switch status {
	case domcron.RunStatusSucceeded, domcron.RunStatusCancelled:
		errMsg = ""
	case domcron.RunStatusFailed:
		if strings.TrimSpace(errMsg) == "" {
			errMsg = "agent execution failed"
		}
	default:
		s.logger.Warn(ctx, "cron: invalid stream terminal status", "run_uuid", runUUID, "status", status)
		return
	}
	s.finalizeRun(ctx, j, r, &now, duration, r.MessageUUID, r.Summary, status, errMsg)
	s.patchTriggerRunStatus(ctx, triggerMessageUUID, status)
}

func (s *impl) markRunFailed(ctx context.Context, r *domcron.Run, msg string) {
	now := time.Now()
	dur := now.Sub(r.StartedAt).Milliseconds()
	j, _ := s.repo.GetJobByID(ctx, r.JobID)
	if j == nil {
		// best-effort: 至少把 run 行刷一下.
		_ = s.runTx(ctx, func(tx pgx.Tx) error {
			status := domcron.RunStatusFailed
			return s.repo.UpdateRun(ctx, tx, r.ID, domcron.UpdateRunInput{
				Status: &status, FinishedAt: &now, DurationMs: &dur, ErrorMessage: &msg,
			})
		})
		return
	}
	s.finalizeRun(ctx, j, r, &now, dur, "", "", domcron.RunStatusFailed, msg)
}

// markRunCancelled · F08 §4.3 / §8.2 #2 R8 复校退出 + R5 catch-up=last 边界.
//
// 与 markRunFailed 的关键差别:
//   - status='cancelled' 而非 'failed' (schema CHECK 已包含 cancelled).
//   - 不增 consecutive_failures, 不推进 status='error' (语义: 非任务自身失败, 是外部条件导致退出).
//   - 不发 R6 失败通知.
//
// 用于:
//   - R8 触发时复校 caller/agent 退群.
//   - 未来 Phase B cancel API.
func (s *impl) markRunCancelled(ctx context.Context, r *domcron.Run, msg string) {
	now := time.Now()
	dur := now.Sub(r.StartedAt).Milliseconds()
	j, _ := s.repo.GetJobByID(ctx, r.JobID)
	if j == nil {
		_ = s.runTx(ctx, func(tx pgx.Tx) error {
			status := domcron.RunStatusCancelled
			return s.repo.UpdateRun(ctx, tx, r.ID, domcron.UpdateRunInput{
				Status: &status, FinishedAt: &now, DurationMs: &dur, ErrorMessage: &msg,
			})
		})
		return
	}
	// finalizeRun 仅根据 status 推进 job.consecutive_failures; cancelled 走"未匹配 succeeded/failed"
	// 分支 → 不 ResetFailures / 不 IncFailures, 符合 R8 的"不增计数"语义.
	s.finalizeRun(ctx, j, r, &now, dur, "", "", domcron.RunStatusCancelled, msg)
}

// isR8MembershipError · 判定 err 是否为 R8 双向成员校验失败 (caller / agent 不在群).
func isR8MembershipError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, ErrCodeCronGroupMemberNotIn) ||
		strings.Contains(msg, ErrCodeCronAgentNotInGroup)
}

func boolPtrDebug(p *bool) string {
	if p == nil {
		return "<nil>"
	}
	return fmt.Sprintf("%v", *p)
}

func stringPtrDebug(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

func (s *impl) finalizeRun(ctx context.Context, j *domcron.Job, r *domcron.Run, finishedAt *time.Time, duration int64,
	messageUUID, summary, status, errMsg string) {
	runOnceDone := false
	if v, ok := j.Metadata["run_once"].(bool); ok && v {
		runOnceDone = true
	}
	s.logger.Info(ctx, "cron: finalize run debug", "job_id", j.ID, "job_enabled", j.Enabled, "metadata", fmt.Sprintf("%#v", j.Metadata), "run_once_done", runOnceDone, "status", status)
	if err := s.runTx(ctx, func(tx pgx.Tx) error {
		runIn := domcron.UpdateRunInput{
			Status: &status, FinishedAt: finishedAt, DurationMs: &duration,
		}
		if summary != "" {
			runIn.Summary = &summary
		}
		if errMsg != "" {
			runIn.ErrorMessage = &errMsg
		}
		if messageUUID != "" {
			runIn.MessageUUID = &messageUUID
		}
		if r.ConversationID != nil {
			runIn.ConversationID = r.ConversationID
		}
		// R9: 记录本次渲染后的 prompt 快照 (executor 在 callPath 里把 prompt 暂存到 r.Summary 路径不够;
		// 直接用 executor 阶段拿到的 prompt). 由 caller 通过 r.PayloadSnapshot["_rendered_prompt"] 透传.
		if v, ok := r.PayloadSnapshot["_rendered_prompt"].(string); ok && v != "" {
			runIn.RenderedPromptSnapshot = &v
		}
		if err := s.repo.UpdateRun(ctx, tx, r.ID, runIn); err != nil {
			return err
		}
		// 同步 job last_run_* + consecutive_failures + 阈值.
		patch := domcron.PatchJobInput{
			SetLastRun: &domcron.RunSummary{At: *finishedAt, Status: status, Summary: summary},
		}
		topic := "audit.cron.run_finished"
		if status == domcron.RunStatusFailed {
			topic = "audit.cron.run_failed"
			patch.IncFailures = true
			// 阈值判断: 现在 +1 是预知; 用 j.ConsecutiveFailures+1 与 j.FailureThreshold 比.
			if j.ConsecutiveFailures+1 >= j.FailureThreshold {
				errState := domcron.StatusError
				patch.Status = &errState
				disabled := false
				patch.Enabled = &disabled
			}
		} else if status == domcron.RunStatusSucceeded {
			patch.ResetFailures = true
		}
		// RunOnce 变通实现: 标准 cron 无年字段, 落库表达式会在下一年同一时刻再次触发;
		// 任务第一次跑到任意终态 (succeeded/failed/cancelled) 后立即停用, 防止真的等到
		// 下一年重新触发。见 domain/cron.CreateJobInput.RunOnce 注释。
		if runOnceDone {
			disabled := false
			pauseReason := domcron.PauseReasonUserPaused
			patch.Enabled = &disabled
			patch.PauseReason = &pauseReason
		}
		s.logger.Info(ctx, "cron: finalize run debug about to PatchJob",
			"job_id", j.ID, "run_once_done", runOnceDone,
			"patch_enabled_set", patch.Enabled != nil,
			"patch_enabled_value", boolPtrDebug(patch.Enabled),
			"patch_pause_reason", stringPtrDebug(patch.PauseReason))
		if err := s.repo.PatchJob(ctx, tx, j.ID, patch); err != nil {
			s.logger.Warn(ctx, "cron: finalize run debug PatchJob returned err", "job_id", j.ID, "err", err)
			return err
		}
		s.logger.Info(ctx, "cron: finalize run debug PatchJob committed ok", "job_id", j.ID)
		s.publishAuditTx(ctx, tx, topic, j.TenantID, map[string]any{
			"resource_kind": "agent_cron_run",
			"resource_uuid": r.UUID,
			"job_uuid":      j.UUID,
			"status":        status,
			"duration_ms":   duration,
		})
		if status == domcron.RunStatusFailed && j.ConsecutiveFailures+1 >= j.FailureThreshold {
			s.publishAuditTx(ctx, tx, "audit.cron.job_disabled_due_to_failures", j.TenantID, map[string]any{
				"resource_kind": "agent_cron_job",
				"resource_uuid": j.UUID,
			})
		}
		return nil
	}); err != nil {
		s.logger.Warn(ctx, "cron: finalize run failed", "run_uuid", r.UUID, "err", err)
	} else if runOnceDone {
		s.notify(ctx, "agent_cron_jobs:"+strconv.FormatInt(j.ID, 10))
		// debug: 事务提交后立刻用一次全新的 GetJobByID 读回, 验证写入是否真的
		// 对随后的读可见 (排查"PatchJob 不报错但读回来还是 enabled=true" 的读写一致性怀疑)。
		if verify, verr := s.repo.GetJobByID(ctx, j.ID); verr == nil && verify != nil {
			s.logger.Info(ctx, "cron: finalize run debug post-commit readback",
				"job_id", j.ID, "enabled", verify.Enabled, "pause_reason", verify.PauseReason)
		} else {
			s.logger.Warn(ctx, "cron: finalize run debug post-commit readback failed", "job_id", j.ID, "err", verr)
		}
	}
	// SSE cron.run.finished.
	r.Status = status
	r.FinishedAt = finishedAt
	r.DurationMs = duration
	r.MessageUUID = messageUUID
	r.Summary = summary
	r.ErrorMessage = errMsg
	s.publishRunEvent(ctx, j, r, EventCronRunFinished)

	// F08 §8.2 #8 / R6: 连续失败到阈值 → status=error + 原会话发"道歉" 系统消息.
	// 注意 j.ConsecutiveFailures 还是触发前的旧值; 阈值判定与 finalizeRun 上面那段保持一致.
	if status == domcron.RunStatusFailed && j.ConsecutiveFailures+1 >= j.FailureThreshold {
		convID := int64(0)
		if r.ConversationID != nil {
			convID = *r.ConversationID
		} else if j.Delivery != nil {
			if cu, _ := j.Delivery["conversation_uuid"].(string); cu != "" {
				if conv, lerr := s.convs.GetByUUID(ctx, cu); lerr == nil && conv != nil {
					convID = conv.ID
				}
			}
		}
		if convID > 0 {
			agentUUID, _ := s.fetchAgentUUID(ctx, j.AgentID)
			s.sendFailureNoticeToConversation(ctx, j, convID, agentUUID, errMsg)
		}
	}
}

// =====================================================
// utility
// =====================================================

// formatTimePtr · time.Time pointer 的 RFC3339 字符串 (nil → "").
func formatTimePtr(t *time.Time) string {
	if t == nil {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// buildFailureNoticeMetadata · F08 §8.2 #8 / R6 · cron 任务连续失败到阈值时发的"道歉" 系统消息 metadata.
//
// 与 trigger message metadata 的关键差别 (与 §1.3 "R6 失败通知 sender 模型" 对齐):
//   - kind="cron_failure_notice" (区分 cron_trigger).
//   - 调用方在写 PG `messages` 行时同步置 sender_agent_id=job.AgentID (本函数不参与 sender 字段, 只产 metadata).
//   - 失败语义 (errMsg / cron.consecutive_failures / cron.failure_threshold) 都进 metadata, 便于审计反查.
//
// 纯函数, 便于单测.
func buildFailureNoticeMetadata(j *domcron.Job, agentUUID, errMsg string) map[string]any {
	md := map[string]any{
		"kind":                      "cron_failure_notice",
		"acting_as":                 "cron_scheduler",
		"cron_owner_account_id":     j.AccountID,
		"cron_agent_id":             j.AgentID,
		"cron_job_uuid":             j.UUID,
		"cron_job_name":             j.Name,
		"cron_consecutive_failures": j.ConsecutiveFailures + 1, // finalizeRun 调用时尚未 +1 落库, 这里显式 +1
		"cron_failure_threshold":    j.FailureThreshold,
		"last_error_message":        errMsg,
	}
	if agentUUID != "" {
		md["cron_agent_uuid"] = agentUUID
	}
	return md
}

// buildFailureNoticeText · 渲染 R6 道歉文案 (中文; 客户端可按 metadata.kind=cron_failure_notice 自渲染).
func buildFailureNoticeText(j *domcron.Job) string {
	return "❌ 我尝试执行定时任务 \"" + j.Name + "\" 失败 " +
		strconv.Itoa(j.FailureThreshold) + " 次, 已自动暂停。请联系设置者检查后手动恢复。"
}

// sendFailureNoticeToConversation · F08 §8.2 #8 / R6 · 在 cron 原会话发一条"任务失败道歉" 系统消息.
//
// 行为:
//   - PG: messages.Append role='system' + sender_agent_id=job.AgentID (与 trigger 的"双 NULL"区分;
//     群成员/客户端必须能反推到具体数字员工, 由 sender_agent_id 承担).
//   - 群聊场景下还应经 WuKong AgentUID /message/send 发到 channel — 由于本期 WuKong sender 投递依赖 R4
//     真正放开, 仅在 PG 落锚点, WuKong chip 投递标 §8.2 #8 follow-up (blocker: §6 WuKong chip schema 未定).
//   - 失败 best-effort: 已经 status=error 的 cron, 多一条道歉消息发不出来不应阻塞 job 状态机.
func (s *impl) sendFailureNoticeToConversation(ctx context.Context, j *domcron.Job, conversationID int64, agentUUID, errMsg string) {
	if s.messages == nil || conversationID == 0 {
		return
	}
	md := buildFailureNoticeMetadata(j, agentUUID, errMsg)
	text := buildFailureNoticeText(j)
	agentID := j.AgentID
	if _, err := s.messages.Append(ctx, &dommsg.Message{
		TenantID:       j.TenantID,
		ConversationID: conversationID,
		Role:           "system",
		SenderAgentID:  &agentID, // ← R6 与 trigger 的核心差别: 必填, 让群成员/客户端识别是哪个数字员工
		Blocks: []map[string]any{
			{"kind": "markdown", "text": text},
		},
		Status:   "final",
		Final:    true,
		Metadata: md,
	}); err != nil {
		s.logger.Warn(ctx, "cron: failure notice insert failed",
			"job_uuid", j.UUID, "conv_id", conversationID, "err", err)
	}
}

// buildTriggerMessageMetadata · F08 §8.2 #3 · 拼 cron trigger message 落 PG 时的 metadata.
//
// 行为契约 (与 docs/features/F08-agent-tasks-cron.md §1.3 / §4.3 对齐):
//   - 必含 "triggered_by"="cron" + "acting_as"="cron_scheduler" (用于 R12 群成员视图 / 客户端 chip 渲染 / 审计反查)
//   - 必含 cron 业务归属: cron_owner_account_id (job.AccountID) + cron_agent_id (job.AgentID)
//   - 必含 cron 反查锚点: cron_job_uuid / cron_run_uuid / cron_job_name
//   - 兼容旧调用方: 保留旧 metadata keys job_uuid / run_uuid (zhiban-app 老 chip 解析 + 部分审计 dashboard 在用)
//
// 不变量 (跟 PG row 的 sender_account_id / sender_agent_id / role 解耦):
//   - 本函数只产出 metadata; trigger message 行 sender_account_id / sender_agent_id 必须 NULL,
//     role 必须 "system"; 调用方 (executeRun) 负责.
//
// 纯函数, 便于单测 (无 DB / 网络依赖).
func buildTriggerMessageMetadata(j *domcron.Job, r *domcron.Run, agentUUID string) map[string]any {
	md := map[string]any{
		// 新 v0.4.3 字段集合.
		"triggered_by":          "cron",
		"acting_as":             "cron_scheduler",
		"cron_owner_account_id": j.AccountID,
		"cron_agent_id":         j.AgentID,
		"cron_job_uuid":         j.UUID,
		"cron_run_uuid":         r.UUID,
		"cron_job_name":         j.Name,
		// 2026-06-12 run 终态语义: 初始 running, 终态时 patchTriggerRunStatus 改写
		// succeeded/failed/cancelled; 客户端卡片状态据此渲染 (缺失 = 老消息, 按已推送处理)。
		"cron_run_status": domcron.RunStatusRunning,
		// 兼容老 metadata keys; 客户端 chip / 老审计 dashboard 仍在用.
		"job_uuid": j.UUID,
		"run_uuid": r.UUID,
	}
	if agentUUID != "" {
		md["cron_agent_uuid"] = agentUUID
	}
	return md
}
