package localmedia

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localmedia"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool} }

// All reads and writes join the owner task. The HTTP/service run authorization also checks live login and lease.
const scope = ` t.uuid=m.run_uuid AND t.tenant_id=$1 AND t.account_id=$2 AND t.uuid=$3 AND t.fence=$4 `

func (r *Repo) Claim(ctx context.Context, t *local.Task, id, digest string) (*dom.Record, bool, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	out := &dom.Record{}
	err = tx.QueryRow(ctx, `INSERT INTO local_runtime_media(run_uuid,operation_id,request_hash,state)
 SELECT uuid,$5,$6,'submitting' FROM local_runtime_tasks WHERE tenant_id=$1 AND account_id=$2 AND uuid=$3 AND fence=$4 AND status='accepted' AND expires_at>now()
 ON CONFLICT DO NOTHING RETURNING operation_id,request_hash,state`, t.Scope.TenantID, t.Scope.AccountID, t.UUID, t.Fence, id, digest).Scan(&out.ID, &out.Digest, &out.State)
	fresh := err == nil
	if errors.Is(err, pgx.ErrNoRows) {
		err = tx.QueryRow(ctx, `SELECT m.operation_id,m.request_hash,m.state,CASE WHEN m.result_expires_at>now() THEN m.image ELSE NULL END
  FROM local_runtime_media m,local_runtime_tasks t WHERE `+scope+` AND (m.operation_id=$5 OR m.request_hash=$6) ORDER BY (m.operation_id=$5) DESC LIMIT 1`, t.Scope.TenantID, t.Scope.AccountID, t.UUID, t.Fence, id, digest).Scan(&out.ID, &out.Digest, &out.State, &out.Image)
	}
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			err = local.ErrDenied
		}
		return nil, false, err
	}
	if out.Digest != digest {
		return nil, false, dom.ErrConflict
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	return out, fresh, nil
}
func (r *Repo) Complete(ctx context.Context, t *local.Task, id string, b []byte) error {
	result, err := r.pool.Exec(ctx, `UPDATE local_runtime_media m SET state='completed',image=$6,result_expires_at=now()+interval '24 hours',updated_at=now()
 FROM local_runtime_tasks t WHERE `+scope+` AND m.operation_id=$5 AND m.state='submitting'`, t.Scope.TenantID, t.Scope.AccountID, t.UUID, t.Fence, id, b)
	if err == nil && result.RowsAffected() != 1 {
		return dom.ErrConflict
	}
	return err
}
func (r *Repo) Uncertain(ctx context.Context, t *local.Task, id string) error {
	_, err := r.pool.Exec(ctx, `UPDATE local_runtime_media m SET state='unknown',updated_at=now() FROM local_runtime_tasks t WHERE `+scope+` AND m.operation_id=$5 AND m.state='submitting'`, t.Scope.TenantID, t.Scope.AccountID, t.UUID, t.Fence, id)
	return err
}
func (r *Repo) Reject(ctx context.Context, t *local.Task, id string) error {
	result, err := r.pool.Exec(ctx, `UPDATE local_runtime_media m SET state='failed',updated_at=now() FROM local_runtime_tasks t WHERE `+scope+` AND m.operation_id=$5 AND m.state='submitting'`, t.Scope.TenantID, t.Scope.AccountID, t.UUID, t.Fence, id)
	if err == nil && result.RowsAffected() != 1 {
		return dom.ErrConflict
	}
	return err
}
func (r *Repo) ExpireResults(ctx context.Context) error {
	_, err := r.pool.Exec(ctx, `UPDATE local_runtime_media SET image=NULL WHERE (run_uuid,operation_id) IN (SELECT run_uuid,operation_id FROM local_runtime_media WHERE image IS NOT NULL AND result_expires_at<=now() LIMIT 100)`)
	return err
}
