package agentkb

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentkb"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo {
	if pool == nil {
		panic("agentkb.Repo: pool required")
	}
	return &Repo{pool: pool}
}

const cols = `id, agent_id, kb_id, binding_kind, priority, note, created_by, created_at, updated_at`

func scan(row pgx.Row) (*dom.Binding, error) {
	b := &dom.Binding{}
	err := row.Scan(&b.ID, &b.AgentID, &b.KBID, &b.BindingKind, &b.Priority, &b.Note,
		&b.CreatedBy, &b.CreatedAt, &b.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return b, nil
}

func (r *Repo) Attach(ctx context.Context, agentID, kbID, createdBy int64, kind string, priority int) (*dom.Binding, error) {
	if kind == "" {
		kind = dom.KindAttached
	}
	row := r.pool.QueryRow(ctx, `
INSERT INTO agent_kb_bindings (agent_id, kb_id, binding_kind, priority, created_by)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (agent_id, kb_id) WHERE deleted_at IS NULL
DO UPDATE SET binding_kind = EXCLUDED.binding_kind, priority = EXCLUDED.priority, updated_at = now()
RETURNING `+cols, agentID, kbID, kind, priority, createdBy)
	b, err := scan(row)
	if err != nil {
		return nil, err
	}
	return b, nil
}

func (r *Repo) Detach(ctx context.Context, agentID, kbID int64) error {
	tag, err := r.pool.Exec(ctx, `
UPDATE agent_kb_bindings SET deleted_at = now(), updated_at = now()
WHERE agent_id = $1 AND kb_id = $2 AND deleted_at IS NULL`, agentID, kbID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (r *Repo) ListByAgent(ctx context.Context, agentID int64) ([]*dom.Binding, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+cols+`
FROM agent_kb_bindings WHERE agent_id = $1 AND deleted_at IS NULL
ORDER BY priority DESC, id ASC`, agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]*dom.Binding, 0)
	for rows.Next() {
		b, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// ReplaceForAgent replaces the caller-managed personal/tenant binding subset.
// Platform bindings come only from trusted template copy and are always kept,
// including when kbIDs is empty.
func (r *Repo) ReplaceForAgent(ctx context.Context, agentID, createdBy int64, kbIDs []int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	// Do not let a client save erase a platform binding that it cannot read or
	// submit back. Other scopes remain actor-validated by the service layer.
	if _, err := tx.Exec(ctx, `
UPDATE agent_kb_bindings b SET deleted_at = now(), updated_at = now()
FROM knowledge_bases k
WHERE b.kb_id = k.id
  AND b.agent_id = $1
  AND b.deleted_at IS NULL
  AND k.space_kind IN ('personal','tenant')`, agentID); err != nil {
		return err
	}
	n := len(kbIDs)
	for i, kbID := range kbIDs {
		// priority 倒序: 第一个 kb 优先级最高 (与 ListByAgent 的 ORDER BY priority DESC 一致)。
		tag, err := tx.Exec(ctx, `
INSERT INTO agent_kb_bindings (agent_id, kb_id, binding_kind, priority, created_by)
SELECT $1, k.id, $3, $4, $5
  FROM knowledge_bases k
 WHERE k.id=$2 AND k.deleted_at IS NULL AND k.space_kind IN ('personal','tenant')
ON CONFLICT (agent_id, kb_id) WHERE deleted_at IS NULL
DO UPDATE SET binding_kind = EXCLUDED.binding_kind, priority = EXCLUDED.priority,
              deleted_at = NULL, updated_at = now()`,
			agentID, kbID, dom.KindAttached, n-i, createdBy)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return apperr.ErrForbidden.Withf("client cannot bind knowledge base %d", kbID)
		}
	}
	return tx.Commit(ctx)
}

// ReplaceAdminTenantForAgent 仅替换后台可管理的租户级 KB 绑定, 保留用户个人私有 KB 绑定。
func (r *Repo) ReplaceAdminTenantForAgent(ctx context.Context, agentID, createdBy int64, kbIDs []int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `
UPDATE agent_kb_bindings b SET deleted_at = now(), updated_at = now()
FROM knowledge_bases k
WHERE b.kb_id = k.id
  AND b.agent_id = $1
  AND b.deleted_at IS NULL
  AND k.space_kind = 'tenant'
  AND k.visibility = 'tenant'`, agentID); err != nil {
		return err
	}
	n := len(kbIDs)
	for i, kbID := range kbIDs {
		tag, err := tx.Exec(ctx, `
INSERT INTO agent_kb_bindings (agent_id, kb_id, binding_kind, priority, created_by)
SELECT $1, k.id, $3, $4, $5
  FROM knowledge_bases k
 WHERE k.id=$2 AND k.deleted_at IS NULL
   AND k.space_kind='tenant' AND k.visibility='tenant'
ON CONFLICT (agent_id, kb_id) WHERE deleted_at IS NULL
DO UPDATE SET binding_kind = EXCLUDED.binding_kind, priority = EXCLUDED.priority,
              deleted_at = NULL, updated_at = now()`,
			agentID, kbID, dom.KindAttached, n-i, createdBy)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return apperr.ErrForbidden.Withf("tenant admin cannot bind knowledge base %d", kbID)
		}
	}
	return tx.Commit(ctx)
}

func (r *Repo) IsBound(ctx context.Context, agentID, kbID int64) (bool, error) {
	var exists bool
	err := r.pool.QueryRow(ctx, `
SELECT EXISTS (
  SELECT 1 FROM agent_kb_bindings
  WHERE agent_id = $1 AND kb_id = $2 AND deleted_at IS NULL
)`, agentID, kbID).Scan(&exists)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return false, err
	}
	return exists, nil
}
