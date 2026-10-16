package drive

import (
	"context"
	"time"
)

// FileVersion F06 §2.7 drive_file_versions 历史版本.
type FileVersion struct {
	ID           int64
	UUID         string
	FileID       int64
	VersionNo    int
	StorageKey   string
	SizeBytes    int64
	SHA256       *string
	Name         string
	UploadSource FileSource // 复用 file.go 的 FileSource enum
	SupersededAt time.Time
	CreatedAt    time.Time
	CreatedBy    *int64
	UpdatedAt    time.Time
	UpdatedBy    *int64
	IsDeleted    bool
	DeletedAt    *time.Time
}

// FileVersionRepo Phase 2.0a 仅暴露 GetByID.
type FileVersionRepo interface {
	GetByID(ctx context.Context, id int64) (*FileVersion, error)
}
