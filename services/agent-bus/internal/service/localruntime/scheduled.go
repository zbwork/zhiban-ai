package localruntime

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

// ResolveScheduledDesktop is deliberately not exposed by the client HTTP API.
func (s *Service) ResolveScheduledDesktop(ctx context.Context, accountID, tenantID int64) (*dom.Device, error) {
	r, ok := s.repo.(interface {
		ResolveScheduledDesktop(context.Context, int64, int64) (*dom.Device, error)
	})
	if !ok {
		return nil, dom.ErrOffline
	}
	return r.ResolveScheduledDesktop(ctx, accountID, tenantID)
}
