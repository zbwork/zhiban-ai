// storage.go — F06 §2.10 drive_storage_defaults / drive_storage_overrides CRUD
// pgx + pgxpool 实现, side-by-side 替代 legacy repodrive 存储配置方法.
//
// 2026-05-26 (migration 000120): 删 force_path_style / prefix_tpl / lifecycle_rules 三列。
// 见 domain/drive/storage.go 文档注释。
package drive

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// StorageRepo F06 §2.10 storage 后端配置 CRUD 的 PG 实现.
type StorageRepo struct{ pool *pgxpool.Pool }

// NewStorageRepo 构造.
func NewStorageRepo(pool *pgxpool.Pool) *StorageRepo { return &StorageRepo{pool: pool} }

// ListDefaults 列出所有未软删的平台默认行.
func (r *StorageRepo) ListDefaults(ctx context.Context) ([]dom.StorageDefault, error) {
	const q = `
		SELECT id, uuid, name, kind, region, endpoint, COALESCE(read_endpoint,''), bucket,
		       access_key_secret_ref, secret_key_secret_ref,
		       status, is_default, created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
		  FROM drive_storage_defaults
		 WHERE is_deleted = false
		 ORDER BY is_default DESC, created_at DESC
	`
	rows, err := r.pool.Query(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("drive.StorageRepo.ListDefaults: %w", err)
	}
	defer rows.Close()

	var out []dom.StorageDefault
	for rows.Next() {
		var d dom.StorageDefault
		if err := rows.Scan(&d.ID, &d.UUID, &d.Name, &d.Kind, &d.Region, &d.Endpoint, &d.ReadEndpoint, &d.Bucket,
			&d.AccessKeySecretRef, &d.SecretKeySecretRef,
			&d.Status, &d.IsDefault, &d.CreatedAt, &d.CreatedBy, &d.UpdatedAt, &d.UpdatedBy, &d.IsDeleted, &d.DeletedAt); err != nil {
			return nil, fmt.Errorf("drive.StorageRepo.ListDefaults scan: %w", err)
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// GetDefaultByUUID 按 uuid 取一行 (未软删).
func (r *StorageRepo) GetDefaultByUUID(ctx context.Context, uuid string) (*dom.StorageDefault, error) {
	const q = `
		SELECT id, uuid, name, kind, region, endpoint, COALESCE(read_endpoint,''), bucket,
		       access_key_secret_ref, secret_key_secret_ref,
		       status, is_default, created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
		  FROM drive_storage_defaults
		 WHERE uuid = $1 AND is_deleted = false
	`
	var d dom.StorageDefault
	err := r.pool.QueryRow(ctx, q, uuid).Scan(
		&d.ID, &d.UUID, &d.Name, &d.Kind, &d.Region, &d.Endpoint, &d.ReadEndpoint, &d.Bucket,
		&d.AccessKeySecretRef, &d.SecretKeySecretRef,
		&d.Status, &d.IsDefault, &d.CreatedAt, &d.CreatedBy, &d.UpdatedAt, &d.UpdatedBy, &d.IsDeleted, &d.DeletedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.StorageRepo.GetDefaultByUUID: %w", err)
	}
	return &d, nil
}

// GetDefaultByID 按 id 取一行 (未软删).
func (r *StorageRepo) GetDefaultByID(ctx context.Context, id int64) (*dom.StorageDefault, error) {
	const q = `
		SELECT id, uuid, name, kind, region, endpoint, COALESCE(read_endpoint,''), bucket,
		       access_key_secret_ref, secret_key_secret_ref,
		       status, is_default, created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
		  FROM drive_storage_defaults
		 WHERE id = $1 AND is_deleted = false
	`
	var d dom.StorageDefault
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&d.ID, &d.UUID, &d.Name, &d.Kind, &d.Region, &d.Endpoint, &d.ReadEndpoint, &d.Bucket,
		&d.AccessKeySecretRef, &d.SecretKeySecretRef,
		&d.Status, &d.IsDefault, &d.CreatedAt, &d.CreatedBy, &d.UpdatedAt, &d.UpdatedBy, &d.IsDeleted, &d.DeletedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.StorageRepo.GetDefaultByID: %w", err)
	}
	return &d, nil
}

// GetActiveDefault 返回当前 is_default=true 的行.
func (r *StorageRepo) GetActiveDefault(ctx context.Context) (*dom.StorageDefault, error) {
	const q = `
		SELECT id, uuid, name, kind, region, endpoint, COALESCE(read_endpoint,''), bucket,
		       access_key_secret_ref, secret_key_secret_ref,
		       status, is_default, created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
		  FROM drive_storage_defaults
		 WHERE is_default = true AND is_deleted = false
		 LIMIT 1
	`
	var d dom.StorageDefault
	err := r.pool.QueryRow(ctx, q).Scan(
		&d.ID, &d.UUID, &d.Name, &d.Kind, &d.Region, &d.Endpoint, &d.ReadEndpoint, &d.Bucket,
		&d.AccessKeySecretRef, &d.SecretKeySecretRef,
		&d.Status, &d.IsDefault, &d.CreatedAt, &d.CreatedBy, &d.UpdatedAt, &d.UpdatedBy, &d.IsDeleted, &d.DeletedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.StorageRepo.GetActiveDefault: %w", err)
	}
	return &d, nil
}

// CreateDefault 插入新平台默认行 (is_default 必须显式后置 SetDefault; 返填 uuid, id, created_at, updated_at).
func (r *StorageRepo) CreateDefault(ctx context.Context, d *dom.StorageDefault) error {
	if d.Status == "" {
		d.Status = dom.StorageStatusActive
	}
	err := r.pool.QueryRow(ctx, `
		INSERT INTO drive_storage_defaults
		  (name, kind, region, endpoint, read_endpoint, bucket,
		   access_key_secret_ref, secret_key_secret_ref,
		   status, is_default)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,false)
		RETURNING id, uuid, created_at, updated_at`,
		d.Name, string(d.Kind), d.Region, d.Endpoint, d.ReadEndpoint, d.Bucket,
		d.AccessKeySecretRef, d.SecretKeySecretRef,
		string(d.Status),
	).Scan(&d.ID, &d.UUID, &d.CreatedAt, &d.UpdatedAt)
	if err != nil {
		return fmt.Errorf("drive.StorageRepo.CreateDefault: %w", err)
	}
	return nil
}

// patchAllowedColumns 白名单 — 防止任意 JSON key 拼入 SQL.
var patchAllowedColumns = map[string]bool{
	"name":                  true,
	"region":                true,
	"endpoint":              true,
	"read_endpoint":         true,
	"bucket":                true,
	"access_key_secret_ref": true,
	"secret_key_secret_ref": true,
	"status":                true,
}

// PatchDefault 部分字段更新; 仅接受 patchAllowedColumns 内的字段.
func (r *StorageRepo) PatchDefault(ctx context.Context, uuid string, fields map[string]any) error {
	if len(fields) == 0 {
		return nil
	}
	args := []any{uuid}
	set := ""
	i := 2
	for k, v := range fields {
		if !patchAllowedColumns[k] {
			continue // 静默丢弃未授权列, 防 SQL 注入 + privilege escalation
		}
		if set != "" {
			set += ", "
		}
		set += fmt.Sprintf("%s = $%d", k, i)
		args = append(args, v)
		i++
	}
	if set == "" {
		return nil
	}
	set += ", updated_at = now()"
	tag, err := r.pool.Exec(ctx, `UPDATE drive_storage_defaults SET `+set+` WHERE uuid = $1 AND is_deleted = false`, args...)
	if err != nil {
		return fmt.Errorf("drive.StorageRepo.PatchDefault: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// SoftDeleteDefault 软删 + 解除 is_default.
func (r *StorageRepo) SoftDeleteDefault(ctx context.Context, uuid string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE drive_storage_defaults
		   SET is_deleted = true, deleted_at = now(), is_default = false, updated_at = now()
		 WHERE uuid = $1 AND is_deleted = false`, uuid)
	if err != nil {
		return fmt.Errorf("drive.StorageRepo.SoftDeleteDefault: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// SetDefault 把指定 uuid 行设为唯一默认 (事务内清零再置一).
func (r *StorageRepo) SetDefault(ctx context.Context, uuid string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("drive.StorageRepo.SetDefault begin: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `UPDATE drive_storage_defaults SET is_default = false WHERE is_default = true`); err != nil {
		return fmt.Errorf("drive.StorageRepo.SetDefault clear: %w", err)
	}
	tag, err := tx.Exec(ctx, `
		UPDATE drive_storage_defaults
		   SET is_default = true, updated_at = now()
		 WHERE uuid = $1 AND is_deleted = false AND status = 'active'`, uuid)
	if err != nil {
		return fmt.Errorf("drive.StorageRepo.SetDefault set: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("drive.StorageRepo.SetDefault commit: %w", err)
	}
	return nil
}

// GetTenantOverride 取租户覆盖 (无则返 nil, nil).
func (r *StorageRepo) GetTenantOverride(ctx context.Context, tenantID int64) (*dom.StorageOverride, error) {
	const q = `
		SELECT id, uuid, tenant_id, default_id, region, endpoint, read_endpoint, bucket,
		       access_key_secret_ref, secret_key_secret_ref,
		       status, created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
		  FROM drive_storage_overrides
		 WHERE tenant_id = $1 AND is_deleted = false
	`
	var o dom.StorageOverride
	err := r.pool.QueryRow(ctx, q, tenantID).Scan(
		&o.ID, &o.UUID, &o.TenantID, &o.DefaultID, &o.Region, &o.Endpoint, &o.ReadEndpoint, &o.Bucket,
		&o.AccessKeySecretRef, &o.SecretKeySecretRef,
		&o.Status, &o.CreatedAt, &o.CreatedBy, &o.UpdatedAt, &o.UpdatedBy, &o.IsDeleted, &o.DeletedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("drive.StorageRepo.GetTenantOverride: %w", err)
	}
	return &o, nil
}

// UpsertTenantOverride 全字段覆盖式 upsert; partial unique index 上需重复 WHERE 条件.
func (r *StorageRepo) UpsertTenantOverride(ctx context.Context, o *dom.StorageOverride) error {
	if o.Status == "" {
		o.Status = dom.StorageStatusActive
	}
	_, err := r.pool.Exec(ctx, `
		INSERT INTO drive_storage_overrides
		  (tenant_id, default_id, region, endpoint, read_endpoint, bucket,
		   access_key_secret_ref, secret_key_secret_ref,
		   status)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		ON CONFLICT (tenant_id) WHERE is_deleted = false DO UPDATE SET
		  default_id            = EXCLUDED.default_id,
		  region                = EXCLUDED.region,
		  endpoint              = EXCLUDED.endpoint,
		  read_endpoint         = EXCLUDED.read_endpoint,
		  bucket                = EXCLUDED.bucket,
		  access_key_secret_ref = EXCLUDED.access_key_secret_ref,
		  secret_key_secret_ref = EXCLUDED.secret_key_secret_ref,
		  status                = EXCLUDED.status,
		  updated_at            = now()`,
		o.TenantID, o.DefaultID, o.Region, o.Endpoint, o.ReadEndpoint, o.Bucket,
		o.AccessKeySecretRef, o.SecretKeySecretRef,
		string(o.Status))
	if err != nil {
		return fmt.Errorf("drive.StorageRepo.UpsertTenantOverride: %w", err)
	}
	return nil
}

// SoftDeleteTenantOverride 软删租户覆盖行.
func (r *StorageRepo) SoftDeleteTenantOverride(ctx context.Context, tenantID int64) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE drive_storage_overrides
		   SET deleted_at = now(), updated_at = now(), is_deleted = true
		 WHERE tenant_id = $1 AND is_deleted = false`, tenantID)
	if err != nil {
		return fmt.Errorf("drive.StorageRepo.SoftDeleteTenantOverride: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
