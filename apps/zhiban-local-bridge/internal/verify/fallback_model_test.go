package verify

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const (
	codexRelay502  = "ERROR: unexpected status 502 Bad Gateway: Upstream request failed (request id: r-1), url: https://api.airick.cn/v1/responses\n"
	claudeRelay502 = `{"type":"result","subtype":"success","is_error":true,"api_error_status":502,"result":"API Error: 502 Upstream request failed (request id: r-1)"}`
	claudeOK       = `{"type":"result","subtype":"success","is_error":false,"result":"ZHIBAN_L3_OK"}`
)

// probeModel tells which model a probe invocation asks for: "" is the model
// the user's configuration names (the probe passes none).
func probeModel(targetID string, arguments []string) string {
	for i, argument := range arguments {
		if targetID == TargetCodexCLI && argument == "-c" && i+1 < len(arguments) && strings.HasPrefix(arguments[i+1], "model=") {
			return strings.Trim(strings.TrimPrefix(arguments[i+1], "model="), `"`)
		}
		if targetID != TargetCodexCLI && argument == "--model" && i+1 < len(arguments) {
			return arguments[i+1]
		}
	}
	return ""
}

// relay answers a probe per model: models in down get the relay's 502.
type relay struct {
	targetID string
	down     map[string]bool
	asked    []string
	other    *Outcome // when set, the configured model fails this way instead
}

func (r *relay) run(_ context.Context, invocation Invocation) (Outcome, error) {
	model := probeModel(r.targetID, invocation.Arguments)
	r.asked = append(r.asked, model)
	if model == "" && r.other != nil {
		return *r.other, nil
	}
	if r.down[model] {
		if r.targetID == TargetCodexCLI {
			return Outcome{ExitCode: 1, Output: []byte(codexRelay502)}, nil
		}
		return Outcome{ExitCode: 1, Output: []byte(claudeRelay502)}, nil
	}
	if r.targetID == TargetCodexCLI {
		for i, argument := range invocation.Arguments {
			if argument == "-o" && i+1 < len(invocation.Arguments) {
				_ = os.WriteFile(invocation.Arguments[i+1], []byte("ZHIBAN_L3_OK\n"), 0o600)
			}
		}
		return Outcome{}, nil
	}
	return Outcome{Output: []byte(claudeOK)}, nil
}

func fallbackFixture(t *testing.T, r *relay) *fixture {
	t.Helper()
	return newFixture(t, successScript, func(config *ManagerConfig) {
		config.Run = r.run
		config.FallbackModels = map[string][]string{
			TargetCodexCLI:  {"gpt-5.6-terra", "gpt-5.5"},
			TargetClaudeCLI: {"claude-sonnet-5", "claude-haiku-4-5-20251001"},
		}
	})
}

func modelWarning(t *testing.T, envelope operation.Envelope) *ModelWarning {
	t.Helper()
	raw, err := json.Marshal(envelope.Result)
	if err != nil {
		t.Fatal(err)
	}
	var result Result
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	return result.ModelWarning
}

// 2026-09-20:中转站上 claude-sonnet-4-6 一条线路 502,检测就整体报"中转站不可用",
// 其实换个模型就能用。配置的模型模型侧失败时用备用模型补测,通一个即算通过并带提示。
func TestVerifyFallsBackToAnotherModelWhenTheConfiguredOneIsDown(t *testing.T) {
	t.Parallel()
	for _, targetID := range []string{TargetCodexCLI, TargetClaudeCLI} {
		t.Run(targetID, func(t *testing.T) {
			r := &relay{targetID: targetID, down: map[string]bool{"": true}}
			f := fallbackFixture(t, r)
			final := f.execute(t, targetID)
			if final.State != operation.StateSucceeded {
				t.Fatalf("final = %+v", final)
			}
			// The configured model twice (one retry), then the first fallback once.
			first := map[string]string{TargetCodexCLI: "gpt-5.6-terra", TargetClaudeCLI: "claude-sonnet-5"}[targetID]
			if want := []string{"", "", first}; strings.Join(r.asked, ",") != strings.Join(want, ",") {
				t.Fatalf("models asked = %q, want %q", r.asked, want)
			}
			warning := modelWarning(t, final)
			if warning == nil || warning.WorkingModel != first || !strings.HasSuffix(warning.ErrorCode, "-GATEWAY-UPSTREAM_UNAVAILABLE") || !strings.HasPrefix(warning.ErrorDetail, "HTTP 502") {
				t.Fatalf("model warning = %+v", warning)
			}
			if len(f.recorded) != 1 {
				t.Fatalf("a fallback pass must still record L3: %v", f.recorded)
			}
		})
	}
}

func TestVerifyTriesTheNextFallbackAndReportsTheConfiguredModelWhenAllFail(t *testing.T) {
	t.Parallel()
	second := &relay{targetID: TargetClaudeCLI, down: map[string]bool{"": true, "claude-sonnet-5": true}}
	f := fallbackFixture(t, second)
	final := f.execute(t, TargetClaudeCLI)
	if final.State != operation.StateSucceeded || modelWarning(t, final).WorkingModel != "claude-haiku-4-5-20251001" {
		t.Fatalf("final = %+v", final)
	}

	all := &relay{targetID: TargetClaudeCLI, down: map[string]bool{"": true, "claude-sonnet-5": true, "claude-haiku-4-5-20251001": true}}
	f = fallbackFixture(t, all)
	final = f.execute(t, TargetClaudeCLI)
	if final.State != operation.StateFailed || *final.ErrorCode != "LCT-CLAUDE_CLI-GATEWAY-UPSTREAM_UNAVAILABLE" || final.ErrorDetail == nil || !strings.HasPrefix(*final.ErrorDetail, "HTTP 502") {
		t.Fatalf("final = %+v", final)
	}
	if len(all.asked) != 4 || len(f.recorded) != 0 {
		t.Fatalf("asked %q recorded %v", all.asked, f.recorded)
	}
}

// 与模型无关的失败换模型也没用:不补测,免得白等。
func TestVerifyDoesNotFallBackForFailuresThatAreNotAboutTheModel(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		outcome Outcome
		options func(*ManagerConfig)
		want    string
	}{
		{name: "quota", outcome: Outcome{ExitCode: 1, Output: []byte("ERROR: unexpected status 429 Too Many Requests: quota exceeded, url: https://api.airick.cn/v1/responses\n")}, want: "-GATEWAY-QUOTA_EXHAUSTED"},
		{name: "unreachable", outcome: Outcome{ExitCode: 1, Output: []byte("error sending request: connection refused\n")}, want: "-GATEWAY-UNREACHABLE"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			outcome := test.outcome
			r := &relay{targetID: TargetCodexCLI, other: &outcome}
			f := newFixture(t, successScript, func(config *ManagerConfig) {
				config.Run = r.run
				config.FallbackModels = map[string][]string{TargetCodexCLI: {"gpt-5.6-terra"}}
				if test.options != nil {
					test.options(config)
				}
			})
			final := f.execute(t, TargetCodexCLI)
			if final.State != operation.StateFailed || !strings.HasSuffix(*final.ErrorCode, test.want) {
				t.Fatalf("final = %+v", final)
			}
			for _, model := range r.asked {
				if model != "" {
					t.Fatalf("a fallback model was probed: %q", r.asked)
				}
			}
		})
	}
}

// 没配备用模型(老行为)与配置的模型本来就通:都不多发请求、不带提示。
func TestVerifyWithoutFallbackNeedsIsUnchanged(t *testing.T) {
	t.Parallel()
	healthy := &relay{targetID: TargetClaudeCLI, down: map[string]bool{}}
	f := fallbackFixture(t, healthy)
	final := f.execute(t, TargetClaudeCLI)
	if final.State != operation.StateSucceeded || modelWarning(t, final) != nil || len(healthy.asked) != 1 {
		t.Fatalf("final = %+v asked %q", final, healthy.asked)
	}
	unconfigured := &relay{targetID: TargetClaudeCLI, down: map[string]bool{"": true}}
	f = newFixture(t, successScript, func(config *ManagerConfig) { config.Run = unconfigured.run })
	final = f.execute(t, TargetClaudeCLI)
	if final.State != operation.StateFailed || len(unconfigured.asked) != 2 {
		t.Fatalf("final = %+v asked %q", final, unconfigured.asked)
	}
}

func TestWithProbeModelPutsTheModelLastAmongTheOptions(t *testing.T) {
	t.Parallel()
	codex := withProbeModel(TargetCodexCLI, []string{"exec", "--profile", "zhiban-ai-managed", "-o", "/tmp/out", "PROMPT"}, "gpt-5.5")
	if want := []string{"exec", "--profile", "zhiban-ai-managed", "-o", "/tmp/out", "-c", `model="gpt-5.5"`, "PROMPT"}; strings.Join(codex, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("codex arguments = %q", codex)
	}
	claude := withProbeModel(TargetClaudeCLI, []string{"--settings", "/m.json", "--max-turns", "1", "-p", "PROMPT"}, "claude-sonnet-5")
	if want := []string{"--settings", "/m.json", "--max-turns", "1", "--model", "claude-sonnet-5", "-p", "PROMPT"}; strings.Join(claude, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("claude arguments = %q", claude)
	}
	original := []string{"exec", "PROMPT"}
	_ = withProbeModel(TargetCodexCLI, original, "gpt-5.5")
	if len(original) != 2 || original[1] != "PROMPT" {
		t.Fatalf("the caller's arguments were modified: %q", original)
	}
}

// 2026-09-21 真机:中转站按套餐分组,免费分组「知办AI-free」只有 14 个模型,写死的
// claude-sonnet-5 / claude-haiku-4-5-20251001 在那里不存在(503 无可用渠道),备用模型
// 对免费用户完全无效。备用模型要从这把 Key 自己看得到的模型里挑。
var (
	freeGroupModels = []string{"claude-haiku-4-5", "claude-opus-4-6", "claude-sonnet-4-6", "code-auto-review", "codex-auto-review",
		"gemini-3.7-flash", "gemini-3.8-flash", "gpt-5.5", "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-image-2.5", "gpt-image-2.5-flare", "gpt-image-2.5-sunburst"}
	paidGroupModels = []string{"claude-fable-5", "claude-fable-5-1", "claude-haiku-4-5-20251001", "claude-opus-4-5-20251101", "claude-opus-4-6",
		"claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-sonnet-4-6", "claude-sonnet-5", "codex-auto-review", "gpt-5.5", "gpt-5.6-luna",
		"gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra", "gpt-image-2", "gemini-3-flash", "qwen3.8-max", "text-embedding-3-large"}
)

func TestFallbackCandidatesComeFromWhatTheKeyCanSee(t *testing.T) {
	t.Parallel()
	claudePreferred := []string{"claude-sonnet-5", "claude-haiku-4-5-20251001"}
	codexPreferred := []string{"gpt-5.6-terra", "gpt-5.5"}
	tests := []struct {
		name       string
		targetID   string
		visible    []string
		preferred  []string
		configured string
		want       []string
	}{
		{name: "free group has neither preferred Claude model", targetID: TargetClaudeCLI, visible: freeGroupModels, preferred: claudePreferred,
			configured: "claude-sonnet-4-6", want: []string{"claude-haiku-4-5", "claude-opus-4-6"}},
		{name: "paid group keeps the preferred Claude models", targetID: TargetClaudeCLI, visible: paidGroupModels, preferred: claudePreferred,
			configured: "claude-sonnet-4-6", want: []string{"claude-sonnet-5", "claude-haiku-4-5-20251001"}},
		{name: "codex skips image and review models and the configured one", targetID: TargetCodexCLI, visible: freeGroupModels, preferred: codexPreferred,
			configured: "gpt-5.6-luna", want: []string{"gpt-5.6-terra", "gpt-5.5"}},
		{name: "slow models only when nothing else is left", targetID: TargetCodexCLI, visible: []string{"gpt-5.6-luna", "gpt-6-astra", "gpt-5.6-sol", "gpt-image-2"},
			preferred: codexPreferred, configured: "gpt-5.6-luna", want: []string{"gpt-5.6-sol", "gpt-6-astra"}},
		{name: "no other model of the family", targetID: TargetClaudeCLI, visible: []string{"claude-sonnet-4-6", "gpt-5.5"}, preferred: claudePreferred,
			configured: "claude-sonnet-4-6", want: nil},
		{name: "list unknown: the compiled-in preference", targetID: TargetClaudeCLI, visible: nil, preferred: claudePreferred,
			configured: "claude-sonnet-4-6", want: claudePreferred},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := fallbackCandidates(test.targetID, test.visible, test.preferred, test.configured)
			if strings.Join(got, ",") != strings.Join(test.want, ",") {
				t.Fatalf("candidates = %q, want %q", got, test.want)
			}
		})
	}
}

func TestVerifyFallsBackWithinTheKeysOwnGroup(t *testing.T) {
	t.Parallel()
	r := &relay{targetID: TargetClaudeCLI, down: map[string]bool{"": true}}
	f := newFixture(t, successScript, func(config *ManagerConfig) {
		config.Run = r.run
		config.FallbackModels = map[string][]string{TargetClaudeCLI: {"claude-sonnet-5", "claude-haiku-4-5-20251001"}}
		config.DefaultModels = map[string]string{TargetClaudeCLI: "claude-sonnet-4-6"}
		config.VisibleModels = func(context.Context, string) ([]string, error) { return freeGroupModels, nil }
	})
	final := f.execute(t, TargetClaudeCLI)
	if final.State != operation.StateSucceeded {
		t.Fatalf("final = %+v", final)
	}
	if want := []string{"", "", "claude-haiku-4-5"}; strings.Join(r.asked, ",") != strings.Join(want, ",") {
		t.Fatalf("models asked = %q, want %q", r.asked, want)
	}
	if warning := modelWarning(t, final); warning == nil || warning.WorkingModel != "claude-haiku-4-5" {
		t.Fatalf("model warning = %+v", warning)
	}
}
