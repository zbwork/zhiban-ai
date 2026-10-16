// admin_recycle.go — F06 Phase B admin: 租户级回收站 (跨账户全可见 + 代为还原/彻底删).
//
// 3 个对外方法:
//
//	List     列本租户全部待清理 recycle 行 (含未过期; 按 expires_at 升序)
//	Restore  反向软删 + tombstone recycle 行 (与 user 端 RecycleSvc.Restore 不同: 不查 caller account)
//	Purge    物理删 + 释放 quota + 删 S3 (与 user 端 RecycleSvc.Purge 不同: 不查 caller account)
//
// ACL: admin handler tenantPerm("tenant.drive.manage_recycle") 把关. 跨租户 enumeration 由 List
// 的 tenant_id 过滤 + Restore/Purge 入口在 TX 内重新校 entry.TenantID == tenantID 双重防御.
//
// 实现复用:
//   - List 走 RecycleRepo.ListByTenant
//   - Restore 在 TX 内复用 files.RestoreTx / folders.RestoreTx + recycle.TombstoneTx
//   - Purge 直接复用 WorkerSvc.PurgeOne (TX + S3 delete + quota release)
package drive

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// AdminRecycleSvc Phase B admin: 租户级回收站 admin 视图.
// 与客户端 RecycleSvc 区别: 不限 caller account; admin perm 已把关.
type AdminRecycleSvc struct {
	pool    *pgxpool.Pool
	recycle *drepo.RecycleRepo
	files   *drepo.FileRepo
	folders *drepo.FolderRepo
	spaces  *drepo.SpaceRepo
	worker  *WorkerSvc // 复用 PurgeOne 的 TX + S3 + quota 释放
}

// NewAdminRecycleSvc 构造. worker 提供 PurgeOne 复用; 其它 repo 用于 List/Restore.
func NewAdminRecycleSvc(
	pool *pgxpool.Pool,
	recycle *drepo.RecycleRepo,
	files *drepo.FileRepo,
	folders *drepo.FolderRepo,
	spaces *drepo.SpaceRepo,
	worker *WorkerSvc,
) *AdminRecycleSvc {
	return &AdminRecycleSvc{
		pool: pool, recycle: recycle, files: files, folders: folders, spaces: spaces, worker: worker,
	}
}

// AdminRecycleItem 单 recycle 行 (response). 字段与前端 wrapper DriveRecycleAdminItem 对齐.
type AdminRecycleItem struct {
	UUID           string    `json:"uuid"`
	TargetKind     string    `json:"target_kind"` // file | folder
	TargetUUID     string    `json:"target_uuid,omitempty"`
	TargetName     string    `json:"target_name,omitempty"`
	SpaceUUID      string    `json:"space_uuid,omitempty"`
	SpaceName      string    `json:"space_name,omitempty"`
	DeletedBy      int64     `json:"deleted_by,omitempty"`
	DeletedByName  string    `json:"deleted_by_name,omitempty"`
	DeletedAt      time.Time `json:"deleted_at"`
	ExpiresAt      time.Time `json:"expires_at"`
	BytesToReclaim int64     `json:"bytes_to_reclaim"`
}

type adminRecycleSpaceMeta struct {
	UUID string
	Name string
}

// List 列本租户回收站. cursor=0 = 第一页; 返 (items, nextCursor); next=0 表示没下一页.
func (s *AdminRecycleSvc) List(ctx context.Context, tenantID int64, limit int, cursor int64) ([]AdminRecycleItem, int64, error) {
	rows, next, err := s.recycle.ListByTenant(ctx, tenantID, limit, cursor)
	if err != nil {
		return nil, 0, apperr.ErrInternal.Wrap(err)
	}
	out := make([]AdminRecycleItem, 0, len(rows))
	// space cache 减少 N+1 查询
	spaceCache := make(map[int64]*adminRecycleSpaceMeta)
	deletedByCache := make(map[int64]string)
	for i := range rows {
		e := &rows[i]
		item := AdminRecycleItem{
			UUID:           e.UUID,
			TargetKind:     string(e.TargetKind),
			DeletedBy:      e.DeletedBy,
			DeletedAt:      e.DeletedAtLogical,
			ExpiresAt:      e.ExpiresAt,
			BytesToReclaim: e.BytesToReclaim,
		}
		if name, ok := deletedByCache[e.DeletedBy]; ok {
			item.DeletedByName = name
		} else {
			name := s.accountDisplayName(ctx, tenantID, e.DeletedBy)
			deletedByCache[e.DeletedBy] = name
			item.DeletedByName = name
		}
		// space 名 (best-effort)
		if sp, ok := spaceCache[e.SpaceID]; ok && sp != nil {
			item.SpaceUUID = sp.UUID
			item.SpaceName = sp.Name
		} else {
			sp := s.recycleSpaceMeta(ctx, tenantID, e.SpaceID)
			spaceCache[e.SpaceID] = sp
			if sp != nil {
				item.SpaceUUID = sp.UUID
				item.SpaceName = sp.Name
			}
		}
		// target 名 + uuid (best-effort; 已物理删的 file/folder 取不到)
		switch e.TargetKind {
		case dom.RecycleTargetFile:
			if f, err := s.files.GetByIDIncludingDeleted(ctx, e.TargetID); err == nil && f != nil {
				item.TargetUUID = f.UUID
				item.TargetName = f.Name
			}
		case dom.RecycleTargetFolder:
			if fd, err := s.folders.GetByIDIncludingDeleted(ctx, e.TargetID); err == nil && fd != nil {
				item.TargetUUID = fd.UUID
				item.TargetName = fd.Name
			}
		}
		out = append(out, item)
	}
	return out, next, nil
}

func (s *AdminRecycleSvc) recycleSpaceMeta(ctx context.Context, tenantID, spaceID int64) *adminRecycleSpaceMeta {
	var (
		uuid      string
		kind      string
		name      string
		ownerName string
	)
	err := s.pool.QueryRow(ctx, `
SELECT s.uuid::text, s.kind, s.name, COALESCE(NULLIF(tm.nickname,''), owner.display_name, '')
  FROM drive_spaces s
  LEFT JOIN accounts owner ON owner.id = s.owner_account_id
  LEFT JOIN tenant_memberships tm ON tm.tenant_id = s.tenant_id
       AND tm.account_id = s.owner_account_id
       AND tm.deleted_at IS NULL
 WHERE s.id = $1 AND s.tenant_id = $2 AND s.is_deleted = false`, spaceID, tenantID).
		Scan(&uuid, &kind, &name, &ownerName)
	if err != nil {
		return nil
	}
	return &adminRecycleSpaceMeta{UUID: uuid, Name: adminSpaceDisplayName(kind, name, ownerName)}
}

func (s *AdminRecycleSvc) accountDisplayName(ctx context.Context, tenantID, accountID int64) string {
	if accountID <= 0 {
		return ""
	}
	var name string
	err := s.pool.QueryRow(ctx, `
SELECT COALESCE(NULLIF(tm.nickname,''), a.display_name, '')
  FROM accounts a
  LEFT JOIN tenant_memberships tm ON tm.tenant_id = $1
       AND tm.account_id = a.id
       AND tm.deleted_at IS NULL
 WHERE a.id = $2 AND a.deleted_at IS NULL`, tenantID, accountID).Scan(&name)
	if err != nil {
		return ""
	}
	return adminCleanDisplayName(name)
}

// Restore 反向软删 + tombstone recycle 行. updatedBy = admin caller id.
// 与 user 端 RecycleSvc.Restore 区别: 不查 caller account; 但仍校 entry.TenantID == tenantID.
func (s *AdminRecycleSvc) Restore(ctx context.Context, tenantID int64, recycleUUID string, updatedBy int64) error {
	entry, err := s.recycle.GetByUUID(ctx, recycleUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("recycle")
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if entry.TenantID != tenantID {
		return apperr.ErrNotFound.Withf("recycle") // 跨租户当 404
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("begin tx: %w", err))
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
		if err := s.files.RestoreTx(ctx, tx, entry.TargetID, updatedBy); err != nil {
			if errors.Is(err, drepo.ErrDuplicateName) {
				return apperr.ErrConflict.Withf("drive.duplicate_name")
			}
			if errors.Is(err, drepo.ErrNotFound) {
				return apperr.ErrNotFound.Withf("file")
			}
			return apperr.ErrInternal.Wrap(err)
		}
	case dom.RecycleTargetFolder:
		if err := s.folders.RestoreTx(ctx, tx, entry.TargetID, updatedBy); err != nil {
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
	if err := s.recycle.TombstoneTx(ctx, tx, entry.ID, updatedBy); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	if err := tx.Commit(ctx); err != nil {
		return apperr.ErrInternal.Wrap(fmt.Errorf("commit: %w", err))
	}
	committed = true
	return nil
}

// Purge 直接复用 WorkerSvc.PurgeOne — 它已包含 TX + S3 delete + quota release.
// 同样校 tenant 一致.
func (s *AdminRecycleSvc) Purge(ctx context.Context, tenantID int64, recycleUUID string) error {
	entry, err := s.recycle.GetByUUID(ctx, recycleUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return apperr.ErrNotFound.Withf("recycle")
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if entry.TenantID != tenantID {
		return apperr.ErrNotFound.Withf("recycle")
	}
	if err := s.worker.PurgeOne(ctx, entry); err != nil {
		return apperr.ErrInternal.Wrap(err)
	}
	return nil
}
