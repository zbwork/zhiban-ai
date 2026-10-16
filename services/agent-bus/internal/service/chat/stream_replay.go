package chat

import "context"

// ReplayTerminalIfDone 消除"晚订阅竞态"：ZAP/dsh 等快 runtime 的回复可能在客户端订阅
// GET /chat/stream 之前就已发布终帧到 fanout。per-stream 的 Subscribe 不回放历史,
// 晚到的订阅者会挂在一条"已结束、永不再来帧"的通道上,界面卡在"处理中"(消息本身已落库/已投 IM,
// 重开会话即可见)。
//
// 用法(见 transport chatStream)：订阅成功后调本方法；返回非 nil 事件说明该 stream 已终态,
// 直接把它当作终帧发给客户端并结束,不要再阻塞读通道(通道里那帧已在订阅前流过,不会重复)。
// 返回 nil = 流仍活跃(或查不到),照常进读循环。
//
// 判据以**已落库的 agent 消息状态**为准(final/failed/cancelled),而不是 message_streams.state,
// 因为终帧内容(blocks/usage/error)在消息行上。streamStore/messages 未装 → 返回 nil(不影响老部署)。
func (s *impl) ReplayTerminalIfDone(ctx context.Context, streamID string) *StreamEvent {
	if s.messages == nil || streamID == "" {
		return nil
	}
	msg, err := s.messages.GetByStreamID(ctx, streamID)
	if err != nil || msg == nil || msg.Role != "agent" {
		return nil
	}
	kind, ok := terminalKindForStatus(msg.Status)
	if !ok {
		return nil
	}
	ev := StreamEvent{
		Kind:             kind,
		ConversationUUID: lookupConversationUUID(ctx, s, msg.ConversationID),
		MessageUUID:      msg.UUID,
		Role:             "agent",
		StreamID:         streamID,
		Final:            true,
	}
	if kind == EventMessageCompleted {
		ev.Blocks = msg.Blocks
		if u, ok := msg.Metadata["usage"].(map[string]any); ok {
			ev.Usage = u
		}
	}
	if msg.ErrorCode != "" {
		ev.ErrorCode = msg.ErrorCode
	}
	if msg.ErrorMessage != "" {
		ev.ErrorMessage = msg.ErrorMessage
	}
	return &ev
}

// terminalKindForStatus 把已落库 message.status 映射成客户端终帧 kind。streaming/空 → 非终态。
func terminalKindForStatus(status string) (string, bool) {
	switch status {
	case "final":
		return EventMessageCompleted, true
	case "failed":
		return EventMessageFailed, true
	case "cancelled":
		return EventMessageCancelled, true
	}
	return "", false
}
