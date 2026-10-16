package drive

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// TicketRepo F06 §3.2 drive_upload_tickets 的 PG 实现.
type TicketRepo struct{ pool *pgxpool.Pool }

// NewTicketRepo 构造.
func NewTicketRepo(pool *pgxpool.Pool) *TicketRepo { return &TicketRepo{pool: pool} }

// GetByFileUUID 按 file_uuid 查 1 行 (注意: 无 is_deleted 列, 不过滤软删).
func (r *TicketRepo) GetByFileUUID(ctx context.Context, fileUUID string) (*dom.UploadTicket, error) {
	const q = `
        SELECT id, file_uuid, account_id, tenant_id, space_id, folder_id, declared_size, declared_mime, declared_name,
               staging_key, final_key, upload_id, part_size, source, status, created_at, expires_at
        FROM drive_upload_tickets
        WHERE file_uuid = $1
    `
	var t dom.UploadTicket
	err := r.pool.QueryRow(ctx, q, fileUUID).Scan(
		&t.ID, &t.FileUUID, &t.AccountID, &t.TenantID, &t.SpaceID, &t.FolderID, &t.DeclaredSize, &t.DeclaredMime, &t.DeclaredName,
		&t.StagingKey, &t.FinalKey, &t.UploadID, &t.PartSize, &t.Source, &t.Status, &t.CreatedAt, &t.ExpiresAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.TicketRepo.GetByFileUUID: %w", err)
	}
	return &t, nil
}

// Create F06 Phase 2.2c presign-put 入库; status 固定 'pending'.
// file_uuid 是 caller (service) 用 github.com/google/uuid 新生成的, 几乎不会撞 unique;
// 真撞了 (23505) 视为内部错 (不暴露到客户端) — 单测覆盖该路径不必.
func (r *TicketRepo) Create(ctx context.Context, in dom.CreateUploadTicketInput) error {
	src := string(in.Source)
	if src == "" {
		src = "user_upload" // Phase 2.5 默认; 现有 client upload 路径不传, 走 user_upload.
	}
	const q = `
        INSERT INTO drive_upload_tickets (
            file_uuid, account_id, tenant_id, space_id, folder_id,
            declared_size, declared_mime, declared_name,
            staging_key, final_key, upload_id, part_size, source, status, expires_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'pending', $14)
    `
	_, err := r.pool.Exec(ctx, q,
		in.FileUUID, in.AccountID, in.TenantID, in.SpaceID, in.FolderID,
		in.DeclaredSize, in.DeclaredMime, in.DeclaredName,
		in.StagingKey, in.FinalKey, in.UploadID, in.PartSize, src, in.ExpiresAt,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return fmt.Errorf("drive.TicketRepo.Create: duplicate file_uuid (unexpected): %w", err)
		}
		return fmt.Errorf("drive.TicketRepo.Create: %w", err)
	}
	return nil
}

// UpdateStatus F06 Phase 2.2c 改 ticket.status (pending → done|partial|failed).
// 非 TX 路径; 用于 confirm 早期 (Stat / quota precheck) 失败的兜底标记.
func (r *TicketRepo) UpdateStatus(ctx context.Context, fileUUID, newStatus string) error {
	const q = `UPDATE drive_upload_tickets SET status = $1 WHERE file_uuid = $2`
	tag, err := r.pool.Exec(ctx, q, newStatus, fileUUID)
	if err != nil {
		return fmt.Errorf("drive.TicketRepo.UpdateStatus: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// UpdateStatusTx F06 Phase 2.2c TX 变体; 用于 confirm 流程 Phase 3 与 INSERT/quota update 同事务标 done.
func (r *TicketRepo) UpdateStatusTx(ctx context.Context, tx pgx.Tx, fileUUID, newStatus string) error {
	const q = `UPDATE drive_upload_tickets SET status = $1 WHERE file_uuid = $2`
	tag, err := tx.Exec(ctx, q, newStatus, fileUUID)
	if err != nil {
		return fmt.Errorf("drive.TicketRepo.UpdateStatusTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListExpiredPending B5 (StagingReaper) 用: 列出 status='pending' 且 expires_at 早于
// (now - gracePeriod) 的 ticket, 按 expires_at ASC, limit cap 500.
// 用于 worker 扫死单 staging upload — caller 拿到后逐个 store.Delete/AbortMultipart staging
// 并把 ticket 标 failed.
//
// gracePeriod 由 caller 控制 (例如 1h grace), 防止把客户端正在持 URL 上传的 ticket 误清理.
func (r *TicketRepo) ListExpiredPending(ctx context.Context, before time.Time, limit int) ([]dom.UploadTicket, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	const q = `
        SELECT id, file_uuid, account_id, tenant_id, space_id, folder_id, declared_size, declared_mime, declared_name,
               staging_key, final_key, upload_id, part_size, source, status, created_at, expires_at
          FROM drive_upload_tickets
         WHERE status = 'pending' AND expires_at < $1
         ORDER BY expires_at ASC
         LIMIT $2
    `
	rows, err := r.pool.Query(ctx, q, before, limit)
	if err != nil {
		return nil, fmt.Errorf("drive.TicketRepo.ListExpiredPending: %w", err)
	}
	defer rows.Close()
	var out []dom.UploadTicket
	for rows.Next() {
		var t dom.UploadTicket
		if err := rows.Scan(
			&t.ID, &t.FileUUID, &t.AccountID, &t.TenantID, &t.SpaceID, &t.FolderID, &t.DeclaredSize, &t.DeclaredMime, &t.DeclaredName,
			&t.StagingKey, &t.FinalKey, &t.UploadID, &t.PartSize, &t.Source, &t.Status, &t.CreatedAt, &t.ExpiresAt,
		); err != nil {
			return nil, fmt.Errorf("drive.TicketRepo.ListExpiredPending scan: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// CountExpiredPending Phase A2 admin workers page: 返 status='pending' 且 expires_at < (now-grace) 行数.
// grace 参数同 WorkerSvc.stagingGrace; caller 传相同值保证一致.
func (r *TicketRepo) CountExpiredPending(ctx context.Context, before time.Time) (int64, error) {
	var n int64
	if err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM drive_upload_tickets WHERE status = 'pending' AND expires_at < $1`, before).Scan(&n); err != nil {
		return 0, fmt.Errorf("drive.TicketRepo.CountExpiredPending: %w", err)
	}
	return n, nil
}

// LockForConfirmTx F06 Phase 2.2c 并发防御: 在 Phase 3 TX 内 SELECT ... FOR UPDATE,
// 同时 re-assert status='pending' + expires_at > now() + account/tenant 归属.
// 返 ErrNotFound 即视为 ticket invalid / 已 done / 已 failed / 已过期 / 跨户偷用 — caller 翻成 403.
// 与 Confirm 入口的 pool-read 形成双重防御: 入口 read 用于做 Stat/Copy (Phase 1/2),
// 本方法在 Phase 3 mutation 之前重新拿行锁, 串行化双 Confirm 调用避免双扣 quota + 双行 INSERT.
func (r *TicketRepo) LockForConfirmTx(ctx context.Context, tx pgx.Tx, fileUUID string, accountID, tenantID int64) (*dom.UploadTicket, error) {
	const q = `
        SELECT id, file_uuid, account_id, tenant_id, space_id, folder_id, declared_size, declared_mime, declared_name,
               staging_key, final_key, upload_id, part_size, source, status, created_at, expires_at
          FROM drive_upload_tickets
         WHERE file_uuid = $1
           AND account_id = $2
           AND tenant_id = $3
           AND status = 'pending'
           AND expires_at > now()
         FOR UPDATE
    `
	var t dom.UploadTicket
	err := tx.QueryRow(ctx, q, fileUUID, accountID, tenantID).Scan(
		&t.ID, &t.FileUUID, &t.AccountID, &t.TenantID, &t.SpaceID, &t.FolderID, &t.DeclaredSize, &t.DeclaredMime, &t.DeclaredName,
		&t.StagingKey, &t.FinalKey, &t.UploadID, &t.PartSize, &t.Source, &t.Status, &t.CreatedAt, &t.ExpiresAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.TicketRepo.LockForConfirmTx: %w", err)
	}
	return &t, nil
}
