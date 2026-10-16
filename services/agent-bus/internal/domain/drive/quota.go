package drive

import (
	"context"
	"time"
)

// QuotaSubjectKind 与 drive_quotas.subject_kind CHECK 对齐 (F06 §2.9).
type QuotaSubjectKind string

const (
	QuotaSubjectTenant  QuotaSubjectKind = "tenant"
	QuotaSubjectAccount QuotaSubjectKind = "account"
)

// Quota F06 §2.9 drive_quotas 一行配额记录.
type Quota struct {
	ID          int64
	UUID        string
	TenantID    int64
	SubjectKind QuotaSubjectKind
	SubjectID   *int64 // account 时填 account_id; tenant 时 NULL
	QuotaBytes  int64  // -1 = 无限
	UsedBytes   int64
	CreatedAt   time.Time
	CreatedBy   *int64
	UpdatedAt   time.Time
	UpdatedBy   *int64
	IsDeleted   bool
	DeletedAt   *time.Time
}

// QuotaRepo Phase 2.0a 仅暴露 GetByID.
type QuotaRepo interface {
	GetByID(ctx context.Context, id int64) (*Quota, error)
}
