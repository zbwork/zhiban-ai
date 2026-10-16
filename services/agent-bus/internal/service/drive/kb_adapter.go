// kb_adapter.go — F06 Phase 2.6: 把 drive.SnapshotSvc 包成 knowledge.DriveFileLookup.
//
// knowledge 包定义了窄抽象 DriveFileLookup (避免 cross-package HTTP / drive 实现细节); 这里
// 在 drivev3 一侧实现该接口, 让 cmd/bus 装配 KB 时直接传 drive.NewKBSnapshotAdapter(...)
// 取代 legacy knowledgeDriveFileLookup{drive: svcdrive.Service, ...}.
//
// 字段映射:
//
//	drive.FileSnapshot.Name        → knowledge.DriveFileSnapshot.FileName
//	drive.FileSnapshot.MimeType    → knowledge.DriveFileSnapshot.MimeType
//	drive.FileSnapshot.SizeBytes   → knowledge.DriveFileSnapshot.FileSize
//	drive.FileSnapshot.DownloadURL → knowledge.DriveFileSnapshot.DownloadURL
//	drive.FileSnapshot.UUID        → knowledge.DriveFileSnapshot.UUID
//
// StorageKind / StorageKey 不再向 knowledge 透传 (KB 只需 GET URL, 不该看 storage 实现).
package drive

import (
	"context"

	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

// KBSnapshotAdapter 实现 knowledge.DriveFileLookup, 内部委托 drive.SnapshotSvc.
type KBSnapshotAdapter struct {
	inner *SnapshotSvc
}

// NewKBSnapshotAdapter 构造.
func NewKBSnapshotAdapter(s *SnapshotSvc) *KBSnapshotAdapter {
	return &KBSnapshotAdapter{inner: s}
}

// GetDriveFileForRead 满足 knowledge.DriveFileLookup; 透传 SnapshotSvc 的错误码
// (drive.file_not_found / drive.access_denied / drive.file_in_copy / drive.preview_unavailable).
func (a *KBSnapshotAdapter) GetDriveFileForRead(
	ctx context.Context,
	accountID, tenantID int64,
	driveFileUUID string,
) (*svckb.DriveFileSnapshot, error) {
	s, err := a.inner.GetDriveFileForRead(ctx, accountID, tenantID, driveFileUUID)
	if err != nil {
		return nil, err
	}
	return &svckb.DriveFileSnapshot{
		UUID:        s.UUID,
		FileName:    s.Name,
		MimeType:    s.MimeType,
		FileSize:    s.SizeBytes,
		DownloadURL: s.DownloadURL,
	}, nil
}

// 编译期断言: KBSnapshotAdapter 必须满足 knowledge.DriveFileLookup.
var _ svckb.DriveFileLookup = (*KBSnapshotAdapter)(nil)
