// Package llm 是用平台 LLM 直接驱动数字员工的 Runtime Adapter。
// 适用于 integration_mode = platform_managed 的数字员工：
// Bus 自己拼 prompt，调 model provider 拿 stream，再封装为 EMP Block。
package llm

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/model"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/llmmetadata"
)

type Adapter struct {
	provider model.Provider
}

func New(p model.Provider) *Adapter { return &Adapter{provider: p} }

func (a *Adapter) Name() string { return "llm" }

func (a *Adapter) HealthCheck(ctx context.Context) error {
	if a.provider == nil {
		return errors.New("model provider not set")
	}
	return nil
}

func (a *Adapter) Stream(ctx context.Context, req runtime.StreamRequest) (runtime.Stream, error) {
	msgs := make([]model.ChatMessage, 0, len(req.History)+2)
	systemPrompt := req.SystemPrompt
	if strings.TrimSpace(systemPrompt) == "" {
		systemPrompt = "你是一个有帮助、简洁的中文助手。回答要结构化、有用、避免废话。"
	}
	msgs = append(msgs, model.ChatMessage{Role: "system", Content: systemPrompt})

	// 历史里最后一条往往是本次正在创建的 streaming 预建消息（无内容），
	// 以及就是这条用户消息本身（已写入 DB）；都不要重复送给模型。
	hist := req.History
	if len(hist) > 0 && hist[len(hist)-1].Role == "agent" && hist[len(hist)-1].Text == "" {
		hist = hist[:len(hist)-1]
	}
	if len(hist) > 0 && hist[len(hist)-1].Role == "user" && hist[len(hist)-1].Text == req.UserMessage {
		hist = hist[:len(hist)-1]
	}

	for _, h := range hist {
		role := normalizeRole(h.Role)
		if role == "" || h.Text == "" {
			continue
		}
		msgs = append(msgs, model.ChatMessage{Role: role, Content: h.Text})
	}
	if req.UserMessage != "" {
		msgs = append(msgs, model.ChatMessage{Role: "user", Content: req.UserMessage})
	}

	ms, err := a.provider.StreamChat(ctx, model.ChatRequest{
		Model:    req.ModelHint,
		Messages: msgs,
		Metadata: llmRequestMetadata(req),
	})
	if err != nil {
		return nil, err
	}
	return &stream{ms: ms, buf: ""}, nil
}

func llmRequestMetadata(req runtime.StreamRequest) map[string]any {
	return llmmetadata.Map(llmmetadata.Context{
		UsageScene:     "chat",
		TenantID:       req.TenantID,
		AccountID:      req.AccountID,
		AgentID:        req.AgentUUID,
		ConversationID: firstRuntimeMetaString(req.Metadata, "conversationId", "conversation_uuid", "conversationUUID"),
		MessageID:      firstRuntimeMetaString(req.Metadata, "messageId", "message_uuid", "messageUUID"),
		StreamID:       req.StreamID,
		RuntimeEnvID:   firstRuntimeMetaInt(req.Metadata, "runtimeEnvId", "runtime_env_id", "runtimeEnvironmentId", "runtime_environment_id"),
	})
}

func firstRuntimeMetaString(m map[string]any, keys ...string) string {
	for _, key := range keys {
		if v := runtimeMetaString(m, key); v != "" {
			return v
		}
	}
	return ""
}

func runtimeMetaString(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	switch v := m[key].(type) {
	case string:
		return strings.TrimSpace(v)
	case int64:
		return strconv.FormatInt(v, 10)
	case int:
		return strconv.Itoa(v)
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	}
	return ""
}

func firstRuntimeMetaInt(m map[string]any, keys ...string) int64 {
	for _, key := range keys {
		raw := runtimeMetaString(m, key)
		if raw == "" {
			continue
		}
		v, err := strconv.ParseInt(raw, 10, 64)
		if err == nil && v > 0 {
			return v
		}
	}
	return 0
}

// normalizeRole 把我们内部 role 映射到 OpenAI 兼容协议要求的 role。
func normalizeRole(r string) string {
	switch r {
	case "user", "system", "assistant", "tool", "function", "developer":
		return r
	case "agent":
		return "assistant"
	default:
		return ""
	}
}

type stream struct {
	ms  model.Stream
	buf string
}

func (s *stream) Recv() (runtime.StreamEvent, error) {
	c, err := s.ms.Recv()
	if err != nil {
		return runtime.StreamEvent{}, err
	}
	if c.Err != nil {
		return runtime.StreamEvent{Kind: "error", Err: c.Err}, nil
	}
	s.buf += c.Delta
	if c.Done {
		final := []map[string]any{{"type": "markdown", "text": s.buf}}
		return runtime.StreamEvent{Kind: "final", Blocks: final, Final: true}, nil
	}
	return runtime.StreamEvent{Kind: "delta", Text: s.buf}, nil
}

func (s *stream) Close() error { return s.ms.Close() }
