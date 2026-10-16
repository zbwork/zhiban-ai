// Package authaudit auth_audit_events PostgreSQL 实现。
package authaudit

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/authaudit"
)

// Repo authaudit.Repository 的 Postgres 实现。
type Repo struct{ pool *pgxpool.Pool }

// New 构造。
func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// Insert 写一行审计事件。
func (r *Repo) Insert(ctx context.Context, e dom.Event) error {
	meta := []byte("{}")
	if len(e.Metadata) > 0 {
		b, err := json.Marshal(e.Metadata)
		if err == nil {
			meta = b
		}
	}
	_, err := r.pool.Exec(ctx, `
INSERT INTO auth_audit_events
  (account_id, session_id, event_kind, event_status, actor_kind,
   tenant_id, workspace_id, login_method, target, reason,
   ip, user_agent, metadata)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::inet,$12,$13::jsonb)`,
		e.AccountID, e.SessionID, string(e.Kind), string(e.Status), nullIfEmpty(e.ActorKind),
		e.TenantID, e.WorkspaceID, nullIfEmpty(e.LoginMethod), nullIfEmpty(e.Target), nullIfEmpty(e.Reason),
		nullIfEmpty(e.IP), nullIfEmpty(e.UserAgent), string(meta),
	)
	return err
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
