// Package localmedia owns run-scoped, at-most-once image submissions.
package localmedia

import (
	"context"
	"errors"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"net/http"
)

const MaxImageBytes = 12 << 20

var (
	ErrInvalid     = errors.New("local.image_invalid")
	ErrCredits     = errors.New("local.image_credit_unavailable")
	ErrUnavailable = errors.New("local.image_unavailable")
	ErrRejected    = errors.New("local.image_rejected")
	ErrUnknown     = errors.New("local.media_reconcile_required")
	ErrConflict    = errors.New("local.media_conflict")
)

type Request struct {
	OperationID string `json:"operation_id"`
	Model       string `json:"model"`
	Prompt      string `json:"prompt"`
	Size        string `json:"size"`
}
type Record struct {
	ID, Digest, State string
	Image             []byte
}
type Repository interface {
	Claim(context.Context, *local.Task, string, string) (*Record, bool, error)
	Complete(context.Context, *local.Task, string, []byte) error
	Uncertain(context.Context, *local.Task, string) error
	Reject(context.Context, *local.Task, string) error
	ExpireResults(context.Context) error
}

// Prepare validates the current model binding. Credentials never cross this interface.
type Provider interface {
	PrepareLocalImage(context.Context, *local.Task, Request) (func(context.Context) (*http.Response, error), error)
}
