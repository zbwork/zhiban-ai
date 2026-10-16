package drive

import (
	"context"
	"time"
)

// ShareTargetKind 与 drive_share_links.target_kind CHECK 对齐 (F06 §2.6 + ADR 0018).
type ShareTargetKind string

const (
	ShareTargetFolder ShareTargetKind = "folder"
	ShareTargetFile   ShareTargetKind = "file"
)

// ShareRole 与 drive_share_links.role CHECK 对齐 (链接分享仅 viewer/editor).
type ShareRole string

const (
	ShareRoleViewer ShareRole = "viewer"
	ShareRoleEditor ShareRole = "editor"
)

// ShareLink F06 §2.6 drive_share_links.
type ShareLink struct {
	ID               int64
	UUID             string
	TenantID         int64
	Token            string
	TargetKind       ShareTargetKind
	TargetID         int64
	Role             ShareRole
	DownloadDisabled bool
	ExpiresAt        *time.Time
	MaxUses          *int
	UsedCount        int
	RevokedAt        *time.Time
	CreatedAt        time.Time
	CreatedBy        *int64
	UpdatedAt        time.Time
	UpdatedBy        *int64
	IsDeleted        bool
	DeletedAt        *time.Time
}

// ShareRepo Phase 2.0a 仅暴露 GetByID.
type ShareRepo interface {
	GetByID(ctx context.Context, id int64) (*ShareLink, error)
}
