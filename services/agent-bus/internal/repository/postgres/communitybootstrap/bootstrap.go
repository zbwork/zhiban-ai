// Package communitybootstrap owns the one-time community administrator transaction.
package communitybootstrap

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrAlreadyInitialized = errors.New("platform administrator already exists")

type Repository struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repository { return &Repository{pool: pool} }

// Create never updates an existing account or credential.
func (r *Repository) Create(ctx context.Context, email, name, passwordHash string) (int64, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(780143219)"); err != nil {
		return 0, err
	}
	var exists bool
	if err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM admin_accounts WHERE is_platform=true)").Scan(&exists); err != nil {
		return 0, err
	}
	if exists {
		return 0, ErrAlreadyInitialized
	}
	var roleID int64
	if err = tx.QueryRow(ctx, "SELECT id FROM roles WHERE code='platform.admin' AND scope_kind='platform' AND tenant_id IS NULL").Scan(&roleID); err != nil {
		return 0, err
	}
	var id int64
	if err = tx.QueryRow(ctx, "INSERT INTO accounts(email,display_name,password_hash,password_set_at,status,locale,timezone) VALUES($1,$2,$3,now(),'active','zh-CN','Asia/Shanghai') RETURNING id", email, name, passwordHash).Scan(&id); err != nil {
		return 0, err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO admin_accounts(account_id,is_platform,must_change_password) VALUES($1,true,false)", id); err != nil {
		return 0, err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO role_assignments(account_id,role_id,scope_kind,note) VALUES($1,$2,'platform','community bootstrap')", id, roleID); err != nil {
		return 0, err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO events_outbox(topic,payload) VALUES('audit.community.bootstrap',jsonb_build_object('actor_kind','system','domain','community','event_kind','bootstrap','data',jsonb_build_object('account_id',$1::bigint)))", id); err != nil {
		return 0, err
	}
	if err = tx.Commit(ctx); err != nil {
		return 0, err
	}
	return id, nil
}
