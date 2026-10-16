package drive

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// ShareRepo F06 §2.6 drive_share_links 的 PG 实现.
type ShareRepo struct{ pool *pgxpool.Pool }

// NewShareRepo 构造.
func NewShareRepo(pool *pgxpool.Pool) *ShareRepo { return &ShareRepo{pool: pool} }

// GetByID 按 id 查 1 行; 软删 (is_deleted=true) 行不返回.
func (r *ShareRepo) GetByID(ctx context.Context, id int64) (*dom.ShareLink, error) {
	const q = `
        SELECT id, uuid, tenant_id, token, target_kind, target_id, role, download_disabled, expires_at, max_uses, used_count, revoked_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_share_links
        WHERE id = $1 AND is_deleted = false
    `
	var s dom.ShareLink
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&s.ID, &s.UUID, &s.TenantID, &s.Token, &s.TargetKind, &s.TargetID, &s.Role, &s.DownloadDisabled, &s.ExpiresAt, &s.MaxUses, &s.UsedCount, &s.RevokedAt,
		&s.CreatedAt, &s.CreatedBy, &s.UpdatedAt, &s.UpdatedBy, &s.IsDeleted, &s.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.ShareRepo.GetByID: %w", err)
	}
	return &s, nil
}
