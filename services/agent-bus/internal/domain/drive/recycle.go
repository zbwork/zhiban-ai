package drive

import (
	"context"
	"time"
)

// RecycleTargetKind 与 drive_recycle_bin.target_kind CHECK 对齐 (F06 §2.8).
type RecycleTargetKind string

const (
	RecycleTargetFile   RecycleTargetKind = "file"
	RecycleTargetFolder RecycleTargetKind = "folder"
)

// RecycleEntry F06 §2.8 drive_recycle_bin 一行待清理记录.
type RecycleEntry struct {
	ID               int64
	UUID             string
	TenantID         int64
	TargetKind       RecycleTargetKind
	TargetID         int64
	SpaceID          int64
	DeletedBy        int64
	DeletedAtLogical time.Time
	ExpiresAt        time.Time
	BytesToReclaim   int64
	CreatedAt        time.Time
	CreatedBy        *int64
	UpdatedAt        time.Time
	UpdatedBy        *int64
	IsDeleted        bool
	DeletedAt        *time.Time
}

// RecycleRepo Phase 2.0a 仅暴露 GetByID.
type RecycleRepo interface {
	GetByID(ctx context.Context, id int64) (*RecycleEntry, error)
}

// CreateRecycleInput F06 Phase 2.2e: 软删 file/folder 时写 drive_recycle_bin 一行.
// bytes_to_reclaim 由 caller (FileSvc/FolderSvc.Delete) 决定; folder 空树时传 0,
// file 传 size_bytes (含未来 version 总量在 versioning slice 接入).
type CreateRecycleInput struct {
	TenantID       int64
	TargetKind     RecycleTargetKind
	TargetID       int64
	SpaceID        int64
	DeletedBy      int64
	ExpiresAt      time.Time
	BytesToReclaim int64
}
