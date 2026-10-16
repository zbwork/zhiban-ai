// Package audit audit_events PostgreSQL 实现（v1 普通表；ADR 0002）。
package audit

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
)

// Store 实现 domain.audit.Store。
type Store struct{ pool *pgxpool.Pool }

// New 构造。
func New(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

const insertSQL = `
INSERT INTO audit_events
  (occurred_at, tenant_id, account_id, actor_kind, acting_as,
   domain, event_kind, severity, resource_kind, resource_uuid,
   target_account_id, target_resource_uuid, trace_id, ip, ua,
   payload, duration_ms)
VALUES ($1, $2, $3, $4, $5,
        $6, $7, $8, $9, $10,
        $11, $12, $13, $14::inet, $15,
        $16::jsonb, $17)`

func argsFor(e dom.Event) []any {
	sev := string(e.Severity)
	if sev == "" {
		sev = string(dom.SeverityInfo)
	}
	payload := string(e.Payload)
	if payload == "" {
		payload = "{}"
	}
	return []any{
		e.OccurredAt,
		nullIfZero(e.TenantID),
		nullIfZero(e.AccountID),
		string(e.ActorKind),
		e.ActingAs,
		e.Domain,
		e.EventKind,
		sev,
		nullIfEmpty(e.ResourceKind),
		nullIfEmpty(e.ResourceUUID),
		nullIfZero(e.TargetAccountID),
		nullIfEmpty(e.TargetResourceUUID),
		nullIfEmpty(e.TraceID),
		nullIfEmpty(e.IP),
		nullIfEmpty(e.UserAgent),
		payload,
		e.DurationMS,
	}
}

// Insert 写一行。
func (s *Store) Insert(ctx context.Context, e dom.Event) error {
	if err := validate(e); err != nil {
		return err
	}
	_, err := s.pool.Exec(ctx, insertSQL, argsFor(e)...)
	if err != nil {
		return fmt.Errorf("audit.Insert: %w", err)
	}
	return nil
}

// InsertMany 批量写（事务内）。
func (s *Store) InsertMany(ctx context.Context, events []dom.Event) error {
	if len(events) == 0 {
		return nil
	}
	for _, e := range events {
		if err := validate(e); err != nil {
			return err
		}
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		batch := &pgx.Batch{}
		for _, e := range events {
			batch.Queue(insertSQL, argsFor(e)...)
		}
		br := tx.SendBatch(ctx, batch)
		defer br.Close()
		for range events {
			if _, err := br.Exec(); err != nil {
				return fmt.Errorf("audit.InsertMany: %w", err)
			}
		}
		return nil
	})
}

func validate(e dom.Event) error {
	if e.OccurredAt.IsZero() {
		return errors.New("audit: occurred_at required")
	}
	if e.ActorKind == "" {
		return errors.New("audit: actor_kind required")
	}
	if e.Domain == "" {
		return errors.New("audit: domain required")
	}
	if e.EventKind == "" {
		return errors.New("audit: event_kind required")
	}
	return nil
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
