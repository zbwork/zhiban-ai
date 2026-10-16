package drive

import (
	"context"
	"time"
)

// ACLTargetKind 与 drive_acl_entries.target_kind CHECK 对齐 (F06 §2.5 + ADR 0017).
type ACLTargetKind string

const (
	ACLTargetSpace  ACLTargetKind = "space"
	ACLTargetFolder ACLTargetKind = "folder"
	ACLTargetFile   ACLTargetKind = "file"
)

// ACLSubjectKind 与 drive_acl_entries.subject_kind CHECK 对齐.
type ACLSubjectKind string

const (
	ACLSubjectAccount    ACLSubjectKind = "account"
	ACLSubjectDepartment ACLSubjectKind = "department"
	ACLSubjectLinkToken  ACLSubjectKind = "link_token"
)

// ACLRole 与 drive_acl_entries.role CHECK 对齐 (扩权-only, ADR 0017).
type ACLRole string

const (
	ACLRoleViewer  ACLRole = "viewer"
	ACLRoleEditor  ACLRole = "editor"
	ACLRoleManager ACLRole = "manager"
)

// ACLEntry F06 §2.5 drive_acl_entries 一条 grant.
type ACLEntry struct {
	ID          int64
	UUID        string
	TenantID    int64
	TargetKind  ACLTargetKind
	TargetID    int64
	SubjectKind ACLSubjectKind
	SubjectID   *int64
	LinkTokenID *int64
	Role        ACLRole
	GrantedBy   int64
	CreatedAt   time.Time
	CreatedBy   *int64
	UpdatedAt   time.Time
	UpdatedBy   *int64
	IsDeleted   bool
	DeletedAt   *time.Time
}

// ACLRepo Phase 2.0a 仅暴露 GetByID.
type ACLRepo interface {
	GetByID(ctx context.Context, id int64) (*ACLEntry, error)
}
