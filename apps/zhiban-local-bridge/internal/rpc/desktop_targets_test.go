package rpc

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

// M3: every method accepts the two desktop targets; the managers behind them
// decide what a desktop target supports. Unknown ids are still rejected.
func TestDesktopTargetsAcceptedAcrossMethods(t *testing.T) {
	t.Parallel()
	var detected, required []string
	server := NewServer(Config{
		BridgeVersion: "0.4.0-test",
		Platform:      "macos",
		Arch:          "arm64",
		Detect: func(_ context.Context, targetID string) (any, error) {
			detected = append(detected, targetID)
			return map[string]any{"target_id": targetID, "ui_state": "not_installed", "form_factor": "desktop"}, nil
		},
		Requirements: func(_ context.Context, targetID string) (any, error) {
			required = append(required, targetID)
			return map[string]any{"target_id": targetID, "satisfied": true}, nil
		},
		ConfigStatus: func(_ context.Context, targetID string) (any, error) {
			return map[string]any{"target_id": targetID, "state": "not_configured", "current_service": "official"}, nil
		},
	})

	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64","locale":"zh-CN"}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tool.detect","params":{"target_id":"codex_desktop"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"requirements.get","params":{"target_id":"claude_desktop"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"config.status","params":{"target_id":"claude_desktop"}}`,
		`{"jsonrpc":"2.0","id":4,"method":"tool.detect","params":{"target_id":"codex_web"}}`,
	}, "\n") + "\n"

	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatalf("Serve() error = %v", err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 5 {
		t.Fatalf("responses = %d, want 5: %s", len(responses), stdout.String())
	}
	if responses[1].Error != nil || responses[2].Error != nil {
		t.Fatalf("desktop detect/requirements must succeed: %+v %+v", responses[1].Error, responses[2].Error)
	}
	if responses[3].Error != nil {
		t.Fatalf("config.status for a desktop target must be accepted: %+v", responses[3].Error)
	}
	if responses[4].Error == nil || responses[4].Error.Code != CodeInvalidParams {
		t.Fatalf("unknown target must be rejected: %+v", responses[4])
	}
	if len(detected) != 1 || detected[0] != "codex_desktop" || len(required) != 1 || required[0] != "claude_desktop" {
		t.Fatalf("detected=%v required=%v", detected, required)
	}
}
