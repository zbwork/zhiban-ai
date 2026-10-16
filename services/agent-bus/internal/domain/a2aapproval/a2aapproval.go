// Package a2aapproval 定义 A2A 策略驱动审批单 (v1e).
package a2aapproval

import (
	"context"
	"time"

	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
)

type Status string

const (
	StatusPending   Status = "pending"
	StatusApproved  Status = "approved"
	StatusRejected  Status = "rejected"
	StatusExpired   Status = "expired"
	StatusCancelled Status = "cancelled"
)

type Request struct {
	ID                     int64
	UUID                   string
	TenantID               int64
	EdgeID                 int64
	EdgeUUID               string
	EdgeCreatedAt          time.Time
	FromAgentID            int64
	ToAgentID              int64
	ParentSessionTokenID   int64
	ParentAccountID        int64
	CallerCapabilities     []string
	InvokeKind             doma2a.InvokeKind
	RequestPayload         []byte
	RequestPayloadRedacted []byte
	FormSchema             []byte
	FormResult             []byte
	Status                 Status
	Reason                 string
	ExpiresAt              *time.Time
	DecidedByAccountID     *int64
	DecidedAt              *time.Time
	DispatchedAt           *time.Time
	CreatedAt              time.Time
	UpdatedAt              time.Time
	IsDeleted              bool
	DeletedAt              *time.Time
}

type CreateInput struct {
	TenantID               int64
	EdgeID                 int64
	EdgeUUID               string
	EdgeCreatedAt          time.Time
	FromAgentID            int64
	ToAgentID              int64
	ParentSessionTokenID   int64
	ParentAccountID        int64
	CallerCapabilities     []string
	InvokeKind             doma2a.InvokeKind
	RequestPayload         []byte
	RequestPayloadRedacted []byte
	FormSchema             []byte
	ExpiresAt              *time.Time
}

type DecisionInput struct {
	TenantID         int64
	ApprovalUUID     string
	ParentAccountID  int64
	Decision         Status
	FormResult       []byte
	Reason           string
	ActorAccountID   int64
	DecidedAt        time.Time
	ClearRawPayload  bool
	MarkDispatchedAt *time.Time
}

type ListFilter struct {
	TenantID        int64
	ParentAccountID int64
	Status          Status
	Limit           int
	Offset          int
}

type Repository interface {
	Create(ctx context.Context, in CreateInput) (*Request, error)
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*Request, error)
	DecidePending(ctx context.Context, in DecisionInput) (*Request, error)
	MarkDispatchedAndClear(ctx context.Context, tenantID int64, approvalUUID string, dispatchedAt time.Time) error
	CancelPendingByEdge(ctx context.Context, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, now time.Time) error
	ExpirePending(ctx context.Context, now time.Time, limit int) ([]*Request, error)
	List(ctx context.Context, f ListFilter) ([]*Request, int, error)
}
