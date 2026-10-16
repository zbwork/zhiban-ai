// chatclient.go — Hermes chat client.
//
// Trusted runtime-tool calls use the Session API so Agent Bus can bind the
// server-side session context without exposing its key to the model. Legacy
// callers without a SessionKey retain the OpenAI-compatible streaming path.
//
// Security: API_SERVER_KEY is passed as Bearer token, never logged. Message content not logged.

package hermes

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	domsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"io"
	"net/http"
	"strings"
	"time"
)

var ErrModelOverrideUnsupported = errors.New("hermes runtime requires per-turn conversation model support")

// ChatClient calls Hermes /v1/chat/completions with stream=true.
type ChatClient struct {
	httpClient *http.Client
	timeout    time.Duration
}

// NewChatClient constructs a ChatClient. timeout applies to the entire SSE stream read.
func NewChatClient(timeout time.Duration) *ChatClient {
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	return &ChatClient{
		httpClient: &http.Client{Timeout: timeout},
		timeout:    timeout,
	}
}

// ChatMessage is an OpenAI-compatible message in the messages array.
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatRequest specifies what to send to Hermes.
type ChatRequest struct {
	ModelService         *domsource.RuntimeBinding
	Endpoint             string // base URL, e.g. "http://127.0.0.1:8642"
	APIKey               string // Bearer token (API_SERVER_KEY)
	Model                string // optional model override
	RequireModelOverride bool   // require request-scoped runtime acknowledgement
	Messages             []ChatMessage
	// SessionKey is the trusted Agent Bus runtime-tool scope. When set, the
	// client uses Hermes Session API and sends it only through
	// X-Hermes-Session-Key; it is never exposed to the model as a tool arg.
	SessionKey string
}

// StreamEvent represents a parsed SSE event from Hermes /v1/chat/completions.
type StreamEvent struct {
	Type         string // "delta", "done", "error", "tool_progress"
	Delta        string // content text (only for Type="delta")
	FinishReason string // e.g. "stop" (only when present)
	Err          error  // non-nil for Type="error"
	ToolCallID   string // Hermes toolCallId (only for Type="tool_progress")
	ToolName     string // Hermes tool name (only for Type="tool_progress")
	ToolStatus   string // running/completed/etc (only for Type="tool_progress")

	// Usage F24: runtime-reported token usage, normalized to
	// {input_tokens, output_tokens, total_tokens, model}. Set on the terminal
	// chunk (OpenAI-compatible `usage` field) or session `run.completed`.
	// Display/observability only — never a billing source (F11 口径).
	Usage map[string]any
}

// ChatStream sends a streaming chat request and calls handler for each SSE event.
// handler returns true to stop reading (e.g. on finish_reason=stop).
// Returns nil on normal completion; non-nil on transport/protocol errors.
func (c *ChatClient) ChatStream(ctx context.Context, req ChatRequest, handler func(StreamEvent) bool) error {
	if strings.TrimSpace(req.SessionKey) != "" {
		return c.sessionChatStream(ctx, req, handler)
	}
	body := map[string]any{
		"messages": req.Messages,
		"stream":   true,
	}
	if req.Model != "" {
		body["model"] = req.Model
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("hermes chat: marshal request: %w", err)
	}

	endpoint := strings.TrimRight(req.Endpoint, "/") + "/v1/chat/completions"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return fmt.Errorf("hermes chat: create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")
	httpReq.Header.Set("Authorization", "Bearer "+req.APIKey)

	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("hermes chat: http do: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return c.handleErrorResponse(resp)
	}

	return parseSSEStream(resp.Body, handler)
}

func (c *ChatClient) sessionChatStream(ctx context.Context, req ChatRequest, handler func(StreamEvent) bool) error {
	sessionKey := strings.TrimSpace(req.SessionKey)
	sessionID := hermesSessionID(sessionKey)
	systemMessage, userMessage := splitHermesSessionMessages(req.Messages)
	if userMessage == "" {
		return fmt.Errorf("hermes session chat: missing user message")
	}

	createBody := map[string]any{"id": sessionID}
	if req.Model != "" {
		createBody["model"] = req.Model
	}
	if systemMessage != "" {
		createBody["system_prompt"] = systemMessage
	}
	if err := c.ensureSession(ctx, req, createBody); err != nil {
		return err
	}

	body := map[string]any{"message": userMessage}
	if req.ModelService != nil {
		body["model_service_override"] = req.ModelService
	}
	if req.RequireModelOverride {
		body["model"] = req.Model
	}
	if systemMessage != "" {
		body["system_message"] = systemMessage
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("hermes session chat: marshal request: %w", err)
	}
	endpoint := strings.TrimRight(req.Endpoint, "/") + "/api/sessions/" + sessionID + "/chat/stream"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return fmt.Errorf("hermes session chat: create request: %w", err)
	}
	setHermesHeaders(httpReq, req, true)
	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("hermes session chat: http do: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return c.handleErrorResponse(resp)
	}
	if req.RequireModelOverride && resp.Header.Get("X-Hermes-Model") != req.Model {
		return ErrModelOverrideUnsupported
	}
	return parseSessionSSEStream(resp.Body, handler)
}

func (c *ChatClient) ensureSession(ctx context.Context, req ChatRequest, body map[string]any) error {
	raw, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("hermes session create: marshal request: %w", err)
	}
	endpoint := strings.TrimRight(req.Endpoint, "/") + "/api/sessions"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return fmt.Errorf("hermes session create: create request: %w", err)
	}
	setHermesHeaders(httpReq, req, false)
	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("hermes session create: http do: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusCreated || resp.StatusCode == http.StatusConflict {
		if req.ModelService != nil && resp.Header.Get("X-Hermes-Model-Platform") != "per-turn-v1" {
			return ErrModelOverrideUnsupported
		}
		if req.RequireModelOverride && resp.Header.Get("X-Hermes-Conversation-Model") != "per-turn" {
			return ErrModelOverrideUnsupported
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}
	return c.handleErrorResponse(resp)
}

func setHermesHeaders(r *http.Request, req ChatRequest, stream bool) {
	r.Header.Set("Content-Type", "application/json")
	if stream {
		r.Header.Set("Accept", "text/event-stream")
	} else {
		r.Header.Set("Accept", "application/json")
	}
	r.Header.Set("Authorization", "Bearer "+req.APIKey)
	if key := strings.TrimSpace(req.SessionKey); key != "" {
		r.Header.Set("X-Hermes-Session-Key", key)
	}
}

func hermesSessionID(sessionKey string) string {
	sum := sha256.Sum256([]byte(sessionKey))
	return fmt.Sprintf("zhiban_%x", sum[:20])
}

func splitHermesSessionMessages(messages []ChatMessage) (string, string) {
	systems := make([]string, 0, 2)
	user := ""
	for _, message := range messages {
		content := strings.TrimSpace(message.Content)
		switch message.Role {
		case "system":
			if content != "" {
				systems = append(systems, content)
			}
		case "user":
			if content != "" {
				user = content
			}
		}
	}
	return strings.Join(systems, "\n\n"), user
}

func parseSessionSSEStream(r io.Reader, handler func(StreamEvent) bool) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	var eventName string
	var dataLines []string
	accumulated := ""
	flush := func() bool {
		if len(dataLines) == 0 {
			return false
		}
		data := strings.Join(dataLines, "\n")
		var payload map[string]any
		if err := json.Unmarshal([]byte(data), &payload); err != nil {
			return handler(StreamEvent{Type: "error", Err: fmt.Errorf("hermes session chat: invalid SSE payload: %w", err)})
		}
		switch eventName {
		case "assistant.delta":
			delta := rawStringFromAny(payload["delta"])
			accumulated += delta
			return handler(StreamEvent{Type: "delta", Delta: delta})
		case "assistant.completed":
			content := rawStringFromAny(payload["content"])
			if content != "" && strings.HasPrefix(content, accumulated) && len(content) > len(accumulated) {
				delta := content[len(accumulated):]
				accumulated = content
				return handler(StreamEvent{Type: "delta", Delta: delta})
			}
		case "tool.started", "tool.completed", "tool.failed":
			status := strings.TrimPrefix(eventName, "tool.")
			toolCallID := stringFromAny(payload["tool_call_id"])
			if toolCallID == "" {
				// Backward compatibility with unpatched Hermes images. Older
				// Session SSE reused message_id for every tool in the turn.
				toolCallID = stringFromAny(payload["message_id"])
			}
			return handler(StreamEvent{
				Type:       "tool_progress",
				ToolCallID: toolCallID,
				ToolName:   stringFromAny(payload["tool_name"]),
				ToolStatus: status,
			})
		case "run.completed", "done":
			return handler(StreamEvent{Type: "done", Usage: normalizeHermesUsage(payload["usage"])})
		case "error":
			return handler(StreamEvent{Type: "error", Err: fmt.Errorf("hermes session chat: %s", stringFromAny(payload["message"]))})
		}
		return false
	}
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, ":") {
			continue
		}
		if line == "" {
			if flush() {
				return nil
			}
			eventName = ""
			dataLines = nil
			continue
		}
		if strings.HasPrefix(line, "event:") {
			eventName = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		} else if strings.HasPrefix(line, "data:") {
			dataLines = append(dataLines, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		}
	}
	if len(dataLines) > 0 {
		flush()
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("hermes session chat: sse read: %w", err)
	}
	return nil
}

// ChatAPIError represents an HTTP error from Hermes.
type ChatAPIError struct {
	StatusCode int
	Code       string
	Message    string
}

func (e *ChatAPIError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("hermes api %d: %s: %s", e.StatusCode, e.Code, e.Message)
	}
	return fmt.Sprintf("hermes api %d: %s", e.StatusCode, e.Message)
}

func (c *ChatClient) handleErrorResponse(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	apiErr := &ChatAPIError{StatusCode: resp.StatusCode}

	var envelope struct {
		Error struct {
			Message string `json:"message"`
			Type    string `json:"type"`
			Code    string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &envelope) == nil && envelope.Error.Message != "" {
		apiErr.Code = envelope.Error.Code
		apiErr.Message = envelope.Error.Message
	} else {
		apiErr.Message = strings.TrimSpace(string(body))
		if apiErr.Message == "" {
			apiErr.Message = resp.Status
		}
	}
	return apiErr
}

// parseSSEStream reads an SSE byte stream and emits StreamEvents.
func parseSSEStream(r io.Reader, handler func(StreamEvent) bool) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var currentEvent string
	var dataLines []string

	for scanner.Scan() {
		line := scanner.Text()

		// Comment line (keepalive): ": keepalive" or ": ping"
		if strings.HasPrefix(line, ":") {
			continue
		}

		// Empty line = event boundary
		if line == "" {
			if len(dataLines) > 0 {
				data := strings.Join(dataLines, "\n")
				ev := parseSSEData(currentEvent, data)
				if handler(ev) {
					return nil
				}
			}
			currentEvent = ""
			dataLines = nil
			continue
		}

		if strings.HasPrefix(line, "event:") {
			currentEvent = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			continue
		}

		if strings.HasPrefix(line, "data:") {
			val := strings.TrimPrefix(line, "data:")
			if len(val) > 0 && val[0] == ' ' {
				val = val[1:]
			}
			dataLines = append(dataLines, val)
			continue
		}
	}

	// Flush remaining data if stream ended without trailing empty line
	if len(dataLines) > 0 {
		data := strings.Join(dataLines, "\n")
		ev := parseSSEData(currentEvent, data)
		handler(ev)
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("hermes chat: sse read: %w", err)
	}
	return nil
}

func parseSSEData(eventName, data string) StreamEvent {
	data = strings.TrimSpace(data)

	// [DONE] sentinel
	if data == "[DONE]" {
		return StreamEvent{Type: "done"}
	}

	// hermes.tool.progress events
	if eventName == "hermes.tool.progress" {
		// Hermes v0.16.0 can multiplex OpenAI-compatible chat chunks under
		// this custom event name after tool progress. Preserve those chunks as
		// text deltas; otherwise the final answer is lost or marked failed.
		if looksLikeOpenAIChunk(data) {
			return parseOpenAIChunk(data)
		}
		var payload map[string]any
		if err := json.Unmarshal([]byte(data), &payload); err != nil {
			return StreamEvent{Type: "ignore"}
		}
		return StreamEvent{
			Type:       "tool_progress",
			ToolCallID: stringFromAny(payload["toolCallId"]),
			ToolName:   stringFromAny(payload["tool"]),
			ToolStatus: strings.ToLower(strings.TrimSpace(stringFromAny(payload["status"]))),
		}
	}

	// Hermes can emit custom SSE events besides OpenAI-compatible chunks. Unknown
	// Hermes events are runtime progress metadata, not chat protocol failures.
	if strings.HasPrefix(eventName, "hermes.") {
		return StreamEvent{Type: "ignore"}
	}

	return parseOpenAIChunk(data)
}

func looksLikeOpenAIChunk(data string) bool {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(data), &raw); err != nil {
		return false
	}
	if _, ok := raw["choices"]; ok {
		return true
	}
	if _, ok := raw["error"]; ok {
		return true
	}
	var object string
	if err := json.Unmarshal(raw["object"], &object); err == nil && strings.Contains(object, "chat.completion") {
		return true
	}
	return false
}

func parseOpenAIChunk(data string) StreamEvent {
	// Parse JSON chunk
	var chunk struct {
		Choices []struct {
			Delta struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"delta"`
			FinishReason *string `json:"finish_reason"`
		} `json:"choices"`
		Error *struct {
			Message string `json:"message"`
			Code    string `json:"code"`
		} `json:"error"`
		Usage *struct {
			PromptTokens     int64 `json:"prompt_tokens"`
			CompletionTokens int64 `json:"completion_tokens"`
			TotalTokens      int64 `json:"total_tokens"`
		} `json:"usage"`
		Model string `json:"model"`
	}

	if err := json.Unmarshal([]byte(data), &chunk); err != nil {
		return StreamEvent{
			Type: "error",
			Err:  fmt.Errorf("hermes chat: malformed SSE JSON: %w", err),
		}
	}

	// Error in chunk
	if chunk.Error != nil && chunk.Error.Message != "" {
		return StreamEvent{
			Type: "error",
			Err: &ChatAPIError{
				Code:    chunk.Error.Code,
				Message: chunk.Error.Message,
			},
		}
	}

	var usage map[string]any
	if chunk.Usage != nil {
		usage = map[string]any{
			"input_tokens":  chunk.Usage.PromptTokens,
			"output_tokens": chunk.Usage.CompletionTokens,
			"total_tokens":  chunk.Usage.TotalTokens,
		}
		if chunk.Usage.TotalTokens == 0 {
			usage["total_tokens"] = chunk.Usage.PromptTokens + chunk.Usage.CompletionTokens
		}
		if chunk.Model != "" {
			usage["model"] = chunk.Model
		}
	}

	if len(chunk.Choices) == 0 {
		return StreamEvent{Type: "delta", Usage: usage}
	}

	choice := chunk.Choices[0]
	ev := StreamEvent{Type: "delta", Usage: usage}

	if choice.Delta.Content != "" {
		ev.Delta = choice.Delta.Content
	}

	if choice.FinishReason != nil && *choice.FinishReason != "" {
		ev.FinishReason = *choice.FinishReason
	}

	return ev
}

func stringFromAny(v any) string {
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case fmt.Stringer:
		return strings.TrimSpace(t.String())
	default:
		return ""
	}
}

// rawStringFromAny is for user-visible streamed text. Whitespace at a delta
// boundary is content (often Markdown spacing/newlines), not protocol padding.
func rawStringFromAny(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case fmt.Stringer:
		return t.String()
	default:
		return ""
	}
}

// normalizeHermesUsage maps a Hermes usage payload (prompt/completion or
// input/output vocab) onto the Bus-wide usage shape. Returns nil when the
// payload carries no token facts.
func normalizeHermesUsage(v any) map[string]any {
	m, ok := v.(map[string]any)
	if !ok || len(m) == 0 {
		return nil
	}
	num := func(keys ...string) (int64, bool) {
		for _, k := range keys {
			switch t := m[k].(type) {
			case float64:
				return int64(t), true
			case int64:
				return t, true
			case json.Number:
				if n, err := t.Int64(); err == nil {
					return n, true
				}
			}
		}
		return 0, false
	}
	in, okIn := num("input_tokens", "prompt_tokens")
	out, okOut := num("output_tokens", "completion_tokens")
	total, okTotal := num("total_tokens")
	if !okIn && !okOut && !okTotal {
		return nil
	}
	if !okTotal {
		total = in + out
	}
	usage := map[string]any{"input_tokens": in, "output_tokens": out, "total_tokens": total}
	if model, ok := m["model"].(string); ok && model != "" {
		usage["model"] = model
	}
	return usage
}
