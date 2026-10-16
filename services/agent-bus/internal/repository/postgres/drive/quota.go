package drive

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// QuotaRepo F06 §2.9 drive_quotas 的 PG 实现.
type QuotaRepo struct{ pool *pgxpool.Pool }

// NewQuotaRepo 构造.
func NewQuotaRepo(pool *pgxpool.Pool) *QuotaRepo { return &QuotaRepo{pool: pool} }

// GetByID 按 id 查 1 行; 软删 (is_deleted=true) 行不返回.
func (r *QuotaRepo) GetByID(ctx context.Context, id int64) (*dom.Quota, error) {
	const q = `
        SELECT id, uuid, tenant_id, subject_kind, subject_id, quota_bytes, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_quotas
        WHERE id = $1 AND is_deleted = false
    `
	var q2 dom.Quota
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&q2.ID, &q2.UUID, &q2.TenantID, &q2.SubjectKind, &q2.SubjectID, &q2.QuotaBytes, &q2.UsedBytes,
		&q2.CreatedAt, &q2.CreatedBy, &q2.UpdatedAt, &q2.UpdatedBy, &q2.IsDeleted, &q2.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.QuotaRepo.GetByID: %w", err)
	}
	return &q2, nil
}

// GetForTenant F06 Phase 2.2c 取租户级配额行 (subject_kind='tenant').
// 不存在 → ErrNotFound; service 层翻译为 "无配额限制".
func (r *QuotaRepo) GetForTenant(ctx context.Context, tenantID int64) (*dom.Quota, error) {
	const q = `
        SELECT id, uuid, tenant_id, subject_kind, subject_id, quota_bytes, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_quotas
        WHERE tenant_id = $1 AND subject_kind = 'tenant' AND is_deleted = false
        LIMIT 1
    `
	var q2 dom.Quota
	err := r.pool.QueryRow(ctx, q, tenantID).Scan(
		&q2.ID, &q2.UUID, &q2.TenantID, &q2.SubjectKind, &q2.SubjectID, &q2.QuotaBytes, &q2.UsedBytes,
		&q2.CreatedAt, &q2.CreatedBy, &q2.UpdatedAt, &q2.UpdatedBy, &q2.IsDeleted, &q2.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.QuotaRepo.GetForTenant: %w", err)
	}
	return &q2, nil
}

// GetForAccount F06 Phase 2.2c 取账号级配额行 (subject_kind='account' AND subject_id=accountID).
// 不存在 → ErrNotFound; service 层翻译为 "无配额限制".
func (r *QuotaRepo) GetForAccount(ctx context.Context, tenantID, accountID int64) (*dom.Quota, error) {
	const q = `
        SELECT id, uuid, tenant_id, subject_kind, subject_id, quota_bytes, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_quotas
        WHERE tenant_id = $1 AND subject_kind = 'account' AND subject_id = $2 AND is_deleted = false
        LIMIT 1
    `
	var q2 dom.Quota
	err := r.pool.QueryRow(ctx, q, tenantID, accountID).Scan(
		&q2.ID, &q2.UUID, &q2.TenantID, &q2.SubjectKind, &q2.SubjectID, &q2.QuotaBytes, &q2.UsedBytes,
		&q2.CreatedAt, &q2.CreatedBy, &q2.UpdatedAt, &q2.UpdatedBy, &q2.IsDeleted, &q2.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.QuotaRepo.GetForAccount: %w", err)
	}
	return &q2, nil
}

// AddUsedBytesSignedTx F06 Phase 2.2e purge 流程 TX 内 -delta 释放配额 (无条件; 不查 quota_bytes).
// 支持负 delta; 用 GREATEST(0, ...) 钉地板, 防御 used_bytes 历史漂移导致下溢.
// quotaID = 0 → no-op (caller 没拿到对应 quota 行, 视为无配额限制).
func (r *QuotaRepo) AddUsedBytesSignedTx(ctx context.Context, tx pgx.Tx, quotaID, delta int64) error {
	if quotaID == 0 || delta == 0 {
		return nil
	}
	_, err := tx.Exec(ctx,
		`UPDATE drive_quotas SET used_bytes = GREATEST(0, used_bytes + $1), updated_at = now() WHERE id = $2 AND is_deleted = false`,
		delta, quotaID,
	)
	if err != nil {
		return fmt.Errorf("drive.QuotaRepo.AddUsedBytesSignedTx: %w", err)
	}
	return nil
}

// ListAccountQuotasByTenant Phase A2 admin: 列本租户所有 subject_kind='account' quota 行 (非软删).
// 用于 GET /api/admin/v1/tenant/drive/quotas 返回 items 列表.
// 按 subject_id ASC; 没有则返 nil.
func (r *QuotaRepo) ListAccountQuotasByTenant(ctx context.Context, tenantID int64) ([]dom.Quota, error) {
	const q = `
        SELECT id, uuid, tenant_id, subject_kind, subject_id, quota_bytes, used_bytes,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
          FROM drive_quotas
         WHERE tenant_id = $1 AND subject_kind = 'account' AND is_deleted = false
         ORDER BY subject_id ASC
    `
	rows, err := r.pool.Query(ctx, q, tenantID)
	if err != nil {
		return nil, fmt.Errorf("drive.QuotaRepo.ListAccountQuotasByTenant: %w", err)
	}
	defer rows.Close()
	var out []dom.Quota
	for rows.Next() {
		var q2 dom.Quota
		if err := rows.Scan(
			&q2.ID, &q2.UUID, &q2.TenantID, &q2.SubjectKind, &q2.SubjectID, &q2.QuotaBytes, &q2.UsedBytes,
			&q2.CreatedAt, &q2.CreatedBy, &q2.UpdatedAt, &q2.UpdatedBy, &q2.IsDeleted, &q2.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.QuotaRepo.ListAccountQuotasByTenant scan: %w", err)
		}
		out = append(out, q2)
	}
	return out, rows.Err()
}

// UpsertTenantQuota F06 v0.3.1 §3.3: 平台 admin 设置/调整租户总额度 (drive_quotas subject_kind='tenant' 行).
// quotaBytes = -1 表示无限. updatedBy = platform admin caller account id.
// 与 UpsertAccountQuota 同模式: try-update-then-insert; uq_quota_tenant partial unique 保证最多一行.
//
// caller 应该先调 GetForTenant 拿到 used_bytes, 再判断 used 是否超 quota; service 层做这个 guard
// (本 repo 不做业务校验, 只保证 DB 一致性).
func (r *QuotaRepo) UpsertTenantQuota(ctx context.Context, tenantID, quotaBytes, updatedBy int64) error {
	const upd = `
        UPDATE drive_quotas
           SET quota_bytes = $1, updated_at = now(), updated_by = $2, quota_source = 'manual'
         WHERE tenant_id = $3 AND subject_kind = 'tenant' AND is_deleted = false
    `
	tag, err := r.pool.Exec(ctx, upd, quotaBytes, updatedBy, tenantID)
	if err != nil {
		return fmt.Errorf("drive.QuotaRepo.UpsertTenantQuota update: %w", err)
	}
	if tag.RowsAffected() > 0 {
		return nil
	}
	const ins = `
        INSERT INTO drive_quotas (tenant_id, subject_kind, subject_id, quota_bytes, used_bytes, created_by, updated_by, quota_source)
        VALUES ($1, 'tenant', NULL, $2, 0, $3, $3, 'manual')
    `
	if _, err := r.pool.Exec(ctx, ins, tenantID, quotaBytes, updatedBy); err != nil {
		return fmt.Errorf("drive.QuotaRepo.UpsertTenantQuota insert: %w", err)
	}
	return nil
}

// SumTenantUsedBytes F06 v0.3.1 §3.3: 实时从 drive_spaces 聚合本租户已用字节 (drive_quotas.used_bytes
// 可能历史漂移; quota 入口校验时取实时值更稳).
// 仅 scope='drive' 的 file (chat scope 不计 quota). 走 drive_spaces.used_bytes 列汇总, 与 confirm
// 路径 AddUsedBytesTx 维护的 column 一致.
func (r *QuotaRepo) SumTenantUsedBytes(ctx context.Context, tenantID int64) (int64, error) {
	const q = `
        SELECT COALESCE(SUM(used_bytes), 0)
          FROM drive_spaces
         WHERE tenant_id = $1 AND is_deleted = false
    `
	var n int64
	if err := r.pool.QueryRow(ctx, q, tenantID).Scan(&n); err != nil {
		return 0, fmt.Errorf("drive.QuotaRepo.SumTenantUsedBytes: %w", err)
	}
	return n, nil
}

// UpsertAccountQuota Phase A2 admin: 插入或更新单 account quota (per-account 调整入口).
// 走 INSERT ... ON CONFLICT (tenant_id, subject_id) WHERE subject_kind='account' AND is_deleted=false
// DO UPDATE SET quota_bytes=$3 — caller 已 ACL 检查, 这里只关心一致性.
// updatedBy 写入 8 字段审计.
func (r *QuotaRepo) UpsertAccountQuota(ctx context.Context, tenantID, accountID, quotaBytes, updatedBy int64) error {
	// 因为 unique index 是 partial (WHERE subject_kind='account' AND is_deleted=false),
	// PG 不能用作 ON CONFLICT target. 改走 try-update-then-insert 模式 (无 race 风险, caller 串行).
	const upd = `
        UPDATE drive_quotas
           SET quota_bytes = $1, updated_at = now(), updated_by = $2
         WHERE tenant_id = $3 AND subject_kind = 'account' AND subject_id = $4 AND is_deleted = false
    `
	tag, err := r.pool.Exec(ctx, upd, quotaBytes, updatedBy, tenantID, accountID)
	if err != nil {
		return fmt.Errorf("drive.QuotaRepo.UpsertAccountQuota update: %w", err)
	}
	if tag.RowsAffected() > 0 {
		return nil
	}
	const ins = `
        INSERT INTO drive_quotas (tenant_id, subject_kind, subject_id, quota_bytes, used_bytes, created_by, updated_by)
        VALUES ($1, 'account', $2, $3, 0, $4, $4)
    `
	if _, err := r.pool.Exec(ctx, ins, tenantID, accountID, quotaBytes, updatedBy); err != nil {
		return fmt.Errorf("drive.QuotaRepo.UpsertAccountQuota insert: %w", err)
	}
	return nil
}

// SumAccountUsedBytesByTenant Phase A2 admin GET summary 用: 按 created_by 聚合 sizes.
// 返每 account 的 used_bytes (scope='drive' 非软删 files); 不含 chat scope.
// 用途: 当 drive_quotas 里 account 行不存在时, 也能展示该用户的当前用量 (从文件聚合).
func (r *QuotaRepo) SumAccountUsedBytesByTenant(ctx context.Context, tenantID int64) (map[int64]int64, error) {
	const q = `
        SELECT f.created_by, COALESCE(SUM(f.size_bytes), 0)
          FROM drive_files f
          JOIN drive_spaces s ON s.id = f.space_id
         WHERE s.tenant_id = $1
           AND f.scope = 'drive'
           AND f.is_deleted = false
           AND f.created_by IS NOT NULL
         GROUP BY f.created_by
    `
	rows, err := r.pool.Query(ctx, q, tenantID)
	if err != nil {
		return nil, fmt.Errorf("drive.QuotaRepo.SumAccountUsedBytesByTenant: %w", err)
	}
	defer rows.Close()
	out := make(map[int64]int64)
	for rows.Next() {
		var aid, used int64
		if err := rows.Scan(&aid, &used); err != nil {
			return nil, fmt.Errorf("drive.QuotaRepo.SumAccountUsedBytesByTenant scan: %w", err)
		}
		out[aid] = used
	}
	return out, rows.Err()
}

// AddUsedBytesAtomicTx F06 Phase 2.2c 原子条件 UPDATE: 仅当 used_bytes + delta <= quota_bytes
// (或 quota_bytes = -1 无限) 才生效. 返 (true, nil) = 配额成功扣加, (false, nil) = 超限不变.
//
// 与 legacy svcdrive AddUsedBytesTx 同模式: 单 UPDATE 语句把 "check + update" 合并为一步,
// 避免 SELECT FOR UPDATE → 二次 UPDATE 之间被其他 TX 抢配额.
//
// quotaID = 0 视为 caller 没拿到 quota 行 (无配额限制) → 直接返 (true, nil).
func (r *QuotaRepo) AddUsedBytesAtomicTx(ctx context.Context, tx pgx.Tx, quotaID int64, delta int64) (bool, error) {
	if quotaID == 0 {
		return true, nil
	}
	if delta <= 0 {
		return false, fmt.Errorf("drive.QuotaRepo.AddUsedBytesAtomicTx: delta must be > 0; got %d", delta)
	}
	const q = `
        UPDATE drive_quotas
           SET used_bytes = used_bytes + $1, updated_at = now()
         WHERE id = $2
           AND is_deleted = false
           AND (quota_bytes = -1 OR used_bytes + $1 <= quota_bytes)
    `
	tag, err := tx.Exec(ctx, q, delta, quotaID)
	if err != nil {
		return false, fmt.Errorf("drive.QuotaRepo.AddUsedBytesAtomicTx: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}
