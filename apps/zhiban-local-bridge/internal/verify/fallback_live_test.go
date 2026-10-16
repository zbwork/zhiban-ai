package verify

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/gatewaymodels"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// TestFallbackAgainstTheRealRelay is a manual end-to-end check
// (VERIFY_LIVE=1): the real verify flow, the real CLI, the real relay and the
// member key of this machine's signed Bridge. The configured model is made
// unusable in a throw-away HOME; the user's own configuration is not touched.
//
//	VERIFY_LIVE=1 VERIFY_LIVE_HELPER=<signed bridge> VERIFY_LIVE_CODEX=<codex> VERIFY_LIVE_CLAUDE=<claude> \
//	  go test ./internal/verify/ -run TestFallbackAgainstTheRealRelay -v -count=1
func TestFallbackAgainstTheRealRelay(t *testing.T) {
	if os.Getenv("VERIFY_LIVE") != "1" {
		t.Skip("set VERIFY_LIVE=1 to probe the real relay with the real CLIs")
	}
	helper := os.Getenv("VERIFY_LIVE_HELPER")
	executables := map[string]string{TargetCodexCLI: os.Getenv("VERIFY_LIVE_CODEX"), TargetClaudeCLI: os.Getenv("VERIFY_LIVE_CLAUDE")}
	brokenModel := map[string]string{TargetCodexCLI: "gpt-zhiban-does-not-exist", TargetClaudeCLI: "claude-zhiban-does-not-exist"}
	if override := os.Getenv("VERIFY_LIVE_MODEL"); override != "" {
		brokenModel = map[string]string{TargetCodexCLI: override, TargetClaudeCLI: override}
	}
	exchange := func(ctx context.Context, targetID string) (string, error) {
		output, err := exec.CommandContext(ctx, helper, "credential", "get", "--target", targetID).Output()
		return strings.TrimSpace(string(output)), err
	}
	for _, targetID := range []string{TargetCodexCLI, TargetClaudeCLI} {
		if executables[targetID] == "" {
			continue
		}
		t.Run(targetID, func(t *testing.T) {
			home := t.TempDir()
			writeLiveConfig(t, home, helper, brokenModel)
			registry := operation.NewRegistry()
			manager, err := NewManager(ManagerConfig{
				HomeDir: home, Operations: registry, TempRoot: home,
				ConfigurationStatus: func(_ context.Context, target string) (configuration.Status, error) {
					return configuration.Status{TargetID: target, State: configuration.StateConfigured, CurrentService: configuration.ServiceZhiban, ProfileVersion: "live"}, nil
				},
				ResolveInstallation: func(_ context.Context, target, id string) (Installation, error) {
					return Installation{TargetID: target, InstallationID: id, Executable: executables[target], Version: "live"}, nil
				},
				ManagedArguments: func(context.Context, string, string) ([]string, error) { return nil, nil },
				ExchangeToken:    exchange,
				RecordVerification: func(_ context.Context, target, _ string) (configuration.Status, error) {
					return configuration.Status{TargetID: target, VerificationLevel: configuration.VerificationL3}, nil
				},
				RecordGlobal: func(_ context.Context, target, _ string) (configuration.GlobalStatus, error) {
					return configuration.GlobalStatus{TargetID: target, VerificationLevel: configuration.VerificationL3, LastVerifiedAt: time.Now().UTC().Format(time.RFC3339)}, nil
				},
				// The office Mac runs a proxy tool; the relay must be reached directly.
				ProxyEnvironment: func(context.Context) []string {
					return []string{"NO_PROXY=api.airick.cn,.airick.cn", "no_proxy=api.airick.cn,.airick.cn"}
				},
				// Which model each probe run asked for ("" = the configured one).
				Run: func(ctx context.Context, invocation Invocation) (Outcome, error) {
					outcome, err := runProcess(ctx, invocation)
					t.Logf("probe model=%q exit=%d timed_out=%v", probeModel(targetID, invocation.Arguments), outcome.ExitCode, outcome.TimedOut)
					return outcome, err
				},
				FallbackModels: map[string][]string{TargetCodexCLI: {"gpt-5.6-terra", "gpt-5.5"}, TargetClaudeCLI: {"claude-sonnet-5", "claude-haiku-4-5-20251001"}},
				DefaultModels:  brokenModel,
				VisibleModels: func(ctx context.Context, target string) ([]string, error) {
					token, err := exchange(ctx, target)
					if err != nil {
						return nil, err
					}
					models, err := gatewaymodels.List(ctx, credential.NewSecureHTTPClient(), "https://api.airick.cn/v1", token)
					t.Logf("visible models: %d, error %v", len(models), err)
					return models, err
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			started := time.Now()
			envelope, err := manager.Execute(context.Background(), targetID, "live-install", ScopeGlobal)
			if err != nil {
				t.Fatalf("Execute: %v", err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
			defer cancel()
			final, err := registry.Wait(ctx, envelope.OperationID)
			if err != nil {
				t.Fatalf("Wait: %v", err)
			}
			raw, _ := json.Marshal(final)
			t.Logf("took %s\n%s", time.Since(started).Round(time.Second), raw)
			if final.State != operation.StateSucceeded {
				t.Fatalf("verification did not pass: %s", raw)
			}
			if warning := modelWarning(t, final); warning == nil || warning.WorkingModel == "" {
				t.Fatalf("passed without a model warning: %s", raw)
			}
		})
	}
}

// writeLiveConfig is what the switch writes, with a model the relay cannot serve.
func writeLiveConfig(t *testing.T, home, helper string, model map[string]string) {
	t.Helper()
	codex := "model_provider = \"zhiban_ai_managed\"\nmodel = \"" + model[TargetCodexCLI] + "\"\nanalytics.enabled = false\n\n" +
		"[model_providers.zhiban_ai_managed]\nname = \"Zhiban AI\"\nbase_url = \"https://api.airick.cn/v1\"\nwire_api = \"responses\"\nrequires_openai_auth = false\n" +
		"http_headers = { \"x-openai-actor-authorization\" = \"zhiban-ai\" }\n\n" +
		"[model_providers.zhiban_ai_managed.auth]\ncommand = \"" + helper + "\"\nargs = [\"credential\", \"get\", \"--target\", \"codex_cli\"]\ntimeout_ms = 5000\n"
	claude, _ := json.Marshal(map[string]any{
		"apiKeyHelper": "'" + helper + "' credential get --target claude_cli",
		"model":        model[TargetClaudeCLI],
		"env":          map[string]string{"ANTHROPIC_BASE_URL": "https://api.airick.cn"},
	})
	for path, content := range map[string][]byte{
		filepath.Join(home, ".codex", "config.toml"):    []byte(codex),
		filepath.Join(home, ".claude", "settings.json"): claude,
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, content, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}
