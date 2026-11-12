package clientanalytics

import (
	"context"
	"math"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientanalytics"
)

type OverviewService interface {
	Overview(ctx context.Context, days int, includeArchived bool) (*dom.Overview, error)
}

type overviewService struct {
	repo dom.OverviewReader
	now  func() time.Time
}

func NewOverview(repo dom.OverviewReader) OverviewService {
	return &overviewService{repo: repo, now: time.Now}
}

func (s *overviewService) Overview(ctx context.Context, days int, includeArchived bool) (*dom.Overview, error) {
	if days != 7 && days != 30 && days != 90 {
		return nil, dom.ErrInvalidRange
	}
	now := s.now().UTC()
	out, err := s.repo.Overview(ctx, days, now, includeArchived)
	if err != nil {
		return nil, err
	}
	out.GeneratedAt = now
	out.Timezone = "Asia/Shanghai"
	out.RangeDays = days
	if out.MAU > 0 {
		out.StickinessPct = math.Round(float64(out.DAU)/float64(out.MAU)*1000) / 10
	}
	return out, nil
}

type ErrorAdminService interface {
	ErrorDetail(ctx context.Context, fingerprint string) (*dom.ErrorDetail, error)
	ArchiveError(ctx context.Context, fingerprint string, accountID int64) error
	UnarchiveError(ctx context.Context, fingerprint string) error
}

type errorAdminService struct {
	repo dom.ErrorAdminRepository
}

func NewErrorAdmin(repo dom.ErrorAdminRepository) ErrorAdminService {
	return &errorAdminService{repo: repo}
}

func (s *errorAdminService) ErrorDetail(ctx context.Context, fingerprint string) (*dom.ErrorDetail, error) {
	return s.repo.ErrorDetail(ctx, fingerprint)
}

func (s *errorAdminService) ArchiveError(ctx context.Context, fingerprint string, accountID int64) error {
	return s.repo.ArchiveError(ctx, fingerprint, accountID)
}

func (s *errorAdminService) UnarchiveError(ctx context.Context, fingerprint string) error {
	return s.repo.UnarchiveError(ctx, fingerprint)
}
