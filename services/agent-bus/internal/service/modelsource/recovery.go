package modelsource

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
)

// RecoveryCandidates uses account-owned versioned sources. It never borrows an
// employee's BYOK key or upgrades to a platform credential.
func (s *Service) RecoveryCandidates(ctx context.Context, scope dom.Scope, ref string) ([]Option, error) {
	original, err := s.Resolve(ctx, scope, ref)
	if err != nil {
		return nil, err
	}
	options, _, err := s.List(ctx, scope)
	if err != nil {
		return nil, err
	}
	source := ""
	for _, o := range options {
		if o.ID == SelectionReference(ref) {
			source = o.SourceID
		}
	}
	if source == "" {
		return nil, dom.ErrDenied
	}
	family := func(id string) string {
		name := strings.ToLower(id)
		for _, prefix := range []string{"claude", "gpt", "gemini", "qwen", "deepseek"} {
			if strings.Contains(name, prefix) {
				return prefix
			}
		}
		return strings.Split(name, "-")[0]
	}
	preferred := []string{"gpt", "claude", "gemini", "qwen", "deepseek"}
	familyRank := func(id string) int {
		f := family(id)
		if f == family(original.ModelID) {
			return 10
		}
		for rank, name := range preferred {
			if f == name {
				return rank
			}
		}
		return 11
	}
	ranks := map[string]int{}
	for _, o := range options {
		if _, exists := ranks[o.SourceID]; !exists {
			ranks[o.SourceID] = len(ranks)
		}
	}
	sort.SliceStable(options, func(i, j int) bool {
		a, b := options[i], options[j]
		if a.SourceID != b.SourceID {
			return ranks[a.SourceID] < ranks[b.SourceID]
		}
		if ra, rb := familyRank(a.ModelID), familyRank(b.ModelID); ra != rb {
			return ra < rb
		}
		return strings.ToLower(a.ModelID) < strings.ToLower(b.ModelID)
	})
	// Fixed slots preserve same-platform then cross-platform semantics even when
	// one group has no compatible model.
	result := make([]Option, 2)
	for _, o := range options {
		if o.ID == SelectionReference(ref) || strings.Contains(strings.ToLower(o.ModelID), "auto-review") {
			continue
		}
		slot := 1
		if o.SourceID == source {
			slot = 0
		}
		if result[slot].ID != "" {
			continue
		}
		route, e := s.Resolve(ctx, scope, o.ID)
		if e != nil || route.Protocol != original.Protocol || !route.ToolUse {
			continue
		}
		result[slot] = o
	}
	return result, nil
}

// PortableRecoveryBody deliberately excludes vendor thinking signatures,
// media, structured-output dialects and oversized histories. It never truncates
// successful tool results or changes the requested output token limit.
func PortableRecoveryBody(body json.RawMessage) bool {
	if len(body) > 64*1024 {
		return false
	}
	var input map[string]json.RawMessage
	if json.Unmarshal(body, &input) != nil {
		return false
	}
	allowed := map[string]bool{"model": true, "messages": true, "stream": true, "stream_options": true, "tools": true, "tool_choice": true, "max_tokens": true, "max_completion_tokens": true, "temperature": true, "top_p": true, "stop": true, "store": true}
	if store, ok := input["store"]; ok && string(store) != "false" {
		return false
	}
	for k := range input {
		if !allowed[k] {
			return false
		}
	}
	var messages []map[string]json.RawMessage
	if json.Unmarshal(input["messages"], &messages) != nil {
		return false
	}
	for _, msg := range messages {
		for k := range msg {
			if k != "role" && k != "content" && k != "tool_calls" && k != "tool_call_id" && k != "name" {
				return false
			}
		}
		content := msg["content"]
		if string(content) == "null" {
			continue
		}
		var text string
		if json.Unmarshal(content, &text) == nil {
			continue
		}
		var parts []map[string]json.RawMessage
		if json.Unmarshal(content, &parts) != nil {
			return false
		}
		for _, p := range parts {
			if string(p["type"]) != `"text"` {
				return false
			}
		}
	}
	return true
}

// Extract only fixed categories, never return provider text, model data or secrets.
func upstreamFailureKind(body []byte) string {
	var value struct {
		Error struct {
			Code    any    `json:"code"`
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
		Code    any    `json:"code"`
		Type    string `json:"type"`
		Message string `json:"message"`
	}
	if json.Unmarshal(body, &value) != nil {
		return "unknown"
	}
	message := strings.ToLower(fmt.Sprint(value.Error.Code) + " " + value.Error.Type + " " + value.Error.Message + " " + fmt.Sprint(value.Code) + " " + value.Type + " " + value.Message)
	for _, entry := range []struct {
		kind  string
		terms []string
	}{
		{"quota", []string{"insufficient_quota", "quota_exceeded", "billing_hard_limit", "free trial quota for the service has been exhausted", "insufficient balance", "余额不足", "额度不足"}},
		{"authentication", []string{"invalid_api_key", "authentication_error", "unauthorized"}},
		{"context_limit", []string{"context_length_exceeded", "maximum context length"}},
		{"token_limit", []string{"max_tokens", "max_completion_tokens"}},
		{"temperature", []string{"temperature"}},
		{"tools", []string{"tool_call", "tools", "function.parameters"}},
		{"model_unavailable", []string{"model_not_found", "model not found", "model does not exist"}},
		{"messages_required", []string{"field messages is required", "parameter messages is invalid or missing"}},
		{"request_invalid", []string{"invalidparameter", "invalid_request_error", "request body format invalid", "invalid request body", "request contains an invalid argument", "contents is not specified"}},
	} {
		for _, term := range entry.terms {
			if strings.Contains(message, term) {
				return entry.kind
			}
		}
	}
	return "unknown"
}

// upstreamFailureReason returns a short, user-safe explanation from the
// provider error. Raw bodies are intentionally never returned: an upstream
// may echo credentials, request content, or internal URLs.
func upstreamFailureReason(body []byte) string {
	var value struct {
		Error struct {
			Code    string `json:"code"`
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
		Code    string `json:"code"`
		Type    string `json:"type"`
		Message string `json:"message"`
	}
	if json.Unmarshal(body, &value) != nil {
		return ""
	}
	code, typ, message := value.Error.Code, value.Error.Type, value.Error.Message
	if code == "" && typ == "" && message == "" {
		code, typ, message = value.Code, value.Type, value.Message
	}
	parts := make([]string, 0, 2)
	if code != "" {
		parts = append(parts, code)
	} else if typ != "" {
		parts = append(parts, typ)
	}
	message = strings.Join(strings.Fields(message), " ")
	if message != "" {
		parts = append(parts, message)
	}
	reason := strings.Join(parts, ": ")
	for _, prefix := range []string{"sk-", "key-", "Bearer "} {
		if i := strings.Index(strings.ToLower(reason), strings.ToLower(prefix)); i >= 0 {
			reason = strings.TrimSpace(reason[:i])
		}
	}
	if len(reason) > 240 {
		reason = reason[:240]
	}
	return reason
}

func (e *UpstreamError) Retryable() bool {
	if e.Kind == "model_unavailable" && (e.Status == 400 || e.Status == 404) {
		return true
	}
	if e.Kind == "quota" || e.Kind == "authentication" || e.Kind == "request_invalid" || e.Kind == "messages_required" {
		return false
	}
	switch e.Status {
	case 408, 429, 500, 502, 503, 504:
		return true
	}
	return false
}

// PublicCode classifies failures without treating provider quota as Zhiban credits.
func (e *UpstreamError) PublicCode() string {
	switch e.Kind {
	case "messages_required":
		return "model.messages_required"
	case "quota":
		return "model.upstream_quota"
	case "authentication":
		return "model.authentication_failed"
	case "context_limit":
		return "model.context_limit"
	case "token_limit":
		return "model.token_limit"
	case "temperature":
		return "model.temperature_invalid"
	case "tools":
		return "model.tools_invalid"
	case "model_unavailable":
		return "model.unavailable"
	case "request_invalid":
		return "model.request_invalid"
	}
	switch e.Status {
	case 401, 403:
		return "model.authentication_failed"
	case 429:
		return "model.rate_limited"
	case 408, 504:
		return "model.timeout"
	}
	return "model.upstream_failure"
}
