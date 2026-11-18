package locala2a

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domlocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/a2aapproval"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/a2a"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
)

type Service struct {
	Repo         *repo.Repo
	Agents       domagent.Repository
	Capabilities a2a.CapabilityRepo
	Local        *localruntime.Service
	Chat         chat.Service
	Visibility   interface {
		AssertAgentVisible(context.Context, int64, int64, string) error
	}
}

func (s *Service) target(ctx context.Context, tenantID, accountID, fromID, toID int64) (*domagent.DigitalEmployee, error) {
	from, err := s.Agents.GetByID(ctx, fromID)
	if err != nil {
		return nil, err
	}
	to, err := s.Agents.GetByID(ctx, toID)
	if err != nil {
		return nil, err
	}
	if from.ID == to.ID || from.ExecutionLocus != "local" || to.ExecutionLocus != "local" || from.Status != "published" || to.Status != "published" {
		return nil, apperr.ErrForbidden
	}
	for _, employee := range []*domagent.DigitalEmployee{from, to} {
		if err := s.Visibility.AssertAgentVisible(ctx, accountID, tenantID, employee.UUID); err != nil {
			return nil, err
		}
	}
	enabled, err := s.Capabilities.HasA2AInvokeCapability(ctx, fromID)
	if err != nil {
		return nil, err
	}
	if !enabled || !a2a.EvaluateWhitelist(a2a.WhitelistInput{
		FromAgentID: from.UUID, FromAgentWorkspc: from.WorkspaceID, ToAgentID: to.UUID, ToAgentWorkspc: to.WorkspaceID,
		ToCallable: a2a.ParseCallablePolicy(to.CallableByAgentsJSON),
	}) {
		return nil, apperr.New(apperr.Forbidden, "数字员工未获准发起这次协作")
	}
	return to, nil
}

func (s *Service) Request(ctx context.Context, task *domlocal.Task, target, prompt string) (string, error) {
	target, prompt = strings.TrimSpace(target), strings.TrimSpace(prompt)
	if target == "" || len([]rune(target)) > 128 || prompt == "" || len([]rune(prompt)) > 4000 || task.Status != "accepted" {
		return "", apperr.ErrInvalidParams
	}
	var payload map[string]any
	if json.Unmarshal(task.Payload, &payload) != nil || payload["local_collaboration_child"] == true {
		return "", apperr.ErrForbidden
	}
	id, err := s.Repo.LocalTargetByName(ctx, task.Scope.TenantID, target)
	if err != nil {
		return "", err
	}
	if _, err = s.target(ctx, task.Scope.TenantID, task.Scope.AccountID, task.EmployeeID, id); err != nil {
		return "", err
	}
	return s.Repo.RequestLocal(ctx, task, id, prompt)
}

func (s *Service) Run(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	var sweepAfter time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		if time.Now().After(sweepAfter) {
			if err := s.Repo.SweepLocal(ctx); err != nil {
				log.Default().Warn(ctx, "local collaboration expiry check failed", "error", err)
			}
			if err := s.Repo.RecoverLocal(ctx); err != nil {
				log.Default().Warn(ctx, "local collaboration recovery failed", "error", err)
			}
			sweepAfter = time.Now().Add(15 * time.Second)
		}
		job, err := s.Repo.ClaimLocal(ctx)
		if err != nil {
			log.Default().Warn(ctx, "local collaboration queue read failed", "error", err)
			continue
		}
		if job != nil {
			s.dispatch(ctx, job)
		}
	}
}

func (s *Service) dispatch(parent context.Context, job *repo.LocalJob) {
	ctx, cancel := context.WithTimeout(parent, domlocal.CollaborationObservationTimeout)
	defer cancel()
	status, code, result := s.execute(ctx, job)
	if status == "" {
		// A lost observer does not determine the durable target run's outcome.
		return
	}
	fin, stop := context.WithTimeout(context.WithoutCancel(parent), 5*time.Second)
	defer stop()
	if err := s.Repo.FinishLocal(fin, job, status, code, result); err != nil {
		log.Default().Warn(fin, "local collaboration finalization could not be persisted", "edge", job.EdgeUUID, "error", err)
	}
}

func (s *Service) execute(ctx context.Context, job *repo.LocalJob) (doma2a.Status, string, []byte) {
	valid, err := s.Repo.LocalJobStillValid(ctx, job)
	if err != nil || !valid {
		return doma2a.StatusFailed, "a2a.local_authorization_expired", nil
	}
	to, err := s.target(ctx, job.TenantID, job.AccountID, job.SourceAgentID, job.TargetAgentID)
	if err != nil {
		return doma2a.StatusFailed, "a2a.local_target_unavailable", nil
	}
	scope := domlocal.Scope{AccountID: job.AccountID, TenantID: job.TenantID, SessionUUID: job.Session}
	device, err := s.Local.ResolveDesktop(ctx, scope, job.Device)
	if err != nil || device.Scope != scope || device.UUID != job.Device {
		return doma2a.StatusFailed, "a2a.local_device_unavailable", nil
	}
	sent, err := s.Chat.Send(ctx, job.AccountID, job.TenantID, chat.SendReq{
		AgentUUID: to.UUID, Text: job.Prompt, LocalLoginSessionUUID: job.Session, LocalDeviceUUID: job.Device,
		LocalCollaborationChild: true, LocalCollaborationEdgeUUID: job.EdgeUUID,
	})
	if err != nil {
		return doma2a.StatusFailed, "a2a.local_dispatch_failed", nil
	}
	sub, closeStream, err := s.Chat.SubscribeWithOwner(ctx, job.AccountID, job.TenantID, sent.StreamID)
	if err != nil {
		return "", "", nil
	}
	defer closeStream()
	for {
		select {
		case <-ctx.Done():
			return "", "", nil
		case ev, ok := <-sub:
			if !ok {
				return "", "", nil
			}
			switch ev.Kind {
			case chat.EventMessageCompleted:
				result, _ := json.Marshal(map[string]string{"target_message_uuid": sent.AgentMessageUUID, "target_conversation_uuid": sent.ConversationUUID})
				return doma2a.StatusDone, "", result
			case chat.EventMessageFailed, chat.EventMessageAwaitingUser:
				return doma2a.StatusFailed, "a2a.local_execution_failed", nil
			case chat.EventMessageCancelled:
				return doma2a.StatusCancelled, "a2a.local_execution_cancelled", nil
			}
		}
	}
}
