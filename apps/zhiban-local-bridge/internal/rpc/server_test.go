package rpc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestServerRequiresInitializeThenDispatchesDetect(t *testing.T) {
	t.Parallel()

	var targets []string
	server := NewServer(Config{
		BridgeVersion: "0.1.0-test",
		Platform:      "macos",
		Arch:          "arm64",
		Detect: func(_ context.Context, targetID string) (any, error) {
			targets = append(targets, targetID)
			return map[string]any{"target_id": targetID, "ui_state": "not_installed"}, nil
		},
	})

	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":"before","method":"tool.detect","params":{"target_id":"codex_cli"}}`,
		`{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64","locale":"zh-CN"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"tool.detect","params":{"target_id":"claude_cli"}}`,
	}, "\n") + "\n"

	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatalf("Serve() error = %v", err)
	}

	responses := decodeResponses(t, stdout.String())
	if len(responses) != 3 {
		t.Fatalf("responses = %d, want 3: %s", len(responses), stdout.String())
	}
	if responses[0].Error == nil || responses[0].Error.Code != CodeNotInitialized {
		t.Fatalf("first response = %+v, want not initialized", responses[0])
	}
	if responses[1].Error != nil {
		t.Fatalf("initialize response error = %+v", responses[1].Error)
	}
	var initResult InitializeResult
	if err := json.Unmarshal(responses[1].Result, &initResult); err != nil {
		t.Fatalf("decode initialize result: %v", err)
	}
	if initResult.ProtocolVersion != "1.0" || initResult.BridgeVersion != "0.1.0-test" {
		t.Fatalf("initialize result = %+v", initResult)
	}
	if len(initResult.SupportedMethods) != 1 || initResult.SupportedMethods[0] != "tool.detect" {
		t.Fatalf("supported methods = %v", initResult.SupportedMethods)
	}
	if responses[2].Error != nil || len(targets) != 1 || targets[0] != "claude_cli" {
		t.Fatalf("detect response = %+v targets=%v", responses[2], targets)
	}
}

func TestServerRejectsInvalidRequestsWithoutExecuting(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		frame    string
		wantCode int
	}{
		{name: "batch", frame: `[{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}]`, wantCode: CodeInvalidRequest},
		{name: "unknown request field", frame: `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{},"command":"whoami"}`, wantCode: CodeInvalidRequest},
		{name: "fractional id", frame: `{"jsonrpc":"2.0","id":1.5,"method":"initialize","params":{}}`, wantCode: CodeInvalidRequest},
		{name: "null id", frame: `{"jsonrpc":"2.0","id":null,"method":"initialize","params":{}}`, wantCode: CodeInvalidRequest},
		{name: "wrong version", frame: `{"jsonrpc":"1.0","id":1,"method":"initialize","params":{}}`, wantCode: CodeInvalidRequest},
		{name: "unknown init param", frame: `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64","path":"/tmp/tool"}}`, wantCode: CodeInvalidParams},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			called := false
			server := testServer(func(context.Context, string) (any, error) {
				called = true
				return nil, nil
			})
			var stdout bytes.Buffer
			if err := server.Serve(context.Background(), strings.NewReader(tt.frame+"\n"), &stdout); err != nil {
				t.Fatalf("Serve() error = %v", err)
			}
			responses := decodeResponses(t, stdout.String())
			if len(responses) != 1 || responses[0].Error == nil || responses[0].Error.Code != tt.wantCode {
				t.Fatalf("responses = %+v, want code %d", responses, tt.wantCode)
			}
			if called {
				t.Fatal("invalid request reached detector")
			}
		})
	}
}

func TestServerDropsNotificationsWithoutExecuting(t *testing.T) {
	t.Parallel()

	called := false
	server := testServer(func(context.Context, string) (any, error) {
		called = true
		return nil, nil
	})
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`,
		`{"jsonrpc":"2.0","method":"tool.detect","params":{"target_id":"codex_cli"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatalf("Serve() error = %v", err)
	}
	if stdout.Len() != 0 {
		t.Fatalf("notification stdout = %q, want empty", stdout.String())
	}
	if called {
		t.Fatal("notification reached detector")
	}
}

func TestServerRejectsRepeatedInitializeUnknownMethodAndUnsafeDetectParams(t *testing.T) {
	t.Parallel()

	server := testServer(func(context.Context, string) (any, error) {
		return nil, errors.New("must not be called")
	})
	input := strings.Join([]string{
		validInitialize("init"),
		validInitialize("again"),
		`{"jsonrpc":"2.0","id":"unknown","method":"install.execute","params":{}}`,
		`{"jsonrpc":"2.0","id":"unsafe","method":"tool.detect","params":{"target_id":"codex_cli","path":"/tmp/codex","env":{"TOKEN":"secret"}}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatalf("Serve() error = %v", err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 4 {
		t.Fatalf("responses = %d, want 4", len(responses))
	}
	if responses[1].Error == nil || responses[1].Error.Code != CodeAlreadyInitialized {
		t.Fatalf("repeat initialize response = %+v", responses[1])
	}
	if responses[2].Error == nil || responses[2].Error.Code != CodeMethodNotFound {
		t.Fatalf("unknown method response = %+v", responses[2])
	}
	if responses[3].Error == nil || responses[3].Error.Code != CodeInvalidParams {
		t.Fatalf("unsafe params response = %+v", responses[3])
	}
}

func TestServerFailsClosedOnOversizedFrame(t *testing.T) {
	t.Parallel()

	server := testServer(nil)
	oversized := strings.Repeat("x", MaxFrameBytes+1) + "\n" + validInitialize("ignored") + "\n"
	var stdout bytes.Buffer
	err := server.Serve(context.Background(), strings.NewReader(oversized), &stdout)
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("Serve() error = %v, want ErrFrameTooLarge", err)
	}
	if stdout.Len() != 0 {
		t.Fatalf("oversized frame stdout = %q, want empty", stdout.String())
	}
}

func TestServerDispatchesCredentialLifecycleAfterInitialize(t *testing.T) {
	t.Parallel()

	var prepared CredentialPrepareParams
	var committed CredentialCommitParams
	statusCalls := 0
	clearCalls := 0
	server := NewServer(Config{
		BridgeVersion: "0.2.0-test",
		Platform:      "macos",
		Arch:          "arm64",
		Detect: func(context.Context, string) (any, error) {
			return map[string]string{"ui_state": "not_installed"}, nil
		},
		CredentialPrepare: func(_ context.Context, params CredentialPrepareParams) (any, error) {
			prepared = params
			return json.RawMessage(`{"device_id":"11111111-1111-4111-8111-111111111111","device_public_jwk":{"kty":"OKP","crv":"Ed25519","x":"public"},"dpop_proof":"proof"}`), nil
		},
		CredentialCommit: func(_ context.Context, params CredentialCommitParams) error {
			committed = params
			return nil
		},
		CredentialStatus: func(context.Context) (any, error) {
			statusCalls++
			return map[string]any{"identity_present": true, "authorization_present": true, "targets": []string{"codex_cli"}}, nil
		},
		CredentialClear: func(context.Context) error {
			clearCalls++
			return nil
		},
	})
	deviceCredential := "lctd.22222222-2222-4222-8222-222222222222." + strings.Repeat("A", 48)
	input := strings.Join([]string{
		validInitialize("init"),
		`{"jsonrpc":"2.0","id":"prepare","method":"credential.registration.prepare","params":{"device_id":"11111111-1111-4111-8111-111111111111","environment":"prod"}}`,
		`{"jsonrpc":"2.0","id":"commit","method":"credential.registration.commit","params":{"credential_id":"22222222-2222-4222-8222-222222222222","device_credential":"` + deviceCredential + `","profile_versions":{"codex_cli":"2026.09.07.1"}}}`,
		`{"jsonrpc":"2.0","id":"status","method":"credential.status","params":{}}`,
		`{"jsonrpc":"2.0","id":"clear","method":"credential.clear","params":{}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 5 {
		t.Fatalf("responses = %d, want 5: %s", len(responses), stdout.String())
	}
	var initialize InitializeResult
	if err := json.Unmarshal(responses[0].Result, &initialize); err != nil {
		t.Fatal(err)
	}
	wantMethods := []string{"tool.detect", "credential.registration.prepare", "credential.registration.commit", "credential.status", "credential.clear"}
	if strings.Join(initialize.SupportedMethods, ",") != strings.Join(wantMethods, ",") {
		t.Fatalf("supported methods = %v", initialize.SupportedMethods)
	}
	if prepared.DeviceID != "11111111-1111-4111-8111-111111111111" || prepared.Environment != "prod" {
		t.Fatalf("prepare params = %+v", prepared)
	}
	if committed.CredentialID != "22222222-2222-4222-8222-222222222222" || committed.DeviceCredential != deviceCredential || committed.ProfileVersions["codex_cli"] != "2026.09.07.1" {
		t.Fatalf("commit params = %+v", committed)
	}
	if statusCalls != 1 || clearCalls != 1 {
		t.Fatalf("status calls=%d clear calls=%d", statusCalls, clearCalls)
	}
	for index, response := range responses {
		if response.Error != nil {
			t.Fatalf("response %d error = %+v", index, response.Error)
		}
	}
	if strings.Contains(stdout.String(), deviceCredential) {
		t.Fatalf("credential echoed to RPC stdout: %s", stdout.String())
	}
}

func TestServerRejectsUnsafeCredentialParamsWithoutExecuting(t *testing.T) {
	t.Parallel()

	called := false
	server := NewServer(Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64",
		CredentialPrepare: func(context.Context, CredentialPrepareParams) (any, error) { called = true; return nil, nil },
		CredentialCommit:  func(context.Context, CredentialCommitParams) error { called = true; return nil },
		CredentialStatus:  func(context.Context) (any, error) { called = true; return nil, nil },
		CredentialClear:   func(context.Context) error { called = true; return nil },
	})
	input := strings.Join([]string{
		validInitialize("init"),
		`{"jsonrpc":"2.0","id":1,"method":"credential.registration.prepare","params":{"device_id":"11111111-1111-4111-8111-111111111111","environment":"prod","url":"https://evil.example"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"credential.registration.commit","params":{"credential_id":"id","device_credential":"secret","profile_versions":{},"access_token":"app-token"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"credential.status","params":{"env":{"TOKEN":"secret"}}}`,
		`{"jsonrpc":"2.0","id":4,"method":"credential.clear","params":{"command":"security"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 5 {
		t.Fatalf("responses = %d", len(responses))
	}
	for _, response := range responses[1:] {
		if response.Error == nil || response.Error.Code != CodeInvalidParams {
			t.Fatalf("unsafe response = %+v", response)
		}
	}
	if called {
		t.Fatal("unsafe credential request reached lifecycle callback")
	}
}

func TestServerDispatchesTypedConfigurationLifecycle(t *testing.T) {
	t.Parallel()

	var planned ConfigPlanParams
	var executed string
	var statusTarget string
	var restoredTarget string
	server := NewServer(Config{
		BridgeVersion: "0.3.0-test", Platform: "macos", Arch: "arm64",
		ConfigStatus: func(_ context.Context, targetID string) (any, error) {
			statusTarget = targetID
			return map[string]string{"target_id": targetID, "state": "not_configured"}, nil
		},
		ConfigPlan: func(_ context.Context, params ConfigPlanParams) (any, error) {
			planned = params
			return map[string]string{"plan_id": "plan-token", "action": "create"}, nil
		},
		ConfigExecute: func(_ context.Context, planID string) (any, error) {
			executed = planID
			return map[string]string{"target_id": "codex_cli", "state": "configured"}, nil
		},
		ConfigRestore: func(_ context.Context, targetID string) (any, error) {
			restoredTarget = targetID
			return map[string]string{"target_id": targetID, "state": "not_configured"}, nil
		},
	})
	input := strings.Join([]string{
		validInitialize("init"),
		`{"jsonrpc":"2.0","id":1,"method":"config.status","params":{"target_id":"codex_cli"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"config.plan","params":{"target_id":"codex_cli","installation_id":"opaque-install"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"config.execute","params":{"plan_id":"plan-token"}}`,
		`{"jsonrpc":"2.0","id":4,"method":"config.restore","params":{"target_id":"claude_cli"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 5 {
		t.Fatalf("responses = %d: %s", len(responses), stdout.String())
	}
	var initialized InitializeResult
	if err := json.Unmarshal(responses[0].Result, &initialized); err != nil {
		t.Fatal(err)
	}
	wantMethods := []string{"config.status", "config.plan", "config.execute", "config.restore"}
	if strings.Join(initialized.SupportedMethods, ",") != strings.Join(wantMethods, ",") {
		t.Fatalf("supported methods = %v", initialized.SupportedMethods)
	}
	for index, response := range responses {
		if response.Error != nil {
			t.Fatalf("response %d error = %+v", index, response.Error)
		}
	}
	if statusTarget != "codex_cli" || planned.TargetID != "codex_cli" || planned.InstallationID != "opaque-install" || executed != "plan-token" || restoredTarget != "claude_cli" {
		t.Fatalf("dispatch status=%q planned=%+v executed=%q restored=%q", statusTarget, planned, executed, restoredTarget)
	}
}

func TestServerRejectsUnsafeConfigurationParamsWithoutExecuting(t *testing.T) {
	t.Parallel()

	called := false
	server := NewServer(Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64",
		ConfigStatus:  func(context.Context, string) (any, error) { called = true; return nil, nil },
		ConfigPlan:    func(context.Context, ConfigPlanParams) (any, error) { called = true; return nil, nil },
		ConfigExecute: func(context.Context, string) (any, error) { called = true; return nil, nil },
		ConfigRestore: func(context.Context, string) (any, error) { called = true; return nil, nil },
	})
	input := strings.Join([]string{
		validInitialize("init"),
		`{"jsonrpc":"2.0","id":1,"method":"config.status","params":{"target_id":"other"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"config.plan","params":{"target_id":"codex_cli","installation_id":"id","gateway_url":"https://evil.example"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"config.execute","params":{"plan_id":"id","command":"whoami"}}`,
		`{"jsonrpc":"2.0","id":4,"method":"config.restore","params":{"target_id":"claude_cli","force":true}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 5 {
		t.Fatalf("responses = %d", len(responses))
	}
	for _, response := range responses[1:] {
		if response.Error == nil || response.Error.Code != CodeInvalidParams {
			t.Fatalf("unsafe response = %+v", response)
		}
	}
	if called {
		t.Fatal("unsafe configuration request reached callback")
	}
}

func TestServerDispatchesProjectGrantAndLaunchPlanWithoutPathParameters(t *testing.T) {
	t.Parallel()

	var bookmark ProjectGrantCreateParams
	var planned LaunchPlanParams
	executed := ""
	server := NewServer(Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64",
		ProjectGrantCreate: func(_ context.Context, params ProjectGrantCreateParams) (any, error) {
			bookmark = params
			return map[string]string{"project_grant_id": "grant", "display_name": "project", "expires_at": "2026-09-07T10:05:00Z"}, nil
		},
		LaunchPlan: func(_ context.Context, params LaunchPlanParams) (any, error) {
			planned = params
			return map[string]string{"launch_plan_id": "plan", "target_id": params.TargetID, "project_name": "project", "expires_at": "2026-09-07T10:02:00Z"}, nil
		},
		LaunchExecute: func(_ context.Context, planID string) (any, error) {
			executed = planID
			return map[string]string{"state": "launched", "target_id": "codex_cli", "project_name": "project"}, nil
		},
	})
	input := strings.Join([]string{
		validInitialize("init"),
		`{"jsonrpc":"2.0","id":1,"method":"project.grant.create","params":{"bookmark_data":"Ym9va21hcms="}}`,
		`{"jsonrpc":"2.0","id":2,"method":"launch.plan","params":{"target_id":"codex_cli","installation_id":"opaque-install","project_grant_id":"opaque-grant","profile_version":"2026.09.07.1"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"launch.execute","params":{"plan_id":"opaque-plan"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 4 {
		t.Fatalf("responses = %d: %s", len(responses), stdout.String())
	}
	var initialized InitializeResult
	if err := json.Unmarshal(responses[0].Result, &initialized); err != nil {
		t.Fatal(err)
	}
	wantMethods := []string{"project.grant.create", "launch.plan", "launch.execute"}
	if strings.Join(initialized.SupportedMethods, ",") != strings.Join(wantMethods, ",") {
		t.Fatalf("supported methods = %v", initialized.SupportedMethods)
	}
	if bookmark.BookmarkData != "Ym9va21hcms=" || planned.TargetID != "codex_cli" || planned.InstallationID != "opaque-install" || planned.ProjectGrantID != "opaque-grant" || planned.ProfileVersion != "2026.09.07.1" || executed != "opaque-plan" {
		t.Fatalf("bookmark=%+v planned=%+v executed=%q", bookmark, planned, executed)
	}
	for index, response := range responses {
		if response.Error != nil {
			t.Fatalf("response %d error = %+v", index, response.Error)
		}
	}
}

func TestServerRejectsUnsafeProjectGrantAndLaunchPlanParams(t *testing.T) {
	t.Parallel()

	called := false
	server := NewServer(Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64",
		ProjectGrantCreate: func(context.Context, ProjectGrantCreateParams) (any, error) { called = true; return nil, nil },
		LaunchPlan:         func(context.Context, LaunchPlanParams) (any, error) { called = true; return nil, nil },
		LaunchExecute:      func(context.Context, string) (any, error) { called = true; return nil, nil },
	})
	input := strings.Join([]string{
		validInitialize("init"),
		`{"jsonrpc":"2.0","id":1,"method":"project.grant.create","params":{"bookmark_data":"Ym9va21hcms=","path":"/tmp/private"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"project.grant.create","params":{"bookmark_data":"%%%"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"launch.plan","params":{"target_id":"codex_cli","installation_id":"install","project_grant_id":"grant","profile_version":"v1","command":"whoami"}}`,
		`{"jsonrpc":"2.0","id":4,"method":"launch.plan","params":{"target_id":"other","installation_id":"install","project_grant_id":"grant","profile_version":"v1"}}`,
		`{"jsonrpc":"2.0","id":5,"method":"launch.execute","params":{"plan_id":"plan","command":"whoami"}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 6 {
		t.Fatalf("responses = %d", len(responses))
	}
	for _, response := range responses[1:] {
		if response.Error == nil || response.Error.Code != CodeInvalidParams {
			t.Fatalf("unsafe response = %+v", response)
		}
	}
	if called {
		t.Fatal("unsafe launch request reached callback")
	}
}

func TestServerSanitizesCredentialLifecycleErrors(t *testing.T) {
	t.Parallel()

	secret := "lctd.22222222-2222-4222-8222-222222222222." + strings.Repeat("S", 48)
	server := NewServer(Config{
		BridgeVersion: "test", Platform: "macos", Arch: "arm64",
		CredentialCommit: func(context.Context, CredentialCommitParams) error {
			return errors.New("keychain failed for " + secret)
		},
	})
	input := strings.Join([]string{
		validInitialize("init"),
		`{"jsonrpc":"2.0","id":1,"method":"credential.registration.commit","params":{"credential_id":"22222222-2222-4222-8222-222222222222","device_credential":"` + secret + `","profile_versions":{"codex_cli":"2026.09.07.1"}}}`,
	}, "\n") + "\n"
	var stdout bytes.Buffer
	if err := server.Serve(context.Background(), strings.NewReader(input), &stdout); err != nil {
		t.Fatal(err)
	}
	responses := decodeResponses(t, stdout.String())
	if len(responses) != 2 || responses[1].Error == nil || responses[1].Error.Code != CodeInternalError {
		t.Fatalf("response = %+v", responses)
	}
	if strings.Contains(stdout.String(), secret) {
		t.Fatalf("error response leaked credential: %s", stdout.String())
	}
}

func FuzzServerFrame(f *testing.F) {
	f.Add(validInitialize("seed"))
	f.Add(`{"jsonrpc":"2.0","id":1,"method":"tool.detect","params":{"target_id":"codex_cli"}}`)
	f.Add(`{"jsonrpc":"2.0","id":2,"method":"credential.registration.prepare","params":{"device_id":"11111111-1111-4111-8111-111111111111","environment":"prod"}}`)
	f.Add(`{"jsonrpc":"2.0","id":3,"method":"credential.registration.commit","params":{"credential_id":"22222222-2222-4222-8222-222222222222","device_credential":"secret","profile_versions":{"codex_cli":"v1"}}}`)
	f.Add(`{"jsonrpc":"2.0","id":4,"method":"credential.status","params":{"url":"https://evil.example"}}`)
	f.Add(`[]`)
	f.Add(`{"jsonrpc":`)

	f.Fuzz(func(t *testing.T, frame string) {
		if len(frame) > MaxFrameBytes {
			t.Skip()
		}
		server := testServer(func(_ context.Context, targetID string) (any, error) {
			return map[string]string{"target_id": targetID}, nil
		})
		var stdout bytes.Buffer
		_ = server.Serve(context.Background(), strings.NewReader(frame+"\n"), &stdout)
		if stdout.Len() > MaxFrameBytes*2 {
			t.Fatalf("unbounded output: %d", stdout.Len())
		}
	})
}

func testServer(detect DetectFunc) *Server {
	return NewServer(Config{
		BridgeVersion: "0.1.0-test",
		Platform:      "macos",
		Arch:          "arm64",
		Detect:        detect,
	})
}

func validInitialize(id string) string {
	return `{"jsonrpc":"2.0","id":"` + id + `","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.2.3","platform":"macos","arch":"arm64"}}`
}

func decodeResponses(t *testing.T, output string) []Response {
	t.Helper()
	if output == "" {
		return nil
	}
	lines := strings.Split(strings.TrimSuffix(output, "\n"), "\n")
	responses := make([]Response, 0, len(lines))
	for _, line := range lines {
		var response Response
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			t.Fatalf("decode response %q: %v", line, err)
		}
		responses = append(responses, response)
	}
	return responses
}
