package auth

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"

	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	evtrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

// PgEventBus 把 EventBusPublisher 适配到 events_outbox。
// 每次 PublishAudit 用独立短事务包一次（best-effort，不影响主流程）。
type PgEventBus struct {
	Pool      *pgxpool.Pool
	Publisher domevt.Publisher
}

// NewPgEventBus 构造。
func NewPgEventBus(pool *pgxpool.Pool) *PgEventBus {
	return &PgEventBus{Pool: pool, Publisher: evtrepo.New(pool)}
}

// PublishAudit 实现 EventBusPublisher.PublishAudit。
//
// payload schema 与 internal/service/auditwriter/loop.go 的 auditPayloadShape 对齐。
func (e *PgEventBus) PublishAudit(ctx context.Context, evt AuditEvent) error {
	if evt.Topic == "" {
		return nil
	}
	domain := evt.Domain
	if domain == "" {
		domain = "auth"
	}
	kind := evt.EventKind
	if kind == "" {
		kind = evt.Topic
	}
	severity := evt.Severity
	if severity == "" {
		severity = "info"
	}

	dataB, _ := json.Marshal(evt.Data)
	if len(dataB) == 0 {
		dataB = []byte("{}")
	}

	payload, _ := json.Marshal(map[string]any{
		"actor_kind": "user",
		"acting_as":  "",
		"domain":     domain,
		"event_kind": kind,
		"severity":   severity,
		"account_id": evt.AccountID,
		"ip":         evt.IP,
		"ua":         evt.UserAgent,
		"data":       json.RawMessage(dataB),
	})

	tx, err := e.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	if err := e.Publisher.Publish(ctx, evtrepo.WrapTx(tx), domevt.Event{
		Topic:          evt.Topic,
		TenantID:       evt.TenantID,
		TraceID:        evt.TraceID,
		IdempotencyKey: evt.IdempotencyKey,
		Payload:        payload,
	}); err != nil {
		_ = tx.Rollback(ctx)
		if errors.Is(err, domevt.ErrDuplicate) {
			return nil
		}
		return err
	}
	return tx.Commit(ctx)
}
