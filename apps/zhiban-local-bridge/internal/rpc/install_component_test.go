package rpc

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

// M3 Task 8 · install.plan carries an optional component; only the Claude Code
// host component is known, and mode must be left empty with it.
func TestInstallPlanAcceptsTheClaudeCodeHostComponent(t *testing.T) {
	t.Parallel()
	var planned []InstallPlanParams
	server := NewServer(Config{
		BridgeVersion: "0.4.0-test",
		Platform:      "macos",
		Arch:          "arm64",
		InstallPlan: func(_ context.Context, params InstallPlanParams) (any, error) {
			planned = append(planned, params)
			return map[string]any{"plan_id": "p1", "target_id": params.TargetID, "mode": "component", "component": params.Component}, nil
		},
		InstallExecute: func(context.Context, string) (any, error) { return map[string]any{}, nil },
	})
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64","locale":"zh-CN"}}`,
		`{"jsonrpc":"2.0","id":1,"method":"install.plan","params":{"target_id":"claude_desktop","component":"claude_code_host"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"install.plan","params":{"target_id":"claude_desktop","component":"claude_code_host","mode":"install"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"install.plan","params":{"target_id":"claude_desktop","component":"vm_bundle"}}`,
		`{"jsonrpc":"2.0","id":4,"method":"install.plan","params":{"target_id":"codex_cli","mode":"install"}}`,
	}, "\n") + "\n"

	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatalf("Serve() error = %v", err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 5 {
		t.Fatalf("responses = %d, want 5: %s", len(responses), stdout.String())
	}
	if responses[1].Error != nil {
		t.Fatalf("component plan must be accepted: %+v", responses[1].Error)
	}
	for _, index := range []int{2, 3} {
		if responses[index].Error == nil || responses[index].Error.Code != CodeInvalidParams {
			t.Fatalf("response %d must be Invalid params: %+v", index, responses[index])
		}
	}
	if responses[4].Error != nil {
		t.Fatalf("plain install plan must still work: %+v", responses[4].Error)
	}
	if len(planned) != 2 || planned[0].Component != "claude_code_host" || planned[0].Mode != "" || planned[1].Component != "" {
		t.Fatalf("planned = %+v", planned)
	}
}
