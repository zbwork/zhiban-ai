// Package event consumer PostgreSQL 实现 (F09-A6-04).
//
// 关键设计:
//   - Claim 用 CTE + SKIP LOCKED + RETURNING 一次 SQL 完成 (status pending→picked + locked_by/until + picked_at).
//   - MarkDone / MarkFailed 各自独立短 tx; 不复用 Publish 的事务句柄.
//   - MarkFailed: attempts ≥ maxAttempts → status=dlq + 同 tx INSERT events_outbox_dlq.
//   - 多副本 worker 安全靠 SKIP LOCKED + locked_until 过期兜底.

package event

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
)

// Consumer 是 events_outbox 消费侧的 Postgres 实现.
type Consumer struct {
	pool *pgxpool.Pool
}

// NewConsumer 构造. pool 不能为 nil.
func NewConsumer(pool *pgxpool.Pool) *Consumer { return &Consumer{pool: pool} }

// Claim 实现 dom.Consumer.Claim.
//
// 实现要点:
//   - 用 CTE 选 status=pending + 到期 (next_retry_at IS NULL OR <= now()) + 未持锁
//     (locked_until IS NULL OR < now()) 的行, FOR UPDATE SKIP LOCKED.
//   - 外层 UPDATE 把这批行转 picked + locked_by + locked_until + picked_at, RETURNING 所有列.
//   - len(topics)==0 → 拉所有 topic; 非空 → 多个 LIKE 用 ANY (string_to_array trick 简化为 OR).
//
// 调用方拿到 PendingEvent 后必须在 lockTTL 内调 MarkDone / MarkFailed / Release 之一;
// 否则 locked_until 过期后其它 worker 可重领该行.
func (c *Consumer) Claim(
	ctx context.Context, topics []string, batchSize int,
	workerID string, lockTTL time.Duration,
) ([]dom.PendingEvent, error) {
	if batchSize <= 0 {
		batchSize = 10
	}
	if workerID == "" {
		return nil, errors.New("event.Consumer.Claim: workerID is required")
	}
	if lockTTL <= 0 {
		lockTTL = 30 * time.Second
	}

	// 构造 topic 过滤 (LIKE 前缀; 调用方传 "runtime.%" 之类).
	// 用 string[] 参数 + ANY ($1) 的 LIKE 实现需要 PG 13+; 直接构造 OR 链更稳定.
	topicClause := ""
	args := []any{workerID, lockTTL.Milliseconds(), batchSize}
	if len(topics) > 0 {
		// $1=workerID $2=lockTTLms $3=batchSize; $4..$N=topics
		topicClause = " AND ("
		for i, tp := range topics {
			if i > 0 {
				topicClause += " OR "
			}
			topicClause += fmt.Sprintf("topic LIKE $%d", len(args)+1)
			args = append(args, tp)
		}
		topicClause += ")"
	}

	// CTE: 先选可用行, FOR UPDATE SKIP LOCKED 防并发.
	// 外层 UPDATE 把状态 / lock 写好, RETURNING 全部列.
	query := fmt.Sprintf(`
WITH claimed AS (
    SELECT id
      FROM events_outbox
     WHERE status = 'pending'
       AND (next_retry_at IS NULL OR next_retry_at <= now())
       AND (locked_until IS NULL OR locked_until < now())
       %s
     ORDER BY next_retry_at NULLS FIRST, created_at
     LIMIT $3 FOR UPDATE SKIP LOCKED
)
UPDATE events_outbox e
   SET status = 'picked',
       locked_by = $1,
       locked_until = now() + ($2::bigint * INTERVAL '1 millisecond'),
       picked_at = now()
  FROM claimed
 WHERE e.id = claimed.id
RETURNING e.id, e.topic, COALESCE(e.tenant_id, 0), COALESCE(e.trace_id, ''),
          COALESCE(e.idempotency_key, ''), e.payload,
          e.status, e.attempts, COALESCE(e.last_error, ''),
          e.created_at, COALESCE(e.next_retry_at, '1970-01-01'::timestamptz)
`, topicClause)

	rows, err := c.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("event.Consumer.Claim: %w", err)
	}
	defer rows.Close()

	var out []dom.PendingEvent
	for rows.Next() {
		var (
			ev           dom.PendingEvent
			payloadBytes []byte
		)
		if err := rows.Scan(
			&ev.ID, &ev.Topic, &ev.TenantID, &ev.TraceID,
			&ev.IdempotencyKey, &payloadBytes,
			&ev.Status, &ev.Attempts, &ev.LastError,
			&ev.CreatedAt, &ev.NextRetryAt,
		); err != nil {
			return nil, fmt.Errorf("event.Consumer.Claim scan: %w", err)
		}
		ev.Payload = payloadBytes
		out = append(out, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("event.Consumer.Claim rows: %w", err)
	}
	return out, nil
}

// MarkDone 实现 dom.Consumer.MarkDone.
func (c *Consumer) MarkDone(ctx context.Context, id int64) error {
	res, err := c.pool.Exec(ctx, `
UPDATE events_outbox
   SET status = 'done',
       done_at = now(),
       locked_by = NULL,
       locked_until = NULL,
       last_error = NULL
 WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("event.Consumer.MarkDone: %w", err)
	}
	if res.RowsAffected() == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// MarkFailed 实现 dom.Consumer.MarkFailed.
//
// 单 tx 内:
//  1. UPDATE events_outbox attempts++; 算出 newAttempts.
//  2. 若 newAttempts < maxAttempts: status=pending + next_retry_at=nextRetryAt + 清 lock.
//  3. 若 newAttempts >= maxAttempts: status=dlq + 清 lock + INSERT events_outbox_dlq.
func (c *Consumer) MarkFailed(
	ctx context.Context, id int64, errMsg string,
	nextRetryAt time.Time, maxAttempts int,
) error {
	if maxAttempts <= 0 {
		maxAttempts = 5
	}

	tx, err := c.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("event.Consumer.MarkFailed begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Step 1: attempts++ + last_error + 清 lock; 拿到 newAttempts 决定后续状态.
	var (
		newAttempts int16
		topic       string
		tenantID    *int64
		traceID     *string
		payload     []byte
		createdAt   time.Time
	)
	err = tx.QueryRow(ctx, `
UPDATE events_outbox
   SET attempts = attempts + 1,
       last_error = $2,
       locked_by = NULL,
       locked_until = NULL
 WHERE id = $1
RETURNING attempts, topic, tenant_id, trace_id, payload, created_at
`, id, errMsg).Scan(&newAttempts, &topic, &tenantID, &traceID, &payload, &createdAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sql.ErrNoRows
		}
		return fmt.Errorf("event.Consumer.MarkFailed update: %w", err)
	}

	if int(newAttempts) < maxAttempts {
		// 还能重试: status=pending + next_retry_at.
		_, err = tx.Exec(ctx, `
UPDATE events_outbox
   SET status = 'pending',
       next_retry_at = $2
 WHERE id = $1`, id, nextRetryAt)
		if err != nil {
			return fmt.Errorf("event.Consumer.MarkFailed reschedule: %w", err)
		}
	} else {
		// 进 dlq.
		_, err = tx.Exec(ctx, `
UPDATE events_outbox
   SET status = 'dlq',
       next_retry_at = NULL
 WHERE id = $1`, id)
		if err != nil {
			return fmt.Errorf("event.Consumer.MarkFailed mark dlq: %w", err)
		}
		// 复制行到 events_outbox_dlq.
		var tid any
		if tenantID != nil {
			tid = *tenantID
		}
		var trid any
		if traceID != nil {
			trid = *traceID
		}
		_, err = tx.Exec(ctx, `
INSERT INTO events_outbox_dlq
    (outbox_id, topic, tenant_id, trace_id, payload, last_error, attempts, created_at, dlq_reason)
VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8, 'attempts_exhausted')`,
			id, topic, tid, trid, string(payload), errMsg, newAttempts, createdAt)
		if err != nil {
			return fmt.Errorf("event.Consumer.MarkFailed insert dlq: %w", err)
		}
	}

	return tx.Commit(ctx)
}

// Release 实现 dom.Consumer.Release.
func (c *Consumer) Release(ctx context.Context, id int64) error {
	_, err := c.pool.Exec(ctx, `
UPDATE events_outbox
   SET locked_by = NULL,
       locked_until = NULL
 WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("event.Consumer.Release: %w", err)
	}
	return nil
}
