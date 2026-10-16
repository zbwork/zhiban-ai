// Package verify implements verify.execute: the L1 → L2 → L3 ladder that ends
// with the target CLI itself completing one fixed, content-free request
// through the Zhiban gateway using the managed configuration.
package verify

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/configuration"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/credential"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

const (
	TargetCodexCLI      = "codex_cli"
	TargetClaudeCLI     = "claude_cli"
	TargetCodexDesktop  = "codex_desktop"
	TargetClaudeDesktop = "claude_desktop"

	StageL1 = "l1"
	StageL2 = "l2"
	StageL3 = "l3"

	// ScopeOverlay verifies the Zhiban-managed overlay (launched with
	// --profile / --settings); ScopeGlobal verifies the user's own global
	// configuration after 切换为知办模型 API (no extra arguments).
	ScopeOverlay = "overlay"
	ScopeGlobal  = "global"

	defaultProbeTimeout = 90 * time.Second
	defaultRetryDelay   = 3 * time.Second
	maxOutputBytes      = 64 << 10
	probePrompt         = "Reply with exactly ZHIBAN_L3_OK and nothing else."
)

var (
	ErrInvalidInput = errors.New("verify: invalid input")

	helperCodePattern = regexp.MustCompile(`LCT-(CODEX_CLI|CLAUDE_CLI)-(AUTH|GATEWAY)-[A-Z_]+`)
)

// Installation is the freshly resolved trusted installation.
type Installation struct {
	TargetID       string
	InstallationID string
	Executable     string
	Version        string
}

// Invocation is the CLI probe to run. It never contains a credential.
type Invocation struct {
	Executable  string
	Arguments   []string
	Dir         string
	Environment []string
}

// Outcome is the probe result.
type Outcome struct {
	ExitCode    int
	Output      []byte
	TimedOut    bool
	StartFailed bool
}

// Result is the succeeded envelope payload.
type Result struct {
	VerificationLevel string `json:"verification_level"`
	VerifiedAt        string `json:"verified_at"`
	// ModelWarning is set when the configured model failed on the relay's
	// side and a fallback model answered (contract §2.7 L3 备用模型).
	ModelWarning *ModelWarning `json:"model_warning,omitempty"`
}

// ModelWarning says why the configured model did not answer and which model
// did: the service works, the user may want to pick another model.
type ModelWarning struct {
	ErrorCode    string `json:"error_code"`
	ErrorDetail  string `json:"error_detail,omitempty"`
	WorkingModel string `json:"working_model"`
}

type (
	ConfigurationStatusFunc func(context.Context, string) (configuration.Status, error)
	ResolveInstallationFunc func(context.Context, string, string) (Installation, error)
	ManagedArgumentsFunc    func(context.Context, string, string) ([]string, error)
	ExchangeTokenFunc       func(context.Context, string) (string, error)
	RecordVerificationFunc  func(context.Context, string, string) (configuration.Status, error)
	RecordGlobalFunc        func(context.Context, string, string) (configuration.GlobalStatus, error)
	RefreshGlobalFunc       func(context.Context, string) error
	RunFunc                 func(context.Context, Invocation) (Outcome, error)
)

// ManagerConfig wires verify into the Bridge process.
type ManagerConfig struct {
	HomeDir             string
	Operations          *operation.Registry
	ConfigurationStatus ConfigurationStatusFunc
	ResolveInstallation ResolveInstallationFunc
	ManagedArguments    ManagedArgumentsFunc
	ExchangeToken       ExchangeTokenFunc
	RecordVerification  RecordVerificationFunc
	// RefreshGlobal re-decides what a switched global configuration derives
	// from the gateway (the Codex model catalog) once the exchange succeeded.
	// Optional; failures never fail the verification.
	RefreshGlobal RefreshGlobalFunc
	RecordGlobal  RecordGlobalFunc
	// ComponentsReady reports whether every runtime component the target's
	// installation needs is present (M3 Task 8); desktop L1 fails with
	// VERIFY-COMPONENT_MISSING otherwise. Optional.
	ComponentsReady ComponentsReadyFunc
	Run             RunFunc
	ProbeTimeout    time.Duration
	// RetryDelay is the pause before the single retry of an L3 probe that
	// failed with a transient gateway classification (default 3 s).
	RetryDelay time.Duration
	TempRoot   string
	// FallbackModels lists, per CLI target, the models preferred as fallbacks
	// when the configured model fails on the relay's side (contract §2.7 L3
	// 备用模型). Empty and no VisibleModels = no fallback.
	FallbackModels map[string][]string
	// VisibleModels returns the model ids the member's key may use. The relay
	// groups keys by plan and every group serves different models (2026-09-21:
	// the free group has neither compiled-in Claude fallback), so fallbacks
	// are picked from this list; without it FallbackModels is used as is.
	VisibleModels func(ctx context.Context, targetID string) ([]string, error)
	// DefaultModels is the model the switch writes per CLI target: probing it
	// again as a "fallback" would only repeat the failure.
	DefaultModels map[string]string
	// NodeLookup finds the Node runtime an npm-installed CLI needs when node
	// is not beside the package (custom npm prefix, bun, volta). Optional:
	// the Node prefix the package lives under is always tried first.
	NodeLookup *shellenv.LoginShellLookup
	// ProxyEnvironment returns the proxy variables a CLI the user starts would
	// see (NO_PROXY as new processes get it now); contract §2.7 network.*.
	ProxyEnvironment func(context.Context) []string
	// ProxyRisk reports missing proxy bypass configuration, not a failure.
	// Only a failed network request uses it as a possible-cause hint; it never
	// shortens timeouts, disables retries, or suppresses model fallbacks.
	ProxyRisk func(context.Context) bool
	// GatewayUnreachable reports that the CLI would connect to the gateway
	// directly and that direct path does not answer (TUN-mode proxy tool,
	// firewall, offline): the L3 probe is bounded instead of
	// waiting out the full timeout twice. It only shortens the wait, the CLI
	// still gets its own attempt (contract §2.7, 2026-09-18). Optional.
	GatewayUnreachable func(context.Context) bool
	// TrafficDiverted is asked only after a probe could not reach the gateway:
	// proxy software is active and the Bridge itself connects directly, so the
	// tool's traffic may be sent to a proxy node (PROCESS-NAME rules, global
	// mode, TUN). Reported as GATEWAY-PROXY_DIVERTED and not retried. Optional.
	TrafficDiverted func(context.Context) bool
}

// proxyRiskTimeout bounds an L3 probe only when its actual direct route
// failed preflight; configured proxies keep the normal timeout.
const proxyRiskTimeout = 25 * time.Second

// divertedCandidate limits GATEWAY-PROXY_DIVERTED to failures proxy software
// explains: no answer at all or a connection-level error. A certificate
// failure is the CLI's own trust store (contract §2.7 "根证书补充"), not routing.
func divertedCandidate(probeCode, detail string) bool {
	if !strings.HasSuffix(probeCode, "-GATEWAY-UNREACHABLE") {
		return false
	}
	lowered := strings.ToLower(detail)
	return !strings.Contains(lowered, "certificate") && !strings.Contains(lowered, "ssl")
}

const directUnreachableDetail = "本机直连知办中转站失败（TLS 握手未完成，常见于代理软件的 TUN / 增强模式或防火墙拦截）"

// Manager implements verify.execute.
type Manager struct {
	homeDir             string
	operations          *operation.Registry
	configurationStatus ConfigurationStatusFunc
	resolveInstallation ResolveInstallationFunc
	managedArguments    ManagedArgumentsFunc
	exchangeToken       ExchangeTokenFunc
	recordVerification  RecordVerificationFunc
	recordGlobal        RecordGlobalFunc
	refreshGlobal       RefreshGlobalFunc
	componentsReady     ComponentsReadyFunc
	run                 RunFunc
	probeTimeout        time.Duration
	retryDelay          time.Duration
	fallbackModels      map[string][]string
	visibleModels       func(ctx context.Context, targetID string) ([]string, error)
	defaultModels       map[string]string
	tempRoot            string
	nodeLookup          *shellenv.LoginShellLookup
	proxyEnvironment    func(context.Context) []string
	proxyRisk           func(context.Context) bool
	gatewayUnreachable  func(context.Context) bool
	trafficDiverted     func(context.Context) bool
}

// NewManager validates config.
func NewManager(config ManagerConfig) (*Manager, error) {
	homeDir := filepath.Clean(strings.TrimSpace(config.HomeDir))
	if homeDir == "." || !filepath.IsAbs(homeDir) || config.Operations == nil || config.ConfigurationStatus == nil ||
		config.ResolveInstallation == nil || config.ManagedArguments == nil || config.ExchangeToken == nil ||
		config.RecordVerification == nil {
		return nil, ErrInvalidInput
	}
	manager := &Manager{
		homeDir: homeDir, operations: config.Operations, configurationStatus: config.ConfigurationStatus,
		resolveInstallation: config.ResolveInstallation, managedArguments: config.ManagedArguments,
		exchangeToken: config.ExchangeToken, recordVerification: config.RecordVerification, recordGlobal: config.RecordGlobal,
		componentsReady: config.ComponentsReady, refreshGlobal: config.RefreshGlobal,
		run: config.Run, probeTimeout: config.ProbeTimeout, retryDelay: config.RetryDelay, tempRoot: config.TempRoot,
		nodeLookup: config.NodeLookup, proxyEnvironment: config.ProxyEnvironment, proxyRisk: config.ProxyRisk,
		gatewayUnreachable: config.GatewayUnreachable, trafficDiverted: config.TrafficDiverted,
		fallbackModels: config.FallbackModels, visibleModels: config.VisibleModels, defaultModels: config.DefaultModels,
	}
	if manager.run == nil {
		manager.run = runProcess
	}
	if manager.probeTimeout <= 0 {
		manager.probeTimeout = defaultProbeTimeout
	}
	if manager.retryDelay <= 0 {
		manager.retryDelay = defaultRetryDelay
	}
	return manager, nil
}

// Execute starts the verification operation. scope is ScopeOverlay (default)
// or ScopeGlobal.
func (m *Manager) Execute(_ context.Context, targetID, installationID, scope string) (operation.Envelope, error) {
	if scope == "" {
		scope = ScopeOverlay
	}
	if !validTarget(targetID) || strings.TrimSpace(installationID) == "" || len(installationID) > 128 ||
		(scope != ScopeOverlay && scope != ScopeGlobal) || (scope == ScopeGlobal && m.recordGlobal == nil) {
		return operation.Envelope{}, ErrInvalidInput
	}
	envelope, err := m.operations.Start(operation.Spec{
		TargetID: targetID, Kind: operation.KindVerify, InitialStage: StageL1, Cancellable: true,
		CancelCode: code(targetID, "LAUNCH", "SYSTEM_CANCELLED"), FailureCode: code(targetID, "GATEWAY", "PROTOCOL_MISMATCH"),
		Run: func(ctx context.Context, report *operation.Reporter) (any, error) {
			return m.verify(ctx, report, targetID, installationID, scope)
		},
	})
	if err != nil {
		if errors.Is(err, operation.ErrBusy) {
			return operation.Envelope{}, operation.Fail(code(targetID, "OPERATION", "BUSY"), nil)
		}
		return operation.Envelope{}, err
	}
	return envelope, nil
}

func (m *Manager) verify(ctx context.Context, report *operation.Reporter, targetID, installationID, scope string) (any, error) {
	report.Stage(StageL1, true)
	status, err := m.configurationStatus(ctx, targetID)
	if err != nil {
		return nil, operation.Fail(code(targetID, "VERIFY", "NOT_CONFIGURED"), err)
	}
	if scope == ScopeGlobal {
		if status.CurrentService != configuration.ServiceZhiban {
			return nil, operation.Fail(code(targetID, "VERIFY", "NOT_CONFIGURED"), nil)
		}
	} else if status.State != configuration.StateConfigured || status.ProfileVersion == "" {
		return nil, operation.Fail(code(targetID, "VERIFY", "NOT_CONFIGURED"), err)
	}
	installation, err := m.resolveInstallation(ctx, targetID, installationID)
	if err != nil || installation.TargetID != targetID || installation.InstallationID != installationID ||
		!filepath.IsAbs(installation.Executable) || installation.Version == "" {
		return nil, operation.Fail(code(targetID, "VERIFY", "INSTALLATION_CHANGED"), err)
	}
	if IsDesktopTarget(targetID) {
		if scope != ScopeGlobal || status.GlobalDrifted {
			return nil, operation.Fail(code(targetID, "VERIFY", "NOT_CONFIGURED"), nil)
		}
		return m.verifyDesktop(ctx, report, targetID, installation)
	}
	var managedArguments []string
	if scope == ScopeOverlay {
		managedArguments, err = m.managedArguments(ctx, targetID, status.ProfileVersion)
		if err != nil || len(managedArguments) == 0 {
			return nil, operation.Fail(code(targetID, "VERIFY", "NOT_CONFIGURED"), err)
		}
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	report.Stage(StageL2, true)
	token, err := m.exchangeToken(ctx, targetID)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, operation.Fail(exchangeCode(targetID, err), err)
	}
	if !credential.ValidAccessToken(token) {
		return nil, operation.Fail(code(targetID, "GATEWAY", "PROTOCOL_MISMATCH"), nil)
	}
	token = ""
	_ = token
	m.refreshGlobalAfterExchange(ctx, targetID, scope)

	report.Stage(StageL3, true)
	workspace, cleanup, err := m.workspace(targetID)
	if err != nil {
		return nil, operation.Fail(code(targetID, "LAUNCH", "PROCESS_FAILED"), err)
	}
	defer cleanup()
	invocation, outputPath := m.invocation(targetID, installation, managedArguments, workspace, scope)
	// The relay occasionally answers one request with "no channel for model"
	// (classified MODEL_DENIED) or an unparseable body (PROTOCOL_MISMATCH) and
	// the very next one normally (2026-09-09 test Mac: two such hiccups, each
	// gone on retry). One retry after a short pause keeps a single hiccup from
	// flagging a freshly written switch as broken; auth and quota failures are
	// deterministic and are not retried.
	probeCode, probeDetail := "", ""
	probeTimeout, attempts := m.probeTimeout, 2
	proxyRisk := m.proxyRisk != nil && m.proxyRisk(ctx)

	// The direct path is dead (TUN-mode proxy tool, firewall, offline): Codex
	// would reconnect silently for the full timeout, twice. This preflight
	// only bounds a direct route; missing proxy bypass rules do not shorten it.
	directUnreachable := !proxyRisk && m.gatewayUnreachable != nil && m.gatewayUnreachable(ctx)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if directUnreachable {
		if probeTimeout > proxyRiskTimeout {
			probeTimeout = proxyRiskTimeout
		}
		attempts = 1
	}
	attempt, degradations := 0, 0
	for {
		probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
		outcome, runErr := m.run(probeCtx, invocation)
		cancel()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if runErr != nil || outcome.StartFailed {
			return nil, operation.Fail(code(targetID, "LAUNCH", "PROCESS_FAILED"), runErr)
		}
		switch {
		case outcome.TimedOut:
			// Say it was the clock: "无法连接" with nothing else could not be
			// told from a CLI-reported network error (2026-09-17 feedback).
			probeCode, probeDetail = code(targetID, "GATEWAY", "UNREACHABLE"), timeoutDetail(probeTimeout)
		case outcome.ExitCode != 0 || !probeSucceeded(targetID, outcome.Output, outputPath):
			probeCode, probeDetail = classifyProbe(targetID, outcome.Output)
			if probeDetail == "" && (strings.HasSuffix(probeCode, "-GATEWAY-PROTOCOL_MISMATCH") || strings.HasSuffix(probeCode, "-GATEWAY-UNREACHABLE")) {
				// No HTTP answer to quote: without the CLI's own words this is
				// an opaque code (2026-09-16 testers; 2026-09-17 Claude Code's
				// "SSL certificate verification failed" reached support as a
				// bare UNREACHABLE and was taken for a proxy problem).
				probeDetail = probeOutputDetail(targetID, outcome.Output)
			}
		default:
			probeCode, probeDetail = "", ""
		}
		if probeCode == "" {
			break
		}
		// An older CLI rejects a hardening option the probe passes and exits
		// before it ever reaches the relay. Drop exactly the option it named
		// and run again: this costs no gateway attempt, and the switch stays
		// usable on that version (contract §2.7.1).
		if option, ok := unknownProbeOption(outcome.Output); ok && degradations < maxProbeDegradations {
			if reduced, dropped := dropProbeArgument(invocation.Arguments, option); dropped {
				invocation.Arguments = reduced
				degradations++
				if outputPath != "" {
					_ = os.Remove(outputPath)
				}
				continue
			}
		}
		attempt++
		// The tool could not reach the gateway although the Bridge can and
		// proxy software is active: diversion is a possible cause. Waiting out
		// a second timeout changes nothing, say so now.
		if !proxyRisk && !directUnreachable && divertedCandidate(probeCode, probeDetail) &&
			m.trafficDiverted != nil && m.trafficDiverted(ctx) {
			probeCode = code(targetID, "GATEWAY", "PROXY_DIVERTED")
			break
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if attempt >= attempts || !transientGatewayCode(probeCode) {
			break
		}
		if outputPath != "" {
			_ = os.Remove(outputPath)
		}
		if !sleepContext(ctx, m.retryDelay) {
			return nil, ctx.Err()
		}
	}
	if proxyRisk && divertedCandidate(probeCode, probeDetail) {
		probeCode = code(targetID, "GATEWAY", "PROXY_INTERFERENCE")
	}
	if directUnreachable && strings.HasSuffix(probeCode, "-GATEWAY-UNREACHABLE") {
		probeDetail = strings.TrimSuffix(directUnreachableDetail+" · "+probeDetail, " · ")
	}
	// One model's route being down on the relay is not the service being
	// down (2026-09-20: claude-sonnet-4-6 answered 502 twice while every other
	// Claude model worked). An HTTP answer is evidence the route worked; proxy
	// configuration must not suppress fallback model verification.
	var warning *ModelWarning
	if modelSideFailure(probeCode) {
		working, err := m.probeFallbackModels(ctx, targetID, invocation, outputPath)
		if err != nil {
			return nil, err
		}
		if working != "" {
			warning = &ModelWarning{ErrorCode: probeCode, ErrorDetail: probeDetail, WorkingModel: working}
			probeCode = ""
		}
	}
	if probeCode != "" {
		return nil, operation.FailDetail(probeCode, probeDetail, nil)
	}

	if scope == ScopeGlobal {
		recorded, err := m.recordGlobal(ctx, targetID, installation.Version)
		if err != nil || recorded.VerificationLevel != configuration.VerificationL3 {
			return nil, operation.Fail(code(targetID, "VERIFY", "NOT_CONFIGURED"), err)
		}
		return Result{VerificationLevel: recorded.VerificationLevel, VerifiedAt: recorded.LastVerifiedAt, ModelWarning: warning}, nil
	}
	recorded, err := m.recordVerification(ctx, targetID, installation.Version)
	if err != nil || recorded.VerificationLevel != configuration.VerificationL3 {
		return nil, operation.Fail(code(targetID, "VERIFY", "NOT_CONFIGURED"), err)
	}
	return Result{VerificationLevel: recorded.VerificationLevel, VerifiedAt: recorded.LastVerifiedAt, ModelWarning: warning}, nil
}

// fallbackProbeTimeout bounds one fallback probe: the relay has just answered
// the configured model within seconds, so a fallback that takes longer is no
// better news.
const fallbackProbeTimeout = 45 * time.Second

// modelSideFailure reports the failures another model can get around: the
// relay answered 5xx for this model, or has no route for it.
func modelSideFailure(probeCode string) bool {
	return strings.HasSuffix(probeCode, "-GATEWAY-UPSTREAM_UNAVAILABLE") || strings.HasSuffix(probeCode, "-GATEWAY-MODEL_DENIED")
}

// probeFallbackModels runs the probe once per fallback model and returns the
// first that answers ("" when none does). The model is named only in this
// invocation's arguments; the user's configuration is never touched.
func (m *Manager) probeFallbackModels(ctx context.Context, targetID string, invocation Invocation, outputPath string) (string, error) {
	timeout := m.probeTimeout
	if timeout > fallbackProbeTimeout {
		timeout = fallbackProbeTimeout
	}
	var visible []string
	if m.visibleModels != nil {
		// A list that cannot be read costs the fallback nothing: the
		// compiled-in preference is tried instead.
		visible, _ = m.visibleModels(ctx, targetID)
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
	}
	for _, model := range fallbackCandidates(targetID, visible, m.fallbackModels[targetID], m.defaultModels[targetID]) {
		if outputPath != "" {
			_ = os.Remove(outputPath)
		}
		attempt := invocation
		attempt.Arguments = withProbeModel(targetID, invocation.Arguments, model)
		probeCtx, cancel := context.WithTimeout(ctx, timeout)
		outcome, runErr := m.run(probeCtx, attempt)
		cancel()
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		if runErr == nil && !outcome.StartFailed && !outcome.TimedOut && outcome.ExitCode == 0 && probeSucceeded(targetID, outcome.Output, outputPath) {
			return model, nil
		}
	}
	return "", nil
}

// maxFallbackModels bounds the extra probes of one verification.
const maxFallbackModels = 2

// slowFallbackModels answered in about 5 s and 10 s when the fallbacks were
// picked (2026-09-20), others in 2–4 s; they are used only when nothing faster
// is left, the less slow one first.
var slowFallbackModels = map[string]int{"gpt-5.6-sol": 8, "gpt-6-astra": 9}

// fallbackCandidates picks up to maxFallbackModels models to probe instead of
// the configured one. With the key's visible models known, only models of the
// target's family that the key can really use are picked — the preferred ones
// first, then the rest (Claude: sonnet, haiku, opus; newer names first; slow
// models last). With the list unknown the preferred models are tried as is.
func fallbackCandidates(targetID string, visible, preferred []string, configured string) []string {
	if len(visible) == 0 {
		return capModels(preferred)
	}
	usable := map[string]bool{}
	for _, id := range visible {
		if id != configured && sameFamily(targetID, id) {
			usable[id] = true
		}
	}
	var picked []string
	for _, id := range preferred {
		if usable[id] {
			picked = append(picked, id)
			delete(usable, id)
		}
	}
	rest := make([]string, 0, len(usable))
	for id := range usable {
		rest = append(rest, id)
	}
	sort.Slice(rest, func(i, j int) bool {
		if left, right := familyRank(rest[i]), familyRank(rest[j]); left != right {
			return left < right
		}
		return rest[i] > rest[j]
	})
	return capModels(append(picked, rest...))
}

func capModels(models []string) []string {
	if len(models) > maxFallbackModels {
		return models[:maxFallbackModels]
	}
	return models
}

// sameFamily keeps a fallback on the protocol the CLI speaks: Claude models
// for Claude Code, GPT text models for Codex (not image or review models).
func sameFamily(targetID, id string) bool {
	if targetID == TargetCodexCLI {
		return strings.HasPrefix(id, "gpt-") && !strings.HasPrefix(id, "gpt-image")
	}
	return strings.HasPrefix(id, "claude-")
}

func familyRank(id string) int {
	if rank, slow := slowFallbackModels[id]; slow {
		return rank
	}
	switch {
	case strings.HasPrefix(id, "claude-sonnet"):
		return 0
	case strings.HasPrefix(id, "claude-haiku"):
		return 1
	case strings.HasPrefix(id, "claude-opus"):
		return 2
	default:
		return 3
	}
}

// withProbeModel names the model for one probe run. It goes last among the
// options so it wins over a model the managed arguments may carry: before
// the prompt for Codex (`-c model="…"`), before `-p <prompt>` for Claude.
func withProbeModel(targetID string, arguments []string, model string) []string {
	option := []string{"--model", model}
	at := len(arguments)
	if targetID == TargetCodexCLI {
		option = []string{"-c", `model="` + model + `"`}
		if at > 0 {
			at--
		}
	} else {
		for i, argument := range arguments {
			if argument == "-p" {
				at = i
				break
			}
		}
	}
	withModel := make([]string, 0, len(arguments)+len(option))
	withModel = append(withModel, arguments[:at]...)
	withModel = append(withModel, option...)
	return append(withModel, arguments[at:]...)
}

// workspace creates an empty project directory and a private TMPDIR so the
// probe never sees user files.
func (m *Manager) workspace(targetID string) (string, func(), error) {
	root, err := os.MkdirTemp(m.tempRoot, "zhiban-verify-"+targetID+"-")
	if err != nil {
		return "", func() {}, err
	}
	for _, name := range []string{"project", "tmp"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o700); err != nil {
			_ = os.RemoveAll(root)
			return "", func() {}, err
		}
	}
	return root, func() { _ = os.RemoveAll(root) }, nil
}

func (m *Manager) invocation(targetID string, installation Installation, managedArguments []string, workspace, scope string) (Invocation, string) {
	project := filepath.Join(workspace, "project")
	temporary := filepath.Join(workspace, "tmp")
	environment := verifyBaseEnvironment(m.homeDir, temporary, installation.Executable)
	// An npm launcher is `#!/usr/bin/env node`: without node on PATH the CLI
	// never starts and a working switch is reported "无法连接" (2026-09-14).
	environment = shellenv.PrependPath(environment, shellenv.NodeDirs(context.Background(), installation.Executable, m.nodeLookup))
	if m.proxyEnvironment != nil {
		// The sanitized environment dropped NO_PROXY: without it Codex takes
		// the system proxy to the gateway even where the user exempted it.
		environment = overrideEnvironment(environment, m.proxyEnvironment(context.Background()))
	}
	var arguments []string
	outputPath := ""
	switch targetID {
	case TargetCodexCLI:
		environment = append(environment, "CODEX_HOME="+filepath.Join(m.homeDir, ".codex"))
		outputPath = filepath.Join(workspace, "last-message.txt")
		arguments = append([]string{"exec"}, managedArguments...)
		arguments = append(arguments,
			// Codex posts analytics to chatgpt.com before exiting and waits up to
			// 25 s for it; behind a system proxy that POST hangs, adding ~7-8 s
			// to every check after the answer is already in (2026-09-15, 12009).
			// Only this probe run: the user's configuration is not changed.
			"-c", "analytics.enabled=false",
			// Codex retries a failed request 4 + 5 times with backoff (about 25 s
			// on a 503) before printing the gateway's answer; the Bridge already
			// retries a transient failure once, so one retry inside is enough.
			"-c", "model_providers."+configuration.CodexGlobalProviderID+".request_max_retries=1",
			"-c", "model_providers."+configuration.CodexGlobalProviderID+".stream_max_retries=1",
			"--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-C", project,
			"-o", outputPath, probePrompt,
		)
	default:
		// CLAUDE_CODE_MAX_RETRIES: Claude Code retries a 5xx about ten times
		// over three minutes, past the probe timeout, so the relay's answer was
		// never seen (2026-09-15); one retry, then the Bridge's own retry.
		environment = append(environment, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "DISABLE_AUTOUPDATER=1", "CLAUDE_CODE_MAX_RETRIES=1")
		arguments = append([]string{}, managedArguments...)
		if scope == ScopeGlobal {
			// The user's own settings.json carries the switch, so it must be
			// loaded: no --bare / --setting-sources here.
			arguments = append(arguments,
				"--no-session-persistence", "--no-chrome",
				"--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`,
				"--tools", "", "--permission-prompts", "none",
				"--output-format", "json", "--max-turns", "1", "-p", probePrompt,
			)
		} else {
			arguments = append(arguments,
				"--bare", "--restricted", "--no-session-persistence", "--no-chrome",
				"--setting-sources", "", "--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`,
				"--tools", "", "--permission-prompts", "none",
				"--output-format", "json", "--max-turns", "1", "-p", probePrompt,
			)
		}
	}
	return Invocation{Executable: installation.Executable, Arguments: arguments, Dir: project, Environment: environment}, outputPath
}

// maxProbeDegradations bounds how many options the probe may drop in one run.
const maxProbeDegradations = 3

// unknownProbeOptionPattern matches how the CLIs name an option they do not
// know: commander prints `error: unknown option '--permission-prompts'`,
// clap prints `unexpected argument '--foo' found`.
var unknownProbeOptionPattern = regexp.MustCompile(`(?i)(?:unknown|unrecognized|unexpected|invalid) (?:option|argument|flag)[^'"\n]*['"]?(--[A-Za-z0-9][A-Za-z0-9-]*)`)

// probeOptionArity tells whether a droppable probe option carries a value.
// Only hardening options appear here: dropping one keeps the probe honest
// (it still sends one real request and reads the answer), while required
// options such as --output-format or -p are never dropped.
var probeOptionArity = map[string]int{
	"--permission-prompts": 1,
	"--no-chrome":          0,
	"--strict-mcp-config":  0,
	"--mcp-config":         1,
	"--tools":              1,
	"--restricted":         0,
	"--bare":               0,
	"--setting-sources":    1,
}

// unknownProbeOption returns the option a CLI reported as unknown.
func unknownProbeOption(output []byte) (string, bool) {
	match := unknownProbeOptionPattern.FindSubmatch(output)
	if len(match) < 2 {
		return "", false
	}
	return string(match[1]), true
}

// dropProbeArgument removes option (and its value) from arguments when it is
// a known droppable one; it reports whether anything was removed.
func dropProbeArgument(arguments []string, option string) ([]string, bool) {
	arity, ok := probeOptionArity[option]
	if !ok {
		return arguments, false
	}
	reduced := make([]string, 0, len(arguments))
	dropped := false
	for index := 0; index < len(arguments); index++ {
		if arguments[index] == option {
			index += arity
			dropped = true
			continue
		}
		reduced = append(reduced, arguments[index])
	}
	return reduced, dropped
}

// transientGatewayCode reports whether a probe classification is worth one
// retry: the gateway answered oddly or not at all, rather than rejecting the
// credential or the quota.
func transientGatewayCode(errorCode string) bool {
	return strings.HasSuffix(errorCode, "-GATEWAY-MODEL_DENIED") ||
		strings.HasSuffix(errorCode, "-GATEWAY-UPSTREAM_UNAVAILABLE") ||
		strings.HasSuffix(errorCode, "-GATEWAY-PROTOCOL_MISMATCH") ||
		strings.HasSuffix(errorCode, "-GATEWAY-UNREACHABLE")
}

// sleepContext waits for delay unless ctx ends first; it reports false when
// the context was cancelled.
func sleepContext(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func probeSucceeded(targetID string, output []byte, outputPath string) bool {
	if targetID == TargetCodexCLI {
		content, err := os.ReadFile(outputPath)
		return err == nil && len(bytes.TrimSpace(content)) > 0
	}
	return len(bytes.TrimSpace(output)) > 0
}

// classifyProbe maps probe output to a contract error code. When the CLI
// reports the gateway's HTTP answer, the status decides the code and the
// relay's redacted message is returned as the detail (gateway_error.go);
// nothing else of the output is kept.
func classifyProbe(targetID string, output []byte) (string, string) {
	if match := helperCodePattern.Find(output); len(match) > 0 {
		return string(match), ""
	}
	if answer, ok := parseGatewayError(targetID, output); ok {
		return classifyGatewayError(targetID, answer), gatewayDetail(answer)
	}
	return classify(targetID, output), ""
}

// classify maps unparsed probe output to a contract error code by keywords.
func classify(targetID string, output []byte) string {
	if match := helperCodePattern.Find(output); len(match) > 0 {
		return string(match)
	}
	text := strings.ToLower(string(output))
	switch {
	case fallbackUnauthorized.MatchString(text) || containsAny(text, "unauthorized", "invalid api key", "authentication_error", "invalid token"):
		return code(targetID, "AUTH", "TOKEN_EXPIRED")
	case fallbackTooMany.MatchString(text) || containsAny(text, "rate limit", "rate_limit", "quota", "insufficient_quota", "insufficient balance"):
		return code(targetID, "GATEWAY", "QUOTA_EXHAUSTED")
	case strings.Contains(text, "model") && containsAny(text, "not found", "does not exist", "not exist", "unknown", "unsupported", "not available", "无"):
		return code(targetID, "GATEWAY", "MODEL_DENIED")
	case containsAny(text, "econnrefused", "enotfound", "econnreset", "etimedout", "connection refused", "connection reset",
		"network", "dns", "tls", "certificate", "timed out", "timeout", "unreachable", "fetch failed", "socket"):
		return code(targetID, "GATEWAY", "UNREACHABLE")
	default:
		return code(targetID, "GATEWAY", "PROTOCOL_MISMATCH")
	}
}

func exchangeCode(targetID string, err error) string {
	switch {
	case errors.Is(err, credential.ErrExchangeRejected):
		return code(targetID, "AUTH", "DEVICE_REVOKED")
	case errors.Is(err, credential.ErrInsufficientCredit):
		return code(targetID, "AUTH", "INSUFFICIENT_CREDIT")
	case errors.Is(err, credential.ErrMemberKeyDisabled):
		return code(targetID, "AUTH", "MEMBER_KEY_DISABLED")
	case errors.Is(err, credential.ErrProfileUnsupported):
		return code(targetID, "AUTH", "SCOPE_DENIED")
	case errors.Is(err, credential.ErrExchangeUnavailable):
		return code(targetID, "GATEWAY", "UNREACHABLE")
	case errors.Is(err, credential.ErrInvalidExchangeResponse):
		return code(targetID, "GATEWAY", "PROTOCOL_MISMATCH")
	default:
		return code(targetID, "AUTH", "DEVICE_MISSING")
	}
}

// RunProcess is the default probe runner; the compatibility check
// (cmd/zhiban-local-bridge, build tag compatcheck) wraps it to keep the output
// of a failed probe.
func RunProcess(ctx context.Context, invocation Invocation) (Outcome, error) {
	return runProcess(ctx, invocation)
}

func runProcess(ctx context.Context, invocation Invocation) (Outcome, error) {
	command := verifyCommand(ctx, invocation.Executable, invocation.Arguments)
	command.Dir = invocation.Dir
	command.Env = invocation.Environment
	command.Stdin = nil
	// Run the probe isolated from the Bridge so a timeout or cancel also kills
	// anything the CLI spawned (process group on Unix, process tree on
	// Windows), and stop waiting on inherited pipes shortly after the context
	// ends.
	isolateProcess(command)
	command.WaitDelay = 2 * time.Second
	var output cappedBuffer
	command.Stdout = &output
	command.Stderr = &output
	err := command.Run()
	outcome := Outcome{Output: output.Bytes()}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		outcome.TimedOut = true
		return outcome, nil
	}
	if ctx.Err() != nil {
		return outcome, ctx.Err()
	}
	var exitErr *exec.ExitError
	switch {
	case err == nil:
		return outcome, nil
	case errors.Is(err, exec.ErrWaitDelay):
		// The probe's main process exited, but a background child it spawned
		// (on Windows, codex's model-manager keeps a "refresh models" stream
		// open) held the inherited pipe past WaitDelay and was killed. The main
		// exit status is authoritative and success is judged from the probe's
		// output file, so this is not a launch failure.
		if command.ProcessState != nil {
			outcome.ExitCode = command.ProcessState.ExitCode()
		}
		if outcome.ExitCode < 0 {
			outcome.ExitCode = 0
		}
		return outcome, nil
	case errors.As(err, &exitErr):
		outcome.ExitCode = exitErr.ExitCode()
		if outcome.ExitCode == 0 {
			outcome.ExitCode = 1
		}
		return outcome, nil
	default:
		outcome.StartFailed = true
		return outcome, nil
	}
}

type cappedBuffer struct {
	buffer bytes.Buffer
}

func (w *cappedBuffer) Write(data []byte) (int, error) {
	remaining := maxOutputBytes - w.buffer.Len()
	if remaining > 0 {
		if len(data) > remaining {
			data = data[:remaining]
		}
		_, _ = w.buffer.Write(data)
	}
	return len(data), nil
}

func (w *cappedBuffer) Bytes() []byte { return w.buffer.Bytes() }

func containsAny(text string, needles ...string) bool {
	for _, needle := range needles {
		if strings.Contains(text, needle) {
			return true
		}
	}
	return false
}

func validTarget(targetID string) bool {
	return targetID == TargetCodexCLI || targetID == TargetClaudeCLI || IsDesktopTarget(targetID)
}

// ComponentsReadyFunc returns nil when every provisioned runtime component of
// the target is present.
type ComponentsReadyFunc func(context.Context, string) error

// IsDesktopTarget reports whether the target is an application bundle (M3).
func IsDesktopTarget(targetID string) bool {
	return targetID == TargetCodexDesktop || targetID == TargetClaudeDesktop
}

// verifyDesktop is L1 + L2 for an application bundle: the configuration is
// switched and intact (checked by the caller) and the credential exchange
// works. A desktop app cannot run an automatic real request, so its ceiling is
// L2 ("已配置知办模型 API"); the App must never show it as "运行正常".
func (m *Manager) verifyDesktop(ctx context.Context, report *operation.Reporter, targetID string, installation Installation) (any, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	// L1 for a desktop application also requires the runtime components
	// Zhiban provisions for it (the Claude Code host bundle for Claude Desktop).
	if m.componentsReady != nil {
		if err := m.componentsReady(ctx, targetID); err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, operation.Fail(code(targetID, "VERIFY", "COMPONENT_MISSING"), err)
		}
	}
	report.Stage(StageL2, true)
	token, err := m.exchangeToken(ctx, targetID)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, operation.Fail(exchangeCode(targetID, err), err)
	}
	if !credential.ValidAccessToken(token) {
		return nil, operation.Fail(code(targetID, "GATEWAY", "PROTOCOL_MISMATCH"), nil)
	}
	token = ""
	_ = token
	m.refreshGlobalAfterExchange(ctx, targetID, ScopeGlobal)
	recorded, err := m.recordGlobal(ctx, targetID, installation.Version)
	if err != nil || recorded.VerificationLevel != configuration.VerificationL2 {
		return nil, operation.Fail(code(targetID, "VERIFY", "NOT_CONFIGURED"), err)
	}
	return Result{VerificationLevel: recorded.VerificationLevel, VerifiedAt: recorded.LastVerifiedAt}, nil
}

func code(targetID, stage, reason string) string {
	return "LCT-" + strings.ToUpper(targetID) + "-" + stage + "-" + reason
}

// overrideEnvironment replaces (or appends) each NAME=value of overrides in
// environment; names compare case-insensitively on Windows.
func overrideEnvironment(environment, overrides []string) []string {
	result := append([]string(nil), environment...)
	for _, item := range overrides {
		name, _, ok := strings.Cut(item, "=")
		if !ok || name == "" {
			continue
		}
		replaced := false
		for index, existing := range result {
			existingName, _, _ := strings.Cut(existing, "=")
			if existingName == name || (runtime.GOOS == "windows" && strings.EqualFold(existingName, name)) {
				result[index] = item
				replaced = true
			}
		}
		if !replaced {
			result = append(result, item)
		}
	}
	return result
}

// refreshGlobalAfterExchange lets the configuration manager refresh the Codex
// model catalog of a global switch before L3 starts Codex with it.
func (m *Manager) refreshGlobalAfterExchange(ctx context.Context, targetID, scope string) {
	if m.refreshGlobal == nil || scope != ScopeGlobal || (targetID != TargetCodexCLI && targetID != TargetCodexDesktop) {
		return
	}
	_ = m.refreshGlobal(ctx, targetID)
}
