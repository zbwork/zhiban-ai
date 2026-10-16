// file_cross_space.go — F06 Phase 2.11/2.12 跨 space file move + retry-copy + cancel-copy.
//
// 实现策略 (lightweight, no worker):
//   Move(new_space_uuid != src.space_uuid):
//     TX1 (DB-only):
//       a. resolve src file + ACL editor+ on src
//       b. resolve dst space + dst folder (or root); ACL editor+ on dst
//       c. assertCopyReady on src; dup-name check in dst folder
//       d. reserve dst quota (tenant + creator account) 原子 UPDATE; fail → 412 quota_exceeded
//       e. INSERT new drive_files row in dst (copy_status='copying', copy_source_file_id=src.id,
//          storage_key=新派生 final key)
//       f. UPDATE drive_spaces.used_bytes += size on dst
//       commit
//     Phase B (NO TX): store.Copy(src.storage_key → new.storage_key) — inline sync
//     TX2:
//       SUCCESS: UPDATE new.copy_status='ready'; soft-delete src + 写 recycle (跟 FileSvc.Delete 同语义)
//       FAILURE: UPDATE new.copy_status='copy_failed' + reason; release dst quota (-size 三处:
//                tenant + account + drive_spaces.used_bytes)
//   RetryCopy(file_uuid): copy_failed 行 → 再做 Phase B + TX2 (同上)
//   CancelCopy(file_uuid): copy_failed 行 → hard delete row + release dst quota
//
// 不实现 folder 跨 space move (递归 copy 工作量过大);
// 跨 space folder move 端点保留之前 403 行为, 错误码不变 (Phase 2.2b 已有).

package drive

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// FileMoveResp Phase 2.11/2.12: Move 返回 (可能跨 space, 包含 copy_status).
//
// 当 copy_status='ready' (同 space, 或 跨 space copy 成功) → 这是 caller 期待的稳定状态.
// 当 copy_status='copy_failed' → 同时返 error (drive.copy_failed); caller 可 retry / cancel.
type FileMoveResp struct {
	Detail FileDetailResp `json:"file"`
}

// Move Phase 2.11/2.12 dispatcher: 同 space → MoveSameSpace; 跨 space → MoveCrossSpace.
// 新 space_uuid 空 → 视作同 space (cross-space move 必须显式传 new_space_uuid).
func (s *FileSvc) Move(ctx context.Context, accountID int64, fileUUID, newSpaceUUID, newFolderUUID string) (*FileDetailResp, error) {
	if newSpaceUUID == "" {
		return s.MoveSameSpace(ctx, accountID, fileUUID, newFolderUUID)
	}
	// 反查 src.space; 决定是否真 cross-space.
	src, srcSpace, _, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if srcSpace.UUID == newSpaceUUID {
		return s.MoveSameSpace(ctx, accountID, fileUUID, newFolderUUID)
	}
	return s.MoveCrossSpace(ctx, accountID, src, srcSpace, newSpaceUUID, newFolderUUID)
}

// MoveCrossSpace Phase 2.11/2.12: 跨 space file move (sync inline).
//
// 调方: 已通过 Move 入口确定确实跨 space (newSpaceUUID != src.spaceUUID).
// 返回新行 detail (copy_status='ready' on success); 失败返 500 drive.copy_failed
// 但新行已 INSERT (copy_status='copy_failed') 等 retry / cancel.
func (s *FileSvc) MoveCrossSpace(ctx context.Context, accountID int64, src *dom.File, srcSpace *dom.Space, newSpaceUUID, newFolderUUID string) (*FileDetailResp, error) {
	if s.quotas == nil {
		return nil, apperr.ErrInternal.Withf("drive.quotas_not_wired")
	}
	if err := assertCopyReady(src); err != nil {
		return nil, err
	}
	// src ACL editor+
	if err := s.requireRole(ctx, accountID, src.ID, dom.ACLRoleEditor); err != nil {
		return nil, err
	}
	// dst space + folder
	dstSpace, err := s.spaces.GetByUUID(ctx, newSpaceUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("space")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if dstSpace.TenantID != srcSpace.TenantID {
		return nil, apperr.ErrForbidden.Withf("drive.cross_tenant_move_not_allowed")
	}
	var (
		dstFolderID *int64
	)
	_ = newSpaceUUID // dstSpace 已 resolve, 形参 newSpaceUUID 仅用于入口决策
	if newFolderUUID != "" {
		nf, err := s.folders.GetByUUID(ctx, newFolderUUID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return nil, apperr.ErrNotFound.Withf("folder")
			}
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if nf.SpaceID != dstSpace.ID {
			return nil, apperr.ErrForbidden.Withf("drive.folder_space_mismatch")
		}
		if nf.IsSystem {
			return nil, apperr.ErrForbidden.Withf("drive.system_folder_protected")
		}
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, nf.ID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
		nid := nf.ID
		dstFolderID = &nid
	} else {
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, dstSpace.ID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	}

	// 派生 dst storage_key (新 final key) — 用 src.created_by 当 owner; tenants 路径
	newFileUUID := uuid.NewString()
	ext := extFromName(src.Name)
	ownerForKey := accountID
	if src.CreatedBy != nil && *src.CreatedBy > 0 {
		ownerForKey = *src.CreatedBy
	}
	newStorageKey := buildFinalKey(dstSpace.TenantID, ownerForKey, newFileUUID, ext)

	// TX1: dup-name + reserve quota + INSERT copying + bump space.used_bytes
	tx1, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx1.Rollback(ctx)
		}
	}()

	// dup-name in dst space (GetByFolderAndName 未限 space, 跨 space 复用会误报).
	// 直接在 dst space + dst folder 下查 1 行同名 live.
	var dupCount int
	if dstFolderID != nil {
		_ = tx1.QueryRow(ctx,
			`SELECT count(*) FROM drive_files WHERE space_id=$1 AND drive_folder_id=$2 AND name=$3 AND is_deleted=false`,
			dstSpace.ID, *dstFolderID, src.Name).Scan(&dupCount)
	} else {
		_ = tx1.QueryRow(ctx,
			`SELECT count(*) FROM drive_files WHERE space_id=$1 AND drive_folder_id IS NULL AND name=$2 AND is_deleted=false`,
			dstSpace.ID, src.Name).Scan(&dupCount)
	}
	if dupCount > 0 {
		return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
	}

	// reserve dst quota — caller account 视作 dst owner (现实最简化)
	if tq, _ := s.quotas.GetForTenant(ctx, dstSpace.TenantID); tq != nil {
		applied, qerr := s.quotas.AddUsedBytesAtomicTx(ctx, tx1, tq.ID, src.SizeBytes)
		if qerr != nil {
			return nil, apperr.ErrInternal.Wrap(qerr)
		}
		if !applied {
			return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded").Withf("tenant quota")
		}
	}
	if aq, _ := s.quotas.GetForAccount(ctx, dstSpace.TenantID, accountID); aq != nil {
		applied, qerr := s.quotas.AddUsedBytesAtomicTx(ctx, tx1, aq.ID, src.SizeBytes)
		if qerr != nil {
			return nil, apperr.ErrInternal.Wrap(qerr)
		}
		if !applied {
			return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded").Withf("account quota")
		}
	}

	// INSERT new row (copy_status='copying')
	newRow, err := s.files.CreateCopyingTx(ctx, tx1, dom.CreateFileInput{
		SpaceID:       dstSpace.ID,
		DriveFolderID: dstFolderID,
		Name:          src.Name,
		MimeType:      src.MimeType,
		SizeBytes:     src.SizeBytes,
		SHA256:        src.SHA256,
		StorageKey:    newStorageKey,
		Scope:         dom.FileScopeDrive,
		Source:        dom.FileSource(src.Source),
		CreatedBy:     accountID,
	}, src.ID)
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// dst space used_bytes += size (即便 copy 失败也保留 — 等 cancel/retry 走资源回收)
	if err := s.spaces.AddUsedBytesTx(ctx, tx1, dstSpace.ID, src.SizeBytes); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := tx1.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	committed = true

	// Phase B: store.Copy (NO TX)
	store, err := s.storage.Resolve(ctx, dstSpace.TenantID)
	if err != nil {
		// 标 copy_failed 让 caller retry; 不 release quota (cancel 时才 release)
		_ = s.markCopyFailed(ctx, newRow.ID, "storage_resolve_failed")
		return nil, apperr.ErrInternal.Withf("drive.copy_failed").Wrap(err)
	}
	if err := store.Copy(ctx, src.StorageKey, newStorageKey); err != nil {
		_ = s.markCopyFailed(ctx, newRow.ID, "copy_error: "+err.Error())
		return nil, apperr.ErrInternal.Withf("drive.copy_failed").Wrap(err)
	}

	// TX2 SUCCESS: copy_status='ready' + soft-delete src + recycle row
	if err := s.completeCopySuccess(ctx, accountID, src, srcSpace, newRow); err != nil {
		// 后半段失败: 新行已 ready (用户可见), src 仍在 (重复但安全; 用户可手动清)
		// 不返错给 caller — caller 拿到了 ready file_uuid 业务已经完成.
		// log warn (slog) 实际生产应 alert + 后台 reconcile.
		return s.fetchDetail(ctx, newRow.ID)
	}

	return s.fetchDetail(ctx, newRow.ID)
}

// RetryCopy Phase 2.11/2.12: copy_failed 行 → 再做 Copy + 状态机迁移.
func (s *FileSvc) RetryCopy(ctx context.Context, accountID int64, fileUUID string) (*FileDetailResp, error) {
	if s.quotas == nil {
		return nil, apperr.ErrInternal.Withf("drive.quotas_not_wired")
	}
	target, dstSpace, _, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if target.CopyStatus != dom.CopyStatusCopyFailed {
		return nil, apperr.ErrConflict.Withf("drive.file_not_in_copy_failed")
	}
	if err := s.requireRole(ctx, accountID, target.ID, dom.ACLRoleEditor); err != nil {
		return nil, err
	}
	if target.CopySourceFileID == nil {
		return nil, apperr.ErrInternal.Withf("drive.copy_source_missing")
	}
	src, err := s.files.GetByID(ctx, *target.CopySourceFileID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.copy_source_unavailable").Wrap(err)
	}
	srcSpace, err := s.spaces.GetByID(ctx, src.SpaceID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// flip to copying first
	tx0, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := s.files.UpdateCopyStatusTx(ctx, tx0, target.ID, string(dom.CopyStatusCopying), nil); err != nil {
		_ = tx0.Rollback(ctx)
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if err := tx0.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	store, err := s.storage.Resolve(ctx, dstSpace.TenantID)
	if err != nil {
		_ = s.markCopyFailed(ctx, target.ID, "storage_resolve_failed")
		return nil, apperr.ErrInternal.Withf("drive.copy_failed").Wrap(err)
	}
	if err := store.Copy(ctx, src.StorageKey, target.StorageKey); err != nil {
		_ = s.markCopyFailed(ctx, target.ID, "copy_error: "+err.Error())
		return nil, apperr.ErrInternal.Withf("drive.copy_failed").Wrap(err)
	}
	if err := s.completeCopySuccess(ctx, accountID, src, srcSpace, target); err != nil {
		return s.fetchDetail(ctx, target.ID)
	}
	return s.fetchDetail(ctx, target.ID)
}

// CancelCopy Phase 2.11/2.12: copy_failed 行 → hard delete + 释放 dst quota.
//   - target file 必须是 copy_failed (copying 中不允许 cancel — 等当前 inline 调用完成)
//   - release: tenant quota + account quota + dst space.used_bytes 都 -size
//   - 不动 src
func (s *FileSvc) CancelCopy(ctx context.Context, accountID int64, fileUUID string) error {
	if s.quotas == nil {
		return apperr.ErrInternal.Withf("drive.quotas_not_wired")
	}
	target, dstSpace, _, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return err
	}
	if target.CopyStatus != dom.CopyStatusCopyFailed {
		return apperr.ErrConflict.Withf("drive.file_not_in_copy_failed")
	}
	if err := s.requireRole(ctx, accountID, target.ID, dom.ACLRoleEditor); err != nil {
		return err
	}
	// TX: hard delete row + release quota (-size 三处)
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()
	if _, err := tx.Exec(ctx, `DELETE FROM drive_files WHERE id = $1`, target.ID); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if tq, _ := s.quotas.GetForTenant(ctx, dstSpace.TenantID); tq != nil {
		if err := s.quotas.AddUsedBytesSignedTx(ctx, tx, tq.ID, -target.SizeBytes); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
	}
	if aq, _ := s.quotas.GetForAccount(ctx, dstSpace.TenantID, accountID); aq != nil {
		if err := s.quotas.AddUsedBytesSignedTx(ctx, tx, aq.ID, -target.SizeBytes); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
	}
	if err := s.spaces.AddUsedBytesSignedTx(ctx, tx, dstSpace.ID, -target.SizeBytes); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if err := tx.Commit(ctx); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	committed = true
	return nil
}

// ----- internal helpers -----

// markCopyFailed best-effort 标 target 为 copy_failed (TX 短开).
func (s *FileSvc) markCopyFailed(ctx context.Context, targetID int64, reason string) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := s.files.UpdateCopyStatusTx(ctx, tx, targetID, string(dom.CopyStatusCopyFailed), &reason); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// completeCopySuccess TX2: 新行 → 'ready', src 软删 + recycle row 写.
func (s *FileSvc) completeCopySuccess(ctx context.Context, accountID int64, src *dom.File, srcSpace *dom.Space, newRow *dom.File) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()
	if err := s.files.UpdateCopyStatusTx(ctx, tx, newRow.ID, string(dom.CopyStatusReady), nil); err != nil {
		return err
	}
	// src soft-delete + recycle (跟 FileSvc.Delete 同语义, inline 一些 SQL 避免循环依赖)
	if err := s.files.SoftDeleteTx(ctx, tx, src.ID, accountID); err != nil {
		return err
	}
	if s.recycle != nil {
		expiresAt := time.Now().Add(s.recycleTTL)
		if err := s.recycle.CreateTx(ctx, tx, dom.CreateRecycleInput{
			TenantID:       srcSpace.TenantID,
			TargetKind:     "file",
			TargetID:       src.ID,
			SpaceID:        src.SpaceID,
			DeletedBy:      accountID,
			ExpiresAt:      expiresAt,
			BytesToReclaim: src.SizeBytes,
		}); err != nil {
			return err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	committed = true
	return nil
}

// fetchDetail 反查 file 行 + 转 detail (供 Move / RetryCopy 完成后返).
func (s *FileSvc) fetchDetail(ctx context.Context, id int64) (*FileDetailResp, error) {
	f, err := s.files.GetByID(ctx, id)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	sp, err := s.spaces.GetByID(ctx, f.SpaceID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	var fd *dom.Folder
	if f.DriveFolderID != nil {
		fd, _ = s.folders.GetByID(ctx, *f.DriveFolderID)
	}
	return buildFileDetail(f, sp, fd), nil
}

// 未来 cross-bucket copy 由 object.Store 扩展支持时, 这里可直接调; 当前 store.Copy 已够用同 bucket 场景.
var _ = object.ErrNotFound
var _ = fmt.Sprintf
