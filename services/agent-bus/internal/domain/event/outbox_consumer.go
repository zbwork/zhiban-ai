// Package event 消费侧接口 (F09-A6-04).
//
// publisher.go 已定义生产侧 (Publisher.Publish 写 events_outbox 行).
// 本文件加消费侧 (Consumer 接口) — 给 cmd/worker / cmd/audit-writer 用.
//
// 设计参 F07 kb_outbox 的 dispatcher 模式 + ADR-0002:
//   1. 跟 events_outbox 表的 status / next_retry_at / locked_* 字段对齐
//   2. SKIP LOCKED + locked_until 兜底防多 worker 并发
//   3. status 状态机: pending → picked → done | failed → (next_retry_at, attempts++) → pending → ... → attempts ≥ max → dlq
//   4. dlq 行同时复制到 events_outbox_dlq (M0 schema 已建)
//
// 接口刻意窄: GetPending / Claim / MarkDone / MarkFailed / MarkDLQ / Release; 不暴露事务句柄给 dispatcher (worker 内部各 tick 独立短 tx).

package event

import (
	"context"
	"time"
)

// PendingEvent · Consumer.Claim 返回的事件视图.
//
// 跟 publisher.Event 的差别: 多带消费侧需要的元数据 (ID / Attempts / 已 lock 信息).
type PendingEvent struct {
	ID             int64
	Topic          string
	TenantID       int64  // 0 = 平台级
	TraceID        string // 可空
	IdempotencyKey string // 可空
	Payload        []byte // JSONB raw

	Status      string // 拿到的瞬时状态 (一般是 "picked")
	Attempts    int16  // 已尝试次数 (含本次 claim 前的)
	LastError   string // 上次失败原因 (空 = 首次或前次成功部分)
	CreatedAt   time.Time
	NextRetryAt time.Time // 调用方一般不用; 仅诊断用 (零值 = 未设置)
}

// Consumer · events_outbox 消费侧接口 (F09-A6-04).
//
// 实现侧 internal/repository/postgres/event/outbox_consumer.go 用 SKIP LOCKED 模式;
// 多 worker 副本并发安全.
type Consumer interface {
	// Claim 一次拉一批待处理事件; 内部 UPDATE 把 status=pending+到期 的行转 picked + lock_until=now()+lockTTL.
	//
	// topics: topic LIKE 任一前缀 (e.g. ["runtime.%"]); 空切片 = 拉全部.
	// batchSize: 单 tick 上限.
	// workerID: 写入 locked_by; 用 hostname+pid+随机 字符串.
	// lockTTL: 写入 locked_until = now() + lockTTL; 单次处理预期最大耗时 * 2 为佳.
	//
	// 返回的事件已经 picked + locked; 即使本函数返回后 worker 进程崩溃,
	// 也仅在 locked_until 之内不会被其它 worker 重领, 过期后自动释放.
	//
	// 没有可领事件时返 (nil, nil).
	Claim(ctx context.Context, topics []string, batchSize int, workerID string, lockTTL time.Duration) ([]PendingEvent, error)

	// MarkDone · 事件处理成功 → status=done + done_at=now() + 清 lock.
	MarkDone(ctx context.Context, id int64) error

	// MarkFailed · 事件处理失败 → attempts++ + last_error=errMsg + 清 lock;
	//   若 attempts < maxAttempts: status=pending + next_retry_at = now() + backoff
	//   若 attempts >= maxAttempts: status=dlq + 同步 INSERT events_outbox_dlq + dlq_reason="attempts_exhausted"
	//
	// dispatcher 调用方负责算 backoff 时间; 本接口不内嵌策略.
	MarkFailed(ctx context.Context, id int64, errMsg string, nextRetryAt time.Time, maxAttempts int) error

	// Release · 显式提前释放 lock (e.g. worker 优雅退出时把未处理的行 lock 清掉).
	// 不改 status / attempts; 仅清 locked_by / locked_until.
	Release(ctx context.Context, id int64) error
}
