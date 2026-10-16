// Package wukongoutbox 是 ADR-0026 P0 前置 — WuKong 外部写入可靠投递 outbox 的领域类型。
//
// 设计:业务事务内只写 outbox 行(Enqueue,幂等),worker 异步发送 WuKong + capped backoff
// 重试,超 max_retries → 终态 failed(不静默吞)。仅 repository 实现碰 SQL。
// 契约见 docs/contracts/agent-bus-client-contract.md §P2.1b「WuKong-send outbox / 可靠投递」。
package wukongoutbox

import (
	"context"
	"time"
)

// Status 枚举(与 migration 000031 的 CHECK 一致)。
const (
	StatusPending = "pending"
	StatusSending = "sending"
	StatusSent    = "sent"
	StatusFailed  = "failed" // retry_count<max_retries=可再 claim; >=max_retries=终态。
)

// Source 枚举(与 migration 000031 的 CHECK 一致)。
const (
	SourceGroupAgentReply       = "group_agent_reply"
	SourceAgentDirectUserFinal  = "agent_direct_user_final"
	SourceAgentDirectAgentFinal = "agent_direct_agent_final"
	SourceRevokeCmd             = "revoke_cmd"
	SourceGeneric               = "generic"
)

// DefaultMaxRetries 默认最大重试次数(达到即 MarkFailed 终态)。
const DefaultMaxRetries = 10

// Message 一行 wukong_send_outbox。
type Message struct {
	ID            string
	TenantID      string
	ChannelID     string
	ChannelType   int
	FromUID       string
	MsgType       int
	Payload       []byte // JSON
	DedupKey      string
	Source        string
	Status        string
	RetryCount    int
	MaxRetries    int
	NextAttemptAt time.Time
	SentAt        *time.Time
	LastError     string
	// lease(visibility timeout):claim 时打租约;worker mark 前崩溃 → lease 到期被重新 claim 重投。
	LockedBy      string
	LockExpiresAt *time.Time
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// DefaultLease worker 默认租约时长(须 > 单条 SendTimeout,使在发送中的行不被误重投)。
const DefaultLease = 2 * time.Minute

// Repository 持久层(仅 repository 实现碰 SQL)。
type Repository interface {
	// Enqueue 幂等插入:(tenant_id, dedup_key) 已存在 → 返回现有行 + inserted=false,不重复。
	Enqueue(ctx context.Context, m Message) (stored Message, inserted bool, err error)

	// ClaimDue claim 一批待办行并转 'sending' + 打 lease(locked_by=workerID,lock_expires_at=now+lease),
	// FOR UPDATE SKIP LOCKED 多 worker 安全。取两类(均要 retry_count<max_retries):
	//   (a) status∈(pending,failed) 且 next_attempt_at<=now —— 正常待办 / 重试;
	//   (b) status='sending' 且 lock_expires_at<=now —— lease 超时(worker 崩溃),重新 claim 重投。
	// 未超时的 sending 不会被取(lock_expires_at 在将来)。
	ClaimDue(ctx context.Context, workerID string, lease time.Duration, limit int, now time.Time) ([]Message, error)

	// MarkSent 发送成功:status='sent' + sent_at。
	MarkSent(ctx context.Context, id string, sentAt time.Time) error

	// MarkRetry 发送失败但未达上限:status='failed' + retry_count+1 + last_error + next_attempt_at(backoff)。
	MarkRetry(ctx context.Context, id, errMsg string, nextAttemptAt time.Time) error

	// MarkFailed 达到上限终态:status='failed' + retry_count+1 + last_error(因 retry_count>=max 不再被 claim)。
	MarkFailed(ctx context.Context, id, errMsg string) error

	// GetByDedupKey 按幂等键查(测试 / enqueue 冲突回查用)。未命中返回 errors.ErrNotFound。
	GetByDedupKey(ctx context.Context, tenantID, dedupKey string) (Message, error)
}

// backoffSchedule capped 退避表:1s, 5s, 15s, 1m, 5m,之后封顶 5m。
var backoffSchedule = []time.Duration{
	1 * time.Second,
	5 * time.Second,
	15 * time.Second,
	1 * time.Minute,
	5 * time.Minute,
}

// BackoffDelay 第 attempt 次失败(attempt 从 1 起)后,下次尝试的间隔;超出表长封顶为最后一档。
func BackoffDelay(attempt int) time.Duration {
	idx := attempt - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(backoffSchedule) {
		idx = len(backoffSchedule) - 1
	}
	return backoffSchedule[idx]
}
