// Package event PostgreSQL 实现 events_outbox publisher（M0 最小事件底座）。
//
// 关键设计:
//   - Publish 必须在调用方提供的事务内执行（pgx.Tx 由 PgTx 包装），保证 outbox 写入与业务变更原子。
//   - idempotency_key 命中 partial UNIQUE 冲突时返回 domain.ErrDuplicate；调用方一般忽略即可。
//   - tenant_id=0 转 NULL；trace_id/idempotency_key 空串转 NULL。
package event

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
)

// PgTx 把 pgx.Tx 包装成 domain.Tx；业务代码看不到 pgx 类型。
type PgTx struct{ Tx pgx.Tx }

func (PgTx) txMarker() {}

// WrapTx 把 pgx.Tx 包成 domain.Tx。
func WrapTx(tx pgx.Tx) dom.Tx { return PgTx{Tx: tx} }

// Publisher 是 events_outbox 的 Postgres 实现。
type Publisher struct {
	// pool 仅用于"不在事务中"的健康检查或后台任务（本期不暴露）。
	pool *pgxpool.Pool
}

// New 构造。pool 可为 nil（如仅在事务里用）。
func New(pool *pgxpool.Pool) *Publisher { return &Publisher{pool: pool} }

// Publish 实现 domain.Publisher.Publish。
func (p *Publisher) Publish(ctx context.Context, tx dom.Tx, evt dom.Event) error {
	if evt.Topic == "" {
		return errors.New("event.Publish: topic is required")
	}
	if len(evt.Payload) == 0 {
		return errors.New("event.Publish: payload is required")
	}
	pgxTx, ok := tx.(PgTx)
	if !ok {
		return fmt.Errorf("event.Publish: tx must be PgTx, got %T", tx)
	}

	var tenantID any
	if evt.TenantID > 0 {
		tenantID = evt.TenantID
	}
	var traceID any
	if evt.TraceID != "" {
		traceID = evt.TraceID
	}
	var idemKey any
	if evt.IdempotencyKey != "" {
		idemKey = evt.IdempotencyKey
	}

	_, err := pgxTx.Tx.Exec(ctx, `
INSERT INTO events_outbox(topic, tenant_id, trace_id, payload, idempotency_key)
VALUES ($1, $2, $3, $4::jsonb, $5)`,
		evt.Topic, tenantID, traceID, string(evt.Payload), idemKey,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == "uq_outbox_idemp_key" {
			return dom.ErrDuplicate
		}
		return fmt.Errorf("event.Publish: %w", err)
	}
	return nil
}
