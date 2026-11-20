package a2a

import (
	"context"
	"testing"

	domapproval "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2aapproval"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func TestApproveWithoutRuntimeDoesNotDecidePending(t *testing.T) {
	s := &Service{deps: Deps{
		// This stub panics on any repository call. Approval must stop before a write.
		Approvals:    struct{ domapproval.Repository }{},
		AgentInvoker: NoopAgentInvoker{},
	}}
	_, err := s.DecideApproval(context.Background(), ApprovalDecisionInput{
		TenantID: 1, ActorAccountID: 2, ApprovalUUID: "fixture", Decision: domapproval.StatusApproved, AdminOverride: true,
	})
	e, ok := apperr.AsError(err)
	if !ok || e.Code != apperr.PreconditionFailed {
		t.Fatalf("expected precondition error before calling repository, got %v", err)
	}
}
