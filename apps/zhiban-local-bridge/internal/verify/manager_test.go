package verify

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

type fixture struct {
	home       string
	registry   *operation.Registry
	manager    *Manager
	status     configuration.Status
	exchange   func() (string, error)
	recorded   []string
	invocation *Invocation
}

func newFixture(t *testing.T, script string, options func(*ManagerConfig)) *fixture {
	t.Helper()
	home := t.TempDir()
	cli := filepath.Join(home, "fake-cli")
	if err := os.WriteFile(cli, []byte(script), 0o700); err != nil {
		t.Fatalf("write fake cli: %v", err)
	}
	f := &fixture{
		home:     home,
		registry: operation.NewRegistry(),
		status:   configuration.Status{TargetID: TargetCodexCLI, State: configuration.StateConfigured, ProfileVersion: "2026.09.07.1", VerificationLevel: configuration.VerificationL1},
		exchange: func() (string, error) { return "lctd.test-access-token-value", nil },
	}
	config := ManagerConfig{
		HomeDir:    home,
		Operations: f.registry,
		ConfigurationStatus: func(_ context.Context, targetID string) (configuration.Status, error) {
			status := f.status
			status.TargetID = targetID
			return status, nil
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			if installationID != "install-1" {
				return Installation{}, errors.New("changed")
			}
			return Installation{TargetID: targetID, InstallationID: installationID, Executable: cli, Version: "0.153.4"}, nil
		},
		ManagedArguments: func(_ context.Context, targetID, _ string) ([]string, error) {
			if targetID == TargetCodexCLI {
				return []string{"--profile", "zhiban-ai-managed"}, nil
			}
			return []string{"--settings", filepath.Join(home, "managed.json")}, nil
		},
		ExchangeToken: func(context.Context, string) (string, error) { return f.exchange() },
		RecordVerification: func(_ context.Context, targetID, version string) (configuration.Status, error) {
			f.recorded = append(f.recorded, targetID+"@"+version)
			return configuration.Status{TargetID: targetID, State: configuration.StateConfigured, VerificationLevel: configuration.VerificationL3, LastVerifiedAt: "2026-09-08T09:00:00Z"}, nil
		},
		ProbeTimeout: 5 * time.Second,
		RetryDelay:   10 * time.Millisecond,
		TempRoot:     home,
	}
	base := config.Run
	config.Run = func(ctx context.Context, invocation Invocation) (Outcome, error) {
		copied := invocation
		f.invocation = &copied
		if base != nil {
			return base(ctx, invocation)
		}
		return runProcess(ctx, invocation)
	}
	if options != nil {
		options(&config)
	}
	manager, err := NewManager(config)
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	f.manager = manager
	return f
}

func (f *fixture) execute(t *testing.T, targetID string) operation.Envelope {
	t.Helper()
	envelope, err := f.manager.Execute(context.Background(), targetID, "install-1", "")
	if err != nil {
		t.Fatalf("Execute(%s) error = %v", targetID, err)
	}
	if envelope.State != operation.StateRunning || envelope.Kind != operation.KindVerify || envelope.Stage != StageL1 || !envelope.Cancellable {
		t.Fatalf("initial envelope = %+v", envelope)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	final, err := f.registry.Wait(ctx, envelope.OperationID)
	if err != nil {
		t.Fatalf("Wait() error = %v", err)
	}
	return final
}

const successScript = `#!/bin/sh
# Assert no credential or loader variables leak into the probe.
for name in OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN DYLD_INSERT_LIBRARIES; do
  if [ -n "$(printenv "$name")" ]; then echo "leaked $name" >&2; exit 3; fi
done
case "$1" in
  exec)
    out=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-o" ]; then out="$arg"; fi
      prev="$arg"
    done
    [ -n "$out" ] || { echo "missing -o" >&2; exit 4; }
    printf 'ZHIBAN_L3_OK\n' > "$out"
    echo "codex transcript"
    ;;
  *)
    echo '{"result":"ZHIBAN_L3_OK"}'
    ;;
esac
exit 0
`

func TestVerifyReachesLevelThreeWithSanitizedProbe(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	// t.Setenv is incompatible with t.Parallel; the probe must not inherit it.
	t.Setenv("OPENAI_API_KEY", "must-not-leak")
	f := newFixture(t, successScript, nil)

	final := f.execute(t, TargetCodexCLI)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("codex final = %+v", final)
	}
	result, ok := final.Result.(Result)
	if !ok || result.VerificationLevel != "l3" || result.VerifiedAt != "2026-09-08T09:00:00Z" {
		t.Fatalf("codex result = %#v", final.Result)
	}
	if len(f.recorded) != 1 || f.recorded[0] != "codex_cli@0.153.4" {
		t.Fatalf("recorded = %v", f.recorded)
	}
	arguments := strings.Join(f.invocation.Arguments, " ")
	for _, want := range []string{"exec --profile zhiban-ai-managed", "-c analytics.enabled=false",
		"-c model_providers.zhiban_ai_managed.request_max_retries=1", "-c model_providers.zhiban_ai_managed.stream_max_retries=1", "--skip-git-repo-check", "--ephemeral", "-s read-only", "-C ", "-o ", probePrompt} {
		if !strings.Contains(arguments, want) {
			t.Fatalf("codex arguments missing %q: %s", want, arguments)
		}
	}
	for _, item := range f.invocation.Environment {
		if strings.HasPrefix(item, "OPENAI_API_KEY=") || strings.HasPrefix(item, "ANTHROPIC_") {
			t.Fatalf("credential variable in probe environment: %s", item)
		}
	}
	if !contains(f.invocation.Environment, "HOME="+f.home) || !contains(f.invocation.Environment, "CODEX_HOME="+filepath.Join(f.home, ".codex")) {
		t.Fatalf("environment = %v", f.invocation.Environment)
	}
	if entries, _ := os.ReadDir(f.home); len(entries) != 1 {
		t.Fatalf("workspace not cleaned: %v", entries)
	}

	final = f.execute(t, TargetClaudeCLI)
	if final.State != operation.StateSucceeded {
		t.Fatalf("claude final = %+v", final)
	}
	arguments = strings.Join(f.invocation.Arguments, " ")
	for _, want := range []string{"--settings " + filepath.Join(f.home, "managed.json"), "--bare", "--no-session-persistence", "--output-format json", "--max-turns 1", "-p " + probePrompt} {
		if !strings.Contains(arguments, want) {
			t.Fatalf("claude arguments missing %q: %s", want, arguments)
		}
	}
	if !contains(f.invocation.Environment, "DISABLE_AUTOUPDATER=1") || !contains(f.invocation.Environment, "CLAUDE_CODE_MAX_RETRIES=1") {
		t.Fatalf("claude environment = %v", f.invocation.Environment)
	}
}

func TestVerifyFailsClosedOnPreconditions(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newFixture(t, successScript, nil)
	f.status.State = configuration.StateNotConfigured
	final := f.execute(t, TargetCodexCLI)
	if final.State != operation.StateFailed || *final.ErrorCode != "LCT-CODEX_CLI-VERIFY-NOT_CONFIGURED" || final.Stage != StageL1 {
		t.Fatalf("not configured final = %+v", final)
	}
	f.status.State = configuration.StateConfigured
	if _, err := f.manager.Execute(context.Background(), TargetCodexCLI, "other-install", ""); err != nil {
		t.Fatalf("Execute(changed) error = %v", err)
	}
	latest, _ := f.registry.Latest(TargetCodexCLI)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	final, _ = f.registry.Wait(ctx, latest.OperationID)
	if final.State != operation.StateFailed || *final.ErrorCode != "LCT-CODEX_CLI-VERIFY-INSTALLATION_CHANGED" {
		t.Fatalf("installation changed final = %+v", final)
	}
	if len(f.recorded) != 0 {
		t.Fatalf("recorded despite failure: %v", f.recorded)
	}
	if _, err := f.manager.Execute(context.Background(), "other", "install-1", ""); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("Execute(bad target) error = %v", err)
	}
}

func TestVerifyMapsExchangeAndProbeFailures(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	exchangeCases := []struct {
		err  error
		want string
	}{
		{err: credential.ErrExchangeRejected, want: "LCT-CODEX_CLI-AUTH-DEVICE_REVOKED"},
		{err: credential.ErrInsufficientCredit, want: "LCT-CODEX_CLI-AUTH-INSUFFICIENT_CREDIT"},
		{err: credential.ErrMemberKeyDisabled, want: "LCT-CODEX_CLI-AUTH-MEMBER_KEY_DISABLED"},
		{err: credential.ErrProfileUnsupported, want: "LCT-CODEX_CLI-AUTH-SCOPE_DENIED"},
		{err: credential.ErrExchangeUnavailable, want: "LCT-CODEX_CLI-GATEWAY-UNREACHABLE"},
		{err: credential.ErrInvalidExchangeResponse, want: "LCT-CODEX_CLI-GATEWAY-PROTOCOL_MISMATCH"},
		{err: errors.New("keychain"), want: "LCT-CODEX_CLI-AUTH-DEVICE_MISSING"},
	}
	for _, test := range exchangeCases {
		f := newFixture(t, successScript, nil)
		exchangeErr := test.err
		f.exchange = func() (string, error) { return "", exchangeErr }
		final := f.execute(t, TargetCodexCLI)
		if final.State != operation.StateFailed || *final.ErrorCode != test.want || final.Stage != StageL2 {
			t.Fatalf("exchange %v final = %+v", test.err, final)
		}
	}

	probeCases := []struct {
		name   string
		script string
		want   string
		detail string
	}{
		{
			name:   "relay overloaded",
			script: "#!/bin/sh\necho 'ERROR: unexpected status 503 Service Unavailable: auth_unavailable: no auth available (model=gpt-5.6-luna), url: https://api.airick.cn/v1/responses' >&2\nexit 1\n",
			want:   "LCT-CODEX_CLI-GATEWAY-UPSTREAM_UNAVAILABLE",
			detail: "HTTP 503 · auth_unavailable: no auth available (model=gpt-5.6-luna)",
		},
		{name: "unauthorized", script: "#!/bin/sh\necho 'HTTP 401 Unauthorized' >&2\nexit 1\n", want: "LCT-CODEX_CLI-AUTH-TOKEN_EXPIRED"},
		{name: "model denied", script: "#!/bin/sh\necho 'model gpt-x does not exist' >&2\nexit 1\n", want: "LCT-CODEX_CLI-GATEWAY-MODEL_DENIED"},
		{name: "quota", script: "#!/bin/sh\necho 'rate limit exceeded' >&2\nexit 1\n", want: "LCT-CODEX_CLI-GATEWAY-QUOTA_EXHAUSTED"},
		{name: "network", script: "#!/bin/sh\necho 'connection refused' >&2\nexit 1\n", want: "LCT-CODEX_CLI-GATEWAY-UNREACHABLE",
			// 没有中转站回答可引用,就带上命令行原话:只有一个"无法连接"时
			// 支持侧分不清是证书、代理、DNS 还是超时(2026-09-17 两位用户)。
			detail: "connection refused"},
		{name: "helper code", script: "#!/bin/sh\necho 'LCT-CODEX_CLI-AUTH-DEVICE_REVOKED' >&2\nexit 1\n", want: "LCT-CODEX_CLI-AUTH-DEVICE_REVOKED"},
		{name: "unknown", script: "#!/bin/sh\necho 'boom' >&2\nexit 2\n", want: "LCT-CODEX_CLI-GATEWAY-PROTOCOL_MISMATCH",
			// 归不了类时把命令行自己的话带出来,否则诊断里只有一个码。
			detail: "boom"},
		{name: "empty output", script: "#!/bin/sh\nexit 0\n", want: "LCT-CODEX_CLI-GATEWAY-PROTOCOL_MISMATCH"},
		{name: "timeout", script: "#!/bin/sh\nsleep 30\n", want: "LCT-CODEX_CLI-GATEWAY-UNREACHABLE",
			detail: "探测超时（2 秒内没有任何回答）"},
	}
	for _, test := range probeCases {
		timeout := 10 * time.Second
		if test.name == "timeout" {
			timeout = 2 * time.Second
		}
		f := newFixture(t, test.script, func(config *ManagerConfig) { config.ProbeTimeout = timeout })
		final := f.execute(t, TargetCodexCLI)
		if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != test.want || final.Stage != StageL3 {
			got := "<nil>"
			if final.ErrorCode != nil {
				got = *final.ErrorCode
			}
			t.Fatalf("%s final = %+v code=%s", test.name, final, got)
		}
		gotDetail := ""
		if final.ErrorDetail != nil {
			gotDetail = *final.ErrorDetail
		}
		if gotDetail != test.detail {
			t.Fatalf("%s error_detail = %q, want %q", test.name, gotDetail, test.detail)
		}
		if len(f.recorded) != 0 {
			t.Fatalf("%s recorded despite failure", test.name)
		}
	}
}

func TestVerifyCancelDuringProbe(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newFixture(t, "#!/bin/sh\nsleep 30\n", func(config *ManagerConfig) { config.ProbeTimeout = 20 * time.Second })
	envelope, err := f.manager.Execute(context.Background(), TargetCodexCLI, "install-1", "")
	if err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		current, _ := f.registry.Get(envelope.OperationID)
		if current.Stage == StageL3 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("never reached l3: %+v", current)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := f.manager.Execute(context.Background(), TargetCodexCLI, "install-1", ""); !isCode(err, "LCT-CODEX_CLI-OPERATION-BUSY") {
		t.Fatalf("Execute() while running error = %v", err)
	}
	if _, err := f.registry.Cancel(envelope.OperationID); err != nil {
		t.Fatalf("Cancel() error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	final, err := f.registry.Wait(ctx, envelope.OperationID)
	if err != nil || final.State != operation.StateCancelled || *final.ErrorCode != "LCT-CODEX_CLI-LAUNCH-SYSTEM_CANCELLED" {
		t.Fatalf("cancelled final = %+v, %v", final, err)
	}
	if entries, _ := os.ReadDir(f.home); len(entries) != 1 {
		t.Fatalf("workspace not cleaned after cancel: %v", entries)
	}
}

func isCode(err error, code string) bool {
	var failure *operation.Failure
	return errors.As(err, &failure) && failure.Code == code
}

func contains(values []string, value string) bool {
	for _, item := range values {
		if item == value {
			return true
		}
	}
	return false
}

func TestVerifyGlobalScopeUsesUserConfigurationAndRecordsGlobal(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	var globalRecorded, refreshed []string
	options := func(config *ManagerConfig) {
		config.RefreshGlobal = func(_ context.Context, targetID string) error {
			refreshed = append(refreshed, targetID)
			return errors.New("refresh failures never fail verification")
		}
		config.RecordGlobal = func(_ context.Context, targetID, version string) (configuration.GlobalStatus, error) {
			globalRecorded = append(globalRecorded, targetID+"@"+version)
			return configuration.GlobalStatus{TargetID: targetID, CurrentService: configuration.ServiceZhiban, VerificationLevel: configuration.VerificationL3, LastVerifiedAt: "2026-09-08T10:00:00Z"}, nil
		}
	}
	for _, targetID := range []string{TargetCodexCLI, TargetClaudeCLI} {
		f := newFixture(t, successScript, options)
		f.status = configuration.Status{TargetID: targetID, State: configuration.StateNotConfigured, CurrentService: configuration.ServiceZhiban, GlobalSwitched: true}
		envelope, err := f.manager.Execute(context.Background(), targetID, "install-1", ScopeGlobal)
		if err != nil {
			t.Fatalf("Execute(%s) error = %v", targetID, err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		final, err := f.registry.Wait(ctx, envelope.OperationID)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if final.State != operation.StateSucceeded {
			t.Fatalf("%s final = %+v", targetID, final)
		}
		joined := strings.Join(f.invocation.Arguments, " ")
		if strings.Contains(joined, "--profile") || strings.Contains(joined, "--settings") ||
			strings.Contains(joined, "--bare") || strings.Contains(joined, "--setting-sources") {
			t.Fatalf("%s global probe carried overlay arguments: %s", targetID, joined)
		}
		if len(f.recorded) != 0 {
			t.Fatalf("%s overlay verification recorded for a global probe: %v", targetID, f.recorded)
		}
	}
	if strings.Join(globalRecorded, ",") != "codex_cli@0.153.4,claude_cli@0.153.4" {
		t.Fatalf("global recorded = %v", globalRecorded)
	}
	// Only Codex derives a model catalog from the gateway (contract §2.7.2).
	if strings.Join(refreshed, ",") != "codex_cli" {
		t.Fatalf("refreshed = %v", refreshed)
	}

	// Not switched → NOT_CONFIGURED; no recorder → invalid input.
	f := newFixture(t, successScript, options)
	f.status = configuration.Status{TargetID: TargetCodexCLI, State: configuration.StateConfigured, ProfileVersion: "v", CurrentService: configuration.ServiceOfficial}
	envelope, err := f.manager.Execute(context.Background(), TargetCodexCLI, "install-1", ScopeGlobal)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	final, err := f.registry.Wait(ctx, envelope.OperationID)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-VERIFY-NOT_CONFIGURED" {
		t.Fatalf("not switched final = %+v", final)
	}
	plain := newFixture(t, successScript, nil)
	if _, err := plain.manager.Execute(context.Background(), TargetCodexCLI, "install-1", ScopeGlobal); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("global scope without recorder error = %v, want ErrInvalidInput", err)
	}
}

// TestL3RetriesOnceOnTransientGatewayFailure: the relay's first answer is a
// hiccup ("no channel for model"), the second is fine → the switch verifies.
// Deterministic failures (auth) are not retried.
func TestL3RetriesOnceOnTransientGatewayFailure(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	// The fake CLI fails the first time it is run and succeeds afterwards; the
	// marker lives in HOME, outside the per-run probe workspace.
	flaky := "#!/bin/sh\nmarker=\"$HOME/.probe-ran\"\nif [ -f \"$marker\" ]; then\n  out=\"\"\n  while [ $# -gt 0 ]; do if [ \"$1\" = -o ]; then out=\"$2\"; fi; shift; done\n  [ -n \"$out\" ] && printf ZHIBAN_L3_OK > \"$out\"\n  echo ZHIBAN_L3_OK\n  exit 0\nfi\ntouch \"$marker\"\necho '分组 X 下模型 gpt-5.6-luna 无可用渠道' >&2\nexit 1\n"
	f := newFixture(t, flaky, nil)
	final := f.execute(t, TargetCodexCLI)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		got := "<nil>"
		if final.ErrorCode != nil {
			got = *final.ErrorCode
		}
		t.Fatalf("flaky probe final = %+v code=%s", final, got)
	}
	if len(f.recorded) != 1 {
		t.Fatalf("recorded = %v, want one L3 record after the retry", f.recorded)
	}

	// Two hiccups in a row: still a failure, classified from the last run.
	always := "#!/bin/sh\necho 'model gpt-x does not exist' >&2\nexit 1\n"
	g := newFixture(t, always, nil)
	if final := g.execute(t, TargetCodexCLI); final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-GATEWAY-MODEL_DENIED" {
		t.Fatalf("persistent failure final = %+v", final)
	}

	// Auth failures are deterministic: exactly one run, no retry.
	counted := "#!/bin/sh\necho run >> \"$HOME/.probe-count\"\necho 'HTTP 401 Unauthorized' >&2\nexit 1\n"
	h := newFixture(t, counted, nil)
	if final := h.execute(t, TargetCodexCLI); final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-AUTH-TOKEN_EXPIRED" {
		t.Fatalf("auth failure final = %+v", final)
	}
	if runs, err := os.ReadFile(filepath.Join(h.home, ".probe-count")); err != nil || strings.Count(string(runs), "run") != 1 {
		t.Fatalf("auth failure runs = %q, %v (want exactly one)", runs, err)
	}
}

// 契约 §2.7「直连预检与快速失败」(2026-09-18,Windows 测试机 Clash TUN):直连不通时
// 探针只跑一次、不再按"超时可重试"再等一轮,说明里写清是本机直连失败。
func TestVerifyBoundsTheProbeWhenTheDirectPathIsDead(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	hanging := "#!/bin/sh\necho run >> \"$HOME/.probe-count\"\nsleep 30\n"
	runs := func(home string) int {
		data, _ := os.ReadFile(filepath.Join(home, ".probe-count"))
		return strings.Count(string(data), "run")
	}

	dead := newFixture(t, hanging, func(config *ManagerConfig) {
		config.ProbeTimeout = 2 * time.Second
		config.GatewayUnreachable = func(context.Context) bool { return true }
	})
	final := dead.execute(t, TargetCodexCLI)
	if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-GATEWAY-UNREACHABLE" {
		t.Fatalf("dead direct path final = %+v", final)
	}
	if final.ErrorDetail == nil || *final.ErrorDetail != directUnreachableDetail+" · 探测超时（2 秒内没有任何回答）" {
		t.Fatalf("dead direct path detail = %v", final.ErrorDetail)
	}
	if got := runs(dead.home); got != 1 {
		t.Fatalf("dead direct path probe runs = %d, want exactly one", got)
	}

	// 预检说通:行为不变,超时仍按 11917 的规则重试一次,说明里不带直连那句。
	alive := newFixture(t, hanging, func(config *ManagerConfig) {
		config.ProbeTimeout = 2 * time.Second
		config.GatewayUnreachable = func(context.Context) bool { return false }
	})
	final = alive.execute(t, TargetCodexCLI)
	if final.ErrorDetail == nil || *final.ErrorDetail != "探测超时（2 秒内没有任何回答）" {
		t.Fatalf("reachable detail = %v", final.ErrorDetail)
	}
	if got := runs(alive.home); got != 2 {
		t.Fatalf("reachable probe runs = %d, want the usual two", got)
	}

	// 预检误判(说不通,但命令行其实连得上):照常通过,不会被判死。
	wrong := newFixture(t, successScript, func(config *ManagerConfig) {
		config.GatewayUnreachable = func(context.Context) bool { return true }
	})
	if final := wrong.execute(t, TargetCodexCLI); final.State != operation.StateSucceeded {
		t.Fatalf("a wrong preflight must not fail a working line: %+v", final)
	}
}

// 契约 §2.7「被代理软件转走」(2026-09-18):探针没连上、而 Bridge 直连可达且本机有代理
// 软件在起作用时,报 PROXY_DIVERTED 且不再重试第二轮;证书类失败不归到这里。
func TestVerifyReportsDivertedTrafficWithoutASecondProbe(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	runs := func(home string) int {
		data, _ := os.ReadFile(filepath.Join(home, ".probe-count"))
		return strings.Count(string(data), "run")
	}
	hanging := "#!/bin/sh\necho run >> \"$HOME/.probe-count\"\nsleep 30\n"
	diverted := newFixture(t, hanging, func(config *ManagerConfig) {
		config.ProbeTimeout = 2 * time.Second
		config.TrafficDiverted = func(context.Context) bool { return true }
	})
	final := diverted.execute(t, TargetCodexCLI)
	if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-GATEWAY-PROXY_DIVERTED" {
		t.Fatalf("diverted final = %+v", final)
	}
	if final.ErrorDetail == nil || *final.ErrorDetail != "探测超时（2 秒内没有任何回答）" {
		t.Fatalf("diverted detail = %v", final.ErrorDetail)
	}
	if got := runs(diverted.home); got != 1 {
		t.Fatalf("diverted probe runs = %d, want exactly one", got)
	}

	// 命令行自己的证书库问题(契约「根证书补充」)不是路由问题:仍是 UNREACHABLE,照常重试。
	certificate := "#!/bin/sh\necho run >> \"$HOME/.probe-count\"\necho 'API Error: Unable to connect to API: SSL certificate verification failed' >&2\nexit 1\n"
	trust := newFixture(t, certificate, func(config *ManagerConfig) {
		config.TrafficDiverted = func(context.Context) bool { return true }
	})
	final = trust.execute(t, TargetCodexCLI)
	if final.ErrorCode == nil || !strings.HasSuffix(*final.ErrorCode, "-GATEWAY-UNREACHABLE") {
		t.Fatalf("certificate failure final = %+v", final)
	}

	// 中转站自己回了话(503 / 模型不存在)与路由无关:不问、不改码。
	asked := false
	relay := newFixture(t, "#!/bin/sh\necho 'model gpt-x does not exist' >&2\nexit 1\n", func(config *ManagerConfig) {
		config.TrafficDiverted = func(context.Context) bool { asked = true; return true }
	})
	if final := relay.execute(t, TargetCodexCLI); final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-GATEWAY-MODEL_DENIED" || asked {
		t.Fatalf("relay answer final = %+v asked=%v", final, asked)
	}
}
