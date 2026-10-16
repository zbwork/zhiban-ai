package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/launch"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/rpc"
)

type fakeDetector struct {
	state detect.State
	calls int
}

type fakeCredentialManager struct {
	prepared       credential.RegistrationPreparation
	committed      credential.RegistrationCommit
	status         credential.Status
	cleared        bool
	exchangeToken  string
	exchangeErr    error
	exchangeTarget string
}

type fakeConfigurationManager struct {
	plannedTarget       string
	plannedInstallation string
	executedPlan        string
}

type fakeProjectLaunchManager struct {
	consumedTicket string
	consumeErr     error
}

func (f *fakeProjectLaunchManager) CreateProjectGrant(context.Context, string) (launch.ProjectGrant, error) {
	return launch.ProjectGrant{}, nil
}

func (f *fakeProjectLaunchManager) Plan(context.Context, launch.PlanRequest) (launch.Plan, error) {
	return launch.Plan{}, nil
}

func (f *fakeProjectLaunchManager) Execute(context.Context, string) (launch.ExecuteResult, error) {
	return launch.ExecuteResult{}, nil
}

func (f *fakeProjectLaunchManager) Consume(_ context.Context, ticketID string, _ []string) error {
	f.consumedTicket = ticketID
	return f.consumeErr
}

func (f *fakeConfigurationManager) Status(_ context.Context, targetID string) (configuration.Status, error) {
	return configuration.Status{TargetID: targetID, State: configuration.StateNotConfigured, VerificationLevel: "l0"}, nil
}

func (f *fakeConfigurationManager) Plan(_ context.Context, targetID, installationID string) (configuration.Plan, error) {
	f.plannedTarget = targetID
	f.plannedInstallation = installationID
	return configuration.Plan{PlanID: "plan-token", TargetID: targetID, Action: configuration.ActionCreate}, nil
}

func (f *fakeConfigurationManager) PlanWithType(ctx context.Context, targetID, installationID, _ string) (configuration.Plan, error) {
	return f.Plan(ctx, targetID, installationID)
}

func (f *fakeConfigurationManager) Execute(_ context.Context, planID string) (configuration.Status, error) {
	f.executedPlan = planID
	return configuration.Status{TargetID: configuration.TargetCodexCLI, State: configuration.StateConfigured, VerificationLevel: "l1"}, nil
}

func (f *fakeConfigurationManager) Restore(_ context.Context, targetID string) (configuration.Status, error) {
	return configuration.Status{TargetID: targetID, State: configuration.StateNotConfigured, VerificationLevel: "l0"}, nil
}

func (f *fakeCredentialManager) PrepareRegistration(_ context.Context, deviceID string, environment credential.Environment) (credential.RegistrationPreparation, error) {
	result := f.prepared
	result.DeviceID = deviceID
	return result, nil
}

func (f *fakeCredentialManager) CommitRegistration(_ context.Context, input credential.RegistrationCommit) error {
	f.committed = input
	return nil
}

func (f *fakeCredentialManager) Status(context.Context) (credential.Status, error) {
	return f.status, nil
}

func (f *fakeCredentialManager) ClearAuthorization(context.Context) error {
	f.cleared = true
	return nil
}

func (f *fakeCredentialManager) ExchangeToken(_ context.Context, targetID string) (string, error) {
	f.exchangeTarget = targetID
	return f.exchangeToken, f.exchangeErr
}

func (f *fakeDetector) Detect(_ context.Context, targetID string) (detect.State, error) {
	f.calls++
	result := f.state
	result.TargetID = targetID
	return result, nil
}

func TestRunServesInitializeAndDetectWithProtocolOnlyStdout(t *testing.T) {
	t.Parallel()

	detector := &fakeDetector{state: detect.State{
		InstallationID:    "opaque-id",
		Generation:        1,
		UIState:           detect.UIStateInstalledUnmanaged,
		InstalledVersion:  "0.153.4",
		InstallSource:     detect.SourceNPM,
		VerificationLevel: "l0",
		NextActions:       []string{"detect"},
	}}
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		`{"jsonrpc":"2.0","id":"2","method":"tool.detect","params":{"target_id":"codex_cli"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := Run(context.Background(), nil, strings.NewReader(input), &stdout, &stderr, Config{
		BridgeVersion: "0.1.0-test",
		Platform:      "macos",
		Arch:          "arm64",
		Detector:      detector,
	})
	if exitCode != 0 {
		t.Fatalf("Run() exit = %d stderr=%q", exitCode, stderr.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
	lines := strings.Split(strings.TrimSuffix(stdout.String(), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("stdout lines = %d: %q", len(lines), stdout.String())
	}
	for _, line := range lines {
		var response rpc.Response
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			t.Fatalf("stdout contains non-protocol text %q: %v", line, err)
		}
	}
	if detector.calls != 1 {
		t.Fatalf("detector calls = %d, want 1", detector.calls)
	}
}

func TestRunWiresConfigurationLifecycle(t *testing.T) {
	t.Parallel()

	manager := &fakeConfigurationManager{}
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		`{"jsonrpc":"2.0","id":"2","method":"config.status","params":{"target_id":"codex_cli"}}`,
		`{"jsonrpc":"2.0","id":"3","method":"config.plan","params":{"target_id":"codex_cli","installation_id":"opaque-install"}}`,
		`{"jsonrpc":"2.0","id":"4","method":"config.execute","params":{"plan_id":"plan-token"}}`,
		`{"jsonrpc":"2.0","id":"5","method":"config.restore","params":{"target_id":"codex_cli"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := Run(context.Background(), nil, strings.NewReader(input), &stdout, &stderr, Config{
		BridgeVersion: "0.3.0-test", Platform: "macos", Arch: "arm64",
		Detector: &fakeDetector{}, Configurations: manager,
	})
	if exitCode != 0 || stderr.Len() != 0 {
		t.Fatalf("Run() exit=%d stderr=%q", exitCode, stderr.String())
	}
	if manager.plannedTarget != configuration.TargetCodexCLI || manager.plannedInstallation != "opaque-install" || manager.executedPlan != "plan-token" {
		t.Fatalf("manager calls target=%q installation=%q plan=%q", manager.plannedTarget, manager.plannedInstallation, manager.executedPlan)
	}
	if strings.Contains(stdout.String(), "opaque-install") {
		t.Fatalf("RPC response leaked installation input: %s", stdout.String())
	}
}

func TestRunRejectsArgumentsAndUnsupportedPlatformWithoutStdout(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		args   []string
		config Config
	}{
		{
			name: "unknown argument", args: []string{"--command", "whoami"},
			config: Config{BridgeVersion: "test", Platform: "macos", Arch: "arm64", Detector: &fakeDetector{}},
		},
		{
			name:   "unsupported platform",
			config: Config{BridgeVersion: "test", Platform: "linux", Arch: "x64", Detector: &fakeDetector{}},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			exitCode := Run(context.Background(), tt.args, strings.NewReader(""), &stdout, &stderr, tt.config)
			if exitCode != 2 {
				t.Fatalf("Run() exit = %d, want 2", exitCode)
			}
			if stdout.Len() != 0 {
				t.Fatalf("stdout = %q, want empty", stdout.String())
			}
			if stderr.Len() == 0 || strings.Contains(stderr.String(), "whoami") {
				t.Fatalf("stderr = %q, want sanitized error", stderr.String())
			}
		})
	}
}

func TestRunLaunchConsumerUsesOnlyTheOneTimeTicket(t *testing.T) {
	t.Parallel()

	manager := &fakeProjectLaunchManager{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := Run(context.Background(), []string{"launch", "consume", "--ticket", "opaque-ticket"}, strings.NewReader(""), &stdout, &stderr, Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64", Launches: manager,
	})
	if exitCode != 0 || stdout.Len() != 0 || stderr.Len() != 0 || manager.consumedTicket != "opaque-ticket" {
		t.Fatalf("consumer exit=%d stdout=%q stderr=%q ticket=%q", exitCode, stdout.String(), stderr.String(), manager.consumedTicket)
	}

	manager.consumeErr = launch.ErrTicketExpired
	stdout.Reset()
	stderr.Reset()
	exitCode = Run(context.Background(), []string{"launch", "consume", "--ticket", "expired-ticket"}, strings.NewReader(""), &stdout, &stderr, Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64", Launches: manager,
	})
	if exitCode != 1 || stdout.Len() != 0 || stderr.String() != "LCT-LAUNCH-TICKET_INVALID\n" {
		t.Fatalf("failed consumer exit=%d stdout=%q stderr=%q", exitCode, stdout.String(), stderr.String())
	}
}

func TestRunFailsClosedOnProtocolError(t *testing.T) {
	t.Parallel()

	input := strings.Repeat("x", rpc.MaxFrameBytes+1) + "\n"
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := Run(context.Background(), nil, strings.NewReader(input), &stdout, &stderr, Config{
		BridgeVersion: "test",
		Platform:      "macos",
		Arch:          "arm64",
		Detector:      &fakeDetector{},
	})
	if exitCode != 1 || stdout.Len() != 0 || stderr.String() != "bridge protocol error\n" {
		t.Fatalf("Run() exit=%d stdout=%q stderr=%q", exitCode, stdout.String(), stderr.String())
	}
}

func TestRunWiresCredentialLifecycleWithoutLeakingCommitSecret(t *testing.T) {
	t.Parallel()

	manager := &fakeCredentialManager{
		prepared: credential.RegistrationPreparation{
			DevicePublicJWK: json.RawMessage(`{"kty":"OKP","crv":"Ed25519","x":"public"}`),
			DPoPProof:       "proof",
		},
		status: credential.Status{IdentityPresent: true, AuthorizationPresent: true, DeviceID: "11111111-1111-4111-8111-111111111111", Environment: credential.EnvironmentProd, Targets: []string{credential.TargetCodexCLI}},
	}
	secret := "lctd.22222222-2222-4222-8222-222222222222." + strings.Repeat("A", 48)
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		`{"jsonrpc":"2.0","id":"2","method":"credential.registration.prepare","params":{"device_id":"11111111-1111-4111-8111-111111111111","environment":"prod"}}`,
		`{"jsonrpc":"2.0","id":"3","method":"credential.registration.commit","params":{"credential_id":"22222222-2222-4222-8222-222222222222","device_credential":"` + secret + `","profile_versions":{"codex_cli":"2026.09.07.1"}}}`,
		`{"jsonrpc":"2.0","id":"4","method":"credential.status","params":{}}`,
		`{"jsonrpc":"2.0","id":"5","method":"credential.clear","params":{}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := Run(context.Background(), nil, strings.NewReader(input), &stdout, &stderr, Config{
		BridgeVersion: "0.2.0-test", Platform: "macos", Arch: "arm64",
		Detector: &fakeDetector{}, Credentials: manager,
	})
	if exitCode != 0 || stderr.Len() != 0 {
		t.Fatalf("Run() exit=%d stderr=%q", exitCode, stderr.String())
	}
	if manager.committed.DeviceCredential != secret || !manager.cleared {
		t.Fatalf("credential manager not called: committed=%+v cleared=%v", manager.committed, manager.cleared)
	}
	if strings.Contains(stdout.String(), secret) {
		t.Fatalf("RPC stdout leaked commit secret: %s", stdout.String())
	}
	if !strings.Contains(stdout.String(), `"device_public_jwk":{"kty":"OKP"`) {
		t.Fatalf("public JWK was not emitted as an object: %s", stdout.String())
	}
}

func TestRunCredentialHelperPrintsOnlyToken(t *testing.T) {
	t.Parallel()

	manager := &fakeCredentialManager{exchangeToken: "short-lived.jwt.token"}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := Run(context.Background(), []string{"credential", "get", "--target", "codex_cli"}, strings.NewReader(""), &stdout, &stderr, Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64", Credentials: manager,
	})
	if exitCode != 0 || stdout.String() != "short-lived.jwt.token\n" || stderr.Len() != 0 {
		t.Fatalf("helper exit=%d stdout=%q stderr=%q", exitCode, stdout.String(), stderr.String())
	}
	if manager.exchangeTarget != credential.TargetCodexCLI {
		t.Fatalf("exchange target = %q", manager.exchangeTarget)
	}
}

func TestRunCredentialHelperFailsClosedWithSanitizedErrors(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		target      string
		exchangeErr error
		wantStderr  string
	}{
		{name: "missing authorization", target: "codex_cli", exchangeErr: credential.ErrAuthorizationMissing, wantStderr: "LCT-CODEX_CLI-AUTH-DEVICE_MISSING\n"},
		{name: "network failure", target: "claude_cli", exchangeErr: errors.Join(credential.ErrExchangeUnavailable, errors.New("dial failed")), wantStderr: "LCT-CLAUDE_CLI-GATEWAY-UNREACHABLE\n"},
		{name: "rejected", target: "claude_cli", exchangeErr: credential.ErrExchangeRejected, wantStderr: "LCT-CLAUDE_CLI-AUTH-DEVICE_REVOKED\n"},
		{name: "out of credit", target: "codex_cli", exchangeErr: credential.ErrInsufficientCredit, wantStderr: "LCT-CODEX_CLI-AUTH-INSUFFICIENT_CREDIT\n"},
		{name: "member key disabled", target: "claude_cli", exchangeErr: credential.ErrMemberKeyDisabled, wantStderr: "LCT-CLAUDE_CLI-AUTH-MEMBER_KEY_DISABLED\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			manager := &fakeCredentialManager{exchangeErr: test.exchangeErr}
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			exitCode := Run(context.Background(), []string{"credential", "get", "--target", test.target}, strings.NewReader(""), &stdout, &stderr, Config{
				BridgeVersion: "test", Platform: "macos", Arch: "arm64", Credentials: manager,
			})
			if exitCode == 0 || stdout.Len() != 0 || stderr.String() != test.wantStderr {
				t.Fatalf("helper exit=%d stdout=%q stderr=%q", exitCode, stdout.String(), stderr.String())
			}
		})
	}

	manager := &fakeCredentialManager{exchangeToken: "must-not-run"}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if exitCode := Run(context.Background(), []string{"credential", "get", "--target", "other"}, strings.NewReader(""), &stdout, &stderr, Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64", Credentials: manager,
	}); exitCode == 0 || stdout.Len() != 0 || manager.exchangeTarget != "" {
		t.Fatalf("unknown target executed: exit=%d stdout=%q target=%q", exitCode, stdout.String(), manager.exchangeTarget)
	}
}
