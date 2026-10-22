package app

import (
	"context"
	"errors"
)

func (s *Service) WorkspaceApps(ctx context.Context, accountID, tenantID int64) ([]map[string]any, error) {
	if accountID <= 0 || tenantID <= 0 {
		return nil, errors.New("workspace identity required")
	}
	repo, ok := s.deps.Apps.(interface {
		WorkspaceApps(context.Context, int64, int64) ([]map[string]any, error)
	})
	if !ok {
		return nil, errors.New("workspace repository unavailable")
	}
	return repo.WorkspaceApps(ctx, accountID, tenantID)
}
