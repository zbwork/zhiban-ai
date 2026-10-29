package modelsource

import (
	"context"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool} }

const member = `EXISTS(SELECT 1 FROM tenant_memberships m JOIN accounts a ON a.id=m.account_id JOIN tenants t ON t.id=m.tenant_id WHERE m.tenant_id=$1 AND m.account_id=$2 AND m.status='active' AND m.deleted_at IS NULL AND a.status='active' AND a.deleted_at IS NULL AND t.status='active')`
const cols = `uuid::text,source_id,version,fingerprint,enabled,config_ciphertext`

func read(row pgx.Row) (*dom.Stored, error) {
	var s dom.Stored
	err := row.Scan(&s.UUID, &s.SourceID, &s.Version, &s.Fingerprint, &s.Enabled, &s.Ciphertext)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrDenied
	}
	return &s, err
}
func (r *Repo) Get(ctx context.Context, scope dom.Scope, id string) (*dom.Stored, error) {
	return read(r.pool.QueryRow(ctx, `SELECT `+cols+` FROM member_model_sources WHERE tenant_id=$1 AND account_id=$2 AND uuid::text=$3 AND `+member, scope.TenantID, scope.AccountID, id))
}
func (r *Repo) List(ctx context.Context, scope dom.Scope) ([]dom.Stored, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+cols+` FROM member_model_sources WHERE tenant_id=$1 AND account_id=$2 AND `+member+` ORDER BY updated_at,source_id`, scope.TenantID, scope.AccountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []dom.Stored{}
	for rows.Next() {
		s, e := read(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}
func (r *Repo) Replace(ctx context.Context, scope dom.Scope, values []dom.Stored) ([]dom.Stored, error) {
	return r.writeSources(ctx, scope, values, true)
}
func (r *Repo) Merge(ctx context.Context, scope dom.Scope, values []dom.Stored) ([]dom.Stored, error) {
	return r.writeSources(ctx, scope, values, false)
}
func (r *Repo) writeSources(ctx context.Context, scope dom.Scope, values []dom.Stored, replace bool) ([]dom.Stored, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var allowed bool
	if err = tx.QueryRow(ctx, `SELECT `+member, scope.TenantID, scope.AccountID).Scan(&allowed); err != nil {
		return nil, err
	}
	if !allowed {
		return nil, dom.ErrDenied
	}
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, fmt.Sprintf("model-sources:%d:%d", scope.TenantID, scope.AccountID)); err != nil {
		return nil, err
	}
	ids := []string{}
	for _, v := range values {
		ids = append(ids, v.SourceID)
	}
	if replace {
		if _, err = tx.Exec(ctx, `UPDATE member_model_sources SET enabled=false,version=version+1,updated_at=now() WHERE tenant_id=$1 AND account_id=$2 AND enabled AND NOT(source_id=ANY($3::text[]))`, scope.TenantID, scope.AccountID, ids); err != nil {
			return nil, err
		}
	}
	out := []dom.Stored{}
	for _, v := range values {
		s, e := read(tx.QueryRow(ctx, `INSERT INTO member_model_sources(tenant_id,account_id,source_id,fingerprint,enabled,config_ciphertext) VALUES($1,$2,$3,$4,$5,$6)
 ON CONFLICT(tenant_id,account_id,source_id) DO UPDATE SET fingerprint=excluded.fingerprint,enabled=excluded.enabled,config_ciphertext=excluded.config_ciphertext,
 version=member_model_sources.version+CASE WHEN member_model_sources.fingerprint<>excluded.fingerprint OR member_model_sources.enabled<>excluded.enabled THEN 1 ELSE 0 END,
 updated_at=CASE WHEN member_model_sources.fingerprint<>excluded.fingerprint OR member_model_sources.enabled<>excluded.enabled THEN now() ELSE member_model_sources.updated_at END RETURNING `+cols, scope.TenantID, scope.AccountID, v.SourceID, v.Fingerprint, v.Enabled, v.Ciphertext))
		if e != nil {
			return nil, e
		}
		out = append(out, *s)
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}
func (r *Repo) RunActive(ctx context.Context, scope dom.Scope, agentID int64, message string) (bool, error) {
	var ok bool
	err := r.pool.QueryRow(ctx, `SELECT `+member+` AND EXISTS(SELECT 1 FROM messages m JOIN conversations c ON c.id=m.conversation_id AND c.tenant_id=m.tenant_id WHERE m.tenant_id=$1 AND m.uuid::text=$3 AND m.sender_agent_id=$4 AND m.status='streaming' AND NOT m.final AND c.account_id=$2)`, scope.TenantID, scope.AccountID, message, agentID).Scan(&ok)
	return ok, err
}

// UpdateCatalog compares the pre-fetch version under the same lock as settings
// writes. It never recreates the source UUID or touches other sources.
func (r *Repo) UpdateCatalog(ctx context.Context, scope dom.Scope, expected *dom.Stored, value dom.Stored) (bool, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, fmt.Sprintf("model-sources:%d:%d", scope.TenantID, scope.AccountID)); err != nil {
		return false, err
	}
	var allowed bool
	if err = tx.QueryRow(ctx, `SELECT `+member, scope.TenantID, scope.AccountID).Scan(&allowed); err != nil {
		return false, err
	}
	if !allowed {
		return false, dom.ErrDenied
	}
	var n int64
	if expected == nil {
		tag, e := tx.Exec(ctx, `INSERT INTO member_model_sources(tenant_id,account_id,source_id,fingerprint,enabled,config_ciphertext) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(tenant_id,account_id,source_id) DO NOTHING`, scope.TenantID, scope.AccountID, value.SourceID, value.Fingerprint, value.Enabled, value.Ciphertext)
		if e != nil {
			return false, e
		}
		n = tag.RowsAffected()
	} else {
		tag, e := tx.Exec(ctx, `UPDATE member_model_sources SET fingerprint=$4,config_ciphertext=CASE WHEN fingerprint<>$4 THEN $5 ELSE config_ciphertext END,version=version+CASE WHEN fingerprint<>$4 THEN 1 ELSE 0 END,updated_at=CASE WHEN fingerprint<>$4 THEN now() ELSE updated_at END WHERE tenant_id=$1 AND account_id=$2 AND uuid::text=$3 AND version=$6 AND fingerprint=$7 AND source_id=$8`, scope.TenantID, scope.AccountID, expected.UUID, value.Fingerprint, value.Ciphertext, expected.Version, expected.Fingerprint, value.SourceID)
		if e != nil {
			return false, e
		}
		n = tag.RowsAffected()
	}
	if n != 1 {
		return false, nil
	}
	return true, tx.Commit(ctx)
}
