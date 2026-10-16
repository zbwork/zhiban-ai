package wukongagent

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agenttrigger"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/conversation"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
	outboxrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/wukongoutbox"
	outboxsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/wukongoutbox"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/wukongwh"
)

// Trigger shares the existing transactional shadow/run gate with webhook and attach.
type Trigger struct{ inner *wukongAgentTrigger }
type AttachResult struct {
	StreamID         string `json:"stream_id"`
	AgentMessageUUID string `json:"agent_message_uuid"`
	ConversationUUID string `json:"conversation_uuid"`
	Status           string `json:"status"`
	RetryAfterMS     int    `json:"retry_after_ms,omitempty"`
}

func New(pool *pgxpool.Pool, chat wkChatRunner, contacts wkContacts, sender *wukong.Client) *Trigger {
	deps := wukongAgentTriggerDeps{logger: log.Default(), rooms: room.New(pool), accounts: account.New(pool), agents: agent.New(pool), convs: conversation.New(pool), triggers: agenttrigger.New(pool), contacts: contacts, chat: chat, sender: sender, readReceipt: sender, agentDirectEnabled: true, agentDirectLookup: agentDirectRoomLookupAdapter{rooms: room.New(pool)}}
	deps.outbox = outboxsvc.NewService(outboxrepo.New(pool))
	return &Trigger{inner: &wukongAgentTrigger{d: deps}}
}
func (t *Trigger) OnMessage(ctx context.Context, ev wukongwh.Event) error {
	return t.inner.OnMessage(ctx, ev)
}
func (t *Trigger) Attach(ctx context.Context, tenantID, accountID int64, convUUID, channelID, messageID string) (*AttachResult, error) {
	result, err := t.inner.attachAgentDirectStream(ctx, ensureAgentDirectRunInput{TenantID: tenantID, CallerAccountID: accountID, ExpectedConversationUUID: convUUID, ChannelID: channelID, MessageID: messageID})
	if err != nil {
		return nil, err
	}
	out := &AttachResult{StreamID: result.StreamID, AgentMessageUUID: result.AgentMessageUUID, ConversationUUID: result.ConversationUUID, Status: result.Status}
	if result.Status == adrStatusPending {
		out.RetryAfterMS = 500
	}
	return out, nil
}
