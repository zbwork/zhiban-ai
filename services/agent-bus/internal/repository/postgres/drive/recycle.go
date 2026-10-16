package drive

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// RecycleRepo F06 §2.8 drive_recycle_bin 的 PG 实现.
type RecycleRepo struct{ pool *pgxpool.Pool }

// NewRecycleRepo 构造.
func NewRecycleRepo(pool *pgxpool.Pool) *RecycleRepo { return &RecycleRepo{pool: pool} }

// recycleColumns 标准列序; CreateTx / GetByID / GetByUUID / ListBySpaces 共用.
const recycleColumns = `id, uuid, tenant_id, target_kind, target_id, space_id, deleted_by,
	deleted_at_logical, expires_at, bytes_to_reclaim,
	created_at, created_by, updated_at, updated_by, is_deleted, deleted_at`

func scanRecycle(row pgx.Row, r *dom.RecycleEntry) error {
	return row.Scan(
		&r.ID, &r.UUID, &r.TenantID, &r.TargetKind, &r.TargetID, &r.SpaceID, &r.DeletedBy,
		&r.DeletedAtLogical, &r.ExpiresAt, &r.BytesToReclaim,
		&r.CreatedAt, &r.CreatedBy, &r.UpdatedAt, &r.UpdatedBy, &r.IsDeleted, &r.DeletedAt,
	)
}

// GetByID 按 id 查 1 行; 软删 (is_deleted=true) 行不返回.
func (r *RecycleRepo) GetByID(ctx context.Context, id int64) (*dom.RecycleEntry, error) {
	q := `SELECT ` + recycleColumns + ` FROM drive_recycle_bin WHERE id = $1 AND is_deleted = false`
	var r2 dom.RecycleEntry
	if err := scanRecycle(r.pool.QueryRow(ctx, q, id), &r2); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("drive.RecycleRepo.GetByID: %w", err)
	}
	return &r2, nil
}

// GetByUUID F06 Phase 2.2e: restore/purge 入口按 uuid 查 recycle 行.
// 已 tombstone 的 (is_deleted=true) 不返回 → 防 restore/purge 同 uuid 两次的幂等 NOOP.
func (r *RecycleRepo) GetByUUID(ctx context.Context, uuid string) (*dom.RecycleEntry, error) {
	q := `SELECT ` + recycleColumns + ` FROM drive_recycle_bin WHERE uuid::text = $1 AND is_deleted = false`
	var r2 dom.RecycleEntry
	if err := scanRecycle(r.pool.QueryRow(ctx, q, uuid), &r2); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("drive.RecycleRepo.GetByUUID: %w", err)
	}
	return &r2, nil
}

// LockByUUIDTx Phase 2.2e: SELECT FOR UPDATE 同行 (restore/purge 防并发).
// 仅锁未 tombstone 行; 已 tombstone → ErrNotFound.
func (r *RecycleRepo) LockByUUIDTx(ctx context.Context, tx pgx.Tx, uuid string) (*dom.RecycleEntry, error) {
	q := `SELECT ` + recycleColumns + ` FROM drive_recycle_bin WHERE uuid::text = $1 AND is_deleted = false FOR UPDATE`
	var r2 dom.RecycleEntry
	if err := scanRecycle(tx.QueryRow(ctx, q, uuid), &r2); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("drive.RecycleRepo.LockByUUIDTx: %w", err)
	}
	return &r2, nil
}

// CreateTx F06 Phase 2.2e: 软删 file/folder 时同事务插入回收站行.
// caller (FileSvc.Delete / FolderSvc.Delete) 负责: 同 TX 内先 SoftDeleteTx 后 CreateTx 本行.
func (r *RecycleRepo) CreateTx(ctx context.Context, tx pgx.Tx, in dom.CreateRecycleInput) error {
	const q = `
        INSERT INTO drive_recycle_bin (
            tenant_id, target_kind, target_id, space_id, deleted_by,
            deleted_at_logical, expires_at, bytes_to_reclaim,
            created_by, updated_by
        ) VALUES ($1, $2, $3, $4, $5, now(), $6, $7, $5, $5)
    `
	_, err := tx.Exec(ctx, q,
		in.TenantID, string(in.TargetKind), in.TargetID, in.SpaceID, in.DeletedBy,
		in.ExpiresAt, in.BytesToReclaim,
	)
	if err != nil {
		return fmt.Errorf("drive.RecycleRepo.CreateTx: %w", err)
	}
	return nil
}

// ListBySpaces F06 Phase 2.2e: 列出 caller manager+ space 内未 tombstone 的回收行.
// limit cap 200; spaceIDs 空 → 直接返 ([], 0). 按 deleted_at_logical DESC.
func (r *RecycleRepo) ListBySpaces(ctx context.Context, spaceIDs []int64, limit int) ([]dom.RecycleEntry, int, error) {
	if len(spaceIDs) == 0 {
		return nil, 0, nil
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	var total int
	if err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM drive_recycle_bin WHERE space_id = ANY($1) AND is_deleted = false`,
		spaceIDs).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("drive.RecycleRepo.ListBySpaces count: %w", err)
	}

	q := `SELECT ` + recycleColumns + `
        FROM drive_recycle_bin
        WHERE space_id = ANY($1) AND is_deleted = false
        ORDER BY deleted_at_logical DESC
        LIMIT $2`
	rows, err := r.pool.Query(ctx, q, spaceIDs, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.RecycleRepo.ListBySpaces: %w", err)
	}
	defer rows.Close()

	var out []dom.RecycleEntry
	for rows.Next() {
		var r2 dom.RecycleEntry
		if err := scanRecycle(rows, &r2); err != nil {
			return nil, 0, fmt.Errorf("drive.RecycleRepo.ListBySpaces scan: %w", err)
		}
		out = append(out, r2)
	}
	return out, total, rows.Err()
}

// ListByTenant Phase A2 admin: 列本租户全部待清理 recycle 行 (含未过期), 按 expires_at ASC.
// cursor=0 → 第一页; limit cap 200; 返 (items, nextCursor). nextCursor=0 表示没下一页.
// keyset 分页: cursor 是 id, 按 (expires_at, id) 字典序前向; 实现上简化为 id ASC 后续可加索引.
func (r *RecycleRepo) ListByTenant(ctx context.Context, tenantID int64, limit int, cursor int64) ([]dom.RecycleEntry, int64, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	q := `SELECT ` + recycleColumns + `
        FROM drive_recycle_bin
        WHERE tenant_id = $1 AND is_deleted = false AND id > $2
        ORDER BY id ASC
        LIMIT $3`
	rows, err := r.pool.Query(ctx, q, tenantID, cursor, limit+1)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.RecycleRepo.ListByTenant: %w", err)
	}
	defer rows.Close()
	var out []dom.RecycleEntry
	for rows.Next() {
		var e dom.RecycleEntry
		if err := scanRecycle(rows, &e); err != nil {
			return nil, 0, fmt.Errorf("drive.RecycleRepo.ListByTenant scan: %w", err)
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	var next int64
	if len(out) > limit {
		next = out[limit-1].ID
		out = out[:limit]
	}
	return out, next, nil
}

// CountExpired Phase A2 admin: workers page pending count. 返 expires_at < now 且未 tombstone 行数.
func (r *RecycleRepo) CountExpired(ctx context.Context) (int64, error) {
	var n int64
	if err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM drive_recycle_bin WHERE is_deleted = false AND expires_at < now()`).Scan(&n); err != nil {
		return 0, fmt.Errorf("drive.RecycleRepo.CountExpired: %w", err)
	}
	return n, nil
}

// ListExpired B5 (RecycleCleaner) 用: 列已 expired (expires_at < before) 且未 tombstone 的 recycle 行,
// 按 expires_at ASC, limit cap 500. caller 走 purge 流程 (S3 delete + HardDelete + quota release).
func (r *RecycleRepo) ListExpired(ctx context.Context, before time.Time, limit int) ([]dom.RecycleEntry, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	q := `SELECT ` + recycleColumns + `
        FROM drive_recycle_bin
        WHERE is_deleted = false AND expires_at < $1
        ORDER BY expires_at ASC
        LIMIT $2`
	rows, err := r.pool.Query(ctx, q, before, limit)
	if err != nil {
		return nil, fmt.Errorf("drive.RecycleRepo.ListExpired: %w", err)
	}
	defer rows.Close()
	var out []dom.RecycleEntry
	for rows.Next() {
		var e dom.RecycleEntry
		if err := scanRecycle(rows, &e); err != nil {
			return nil, fmt.Errorf("drive.RecycleRepo.ListExpired scan: %w", err)
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// TombstoneTx F06 Phase 2.2e: restore 路径把 recycle 行标 is_deleted=true (保留行供审计/审计回放),
// 与 purge 的 HardDeleteTx 互斥.
func (r *RecycleRepo) TombstoneTx(ctx context.Context, tx pgx.Tx, id int64, by int64) error {
	const q = `
        UPDATE drive_recycle_bin
           SET is_deleted = true,
               deleted_at = now(),
               updated_at = now(),
               updated_by = $1
         WHERE id = $2 AND is_deleted = false
    `
	tag, err := tx.Exec(ctx, q, by, id)
	if err != nil {
		return fmt.Errorf("drive.RecycleRepo.TombstoneTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// HardDeleteTx F06 Phase 2.2e: purge 路径物理删 recycle 行 (与 file/folder 物理删一起).
func (r *RecycleRepo) HardDeleteTx(ctx context.Context, tx pgx.Tx, id int64) error {
	tag, err := tx.Exec(ctx, `DELETE FROM drive_recycle_bin WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("drive.RecycleRepo.HardDeleteTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
