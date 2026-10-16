// Package auditwriter 实现 cmd/audit-writer 的核心消费 loop（M0 ADR 0002）。
//
// 设计:
//   - 单一 goroutine 轮询 events_outbox，每批 SKIP LOCKED 拉 BatchSize 行
//   - 只消费 audit.* topic → AuditStore.Insert
//   - 其他 topic 留给各自消费者，不能抢占标 done
//   - 单行失败：attempts++ + last_error；达到 MaxAttempts 时复制到 events_outbox_dlq + 标 status='dlq'
//   - 多实例：SELECT ... FOR UPDATE SKIP LOCKED 自然协调，无需外部锁
package auditwriter

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	audom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// Config 来自 config.AuditWriterConfig。
type Config struct {
	BatchSize    int
	PollMS       int
	BackoffMaxMS int
	MaxAttempts  int
}

// Loop 是核心消费循环；调用 Run 阻塞，ctx 取消时退出。
type Loop struct {
	pool   *pgxpool.Pool
	audit  audom.Store
	cfg    Config
	logger *logpkg.Logger
}

// New 构造。
func New(pool *pgxpool.Pool, audit audom.Store, cfg Config, logger *logpkg.Logger) *Loop {
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = 500
	}
	if cfg.PollMS <= 0 {
		cfg.PollMS = 200
	}
	if cfg.BackoffMaxMS <= 0 {
		cfg.BackoffMaxMS = 2000
	}
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = 5
	}
	return &Loop{pool: pool, audit: audit, cfg: cfg, logger: logger}
}

// Run 阻塞跑消费循环。ctx 取消时优雅退出。
func (l *Loop) Run(ctx context.Context) error {
	l.logger.Info(ctx, "audit-writer loop started",
		"batch_size", l.cfg.BatchSize,
		"poll_ms", l.cfg.PollMS,
		"max_attempts", l.cfg.MaxAttempts)

	currentSleep := time.Duration(l.cfg.PollMS) * time.Millisecond
	maxSleep := time.Duration(l.cfg.BackoffMaxMS) * time.Millisecond

	for {
		select {
		case <-ctx.Done():
			l.logger.Info(ctx, "audit-writer loop stopping", "reason", ctx.Err())
			return nil
		default:
		}

		n, err := l.consumeOnce(ctx)
		if err != nil {
			l.logger.Error(ctx, "audit-writer consumeOnce failed", "err", err)
			time.Sleep(currentSleep)
			continue
		}
		if n == 0 {
			// 空：指数退避到 maxSleep
			time.Sleep(currentSleep)
			currentSleep *= 2
			if currentSleep > maxSleep {
				currentSleep = maxSleep
			}
		} else {
			// 有事件：复位 sleep
			currentSleep = time.Duration(l.cfg.PollMS) * time.Millisecond
		}
	}
}

// consumeOnce 拉一批 + 处理；返回本批处理行数。
func (l *Loop) consumeOnce(ctx context.Context) (int, error) {
	tx, err := l.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }() // commit 成功后 rollback 是 no-op

	rows, err := tx.Query(ctx, `
SELECT id, topic, tenant_id, trace_id, payload, attempts
FROM events_outbox
WHERE (status='pending' OR (status='failed' AND attempts < $1))
  AND topic LIKE 'audit.%'
ORDER BY created_at
LIMIT $2
FOR UPDATE SKIP LOCKED`, l.cfg.MaxAttempts, l.cfg.BatchSize)
	if err != nil {
		return 0, fmt.Errorf("select for update: %w", err)
	}

	type row struct {
		ID       int64
		Topic    string
		TenantID *int64
		TraceID  *string
		Payload  []byte
		Attempts int16
	}
	var batch []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.ID, &r.Topic, &r.TenantID, &r.TraceID, &r.Payload, &r.Attempts); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan: %w", err)
		}
		batch = append(batch, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("rows err: %w", err)
	}
	if len(batch) == 0 {
		_ = tx.Commit(ctx)
		return 0, nil
	}

	// 处理每一行 → 决定 status 更新 / 进 DLQ
	for _, r := range batch {
		if err := l.processRow(ctx, tx, r.ID, r.Topic, tenantOrZero(r.TenantID), strOrEmpty(r.TraceID), r.Payload, int(r.Attempts)); err != nil {
			l.logger.Error(ctx, "audit-writer row failed",
				"outbox_id", r.ID, "topic", r.Topic, "err", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return len(batch), fmt.Errorf("commit: %w", err)
	}
	l.logger.Info(ctx, "audit-writer batch done", "count", len(batch))
	return len(batch), nil
}

// processRow 处理单行：写 audit_events / 标 done / 进 DLQ。
func (l *Loop) processRow(ctx context.Context, tx pgx.Tx, id int64, topic string, tenantID int64, traceID string, payload []byte, attempts int) error {
	now := time.Now()

	if strings.HasPrefix(topic, "audit.") {
		// 解析 payload 拿 audit 字段
		evt, err := parseAuditPayload(topic, tenantID, traceID, payload, now)
		if err != nil {
			return l.handleFailure(ctx, tx, id, attempts, fmt.Errorf("parse audit payload: %w", err))
		}
		// 写 audit_events（同事务）
		if err := insertAuditInTx(ctx, tx, evt); err != nil {
			return l.handleFailure(ctx, tx, id, attempts, fmt.Errorf("insert audit: %w", err))
		}
		return markDone(ctx, tx, id)
	}

	// consumeOnce 的 SELECT 已限制 audit.*；这里保留保护，避免调用方误传非 audit topic。
	l.logger.Warn(ctx, "audit-writer: no sink for topic; marking done",
		"outbox_id", id, "topic", topic)
	return markDone(ctx, tx, id)
}

// handleFailure 标 failed 或入 DLQ。
func (l *Loop) handleFailure(ctx context.Context, tx pgx.Tx, id int64, currentAttempts int, errIn error) error {
	newAttempts := currentAttempts + 1
	if newAttempts >= l.cfg.MaxAttempts {
		// 复制到 DLQ + 标 status='dlq'
		_, err := tx.Exec(ctx, `
INSERT INTO events_outbox_dlq
  (outbox_id, topic, tenant_id, trace_id, payload, last_error, attempts, created_at, dlq_reason)
SELECT id, topic, tenant_id, trace_id, payload, $2, $3, created_at, 'attempts_exhausted'
FROM events_outbox WHERE id=$1`, id, errIn.Error(), newAttempts)
		if err != nil {
			return fmt.Errorf("dlq insert: %w", err)
		}
		_, err = tx.Exec(ctx, `
UPDATE events_outbox SET status='dlq', attempts=$2, last_error=$3, done_at=now()
WHERE id=$1`, id, newAttempts, errIn.Error())
		if err != nil {
			return fmt.Errorf("mark dlq: %w", err)
		}
		l.logger.Warn(ctx, "audit-writer: row moved to DLQ", "outbox_id", id, "attempts", newAttempts)
		return nil
	}
	_, err := tx.Exec(ctx, `
UPDATE events_outbox SET status='failed', attempts=$2, last_error=$3, picked_at=now()
WHERE id=$1`, id, newAttempts, errIn.Error())
	if err != nil {
		return fmt.Errorf("mark failed: %w", err)
	}
	return nil
}

func markDone(ctx context.Context, tx pgx.Tx, id int64) error {
	_, err := tx.Exec(ctx, `
UPDATE events_outbox SET status='done', done_at=now()
WHERE id=$1`, id)
	if err != nil {
		return fmt.Errorf("mark done: %w", err)
	}
	return nil
}

// auditPayloadShape 是 audit.* topic payload 的预期结构。
// 字段名沿用 audit_events 列；调用方 publish 时按此构造。
type auditPayloadShape struct {
	AccountID          int64           `json:"account_id,omitempty"`
	ActorKind          string          `json:"actor_kind"`
	ActingAs           string          `json:"acting_as,omitempty"`
	Domain             string          `json:"domain"`
	EventKind          string          `json:"event_kind,omitempty"` // 可缺省 → topic 的最后段
	Severity           string          `json:"severity,omitempty"`
	ResourceKind       string          `json:"resource_kind,omitempty"`
	ResourceUUID       string          `json:"resource_uuid,omitempty"`
	TargetAccountID    int64           `json:"target_account_id,omitempty"`
	TargetResourceUUID string          `json:"target_resource_uuid,omitempty"`
	IP                 string          `json:"ip,omitempty"`
	UserAgent          string          `json:"ua,omitempty"`
	DurationMS         int32           `json:"duration_ms,omitempty"`
	Data               json.RawMessage `json:"data,omitempty"` // 业务自定义字段
}

func parseAuditPayload(topic string, tenantID int64, traceID string, payload []byte, occurredAt time.Time) (audom.Event, error) {
	var shape auditPayloadShape
	if err := json.Unmarshal(payload, &shape); err != nil {
		return audom.Event{}, fmt.Errorf("payload not json: %w", err)
	}
	if shape.Domain == "" {
		// 从 topic 推断：audit.<domain>.<event_kind>
		parts := strings.SplitN(topic, ".", 3)
		if len(parts) >= 2 {
			shape.Domain = parts[1]
		}
	}
	if shape.EventKind == "" {
		parts := strings.SplitN(topic, ".", 3)
		if len(parts) == 3 && parts[2] != "" {
			shape.EventKind = parts[2]
		} else {
			shape.EventKind = topic
		}
	}
	if shape.ActorKind == "" {
		// Historical audit publishers often wrote only business payload fields.
		// Keep writer strict for JSON shape, but derive actor kind so existing
		// outbox rows can drain instead of poisoning the queue forever.
		if shape.AccountID > 0 {
			shape.ActorKind = string(audom.ActorUser)
		} else {
			shape.ActorKind = string(audom.ActorSystem)
		}
	}
	// payload 字段已抽出后，把 data 作为最终 payload；data 为空就用原 payload
	finalPayload := shape.Data
	if len(finalPayload) == 0 {
		finalPayload = payload
	}

	return audom.Event{
		OccurredAt:         occurredAt,
		TenantID:           tenantID,
		AccountID:          shape.AccountID,
		ActorKind:          audom.ActorKind(shape.ActorKind),
		ActingAs:           shape.ActingAs,
		Domain:             shape.Domain,
		EventKind:          shape.EventKind,
		Severity:           audom.Severity(shape.Severity),
		ResourceKind:       shape.ResourceKind,
		ResourceUUID:       shape.ResourceUUID,
		TargetAccountID:    shape.TargetAccountID,
		TargetResourceUUID: shape.TargetResourceUUID,
		TraceID:            traceID,
		IP:                 shape.IP,
		UserAgent:          shape.UserAgent,
		Payload:            finalPayload,
		DurationMS:         shape.DurationMS,
	}, nil
}

func insertAuditInTx(ctx context.Context, tx pgx.Tx, e audom.Event) error {
	sev := string(e.Severity)
	if sev == "" {
		sev = string(audom.SeverityInfo)
	}
	payload := string(e.Payload)
	if payload == "" {
		payload = "{}"
	}
	_, err := tx.Exec(ctx, `
INSERT INTO audit_events
  (occurred_at, tenant_id, account_id, actor_kind, acting_as,
   domain, event_kind, severity, resource_kind, resource_uuid,
   target_account_id, target_resource_uuid, trace_id, ip, ua,
   payload, duration_ms)
VALUES ($1, $2, $3, $4, $5,
        $6, $7, $8, $9, $10,
        $11, $12, $13, $14::inet, $15,
        $16::jsonb, $17)`,
		e.OccurredAt,
		nullIfZero(e.TenantID), nullIfZero(e.AccountID),
		string(e.ActorKind), e.ActingAs,
		e.Domain, e.EventKind, sev,
		nullIfEmpty(e.ResourceKind), nullIfEmpty(e.ResourceUUID),
		nullIfZero(e.TargetAccountID), nullIfEmpty(e.TargetResourceUUID),
		nullIfEmpty(e.TraceID), nullIfEmpty(e.IP), nullIfEmpty(e.UserAgent),
		payload, e.DurationMS,
	)
	return err
}

func nullIfZero(v int64) any {
	if v == 0 {
		return nil
	}
	return v
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func tenantOrZero(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

func strOrEmpty(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
