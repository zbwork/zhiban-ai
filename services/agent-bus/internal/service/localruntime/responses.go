package localruntime

import (
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

// Native model tools execute on the desktop; hosted tools would bypass its policy/lease gates.
func NormalizeResponses(body json.RawMessage) (json.RawMessage, error) {
	var in map[string]json.RawMessage
	if json.Unmarshal(body, &in) != nil || in == nil {
		return nil, dom.ErrDenied
	}
	for _, key := range []string{"previous_response_id", "conversation"} {
		if v, ok := in[key]; ok && string(v) != "null" {
			return nil, dom.ErrDenied
		}
	}
	type responseTool struct {
		Type  string `json:"type"`
		Tools []struct {
			Type string `json:"type"`
		} `json:"tools"`
	}
	var tools []responseTool
	if raw, ok := in["tools"]; ok {
		if json.Unmarshal(raw, &tools) != nil {
			return nil, dom.ErrDenied
		}
	}
	for _, tool := range tools {
		switch tool.Type {
		case "function", "custom":
		case "namespace":
			if len(tool.Tools) == 0 {
				return nil, dom.ErrDenied
			}
			for _, child := range tool.Tools {
				if child.Type != "function" && child.Type != "custom" {
					return nil, dom.ErrDenied
				}
			}
		default:
			return nil, dom.ErrDenied
		}
	}
	in["store"] = json.RawMessage("false")
	// Background execution is opt-in. Omission keeps synchronous execution and
	// supports compatible gateways that reject even background=false.
	delete(in, "background")
	return json.Marshal(in)
}
