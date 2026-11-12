package downloadchannel

import (
	"context"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/downloadchannel"
)

type Service interface {
	List(ctx context.Context, f dom.Filter) ([]dom.ChannelWithStats, int64, error)
	ListShareGrowth(ctx context.Context, f dom.Filter) ([]dom.ShareGrowthItem, int64, error)
	Get(ctx context.Context, uuid string) (*dom.Channel, error)
	Create(ctx context.Context, in dom.UpsertInput) (*dom.Channel, error)
	Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Channel, error)
	Delete(ctx context.Context, uuid string, actorID int64) error
	RecordVisit(ctx context.Context, code, pageURL, ipHash, userAgent string) error
	RecordDownloadClick(ctx context.Context, code, platform, pageURL, ipHash, userAgent string) error
	Stats(ctx context.Context, f dom.Filter) (*dom.Stats, error)
	ShareGrowthStats(ctx context.Context, f dom.Filter) (*dom.ShareGrowthStats, error)
}

type impl struct {
	repo dom.Repository
}

func New(repo dom.Repository) Service {
	return &impl{repo: repo}
}

func (s *impl) List(ctx context.Context, f dom.Filter) ([]dom.ChannelWithStats, int64, error) {
	f.Status = normalize(f.Status)
	f.Keyword = strings.TrimSpace(f.Keyword)
	f.Kind = normalize(f.Kind)
	if f.Status != "" && !dom.ValidStatus(f.Status) {
		return nil, 0, dom.ErrInvalidStatus
	}
	if !dom.ValidFilterKind(f.Kind) {
		return nil, 0, dom.ErrInvalidKind
	}
	if f.Limit <= 0 || f.Limit > 100 {
		f.Limit = 20
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	return s.repo.List(ctx, f)
}

func (s *impl) ListShareGrowth(ctx context.Context, f dom.Filter) ([]dom.ShareGrowthItem, int64, error) {
	f, err := normalizeShareGrowthFilter(f)
	if err != nil {
		return nil, 0, err
	}
	if f.Limit <= 0 || f.Limit > 100 {
		f.Limit = 20
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	return s.repo.ListShareGrowth(ctx, f)
}

func (s *impl) Get(ctx context.Context, uuid string) (*dom.Channel, error) {
	return s.repo.GetByUUID(ctx, strings.TrimSpace(uuid))
}

func (s *impl) Create(ctx context.Context, in dom.UpsertInput) (*dom.Channel, error) {
	normalized, err := normalizeInput(in)
	if err != nil {
		return nil, err
	}
	return s.repo.Create(ctx, normalized)
}

func (s *impl) Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Channel, error) {
	normalized, err := normalizeInput(in)
	if err != nil {
		return nil, err
	}
	return s.repo.Update(ctx, strings.TrimSpace(uuid), normalized)
}

func (s *impl) Delete(ctx context.Context, uuid string, actorID int64) error {
	return s.repo.Delete(ctx, strings.TrimSpace(uuid), actorID)
}

func (s *impl) RecordVisit(ctx context.Context, code, pageURL, ipHash, userAgent string) error {
	code = normalize(code)
	if code == "" {
		return dom.ErrMissingCode
	}
	return s.repo.RecordEvent(ctx, dom.EventInput{
		ChannelCode: code,
		EventKind:   dom.EventKindVisit,
		PageURL:     strings.TrimSpace(pageURL),
		IPHash:      ipHash,
		UserAgent:   userAgent,
	})
}

func (s *impl) RecordDownloadClick(ctx context.Context, code, platform, pageURL, ipHash, userAgent string) error {
	code = normalize(code)
	if code == "" {
		return dom.ErrMissingCode
	}
	return s.repo.RecordEvent(ctx, dom.EventInput{
		ChannelCode: code,
		EventKind:   dom.EventKindDownloadClick,
		Platform:    normalize(platform),
		PageURL:     strings.TrimSpace(pageURL),
		IPHash:      ipHash,
		UserAgent:   userAgent,
	})
}

func (s *impl) Stats(ctx context.Context, f dom.Filter) (*dom.Stats, error) {
	f.Status = normalize(f.Status)
	f.Keyword = strings.TrimSpace(f.Keyword)
	f.Kind = normalize(f.Kind)
	if f.Status != "" && !dom.ValidStatus(f.Status) {
		return nil, dom.ErrInvalidStatus
	}
	if !dom.ValidFilterKind(f.Kind) {
		return nil, dom.ErrInvalidKind
	}
	return s.repo.Stats(ctx, f)
}

func (s *impl) ShareGrowthStats(ctx context.Context, f dom.Filter) (*dom.ShareGrowthStats, error) {
	f, err := normalizeShareGrowthFilter(f)
	if err != nil {
		return nil, err
	}
	return s.repo.ShareGrowthStats(ctx, f)
}

func normalizeShareGrowthFilter(f dom.Filter) (dom.Filter, error) {
	f.Status = normalize(f.Status)
	f.Keyword = strings.TrimSpace(f.Keyword)
	f.Kind = dom.KindUserShare
	if f.Status != "" && !dom.ValidStatus(f.Status) {
		return f, dom.ErrInvalidStatus
	}
	return f, nil
}

func normalizeInput(in dom.UpsertInput) (dom.UpsertInput, error) {
	in.Code = normalize(in.Code)
	in.Name = strings.TrimSpace(in.Name)
	in.Description = strings.TrimSpace(in.Description)
	in.Status = normalize(in.Status)
	if in.Code == "" {
		return in, dom.ErrMissingCode
	}
	if in.Name == "" {
		return in, dom.ErrMissingName
	}
	if in.Status == "" {
		in.Status = dom.StatusActive
	}
	if !dom.ValidStatus(in.Status) {
		return in, dom.ErrInvalidStatus
	}
	return in, nil
}

func normalize(v string) string {
	return strings.ToLower(strings.TrimSpace(v))
}
