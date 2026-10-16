package drive

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// FileRepo F06 §2.4 drive_files 的 PG 实现.
type FileRepo struct{ pool *pgxpool.Pool }

// NewFileRepo 构造.
func NewFileRepo(pool *pgxpool.Pool) *FileRepo { return &FileRepo{pool: pool} }

// GetByID 按 id 查 1 行; 软删 (is_deleted=true) 行不返回.
func (r *FileRepo) GetByID(ctx context.Context, id int64) (*dom.File, error) {
	const q = `
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE id = $1 AND is_deleted = false
    `
	var f dom.File
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.GetByID: %w", err)
	}
	return &f, nil
}

// GetByIDIncludingDeleted 按 id 查 1 行,不排除软删行。
// 回收站列表需要展示已删除文件的原始 uuid/mime/size 等只读元数据。
func (r *FileRepo) GetByIDIncludingDeleted(ctx context.Context, id int64) (*dom.File, error) {
	const q = `
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE id = $1
    `
	var f dom.File
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.GetByIDIncludingDeleted: %w", err)
	}
	return &f, nil
}

// ListByFolder 列 folder 下未软删 + scope='drive' 的文件 (分页).
// 用于 folder children 接口的"文件"部分.
func (r *FileRepo) ListByFolder(ctx context.Context, folderID int64, page, pageSize int) ([]dom.File, int, error) {
	if page < 1 {
		page = 1
	}
	if pageSize <= 0 {
		pageSize = 50
	}
	if pageSize > 200 {
		pageSize = 200
	}
	offset := (page - 1) * pageSize

	// 先查 total count
	var total int
	err := r.pool.QueryRow(ctx, `
        SELECT COUNT(*)
        FROM drive_files
        WHERE drive_folder_id = $1 AND scope = 'drive' AND is_deleted = false
    `, folderID).Scan(&total)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.FileRepo.ListByFolder count: %w", err)
	}

	// 再查分页数据
	const q = `
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE drive_folder_id = $1 AND scope = 'drive' AND is_deleted = false
        ORDER BY created_at DESC
        LIMIT $2 OFFSET $3
    `
	rows, err := r.pool.Query(ctx, q, folderID, pageSize, offset)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.FileRepo.ListByFolder: %w", err)
	}
	defer rows.Close()

	var out []dom.File
	for rows.Next() {
		var f dom.File
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
			&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
			&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
			&f.CopyStartedAt, &f.CopyFinishedAt,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, 0, fmt.Errorf("drive.FileRepo.ListByFolder scan: %w", err)
		}
		out = append(out, f)
	}
	return out, total, rows.Err()
}

// CreateTx F06 Phase 2.2c confirm 流程 (TX 内 INSERT, 跟 quota / space.used_bytes 一起原子).
// uq_dfile_folder_name 唯一索引 (drive_folder_id, name) WHERE is_deleted=false → 23505 → ErrDuplicateName.
// caller (service) 负责把 ErrDuplicateName 翻成 409 drive.duplicate_name 并清理 staging + final.
func (r *FileRepo) CreateTx(ctx context.Context, tx pgx.Tx, in dom.CreateFileInput) (*dom.File, error) {
	const q = `
        INSERT INTO drive_files (
            space_id, scope, source, drive_folder_id,
            storage_key, name, mime_type, size_bytes, sha256,
            created_by, updated_by
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10)
        RETURNING id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                  origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                  thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                  copy_started_at, copy_finished_at,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.File
	err := tx.QueryRow(ctx, q,
		in.SpaceID, string(in.Scope), string(in.Source), in.DriveFolderID,
		in.StorageKey, in.Name, in.MimeType, in.SizeBytes, in.SHA256,
		in.CreatedBy,
	).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrDuplicateName
		}
		return nil, fmt.Errorf("drive.FileRepo.CreateTx: %w", err)
	}
	return &f, nil
}

// GetByUUID F06 Phase 2.2d 按 uuid 查文件 (软删行不返回; 与 GetByID 完全等价仅入参不同).
func (r *FileRepo) GetByUUID(ctx context.Context, uuid string) (*dom.File, error) {
	const q = `
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE uuid = $1 AND is_deleted = false
    `
	var f dom.File
	err := r.pool.QueryRow(ctx, q, uuid).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.GetByUUID: %w", err)
	}
	return &f, nil
}

// RenameTx F06 Phase 2.2d 在 TX 内改 name + 审计字段; 23505 → ErrDuplicateName.
// caller 负责先做 ACL editor+ + copy_status='ready' guard + name 校验.
func (r *FileRepo) RenameTx(ctx context.Context, tx pgx.Tx, id int64, newName string, updatedBy int64) (*dom.File, error) {
	const q = `
        UPDATE drive_files
           SET name = $1, updated_at = now(), updated_by = $2
         WHERE id = $3 AND is_deleted = false
        RETURNING id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                  origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                  thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                  copy_started_at, copy_finished_at,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.File
	err := tx.QueryRow(ctx, q, newName, updatedBy, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrDuplicateName
		}
		return nil, fmt.Errorf("drive.FileRepo.RenameTx: %w", err)
	}
	return &f, nil
}

// CreateCopyingTx Phase 2.11/2.12: 跨 space file move 的第一步, INSERT 一行
//
//	copy_status='copying' + copy_source_file_id=源 + copy_started_at=now(),
//	storage_key 此时是预留的新 final key (caller 算好), 对象尚未真 copy 到位.
//
// 23505 → ErrDuplicateName (dst folder 同名冲突).
func (r *FileRepo) CreateCopyingTx(ctx context.Context, tx pgx.Tx, in dom.CreateFileInput, sourceFileID int64) (*dom.File, error) {
	const q = `
        INSERT INTO drive_files (
            space_id, scope, source, drive_folder_id,
            storage_key, name, mime_type, size_bytes, sha256,
            copy_status, copy_source_file_id, copy_started_at,
            created_by, updated_by
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'copying', $10, now(), $11, $11)
        RETURNING id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                  origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                  thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                  copy_started_at, copy_finished_at,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.File
	err := tx.QueryRow(ctx, q,
		in.SpaceID, string(in.Scope), string(in.Source), in.DriveFolderID,
		in.StorageKey, in.Name, in.MimeType, in.SizeBytes, in.SHA256,
		sourceFileID, in.CreatedBy,
	).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrDuplicateName
		}
		return nil, fmt.Errorf("drive.FileRepo.CreateCopyingTx: %w", err)
	}
	return &f, nil
}

// UpdateCopyStatusTx Phase 2.11/2.12: 状态机迁移 copying → ready | copy_failed.
//   - newStatus='ready':       copy_finished_at=now(), copy_failure_reason=NULL
//   - newStatus='copy_failed': copy_finished_at=now(), copy_failure_reason=reason
//
// 调方应已经把对象端的 Copy 操作做完 (成功或失败) 才调本方法.
func (r *FileRepo) UpdateCopyStatusTx(ctx context.Context, tx pgx.Tx, id int64, newStatus string, reason *string) error {
	const q = `
        UPDATE drive_files
           SET copy_status = $1,
               copy_finished_at = now(),
               copy_failure_reason = $2,
               updated_at = now()
         WHERE id = $3 AND is_deleted = false
    `
	tag, err := tx.Exec(ctx, q, newStatus, reason, id)
	if err != nil {
		return fmt.Errorf("drive.FileRepo.UpdateCopyStatusTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// MoveTx F06 Phase 2.2d 在 TX 内改 drive_folder_id; newFolderID=nil → 移到 space 根.
// 23505 → ErrDuplicateName (target folder 已有同名).
func (r *FileRepo) MoveTx(ctx context.Context, tx pgx.Tx, id int64, newFolderID *int64, updatedBy int64) (*dom.File, error) {
	const q = `
        UPDATE drive_files
           SET drive_folder_id = $1, updated_at = now(), updated_by = $2
         WHERE id = $3 AND is_deleted = false
        RETURNING id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                  origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                  thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                  copy_started_at, copy_finished_at,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.File
	err := tx.QueryRow(ctx, q, newFolderID, updatedBy, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrDuplicateName
		}
		return nil, fmt.Errorf("drive.FileRepo.MoveTx: %w", err)
	}
	return &f, nil
}

// SoftDelete F06 Phase 2.2d 软删 file 行 (非 TX 路径; Phase 2.2e 起改走 SoftDeleteTx +
// 同事务写 drive_recycle_bin). 旧调用方保留接口兼容.
func (r *FileRepo) SoftDelete(ctx context.Context, id, deletedBy int64) error {
	tag, err := r.pool.Exec(ctx, softDeleteFileSQL, deletedBy, id)
	if err != nil {
		return fmt.Errorf("drive.FileRepo.SoftDelete: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// SoftDeleteTx F06 Phase 2.2e: TX 变体, service 在 BeginTx 后传 tx 进来 (跟 RecycleRepo.CreateTx
// 同事务, 保证 "软删 file + 写回收行" 原子).
func (r *FileRepo) SoftDeleteTx(ctx context.Context, tx pgx.Tx, id, deletedBy int64) error {
	tag, err := tx.Exec(ctx, softDeleteFileSQL, deletedBy, id)
	if err != nil {
		return fmt.Errorf("drive.FileRepo.SoftDeleteTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// softDeleteFileSQL 共用模板.
const softDeleteFileSQL = `
    UPDATE drive_files
       SET is_deleted = true,
           deleted_at = now(),
           updated_at = now(),
           updated_by = $1
     WHERE id = $2 AND is_deleted = false
`

// LockByIDTx F06 Phase 2.2e: restore/purge 入口 SELECT FOR UPDATE file (含已 soft-deleted 行;
// 回收站里的 file is_deleted=true, 但我们要锁它来 restore/purge). 与 GetByID 不同, 这里
// **不**过滤 is_deleted.
func (r *FileRepo) LockByIDTx(ctx context.Context, tx pgx.Tx, id int64) (*dom.File, error) {
	const q = `
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE id = $1
        FOR UPDATE
    `
	var f dom.File
	err := tx.QueryRow(ctx, q, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.LockByIDTx: %w", err)
	}
	return &f, nil
}

// RestoreTx F06 Phase 2.2e: 反向软删 (recycle restore 路径); is_deleted=true → false.
// 23505 → ErrDuplicateName (并发场景: 同 folder 同 name 已被新 file 占用).
func (r *FileRepo) RestoreTx(ctx context.Context, tx pgx.Tx, id, updatedBy int64) error {
	const q = `
        UPDATE drive_files
           SET is_deleted = false,
               deleted_at = NULL,
               updated_at = now(),
               updated_by = $1
         WHERE id = $2 AND is_deleted = true
    `
	tag, err := tx.Exec(ctx, q, updatedBy, id)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return ErrDuplicateName
		}
		return fmt.Errorf("drive.FileRepo.RestoreTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListLiveByFolderIDsTx B2 (recursive folder soft delete): 列 folderIDs 下所有未软删的 file.
// scope/source 不限 (drive + chat 都列; chat scope 不挂 folder, 但理论上 caller 传的都是 drive folder ids).
// 返字段集与 GetByID 一致 (含 size_bytes, 用于 recycle bytes_to_reclaim).
func (r *FileRepo) ListLiveByFolderIDsTx(ctx context.Context, tx pgx.Tx, folderIDs []int64) ([]dom.File, error) {
	if len(folderIDs) == 0 {
		return nil, nil
	}
	const q = `
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE drive_folder_id = ANY($1) AND is_deleted = false
    `
	rows, err := tx.Query(ctx, q, folderIDs)
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.ListLiveByFolderIDsTx: %w", err)
	}
	defer rows.Close()
	var out []dom.File
	for rows.Next() {
		var f dom.File
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
			&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
			&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
			&f.CopyStartedAt, &f.CopyFinishedAt,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.FileRepo.ListLiveByFolderIDsTx scan: %w", err)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// SoftDeleteByIDsTx B2: 批量软删 files (`is_deleted=true, deleted_at=now()`).
// caller 已锁 root folder + 列了 ids; quota / space.used_bytes **不**在这里释放 (purge 才释).
func (r *FileRepo) SoftDeleteByIDsTx(ctx context.Context, tx pgx.Tx, ids []int64, updatedBy int64) error {
	if len(ids) == 0 {
		return nil
	}
	const q = `
        UPDATE drive_files
           SET is_deleted = true,
               deleted_at = now(),
               updated_at = now(),
               updated_by = $1
         WHERE id = ANY($2) AND is_deleted = false
    `
	if _, err := tx.Exec(ctx, q, updatedBy, ids); err != nil {
		return fmt.Errorf("drive.FileRepo.SoftDeleteByIDsTx: %w", err)
	}
	return nil
}

// UpdateContentInput B1 versioning + restore 用: 改 storage_key / size / mime / sha256 + 审计字段.
// 不动 name / folder / scope / source / copy_status / is_deleted.
type UpdateContentInput struct {
	StorageKey string
	SizeBytes  int64
	MimeType   string
	SHA256     *string
	UpdatedBy  int64
}

// UpdateContentTx B1: 在 TX 内 rewire 一行 drive_files 的内容指针 (storage_key + size + mime + sha256).
// 用于:
//   - 同名上传命中已 ready 行 → 旧行快照入 drive_file_versions, 当前行换指针 (UploadSvc.runConfirmBackHalf)
//   - 历史版本 restore → 当前行先 snapshot 入 drive_file_versions, 再 rewire 指向选中的版本 (FileSvc.RestoreVersion)
//
// caller 保证已锁 file 行 (LockByIDTx) + copy_status='ready' + ACL editor+.
func (r *FileRepo) UpdateContentTx(ctx context.Context, tx pgx.Tx, id int64, in UpdateContentInput) (*dom.File, error) {
	const q = `
        UPDATE drive_files
           SET storage_key = $1,
               size_bytes  = $2,
               mime_type   = $3,
               sha256      = $4,
               updated_at  = now(),
               updated_by  = $5
         WHERE id = $6 AND is_deleted = false
        RETURNING id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                  origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                  thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                  copy_started_at, copy_finished_at,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.File
	err := tx.QueryRow(ctx, q,
		in.StorageKey, in.SizeBytes, in.MimeType, in.SHA256, in.UpdatedBy, id,
	).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.UpdateContentTx: %w", err)
	}
	return &f, nil
}

// HardDeleteByIDTx F06 Phase 2.2e: purge 路径物理删 file 行.
func (r *FileRepo) HardDeleteByIDTx(ctx context.Context, tx pgx.Tx, id int64) error {
	tag, err := tx.Exec(ctx, `DELETE FROM drive_files WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("drive.FileRepo.HardDeleteByIDTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// RecentByAccessibleSpaces F06 Phase 2.2e + B4: 列出可见文件 (scope=drive, 非软删) 按 updated_at DESC.
//
// 可见集 = (space_id ∈ spaceIDs) OR (drive_folder_id ∈ extraFolderIDs) OR (id ∈ extraFileIDs).
// B4 (granular ACL) 起 caller 传 folder/file extra ids — 即使没 space-level 权限, 单文件/单 folder
// grant 也能命中. Phase 2.2e 路径 caller 传空 slice 等同老行为 (仅 space 过滤).
//
// spaceIDs + extraFolderIDs + extraFileIDs 全空 → 返 ([], 0) (DB 不查).
// 仅 scope='drive' (chat scope 不在 Drive UI 露出).
func (r *FileRepo) RecentByAccessibleSpaces(ctx context.Context, spaceIDs, extraFolderIDs, extraFileIDs []int64, limit int) ([]dom.File, int, error) {
	if len(spaceIDs) == 0 && len(extraFolderIDs) == 0 && len(extraFileIDs) == 0 {
		return nil, 0, nil
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	const whereVisible = `(space_id = ANY($1) OR drive_folder_id = ANY($2) OR id = ANY($3))
          AND scope = 'drive' AND is_deleted = false`

	var total int
	if err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM drive_files WHERE `+whereVisible,
		spaceIDs, extraFolderIDs, extraFileIDs).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("drive.FileRepo.RecentByAccessibleSpaces count: %w", err)
	}

	q := `
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE ` + whereVisible + `
        ORDER BY updated_at DESC
        LIMIT $4
    `
	rows, err := r.pool.Query(ctx, q, spaceIDs, extraFolderIDs, extraFileIDs, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.FileRepo.RecentByAccessibleSpaces: %w", err)
	}
	defer rows.Close()

	var out []dom.File
	for rows.Next() {
		var f dom.File
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
			&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
			&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
			&f.CopyStartedAt, &f.CopyFinishedAt,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, 0, fmt.Errorf("drive.FileRepo.RecentByAccessibleSpaces scan: %w", err)
		}
		out = append(out, f)
	}
	return out, total, rows.Err()
}

// SearchByName F06 Phase 2.2e + B4: GIN tsvector 搜文件名; ACL = space-set ∪ folder-grant ∪ file-grant.
// query 由 service 层 trim/校验 (非空); plainto_tsquery 容错 stop-word/分词错误.
// extra ids 见 RecentByAccessibleSpaces 说明.
func (r *FileRepo) SearchByName(ctx context.Context, spaceIDs, extraFolderIDs, extraFileIDs []int64, query string, limit int) ([]dom.File, int, error) {
	if len(spaceIDs) == 0 && len(extraFolderIDs) == 0 && len(extraFileIDs) == 0 {
		return nil, 0, nil
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	const whereVisibleAndQuery = `(space_id = ANY($1) OR drive_folder_id = ANY($2) OR id = ANY($3))
          AND scope = 'drive' AND is_deleted = false
          AND to_tsvector('simple', name) @@ plainto_tsquery('simple', $4)`

	var total int
	if err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM drive_files WHERE `+whereVisibleAndQuery,
		spaceIDs, extraFolderIDs, extraFileIDs, query).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("drive.FileRepo.SearchByName count: %w", err)
	}

	q := `
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE ` + whereVisibleAndQuery + `
        ORDER BY updated_at DESC
        LIMIT $5
    `
	rows, err := r.pool.Query(ctx, q, spaceIDs, extraFolderIDs, extraFileIDs, query, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.FileRepo.SearchByName: %w", err)
	}
	defer rows.Close()

	var out []dom.File
	for rows.Next() {
		var f dom.File
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
			&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
			&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
			&f.CopyStartedAt, &f.CopyFinishedAt,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, 0, fmt.Errorf("drive.FileRepo.SearchByName scan: %w", err)
		}
		out = append(out, f)
	}
	return out, total, rows.Err()
}

// ListInSpace F06 Phase 2.2f: GET /drive/files flat list 后端.
// 单 space 内列文件 (scope='drive', 未软删), 支持可选 folder 过滤 + 名称 ILIKE + mime 前缀 + cursor 分页.
//
// 参数:
//   - spaceID: 必填; caller 已在 service 层做完 ACL viewer+ 检查.
//   - folderID: 可空; 非 nil 时过滤 drive_folder_id=$id; nil 时不限定 folder (返 space-wide).
//   - qLike: 可空; service 层已 escape (% / _ / \\); 直接当 ILIKE pattern 用.
//     空 → 不附加过滤.
//   - mimePrefix: 可空; service 层已 escape; 直接当 LIKE pattern 用 (e.g. "image/%").
//     空 → 不附加过滤.
//   - cursorID: > 0 → AND id > $cursor (keyset 分页); 0 → 从头.
//   - limit: > 0; service 层已 default 50 / cap 200.
//
// 排序: ORDER BY id ASC (cursor 分页友好; 与 RecentByAccessibleSpaces 的 updated_at DESC 区分).
// 返回: (rows, nextCursor); 行数 < limit 时 nextCursor=0.
func (r *FileRepo) ListInSpace(
	ctx context.Context,
	spaceID int64,
	folderID *int64,
	rootOnly bool,
	qLike, mimePrefix string,
	cursorID int64,
	limit int,
) ([]dom.File, int64, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	// 动态拼 SQL: 用 $N 参数化, 不做字符串拼接 user input.
	args := []any{spaceID}
	where := "space_id = $1 AND scope = 'drive' AND is_deleted = false"
	if folderID != nil {
		args = append(args, *folderID)
		where += fmt.Sprintf(" AND drive_folder_id = $%d", len(args))
	} else if rootOnly {
		where += " AND drive_folder_id IS NULL"
	}
	if qLike != "" {
		args = append(args, "%"+qLike+"%")
		where += fmt.Sprintf(" AND name ILIKE $%d ESCAPE '\\'", len(args))
	}
	if mimePrefix != "" {
		args = append(args, mimePrefix+"%")
		where += fmt.Sprintf(" AND mime_type LIKE $%d ESCAPE '\\'", len(args))
	}
	if cursorID > 0 {
		args = append(args, cursorID)
		where += fmt.Sprintf(" AND id > $%d", len(args))
	}
	args = append(args, limit)
	q := fmt.Sprintf(`
        SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
               origin_message_file_id, origin_conversation_uuid, origin_agent_id,
               thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
               copy_started_at, copy_finished_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_files
        WHERE %s
        ORDER BY id ASC
        LIMIT $%d
    `, where, len(args))

	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("drive.FileRepo.ListInSpace: %w", err)
	}
	defer rows.Close()

	var out []dom.File
	for rows.Next() {
		var f dom.File
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
			&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
			&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
			&f.CopyStartedAt, &f.CopyFinishedAt,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, 0, fmt.Errorf("drive.FileRepo.ListInSpace scan: %w", err)
		}
		out = append(out, f)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, fmt.Errorf("drive.FileRepo.ListInSpace rows: %w", err)
	}

	// nextCursor: 满 limit → 最后一行 id; 不满 → 0.
	var nextCursor int64
	if len(out) == limit {
		nextCursor = out[len(out)-1].ID
	}
	return out, nextCursor, nil
}

// ImportFromChatTx F06 Phase 2.3 chat-import 行级 UPDATE: 把 scope='chat' 行升为 scope='drive'
// + 挂到目标 folder + 记录 origin_message_file_id=cmf.id.
//
// 不动 storage_key / size_bytes / sha256 / drive_file_uuid (用户在 chat 见到的就是同一个 uuid 同一份字节),
// 仅切换 scope / source / drive_folder_id / origin_message_file_id + 审计字段.
//
// 23505 uq_dfile_folder_name (target folder 已有同名 file) → ErrDuplicateName;
// caller 负责翻成 409 drive.duplicate_name.
//
// 入口 caller 必须已:
//   - 反查 cmf (验 tenant + 拿到 cmf.ID 当 origin)
//   - 反查 drive_files (验 scope='chat' + tenant)
//   - 反查 target folder (验 same tenant + 非 system + editor+ ACL)
func (r *FileRepo) ImportFromChatTx(
	ctx context.Context, tx pgx.Tx, fileID, targetFolderID, cmfID, updatedBy int64,
) (*dom.File, error) {
	const q = `
        UPDATE drive_files
           SET scope = 'drive',
               source = 'chat_import',
               drive_folder_id = $1,
               origin_message_file_id = $2,
               updated_at = now(),
               updated_by = $3
         WHERE id = $4 AND is_deleted = false
        RETURNING id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                  origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                  thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                  copy_started_at, copy_finished_at,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.File
	err := tx.QueryRow(ctx, q, targetFolderID, cmfID, updatedBy, fileID).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrDuplicateName
		}
		return nil, fmt.Errorf("drive.FileRepo.ImportFromChatTx: %w", err)
	}
	return &f, nil
}

// GetBySpaceRootAndName duplicate-name precheck for files directly under a space root.
// It is scoped by space_id because drive_folder_id is NULL for every root file.
func (r *FileRepo) GetBySpaceRootAndName(ctx context.Context, spaceID int64, name string) (*dom.File, error) {
	const q = `
            SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                   origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                   thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                   copy_started_at, copy_finished_at,
                   created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
            FROM drive_files
            WHERE space_id = $1 AND drive_folder_id IS NULL AND scope = 'drive' AND name = $2 AND is_deleted = false
            LIMIT 1
        `
	var f dom.File
	err := r.pool.QueryRow(ctx, q, spaceID, name).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.GetBySpaceRootAndName: %w", err)
	}
	return &f, nil
}

// GetByFolderAndName F06 Phase 2.2c duplicate-name 预检 (service confirm 流程在 TX 内调).
// folderID 为 nil → 走 `drive_folder_id IS NULL` 分支 (chat scope 不在本路径用; 留全 NULL 分支兼容).
// 不存在 → ErrNotFound.
func (r *FileRepo) GetByFolderAndName(ctx context.Context, folderID *int64, name string) (*dom.File, error) {
	var (
		row pgx.Row
		q   string
	)
	if folderID == nil {
		q = `
            SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                   origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                   thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                   copy_started_at, copy_finished_at,
                   created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
            FROM drive_files
            WHERE drive_folder_id IS NULL AND name = $1 AND is_deleted = false
            LIMIT 1
        `
		row = r.pool.QueryRow(ctx, q, name)
	} else {
		q = `
            SELECT id, uuid, space_id, scope, source, drive_folder_id, storage_key, name, mime_type, size_bytes, sha256,
                   origin_message_file_id, origin_conversation_uuid, origin_agent_id,
                   thumbnail_key, thumbnail_status, copy_status, copy_failure_reason, copy_source_file_id,
                   copy_started_at, copy_finished_at,
                   created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
            FROM drive_files
            WHERE drive_folder_id = $1 AND name = $2 AND is_deleted = false
            LIMIT 1
        `
		row = r.pool.QueryRow(ctx, q, *folderID, name)
	}
	var f dom.File
	err := row.Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.Scope, &f.Source, &f.DriveFolderID, &f.StorageKey, &f.Name, &f.MimeType, &f.SizeBytes, &f.SHA256,
		&f.OriginMessageFileID, &f.OriginConversationUUID, &f.OriginAgentID,
		&f.ThumbnailKey, &f.ThumbnailStatus, &f.CopyStatus, &f.CopyFailureReason, &f.CopySourceFileID,
		&f.CopyStartedAt, &f.CopyFinishedAt,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.GetByFolderAndName: %w", err)
	}
	return &f, nil
}

// GetByOutputStorageKey resolves a confirmed ticket to the actual file UUID.
// Tickets have upload UUIDs; CreateTx generates a separate file UUID, and later
// same-name uploads retain it while moving old object keys into versions.
func (r *FileRepo) GetByOutputStorageKey(ctx context.Context, accountID, folderID int64, key string) (*dom.File, error) {
	const q = `SELECT f.uuid FROM drive_files f
 WHERE f.created_by=$1 AND f.drive_folder_id=$2 AND f.is_deleted=false
 AND (f.storage_key=$3 OR EXISTS (SELECT 1 FROM drive_file_versions v WHERE v.file_id=f.id AND v.storage_key=$3)) LIMIT 1`
	var id string
	err := r.pool.QueryRow(ctx, q, accountID, folderID, key).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileRepo.GetByOutputStorageKey: %w", err)
	}
	return r.GetByUUID(ctx, id)
}
