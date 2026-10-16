// folder.go — F06 Phase 2.2b FolderSvc: folder create / rename / move (same-space) / delete.
//
// ACL: editor+ 必检 (用 ACLService.CheckEffectiveRole).
// 系统目录 (is_system=true) reject rename/move/delete; 创建子时 parent.is_system 也 reject.
// 同 parent 同名冲突 → 409 drive.duplicate_name (基于 uq_folder_sibling).
// 跨 space parent (create/move) → 403 drive.cross_space_move_not_allowed (Phase 2.2b 仅同 space).
// Move 防环 (自移自 / 移到后代) → 400 drive.folder_cycle.
// Delete 仅空 folder (Phase 2.2b 不接 recycle_bin write, 由 Phase 2.2e 接).
//
// path 维护: parent.path + name + "/" (root parent=空时 = "/<name>/");
// rename/move 时级联 UPDATE 后代 folder.path 前缀.
package drive

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// FolderSvc Phase 2.2b: 4 个 folder mutation 端点的服务层.
// B2 起 Delete recursive=true 需级联软删子文件 → 注入 FileRepo.
type FolderSvc struct {
	pool       *pgxpool.Pool
	spaces     *drepo.SpaceRepo
	folders    *drepo.FolderRepo
	files      *drepo.FileRepo    // B2: recursive delete 列子文件 + 批量软删 + 写 recycle 行
	recycle    *drepo.RecycleRepo // Phase 2.2e: Delete 时写回收行
	acl        *ACLService
	recycleTTL time.Duration // 默认 30 天 (F06 §4.7)
}

// NewFolderSvc 构造. recycle 可为 nil (兼容旧 caller); Phase 2.Z 改必传.
// files 同样可为 nil (旧 caller); Delete(recursive=true) 时若 files==nil 会 ErrInternal.
func NewFolderSvc(pool *pgxpool.Pool, sp *drepo.SpaceRepo, fd *drepo.FolderRepo, rc *drepo.RecycleRepo, acl *ACLService) *FolderSvc {
	return &FolderSvc{
		pool:       pool,
		spaces:     sp,
		folders:    fd,
		recycle:    rc,
		acl:        acl,
		recycleTTL: 30 * 24 * time.Hour,
	}
}

// WithFiles B2: 注入 FileRepo, 开启 recursive=true 时的子文件级联软删.
// 不调用 → recursive=true 时返 ErrInternal.drive.recursive_not_wired.
func (s *FolderSvc) WithFiles(fl *drepo.FileRepo) *FolderSvc {
	s.files = fl
	return s
}

// Create F06 Phase 2.2b: 在 space (或 parent folder) 下创建 regular folder.
// ACL: editor+ 必检 (parent_uuid 给了 → 在 parent folder 上; 否则在 space 上).
// 校验顺序: name 合法性 → space 存在 → (可选) parent 存在且同 space + 非 is_system → ACL editor+ → INSERT.
func (s *FolderSvc) Create(ctx context.Context, accountID, tenantID int64, spaceUUID, parentUUID, name string) (*dom.Folder, error) {
	name = strings.TrimSpace(name)
	if !validFolderName(name) {
		return nil, apperr.ErrInvalidParams.Withf("drive.folder_name_invalid")
	}
	if spaceUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("space_uuid required")
	}

	space, err := s.spaces.GetByUUID(ctx, spaceUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("space")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if space.TenantID != tenantID {
		// 跨租户 space 一律 404 隐藏存在性
		return nil, apperr.ErrNotFound.Withf("space")
	}

	var (
		parentID   *int64
		parentPath = "/"
	)
	if parentUUID != "" {
		parent, err := s.folders.GetByUUID(ctx, parentUUID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return nil, apperr.ErrNotFound.Withf("folder")
			}
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if parent.SpaceID != space.ID {
			return nil, apperr.ErrForbidden.Withf("drive.cross_space_move_not_allowed")
		}
		if parent.IsSystem {
			return nil, apperr.ErrForbidden.Withf("drive.system_folder_protected")
		}
		pid := parent.ID
		parentID = &pid
		parentPath = ensureTrailingSlash(parent.Path)
	}

	// ACL editor+ check: 有 parent 在 parent 上, 否则在 space 上
	var aclTarget dom.ACLTargetKind = dom.ACLTargetSpace
	var aclID int64 = space.ID
	if parentID != nil {
		aclTarget = dom.ACLTargetFolder
		aclID = *parentID
	}
	role, err := s.acl.CheckEffectiveRole(ctx, accountID, aclTarget, aclID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastEditor(role) {
		return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}

	newPath := parentPath + name + "/"
	created, err := s.folders.Create(ctx, dom.CreateFolderInput{
		SpaceID:   space.ID,
		ParentID:  parentID,
		Name:      name,
		Path:      newPath,
		Kind:      dom.FolderKindRegular,
		IsSystem:  false,
		CreatedBy: accountID,
	})
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return created, nil
}

// Rename F06 Phase 2.2b: 改 folder.name (path 自动重算 + 级联子 folder).
// ACL: editor+ 在 folder 自身.
// 系统目录拒绝; 同 parent 同名 409.
func (s *FolderSvc) Rename(ctx context.Context, accountID int64, folderUUID, newName string) (*dom.Folder, error) {
	newName = strings.TrimSpace(newName)
	if !validFolderName(newName) {
		return nil, apperr.ErrInvalidParams.Withf("drive.folder_name_invalid")
	}

	folder, err := s.folders.GetByUUID(ctx, folderUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("folder")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if folder.IsSystem {
		return nil, apperr.ErrForbidden.Withf("drive.system_folder_protected")
	}

	role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, folder.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastEditor(role) {
		return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}

	// 算 parentPath: 没 parent 时 root "/", 否则 parent.path 尾 /.
	parentPath := "/"
	if folder.ParentID != nil {
		parent, err := s.folders.GetByID(ctx, *folder.ParentID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		parentPath = ensureTrailingSlash(parent.Path)
	}
	newPath := parentPath + newName + "/"

	// no-op (同名同路径) → 直接返
	oldPath := ensureTrailingSlash(folder.Path)
	if newPath == oldPath && newName == folder.Name {
		return folder, nil
	}

	// I2 修复: 把 main UPDATE + 级联 UPDATE 包同一事务. 任一步失败回滚,
	// 避免 "main 行已改 path 但级联失败 → 子 folder.path 仍指 oldPath" 的断裂树.
	// I4 修复: 同一事务里 PG 用 uq_folder_sibling 兜底并发改名冲突, 输给方收 23505 → duplicate_name.
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FolderSvc.Rename.beginTx: %w", err))
	}
	defer func() { _ = tx.Rollback(ctx) }() // commit 后 Rollback 返 ErrTxClosed, ignore

	updated, err := s.folders.RenameTx(ctx, tx, folder.ID, newName, newPath, accountID)
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("folder")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 级联子 folder path 前缀: oldPath → newPath (newPath 已带尾 /).
	if oldPath != newPath {
		if err := s.folders.UpdateDescendantPathsTx(ctx, tx, folder.SpaceID, folder.ID, oldPath, newPath); err != nil {
			return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FolderSvc.Rename.cascade: %w", err))
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FolderSvc.Rename.commit: %w", err))
	}
	return updated, nil
}

// MoveSameSpace F06 Phase 2.2b: 把 folder 移到同 space 下另一 parent (newParentUUID="" = 移到 space 根).
// ACL: editor+ 在 folder 自身 AND editor+ 在 new parent (或 space 若空).
// 系统目录拒绝 (folder 自身 is_system → 403).
// 同 space 限制; 防环 (移到自身 / 后代).
func (s *FolderSvc) MoveSameSpace(ctx context.Context, accountID int64, folderUUID, newParentUUID string) (*dom.Folder, error) {
	folder, err := s.folders.GetByUUID(ctx, folderUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("folder")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if folder.IsSystem {
		return nil, apperr.ErrForbidden.Withf("drive.system_folder_protected")
	}

	// ACL on folder itself (editor+)
	role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, folder.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastEditor(role) {
		return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}

	var (
		newParentID *int64
		parentPath  = "/"
	)
	if newParentUUID != "" {
		// move under another folder
		newParent, err := s.folders.GetByUUID(ctx, newParentUUID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return nil, apperr.ErrNotFound.Withf("folder")
			}
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if newParent.SpaceID != folder.SpaceID {
			return nil, apperr.ErrForbidden.Withf("drive.cross_space_move_not_allowed")
		}
		// I3 修复: 拒绝把 regular folder 移到 system folder 下;
		// Create 已挡住 "在 system parent 下新建子", Move 也得对称封口,
		// 否则可以先建在普通父下再 Move 进 system 绕过保护.
		if newParent.IsSystem {
			return nil, apperr.ErrForbidden.Withf("drive.system_folder_protected")
		}
		// 防环: 不能移到自己, 也不能移到自己的后代
		if newParent.ID == folder.ID {
			return nil, apperr.ErrInvalidParams.Withf("drive.folder_cycle")
		}
		if strings.HasPrefix(ensureTrailingSlash(newParent.Path), ensureTrailingSlash(folder.Path)) {
			return nil, apperr.ErrInvalidParams.Withf("drive.folder_cycle")
		}
		// ACL on new parent (editor+)
		role2, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, newParent.ID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role2) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
		pid := newParent.ID
		newParentID = &pid
		parentPath = ensureTrailingSlash(newParent.Path)
	} else {
		// move to space root: ACL editor+ on space
		role2, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, folder.SpaceID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role2) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	}

	newPath := parentPath + folder.Name + "/"
	oldPath := ensureTrailingSlash(folder.Path)

	// no-op: 同 parent 同 path 无变化
	samePid := (newParentID == nil && folder.ParentID == nil) ||
		(newParentID != nil && folder.ParentID != nil && *newParentID == *folder.ParentID)
	if samePid && newPath == oldPath {
		return folder, nil
	}

	// I2 修复: 同事务包 main Move + 级联 path 更新, 详见 Rename 内同处注释.
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FolderSvc.MoveSameSpace.beginTx: %w", err))
	}
	defer func() { _ = tx.Rollback(ctx) }()

	updated, err := s.folders.MoveTx(ctx, tx, folder.ID, newParentID, newPath, accountID)
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("folder")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if oldPath != newPath {
		if err := s.folders.UpdateDescendantPathsTx(ctx, tx, folder.SpaceID, folder.ID, oldPath, newPath); err != nil {
			return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FolderSvc.MoveSameSpace.cascade: %w", err))
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FolderSvc.MoveSameSpace.commit: %w", err))
	}
	return updated, nil
}

// Delete F06 Phase 2.2b + 2.2e + B2: 软删 folder + 写回收行.
//   - recursive=false (老语义): 非空 → 409 drive.folder_not_empty
//   - recursive=true  (B2):    级联子树 — 列所有未软删 descendants (folders + files) 同 TX 软删, 写 N 条 recycle 行.
//
// ACL editor+ 在 root folder; 系统目录拒绝 (不论 recursive).
// quota / used_bytes **不**在 soft-delete 阶段释放; Purge (B5 reaper) 才释.
//
// 行为 (recursive=true, TX):
//  1. LockByIDTx root
//  2. ListLiveDescendantsTx(rootPath) → 子 folder list (含直接 + 间接, 不含 root)
//  3. ListLiveByFolderIDsTx({root.ID, ...descendant ids}) → 全部 file list
//  4. SoftDeleteByIDsTx({root.ID, ...descendants})
//  5. SoftDeleteByIDsTx(file ids)
//  6. recycle.CreateTx × (root + descendant folders + files) — folder rows bytes=0, file rows bytes=size
//  7. commit
//
// recycle 依赖未注入 (旧 caller) 时降级走非 TX SoftDelete (兼容性); recursive 走非 TX 时不写 recycle 行 (没意义).
func (s *FolderSvc) Delete(ctx context.Context, accountID int64, folderUUID string, recursive bool) error {
	folder, err := s.folders.GetByUUID(ctx, folderUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("folder")
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if folder.IsSystem {
		return apperr.ErrForbidden.Withf("drive.system_folder_protected")
	}

	role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, folder.ID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastEditor(role) {
		return apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}

	hasChildren, err := s.folders.HasLiveChildren(ctx, folder.ID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if hasChildren && !recursive {
		return apperr.ErrConflict.Withf("drive.folder_not_empty")
	}
	if recursive && s.files == nil {
		return apperr.ErrInternal.Withf("drive.recursive_not_wired")
	}

	// 拉 space 取 tenant_id (写回收行用); 旧 caller 兼容路径不需要.
	sp, err := s.spaces.GetByID(ctx, folder.SpaceID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if sp == nil {
		return apperr.ErrNotFound.Withf("space")
	}

	if s.recycle == nil {
		// 兼容性: 旧 caller 未注 recycle, 仅做 root SoftDelete; 递归子树不在此分支处理 (没意义没事务).
		if err := s.folders.SoftDelete(ctx, folder.ID, accountID); err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return apperr.ErrNotFound.Withf("folder")
			}
			return apperr.ErrInternal.Wrap(err)
		}
		return nil
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("drive.FolderSvc.Delete.beginTx: %w", err))
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	if _, err := s.folders.LockByIDTx(ctx, tx, folder.ID); err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("folder")
		}
		return apperr.ErrInternal.Wrap(err)
	}

	// 收集所有要软删的 folder ids + file objects (root + 子树).
	folderIDs := []int64{folder.ID}
	if recursive && hasChildren {
		desc, err := s.folders.ListLiveDescendantsTx(ctx, tx, folder.SpaceID, folder.ID, folder.Path)
		if err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		for _, d := range desc {
			folderIDs = append(folderIDs, d.ID)
		}
	}
	files, err := s.files.ListLiveByFolderIDsTx(ctx, tx, folderIDs)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}

	// 软删 folders + files.
	if err := s.folders.SoftDeleteByIDsTx(ctx, tx, folderIDs, accountID); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if len(files) > 0 {
		fileIDs := make([]int64, 0, len(files))
		for _, f := range files {
			fileIDs = append(fileIDs, f.ID)
		}
		if err := s.files.SoftDeleteByIDsTx(ctx, tx, fileIDs, accountID); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
	}

	// 写 recycle 行 — folder 行 bytes=0, file 行 bytes=size_bytes.
	expiresAt := time.Now().Add(s.recycleTTL)
	for _, fid := range folderIDs {
		if err := s.recycle.CreateTx(ctx, tx, dom.CreateRecycleInput{
			TenantID:       sp.TenantID,
			TargetKind:     dom.RecycleTargetFolder,
			TargetID:       fid,
			SpaceID:        folder.SpaceID,
			DeletedBy:      accountID,
			ExpiresAt:      expiresAt,
			BytesToReclaim: 0,
		}); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
	}
	for _, f := range files {
		if err := s.recycle.CreateTx(ctx, tx, dom.CreateRecycleInput{
			TenantID:       sp.TenantID,
			TargetKind:     dom.RecycleTargetFile,
			TargetID:       f.ID,
			SpaceID:        folder.SpaceID,
			DeletedBy:      accountID,
			ExpiresAt:      expiresAt,
			BytesToReclaim: f.SizeBytes,
		}); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("drive.FolderSvc.Delete.commit: %w", err))
	}
	committed = true
	return nil
}

// =====================================================
// local helpers
// =====================================================

// validFolderName F06 v0.3.x 与 legacy svcdrive 一致的命名校验 (跟 path 兼容).
// 拒绝空串 / 超长 / 含分隔符 / 含控制字符.
func validFolderName(name string) bool {
	if name == "" || len(name) > 128 {
		return false
	}
	for _, r := range name {
		if r == '/' || r == '\\' || r == 0 || r < 0x20 {
			return false
		}
	}
	return true
}

// ensureTrailingSlash 给 path 补尾 /; 已有则原样返.
func ensureTrailingSlash(p string) string {
	if !strings.HasSuffix(p, "/") {
		return p + "/"
	}
	return p
}

// roleAtLeastEditor editor+ 闸 (跟 drivev3_read.go 的 roleAtLeast 等价, 但 service 层独立避免 import 反向依赖).
func roleAtLeastEditor(role dom.ACLRole) bool {
	switch role {
	case dom.ACLRoleEditor, dom.ACLRoleManager:
		return true
	}
	return false
}
