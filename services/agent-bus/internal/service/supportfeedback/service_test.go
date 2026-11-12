package supportfeedback

import (
	"context"
	"errors"
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/supportfeedback"
)

func TestCreateFromAgentChatDefaultsAndValidates(t *testing.T) {
	t.Parallel()

	repo := &fakeRepo{}
	svc := New(repo)

	got, err := svc.Create(context.Background(), dom.CreateInput{
		TenantID:    10,
		AccountID:   ptrInt64(20),
		AgentID:     ptrInt64(30),
		Source:      "",
		Category:    "bug",
		Priority:    "",
		Title:       "上传文件失败",
		Description: "在企业云盘上传合同 PDF 时提示 500。",
		PageURL:     "/drive",
		ClientInfo:  map[string]any{"platform": "macos"},
		Attachments: []any{map[string]any{"file_uuid": "file-1", "name": "error.png"}},
	})
	if err != nil {
		t.Fatalf("Create returned error: %v", err)
	}
	if got.Status != dom.StatusOpen {
		t.Fatalf("status = %q, want %q", got.Status, dom.StatusOpen)
	}
	if got.Priority != dom.PriorityNormal {
		t.Fatalf("priority = %q, want %q", got.Priority, dom.PriorityNormal)
	}
	if repo.created.Source != dom.SourceAgentChat {
		t.Fatalf("source = %q, want %q", repo.created.Source, dom.SourceAgentChat)
	}
	if len(repo.created.Attachments) != 1 {
		t.Fatalf("attachments len = %d, want 1", len(repo.created.Attachments))
	}

	_, err = svc.Create(context.Background(), dom.CreateInput{
		TenantID:    10,
		Category:    "not-real",
		Title:       "分类错误",
		Description: "bad category",
	})
	if !errors.Is(err, dom.ErrInvalidCategory) {
		t.Fatalf("invalid category error = %v, want ErrInvalidCategory", err)
	}

	tooMany := make([]any, dom.MaxAttachments+1)
	_, err = svc.Create(context.Background(), dom.CreateInput{
		TenantID:    10,
		Category:    dom.CategoryBug,
		Title:       "附件过多",
		Description: "bad attachments",
		Attachments: tooMany,
	})
	if !errors.Is(err, dom.ErrTooManyFiles) {
		t.Fatalf("too many attachments error = %v, want ErrTooManyFiles", err)
	}
}

func TestUpdatePlatformValidatesStatusAndHandler(t *testing.T) {
	t.Parallel()

	repo := &fakeRepo{updated: dom.Feedback{UUID: "fb-1", Status: dom.StatusInProgress, Priority: dom.PriorityHigh}}
	svc := New(repo)

	got, err := svc.UpdatePlatform(context.Background(), "fb-1", 99, dom.UpdateInput{
		Status:      dom.StatusInProgress,
		Priority:    dom.PriorityHigh,
		HandlerNote: "已转研发排查",
	})
	if err != nil {
		t.Fatalf("UpdatePlatform returned error: %v", err)
	}
	if repo.updateUUID != "fb-1" || repo.updateActorID != 99 {
		t.Fatalf("update target = (%q,%d), want (fb-1,99)", repo.updateUUID, repo.updateActorID)
	}
	if got.Status != dom.StatusInProgress || got.Priority != dom.PriorityHigh {
		t.Fatalf("updated status/priority = %q/%q", got.Status, got.Priority)
	}

	_, err = svc.UpdatePlatform(context.Background(), "fb-1", 99, dom.UpdateInput{Status: "finished"})
	if !errors.Is(err, dom.ErrInvalidStatus) {
		t.Fatalf("invalid status error = %v, want ErrInvalidStatus", err)
	}
}

type fakeRepo struct {
	created       dom.CreateInput
	updated       dom.Feedback
	updateUUID    string
	updateActorID int64
}

func (r *fakeRepo) Create(ctx context.Context, in dom.CreateInput) (*dom.Feedback, error) {
	r.created = in
	return &dom.Feedback{
		UUID:        "fb-1",
		TenantID:    in.TenantID,
		AccountID:   in.AccountID,
		AgentID:     in.AgentID,
		Source:      in.Source,
		Category:    in.Category,
		Priority:    in.Priority,
		Status:      in.Status,
		Title:       in.Title,
		Description: in.Description,
		PageURL:     in.PageURL,
		ClientInfo:  in.ClientInfo,
		Attachments: in.Attachments,
	}, nil
}

func (r *fakeRepo) LastByConversationBeforeMessage(ctx context.Context, conversationID, beforeMessageID int64) (*dom.Feedback, error) {
	return nil, nil
}

func (r *fakeRepo) ListPlatform(ctx context.Context, f dom.Filter) ([]dom.Feedback, int64, error) {
	return nil, 0, nil
}

func (r *fakeRepo) UpdatePlatform(ctx context.Context, uuid string, actorID int64, in dom.UpdateInput) (*dom.Feedback, error) {
	r.updateUUID = uuid
	r.updateActorID = actorID
	r.updated.Status = in.Status
	r.updated.Priority = in.Priority
	r.updated.HandlerNote = in.HandlerNote
	return &r.updated, nil
}

func ptrInt64(v int64) *int64 { return &v }
