package rpc

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

func TestServerAcceptsGlobalSwitchVerifyScopeAndHomeLaunch(t *testing.T) {
	t.Parallel()

	var plans []ConfigPlanParams
	var verifies []VerifyExecuteParams
	var launches []LaunchPlanParams
	server := NewServer(Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64",
		ConfigStatus: func(context.Context, string) (any, error) { return map[string]string{}, nil },
		ConfigPlan: func(_ context.Context, params ConfigPlanParams) (any, error) {
			plans = append(plans, params)
			return map[string]string{"plan_id": "plan"}, nil
		},
		ConfigExecute: func(context.Context, string) (any, error) { return map[string]string{}, nil },
		ConfigRestore: func(context.Context, string) (any, error) { return map[string]string{}, nil },
		VerifyExecute: func(_ context.Context, params VerifyExecuteParams) (any, error) {
			verifies = append(verifies, params)
			return map[string]string{"operation_id": "op"}, nil
		},
		LaunchPlan: func(_ context.Context, params LaunchPlanParams) (any, error) {
			launches = append(launches, params)
			return map[string]string{"launch_plan_id": "plan"}, nil
		},
		LaunchExecute:      func(context.Context, string) (any, error) { return nil, nil },
		ProjectGrantCreate: func(context.Context, ProjectGrantCreateParams) (any, error) { return nil, nil },
	})
	input := strings.Join([]string{
		validInitialize("init"),
		// valid
		`{"jsonrpc":"2.0","id":1,"method":"config.plan","params":{"target_id":"codex_cli","installation_id":"install","type":"switch_global"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"config.plan","params":{"target_id":"claude_cli","type":"restore_global"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"verify.execute","params":{"target_id":"codex_cli","installation_id":"install","scope":"global"}}`,
		`{"jsonrpc":"2.0","id":4,"method":"launch.plan","params":{"target_id":"codex_cli","installation_id":"install","mode":"official"}}`,
		// invalid
		`{"jsonrpc":"2.0","id":5,"method":"config.plan","params":{"target_id":"codex_cli","installation_id":"install","type":"switch_everything"}}`,
		`{"jsonrpc":"2.0","id":6,"method":"config.plan","params":{"target_id":"codex_cli","type":"switch_global"}}`,
		`{"jsonrpc":"2.0","id":7,"method":"verify.execute","params":{"target_id":"codex_cli","installation_id":"install","scope":"system"}}`,
		`{"jsonrpc":"2.0","id":8,"method":"launch.plan","params":{"target_id":"codex_cli","installation_id":"install","profile_version":"v1"}}`,
		`{"jsonrpc":"2.0","id":9,"method":"launch.plan","params":{"target_id":"codex_cli","installation_id":"install","mode":"managed"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 10 {
		t.Fatalf("responses = %d: %s", len(responses), stdout.String())
	}
	for _, response := range responses[1:5] {
		if response.Error != nil {
			t.Fatalf("valid request rejected: %+v", response)
		}
	}
	for _, response := range responses[5:] {
		if response.Error == nil || response.Error.Code != CodeInvalidParams {
			t.Fatalf("invalid request accepted: %+v", response)
		}
	}
	if len(plans) != 2 || plans[0].Type != "switch_global" || plans[1].Type != "restore_global" || plans[1].InstallationID != "" {
		t.Fatalf("plans = %+v", plans)
	}
	if len(verifies) != 1 || verifies[0].Scope != "global" {
		t.Fatalf("verifies = %+v", verifies)
	}
	if len(launches) != 1 || launches[0].Mode != "official" || launches[0].ProjectGrantID != "" {
		t.Fatalf("launches = %+v", launches)
	}
}

// Contract §2.7.2: config.execute / config.restore report a §6 code for the
// failures the App acts on (retry the write, re-detect), not -32603.
func TestServerConfigWriteFailuresCarryTheDomainCode(t *testing.T) {
	t.Parallel()
	server := NewServer(Config{
		BridgeVersion: "0.4.0-test", Platform: "macos", Arch: "arm64",
		ConfigStatus: func(context.Context, string) (any, error) { return map[string]string{}, nil },
		ConfigPlan:   func(context.Context, ConfigPlanParams) (any, error) { return map[string]string{}, nil },
		ConfigExecute: func(context.Context, string) (any, error) {
			return nil, operation.Fail("LCT-CODEX_CLI-CONFIG-PRECONDITION_CHANGED", errors.New("changed"))
		},
		ConfigRestore: func(context.Context, string) (any, error) { return nil, errors.New("opaque") },
	})
	input := strings.Join([]string{
		validInitialize("init"),
		`{"jsonrpc":"2.0","id":1,"method":"config.execute","params":{"plan_id":"plan-token"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"config.restore","params":{"target_id":"codex_cli"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 3 {
		t.Fatalf("responses = %d: %s", len(responses), stdout.String())
	}
	if responses[1].Error == nil || responses[1].Error.Code != CodeDomainError ||
		responses[1].Error.Message != "LCT-CODEX_CLI-CONFIG-PRECONDITION_CHANGED" {
		t.Fatalf("config.execute error = %+v", responses[1].Error)
	}
	// An unclassified failure stays opaque.
	if responses[2].Error == nil || responses[2].Error.Code != CodeInternalError {
		t.Fatalf("config.restore error = %+v", responses[2].Error)
	}
}
