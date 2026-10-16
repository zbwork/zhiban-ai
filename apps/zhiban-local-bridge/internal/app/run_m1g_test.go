package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/diagnostics"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/install"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/rpc"
)

type fakeInstallManager struct {
	registry       *operation.Registry
	planErr        error
	release        chan struct{}
	componentPlans []string
}

func (f *fakeInstallManager) Requirements(_ context.Context, targetID string) (install.Requirements, error) {
	return install.Requirements{TargetID: targetID, Version: "0.153.4", Satisfied: true, Issues: []string{}}, nil
}

func (f *fakeInstallManager) Plan(_ context.Context, targetID, mode string) (install.Plan, error) {
	if f.planErr != nil {
		return install.Plan{}, f.planErr
	}
	return install.Plan{PlanID: "plan-1", TargetID: targetID, Mode: mode, Version: "0.153.4"}, nil
}

func (f *fakeInstallManager) PlanComponent(_ context.Context, targetID, componentID string) (install.Plan, error) {
	if f.planErr != nil {
		return install.Plan{}, f.planErr
	}
	f.componentPlans = append(f.componentPlans, targetID+":"+componentID)
	return install.Plan{PlanID: "plan-1", TargetID: targetID, Mode: install.ModeComponent, Component: componentID, Version: "2.1.260"}, nil
}

func (f *fakeInstallManager) Execute(_ context.Context, planID string) (operation.Envelope, error) {
	if planID != "plan-1" {
		return operation.Envelope{}, operation.Fail("LCT-BRIDGE-OPERATION-NOT_FOUND", nil)
	}
	return f.registry.Start(operation.Spec{
		TargetID: "codex_cli", Kind: operation.KindInstall, InitialStage: "preflight", Cancellable: true,
		CancelCode: "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED", FailureCode: "LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED",
		Run: func(ctx context.Context, report *operation.Reporter) (any, error) {
			report.Progress("downloading", 50, true)
			select {
			case <-f.release:
				return nil, operation.Fail("LCT-CODEX_CLI-INSTALL-HASH_MISMATCH", nil)
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		},
	})
}

type policyConflictConfigurationManager struct{ fakeConfigurationManager }

func (p *policyConflictConfigurationManager) PlanWithType(context.Context, string, string, string) (configuration.Plan, error) {
	return configuration.Plan{}, configuration.ErrPolicyConflict
}

type fakeVerifyManager struct{ target, installation string }

func (f *fakeVerifyManager) Execute(_ context.Context, targetID, installationID, _ string) (operation.Envelope, error) {
	f.target = targetID
	f.installation = installationID
	return operation.Envelope{OperationID: "verify-1", TargetID: targetID, Kind: operation.KindVerify, State: operation.StateRunning, Stage: "l1", NextActions: []string{"cancel"}}, nil
}

func TestRunWiresM1GMethodsAndDomainErrors(t *testing.T) {
	t.Parallel()

	recorder := diagnostics.NewRecorder("0.3.0-test", nil)
	registry := operation.NewRegistry(operation.WithObserver(recorder.Observe))
	installs := &fakeInstallManager{registry: registry, release: make(chan struct{})}
	verifier := &fakeVerifyManager{}
	detector := &fakeDetector{state: detect.State{UIState: detect.UIStateUnsupported, ErrorCode: "LCT-CODEX_CLI-DETECT-MULTIPLE_INSTALLS", VerificationLevel: "l0", NextActions: []string{"detect"}}}

	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"requirements.get","params":{"target_id":"codex_cli"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"install.plan","params":{"target_id":"codex_cli","mode":"install"}}`,
		`{"jsonrpc":"2.0","id":4,"method":"install.execute","params":{"plan_id":"plan-1"}}`,
		`{"jsonrpc":"2.0","id":5,"method":"operation.get","params":{"operation_id":"does-not-exist"}}`,
		`{"jsonrpc":"2.0","id":6,"method":"verify.execute","params":{"target_id":"claude_cli","installation_id":"inst-1"}}`,
		`{"jsonrpc":"2.0","id":7,"method":"tool.detect","params":{"target_id":"codex_cli"}}`,
		`{"jsonrpc":"2.0","id":8,"method":"diagnostics.get_latest","params":{"target_id":"codex_cli"}}`,
		`{"jsonrpc":"2.0","id":9,"method":"install.plan","params":{"target_id":"codex_cli","mode":"reinstall"}}`,
	}, "\n") + "\n"
	var stdout, stderr bytes.Buffer
	exitCode := Run(context.Background(), nil, strings.NewReader(input), &stdout, &stderr, Config{
		BridgeVersion: "0.3.0-test", Platform: "macos", Arch: "arm64",
		Detector: detector, Installs: installs, Verifier: verifier, Operations: registry, Diagnostics: recorder,
	})
	if exitCode != 0 || stderr.Len() != 0 {
		t.Fatalf("Run() exit = %d stderr = %q", exitCode, stderr.String())
	}
	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if len(lines) != 9 {
		t.Fatalf("responses = %d: %s", len(lines), stdout.String())
	}
	responses := make([]rpc.Response, len(lines))
	for index, line := range lines {
		if err := json.Unmarshal([]byte(line), &responses[index]); err != nil {
			t.Fatalf("decode response %d: %v", index, err)
		}
	}

	var initResult rpc.InitializeResult
	if err := json.Unmarshal(responses[0].Result, &initResult); err != nil {
		t.Fatal(err)
	}
	methods := strings.Join(initResult.SupportedMethods, ",")
	if !strings.HasPrefix(methods, "tool.detect,") || !strings.HasSuffix(methods, "requirements.get,install.plan,install.execute,operation.get,operation.cancel,verify.execute,diagnostics.get_latest") {
		t.Fatalf("supported methods = %s", methods)
	}
	if responses[1].Error != nil || !strings.Contains(string(responses[1].Result), `"satisfied":true`) {
		t.Fatalf("requirements response = %+v", responses[1])
	}
	if responses[2].Error != nil || !strings.Contains(string(responses[2].Result), `"plan_id":"plan-1"`) {
		t.Fatalf("install.plan response = %+v", responses[2])
	}
	var envelope operation.Envelope
	if responses[3].Error != nil || json.Unmarshal(responses[3].Result, &envelope) != nil || envelope.State != operation.StateRunning || envelope.OperationID == "" {
		t.Fatalf("install.execute response = %+v", responses[3])
	}
	if responses[4].Error == nil || responses[4].Error.Code != rpc.CodeDomainError || responses[4].Error.Message != "LCT-BRIDGE-OPERATION-NOT_FOUND" {
		t.Fatalf("operation.get response = %+v", responses[4])
	}
	if responses[5].Error != nil || verifier.target != "claude_cli" || verifier.installation != "inst-1" || !strings.Contains(string(responses[5].Result), `"operation_id":"verify-1"`) {
		t.Fatalf("verify.execute response = %+v verifier=%+v", responses[5], verifier)
	}
	if responses[6].Error != nil {
		t.Fatalf("detect response = %+v", responses[6])
	}
	var latest diagnostics.Latest
	if responses[7].Error != nil || json.Unmarshal(responses[7].Result, &latest) != nil || latest.ErrorCode == nil ||
		*latest.ErrorCode != "LCT-CODEX_CLI-DETECT-MULTIPLE_INSTALLS" || *latest.Kind != diagnostics.KindDetect || latest.BridgeVersion != "0.3.0-test" {
		t.Fatalf("diagnostics response = %+v latest=%+v", responses[7], latest)
	}
	if responses[8].Error == nil || responses[8].Error.Code != rpc.CodeInvalidParams {
		t.Fatalf("install.plan bad mode response = %+v", responses[8])
	}

	// The stdio session ended while the install operation was still running:
	// Run must have cancelled it before returning.
	final, err := registry.Get(envelope.OperationID)
	if err != nil || final.State != operation.StateCancelled || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED" {
		t.Fatalf("operation after session end = %+v, %v", final, err)
	}
	if recorded := recorder.Latest("codex_cli"); recorded.ErrorCode == nil || *recorded.ErrorCode != "LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED" {
		t.Fatalf("diagnostics after shutdown = %+v", recorded)
	}
}

func TestRunMapsInstallPlanDomainErrorsAndKeepsInternalErrorsOpaque(t *testing.T) {
	t.Parallel()
	registry := operation.NewRegistry()
	installs := &fakeInstallManager{registry: registry, planErr: operation.Fail("LCT-CODEX_CLI-INSTALL-ALREADY_INSTALLED", nil)}
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"install.plan","params":{"target_id":"codex_cli"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"install.plan","params":{"target_id":"codex_cli"}}`,
	}, "\n") + "\n"
	var stdout, stderr bytes.Buffer
	detector := &fakeDetector{state: detect.State{UIState: detect.UIStateNotInstalled, VerificationLevel: "l0", NextActions: []string{"detect"}}}
	go func() {}()
	exitCode := Run(context.Background(), nil, strings.NewReader(input), &stdout, &stderr, Config{
		BridgeVersion: "0.3.0-test", Platform: "macos", Arch: "arm64", Detector: detector, Installs: installs, Operations: registry,
	})
	if exitCode != 0 {
		t.Fatalf("Run() exit = %d", exitCode)
	}
	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("responses: %s", stdout.String())
	}
	var second rpc.Response
	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatal(err)
	}
	if second.Error == nil || second.Error.Code != rpc.CodeDomainError || second.Error.Message != "LCT-CODEX_CLI-INSTALL-ALREADY_INSTALLED" {
		t.Fatalf("domain error response = %+v", second)
	}
	installs.planErr = errors.New("disk exploded with /Users/someone/secret")
	stdout.Reset()
	exitCode = Run(context.Background(), nil, strings.NewReader(input), &stdout, &stderr, Config{
		BridgeVersion: "0.3.0-test", Platform: "macos", Arch: "arm64", Detector: detector, Installs: installs, Operations: registry,
	})
	if exitCode != 0 || strings.Contains(stdout.String(), "secret") || !strings.Contains(stdout.String(), `"Internal error"`) {
		t.Fatalf("internal error leaked or missing: %s", stdout.String())
	}
}

func TestRunMapsManagedPolicyConflictToDomainError(t *testing.T) {
	t.Parallel()
	recorder := diagnostics.NewRecorder("0.3.0-test", nil)
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"config.plan","params":{"target_id":"claude_cli","installation_id":"inst-1","type":"enable"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"diagnostics.get_latest","params":{"target_id":"claude_cli"}}`,
	}, "\n") + "\n"
	var stdout, stderr bytes.Buffer
	exitCode := Run(context.Background(), nil, strings.NewReader(input), &stdout, &stderr, Config{
		BridgeVersion: "0.3.0-test", Platform: "macos", Arch: "arm64",
		Detector:       &fakeDetector{state: detect.State{UIState: detect.UIStateNotInstalled, VerificationLevel: "l0", NextActions: []string{"detect"}}},
		Configurations: &policyConflictConfigurationManager{}, Diagnostics: recorder,
	})
	if exitCode != 0 {
		t.Fatalf("Run() exit = %d", exitCode)
	}
	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("responses: %s", stdout.String())
	}
	var second rpc.Response
	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatal(err)
	}
	if second.Error == nil || second.Error.Code != rpc.CodeDomainError || second.Error.Message != "LCT-CLAUDE_CLI-CONFIG-POLICY_CONFLICT" {
		t.Fatalf("config.plan response = %+v", second)
	}
	if !strings.Contains(lines[2], `"error_code":"LCT-CLAUDE_CLI-CONFIG-POLICY_CONFLICT"`) {
		t.Fatalf("diagnostics response = %s", lines[2])
	}
}
