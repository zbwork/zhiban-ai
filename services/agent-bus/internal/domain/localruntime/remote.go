package localruntime

import (
	"context"
	"time"
)

type ApprovalDisplay struct {
	Tool      string `json:"tool"`
	Operation string `json:"operation"`
	Target    string `json:"target"`
}
type Approval struct {
	EmployeeName  string          `json:"employee_name"`
	ID            string          `json:"id"`
	Run           string          `json:"run"`
	Conversation  string          `json:"conversation_id"`
	Fence         int64           `json:"fence"`
	Revision      int             `json:"revision"`
	IntentHash    string          `json:"intent_hash"`
	Display       ApprovalDisplay `json:"display"`
	Status        string          `json:"status"`
	DecisionScope string          `json:"scope"`
	ExpiresAt     time.Time       `json:"expires_at"`
}

// Separate from device-only Repository to preserve the execution capability boundary.
type RemoteRepository interface {
	ConversationState(context.Context, Scope, string) (map[string]string, error)
	SetProtocolVersion(context.Context, Scope, string, int) error
	ResolveDesktop(context.Context, Scope, string) (*Device, error)
	ValidateRequester(context.Context, Scope) error
	RegisterApproval(context.Context, *Task, Approval) (*Approval, error)
	GetApproval(context.Context, *Task, string) (*Approval, error)
	ExpireApproval(context.Context, *Task, string) error
	ListApprovals(context.Context, Scope, string) ([]Approval, error)
	DecideApproval(context.Context, Scope, string, int, string, bool, string) (*Approval, error)
}
