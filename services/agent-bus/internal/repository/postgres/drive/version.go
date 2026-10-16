package drive

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// FileVersionRepo F06 §2.7 drive_file_versions 的 PG 实现.
//
// B1 (file versioning) 引入:
//   - InsertSnapshotTx — TX 内 INSERT 一条 "旧版本快照" (version_no auto = MAX+1)
//   - GetByFileAndVersionTx — TX 内按 (file_id, version_no) 取一行 (restore 用)
//   - ListByFileID — 列某 file 的全部历史版本 (按 version_no DESC)
type FileVersionRepo struct{ pool *pgxpool.Pool }

// NewFileVersionRepo 构造.
func NewFileVersionRepo(pool *pgxpool.Pool) *FileVersionRepo { return &FileVersionRepo{pool: pool} }

// GetByID 按 id 查 1 行; 软删 (is_deleted=true) 行不返回.
func (r *FileVersionRepo) GetByID(ctx context.Context, id int64) (*dom.FileVersion, error) {
	const q = `
        SELECT id, uuid, file_id, version_no, storage_key, size_bytes, sha256, name, upload_source, superseded_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_file_versions
        WHERE id = $1 AND is_deleted = false
    `
	var v dom.FileVersion
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&v.ID, &v.UUID, &v.FileID, &v.VersionNo, &v.StorageKey, &v.SizeBytes, &v.SHA256, &v.Name, &v.UploadSource, &v.SupersededAt,
		&v.CreatedAt, &v.CreatedBy, &v.UpdatedAt, &v.UpdatedBy, &v.IsDeleted, &v.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileVersionRepo.GetByID: %w", err)
	}
	return &v, nil
}

// InsertSnapshotInput B1 versioning 输入: 旧 drive_files 行的快照 + 触发版本化的上传 source.
//
// version_no 由 repo 在 INSERT 时自动算 (= MAX(version_no) + 1 per file_id),
// caller 不传 — 避免 caller 与 repo 在 race 下双方各算一遍 不一致.
type InsertSnapshotInput struct {
	FileID       int64
	StorageKey   string
	SizeBytes    int64
	SHA256       *string
	Name         string
	UploadSource dom.FileSource
	CreatedBy    int64
}

// InsertSnapshotTx F06 §2.7 + B1 TX 内插入一条 file_version 快照.
// version_no 取 MAX(version_no)+1 per file_id (子查询); UNIQUE (file_id, version_no) 保证并发下 race 报 23505.
// 23505 → ErrConflict (caller 处理重试或返 500).
func (r *FileVersionRepo) InsertSnapshotTx(ctx context.Context, tx pgx.Tx, in InsertSnapshotInput) (*dom.FileVersion, error) {
	const q = `
        INSERT INTO drive_file_versions (
            file_id, version_no, storage_key, size_bytes, sha256, name, upload_source, superseded_at,
            created_by, updated_by
        )
        SELECT $1,
               COALESCE(MAX(version_no), 0) + 1,
               $2, $3, $4, $5, $6, now(),
               $7, $7
          FROM drive_file_versions
         WHERE file_id = $1
        RETURNING id, uuid, file_id, version_no, storage_key, size_bytes, sha256, name, upload_source, superseded_at,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var v dom.FileVersion
	err := tx.QueryRow(ctx, q,
		in.FileID, in.StorageKey, in.SizeBytes, in.SHA256, in.Name, string(in.UploadSource),
		in.CreatedBy,
	).Scan(
		&v.ID, &v.UUID, &v.FileID, &v.VersionNo, &v.StorageKey, &v.SizeBytes, &v.SHA256, &v.Name, &v.UploadSource, &v.SupersededAt,
		&v.CreatedAt, &v.CreatedBy, &v.UpdatedAt, &v.UpdatedBy, &v.IsDeleted, &v.DeletedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("drive.FileVersionRepo.InsertSnapshotTx: %w", err)
	}
	return &v, nil
}

// GetByFileAndVersionTx B1 restore 用: TX 内按 (file_id, version_no) 取一行 (软删行不返回).
func (r *FileVersionRepo) GetByFileAndVersionTx(ctx context.Context, tx pgx.Tx, fileID int64, versionNo int) (*dom.FileVersion, error) {
	const q = `
        SELECT id, uuid, file_id, version_no, storage_key, size_bytes, sha256, name, upload_source, superseded_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_file_versions
        WHERE file_id = $1 AND version_no = $2 AND is_deleted = false
    `
	var v dom.FileVersion
	err := tx.QueryRow(ctx, q, fileID, versionNo).Scan(
		&v.ID, &v.UUID, &v.FileID, &v.VersionNo, &v.StorageKey, &v.SizeBytes, &v.SHA256, &v.Name, &v.UploadSource, &v.SupersededAt,
		&v.CreatedAt, &v.CreatedBy, &v.UpdatedAt, &v.UpdatedBy, &v.IsDeleted, &v.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FileVersionRepo.GetByFileAndVersionTx: %w", err)
	}
	return &v, nil
}

// ListFileIDsWithExcess B5 (VersionCleaner): 列 drive_file_versions 里版本数 > keepLatest 的 file_id.
// caller 对每个 file_id 调 ListByFileID 拿全部行, 然后 offset keepLatest 处往后 hard-delete.
//
// 用于 worker 定期把超量版本清理掉, 避免 S3 / DB 堆积.
func (r *FileVersionRepo) ListFileIDsWithExcess(ctx context.Context, keepLatest, limit int) ([]int64, error) {
	if keepLatest < 0 {
		keepLatest = 0
	}
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	const q = `
        SELECT file_id
          FROM drive_file_versions
         WHERE is_deleted = false
         GROUP BY file_id
        HAVING COUNT(*) > $1
         ORDER BY file_id
         LIMIT $2
    `
	rows, err := r.pool.Query(ctx, q, keepLatest, limit)
	if err != nil {
		return nil, fmt.Errorf("drive.FileVersionRepo.ListFileIDsWithExcess: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("drive.FileVersionRepo.ListFileIDsWithExcess scan: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// CountExcess Phase A2 admin workers page: 返 "版本数 > keepLatest" 的 file 数.
// 用于 VersionCleaner pending count 展示.
func (r *FileVersionRepo) CountExcess(ctx context.Context, keepLatest int) (int64, error) {
	if keepLatest < 0 {
		keepLatest = 0
	}
	const q = `
        SELECT COUNT(*) FROM (
          SELECT 1 FROM drive_file_versions
           WHERE is_deleted = false
           GROUP BY file_id
          HAVING COUNT(*) > $1
        ) AS sub
    `
	var n int64
	if err := r.pool.QueryRow(ctx, q, keepLatest).Scan(&n); err != nil {
		return 0, fmt.Errorf("drive.FileVersionRepo.CountExcess: %w", err)
	}
	return n, nil
}

// HardDeleteByID B5: 物理删 1 行 (caller 已 store.Delete 完 S3 对象).
func (r *FileVersionRepo) HardDeleteByID(ctx context.Context, id int64) error {
	tag, err := r.pool.Exec(ctx, `DELETE FROM drive_file_versions WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("drive.FileVersionRepo.HardDeleteByID: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListByFileID B1: 列某 file 的全部历史版本 (按 version_no DESC; 软删行不返回).
// 当前 drive_files 一行 NOT 在这个列表里 (它不是历史, 而是"当前").
func (r *FileVersionRepo) ListByFileID(ctx context.Context, fileID int64) ([]dom.FileVersion, error) {
	const q = `
        SELECT id, uuid, file_id, version_no, storage_key, size_bytes, sha256, name, upload_source, superseded_at,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_file_versions
        WHERE file_id = $1 AND is_deleted = false
        ORDER BY version_no DESC
    `
	rows, err := r.pool.Query(ctx, q, fileID)
	if err != nil {
		return nil, fmt.Errorf("drive.FileVersionRepo.ListByFileID: %w", err)
	}
	defer rows.Close()
	var out []dom.FileVersion
	for rows.Next() {
		var v dom.FileVersion
		if err := rows.Scan(
			&v.ID, &v.UUID, &v.FileID, &v.VersionNo, &v.StorageKey, &v.SizeBytes, &v.SHA256, &v.Name, &v.UploadSource, &v.SupersededAt,
			&v.CreatedAt, &v.CreatedBy, &v.UpdatedAt, &v.UpdatedBy, &v.IsDeleted, &v.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.FileVersionRepo.ListByFileID scan: %w", err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("drive.FileVersionRepo.ListByFileID rows.Err: %w", err)
	}
	return out, nil
}

// StorageKeyByChecksum selects only a version of an already ACL-authorized file.
func (r *FileVersionRepo) StorageKeyByChecksum(ctx context.Context, fileID int64, checksum string) (string, error) {
	var key string
	err := r.pool.QueryRow(ctx, `SELECT storage_key FROM drive_file_versions WHERE file_id=$1 AND sha256=$2 AND NOT is_deleted ORDER BY version_no DESC LIMIT 1`, fileID, checksum).Scan(&key)
	return key, err
}
