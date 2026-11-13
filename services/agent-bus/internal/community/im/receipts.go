package im

import (
	"context"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/account"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/conversation"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/clientchat"
	"net/http"
)

func registerConversationState(mux *http.ServeMux, state *clientchat.StateHandlers, auth func(http.Handler) http.Handler) {
	mux.Handle("POST /api/agent-bus/v1/chat/conversations/{uuid}/read", auth(http.HandlerFunc(state.MarkConversationRead)))
	mux.Handle("POST /api/agent-bus/v1/chat/conversations/{uuid}/show", auth(http.HandlerFunc(state.ShowConversationForAccount)))
}
func registerReadReceipts(mux *http.ServeMux, receipts *clientchat.ReadReceiptsHandlers, auth func(http.Handler) http.Handler) {
	mux.Handle("GET /api/agent-bus/v1/chat/conversations/{uuid}/read-receipts", auth(http.HandlerFunc(receipts.GetReadReceipts)))
}

type messageReceiptsConvLookup struct {
	convs *conversation.Repo
	rooms *room.Repo
	accts *account.Repo
}

func (l messageReceiptsConvLookup) AccessibleByAccount(ctx context.Context, tenantID, accountID int64, conversationUUID string) (bool, error) {
	return l.convs.AccessibleByAccount(ctx, tenantID, accountID, conversationUUID)
}

func (l messageReceiptsConvLookup) ResolveChannelAndCaller(ctx context.Context, tenantID, callerAccountID int64, conversationUUID string) (channelID string, channelType int, callerAccountUUID string, err error) {
	conv, err := l.convs.GetByUUID(ctx, conversationUUID)
	if err != nil {
		return "", 0, "", err
	}
	if conv.TenantID != tenantID {
		return "", 0, "", apperr.ErrForbidden.Withf("read_receipts: tenant mismatch")
	}
	if conv.RoomID == nil {
		return "", 0, "", apperr.ErrInvalidParams.Withf("conversation has no WuKong room; agent_direct / legacy single not supported")
	}
	rm, err := l.rooms.GetByID(ctx, *conv.RoomID)
	if err != nil {
		return "", 0, "", err
	}
	if rm == nil || rm.WuKongChannelID == "" || rm.WuKongChannelType <= 0 {
		return "", 0, "", apperr.ErrInvalidParams.Withf("room has no WuKong channel link")
	}
	callerAcc, err := l.accts.GetByID(ctx, callerAccountID)
	if err != nil {
		return "", 0, "", err
	}
	if callerAcc == nil {
		return "", 0, "", apperr.ErrInternal.Withf("caller account not found")
	}
	return rm.WuKongChannelID, rm.WuKongChannelType, callerAcc.UUID, nil
}
