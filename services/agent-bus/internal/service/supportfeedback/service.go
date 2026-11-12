package supportfeedback

import (
	"context"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/supportfeedback"
)

type Service interface {
	Create(ctx context.Context, in dom.CreateInput) (*dom.Feedback, error)
	LastByConversationBeforeMessage(ctx context.Context, conversationID, beforeMessageID int64) (*dom.Feedback, error)
	ListPlatform(ctx context.Context, f dom.Filter) ([]dom.Feedback, int64, error)
	UpdatePlatform(ctx context.Context, uuid string, actorID int64, in dom.UpdateInput) (*dom.Feedback, error)
}

type impl struct {
	repo dom.Repository
}

func New(repo dom.Repository) Service {
	return &impl{repo: repo}
}

func (s *impl) Create(ctx context.Context, in dom.CreateInput) (*dom.Feedback, error) {
	in.Title = strings.TrimSpace(in.Title)
	in.Description = strings.TrimSpace(in.Description)
	in.PageURL = strings.TrimSpace(in.PageURL)
	if in.Source == "" {
		in.Source = dom.SourceAgentChat
	}
	if in.Category == "" {
		in.Category = dom.CategoryOther
	}
	if in.Priority == "" {
		in.Priority = dom.PriorityNormal
	}
	if in.Status == "" {
		in.Status = dom.StatusOpen
	}
	if err := validateCreate(in); err != nil {
		return nil, err
	}
	return s.repo.Create(ctx, in)
}

func (s *impl) LastByConversationBeforeMessage(ctx context.Context, conversationID, beforeMessageID int64) (*dom.Feedback, error) {
	return s.repo.LastByConversationBeforeMessage(ctx, conversationID, beforeMessageID)
}

func (s *impl) ListPlatform(ctx context.Context, f dom.Filter) ([]dom.Feedback, int64, error) {
	f.Keyword = strings.TrimSpace(f.Keyword)
	if f.Status != "" && !dom.ValidStatus(f.Status) {
		return nil, 0, dom.ErrInvalidStatus
	}
	if f.Category != "" && !dom.ValidCategory(f.Category) {
		return nil, 0, dom.ErrInvalidCategory
	}
	if f.Priority != "" && !dom.ValidPriority(f.Priority) {
		return nil, 0, dom.ErrInvalidPriority
	}
	if f.Limit <= 0 || f.Limit > 100 {
		f.Limit = 20
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	return s.repo.ListPlatform(ctx, f)
}

func (s *impl) UpdatePlatform(ctx context.Context, uuid string, actorID int64, in dom.UpdateInput) (*dom.Feedback, error) {
	in.HandlerNote = strings.TrimSpace(in.HandlerNote)
	if in.Status != "" && !dom.ValidStatus(in.Status) {
		return nil, dom.ErrInvalidStatus
	}
	if in.Priority != "" && !dom.ValidPriority(in.Priority) {
		return nil, dom.ErrInvalidPriority
	}
	if in.AssignedToSet && in.AssignedTo != nil && *in.AssignedTo <= 0 {
		return nil, dom.ErrInvalidAssignee
	}
	return s.repo.UpdatePlatform(ctx, uuid, actorID, in)
}

func validateCreate(in dom.CreateInput) error {
	if in.TenantID <= 0 {
		return dom.ErrMissingTenant
	}
	if in.Title == "" {
		return dom.ErrMissingTitle
	}
	if in.Description == "" {
		return dom.ErrMissingBody
	}
	if len(in.Attachments) > dom.MaxAttachments {
		return dom.ErrTooManyFiles
	}
	if !dom.ValidSource(in.Source) {
		return dom.ErrInvalidSource
	}
	if !dom.ValidCategory(in.Category) {
		return dom.ErrInvalidCategory
	}
	if !dom.ValidPriority(in.Priority) {
		return dom.ErrInvalidPriority
	}
	if !dom.ValidStatus(in.Status) {
		return dom.ErrInvalidStatus
	}
	return nil
}
