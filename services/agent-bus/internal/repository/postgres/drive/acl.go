package drive

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// ACLRepo F06 §2.5 drive_acl_entries 的 PG 实现.
type ACLRepo struct{ pool *pgxpool.Pool }

// NewACLRepo 构造.
func NewACLRepo(pool *pgxpool.Pool) *ACLRepo { return &ACLRepo{pool: pool} }

// GetByID 按 id 查 1 行; 软删 (is_deleted=true) 行不返回.
func (r *ACLRepo) GetByID(ctx context.Context, id int64) (*dom.ACLEntry, error) {
	const q = `
        SELECT id, uuid, tenant_id, target_kind, target_id, subject_kind, subject_id, link_token_id, role, granted_by,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_acl_entries
        WHERE id = $1 AND is_deleted = false
    `
	var a dom.ACLEntry
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&a.ID, &a.UUID, &a.TenantID, &a.TargetKind, &a.TargetID, &a.SubjectKind, &a.SubjectID, &a.LinkTokenID, &a.Role, &a.GrantedBy,
		&a.CreatedAt, &a.CreatedBy, &a.UpdatedAt, &a.UpdatedBy, &a.IsDeleted, &a.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.ACLRepo.GetByID: %w", err)
	}
	return &a, nil
}

// ListAccountSubjectsByTarget B3: 列某 target (space/folder/file) 上所有 subject_kind='account' 的非软删 grant.
// 不含 link_token / department grants (B3 只管 account members).
// 按 created_at ASC 返 (旧成员靠前; 简单可预测排序).
func (r *ACLRepo) ListAccountSubjectsByTarget(ctx context.Context, kind dom.ACLTargetKind, targetID int64) ([]dom.ACLEntry, error) {
	const q = `
        SELECT id, uuid, tenant_id, target_kind, target_id, subject_kind, subject_id, link_token_id, role, granted_by,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_acl_entries
        WHERE target_kind = $1 AND target_id = $2
          AND subject_kind = 'account'
          AND is_deleted = false
        ORDER BY created_at ASC, id ASC
    `
	rows, err := r.pool.Query(ctx, q, string(kind), targetID)
	if err != nil {
		return nil, fmt.Errorf("drive.ACLRepo.ListAccountSubjectsByTarget: %w", err)
	}
	defer rows.Close()
	var out []dom.ACLEntry
	for rows.Next() {
		var a dom.ACLEntry
		if err := rows.Scan(
			&a.ID, &a.UUID, &a.TenantID, &a.TargetKind, &a.TargetID, &a.SubjectKind, &a.SubjectID, &a.LinkTokenID, &a.Role, &a.GrantedBy,
			&a.CreatedAt, &a.CreatedBy, &a.UpdatedAt, &a.UpdatedBy, &a.IsDeleted, &a.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.ACLRepo.ListAccountSubjectsByTarget scan: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// GetAccountGrant B3: 取某 target × account 的当前 (非软删) grant; 不存在 → ErrNotFound.
func (r *ACLRepo) GetAccountGrant(ctx context.Context, kind dom.ACLTargetKind, targetID, accountID int64) (*dom.ACLEntry, error) {
	const q = `
        SELECT id, uuid, tenant_id, target_kind, target_id, subject_kind, subject_id, link_token_id, role, granted_by,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_acl_entries
        WHERE target_kind = $1 AND target_id = $2
          AND subject_kind = 'account' AND subject_id = $3
          AND is_deleted = false
        LIMIT 1
    `
	var a dom.ACLEntry
	err := r.pool.QueryRow(ctx, q, string(kind), targetID, accountID).Scan(
		&a.ID, &a.UUID, &a.TenantID, &a.TargetKind, &a.TargetID, &a.SubjectKind, &a.SubjectID, &a.LinkTokenID, &a.Role, &a.GrantedBy,
		&a.CreatedAt, &a.CreatedBy, &a.UpdatedAt, &a.UpdatedBy, &a.IsDeleted, &a.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.ACLRepo.GetAccountGrant: %w", err)
	}
	return &a, nil
}

// InsertAccountGrantInput B3 Add/Update 入参.
type InsertAccountGrantInput struct {
	TenantID  int64
	Kind      dom.ACLTargetKind
	TargetID  int64
	AccountID int64
	Role      dom.ACLRole
	GrantedBy int64
}

// InsertAccountGrant B3: 插入一条 subject_kind=account 的 grant.
// 23505 (与现有非软删 grant 冲突) → ErrDuplicate.
func (r *ACLRepo) InsertAccountGrant(ctx context.Context, in InsertAccountGrantInput) (*dom.ACLEntry, error) {
	const q = `
        INSERT INTO drive_acl_entries (
            tenant_id, target_kind, target_id, subject_kind, subject_id, role, granted_by,
            created_by, updated_by
        ) VALUES ($1, $2, $3, 'account', $4, $5, $6, $6, $6)
        RETURNING id, uuid, tenant_id, target_kind, target_id, subject_kind, subject_id, link_token_id, role, granted_by,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var a dom.ACLEntry
	err := r.pool.QueryRow(ctx, q,
		in.TenantID, string(in.Kind), in.TargetID, in.AccountID, string(in.Role), in.GrantedBy,
	).Scan(
		&a.ID, &a.UUID, &a.TenantID, &a.TargetKind, &a.TargetID, &a.SubjectKind, &a.SubjectID, &a.LinkTokenID, &a.Role, &a.GrantedBy,
		&a.CreatedAt, &a.CreatedBy, &a.UpdatedAt, &a.UpdatedBy, &a.IsDeleted, &a.DeletedAt,
	)
	if err != nil {
		// 23505 (uq_acl_grant 冲突) 由 caller 走 update 路径.
		return nil, fmt.Errorf("drive.ACLRepo.InsertAccountGrant: %w", err)
	}
	return &a, nil
}

// UpdateRoleByID B3: 改 role; row 已 GetByID 拿到 (caller 保证仍 non-deleted).
func (r *ACLRepo) UpdateRoleByID(ctx context.Context, id int64, role dom.ACLRole, updatedBy int64) error {
	const q = `
        UPDATE drive_acl_entries
           SET role = $1, updated_at = now(), updated_by = $2
         WHERE id = $3 AND is_deleted = false
    `
	tag, err := r.pool.Exec(ctx, q, string(role), updatedBy, id)
	if err != nil {
		return fmt.Errorf("drive.ACLRepo.UpdateRoleByID: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListGrantedFolderIDsByAccount B4 (granular ACL): 列 caller 在 tenant 内被 grant 的 folder ids.
// subject_kind='account', subject_id=accountID; target_kind='folder'; 非软删.
// 用途: Recent/Search 时把这些 folder 的文件也并入可见集.
func (r *ACLRepo) ListGrantedFolderIDsByAccount(ctx context.Context, tenantID, accountID int64) ([]int64, error) {
	const q = `
        SELECT DISTINCT target_id
          FROM drive_acl_entries
         WHERE tenant_id = $1
           AND target_kind = 'folder'
           AND subject_kind = 'account' AND subject_id = $2
           AND is_deleted = false
    `
	rows, err := r.pool.Query(ctx, q, tenantID, accountID)
	if err != nil {
		return nil, fmt.Errorf("drive.ACLRepo.ListGrantedFolderIDsByAccount: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("drive.ACLRepo.ListGrantedFolderIDsByAccount scan: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// ListGrantedFileIDsByAccount B4 (granular ACL): 列 caller 在 tenant 内被 grant 的 file ids.
// subject_kind='account', subject_id=accountID; target_kind='file'; 非软删.
func (r *ACLRepo) ListGrantedFileIDsByAccount(ctx context.Context, tenantID, accountID int64) ([]int64, error) {
	const q = `
        SELECT DISTINCT target_id
          FROM drive_acl_entries
         WHERE tenant_id = $1
           AND target_kind = 'file'
           AND subject_kind = 'account' AND subject_id = $2
           AND is_deleted = false
    `
	rows, err := r.pool.Query(ctx, q, tenantID, accountID)
	if err != nil {
		return nil, fmt.Errorf("drive.ACLRepo.ListGrantedFileIDsByAccount: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("drive.ACLRepo.ListGrantedFileIDsByAccount scan: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// SoftDeleteByID B3: 软删 grant (member 移除).
func (r *ACLRepo) SoftDeleteByID(ctx context.Context, id, updatedBy int64) error {
	const q = `
        UPDATE drive_acl_entries
           SET is_deleted = true,
               deleted_at = now(),
               updated_at = now(),
               updated_by = $1
         WHERE id = $2 AND is_deleted = false
    `
	tag, err := r.pool.Exec(ctx, q, updatedBy, id)
	if err != nil {
		return fmt.Errorf("drive.ACLRepo.SoftDeleteByID: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
