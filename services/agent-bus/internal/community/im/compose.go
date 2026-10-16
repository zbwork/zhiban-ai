package im

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/community/config"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/conversation"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/convstate"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agentdirect"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contacts"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/wukongagent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientchat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientim"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/wukongwh"
	"io"
	"net/http"
	"time"
)

type accountLookup struct{ repo *account.Repo }

func (a accountLookup) AccountUUID(ctx context.Context, id int64) (string, error) {
	acc, err := a.repo.GetByID(ctx, id)
	if err != nil {
		return "", err
	}
	if acc == nil {
		return "", fmt.Errorf("account unavailable")
	}
	return acc.UUID, nil
}

type agentLookup struct{ repo *agent.Repo }

func (a agentLookup) AgentByUUID(ctx context.Context, tenantID int64, uuid string) (agentdirect.AgentTarget, bool, error) {
	ag, err := a.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return agentdirect.AgentTarget{}, false, err
	}
	if ag == nil || ag.TenantID != tenantID {
		return agentdirect.AgentTarget{}, false, nil
	}
	return agentdirect.AgentTarget{ID: ag.ID, ExecutionLocus: ag.ExecutionLocus}, true, nil
}

type roomEnsurer struct{ repo *room.Repo }

func (r roomEnsurer) EnsureAgentDirectRoom(ctx context.Context, tenantID, accountID, agentID int64, channel string, channelType int) (int64, string, string, error) {
	out, err := r.repo.CreateDirectWithAgentPair(ctx, room.CreateDirectWithAgentPairInput{TenantID: tenantID, CallerID: accountID, AgentID: agentID, WuKongChannelID: channel, WuKongChannelType: channelType})
	if err != nil {
		return 0, "", "", err
	}
	conv, err := r.repo.ConversationUUIDByRoomID(ctx, out.Room.ID)
	return out.Room.ID, out.Room.UUID, conv, err
}

type strictMembership struct{ repo *room.Repo }

func (m strictMembership) CheckChannelMembership(ctx context.Context, tenantID, accountID int64, channel string) (bool, bool, error) {
	linked, allowed, err := m.repo.ChannelMembership(ctx, tenantID, accountID, channel)
	return true, linked && allowed, err
}

// The persistent trigger/shadow transaction supplies idempotency. Retried webhooks
// must reach that gate; marking an in-memory key before a failed sink would lose retries.
type persistentGate struct{}

func (persistentGate) SeenOrMark(context.Context, string) (bool, error) { return true, nil }

func decode(w http.ResponseWriter, r *http.Request, out any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(out); err != nil {
		return err
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return fmt.Errorf("expected one JSON value")
	}
	return nil
}
func Register(mux *http.ServeMux, pool *pgxpool.Pool, c config.Config, chatSvc chat.Service, visibility contacts.Service, auth func(http.Handler) http.Handler) {
	list := &clientchat.ListHandler{Chat: chatSvc}
	mux.Handle("GET /api/agent-bus/v1/chat/conversations", auth(http.HandlerFunc(list.List)))
	if c.WuKong.URL == "" {
		return
	}
	lookup := accountLookup{account.New(pool)}
	adapter := wukong.NewAdapter(c.WuKong.URL, c.WuKong.TCPAddr, c.WuKong.WSAddr, nil)
	mapper := wukong.NewDirectRoomMapper(adapter, lookup)
	rooms := room.New(pool)
	prepare := agentdirect.NewPrepareService(true, agentLookup{agent.New(pool)}, visibility, agentdirect.New(mapper, roomEnsurer{rooms}))
	trigger := wukongagent.New(pool, chatSvc, visibility, adapter.Client())
	syncProxy := wukong.NewMessageSyncProxy(adapter.Client(), lookup)
	syncProxy.SetMembershipChecker(strictMembership{rooms})
	list.WuKongMsgSync = syncProxy
	list.WuKongConvSync = wukong.NewConversationSyncProxy(adapter.Client(), lookup)
	credential := &clientim.Handlers{WuKongCred: wukong.NewCredentialIssuer(adapter, lookup)}
	mux.Handle("POST /api/agent-bus/v1/im/credentials", auth(http.HandlerFunc(credential.Issue)))
	mux.Handle("POST /api/agent-bus/v1/chat/agent-direct/prepare-wukong", auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AgentUUID string `json:"agent_uuid"`
		}
		if err := decode(w, r, &in); err != nil || in.AgentUUID == "" {
			encode.JSONError(w, apperr.ErrInvalidParams)
			return
		}
		result, err := prepare.Prepare(r.Context(), middleware.MustTenantID(r.Context()), middleware.MustAccountID(r.Context()), in.AgentUUID)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, map[string]any{"conversation_uuid": result.ConversationUUID, "room_uuid": result.RoomUUID, "wukong_channel_id": result.ChannelID, "wukong_channel_type": result.ChannelType, "agent_uuid": in.AgentUUID})
	})))
	mux.Handle("POST /api/agent-bus/v1/chat/agent-direct/attach-stream", auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			ConversationUUID string `json:"conversation_uuid"`
			Channel          string `json:"wukong_channel_id"`
			Message          string `json:"wukong_message_id"`
			ClientMsgNo      string `json:"client_msg_no,omitempty"`
		}
		if err := decode(w, r, &in); err != nil || in.ConversationUUID == "" || in.Channel == "" || in.Message == "" {
			encode.JSONError(w, apperr.ErrInvalidParams)
			return
		}
		out, err := trigger.Attach(r.Context(), middleware.MustTenantID(r.Context()), middleware.MustAccountID(r.Context()), in.ConversationUUID, in.Channel, in.Message)
		if err != nil {
			if errors.Is(err, wukong.ErrNotDirectChannel) || errors.Is(err, wukong.ErrTenantMismatch) || errors.Is(err, wukong.ErrRoomNotFound) || errors.Is(err, wukong.ErrSenderNotInRoom) {
				encode.JSONError(w, apperr.ErrForbidden)
			} else {
				encode.JSONError(w, err)
			}
			return
		}
		encode.JSON(w, out)
	})))
	mux.Handle("POST /api/agent-bus/v1/im/wukong/messagesync", auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Channel          string `json:"channel_id"`
			ChannelType      int    `json:"channel_type"`
			Start            int    `json:"start_message_seq"`
			End              int    `json:"end_message_seq"`
			Limit            int    `json:"limit"`
			PullMode         int    `json:"pull_mode"`
			ConversationUUID string `json:"conversation_uuid,omitempty"`
		}
		if err := decode(w, r, &in); err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams)
			return
		}
		var clearedAt *time.Time
		if in.ConversationUUID != "" {
			tenantID, accountID := middleware.MustTenantID(r.Context()), middleware.MustAccountID(r.Context())
			convs := conversation.New(pool)
			allowed, err := convs.AccessibleByAccount(r.Context(), tenantID, accountID, in.ConversationUUID)
			if err != nil {
				encode.JSONError(w, err)
				return
			}
			if !allowed {
				encode.JSONError(w, apperr.ErrForbidden)
				return
			}
			conv, err := convs.GetByUUID(r.Context(), in.ConversationUUID)
			if err != nil {
				encode.JSONError(w, err)
				return
			}
			if conv.RoomID == nil {
				encode.JSONError(w, apperr.ErrForbidden)
				return
			}
			linkedRoom, err := rooms.GetByID(r.Context(), *conv.RoomID)
			if err != nil {
				encode.JSONError(w, err)
				return
			}
			if linkedRoom == nil || linkedRoom.WuKongChannelID != in.Channel || linkedRoom.WuKongChannelType != in.ChannelType {
				encode.JSONError(w, apperr.ErrForbidden)
				return
			}
			clearedAt, err = convstate.New(pool).ClearedAt(r.Context(), accountID, tenantID, in.ConversationUUID)
			if err != nil {
				encode.JSONError(w, err)
				return
			}
		}
		raw, err := syncProxy.Sync(r.Context(), middleware.MustTenantID(r.Context()), middleware.MustAccountID(r.Context()), in.Channel, in.ChannelType, in.Start, in.End, in.Limit, in.PullMode)
		if err != nil {
			if errors.Is(err, wukong.ErrNotMember) || errors.Is(err, wukong.ErrCrossTenant) {
				encode.JSONError(w, apperr.ErrForbidden)
			} else {
				encode.JSONError(w, apperr.New(apperr.UpstreamUnavailable, "im unavailable"))
			}
			return
		}
		var data any
		if err := json.Unmarshal(raw, &data); err != nil {
			encode.JSONError(w, apperr.New(apperr.UpstreamUnavailable, "invalid im response"))
			return
		}
		if clearedAt != nil {
			data = wukong.FilterSyncMessagesAfter(data, *clearedAt)
		}
		encode.JSON(w, data)
	})))
	mux.Handle("POST "+wukongwh.WebhookPath, &wukongwh.Handler{Secret: c.WuKong.Token, Idem: persistentGate{}, Sink: trigger, PropagateSinkErrors: true})
}
