package localruntime

import (
	"context"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

func (s *Service) remote() (dom.RemoteRepository, error) {
	r, ok := s.repo.(dom.RemoteRepository)
	if !ok {
		return nil, dom.ErrOffline
	}
	return r, nil
}
func (s *Service) ResolveDesktop(ctx context.Context, caller dom.Scope, deviceID string) (*dom.Device, error) {
	r, err := s.remote()
	if err != nil {
		return nil, err
	}
	return r.ResolveDesktop(ctx, caller, deviceID)
}

func (s *Service) ConversationState(ctx context.Context, caller dom.Scope, conversation string) (map[string]string, error) {
	if _, err := uuid.Parse(conversation); err != nil {
		return nil, dom.ErrDenied
	}
	r, err := s.remote()
	if err != nil {
		return nil, err
	}
	return r.ConversationState(ctx, caller, conversation)
}
func (s *Service) requester(ctx context.Context, task *dom.Task) error {
	if task.RequesterSessionUUID == "" {
		return nil
	}
	r, err := s.remote()
	if err != nil {
		return err
	}
	return r.ValidateRequester(ctx, dom.Scope{AccountID: task.Scope.AccountID, TenantID: task.Scope.TenantID, SessionUUID: task.RequesterSessionUUID})
}

var approvalHash = regexp.MustCompile(`^[a-f0-9]{64}$`)
var approvalTool = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,100}$`)

func (s *Service) RegisterApproval(ctx context.Context, task *dom.Task, in dom.Approval) (*dom.Approval, error) {
	if _, err := uuid.Parse(in.ID); err != nil {
		return nil, dom.ErrDenied
	}
	if in.Revision <= 0 || !approvalHash.MatchString(in.IntentHash) || !approvalTool.MatchString(in.Display.Tool) || len(in.Display.Target) > 512 || strings.ContainsAny(in.Display.Target, "\x00\r\n/\\") || !in.ExpiresAt.After(time.Now()) || in.ExpiresAt.After(time.Now().Add(2*time.Minute)) || in.ExpiresAt.After(task.ExpiresAt) {
		return nil, dom.ErrDenied
	}
	switch in.Display.Operation {
	case "read", "write", "overwrite", "delete", "shell", "network", "browser", "desktop", "upload":
	default:
		return nil, dom.ErrDenied
	}
	in.Run = task.UUID
	in.Fence = task.Fence
	r, err := s.remote()
	if err != nil {
		return nil, err
	}
	return r.RegisterApproval(ctx, task, in)
}
func (s *Service) GetApproval(ctx context.Context, task *dom.Task, id string) (*dom.Approval, error) {
	r, err := s.remote()
	if err != nil {
		return nil, err
	}
	return r.GetApproval(ctx, task, id)
}
func (s *Service) ExpireApproval(ctx context.Context, task *dom.Task, id string) error {
	r, err := s.remote()
	if err != nil {
		return err
	}
	return r.ExpireApproval(ctx, task, id)
}
func (s *Service) ListApprovals(ctx context.Context, caller dom.Scope, conversation string) ([]dom.Approval, error) {
	if _, err := uuid.Parse(conversation); conversation != "" && err != nil {
		return nil, dom.ErrDenied
	}
	r, err := s.remote()
	if err != nil {
		return nil, err
	}
	return r.ListApprovals(ctx, caller, conversation)
}
func (s *Service) DecideApproval(ctx context.Context, caller dom.Scope, id string, revision int, hash string, approved bool, grant string) (*dom.Approval, error) {
	if _, err := uuid.Parse(id); err != nil {
		return nil, dom.ErrDenied
	}
	if revision <= 0 || !approvalHash.MatchString(hash) || (grant != "once" && grant != "task") {
		return nil, dom.ErrDenied
	}
	r, err := s.remote()
	if err != nil {
		return nil, err
	}
	return r.DecideApproval(ctx, caller, id, revision, hash, approved, grant)
}
