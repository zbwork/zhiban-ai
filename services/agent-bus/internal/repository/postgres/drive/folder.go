package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// FolderRepo F06 §2.3 drive_folders 的 PG 实现.
type FolderRepo struct{ pool *pgxpool.Pool }

// NewFolderRepo 构造.
func NewFolderRepo(pool *pgxpool.Pool) *FolderRepo { return &FolderRepo{pool: pool} }

// escapeLike 把 \, %, _ 在 LIKE pattern 里转义掉, 与 SQL `ESCAPE '\'` 搭配使用.
// 必须先转 `\` (否则后续插入的 `\%` / `\_` 会再被自己 escape 一次).
// 用例: validFolderName 允许 `_` `%`, 不转义会让 `like_test/%` 误匹配到 `likextest/`.
func escapeLike(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `%`, `\%`)
	s = strings.ReplaceAll(s, `_`, `\_`)
	return s
}

// GetByID 按 id 查 1 行; 软删 (is_deleted=true) 行不返回.
func (r *FolderRepo) GetByID(ctx context.Context, id int64) (*dom.Folder, error) {
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_folders
        WHERE id = $1 AND is_deleted = false
    `
	var f dom.Folder
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.GetByID: %w", err)
	}
	return &f, nil
}

// ListByIDs 批量按 id 查; 与 GetByID 同口径 is_deleted=false, 缺失/软删 id 不返回.
// discover 列表批量补齐 folder_uuid 用 (替代逐 file GetByID N+1).
func (r *FolderRepo) ListByIDs(ctx context.Context, ids []int64) ([]dom.Folder, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_folders
        WHERE id = ANY($1) AND is_deleted = false
    `
	rows, err := r.pool.Query(ctx, q, ids)
	if err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.ListByIDs: %w", err)
	}
	defer rows.Close()
	var out []dom.Folder
	for rows.Next() {
		var f dom.Folder
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.FolderRepo.ListByIDs.scan: %w", err)
		}
		out = append(out, f)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.ListByIDs.rows: %w", err)
	}
	return out, nil
}

// GetByIDIncludingDeleted 按 id 查 1 行, 不排除软删行。
// 回收站 admin 列表需要展示已删除目录的原始 uuid/name 等只读元数据。
func (r *FolderRepo) GetByIDIncludingDeleted(ctx context.Context, id int64) (*dom.Folder, error) {
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_folders
        WHERE id = $1
    `
	var f dom.Folder
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.GetByIDIncludingDeleted: %w", err)
	}
	return &f, nil
}

// GetByUUID 按 uuid 查 1 行; 软删行不返回.
func (r *FolderRepo) GetByUUID(ctx context.Context, uuid string) (*dom.Folder, error) {
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_folders
        WHERE uuid = $1 AND is_deleted = false
    `
	var f dom.Folder
	err := r.pool.QueryRow(ctx, q, uuid).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.GetByUUID: %w", err)
	}
	return &f, nil
}

// ListBySpace 列出某 space 下所有未软删 folder, 按 path/sort 排序.
// 用于 folder tree 接口 (一次拉全树, 前端自己组装).
func (r *FolderRepo) ListBySpace(ctx context.Context, spaceID int64) ([]dom.Folder, error) {
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_folders
        WHERE space_id = $1 AND is_deleted = false
        ORDER BY path ASC, sort ASC
    `
	rows, err := r.pool.Query(ctx, q, spaceID)
	if err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.ListBySpace: %w", err)
	}
	defer rows.Close()

	var out []dom.Folder
	for rows.Next() {
		var f dom.Folder
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.FolderRepo.ListBySpace scan: %w", err)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// Create F06 Phase 2.2b 新建 folder; 23505 (uq_folder_sibling) → ErrDuplicateName.
// path 由 service 层预算好后传入 (/<...>/<name>/).
func (r *FolderRepo) Create(ctx context.Context, in dom.CreateFolderInput) (*dom.Folder, error) {
	const q = `
        INSERT INTO drive_folders (
            space_id, parent_id, name, kind, agent_id, is_system, path,
            created_by, updated_by
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
        RETURNING id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.Folder
	err := r.pool.QueryRow(ctx, q,
		in.SpaceID, in.ParentID, in.Name, string(in.Kind), in.AgentID, in.IsSystem, in.Path,
		in.CreatedBy,
	).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrDuplicateName
		}
		return nil, fmt.Errorf("drive.FolderRepo.Create: %w", err)
	}
	return &f, nil
}

// Rename F06 Phase 2.2b 修改 folder.name + folder.path (path 由 service 预算).
// 23505 (uq_folder_sibling) → ErrDuplicateName.
// 非 TX 路径; 上层若需要跟 UpdateDescendantPaths 一起原子化, 走 RenameTx.
func (r *FolderRepo) Rename(ctx context.Context, id int64, newName, newPath string, updatedBy int64) (*dom.Folder, error) {
	return r.renameExec(ctx, r.pool, id, newName, newPath, updatedBy)
}

// RenameTx F06 Phase 2.2b TX 变体; service 在 BeginTx 后传 tx 进来, 跟
// UpdateDescendantPathsTx 同事务, 保证 main 行 + 级联要么全成要么全不动 (I2 修复).
func (r *FolderRepo) RenameTx(ctx context.Context, tx pgx.Tx, id int64, newName, newPath string, updatedBy int64) (*dom.Folder, error) {
	return r.renameExec(ctx, tx, id, newName, newPath, updatedBy)
}

// renameExec 内部实现, 接 pgxExecutor.
func (r *FolderRepo) renameExec(ctx context.Context, ex pgxExecutor, id int64, newName, newPath string, updatedBy int64) (*dom.Folder, error) {
	const q = `
        UPDATE drive_folders
           SET name = $1, path = $2, updated_at = now(), updated_by = $3
         WHERE id = $4 AND is_deleted = false
        RETURNING id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.Folder
	err := ex.QueryRow(ctx, q, newName, newPath, updatedBy, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
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
		return nil, fmt.Errorf("drive.FolderRepo.Rename: %w", err)
	}
	return &f, nil
}

// Move F06 Phase 2.2b 修改 folder.parent_id + folder.path (path 由 service 预算).
// 23505 (uq_folder_sibling) → ErrDuplicateName (新 parent 下已有同名兄弟).
// 非 TX 路径; 上层若需要跟 UpdateDescendantPaths 一起原子化, 走 MoveTx.
func (r *FolderRepo) Move(ctx context.Context, id int64, newParentID *int64, newPath string, updatedBy int64) (*dom.Folder, error) {
	return r.moveExec(ctx, r.pool, id, newParentID, newPath, updatedBy)
}

// MoveTx F06 Phase 2.2b TX 变体; service 在 BeginTx 后传 tx 进来 (I2 修复).
func (r *FolderRepo) MoveTx(ctx context.Context, tx pgx.Tx, id int64, newParentID *int64, newPath string, updatedBy int64) (*dom.Folder, error) {
	return r.moveExec(ctx, tx, id, newParentID, newPath, updatedBy)
}

// moveExec 内部实现, 接 pgxExecutor.
func (r *FolderRepo) moveExec(ctx context.Context, ex pgxExecutor, id int64, newParentID *int64, newPath string, updatedBy int64) (*dom.Folder, error) {
	const q = `
        UPDATE drive_folders
           SET parent_id = $1, path = $2, updated_at = now(), updated_by = $3
         WHERE id = $4 AND is_deleted = false
        RETURNING id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
                  created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
    `
	var f dom.Folder
	err := ex.QueryRow(ctx, q, newParentID, newPath, updatedBy, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
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
		return nil, fmt.Errorf("drive.FolderRepo.Move: %w", err)
	}
	return &f, nil
}

// UpdateDescendantPaths F06 Phase 2.2b 级联更新 space 内所有以 oldPrefix 开头的子 folder 的 path
// (替换为 newPrefix). folderID 是本次刚改的 folder 自身, **跳过不动** (它的 path 已被 Rename/Move 写入).
//
// 用法: oldPrefix / newPrefix 必须均带尾部 /, 形如 "/a/b/" → "/a/c/".
// SQL: path = newPrefix || substring(path, length(oldPrefix)+1)
//
// 没有 oldPrefix 命中的行也合法 (e.g. leaf folder rename) — Exec 不报错.
//
// I1 修复: validFolderName 允许 `_` `%`, 走原始 oldPrefix 当 LIKE pattern 会跨 folder 误匹配
// (例: oldPrefix="/like_test/" 会匹配 "/likextest/x/"). 用 escapeLike + ESCAPE '\' 解决;
// substring 的偏移量必须用 **未转义** 的 oldPrefix 长度, 因为 stored path 里没有反斜杠.
func (r *FolderRepo) UpdateDescendantPaths(ctx context.Context, spaceID, folderID int64, oldPrefix, newPrefix string) error {
	return r.updateDescendantPathsExec(ctx, r.pool, spaceID, folderID, oldPrefix, newPrefix)
}

// pgxExecutor 是 pool 和 tx 共享的最小执行接口, 让 *Tx 变体复用同一段 SQL.
type pgxExecutor interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// updateDescendantPathsExec 内部实现, 接 pgxExecutor (pool 或 tx 都行).
func (r *FolderRepo) updateDescendantPathsExec(ctx context.Context, ex pgxExecutor, spaceID, folderID int64, oldPrefix, newPrefix string) error {
	// substring 用两参数 form substring(path FROM start); start 由应用层算 (oldPrefix 字符长度 +1).
	// **必须用 rune count 不能用 byte count** — PG substring(text FROM int) 是字符索引
	// (1-based codepoint), 不是字节索引. 中文 / 全角字符路径用 len() 会算多 (UTF-8 3-byte/字),
	// 让 substring 跳过过多前缀, 截掉子目录名 (Phase 2.9 数字员工系统目录 rename 暴露).
	// $2::int 显式声明类型, 否则 pgx 对 substring(path FROM $2) 的参数 OID 推断会
	// 落到 text (跟 path 同列类型), int 值就无法 encode (报 OID 25 cannot find encode plan).
	const q = `
        UPDATE drive_folders
           SET path = $1 || substring(path FROM $2::int),
               updated_at = now()
         WHERE space_id = $3
           AND path LIKE $4 ESCAPE '\'
           AND id != $5
           AND is_deleted = false
    `
	_, err := ex.Exec(ctx, q,
		newPrefix,
		utf8.RuneCountInString(oldPrefix)+1,
		spaceID,
		escapeLike(oldPrefix)+"%",
		folderID,
	)
	if err != nil {
		return fmt.Errorf("drive.FolderRepo.UpdateDescendantPaths: %w", err)
	}
	return nil
}

// UpdateDescendantPathsTx F06 Phase 2.2b TX 变体, 由 service 在 Rename/Move 同一事务里调.
// 保证 main 行 + 级联子 path 要么全成要么全不动, 避免 partial-cascade 导致树断裂.
func (r *FolderRepo) UpdateDescendantPathsTx(ctx context.Context, tx pgx.Tx, spaceID, folderID int64, oldPrefix, newPrefix string) error {
	return r.updateDescendantPathsExec(ctx, tx, spaceID, folderID, oldPrefix, newPrefix)
}

// SoftDelete F06 Phase 2.2b 软删 folder (非 TX 路径; Phase 2.2e 起改走 SoftDeleteTx +
// 同事务写 drive_recycle_bin). 保留旧签名以防其它调用方依赖.
func (r *FolderRepo) SoftDelete(ctx context.Context, id, deletedBy int64) error {
	tag, err := r.pool.Exec(ctx, softDeleteFolderSQL, deletedBy, id)
	if err != nil {
		return fmt.Errorf("drive.FolderRepo.SoftDelete: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// SoftDeleteTx F06 Phase 2.2e TX 变体, service 在 BeginTx 后传 tx 进来 (跟 RecycleRepo.CreateTx
// 同事务).
func (r *FolderRepo) SoftDeleteTx(ctx context.Context, tx pgx.Tx, id, deletedBy int64) error {
	tag, err := tx.Exec(ctx, softDeleteFolderSQL, deletedBy, id)
	if err != nil {
		return fmt.Errorf("drive.FolderRepo.SoftDeleteTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// softDeleteFolderSQL 共用模板.
const softDeleteFolderSQL = `
    UPDATE drive_folders
       SET is_deleted = true,
           deleted_at = now(),
           updated_at = now(),
           updated_by = $1
     WHERE id = $2 AND is_deleted = false
`

// LockByIDTx F06 Phase 2.2e: restore/purge 入口 SELECT FOR UPDATE folder (含 is_deleted=true 行).
func (r *FolderRepo) LockByIDTx(ctx context.Context, tx pgx.Tx, id int64) (*dom.Folder, error) {
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_folders
        WHERE id = $1
        FOR UPDATE
    `
	var f dom.Folder
	err := tx.QueryRow(ctx, q, id).Scan(
		&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
		&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.LockByIDTx: %w", err)
	}
	return &f, nil
}

// RestoreTx F06 Phase 2.2e: 反向软删 (recycle restore folder 路径).
// 23505 → ErrDuplicateName (并发: 同 parent 下同名 folder 已被新建).
func (r *FolderRepo) RestoreTx(ctx context.Context, tx pgx.Tx, id, updatedBy int64) error {
	const q = `
        UPDATE drive_folders
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
		return fmt.Errorf("drive.FolderRepo.RestoreTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// HardDeleteByIDTx F06 Phase 2.2e: purge 路径物理删 folder 行.
func (r *FolderRepo) HardDeleteByIDTx(ctx context.Context, tx pgx.Tx, id int64) error {
	tag, err := tx.Exec(ctx, `DELETE FROM drive_folders WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("drive.FolderRepo.HardDeleteByIDTx: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// HasLiveChildren F06 Phase 2.2b 判 folder 是否还有未软删的子 folder 或子 file.
// Phase 2.2b delete guard 用; 任一有 → 拒绝软删.
func (r *FolderRepo) HasLiveChildren(ctx context.Context, folderID int64) (bool, error) {
	// 用 EXISTS UNION ALL 走单 round-trip; 任一 hit 立返 true.
	const q = `
        SELECT EXISTS (
            SELECT 1 FROM drive_folders WHERE parent_id = $1 AND is_deleted = false
            UNION ALL
            SELECT 1 FROM drive_files   WHERE drive_folder_id = $1 AND is_deleted = false
        )
    `
	var has bool
	if err := r.pool.QueryRow(ctx, q, folderID).Scan(&has); err != nil {
		return false, fmt.Errorf("drive.FolderRepo.HasLiveChildren: %w", err)
	}
	return has, nil
}

// ListChildren 列出 folder 直接子 folder (分页).
// pageSize cap 200; page 从 1 起.
func (r *FolderRepo) ListChildren(ctx context.Context, folderID int64, page, pageSize int) ([]dom.Folder, error) {
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

	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_folders
        WHERE parent_id = $1 AND is_deleted = false
        ORDER BY sort ASC, created_at DESC
        LIMIT $2 OFFSET $3
    `
	rows, err := r.pool.Query(ctx, q, folderID, pageSize, offset)
	if err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.ListChildren: %w", err)
	}
	defer rows.Close()

	var out []dom.Folder
	for rows.Next() {
		var f dom.Folder
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.FolderRepo.ListChildren scan: %w", err)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// ListLiveDescendantsTx B2 (recursive soft delete): 列出 root 之下所有未软删的子 folder.
// 不含 root 本身. path LIKE rootPath||'%' (root 自身的 path == rootPath, 排掉; 用 != id).
// LIKE pattern 已用 escapeLike (与 UpdateDescendantPaths 一致, 防 `_` `%` 误匹配).
//
// 不含系统目录? — 系统目录 (de_root / de_agent / de_outputs) 已在 service 层 root.IsSystem 检查
// 时拒掉. 但 root 是非系统的 regular folder, 其子树**理论上**不会有系统目录 (系统目录直接挂 space
// 根或挂在 de_root 下, 不会嵌进 regular folder). 这里不再筛, service 层信任.
func (r *FolderRepo) ListLiveDescendantsTx(ctx context.Context, tx pgx.Tx, spaceID int64, rootID int64, rootPath string) ([]dom.Folder, error) {
	const q = `
        SELECT id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
               created_at, created_by, updated_at, updated_by, is_deleted, deleted_at
        FROM drive_folders
        WHERE space_id = $1
          AND id != $2
          AND is_deleted = false
          AND path LIKE $3 ESCAPE '\'
        ORDER BY path ASC
    `
	prefix := escapeLike(rootPath) + "%"
	rows, err := tx.Query(ctx, q, spaceID, rootID, prefix)
	if err != nil {
		return nil, fmt.Errorf("drive.FolderRepo.ListLiveDescendantsTx: %w", err)
	}
	defer rows.Close()
	var out []dom.Folder
	for rows.Next() {
		var f dom.Folder
		if err := rows.Scan(
			&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt,
		); err != nil {
			return nil, fmt.Errorf("drive.FolderRepo.ListLiveDescendantsTx scan: %w", err)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// SoftDeleteByIDsTx B2: 批量软删 folders (`is_deleted=true, deleted_at=now()`).
// caller 已锁 root + 列了 ids; 不再单条 LockByIDTx (root 锁住后子树不会被并发改).
func (r *FolderRepo) SoftDeleteByIDsTx(ctx context.Context, tx pgx.Tx, ids []int64, updatedBy int64) error {
	if len(ids) == 0 {
		return nil
	}
	const q = `
        UPDATE drive_folders
           SET is_deleted = true,
               deleted_at = now(),
               updated_at = now(),
               updated_by = $1
         WHERE id = ANY($2) AND is_deleted = false
    `
	if _, err := tx.Exec(ctx, q, updatedBy, ids); err != nil {
		return fmt.Errorf("drive.FolderRepo.SoftDeleteByIDsTx: %w", err)
	}
	return nil
}
