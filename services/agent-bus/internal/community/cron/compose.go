// Package cron assembles the shared scheduler with community chat execution.
package cron

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	communitychat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/chat"
	domcron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/cron"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/conversation"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/cron"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/message"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/cron"
	"time"
)

func Compose(ctx context.Context, pool *pgxpool.Pool, chatSvc chat.Service, visibility svc.ContactsVisibility, direct svc.DirectConversationEnsurer) svc.Service {
	runner := &chatRunner{ctx: ctx, chat: chatSvc}
	service := svc.New(svc.Deps{Repo: repo.NewCommunity(pool), Agents: agent.New(pool), Conversations: conversation.New(pool), Messages: message.New(pool), Visibility: activeVisibility{visibility, account.New(pool)}, Runtime: communitychat.NewFrameworkLookup(pool), Rooms: room.New(pool), DirectConversations: direct, Runner: runner, NodeID: "community-" + uuid.NewString(), Config: svc.Config{DisableRuntimeProjection: true}})
	runner.service = service
	return service
}

type chatRunner struct {
	ctx     context.Context
	chat    chat.Service
	service svc.Service
}

func (r *chatRunner) RunAgentForConversation(ctx context.Context, in svc.ChatRunInput) (*svc.ChatRunOutput, error) {
	out, err := r.chat.RunAgentForConversation(ctx, chat.RunAgentInput{AccountID: in.AccountID, TenantID: in.TenantID, Conversation: in.Conversation, Agent: in.Agent, PromptText: in.PromptText, TriggerMessageUUID: &in.TriggerMessageUUID, CronRunUUID: in.RunUUID})
	if err != nil {
		return nil, err
	}
	watch, cancel := context.WithTimeout(r.ctx, 15*time.Minute)
	events, unsub, err := r.chat.SubscribeWithOwner(watch, in.AccountID, in.TenantID, out.StreamID)
	if err != nil {
		cancel()
		return nil, errors.New("cron execution stream subscription failed")
	}
	go func() {
		defer cancel()
		defer unsub()
		status, reason := domcron.RunStatusFailed, "execution stream closed without terminal event"
		defer func() {
			// A cancelled execution context must not prevent persistence of its terminal state.
			finish, done := context.WithTimeout(context.WithoutCancel(r.ctx), 10*time.Second)
			defer done()
			r.service.HandleRunStreamTerminal(finish, in.RunUUID, in.TriggerMessageUUID, status, reason)
		}()
		for {
			select {
			case <-watch.Done():
				reason = "execution timeout or service stopped"
				return
			case ev, ok := <-events:
				if !ok {
					return
				}
				if !ev.IsTerminal() {
					continue
				}
				switch ev.Kind {
				case chat.EventMessageCompleted:
					status, reason = domcron.RunStatusSucceeded, ""
				case chat.EventMessageCancelled:
					status, reason = domcron.RunStatusCancelled, ""
				default:
					reason = ev.ErrorMessage
					if reason == "" {
						reason = "agent execution failed"
					}
				}
				return
			}
		}
	}()
	return &svc.ChatRunOutput{StreamID: out.StreamID, AgentMessageUUID: out.AgentMessageUUID, FinalizeDeferred: true}, nil
}

// Scheduler calls have no HTTP middleware: recheck membership on every execution.
type activeVisibility struct {
	visibility svc.ContactsVisibility
	accounts   *account.Repo
}

func (v activeVisibility) AssertAgentVisible(ctx context.Context, accountID, tenantID int64, agentUUID string) error {
	member, err := v.accounts.GetMembership(ctx, accountID, tenantID)
	if err != nil || member == nil || member.Status != "active" {
		return apperr.ErrForbidden
	}
	return v.visibility.AssertAgentVisible(ctx, accountID, tenantID, agentUUID)
}
