package messagereceipts

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// WKReadReceiptSignalContentType 是 EasyO 已读水位实时刷新信号。
//
// 与 RTC 1001 / revoke 98 / mixed 110 / agent final 111 分离。该类型只作为
// WuKong no_persist 临时消息进入在线长连接,客户端必须旁路消费,不得渲染成普通聊天消息。
const WKReadReceiptSignalContentType = 1002

// ReadReceiptNotifier markRead 后的 best-effort 在线通知。
type ReadReceiptNotifier interface {
	NotifyReadReceiptChanged(ctx context.Context, in NotifyReadReceiptChangedIn) error
}

type NotifyReadReceiptChangedIn struct {
	TenantID           int64
	ReaderAccountID    int64
	ConversationUUID   string
	LastReadMessageSeq int64
}

// EphemeralSender 是 wukong.Client.SendEphemeralNotification 的窄接口。
type EphemeralSender interface {
	SendEphemeralNotification(ctx context.Context, fromUID, channelID string, channelType int, payload []byte) (messageID int64, err error)
}

type readReceiptNotifier struct {
	conv   ConvLookup
	sender EphemeralSender
}

func NewReadReceiptNotifier(conv ConvLookup, sender EphemeralSender) ReadReceiptNotifier {
	return &readReceiptNotifier{conv: conv, sender: sender}
}

type readReceiptSignalPayload struct {
	Type               int    `json:"type"`
	Version            int    `json:"version"`
	Kind               string `json:"kind"`
	ConversationUUID   string `json:"conversation_uuid"`
	LastReadMessageSeq int64  `json:"last_read_message_seq"`
	ReaderUID          string `json:"reader_uid"`
	Timestamp          string `json:"ts"`
}

func (n *readReceiptNotifier) NotifyReadReceiptChanged(ctx context.Context, in NotifyReadReceiptChangedIn) error {
	if n == nil || n.conv == nil || n.sender == nil {
		return nil
	}
	if in.TenantID <= 0 || in.ReaderAccountID <= 0 || in.ConversationUUID == "" || in.LastReadMessageSeq <= 0 {
		return apperr.ErrInvalidParams.Withf("read receipt notify: invalid args")
	}
	channelID, channelType, readerAccountUUID, err := n.conv.ResolveChannelAndCaller(ctx, in.TenantID, in.ReaderAccountID, in.ConversationUUID)
	if err != nil {
		return err
	}
	if channelID == "" || channelType <= 0 {
		return apperr.ErrInvalidParams.Withf("read receipt notify: conversation has no WuKong channel")
	}
	if channelType == 1 {
		return apperr.ErrInvalidParams.Withf("read receipt notify: person channel type=1 is not supported; use EasyO room/group channel")
	}
	if readerAccountUUID == "" {
		return apperr.ErrInternal.Withf("read receipt notify: reader account uuid lookup empty")
	}
	readerUID := wukong.UserUID(in.TenantID, readerAccountUUID)
	payload, err := json.Marshal(readReceiptSignalPayload{
		Type:               WKReadReceiptSignalContentType,
		Version:            1,
		Kind:               "read_receipt.changed",
		ConversationUUID:   in.ConversationUUID,
		LastReadMessageSeq: in.LastReadMessageSeq,
		ReaderUID:          readerUID,
		Timestamp:          time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		return fmt.Errorf("read receipt notify: marshal: %w", err)
	}
	_, err = n.sender.SendEphemeralNotification(ctx, readerUID, channelID, channelType, payload)
	return err
}
