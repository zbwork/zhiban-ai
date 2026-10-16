// Package drivev3 是 F06 Drive v0.3.x 的 domain types + Repo 接口 (side-by-side 切换期临时命名;
// Phase 2.Z 删 legacy 后 rename 为 drive).
//
// 设计纪律:
//   - 仅 domain struct + Repo 接口; 不含 service 行为; 不含 pgx 实现
//   - 跟 F06 v0.3.1 §2.x schema 1:1 对齐 (drive_spaces / drive_folders / drive_files / drive_acl_entries /
//     drive_share_links / drive_file_versions / drive_recycle_bin / drive_quotas / drive_upload_tickets)
package drive

import (
	"context"
	"time"
)

// SpaceKind 与 drive_spaces.kind CHECK 对齐 (F06 §2.2).
type SpaceKind string

const (
	SpaceKindPersonal   SpaceKind = "personal"
	SpaceKindTenant     SpaceKind = "tenant"
	SpaceKindDepartment SpaceKind = "department"
	SpaceKindShared     SpaceKind = "shared"
)

// SpaceStatus 与 drive_spaces.status CHECK 对齐.
type SpaceStatus string

const (
	SpaceStatusActive   SpaceStatus = "active"
	SpaceStatusArchived SpaceStatus = "archived"
)

// Space 4 类空间 (F06 §2.2 / ADR 0015).
type Space struct {
	ID             int64
	UUID           string
	TenantID       int64
	Kind           SpaceKind
	OwnerAccountID *int64 // personal/shared 时非空; tenant/department 时 NULL
	DepartmentID   *int64 // department 时非空; 其它 NULL
	Name           string
	Description    string
	Status         SpaceStatus
	UsedBytes      int64
	CreatedAt      time.Time
	CreatedBy      *int64
	UpdatedAt      time.Time
	UpdatedBy      *int64
	IsDeleted      bool
	DeletedAt      *time.Time
}

// SpaceRepo F06 §2.2 drive_spaces 的最小读写接口.
// Phase 2.0a 仅暴露 GetByID; 后续 slice 按需扩 (EnsurePersonal / EnsureTenant /
// EnsureDepartment / ListByTenant 等).
type SpaceRepo interface {
	GetByID(ctx context.Context, id int64) (*Space, error)
}

// CreateSpaceInput F06 Phase 2.2e: 新建 space (当前仅 shared 路径用; personal/tenant/department
// 走专用 Ensure 路径). owner_account_id 必填 (shared owner = manager 默认); department_id/created_by
// 可空.
type CreateSpaceInput struct {
	TenantID       int64
	Kind           SpaceKind
	OwnerAccountID *int64
	DepartmentID   *int64
	Name           string
	Description    string
	Status         SpaceStatus
	CreatedBy      *int64
}
