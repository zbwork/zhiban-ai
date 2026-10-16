// Package chattask 定义 doc-11 / doc-12 Task D 聊天消息队列 (chat_message_tasks) 的领域类型与仓储接口。
//
// 任务态 (queued|running|done|failed|cancelled|dlq) **独立于** messages.status —— 不污染消息枚举。
// Postgres 是事实源; 集群多 worker 用 FOR UPDATE SKIP LOCKED + lease 抢任务; 同 conversation 同时最多 1 条 running。
package chattask

import (
	"context"
	"time"
)

// Status 任务态 (跟 migration 000023 CHECK 一致)。
const (
	StatusQueued    = "queued"
	StatusRunning   = "running"
	StatusDone      = "done"
	StatusFailed    = "failed"
	StatusCancelled = "cancelled"
	StatusDLQ       = "dlq" // 超 max_attempts 的死信终态
)

// Task 一行 chat_message_tasks。
type Task struct {
	ID               int64
	UUID             string
	TenantID         int64
	AccountID        int64
	ConversationID   int64
	ConversationUUID string
	RoomUUID         string
	AgentUUID        string
	AgentMessageUUID string
	StreamID         string
	// UserMessageUUID 已落库 user 消息 uuid。任务表**不复制用户正文**; worker 据此回读 messages 取 prompt。
	UserMessageUUID string
	Status          string
	Attempts        int
	MaxAttempts     int
	NextRetryAt     time.Time
	LastError       string
	CreatedAt       time.Time
}

// EnqueueInput 入队一条聊天任务 (Send 创建 user/agent 预建消息 + stream 后调用)。
type EnqueueInput struct {
	TenantID         int64
	AccountID        int64
	ConversationID   int64
	ConversationUUID string
	RoomUUID         string
	AgentUUID        string
	AgentMessageUUID string
	StreamID         string
	UserMessageUUID  string // 任务表存 uuid 引用, 不复制用户正文
}

// Repository chat_message_tasks 持久层 (实现见 internal/repository/postgres/chattask)。
type Repository interface {
	// Enqueue 写一条 queued 任务。agent_message_uuid 幂等键 (UNIQUE) 撞约束 → 返回 (nil, ErrConflict)。
	Enqueue(ctx context.Context, in EnqueueInput) (*Task, error)

	// ClaimNext 抢 **1 条** 可执行任务 (queued + next_retry_at<=now + **该 conversation 当前无 running**),
	// FOR UPDATE SKIP LOCKED + 置 running + lease(locked_by/locked_until) + attempts++; 无可抢返回 (nil, nil)。
	// 同会话串行由"排除 running"+ partial unique uq_cmt_running_conv 双重保证 (集群安全)。
	ClaimNext(ctx context.Context, workerID string, lockTTL time.Duration) (*Task, error)

	// MarkDone 执行完成 (Agent 调用已跑完并 finalize 消息) → status='done' + completed_at。
	MarkDone(ctx context.Context, id int64) error

	// MarkRetry 真实失败但 attempts<max → status='queued' + next_retry_at 退避 + 释放 lease (attempts 已在 claim 时 +1)。
	MarkRetry(ctx context.Context, id int64, errMsg string, nextRetryAt time.Time) error

	// MarkDLQ attempts 达 max 的死信 → status='dlq' (终态) + last_error。
	MarkDLQ(ctx context.Context, id int64, errMsg string) error

	// MarkFailed 配置/不可恢复错误 → status='failed' (终态, 不重试)。
	MarkFailed(ctx context.Context, id int64, errMsg string) error

	// MarkDeferred 实例/Agent 未就绪的**正常等待** → 回 queued + 退避 + 释放 lease, **不消耗 attempts** (claim 已 +1, 这里 -1 还原)。
	MarkDeferred(ctx context.Context, id int64, reason string, nextRetryAt time.Time) error

	// RequeueExpired lease 恢复: running 且 locked_until<now → queued + 退避 + 释放 lease; 返回回收条数。
	RequeueExpired(ctx context.Context, nextRetryAt time.Time, limit int) (int64, error)

	// CancelQueuedByAgentMessage stop 端点用: 若该 agent 消息对应任务仍 queued → 原子置 cancelled,
	// 返回被取消的任务行 (含 ConversationUUID/RoomUUID, 供 caller finalize 预建消息); 已 running/终态/不存在 → (nil,nil)
	//（running 由现有 stream cancel 处理）。tenant 隔离。RETURNING 一次完成, 无 TOCTOU。
	CancelQueuedByAgentMessage(ctx context.Context, tenantID int64, agentMessageUUID string) (*Task, error)

	// CountActiveByConversation / CountActiveByTenant: backlog 硬限计数 (queued+running)。
	CountActiveByConversation(ctx context.Context, conversationID int64) (int, error)
	CountActiveByTenant(ctx context.Context, tenantID int64) (int, error)
}
