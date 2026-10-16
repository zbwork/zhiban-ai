package runtimeprewarm

import (
	"context"
	"time"
)

// ResyncReason 标注一条 resync 信号的来源 (诊断用; worker 始终按当前 DB 状态全量重算, 不依赖 reason)。
const (
	ResyncReasonPublish        = "publish"
	ResyncReasonUpdate         = "update"
	ResyncReasonBindingChange  = "binding_change"
	ResyncReasonSkillUnbind    = "skill_unbind"    // 技能解绑 → 携带 SkillUUID, 走 skill_unregister 卸载 (doc-12 §11.5 Task C-2)
	ResyncReasonAgentUnpublish = "agent_unpublish" // 数字员工下架 → 走 agent_unregister 注销运行端 agent, 不删除 pod/workload
)

// ResyncSignal 一条 runtime_resync_outbox (doc-12 §11.5 Task C 发布/编辑增量同步信号)。
//
// 它**只是信号**: "该数字员工配置变了, 请对其租户已 ready 的运行实例做增量同步"。
// **绝不承载会话数据**; 处理它绝不改 messages/conversations/message_streams (见 docs/pitfalls)。
type ResyncSignal struct {
	ID                  int64
	TenantID            int64
	DigitalEmployeeUUID string
	Reason              string
	// SkillUUID 非空 (reason=skill_unbind) → 卸载这一技能 (skill_unregister); reason=agent_unpublish → 注销 agent;
	// 其它空 SkillUUID → 全量 resync (install)。
	SkillUUID string
	Attempts  int
}

// ResyncOutbox 是 Task C 增量同步信号的 outbox 持久层。
//
//   - Admin 侧 (publish/update/binding 成功后) 只调 Enqueue 写信号 (仅依赖 pool, 无 control-plane 耦合)。
//   - Bus 侧 prewarm worker 调 ClaimBatch/Mark* drain 信号, 交 ResyncDigitalEmployee 做 gated fan-out。
//
// 复用 runtime_prewarm_tasks 同款 lease/attempt/backoff (FOR UPDATE SKIP LOCKED), 不新增 Redis。
type ResyncOutbox interface {
	// Enqueue 写一条全量 resync pending 信号 (skill_uuid=NULL)。(tenant, de) 已有 pending(NULL) 时 ON CONFLICT DO NOTHING →
	// 返回 (false, nil) 表示已存在 (幂等合并); 新建成功返回 (true, nil)。
	Enqueue(ctx context.Context, tenantID int64, deUUID, reason string) (created bool, err error)

	// EnqueueSkillUnbind 写一条按技能卸载 pending 信号 (reason=skill_unbind, 携带 skillUUID)。
	// (tenant, de, skill) 已有 pending 时 ON CONFLICT DO NOTHING → 幂等合并 (已存在视为成功)。
	EnqueueSkillUnbind(ctx context.Context, tenantID int64, deUUID, skillUUID string) error

	// ClaimBatch 抢一批可处理信号 (status='pending' 且 next_retry_at<=now), FOR UPDATE SKIP LOCKED + lease。
	ClaimBatch(ctx context.Context, workerID string, lockTTL time.Duration, limit int) ([]*ResyncSignal, error)

	// MarkDone 处理成功 → status='done' (释放 lease)。
	MarkDone(ctx context.Context, id int64) error

	// MarkRetry 失败但 attempts<max → 仍 pending + attempts++ + next_retry_at 退避 + 释放 lease。
	MarkRetry(ctx context.Context, id int64, errMsg string, nextRetryAt time.Time) error

	// MarkFailed attempts 达 max → status='failed' (终态) + last_error。
	MarkFailed(ctx context.Context, id int64, errMsg string) error
}
