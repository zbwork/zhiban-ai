// file.go — F06 Phase 2.2d FileSvc: file detail / preview / rename / move-same-space / delete.
//
// ACL 语义 (本 slice 5 个端点):
//
//	GET   /drive/files/{uuid}            viewer+
//	GET   /drive/files/{uuid}/preview    viewer+
//	PATCH /drive/files/{uuid}            editor+
//	POST  /drive/files/{uuid}/move       editor+
//	DELETE /drive/files/{uuid}           editor+
//
// copy_status state-machine guard (F06 §4.9):
//
//	read 端点 (GET / preview) 对任何 copy_status 都开放, 调用方可能就是想看 copy_failed 的文件
//	去 retry / cancel; mutate 端点 (rename / move / delete) 必须在 copy_status='ready' 才能动,
//	否则 → 409 drive.file_in_copy.
//
// 同名冲突:
//
//	uq_dfile_folder_name 唯一索引 (drive_folder_id, name) WHERE is_deleted=false → 23505 →
//	ErrDuplicateName → 409 drive.duplicate_name. rename 直接 UPDATE 触发; move 同样.
//
// 同 space 限制 (本 slice):
//
//	move 仅支持同 space 流转; 跨 space 的 server-side copy 在 Phase 2.11/2.12 接入 (依赖 copy_status
//	lifecycle). 新 folder_uuid 留空 → 移到 space 根 (drive_folder_id=NULL).
//
// 软删行为 (本 slice):
//
//	仅 UPDATE drive_files SET is_deleted=true, deleted_at=now() 一行; drive_recycle_bin 写入 +
//	quota 释放在 Phase 2.2e 接入.
package drive

import (
	"context"
	"errors"
	"fmt"
	"path"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// FileSvc Phase 2.2d: 5 个 file 端点的服务层. Phase 2.11/2.12 起加跨 space move.
type FileSvc struct {
	pool       *pgxpool.Pool
	spaces     *drepo.SpaceRepo
	folders    *drepo.FolderRepo
	files      *drepo.FileRepo
	recycle    *drepo.RecycleRepo     // Phase 2.2e: Delete 时写回收行
	quotas     *drepo.QuotaRepo       // Phase 2.11/2.12: 跨 space move reserve/release dst quota
	versions   *drepo.FileVersionRepo // B1: nil 时 ListVersions/RestoreVersion 返 404; 非 nil 时启用
	acl        *ACLService
	storage    StorageGetter
	previewTTL time.Duration // 默认 10 分钟 (F06 §3.2)
	recycleTTL time.Duration // 默认 30 天 (F06 §4.7)
}

// NewFileSvc 构造.
//
// recycle 可为 nil (旧调用方未传); nil 时 Delete 走"仅软删"分支 (兼容性).
// Phase 2.Z 全切后改为必传.
func NewFileSvc(
	pool *pgxpool.Pool,
	sp *drepo.SpaceRepo,
	fd *drepo.FolderRepo,
	fl *drepo.FileRepo,
	rc *drepo.RecycleRepo,
	acl *ACLService,
	storage StorageGetter,
) *FileSvc {
	return &FileSvc{
		pool:       pool,
		spaces:     sp,
		folders:    fd,
		files:      fl,
		recycle:    rc,
		acl:        acl,
		storage:    storage,
		previewTTL: 10 * time.Minute,
		recycleTTL: 30 * 24 * time.Hour,
	}
}

// WithQuotas Phase 2.11/2.12: 注入 quota repo (跨 space move reserve/release).
// 旧 NewFileSvc 调用方 (FileSvc 仅做同 space move) 不传也能跑;
// 跨 space move 端点需调方先调本 setter.
func (s *FileSvc) WithQuotas(q *drepo.QuotaRepo) *FileSvc {
	s.quotas = q
	return s
}

// WithVersions B1 (file versioning): 注入 FileVersionRepo, 开启 ListVersions / RestoreVersion 两个端点.
// 不调用此 setter 的旧 caller 行为不变 (端点返 404 drive.versions_not_wired).
func (s *FileSvc) WithVersions(v *drepo.FileVersionRepo) *FileSvc {
	s.versions = v
	return s
}

// FileDetailResp F06 §3.2 GET /drive/files/{uuid} 响应.
type FileDetailResp struct {
	UUID       string    `json:"uuid"`
	SpaceUUID  string    `json:"space_uuid"`
	FolderUUID string    `json:"folder_uuid,omitempty"`
	Name       string    `json:"name"`
	MimeType   string    `json:"mime_type"`
	SizeBytes  int64     `json:"size_bytes"`
	SHA256     string    `json:"sha256,omitempty"`
	StorageKey string    `json:"storage_key"`
	CopyStatus string    `json:"copy_status"`
	CreatedAt  time.Time `json:"created_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}

// PreviewResp F06 §3.2 GET /drive/files/{uuid}/preview 响应.
type PreviewResp struct {
	URL         string    `json:"url"`
	ExpiresAt   time.Time `json:"expires_at"`
	PreviewKind string    `json:"preview_kind"`
}

// DownloadResp F06 Phase 2.2f GET /drive/files/{uuid}/download 响应.
//
// 与 PreviewResp 区分: download 强制 attachment Content-Disposition (URL 内已带 filename),
// 不返 preview_kind (download 不需要前端按类型挑预览组件); 返 name 方便前端展示.
type DownloadResp struct {
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expires_at"`
	Name      string    `json:"name"`
}

// =====================================================
// Get (viewer+; copy_status: any)
// =====================================================

// Get GET /drive/files/{uuid}: 取详情 (含 copy_status). ACL viewer+.
// 任何 copy_status 都允许 (caller 可能就是想看 copy_failed 的文件状态).
func (s *FileSvc) Get(ctx context.Context, accountID int64, fileUUID string) (*FileDetailResp, error) {
	file, sp, fd, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleViewer); err != nil {
		return nil, err
	}
	return buildFileDetail(file, sp, fd), nil
}

// GetForTenant 是跨 service 读取文件轻量元数据的入口。与 Get 相比显式校验 tenant，
// 用于收藏等用户级聚合，避免只凭全局 account id / file uuid 读取跨租户元数据。
func (s *FileSvc) GetForTenant(
	ctx context.Context,
	accountID, tenantID int64,
	fileUUID string,
) (*FileDetailResp, error) {
	file, sp, fd, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if sp.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("file")
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleViewer); err != nil {
		return nil, err
	}
	return buildFileDetail(file, sp, fd), nil
}

// =====================================================
// Preview (viewer+; copy_status: any)
// =====================================================

// Preview GET /drive/files/{uuid}/preview: 签 GET URL 给前端 inline 预览.
// ACL viewer+; storage.Resolve(tenantID) → store.PresignGet(Inline=true, FileName=file.Name).
func (s *FileSvc) Preview(ctx context.Context, accountID, tenantID int64, fileUUID string, checksums ...string) (*PreviewResp, error) {
	file, sp, _, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	// space 必须与 caller 同 tenant (与 Bootstrap/folder 端点一致的 tenant 隔离).
	if sp.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("file")
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleViewer); err != nil {
		return nil, err
	}

	if len(checksums) > 0 && checksums[0] != "" {
		checksum := checksums[0]
		if len(checksum) != 64 || strings.Trim(checksum, "0123456789abcdef") != "" {
			return nil, apperr.ErrInvalidParams
		}
		if file.SHA256 == nil || *file.SHA256 != checksum {
			if s.versions == nil {
				return nil, apperr.ErrNotFound.Withf("file version")
			}
			key, err := s.versions.StorageKeyByChecksum(ctx, file.ID, checksum)
			if err != nil {
				return nil, apperr.ErrNotFound.Withf("file version")
			}
			file.StorageKey = key
		}
	}

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("storage resolve: %w", err))
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{
		Key:      file.StorageKey,
		TTL:      s.previewTTL,
		Inline:   true,
		FileName: file.Name,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("presign get: %w", err))
	}
	return &PreviewResp{
		URL:         out.URL,
		ExpiresAt:   out.ExpiresAt,
		PreviewKind: derivePreviewKind(file.MimeType, file.Name),
	}, nil
}

// =====================================================
// Download (viewer+; copy_status=ready)
// =====================================================

// Download GET /drive/files/{uuid}/download (Phase 2.2f 由 drivev3 接管, legacy svcdrive.Download 退场).
//
// 客户端拿 DownloadResp.URL 后再发 GET 拉字节 (URL 已是 presigned, 直接走对象存储, 不再过 bus).
// Response shape 与 Preview 类似但不含 preview_kind, 且 Content-Disposition=attachment.
//
// 与 Preview 的差异:
//   - Inline=false → store 端 ResponseContentDisposition=attachment
//   - 强制 copy_status='ready' (download 是终端流量场景, 拒绝 copying 中的部分文件; Preview 仍开放
//     copy_failed 等状态便于 caller retry/cancel)
//   - 返 DownloadResp{url, expires_at, name} (无 preview_kind 字段)
//
// ACL viewer+; 跨 tenant → 404; copy_status 非 ready → 409 drive.file_in_copy.
//
// 检查顺序: ACL 先于 copy_status. 反之会泄露 copy_status 给无权 caller — 同一无权 caller 撞到
// 'ready' 文件得 403, 撞到 'copying' 文件得 409, 响应可区分即可被枚举.
// 与 Rename/MoveSameSpace/Delete 保持一致的 ACL-first 顺序.
func (s *FileSvc) Download(ctx context.Context, accountID, tenantID int64, fileUUID string) (*DownloadResp, error) {
	file, sp, _, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if sp.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("file")
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleViewer); err != nil {
		return nil, err
	}
	if err := assertCopyReady(file); err != nil {
		return nil, err
	}

	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("storage resolve: %w", err))
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{
		Key:      file.StorageKey,
		TTL:      s.previewTTL,
		Inline:   false,
		FileName: file.Name,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("presign get: %w", err))
	}
	return &DownloadResp{
		URL:       out.URL,
		ExpiresAt: out.ExpiresAt,
		Name:      file.Name,
	}, nil
}

// =====================================================
// Rename (editor+; copy_status=ready)
// =====================================================

// Rename PATCH /drive/files/{uuid}: 改 name + 审计字段; 同 folder 同名冲突 → 409.
// ACL editor+; copy_status='ready' guard.
func (s *FileSvc) Rename(ctx context.Context, accountID int64, fileUUID, newName string) (*FileDetailResp, error) {
	newName = strings.TrimSpace(newName)
	if !validFileName(newName) {
		return nil, apperr.ErrInvalidParams.Withf("drive.invalid_name")
	}

	file, sp, fd, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if err := assertCopyReady(file); err != nil {
		return nil, err
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleEditor); err != nil {
		return nil, err
	}

	// no-op (同名) → 直接返
	if newName == file.Name {
		return buildFileDetail(file, sp, fd), nil
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FileSvc.Rename.beginTx: %w", err))
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	updated, err := s.files.RenameTx(ctx, tx, file.ID, newName, accountID)
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("file")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FileSvc.Rename.commit: %w", err))
	}
	committed = true

	return buildFileDetail(updated, sp, fd), nil
}

// =====================================================
// MoveSameSpace (editor+; copy_status=ready)
// =====================================================

// MoveSameSpace POST /drive/files/{uuid}/move: 同 space 内换 folder.
// new_folder_uuid="" → 移到 space 根 (drive_folder_id=NULL); 跨 space 拒 (Phase 2.11/2.12).
// ACL: editor+ 在 file 自身 + editor+ 在新 parent (或 space 若移到根); copy_status='ready' guard.
func (s *FileSvc) MoveSameSpace(ctx context.Context, accountID int64, fileUUID, newFolderUUID string) (*FileDetailResp, error) {
	file, sp, _, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if err := assertCopyReady(file); err != nil {
		return nil, err
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleEditor); err != nil {
		return nil, err
	}

	var (
		newFolderID *int64
		newFolder   *dom.Folder
	)
	if newFolderUUID != "" {
		nf, err := s.folders.GetByUUID(ctx, newFolderUUID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return nil, apperr.ErrNotFound.Withf("folder")
			}
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if nf.SpaceID != file.SpaceID {
			return nil, apperr.ErrForbidden.Withf("drive.cross_space_move_not_allowed")
		}
		if nf.IsSystem {
			return nil, apperr.ErrForbidden.Withf("drive.system_folder_protected")
		}
		// ACL editor+ on new folder
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFolder, nf.ID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
		nid := nf.ID
		newFolderID = &nid
		newFolder = nf
	} else {
		// move to space root: ACL editor+ on space
		role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, file.SpaceID)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if !roleAtLeastEditor(role) {
			return nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
		}
	}

	// no-op: 目标 folder 与当前相同 (含都 NULL).
	samePid := (newFolderID == nil && file.DriveFolderID == nil) ||
		(newFolderID != nil && file.DriveFolderID != nil && *newFolderID == *file.DriveFolderID)
	if samePid {
		return buildFileDetail(file, sp, newFolder), nil
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FileSvc.MoveSameSpace.beginTx: %w", err))
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	updated, err := s.files.MoveTx(ctx, tx, file.ID, newFolderID, accountID)
	if err != nil {
		if errors.Is(err, drepo.ErrDuplicateName) {
			return nil, apperr.ErrConflict.Withf("drive.duplicate_name")
		}
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("file")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.FileSvc.MoveSameSpace.commit: %w", err))
	}
	committed = true

	return buildFileDetail(updated, sp, newFolder), nil
}

// =====================================================
// Delete (editor+; copy_status=ready)
// =====================================================

// Delete DELETE /drive/files/{uuid}: 软删 + 写回收站 (Phase 2.2e 接入).
// ACL editor+; copy_status='ready' guard.
//
// 行为 (TX):
//  1. SoftDeleteTx drive_files (is_deleted=true, deleted_at=now)
//  2. CreateTx drive_recycle_bin (target_kind=file, bytes_to_reclaim=file.size_bytes, expires_at=now+30天)
//     配额释放 + 物理删 staging 都在 Recycle.Purge 路径; Delete 仅暂存待 30 天清理.
//
// recycle 依赖未注入 (旧 caller) 时降级走非 TX SoftDelete (兼容性; 不应在生产路径出现).
func (s *FileSvc) Delete(ctx context.Context, accountID int64, fileUUID string) error {
	file, sp, _, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return err
	}
	if err := assertCopyReady(file); err != nil {
		return err
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleEditor); err != nil {
		return err
	}

	// 兼容性兜底: recycle repo 未注入 → 退回老路径 (仅软删, 不写回收行).
	if s.recycle == nil {
		if err := s.files.SoftDelete(ctx, file.ID, accountID); err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				return apperr.ErrNotFound.Withf("file")
			}
			return apperr.ErrInternal.Wrap(err)
		}
		return nil
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("drive.FileSvc.Delete.beginTx: %w", err))
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	// SELECT FOR UPDATE: 防御并发 Delete 同一 file (第二个 caller 拿到锁后 SoftDeleteTx 已=0行 → ErrNotFound).
	if _, err := s.files.LockByIDTx(ctx, tx, file.ID); err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("file")
		}
		return apperr.ErrInternal.Wrap(err)
	}

	if err := s.files.SoftDeleteTx(ctx, tx, file.ID, accountID); err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("file")
		}
		return apperr.ErrInternal.Wrap(err)
	}

	if err := s.recycle.CreateTx(ctx, tx, dom.CreateRecycleInput{
		TenantID:       sp.TenantID,
		TargetKind:     dom.RecycleTargetFile,
		TargetID:       file.ID,
		SpaceID:        file.SpaceID,
		DeletedBy:      accountID,
		ExpiresAt:      time.Now().Add(s.recycleTTL),
		BytesToReclaim: file.SizeBytes,
	}); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("drive.FileSvc.Delete.commit: %w", err))
	}
	committed = true
	return nil
}

// =====================================================
// local helpers
// =====================================================

// resolveFile 反查 file + 关联 space + (可选) folder. file 不存在 → 404 drive file.
func (s *FileSvc) resolveFile(ctx context.Context, fileUUID string) (*dom.File, *dom.Space, *dom.Folder, error) {
	if fileUUID == "" {
		return nil, nil, nil, apperr.ErrInvalidParams.Withf("file_uuid required")
	}
	file, err := s.files.GetByUUID(ctx, fileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, nil, nil, apperr.ErrNotFound.Withf("file")
		}
		return nil, nil, nil, apperr.ErrInternal.Wrap(err)
	}
	sp, err := s.spaces.GetByID(ctx, file.SpaceID)
	if err != nil {
		return nil, nil, nil, apperr.ErrInternal.Wrap(err)
	}
	if sp == nil {
		return nil, nil, nil, apperr.ErrNotFound.Withf("space")
	}
	var fd *dom.Folder
	if file.DriveFolderID != nil {
		fd, err = s.folders.GetByID(ctx, *file.DriveFolderID)
		if err != nil {
			// folder 被软删但 file 还在 → 视为根 (FolderUUID 留空, 不阻塞 read);
			// 实际生产中 folder 软删会级联软删子 file (Phase 2.2e 接入).
			if !errors.Is(err, drepo.ErrNotFound) {
				return nil, nil, nil, apperr.ErrInternal.Wrap(err)
			}
			fd = nil
		}
	}
	return file, sp, fd, nil
}

// requireRole ACL gate: 取 file 上的 effective role, 不满足 want → 403 drive.acl.forbidden.
func (s *FileSvc) requireRole(ctx context.Context, accountID, fileID int64, want dom.ACLRole) error {
	role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFile, fileID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastFile(role, want) {
		return apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}
	return nil
}

// roleAtLeastFile 与 drivev3_read.go::roleAtLeast 等价的 file-scope helper (避免反向 import).
func roleAtLeastFile(have, want dom.ACLRole) bool {
	rank := map[dom.ACLRole]int{"": 0, dom.ACLRoleViewer: 1, dom.ACLRoleEditor: 2, dom.ACLRoleManager: 3}
	return rank[have] >= rank[want]
}

// assertCopyReady mutate 路径 (rename/move/delete) 的 copy_status guard:
// 非 ready (e.g. 'copying' 跨 space copy 进行中) → 409 drive.file_in_copy.
func assertCopyReady(f *dom.File) error {
	if f.CopyStatus != dom.CopyStatusReady {
		return apperr.ErrConflict.Withf("drive.file_in_copy")
	}
	return nil
}

// validFileName F06 v0.3.x 文件名校验:
// - 不能空 / 仅空白
// - 长度 ≤ 255 (drive_files.name VARCHAR(255))
// - 不能含路径分隔符 / 控制字符 (与 folder 同, 但文件允许 `.`).
//
// 注意: rename 不再走 Sanitize (上传时已 Sanitize 过, 用户编辑应保留扩展名等);
// 仅做"不破坏存储路径假设"的最小校验.
func validFileName(name string) bool {
	if name == "" || len(name) > 255 {
		return false
	}
	for _, r := range name {
		if r == '/' || r == '\\' || r == 0 || r < 0x20 {
			return false
		}
	}
	return true
}

// derivePreviewKind F06 §3.2 文件预览类型派生; 镜像 legacy svcdrive 的实现.
// 优先看 mime_type; 兜底看扩展名; 都识别不出 → "binary".
func derivePreviewKind(mime, fileName string) string {
	m := strings.ToLower(mime)
	switch {
	case strings.HasPrefix(m, "image/"):
		return "image"
	case strings.HasPrefix(m, "audio/"):
		return "audio"
	case strings.HasPrefix(m, "video/"):
		return "video"
	case m == "application/pdf":
		return "pdf"
	case m == "text/markdown":
		return "markdown"
	case strings.HasPrefix(m, "text/"):
		return "text"
	}
	ext := strings.ToLower(path.Ext(fileName))
	switch ext {
	case ".md", ".markdown":
		return "markdown"
	case ".txt", ".log", ".csv":
		return "text"
	case ".pdf":
		return "pdf"
	}
	return "binary"
}

// =====================================================
// B1 ListVersions / RestoreVersion
// =====================================================

// VersionResp F06 §2.7 + B1: GET /drive/files/{uuid}/versions 单条响应.
type VersionResp struct {
	VersionNo    int       `json:"version_no"`
	StorageKey   string    `json:"storage_key"`
	SizeBytes    int64     `json:"size_bytes"`
	SHA256       string    `json:"sha256,omitempty"`
	Name         string    `json:"name"`
	UploadSource string    `json:"upload_source"`
	SupersededAt time.Time `json:"superseded_at"`
	CreatedAt    time.Time `json:"created_at"`
}

// ListVersions B1: GET /drive/files/{uuid}/versions — 列某 file 历史版本 (DESC).
// ACL viewer+; 返回不含当前 drive_files 行 (只有历史). 当前内容仍在 GET /drive/files/{uuid}.
// versions repo 未注入 → 503-equivalent ErrInternal.drive.versions_not_wired.
func (s *FileSvc) ListVersions(ctx context.Context, accountID int64, fileUUID string) ([]VersionResp, error) {
	if s.versions == nil {
		return nil, apperr.ErrInternal.Withf("drive.versions_not_wired")
	}
	file, _, _, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleViewer); err != nil {
		return nil, err
	}
	rows, err := s.versions.ListByFileID(ctx, file.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	out := make([]VersionResp, 0, len(rows))
	for _, v := range rows {
		r := VersionResp{
			VersionNo:    v.VersionNo,
			StorageKey:   v.StorageKey,
			SizeBytes:    v.SizeBytes,
			Name:         v.Name,
			UploadSource: string(v.UploadSource),
			SupersededAt: v.SupersededAt,
			CreatedAt:    v.CreatedAt,
		}
		if v.SHA256 != nil {
			r.SHA256 = *v.SHA256
		}
		out = append(out, r)
	}
	return out, nil
}

// RestoreVersion B1: POST /drive/files/{uuid}/versions/{version_no}/restore — 把历史版本提升为当前.
// ACL editor+; copy_status='ready' guard.
//
// TX 流程 (与 UploadSvc.runConfirmVersioning 对称, 但无 S3 Copy — 历史版本的 storage_key 仍在 S3):
//  1. LockByIDTx(file.ID) + 重检 ready
//  2. 取 picked = versions.GetByFileAndVersionTx(file.ID, versionNo)
//  3. quota delta = picked.SizeBytes - locked.SizeBytes; 正/负/0 分支与 versioning 一致
//  4. space.AddUsedBytesSignedTx(+delta)
//  5. InsertSnapshotTx(locked 当前内容) → 历史版本行 (version_no = MAX+1)
//  6. UpdateContentTx(file.ID, picked.StorageKey + picked.SizeBytes + 当前 mime + picked.SHA256)
//     说明: mime 不在 drive_file_versions 里, restore 后保持当前 mime (历史 mime 可由 caller 后续 PATCH 调整)
//  7. TX commit
//
// 失败任一步 rollback; 不动任何 S3 对象 (历史 key 还活, 当前 key 暂保留, 由 B5 reaper 清).
func (s *FileSvc) RestoreVersion(ctx context.Context, accountID int64, fileUUID string, versionNo int) (*FileDetailResp, error) {
	if s.versions == nil {
		return nil, apperr.ErrInternal.Withf("drive.versions_not_wired")
	}
	if versionNo <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("version_no must be > 0")
	}
	file, sp, fd, err := s.resolveFile(ctx, fileUUID)
	if err != nil {
		return nil, err
	}
	if err := assertCopyReady(file); err != nil {
		return nil, err
	}
	if err := s.requireRole(ctx, accountID, file.ID, dom.ACLRoleEditor); err != nil {
		return nil, err
	}

	// quota lookup pre-TX (TX 内只做 atomic / signed update).
	tenantQuotaID, accountQuotaID, err := s.lookupQuotaIDs(ctx, sp.TenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("begin tx: %w", err))
	}
	defer tx.Rollback(ctx) // safe: commit 后 rollback no-op

	locked, err := s.files.LockByIDTx(ctx, tx, file.ID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("file")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if locked.IsDeleted || locked.CopyStatus != dom.CopyStatusReady {
		return nil, apperr.ErrConflict.Withf("drive.file_state_changed")
	}

	picked, err := s.versions.GetByFileAndVersionTx(ctx, tx, locked.ID, versionNo)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("version")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	delta := picked.SizeBytes - locked.SizeBytes
	if delta > 0 {
		if tenantQuotaID != 0 {
			ok, qErr := s.quotas.AddUsedBytesAtomicTx(ctx, tx, tenantQuotaID, delta)
			if qErr != nil {
				return nil, apperr.ErrInternal.Wrap(qErr)
			}
			if !ok {
				return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded")
			}
		}
		if accountQuotaID != 0 {
			ok, qErr := s.quotas.AddUsedBytesAtomicTx(ctx, tx, accountQuotaID, delta)
			if qErr != nil {
				return nil, apperr.ErrInternal.Wrap(qErr)
			}
			if !ok {
				return nil, apperr.New(apperr.PreconditionFailed, "drive.quota_exceeded")
			}
		}
	} else if delta < 0 {
		if tenantQuotaID != 0 {
			if qErr := s.quotas.AddUsedBytesSignedTx(ctx, tx, tenantQuotaID, delta); qErr != nil {
				return nil, apperr.ErrInternal.Wrap(qErr)
			}
		}
		if accountQuotaID != 0 {
			if qErr := s.quotas.AddUsedBytesSignedTx(ctx, tx, accountQuotaID, delta); qErr != nil {
				return nil, apperr.ErrInternal.Wrap(qErr)
			}
		}
	}
	if delta != 0 {
		if err := s.spaces.AddUsedBytesSignedTx(ctx, tx, sp.ID, delta); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
	}

	// snapshot 当前内容入历史版本
	if _, err := s.versions.InsertSnapshotTx(ctx, tx, drepo.InsertSnapshotInput{
		FileID:       locked.ID,
		StorageKey:   locked.StorageKey,
		SizeBytes:    locked.SizeBytes,
		SHA256:       locked.SHA256,
		Name:         locked.Name,
		UploadSource: locked.Source,
		CreatedBy:    accountID,
	}); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	updated, err := s.files.UpdateContentTx(ctx, tx, locked.ID, drepo.UpdateContentInput{
		StorageKey: picked.StorageKey,
		SizeBytes:  picked.SizeBytes,
		MimeType:   locked.MimeType, // 历史版本不带 mime; 保留当前
		SHA256:     picked.SHA256,
		UpdatedBy:  accountID,
	})
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("commit: %w", err))
	}

	return buildFileDetail(updated, sp, fd), nil
}

// lookupQuotaIDs B1: 抄 UploadSvc.lookupQuotaIDs 同样模式 (TenantQuota, AccountQuota).
// best-effort: 不存在 = 无配额 (id=0).
func (s *FileSvc) lookupQuotaIDs(ctx context.Context, tenantID, accountID int64) (int64, int64, error) {
	if s.quotas == nil {
		return 0, 0, nil
	}
	var tenantQuotaID, accountQuotaID int64
	if q, e := s.quotas.GetForTenant(ctx, tenantID); e == nil && q != nil {
		tenantQuotaID = q.ID
	} else if e != nil && !errors.Is(e, drepo.ErrNotFound) {
		return 0, 0, e
	}
	if q, e := s.quotas.GetForAccount(ctx, tenantID, accountID); e == nil && q != nil {
		accountQuotaID = q.ID
	} else if e != nil && !errors.Is(e, drepo.ErrNotFound) {
		return 0, 0, e
	}
	return tenantQuotaID, accountQuotaID, nil
}

// buildFileDetail F06 §3.2 把 (file, space, folder) 拼装成响应 DTO.
// folder 可空 (file 在 space 根 / KB-only / 测试场景).
func buildFileDetail(file *dom.File, sp *dom.Space, fd *dom.Folder) *FileDetailResp {
	out := &FileDetailResp{
		UUID:       file.UUID,
		SpaceUUID:  sp.UUID,
		Name:       file.Name,
		MimeType:   file.MimeType,
		SizeBytes:  file.SizeBytes,
		StorageKey: file.StorageKey,
		CopyStatus: string(file.CopyStatus),
		CreatedAt:  file.CreatedAt,
		UpdatedAt:  file.UpdatedAt,
	}
	if file.SHA256 != nil {
		out.SHA256 = *file.SHA256
	}
	if fd != nil {
		out.FolderUUID = fd.UUID
	}
	return out
}
