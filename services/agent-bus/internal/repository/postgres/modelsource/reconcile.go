package modelsource

import (
	"context"
	"fmt"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
)

// Shares the member lock with sync and refresh; no stale pre-lock snapshot can
// retire a source that another request just changed.
func (r *Repo) Reconcile(ctx context.Context, scope dom.Scope, transform func([]dom.Stored) ([]dom.Stored, error)) ([]dom.Stored, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, fmt.Sprintf("model-sources:%d:%d", scope.TenantID, scope.AccountID)); err != nil {
		return nil, err
	}
	var allowed bool
	if err = tx.QueryRow(ctx, `SELECT `+member, scope.TenantID, scope.AccountID).Scan(&allowed); err != nil {
		return nil, err
	}
	if !allowed {
		return nil, dom.ErrDenied
	}
	rows, err := tx.Query(ctx, `SELECT `+cols+` FROM member_model_sources WHERE tenant_id=$1 AND account_id=$2 ORDER BY updated_at,source_id FOR UPDATE`, scope.TenantID, scope.AccountID)
	if err != nil {
		return nil, err
	}
	current := []dom.Stored{}
	for rows.Next() {
		row, e := read(rows)
		if e != nil {
			rows.Close()
			return nil, e
		}
		current = append(current, *row)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	changes, err := transform(current)
	if err != nil {
		return nil, err
	}
	for _, v := range changes {
		index := -1
		for i := range current {
			if current[i].UUID == v.UUID {
				index = i
				break
			}
		}
		if index < 0 {
			return nil, dom.ErrDenied
		}
		updated, e := read(tx.QueryRow(ctx, `UPDATE member_model_sources SET source_id=$4,fingerprint=$5,enabled=$6,config_ciphertext=$7,version=version+1,updated_at=now() WHERE tenant_id=$1 AND account_id=$2 AND uuid::text=$3 RETURNING `+cols, scope.TenantID, scope.AccountID, v.UUID, v.SourceID, v.Fingerprint, v.Enabled, v.Ciphertext))
		if e != nil {
			return nil, e
		}
		current[index] = *updated
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return current, nil
}
