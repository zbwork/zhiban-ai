package chat

import (
	"context"
	"errors"
	"fmt"
	"strings"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	domsupport "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/supportfeedback"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const supportAgentKey = "zhiban-support"

type supportFeedbackInput struct {
	AccountID         int64
	TenantID          int64
	Conversation      *domconv.Conversation
	Agent             *domagent.DigitalEmployee
	Text              string
	UserMessage       *dommsg.Message
	UserMessageBlocks []map[string]any
	Trigger           string
	RoomUUID          string
}

type supportFeedbackRoute string

const (
	supportRouteAnswer           supportFeedbackRoute = "answer"
	supportRouteAskForScreenshot supportFeedbackRoute = "ask_for_screenshot"
	supportRouteCreateFeedback   supportFeedbackRoute = "create_feedback"
)

type supportFeedbackContextReader interface {
	LastByConversationBeforeMessage(ctx context.Context, conversationID, beforeMessageID int64) (*domsupport.Feedback, error)
}

func (s *impl) maybeRecordSupportFeedbackFromRunInput(ctx context.Context, in RunAgentInput, inputMessageUUID string) {
	if s.supportFeedback == nil || !isZhibanSupportAgent(in.Agent) || strings.TrimSpace(inputMessageUUID) == "" {
		return
	}
	msg, err := s.messages.GetByUUID(ctx, inputMessageUUID)
	if err != nil {
		s.logger.Warn(ctx, "support feedback auto capture: load input message failed",
			"message_uuid", inputMessageUUID, "err", err.Error())
		return
	}
	s.maybeRecordSupportFeedback(ctx, supportFeedbackInput{
		AccountID:         in.AccountID,
		TenantID:          in.TenantID,
		Conversation:      in.Conversation,
		Agent:             in.Agent,
		Text:              firstNonEmpty(supportFeedbackTextFromBlocks(msg.Blocks), in.PromptText),
		UserMessage:       msg,
		UserMessageBlocks: msg.Blocks,
		Trigger:           "run_agent",
		RoomUUID:          in.RoomUUID,
	})
}

func (s *impl) maybeRecordSupportFeedback(ctx context.Context, in supportFeedbackInput) (*domsupport.Feedback, bool) {
	if s.supportFeedback == nil || !isSupportBuiltinAgent(in.Agent) {
		return nil, false
	}
	text := sanitizeSupportFeedbackText(in.Text)
	category, route := decideSupportFeedbackRoute(text, supportFeedbackAttachmentsFromBlocks(in.UserMessageBlocks))
	if route != supportRouteCreateFeedback || category == "" {
		return nil, false
	}
	title := summarizeSupportFeedbackTitle(text)
	attachments := supportFeedbackAttachmentsFromBlocks(in.UserMessageBlocks)
	messageUUID := ""
	var messageID *int64
	if in.UserMessage != nil {
		messageUUID = in.UserMessage.UUID
		if in.UserMessage.ID > 0 {
			id := in.UserMessage.ID
			messageID = &id
		}
	}
	var convID *int64
	convUUID := ""
	if in.Conversation != nil {
		convUUID = in.Conversation.UUID
		if in.Conversation.ID > 0 {
			id := in.Conversation.ID
			convID = &id
		}
	}
	agentID := &in.Agent.ID
	accountID := &in.AccountID
	clientInfo := map[string]any{
		"auto_capture":      true,
		"trigger":           in.Trigger,
		"agent_uuid":        in.Agent.UUID,
		"conversation_uuid": convUUID,
		"message_uuid":      messageUUID,
		"room_uuid":         in.RoomUUID,
	}
	if contextInfo := s.supportFeedbackContext(ctx, in, messageID); len(contextInfo) > 0 {
		for k, v := range contextInfo {
			clientInfo[k] = v
		}
	}
	created, err := s.supportFeedback.Create(ctx, domsupport.CreateInput{
		TenantID:       in.TenantID,
		AccountID:      accountID,
		AgentID:        agentID,
		ConversationID: convID,
		MessageID:      messageID,
		Source:         domsupport.SourceAgentChat,
		Category:       category,
		Priority:       inferSupportFeedbackPriority(text),
		Status:         domsupport.StatusOpen,
		Title:          title,
		Description:    text,
		Attachments:    attachments,
		ClientInfo:     clientInfo,
	})
	if err != nil {
		s.logger.Warn(ctx, "support feedback auto capture failed",
			"agent_uuid", in.Agent.UUID, "conversation_uuid", convUUID, "message_uuid", messageUUID, "err", err.Error())
		return nil, false
	}
	return created, true
}

func (s *impl) supportFeedbackContext(ctx context.Context, in supportFeedbackInput, messageID *int64) map[string]any {
	if in.Conversation == nil || in.UserMessage == nil || messageID == nil || *messageID <= 0 || s.messages == nil {
		return nil
	}
	previousMessageID := int64(0)
	previousFeedbackUUID := ""
	if reader, ok := s.supportFeedback.(supportFeedbackContextReader); ok {
		prev, err := reader.LastByConversationBeforeMessage(ctx, in.Conversation.ID, *messageID)
		if err == nil && prev != nil {
			previousFeedbackUUID = prev.UUID
			if prev.MessageID != nil {
				previousMessageID = *prev.MessageID
			}
		} else if err != nil && !isSupportFeedbackNotFound(err) {
			s.logger.Warn(ctx, "support feedback context: load previous feedback failed",
				"conversation_id", in.Conversation.ID, "message_id", *messageID, "err", err.Error())
		}
	}

	hist, err := s.messages.History(ctx, dommsg.HistoryFilter{
		ConversationID: in.Conversation.ID,
		Limit:          50,
		Before:         &in.UserMessage.CreatedAt,
	})
	if err != nil {
		s.logger.Warn(ctx, "support feedback context: load message history failed",
			"conversation_id", in.Conversation.ID, "message_id", *messageID, "err", err.Error())
		return nil
	}

	const maxMessages = 10
	lines := make([]string, 0, maxMessages)
	fromMessageID := int64(0)
	toMessageID := *messageID
	for _, msg := range hist {
		if msg.ID <= previousMessageID || msg.ID >= *messageID {
			continue
		}
		text := supportFeedbackTextFromBlocks(msg.Blocks)
		if text == "" {
			continue
		}
		line := truncateSupportContextLine(fmt.Sprintf("[%s] %s", msg.Role, text), 200)
		lines = append(lines, line)
		if fromMessageID == 0 || msg.ID < fromMessageID {
			fromMessageID = msg.ID
		}
		if len(lines) >= maxMessages {
			break
		}
	}
	if len(lines) == 0 {
		return nil
	}
	for i, j := 0, len(lines)-1; i < j; i, j = i+1, j-1 {
		lines[i], lines[j] = lines[j], lines[i]
	}
	excerpt := truncateSupportContextLine(strings.Join(lines, "\n"), 2000)
	if excerpt == "" {
		return nil
	}
	return map[string]any{
		"context_excerpt": excerpt,
		"context_range": map[string]any{
			"from_message_id":        fromMessageID,
			"to_message_id":          toMessageID,
			"previous_feedback_uuid": previousFeedbackUUID,
			"previous_message_id":    previousMessageID,
		},
	}
}

func isSupportFeedbackNotFound(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, apperr.ErrNotFound) {
		return true
	}
	var e *apperr.Error
	if errors.As(err, &e) {
		return e.Code == apperr.NotFound
	}
	return false
}

func truncateSupportContextLine(text string, max int) string {
	text = sanitizeSupportFeedbackText(text)
	if max <= 0 || text == "" {
		return ""
	}
	rs := []rune(text)
	if len(rs) <= max {
		return text
	}
	return string(rs[:max]) + "..."
}

func supportFeedbackTextFromBlocks(blocks []map[string]any) string {
	parts := make([]string, 0, len(blocks))
	for _, block := range blocks {
		kind := strings.ToLower(strings.TrimSpace(fmt.Sprint(block["type"])))
		if kind != "plain" && kind != "markdown" && kind != "text" {
			continue
		}
		text := sanitizeSupportFeedbackText(firstString(block, "text", "content"))
		if text != "" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

func sanitizeSupportFeedbackText(text string) string {
	return strings.TrimSpace(strings.ToValidUTF8(text, ""))
}

func isSupportBuiltinAgent(agent *domagent.DigitalEmployee) bool {
	if agent == nil || agent.Metadata == nil {
		return false
	}
	return strings.TrimSpace(fmt.Sprint(agent.Metadata["runtime_kind"])) == FrameworkSupportBuiltin ||
		strings.TrimSpace(fmt.Sprint(agent.Metadata["agent_key"])) == supportAgentKey
}

func isZhibanSupportAgent(agent *domagent.DigitalEmployee) bool {
	return isSupportBuiltinAgent(agent)
}

func classifySupportFeedbackIntent(text string) (string, bool) {
	t := strings.ToLower(sanitizeSupportFeedbackText(text))
	if t == "" {
		return "", false
	}
	if containsAny(t, "建议", "希望增加", "希望支持", "能不能增加", "产品建议", "优化一下") {
		return domsupport.CategoryProductSuggestion, true
	}
	if containsAny(t, "登录不了", "无法登录", "不能登录", "账号", "账户", "权限", "没权限", "访问被拒绝") &&
		containsAny(t, "反馈", "问题", "不了", "无法", "不能", "拒绝", "报错", "错误") {
		return domsupport.CategoryAccountAccess, true
	}
	if containsAny(t, "卡顿", "很慢", "太慢", "一直转圈", "加载不出来", "卡住", "没反应", "无响应") {
		return domsupport.CategoryPerformance, true
	}
	if containsAny(t, "bug", "报错", "错误", "异常", "失败", "无法", "不能", "打不开", "崩溃", "闪退", "白屏", "黑屏", "500", "404", "上传不了", "更新不了", "没法更新") {
		return domsupport.CategoryBug, true
	}
	if containsAny(t, "反馈", "帮我记录", "帮我提交", "提个问题", "提交问题", "问题反馈") &&
		!containsAny(t, "怎么", "如何", "在哪里", "是什么") {
		return domsupport.CategoryOther, true
	}
	return "", false
}

func decideSupportFeedbackRoute(text string, attachments []any) (string, supportFeedbackRoute) {
	category, ok := classifySupportFeedbackIntent(text)
	if !ok {
		return "", supportRouteAnswer
	}
	if len(attachments) > 0 || isExplicitSupportFeedbackSubmission(text) {
		return category, supportRouteCreateFeedback
	}
	switch category {
	case domsupport.CategoryProductSuggestion:
		return category, supportRouteCreateFeedback
	case domsupport.CategoryBug, domsupport.CategoryPerformance, domsupport.CategoryAccountAccess:
		return category, supportRouteAskForScreenshot
	default:
		return category, supportRouteAskForScreenshot
	}
}

func isExplicitSupportFeedbackSubmission(text string) bool {
	t := strings.ToLower(sanitizeSupportFeedbackText(text))
	if t == "" {
		return false
	}
	return containsAny(t,
		"反馈", "问题反馈", "帮我记录", "帮我提交", "提交问题",
		"记录一下", "提个问题", "提个bug", "提个 bug", "提交bug", "提交 bug", "报个bug", "报个 bug",
	)
}

func inferSupportFeedbackPriority(text string) string {
	t := strings.ToLower(sanitizeSupportFeedbackText(text))
	if containsAny(t, "紧急", "严重", "阻塞", "全员", "所有人", "无法使用") {
		return domsupport.PriorityHigh
	}
	return domsupport.PriorityNormal
}

func summarizeSupportFeedbackTitle(text string) string {
	rs := []rune(sanitizeSupportFeedbackText(text))
	if len(rs) == 0 {
		return "用户问题反馈"
	}
	if len(rs) > 60 {
		return string(rs[:60])
	}
	return string(rs)
}

func supportFeedbackAttachmentsFromBlocks(blocks []map[string]any) []any {
	out := make([]any, 0)
	seen := map[string]struct{}{}
	for _, block := range blocks {
		if len(out) >= domsupport.MaxAttachments {
			break
		}
		kind := strings.ToLower(strings.TrimSpace(fmt.Sprint(block["type"])))
		if kind != "image" && kind != "file" && kind != "document" && kind != "video" {
			continue
		}
		if kind == "document" {
			kind = "file"
		}
		fileUUID := strings.TrimSpace(firstString(block, "file_id"))
		refUUID := strings.TrimSpace(firstString(block, "ref_uuid", "refUuid", "uuid", "fileId"))
		url := strings.TrimSpace(firstString(block, "url", "fileLink", "preview_url", "previewUrl", "download_url", "downloadUrl", "thumb_url", "thumbUrl"))
		dedupeKey := firstNonEmpty(fileUUID, refUUID, url, fmt.Sprintf("%s:%d", kind, len(out)))
		if _, ok := seen[dedupeKey]; ok {
			continue
		}
		seen[dedupeKey] = struct{}{}
		item := map[string]any{
			"type": kind,
			"name": firstString(block, "name", "file_name", "fileName", "filename", "title"),
			"mime": firstString(block, "mime", "mime_type", "mimeType"),
			"size": firstNonNil(block["size"], block["size_bytes"], block["sizeBytes"]),
			"url":  url,
		}
		if fileUUID != "" {
			item["file_uuid"] = fileUUID
		}
		if refUUID != "" {
			item["ref_uuid"] = refUUID
		}
		out = append(out, item)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func firstString(block map[string]any, keys ...string) string {
	for _, key := range keys {
		if v, ok := block[key]; ok {
			if s := strings.TrimSpace(strings.ToValidUTF8(fmt.Sprint(v), "")); s != "" && s != "<nil>" {
				return s
			}
		}
	}
	return ""
}

func firstNonNil(values ...any) any {
	for _, v := range values {
		if v != nil {
			return v
		}
	}
	return nil
}

func containsAny(s string, parts ...string) bool {
	for _, part := range parts {
		if strings.Contains(s, part) {
			return true
		}
	}
	return false
}
