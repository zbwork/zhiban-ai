package drive

import (
	"context"
	"time"
)

// FolderKind 与 drive_folders.kind CHECK 对齐 (F06 §2.3 + ADR 0019).
type FolderKind string

const (
	FolderKindRegular   FolderKind = "regular"
	FolderKindDeRoot    FolderKind = "de_root"
	FolderKindDeAgent   FolderKind = "de_agent"
	FolderKindDeOutputs FolderKind = "de_outputs"
)

// Folder 云盘目录树节点 (F06 §2.3).
type Folder struct {
	ID        int64
	UUID      string
	SpaceID   int64
	ParentID  *int64
	Name      string
	Kind      FolderKind
	AgentID   *string // de_agent/de_outputs 时非空
	IsSystem  bool
	Path      string
	Sort      int
	CreatedAt time.Time
	CreatedBy *int64
	UpdatedAt time.Time
	UpdatedBy *int64
	IsDeleted bool
	DeletedAt *time.Time
}

// FolderRepo Phase 2.0a 仅暴露 GetByID; 后续按需扩.
type FolderRepo interface {
	GetByID(ctx context.Context, id int64) (*Folder, error)
}

// CreateFolderInput F06 Phase 2.2b drive_folders 创建入参.
// path 由 service 层根据 parent.path + name 预算好后传入 (repo 不再二次拼接).
type CreateFolderInput struct {
	SpaceID   int64
	ParentID  *int64
	Name      string
	Path      string // 由 service 层预算 (/<...>/<name>/)
	Kind      FolderKind
	AgentID   *string
	IsSystem  bool
	CreatedBy int64
}
