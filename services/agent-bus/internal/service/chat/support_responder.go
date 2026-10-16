package chat

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/model"
	domagentkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentkb"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/llmmetadata"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider"
)

const (
	supportResponderFallback      = "你好，我是知办客服。你可以问我知办AI的使用问题；如果遇到报错、卡顿或功能异常，也可以把截图、发生页面、操作步骤和客户端版本发给我，我会帮你记录反馈。"
	supportFeedbackAck            = "已记录。我会把这个问题反馈给平台管理员处理；如果方便，请继续补充发生页面、操作步骤、报错提示、客户端版本或更多截图。"
	supportFeedbackNeedScreenshot = "我可以帮你记录这个问题。为了方便定位，请上传问题截图，并补充发生页面、操作步骤、报错提示和客户端版本；收到截图或文件后我会帮你记录到问题反馈。"
	supportSystemPrompt           = "你是知办客服。可以自然回应问候，也可以解答知办AI软件使用相关问题。回答优先依据下方提供的资料片段；涉及知办AI、客户制度、上传文件或企业内部事实时，禁止补充片段之外的推测或承诺。若资料不足以回答这类专有问题，用自然的表达说明暂时没有确切资料、为避免误导不做猜测，并引导用户补充具体问题细节以便记录反馈；不要向用户提及“知识库”“检索”“召回”“片段”“绑定”等内部机制词汇。若用户问的是通用概念或常识问题，可以自然、简短回答；不要伪装成官方资料结论，也无需添加固定前缀或免责声明。遇到疑似报错、卡顿、功能异常或产品建议时，直接引导用户提供截图、发生页面、操作步骤和客户端版本，不要先说明资料查询情况。不要每轮回复都以问候开头，仅在用户先问候时回应问候。"
)

// SupportKBBindingLister 是知办客服内置 responder 对 agent_kb_bindings 的窄依赖。
type SupportKBBindingLister interface {
	ListByAgent(ctx context.Context, agentID int64) ([]*domagentkb.Binding, error)
}

// SupportKnowledgeProvider 是知办客服内置 responder 对 F07 provider 的窄依赖。
type SupportKnowledgeProvider interface {
	Retrieve(ctx context.Context, in provider.RetrieveReq) ([]provider.Chunk, error)
}

// SupportLLMProvider 是知办客服内置 responder 对轻量 LLM 的窄依赖。
type SupportLLMProvider interface {
	StreamChat(ctx context.Context, req model.ChatRequest) (model.Stream, error)
}

// SetSupportResponderDepsOnService 装配知办客服内置 responder 的 KB/LLM 依赖。
func SetSupportResponderDepsOnService(svc Service, kbs SupportKBBindingLister, p SupportKnowledgeProvider, llm SupportLLMProvider) {
	if im, ok := svc.(*impl); ok {
		im.supportKBs = kbs
		im.supportProvider = p
		im.supportLLM = llm
	}
}

func (s *impl) runSupportResponderGoroutine(ctx context.Context, streamID string, in runAgentInternalIn, agentMsgUUID string) {
	defer s.fanout.Close(ctx, streamID)

	var userBlocks []map[string]any
	var userMsg *dommsg.Message
	var userMsgUUID string
	if inputUUID := strings.TrimSpace(firstNonEmpty(in.InputMessageUUID, in.UserMessageUUID)); inputUUID != "" && s.messages != nil {
		if msg, err := s.messages.GetByUUID(ctx, inputUUID); err == nil && msg != nil {
			userMsg = msg
			userBlocks = msg.Blocks
			userMsgUUID = msg.UUID
		} else if err != nil {
			s.logger.Warn(ctx, "support responder: load input message failed", "message_uuid", inputUUID, "err", err.Error())
		}
	}

	userText := supportFeedbackTextFromBlocks(userBlocks)
	if userText == "" {
		userText = sanitizeSupportFeedbackText(in.PromptText)
	}
	attachments := supportFeedbackAttachmentsFromBlocks(userBlocks)
	_, route := decideSupportFeedbackRoute(userText, attachments)
	if route == supportRouteAskForScreenshot {
		s.finalize(ctx, streamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, agentMsgUUID,
			[]map[string]any{markdownBlock(supportFeedbackNeedScreenshot)}, "final", "", "", nil)
		return
	}

	if route == supportRouteCreateFeedback {
		if _, ok := s.maybeRecordSupportFeedback(ctx, supportFeedbackInput{
			AccountID:         in.AccountID,
			TenantID:          in.TenantID,
			Conversation:      in.Conversation,
			Agent:             in.Agent,
			Text:              userText,
			UserMessage:       userMsg,
			UserMessageBlocks: userBlocks,
			Trigger:           "support_builtin",
			RoomUUID:          in.RoomUUID,
		}); ok {
			s.finalize(ctx, streamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, agentMsgUUID,
				[]map[string]any{markdownBlock(supportFeedbackAck)}, "final", "", "", nil)
			return
		}
	}

	answer := s.answerSupportQuestion(ctx, in, userMsgUUID, userText)
	if context.Cause(ctx) != nil {
		s.finalize(ctx, streamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, agentMsgUUID,
			nil, "cancelled", "", "", nil)
		return
	}
	s.finalize(ctx, streamID, in.AccountID, in.TenantID, in.Conversation.UUID, in.RoomUUID, agentMsgUUID,
		[]map[string]any{markdownBlock(answer)}, "final", "", "", nil)
}

func (s *impl) answerSupportQuestion(ctx context.Context, in runAgentInternalIn, userMsgUUID string, query string) string {
	query = sanitizeSupportFeedbackText(query)
	if query == "" {
		return supportResponderFallback
	}
	chunks := s.retrieveSupportChunks(ctx, in, query)
	if len(chunks) > 0 && s.logger != nil {
		s.logger.Info(ctx, "support responder: knowledge context prepared",
			"tenant_id", in.TenantID,
			"account_id", in.AccountID,
			"agent_uuid", in.Agent.UUID,
			"conversation_uuid", in.Conversation.UUID,
			"message_uuid", userMsgUUID,
			"chunk_count", len(chunks),
			"source", "support_builtin")
	}
	if s.supportLLM == nil {
		if len(chunks) == 0 {
			return supportResponderFallback
		}
		return supportAnswerFromChunks(chunks)
	}
	answer, err := s.generateSupportAnswer(ctx, in, userMsgUUID, query, chunks)
	if err != nil {
		s.logger.Warn(ctx, "support responder: llm answer failed", "agent_uuid", in.Agent.UUID, "message_uuid", userMsgUUID, "err", err.Error())
		return supportAnswerFromChunks(chunks)
	}
	answer = strings.TrimSpace(answer)
	if answer == "" {
		return supportAnswerFromChunks(chunks)
	}
	return answer
}

func (s *impl) retrieveSupportChunks(ctx context.Context, in runAgentInternalIn, query string) []provider.Chunk {
	if s.supportKBs == nil || s.supportProvider == nil || in.Agent == nil || in.Agent.ID <= 0 {
		return nil
	}
	binds, err := s.supportKBs.ListByAgent(ctx, in.Agent.ID)
	if err != nil {
		s.logger.Warn(ctx, "support responder: list agent kb bindings failed", "agent_uuid", in.Agent.UUID, "err", err.Error())
		return nil
	}
	out := make([]provider.Chunk, 0, 6)
	for _, b := range binds {
		if b == nil || b.KBID <= 0 {
			continue
		}
		recalled, err := s.supportProvider.Retrieve(ctx, provider.RetrieveReq{
			TenantID:  in.TenantID,
			KBID:      b.KBID,
			Query:     query,
			TopK:      3,
			Threshold: 0.01,
		})
		if err != nil {
			s.logger.Warn(ctx, "support responder: retrieve kb failed", "agent_uuid", in.Agent.UUID, "kb_id", b.KBID, "err", err.Error())
			continue
		}
		out = append(out, recalled...)
		if len(out) >= 6 {
			return out[:6]
		}
	}
	return out
}

func (s *impl) generateSupportAnswer(ctx context.Context, in runAgentInternalIn, userMsgUUID string, query string, chunks []provider.Chunk) (string, error) {
	llmCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	modelName := ""
	if in.Agent != nil {
		modelName = strings.TrimSpace(in.Agent.ModelPrimary)
	}
	stream, err := s.supportLLM.StreamChat(llmCtx, model.ChatRequest{
		Model: modelName,
		Messages: []model.ChatMessage{
			{Role: "system", Content: supportSystemPrompt},
			{Role: "user", Content: supportPrompt(query, chunks)},
		},
		Metadata: llmmetadata.Map(llmmetadata.Context{
			UsageScene:     "chat",
			TenantID:       in.TenantID,
			AccountID:      in.AccountID,
			AgentID:        safeAgentUUID(in.Agent),
			ConversationID: safeConversationUUID(in.Conversation),
			MessageID:      userMsgUUID,
		}),
	})
	if err != nil {
		return "", err
	}
	defer stream.Close()

	var b strings.Builder
	for {
		chunk, err := stream.Recv()
		if err != nil {
			return "", err
		}
		if chunk.Err != nil {
			return "", chunk.Err
		}
		if chunk.Delta != "" {
			b.WriteString(chunk.Delta)
			if utf8.RuneCountInString(b.String()) > 3000 {
				break
			}
		}
		if chunk.Done {
			break
		}
	}
	return strings.TrimSpace(b.String()), nil
}

func supportPrompt(query string, chunks []provider.Chunk) string {
	var b strings.Builder
	b.WriteString("当前日期：")
	b.WriteString(time.Now().Format("2006年1月2日"))
	b.WriteString("\n\n")
	b.WriteString("用户问题：\n")
	b.WriteString(query)
	b.WriteString("\n\n知识库片段：\n")
	if len(chunks) == 0 {
		b.WriteString("无（本轮未召回到可用知识库片段）\n")
	} else {
		for i, c := range chunks {
			if i >= 6 {
				break
			}
			content := strings.TrimSpace(c.Content)
			if content == "" {
				continue
			}
			b.WriteString(fmt.Sprintf("[%d] %s\n", i+1, truncateRunes(content, 800)))
		}
	}
	b.WriteString("\n回答要求：\n")
	b.WriteString("- 知办AI、客户制度、上传文件、企业内部事实类问题：必须优先依据知识库片段；片段不足时用自然表达说明暂时没有确切资料、不做猜测，并引导用户补充问题细节以便记录反馈。\n")
	b.WriteString("- 报错、卡顿、功能异常或产品建议类：直接引导用户提供截图、发生页面、操作步骤和客户端版本，不要提及资料查询情况。\n")
	b.WriteString("- 通用概念或常识问题：自然、简短回答，无需添加“通用说明”等固定前缀或免责声明。\n")
	b.WriteString("- 不要向用户提及“知识库”“检索”“召回”“片段”“绑定”等内部机制词汇；不要把通用常识伪装成官方资料结论，不要编造片段没有的内部事实。\n")
	b.WriteString("- 不要每轮回复都以问候开头。\n")
	return b.String()
}

func supportAnswerFromChunks(chunks []provider.Chunk) string {
	if len(chunks) == 0 {
		return supportResponderFallback
	}
	first := strings.TrimSpace(chunks[0].Content)
	if first == "" {
		return supportResponderFallback
	}
	return "我查到的相关资料如下：\n\n" + truncateRunes(first, 1000)
}

func markdownBlock(text string) map[string]any {
	return map[string]any{"type": "markdown", "text": strings.TrimSpace(text)}
}

func truncateRunes(s string, max int) string {
	rs := []rune(strings.TrimSpace(s))
	if len(rs) <= max {
		return string(rs)
	}
	return string(rs[:max]) + "..."
}
