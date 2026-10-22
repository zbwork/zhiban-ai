// snapshot.go — F06 Phase 2.6: 给跨 svc consumer (KB LinkFromDrive / 未来 ZAP / 其他 svc)
// 的窄投影 + 一次性 GET URL.
//
// 设计目标:
//  1. 收紧暴露面: 只给名字 / mime / size / 已签好的 GET URL + 过期墙钟; storage_key、
//     space/folder 结构、ACL 细节都不出 drivev3 包.
//  2. ACL viewer+ 强制 (Phase 2.0c CheckEffectiveRole) — 与 file.go::Preview 同款.
//  3. copy_status='ready' 强制 — 跨 space copy 进行中的文件不应被 KB ingest / 其他消费者
//     拉到部分内容 (legacy svcdrive.GetFile 不校 copy_status, 这里收紧).
//  4. 跨 tenant → 404 (与 file.go::Preview/Download 一致, 不返 403 防止 enumeration).
//
// 该 svc 不暴露给 HTTP client; 仅 cmd/bus 装配时给 knowledge.DriveFileLookup 用 (经
// KBSnapshotAdapter 适配; 见 kb_adapter.go).
package drive

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/object"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	drepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/drive"
)

// FileSnapshot 是给跨 svc consumer 的窄投影:
//   - 名称 + mime + size: 让 caller 做 MIME/size 闸口 (与 upload 一致).
//   - DownloadURL: 已签好的一次性 GET URL; caller 用 HTTP GET 拉字节.
//   - ExpiresAt: URL 过期墙钟; caller 自行决定缓存策略 (建议立刻消费).
//
// 不暴露 storage_key / folder 结构 / ACL 细节 — 这些是 drivev3 internal 关心的.
type FileSnapshot struct {
	UUID        string
	Name        string
	MimeType    string
	SizeBytes   int64
	DownloadURL string
	ExpiresAt   time.Time
}

// SnapshotSvc 给 knowledge.LinkFromDrive / 未来 KB sync 用; 不暴露给 HTTP client.
type SnapshotSvc struct {
	pool    *pgxpool.Pool
	spaces  *drepo.SpaceRepo
	folders *drepo.FolderRepo
	files   *drepo.FileRepo
	acl     *ACLService
	storage StorageGetter
	ttl     time.Duration // 默认 10min, 与 object.PresignGet 的 ≤ 10min 上限对齐
}

// NewSnapshotSvc 构造.
func NewSnapshotSvc(
	pool *pgxpool.Pool,
	sp *drepo.SpaceRepo,
	fd *drepo.FolderRepo,
	fl *drepo.FileRepo,
	acl *ACLService,
	storage StorageGetter,
) *SnapshotSvc {
	return &SnapshotSvc{
		pool:    pool,
		spaces:  sp,
		folders: fd,
		files:   fl,
		acl:     acl,
		storage: storage,
		ttl:     10 * time.Minute,
	}
}

// GetDriveFileForRead 给 KB / ZAP / 其他 svc 用; 校 viewer+ ACL on file's space+folder; 返签 GET URL.
//
// 错误码:
//   - drive.file_not_found (404)        — uuid 不存在 / soft-deleted / 跨 tenant
//   - drive.access_denied (403)         — ACL < viewer
//   - drive.file_in_copy (409)          — copy_status != ready (跨 space copy 期间不可消费)
//   - drive.preview_unavailable (500)   — storage adapter resolve/presign 失败
//
// 跨 tenant 用 404 而非 403 (与 file get/download 一致, 无信息泄露).
// 检查顺序: file 存在 → 同 tenant → ACL → copy_status → presign. ACL 优先于 copy_status,
// 避免无权 caller 通过 409 vs 200 区分文件状态被枚举 (与 file.go::Download 同款理由).
func (s *SnapshotSvc) GetDriveFileForRead(
	ctx context.Context,
	accountID, tenantID int64,
	fileUUID string,
) (*FileSnapshot, error) {
	if fileUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("file_uuid required")
	}

	// 1. 反查 drive_files (FileRepo.GetByUUID 自带 is_deleted=false 过滤; soft-deleted → 404).
	f, err := s.files.GetByUUID(ctx, fileUUID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("drive.file_not_found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}

	// 2. 反查 space + tenant 隔离 (跨 tenant 统一返 404, 避免枚举).
	space, err := s.spaces.GetByID(ctx, f.SpaceID)
	if err != nil {
		if errors.Is(err, drepo.ErrNotFound) {
			return nil, apperr.ErrNotFound.Withf("drive.file_not_found")
		}
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if space == nil || space.TenantID != tenantID {
		return nil, apperr.ErrNotFound.Withf("drive.file_not_found")
	}

	// 3. ACL viewer+ check (Phase 2.0c CheckEffectiveRole; target=file).
	role, err := s.acl.CheckEffectiveRole(ctx, accountID, dom.ACLTargetFile, f.ID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !roleAtLeastFile(role, dom.ACLRoleViewer) {
		return nil, apperr.ErrForbidden.Withf("drive.access_denied")
	}

	// 4. copy_status 闸: 跨 space copy 进行中的文件不应被 KB ingest 拉到部分内容.
	//    legacy svcdrive.GetFile 不校 copy_status; Phase 2.6 收紧 (与 file.go::Download 一致).
	if f.CopyStatus != dom.CopyStatusReady {
		return nil, apperr.ErrConflict.Withf("drive.file_in_copy")
	}

	// 5. presign GET URL (10min TTL, attachment 模式 — KB ingest 是流水读, 非 inline 预览).
	store, err := s.storage.Resolve(ctx, tenantID)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.preview_unavailable").Wrap(fmt.Errorf("storage resolve: %w", err))
	}
	input := object.PresignGetInput{
		Key:      f.StorageKey,
		TTL:      s.ttl,
		Inline:   false,
		FileName: f.Name,
	}
	// Backend consumers use the internal endpoint when client URLs use a public host.
	presign := store.PresignGet
	if internal, ok := store.(interface {
		PresignGetInternal(context.Context, object.PresignGetInput) (*object.PresignGetOutput, error)
	}); ok {
		presign = internal.PresignGetInternal
	}
	out, err := presign(ctx, input)
	if err != nil {
		return nil, apperr.ErrInternal.Withf("drive.preview_unavailable").Wrap(fmt.Errorf("presign get: %w", err))
	}

	return &FileSnapshot{
		UUID:        f.UUID,
		Name:        f.Name,
		MimeType:    f.MimeType,
		SizeBytes:   f.SizeBytes,
		DownloadURL: out.URL,
		ExpiresAt:   out.ExpiresAt,
	}, nil
}
