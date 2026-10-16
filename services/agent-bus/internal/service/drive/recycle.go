// recycle.go — F06 Phase 2.2e: recycle list / restore / purge 端点的服务层 (RecycleSvc).
//
// 3 个 service 入口对应 3 个客户端 endpoint:
//
//	List    → GET    /drive/recycle                            ACL manager+ on space
//	Restore → POST   /drive/recycle/{uuid}/restore              ACL manager+ on space; 配额不变
//	Purge   → DELETE /drive/recycle/{uuid}/purge                ACL manager+; 释放配额 + store.Delete
//
// 设计要点 (F06 §3.2 + §4.7):
//   - List 只返 caller manager+ 的 space 内 (= owner + grant 显式 manager); department/tenant default
//     不到 manager → 这些 space 上 deleted 文件由 owner 来管.
//   - Restore: TX 内反向 SoftDelete + 把 recycle 行 tombstone (is_deleted=true); 不动配额 (原 size 仍计).
//   - Purge: TX 内物理删 file/folder + 物理删 recycle 行 + 释放 tenant/account quota + 释放 space.used_bytes,
//     提交后 best-effort store.Delete(storage_key).
//   - 同名重传冲突 (Restore 时 folder 已有同名 file) → 409 drive.duplicate_name.
package drive

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// RecycleItem F06 Phase 2.2e: 回收站列表行.
// name 由 service 层 JOIN 反查 (target_kind=file → drive_files.name; folder → drive_folders.name);
// 反查失败 (并发 hard-purge) 行 name 留空.
type RecycleItem struct {
	UUID               string    `json:"uuid"`
	TargetKind         string    `json:"target_kind"`
	TargetUUID         string    `json:"target_uuid,omitempty"`
	SpaceUUID          string    `json:"space_uuid"`
	Name               string    `json:"name"`
	LocationPath       string    `json:"location_path,omitempty"`
	MimeType           string    `json:"mime_type,omitempty"`
	PreviewURL         string    `json:"preview_url,omitempty"`
	DeletedByUUID      string    `json:"deleted_by_account_uuid,omitempty"`
	DeletedByName      string    `json:"deleted_by_display_name,omitempty"`
	DeletedByAvatarURL string    `json:"deleted_by_avatar_url,omitempty"`
	DeletedAtLogical   time.Time `json:"deleted_at_logical"`
	ExpiresAt          time.Time `json:"expires_at"`
	BytesToReclaim     int64     `json:"bytes_to_reclaim"`
}

// RecycleListResp F06 Phase 2.2e: GET /drive/recycle 响应.
type RecycleListResp struct {
	Items []RecycleItem `json:"items"`
	Total int           `json:"total"`
}

// RecyclePreviewResp GET /drive/recycle/{uuid}/preview 响应.
type RecyclePreviewResp struct {
	URL         string    `json:"url"`
	ExpiresAt   time.Time `json:"expires_at"`
	PreviewKind string    `json:"preview_kind"`
}

// RecycleSvc Phase 2.2e: recycle 服务.
type RecycleSvc struct {
	pool       *pgxpool.Pool
	spaces     *drepo.SpaceRepo
	folders    *drepo.FolderRepo
	files      *drepo.FileRepo
	quotas     *drepo.QuotaRepo
	recycle    *drepo.RecycleRepo
	acl        *ACLService
	storage    StorageGetter
	previewTTL time.Duration
	deleters   interface {
		GetByID(ctx context.Context, id int64) (*domaccount.Account, error)
	}
}

// NewRecycleSvc 构造.
func NewRecycleSvc(
	pool *pgxpool.Pool,
	sp *drepo.SpaceRepo,
	fd *drepo.FolderRepo,
	fl *drepo.FileRepo,
	qt *drepo.QuotaRepo,
	rc *drepo.RecycleRepo,
	acl *ACLService,
	storage StorageGetter,
) *RecycleSvc {
	return &RecycleSvc{
		pool:       pool,
		spaces:     sp,
		folders:    fd,
		files:      fl,
		quotas:     qt,
		recycle:    rc,
		acl:        acl,
		storage:    storage,
		previewTTL: 10 * time.Minute,
	}
}

// WithDeletedByLookup 注入账号查询,为回收站「删除者」列回填展示字段。
func (s *RecycleSvc) WithDeletedByLookup(lookup interface {
	GetByID(ctx context.Context, id int64) (*domaccount.Account, error)
}) *RecycleSvc {
	s.deleters = lookup
	return s
}

// List GET /drive/recycle: 返 caller manager+ space 内未 tombstone 的回收行.
// 默认 50, cap 200; 按 deleted_at_logical DESC.
func (s *RecycleSvc) List(ctx context.Context, accountID, tenantID int64, limit int) (*RecycleListResp, error) {
	spaceIDs, err := s.acl.ListManageableSpaceIDs(ctx, tenantID, accountID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(fmt.Errorf("drive.RecycleSvc.List.ACL: %w", err))
	}
	if len(spaceIDs) == 0 {
		return &RecycleListResp{Items: []RecycleItem{}, Total: 0}, nil
	}

	entries, total, err := s.recycle.ListBySpaces(ctx, spaceIDs, limit)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}

	out := make([]RecycleItem, 0, len(entries))
	spaceCache := make(map[int64]string)
	spaceObjCache := make(map[int64]*dom.Space)
	deleterCache := make(map[int64]*domaccount.Account)
	for i := range entries {
		e := &entries[i]
		var sp *dom.Space
		spUUID, ok := spaceCache[e.SpaceID]
		if !ok {
			var err error
			sp, err = s.spaces.GetByID(ctx, e.SpaceID)
			if err != nil {
				return nil, apperr.ErrInternal.Wrap(err)
			}
			if sp != nil {
				spUUID = sp.UUID
				spaceCache[e.SpaceID] = spUUID
				spaceObjCache[e.SpaceID] = sp
			}
		} else {
			sp = spaceObjCache[e.SpaceID]
		}
		targetUUID, name, mimeType, locationPath, previewURL := s.lookupTargetMeta(ctx, tenantID, e, sp)
		var deletedByUUID, deletedByName, deletedByAvatar string
		if s.deleters != nil && e.DeletedBy > 0 {
			deleter, ok := deleterCache[e.DeletedBy]
			if !ok {
				if acc, err := s.deleters.GetByID(ctx, e.DeletedBy); err == nil && acc != nil {
					deleter = acc
				}
				deleterCache[e.DeletedBy] = deleter
			}
			if deleter != nil {
				deletedByUUID = deleter.UUID
				deletedByName = deleter.DisplayName
				deletedByAvatar = deleter.AvatarURL
			}
		}
		out = append(out, RecycleItem{
			UUID:               e.UUID,
			TargetKind:         string(e.TargetKind),
			TargetUUID:         targetUUID,
			SpaceUUID:          spUUID,
			Name:               name,
			LocationPath:       locationPath,
			MimeType:           mimeType,
			PreviewURL:         previewURL,
			DeletedByUUID:      deletedByUUID,
			DeletedByName:      deletedByName,
			DeletedByAvatarURL: deletedByAvatar,
			DeletedAtLogical:   e.DeletedAtLogical,
			ExpiresAt:          e.ExpiresAt,
			BytesToReclaim:     e.BytesToReclaim,
		})
	}
	return &RecycleListResp{Items: out, Total: total}, nil
}

// Preview GET /drive/recycle/{uuid}/preview: 为回收站中的图片文件签 inline 预览 URL.
// 不复用 FileSvc.Preview, 因为普通文件预览会过滤 is_deleted=true。
func (s *RecycleSvc) Preview(ctx context.Context, accountID, tenantID int64, recycleUUID string) (*RecyclePreviewResp, error) {
	entry, sp, err := s.resolveEntryForManager(ctx, accountID, tenantID, recycleUUID)
	if err != nil {
		return nil, err
	}
	if entry.TargetKind != dom.RecycleTargetFile {
		return nil, apperr.ErrInvalidParams.Withf("drive.recycle_preview_not_file")
	}
	file, err := s.files.GetByIDIncludingDeleted(ctx, entry.TargetID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("file")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !isRecycleImage(file) {
		return nil, apperr.ErrInvalidParams.Withf("drive.recycle_preview_not_image")
	}
	store, err := s.storage.Resolve(ctx, sp.TenantID)
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
	return &RecyclePreviewResp{
		URL:         out.URL,
		ExpiresAt:   out.ExpiresAt,
		PreviewKind: "image",
	}, nil
}

// Restore POST /drive/recycle/{uuid}/restore: 反向软删 target + tombstone 回收行.
// ACL manager+ on space; 配额**不动** (原 size 仍计).
// 409 drive.duplicate_name: 同 folder/parent 已有同名 (recycle 期间被新建).
func (s *RecycleSvc) Restore(ctx context.Context, accountID, tenantID int64, recycleUUID string) error {
	entry, _, err := s.resolveEntryForManager(ctx, accountID, tenantID, recycleUUID)
	if err != nil {
		return err
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("drive.RecycleSvc.Restore.beginTx: %w", err))
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	if _, err := s.recycle.LockByUUIDTx(ctx, tx, recycleUUID); err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("recycle")
		}
		return apperr.ErrInternal.Wrap(err)
	}

	switch entry.TargetKind {
	case dom.RecycleTargetFile:
		if err := s.files.RestoreTx(ctx, tx, entry.TargetID, accountID); err != nil {
			if errors.Is(err, drepo.ErrDuplicateName) {
				return apperr.ErrConflict.Withf("drive.duplicate_name")
			}
			if errors.Is(err, drepo.ErrNotFound) {
				return apperr.ErrNotFound.Withf("file")
			}
			return apperr.ErrInternal.Wrap(err)
		}
	case dom.RecycleTargetFolder:
		if err := s.folders.RestoreTx(ctx, tx, entry.TargetID, accountID); err != nil {
			if errors.Is(err, drepo.ErrDuplicateName) {
				return apperr.ErrConflict.Withf("drive.duplicate_name")
			}
			if errors.Is(err, drepo.ErrNotFound) {
				return apperr.ErrNotFound.Withf("folder")
			}
			return apperr.ErrInternal.Wrap(err)
		}
	default:
		return apperr.ErrInternal.Withf("drive.recycle_unknown_kind")
	}

	if err := s.recycle.TombstoneTx(ctx, tx, entry.ID, accountID); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}

	if err := tx.Commit(ctx); err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("drive.RecycleSvc.Restore.commit: %w", err))
	}
	committed = true
	return nil
}

// Purge DELETE /drive/recycle/{uuid}/purge: 物理删 + 释放配额 + best-effort store.Delete.
// ACL manager+ on space.
//
// 3 阶段:
//
//	Phase 1 (no TX): 锁 recycle 行, 拿 storage_key (file 才有);
//	Phase 2 (TX):    物理删 drive_files/folders + recycle + 释放 tenant/account quota + 释放 space.used_bytes;
//	Phase 3 (after commit): best-effort store.Delete(storage_key) for files; 失败仅 slog (reaper 兜底).
func (s *RecycleSvc) Purge(ctx context.Context, accountID, tenantID int64, recycleUUID string) error {
	entry, _, err := s.resolveEntryForManager(ctx, accountID, tenantID, recycleUUID)
	if err != nil {
		return err
	}

	// 预拿 tenant quota 行 id (purge 阶段 -delta 用); 不存在视为无配额.
	// account quota id 必须在 TX 内 LockByIDTx 之后用 file.created_by 反查 —
	// 因为是上传者被扣的, 不是删除者 (entry.DeletedBy 可能是 manager 帮删, 与上传者无关).
	tenantQuotaID, err := s.lookupTenantQuotaID(ctx, tenantID)
	if err != nil {
		return apperr.ErrInternal.Wrap(err)
	}

	var storageKey string
	var accountQuotaID int64 // 0 = 不释放 account quota (legacy created_by=NULL or folder branch).

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("drive.RecycleSvc.Purge.beginTx: %w", err))
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	if _, err := s.recycle.LockByUUIDTx(ctx, tx, recycleUUID); err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("recycle")
		}
		return apperr.ErrInternal.Wrap(err)
	}

	switch entry.TargetKind {
	case dom.RecycleTargetFile:
		// 锁 file 取 storage_key (Phase 3 best-effort store.Delete 用) + created_by (account quota 释放对象).
		f, err := s.files.LockByIDTx(ctx, tx, entry.TargetID)
		if err != nil {
			if errors.Is(err, drepo.ErrNotFound) {
				// 已被并发清理 (e.g. cleanup-worker reaper); 继续 purge recycle 行 + 释放 tenant 配额仍然安全.
				// account quota 无法定位上传者 → 跳过, 避免误扣他人.
				storageKey = ""
			} else {
				return apperr.ErrInternal.Wrap(err)
			}
		} else {
			storageKey = f.StorageKey
			if f.CreatedBy != nil {
				accountQuotaID, err = s.lookupAccountQuotaID(ctx, tenantID, *f.CreatedBy)
				if err != nil {
					return apperr.ErrInternal.Wrap(err)
				}
			} else {
				// 历史遗留: created_by 缺失 → 只释放 tenant quota; account quota 跳过.
				slog.WarnContext(ctx, "drive.recycle.purge.file_missing_created_by",
					"file_id", entry.TargetID, "tenant_id", tenantID, "recycle_uuid", recycleUUID)
			}
		}
		if err := s.files.HardDeleteByIDTx(ctx, tx, entry.TargetID); err != nil && !errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrInternal.Wrap(err)
		}
	case dom.RecycleTargetFolder:
		// folder 分支 entry.BytesToReclaim == 0 (folder.Delete 仅允许空 folder), account quota math 是 no-op,
		// accountQuotaID 留 0 即可.
		if err := s.folders.HardDeleteByIDTx(ctx, tx, entry.TargetID); err != nil && !errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrInternal.Wrap(err)
		}
	default:
		return apperr.ErrInternal.Withf("drive.recycle_unknown_kind")
	}

	if err := s.recycle.HardDeleteTx(ctx, tx, entry.ID); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}

	if entry.BytesToReclaim > 0 {
		// quotaID == 0 → AddUsedBytesSignedTx 自身 no-op (tenant 无配额 / file.created_by=NULL 跳过).
		if err := s.quotas.AddUsedBytesSignedTx(ctx, tx, tenantQuotaID, -entry.BytesToReclaim); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if err := s.quotas.AddUsedBytesSignedTx(ctx, tx, accountQuotaID, -entry.BytesToReclaim); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
		if err := s.spaces.AddUsedBytesSignedTx(ctx, tx, entry.SpaceID, -entry.BytesToReclaim); err != nil {
			return apperr.ErrInternal.Wrap(err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("drive.RecycleSvc.Purge.commit: %w", err))
	}
	committed = true

	// Phase 3: best-effort store.Delete (失败仅日志; orphan 由 reaper 兜底).
	if storageKey != "" && s.storage != nil {
		store, err := s.storage.Resolve(ctx, tenantID)
		if err != nil {
			slog.ErrorContext(ctx, "drive.recycle.purge.storage_resolve_failed",
				"err", err.Error(), "tenant_id", tenantID, "key", storageKey)
		} else if delErr := store.Delete(ctx, storageKey); delErr != nil {
			slog.ErrorContext(ctx, "drive.recycle.purge.orphan_object",
				"key", storageKey, "err", delErr.Error(), "tenant_id", tenantID, "recycle_uuid", recycleUUID)
		}
	}
	return nil
}

func (s *RecycleSvc) resolveEntryForManager(ctx context.Context, accountID, tenantID int64, recycleUUID string) (*dom.RecycleEntry, *dom.Space, error) {
	entry, err := s.recycle.GetByUUID(ctx, recycleUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, nil, apperr.ErrNotFound.Withf("recycle")
		}
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	sp, err := s.spaces.GetByID(ctx, entry.SpaceID)
	if err != nil {
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	if sp == nil || sp.TenantID != tenantID {
		return nil, nil, apperr.ErrNotFound.Withf("recycle")
	}
	role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetSpace, sp.ID)
	if err != nil {
		return nil, nil, apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastManager(role) {
		return nil, nil, apperr.ErrForbidden.Withf("drive.acl.forbidden")
	}
	return entry, sp, nil
}

func (s *RecycleSvc) lookupTargetMeta(ctx context.Context, tenantID int64, e *dom.RecycleEntry, sp *dom.Space) (targetUUID, name, mimeType, locationPath, previewURL string) {
	switch e.TargetKind {
	case dom.RecycleTargetFile:
		f, err := s.files.GetByIDIncludingDeleted(ctx, e.TargetID)
		if err != nil || f == nil {
			return "", "", "", "", ""
		}
		return f.UUID, f.Name, f.MimeType, s.locationPathForFile(ctx, sp, f), s.presignRecyclePreviewURL(ctx, tenantID, f)
	case dom.RecycleTargetFolder:
		var uuid, name, path string
		if err := s.pool.QueryRow(ctx, `SELECT uuid::text, name, path FROM drive_folders WHERE id = $1`, e.TargetID).Scan(&uuid, &name, &path); err != nil {
			return "", "", "", "", ""
		}
		return uuid, name, "", recycleDisplayPath(sp, path, false), ""
	}
	return "", "", "", "", ""
}

func (s *RecycleSvc) locationPathForFile(ctx context.Context, sp *dom.Space, f *dom.File) string {
	if f.DriveFolderID == nil {
		return recycleDisplayPath(sp, "", true)
	}
	var path string
	if err := s.pool.QueryRow(ctx, `SELECT path FROM drive_folders WHERE id = $1`, *f.DriveFolderID).Scan(&path); err != nil {
		return recycleDisplayPath(sp, "", true)
	}
	return recycleDisplayPath(sp, path, true)
}

func recycleDisplayPath(sp *dom.Space, folderPath string, includeSelf bool) string {
	prefix := recyclePathPrefix(sp)
	p := strings.Trim(folderPath, "/")
	if p == "" {
		return prefix
	}
	parts := strings.Split(p, "/")
	if !includeSelf && len(parts) > 0 {
		parts = parts[:len(parts)-1]
	}
	if len(parts) == 0 {
		return prefix
	}
	return prefix + " / " + strings.Join(parts, " / ")
}

func recyclePathPrefix(sp *dom.Space) string {
	if sp == nil {
		return "云盘"
	}
	if sp.Kind == dom.SpaceKindPersonal {
		return "我的空间 / 云盘"
	}
	name := strings.TrimSpace(sp.Name)
	if name == "" {
		return "共享空间 / 云盘"
	}
	return "共享空间 / 云盘 / " + name
}

func (s *RecycleSvc) presignRecyclePreviewURL(ctx context.Context, tenantID int64, f *dom.File) string {
	if s.storage == nil || !isRecycleImage(f) {
		return ""
	}
	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return ""
	}
	out, err := store.PresignGet(ctx, object.PresignGetInput{
		Key:      f.StorageKey,
		TTL:      s.previewTTL,
		Inline:   true,
		FileName: f.Name,
	})
	if err != nil || out == nil {
		return ""
	}
	return out.URL
}

func isRecycleImage(f *dom.File) bool {
	if f == nil {
		return false
	}
	if strings.HasPrefix(strings.ToLower(f.MimeType), "image/") {
		return true
	}
	name := strings.ToLower(f.Name)
	return strings.HasSuffix(name, ".png") ||
		strings.HasSuffix(name, ".jpg") ||
		strings.HasSuffix(name, ".jpeg") ||
		strings.HasSuffix(name, ".gif") ||
		strings.HasSuffix(name, ".webp") ||
		strings.HasSuffix(name, ".bmp") ||
		strings.HasSuffix(name, ".svg") ||
		strings.HasSuffix(name, ".heic") ||
		strings.HasSuffix(name, ".heif")
}

func (s *RecycleSvc) lookupTenantQuotaID(ctx context.Context, tenantID int64) (int64, error) {
	q, err := s.quotas.GetForTenant(ctx, tenantID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return 0, nil
		}
		return 0, err
	}
	return q.ID, nil
}

func (s *RecycleSvc) lookupAccountQuotaID(ctx context.Context, tenantID, accountID int64) (int64, error) {
	q, err := s.quotas.GetForAccount(ctx, tenantID, accountID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return 0, nil
		}
		return 0, err
	}
	return q.ID, nil
}

// roleAtLeastManager Recycle 语义 (manager+); 与 roleAtLeastEditor 对称, 避免反向 import.
func roleAtLeastManager(role dom.ACLRole) bool {
	return role == dom.ACLRoleManager
}
