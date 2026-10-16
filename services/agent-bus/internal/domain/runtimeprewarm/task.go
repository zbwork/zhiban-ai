// Package runtimeprewarm 是 doc-10 登录预热任务 (runtime_prewarm_tasks) 的领域类型。
//
// 每个【运行实例初始化】= 一条 TaskKindInstanceInit; 每个【外部 Agent 实例初始化】=
// 一条 TaskKindAgentInstanceInit; 每个【Agent 注册/注销】= 一条 Agent 任务。
// 任务表是 DB 事实源 (doc-10 §7.1); Redis 仅作 wakeup。本包不依赖 runtimehosting / agent service,
// 仅定义类型与仓储接口, 由 worker (service 层) 编排真正的 EnsureWorkload / OpenClawSyncer。
package runtimeprewarm

import (
	"context"
	"time"
)

// TaskKind 任务类型 (跟 runtime_prewarm_tasks CHECK 一致)。
const (
	TaskKindInstanceInit      = "instance_init"       // 拉起 per-user 实例
	TaskKindAgentRegister     = "agent_register"      // 把数字员工注册进该实例
	TaskKindAgentInstanceInit = "agent_instance_init" // ZAP 外部 runtime: 初始化/解析当前用户的数字员工本地实例
	TaskKindAgentUnregister   = "agent_unregister"    // 删除数字员工时从该实例注销运行端 agent
	TaskKindSkillRegister     = "skill_register"      // 把数字员工绑定的技能 install 进该实例 workspace (skill.install, doc-12 §11.5 Task B)
	TaskKindSkillUnregister   = "skill_unregister"    // 解绑后删除该实例 workspace 下 skills/<slug>/ (skill.uninstall, doc-12 §11.5 Task C-2)
	TaskKindIdentityProvision = "identity_provision"  // Deprecated: use agent_instance_init.
)

// NotifyChannelTaskReady 是"有新任务待执行"的 PG NOTIFY 频道: 落库事务提交时发出, worker 收到即跑一轮,
// 免去最多一个 tick 的空等 (external 环境注册本身零工作, 等节拍就是全部延迟)。
// 通知只是加速信号, 丢了也只是退回按节拍轮询, 不影响正确性。
const NotifyChannelTaskReady = "runtime_prewarm_task_ready"

// Status 任务状态 (跟 migration 000008 的 CHECK 一致, 同时是客户端任务列表语义, doc-10 §8)。
const (
	StatusPending         = "pending"          // 已入队待调度
	StatusWaitingInstance = "waiting_instance" // agent_register 等其依赖实例就绪
	StatusRunning         = "running"          // 正在执行
	StatusSucceeded       = "succeeded"        // 完成
	StatusFailed          = "failed"           // 终态失败 (超 maxAttempts)
	StatusRetrying        = "retrying"         // 失败待重试 (attempts < max, next_retry_at 退避)
)

// Task 一行 runtime_prewarm_tasks。
type Task struct {
	ID                   int64
	UUID                 string
	TenantID             int64
	AccountID            int64
	RuntimeEnvironmentID int64
	TaskKind             string
	DigitalEmployeeUUID  *string // agent_instance_init / agent_register / agent_unregister / skill_register
	DependsTaskUUID      *string // agent_*: 依赖 instance_init; skill_*: 依赖 agent_register (本表自引用)
	RuntimeInstanceUUID  *string // instance_init 产出 / 提升时拷入下游任务的 runtime_instances.uuid (ZAP 为 nil)
	// skill_register 专用 (doc-12 §11.5 Task B):
	SkillUUID        *string // skills.uuid
	SkillSlug        *string // skills.code (容器内 skills/<slug>/ 目录名)
	SkillVersionUUID *string // skill_versions.uuid (要安装的已发布版本)
	// TargetSignature 目标签名 (doc-10 §5b 幂等 ensure): instance_init=env.updated_at,
	// agent_register=de.updated_at, skill_register=skill_versions.uuid。同 identity 已 succeeded
	// 且签名一致 → 登录 ensure 跳过; 不一致(目标变化) → 重新生成。
	TargetSignature *string
	Status          string
	Attempts        int
	NextRetryAt     time.Time
	LastError       string
	LockedBy        string
	LockedUntil     *time.Time
	SucceededAt     *time.Time
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// CreateTaskInput 创建一条预热任务。
type CreateTaskInput struct {
	// UUID 可选。空时由 DB 默认 gen_random_uuid() 生成；批量创建时由服务端预生成,
	// 以便同一批次内先填好 depends_task_uuid, 避免插入后再逐条回查。
	UUID                 string
	TenantID             int64
	AccountID            int64
	RuntimeEnvironmentID int64
	TaskKind             string
	DigitalEmployeeUUID  *string
	DependsTaskUUID      *string
	// skill_register 专用 (doc-12 §11.5 Task B): 要安装的技能标识。
	SkillUUID        *string
	SkillSlug        *string
	SkillVersionUUID *string
	// TargetSignature 目标签名 (doc-10 §5b 幂等 ensure), 创建时写入; 见 Task.TargetSignature。
	TargetSignature *string
	// InitialStatus 默认 StatusPending; agent_register / agent_unregister / skill_register 通常传 StatusWaitingInstance。
	InitialStatus string
}

// SkillRef 一个数字员工绑定且**可安装**的技能引用 (doc-12 §11.5 Task B): 已解析到一个已发布版本 + 安装包。
// 由 BoundSkillSource (cpresolver) 解析; buildPlan 据此每技能生成一条 skill_register。
type SkillRef struct {
	SkillUUID        string // skills.uuid
	SkillSlug        string // skills.code
	SkillVersionUUID string // skill_versions.uuid (已发布 + 有 package_url)
}

// PlanItem 是一次 Ensure 计划里的一条待建任务。
// DependsOnIndex 指向**同一计划内**它依赖的 instance_init 项的下标 (-1 = 无依赖, 即 instance_init 自身);
// agent_register 的 depends_task_uuid 在执行期由该下标解析出的 (新建或复用) 任务 uuid 填入。
type PlanItem struct {
	Input          CreateTaskInput
	DependsOnIndex int
}

// EnsureBudgetedInput 一次"预算判定 + 创建"原子操作 (doc-10 §6.2 硬限)。
// 实现 (postgres repo) 必须在 tenant/account advisory 事务锁内重新计数 + 复查 + 创建,
// 保证并发登录下 active 上限真正成立 (单请求预算正确 ≠ 并发硬限成立)。
type EnsureBudgetedInput struct {
	TenantID      int64
	AccountID     int64
	Plan          []PlanItem
	MaxPerTenant  int
	MaxPerAccount int
	// SuppressFailedWithin (doc-12 §11.8.1 问题6): >0 时, 对**已有近期终态 failed (同 identity)** 的
	// agent_register/agent_unregister/skill_register/skill_unregister **不重复创建** (cooldown), 防重复登录 ensure 刷一批同名失败。
	// 0 = 不抑制 (resync / 配置变更 / 手动 retry 用, 允许重新创建)。instance_init 不受抑制。
	SuppressFailedWithin time.Duration
	// SkipAlreadySynced (doc-10 §5b 幂等 ensure): true 时, 对"同 identity 已有 succeeded 且
	// target_signature 与本次 PlanItem 一致"的任务**跳过创建、不计入 actionable 结果** (登录 ensure 用,
	// 实现"已初始化且未更新→下次进入不重复执行/展示")。false = 不跳过, 始终按计划创建 (resync 路径用,
	// 始终把最新配置推到运行端)。复用 active 与 cooldown 抑制不受本开关影响。
	SkipAlreadySynced bool
}

// EnsureBudgetedResult Ensure 的执行结果。
type EnsureBudgetedResult struct {
	Tasks         []*Task // 计划逐项解析出的任务 (新建 + 复用); degraded 时为空
	Degraded      bool
	SkippedReason string // "tenant_queue_full" | "account_queue_full"
	Created       int
	Reused        int
	Suppressed    int // cooldown 抑制 (近期同 identity failed) 未创建的任务数
	Synced        int // 已同步跳过 (同 identity succeeded 且签名一致) 未创建、未计入 Tasks 的任务数 (doc-10 §5b)
}

// DecideBudget 纯函数: 给定锁内重新计得的 active 计数 + 本次真正新增量, 判断是否超限及原因。
// tenant 优先 (与 §6.2 顺序一致); newCount<=0 (全部复用) 永不降级。
// 判定式是 currentActive + newCount > limit (创建前预算), 不是 currentActive >= limit。
func DecideBudget(tenantActive, accountActive, newCount, maxPerTenant, maxPerAccount int) (degraded bool, reason string) {
	if newCount <= 0 {
		return false, ""
	}
	if tenantActive+newCount > maxPerTenant {
		return true, "tenant_queue_full"
	}
	if accountActive+newCount > maxPerAccount {
		return true, "account_queue_full"
	}
	return false, ""
}

// Repository 持久层。实现见 internal/repository/postgres/runtimeprewarm。
type Repository interface {
	// EnsureBudgeted 原子地"预算判定 + 创建"一批预热任务 (doc-10 §6.2 硬限并发安全):
	// 在 tenant/account advisory 事务锁内重新 CountActive + 逐项复查 active (复用不计新增) +
	// DecideBudget; 未超限才创建, 超限整批 degraded 不创建。复用已有 active、不重复创建。
	EnsureBudgeted(ctx context.Context, in EnsureBudgetedInput) (*EnsureBudgetedResult, error)

	// Create 写一条任务 (登录 ensure 时按预热集合批量调用)。
	// DB 级幂等 (uq_rpt_active_instance / uq_rpt_active_agent + ON CONFLICT DO NOTHING):
	// 并发登录撞 active 唯一约束时不重复造任务, 返回 (nil, apperr.ErrConflict), 由 service 复用既有 (FindActive)。
	// 已终结任务不占唯一索引 → 新一轮 ensure 可重新生成 active 任务。
	Create(ctx context.Context, in CreateTaskInput) (*Task, error)

	// ClaimBatch 抢一批可执行任务 (status IN pending/retrying + next_retry_at<=now),
	// 用 FOR UPDATE SKIP LOCKED + UPDATE status='running'/locked_by/locked_until。
	// waiting_instance 的任务不在此被 claim, 需先经 PromoteReadyAgentTasks 转 pending。
	ClaimBatch(ctx context.Context, workerID string, lockTTL time.Duration, limit int) ([]*Task, error)

	// RequeueExpired lease 恢复 (doc-10 §7.4): running 且 locked_until<now 的任务恢复为 retrying,
	// attempts++ + last_error 标记 + next_retry_at 退避; 返回回收条数。worker 崩溃后由其它 worker 调。
	RequeueExpired(ctx context.Context, nextRetryAt time.Time, limit int) (int64, error)

	// PromoteReadyAgentTasks 把"依赖的 instance_init 任务已 succeeded"的 waiting_instance 任务转回 pending,
	// 并从该 instance_init 任务拷入 runtime_instance_uuid (ZAP 为 NULL 也提升, 不卡死)。返回提升条数。
	// 自连接本表 (同 tenant/account/env), 不 join runtime_instances —— 故 external_endpoint 无实例行也成立。
	PromoteReadyAgentTasks(ctx context.Context, limit int) (int64, error)

	// PromoteReadySkillTasks 把"依赖的 agent_register 任务已 succeeded"的 waiting_instance skill_register 任务转回 pending,
	// 并从该 agent_register 任务拷入 runtime_instance_uuid (技能装进同一 per-user 实例)。返回提升条数。
	// 自连接本表 (同 tenant/account/env/数字员工), 依赖完整性同 PromoteReadyAgentTasks (doc-12 §11.5 Task B)。
	PromoteReadySkillTasks(ctx context.Context, limit int) (int64, error)

	// FailBlockedDependencyTasks 收敛已无恢复路径的 waiting_instance 依赖链：
	// 先处理 instance_init failed 后的 agent 任务，再处理 agent_register failed 后的 skill 任务。
	// 若同身份仍有 active 替代父任务或可用 succeeded 结果则保留等待；否则终结为 dependency_failed。
	FailBlockedDependencyTasks(ctx context.Context, limit int) (int64, error)

	// MarkSucceeded status='succeeded' + succeeded_at; 可回写实际实例 uuid (instance_init 产出)。
	MarkSucceeded(ctx context.Context, id int64, runtimeInstanceUUID *string) error

	// MarkWaitingInstance instance_init 仍未就绪时, agent_register 任务退回等待 (不消耗 attempts)。
	MarkWaitingInstance(ctx context.Context, id int64, errMsg string, nextRetryAt time.Time) error

	// MarkRetry 失败但 attempts < max: status='retrying' + attempts++ + next_retry_at 退避。
	MarkRetry(ctx context.Context, id int64, errMsg string, nextRetryAt time.Time) error

	// MarkDeferred 非失败的"稍后再试": status='retrying' + next_retry_at 退避 + 释放 lease,
	// **不增加 attempts**。用于 instance_init 实例仍 pending/starting (正常启动等待, 不是失败),
	// 以及 (若采用 tryAcquire 方案) 执行并发不足时的让位。attempts 只统计真实失败 / lease expired。
	MarkDeferred(ctx context.Context, id int64, reason string, nextRetryAt time.Time) error

	// MarkFailed attempts 达到 max: status='failed' (终态) + last_error。
	MarkFailed(ctx context.Context, id int64, errMsg string) error

	// ListByAccount 客户端 GET /runtime/tasks: 该用户当前预热任务 (含两类), 按 created_at。
	ListByAccount(ctx context.Context, tenantID, accountID int64, limit int) ([]*Task, error)

	// CountActiveByAccount / CountActiveByTenant: §6 队列硬限计数 (pending/waiting_instance/running/retrying)。
	CountActiveByAccount(ctx context.Context, tenantID, accountID int64) (int, error)
	CountActiveByTenant(ctx context.Context, tenantID int64) (int, error)

	// FindActive 幂等去重: 查同 (account, env, kind[, de]) 的未终结任务, 存在则复用不重复建。
	FindActive(ctx context.Context, in CreateTaskInput) (*Task, error)
}
