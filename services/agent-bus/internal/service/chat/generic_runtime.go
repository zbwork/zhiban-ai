package chat

import (
	"context"
	runtimeadapter "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	"time"
)

// SetGenericRuntime selects an explicitly configured embedded runtime at startup.
func SetGenericRuntime(service Service, adapter runtimeadapter.Adapter) {
	if s, ok := service.(*impl); ok {
		s.genericRuntime = adapter
	}
}
func (s *impl) runGenericRuntime(ctx context.Context, streamID string, in runAgentInternalIn, messageUUID string) {
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		s.fanout.Close(cleanup, streamID)
	}()
	finish := func(blocks []map[string]any, status, code string) {
		if ctx.Err() != nil {
			blocks = nil
			status = "cancelled"
			code = ""
		}
		terminal, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		s.finalize(terminal, streamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, messageUUID, blocks, status, code, "", nil)
	}
	if ctx.Err() != nil {
		finish(nil, "cancelled", "")
		return
	}
	if s.genericRuntime == nil {
		finish(nil, "failed", ErrCodeProtocolUnsupported)
		return
	}
	history, err := s.messages.History(ctx, dommsg.HistoryFilter{ConversationID: in.Conversation.ID, Limit: 80})
	if err != nil {
		finish(nil, "failed", "chat.history_unavailable")
		return
	}
	req := runtimeadapter.StreamRequest{StreamID: streamID, TenantID: in.TenantID, AccountID: in.AccountID, AgentUUID: in.Agent.UUID, ConversationID: in.Conversation.ID, UserMessage: in.PromptText, UserBlocks: in.UserBlocks, ModelHint: selectedConversationModel(in.UserMetadata)}

	req.SystemPrompt = in.Agent.Description
	if in.Agent.CurrentVersion > 0 {
		version, err := s.agents.GetVersion(ctx, in.Agent.ID, in.Agent.CurrentVersion)
		if err != nil || version == nil {
			finish(nil, "failed", "chat.version_unavailable")
			return
		}
		if prompt, ok := version.Snapshot["system_prompt"].(string); ok {
			req.SystemPrompt = prompt
		}
	}
	for _, m := range history {
		if m.TenantID != in.TenantID || m.ConversationID != in.Conversation.ID {
			finish(nil, "failed", "chat.history_scope_mismatch")
			return
		}
		if m.Status != "final" || m.UUID == messageUUID || m.UUID == in.UserMessageUUID || m.UUID == in.InputMessageUUID {
			continue
		}
		if m.Role != "user" && m.Role != "agent" {
			continue
		}
		req.History = append(req.History, runtimeadapter.HistoryMessage{Role: m.Role, Text: extractPromptText(m.Blocks), Blocks: m.Blocks})
	}
	stream, err := s.genericRuntime.Stream(ctx, req)
	if err != nil {
		finish(nil, "failed", "chat.runtime_unavailable")
		return
	}
	defer stream.Close()
	for {
		ev, err := stream.Recv()
		if err != nil || ev.Err != nil || ev.Kind == "error" {
			finish(nil, "failed", "chat.runtime_stream_failed")
			return
		}
		if ctx.Err() != nil {
			finish(nil, "cancelled", "")
			return
		}
		if ev.Final && ev.Kind == "final" {
			finish(ev.Blocks, "final", "")
			return
		}
		if ev.Kind != "delta" {
			continue
		}
		blocks := []map[string]any{{"type": "markdown", "text": ev.Text}}
		if err := s.messages.UpdateStreamBlocks(ctx, streamID, blocks); err != nil {
			finish(nil, "failed", "chat.persistence_failed")
			return
		}
		if err := s.fanout.Publish(ctx, streamID, in.AccountID, in.TenantID, StreamEvent{Kind: EventMessageBlockDelta, ConversationUUID: in.Conversation.UUID, RoomUUID: in.RoomUUID, MessageUUID: messageUUID, Blocks: blocks, Text: ev.Text, Timestamp: time.Now()}); err != nil {
			finish(nil, "failed", "chat.publish_failed")
			return
		}
	}
}
