package detect

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
)

func TestDetectorMapsDiscoveryAndProbeStates(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name          string
		target        string
		candidates    []Candidate
		discoverErr   error
		version       string
		probeErr      error
		wantState     string
		wantErrorCode string
		wantProbes    int
	}{
		{name: "not installed", target: TargetCodexCLI, wantState: UIStateNotInstalled},
		{
			name: "trusted installation", target: TargetClaudeCLI,
			candidates: []Candidate{{Path: "/Users/test/.local/bin/claude", RealPath: "/Users/test/.local/share/claude/versions/2.1.263", Source: SourceOfficial}},
			version:    "2.1.263", wantState: UIStateInstalledUnmanaged, wantProbes: 1,
		},
		{
			name: "unknown source", target: TargetCodexCLI,
			candidates: []Candidate{{Path: "/Users/test/bin/codex", RealPath: "/Users/test/bin/codex", Source: SourceUnknown}},
			wantState:  UIStateUnsupported, wantErrorCode: "LCT-CODEX_CLI-DETECT-UNTRUSTED_PATH",
		},
		{
			name: "multiple installations", target: TargetClaudeCLI,
			candidates: []Candidate{
				{Path: "/opt/homebrew/bin/claude", RealPath: "/opt/homebrew/Caskroom/claude-code/2.1.263/claude", Source: SourceHomebrew},
				{Path: "/Users/test/.local/bin/claude", RealPath: "/Users/test/.local/share/claude/versions/2.1.263", Source: SourceOfficial},
			},
			// 2026-09-14: several copies are no longer a user choice. Same version,
			// no preferred copy → official wins; each copy is probed once.
			version: "2.1.263", wantState: UIStateInstalledUnmanaged, wantProbes: 2,
		},
		{
			name: "untrusted path lookup", target: TargetCodexCLI, discoverErr: ErrUntrustedSearchPath,
			wantState: UIStateUnsupported, wantErrorCode: "LCT-CODEX_CLI-DETECT-UNTRUSTED_PATH",
		},
		{
			name: "version timeout", target: TargetClaudeCLI,
			candidates: []Candidate{{Path: "/known/claude", RealPath: "/known/claude", Source: SourceOfficial}}, probeErr: ErrProbeTimeout,
			wantState: UIStateRepairable, wantErrorCode: "LCT-CLAUDE_CLI-DETECT-TIMEOUT", wantProbes: 1,
		},
		{
			name: "damaged executable", target: TargetCodexCLI,
			candidates: []Candidate{{Path: "/known/codex", RealPath: "/known/codex", Source: SourceNPM}}, probeErr: ErrProbeFailed,
			wantState: UIStateRepairable, wantErrorCode: "LCT-CODEX_CLI-DETECT-DAMAGED", wantProbes: 1,
		},
		{
			name: "unknown version", target: TargetCodexCLI,
			candidates: []Candidate{{Path: "/known/codex", RealPath: "/known/codex", Source: SourceHomebrew}}, probeErr: ErrVersionUnrecognized,
			wantState: UIStateUnsupported, wantErrorCode: "LCT-CODEX_CLI-DETECT-VERSION_UNKNOWN", wantProbes: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			probes := 0
			detector, err := NewDetector(
				func(context.Context, string) ([]Candidate, error) { return tt.candidates, tt.discoverErr },
				func(context.Context, string, Candidate) (string, error) {
					probes++
					return tt.version, tt.probeErr
				},
				[]byte("0123456789abcdef0123456789abcdef"),
			)
			if err != nil {
				t.Fatalf("NewDetector() error = %v", err)
			}
			state, err := detector.Detect(context.Background(), tt.target)
			if err != nil {
				t.Fatalf("Detect() error = %v", err)
			}
			if state.TargetID != tt.target || state.UIState != tt.wantState || state.ErrorCode != tt.wantErrorCode {
				t.Fatalf("state = %+v, want state=%s error=%s", state, tt.wantState, tt.wantErrorCode)
			}
			if probes != tt.wantProbes {
				t.Fatalf("probe calls = %d, want %d", probes, tt.wantProbes)
			}
			if strings.Contains(state.InstallationID, "/") {
				t.Fatalf("installation id leaks a path: %q", state.InstallationID)
			}
			if tt.wantState == UIStateInstalledUnmanaged {
				if state.InstallationID == "" || state.InstalledVersion != tt.version || state.InstallSource != SourceOfficial {
					t.Fatalf("trusted state = %+v", state)
				}
			}
		})
	}
}

func TestDetectorGenerationIncreasesAndOpaqueIDIsStableWithinProcess(t *testing.T) {
	t.Parallel()

	candidate := Candidate{Path: "/known/codex", RealPath: "/private/Users/alice/codex", Source: SourceOfficial}
	detector, err := NewDetector(
		func(context.Context, string) ([]Candidate, error) { return []Candidate{candidate}, nil },
		func(context.Context, string, Candidate) (string, error) { return "0.153.4", nil },
		[]byte("0123456789abcdef0123456789abcdef"),
	)
	if err != nil {
		t.Fatalf("NewDetector() error = %v", err)
	}
	first, err := detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("first Detect() error = %v", err)
	}
	second, err := detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("second Detect() error = %v", err)
	}
	if first.Generation != 1 || second.Generation != 2 {
		t.Fatalf("generations = %d,%d", first.Generation, second.Generation)
	}
	if first.InstallationID == "" || first.InstallationID != second.InstallationID {
		t.Fatalf("installation ids = %q,%q", first.InstallationID, second.InstallationID)
	}
	if strings.Contains(first.InstallationID, "alice") || strings.Contains(first.InstallationID, "codex") {
		t.Fatalf("installation id leaks path material: %q", first.InstallationID)
	}
}

func TestDetectorRejectsUnsupportedTargetAndInvalidKey(t *testing.T) {
	t.Parallel()

	if _, err := NewDetector(nil, nil, []byte("short")); err == nil {
		t.Fatal("NewDetector() error = nil, want invalid key")
	}
	detector, err := NewDetector(
		func(context.Context, string) ([]Candidate, error) { return nil, nil },
		func(context.Context, string, Candidate) (string, error) { return "", nil },
		[]byte("0123456789abcdef0123456789abcdef"),
	)
	if err != nil {
		t.Fatalf("NewDetector() error = %v", err)
	}
	// Desktop targets are valid since M3; an unknown id is still rejected.
	_, err = detector.Detect(context.Background(), "codex_web")
	if !errors.Is(err, ErrUnsupportedTarget) {
		t.Fatalf("Detect() error = %v, want ErrUnsupportedTarget", err)
	}
}

func TestDetectorResolvesOnlyTheFreshInstallationBoundToOpaqueID(t *testing.T) {
	t.Parallel()

	candidate := Candidate{Path: "/known/codex", RealPath: "/private/known/codex", Source: SourceOfficial}
	detector, err := NewDetector(
		func(context.Context, string) ([]Candidate, error) { return []Candidate{candidate}, nil },
		func(context.Context, string, Candidate) (string, error) { return "0.153.4", nil },
		[]byte("0123456789abcdef0123456789abcdef"),
	)
	if err != nil {
		t.Fatal(err)
	}
	state, err := detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := detector.ResolveInstallation(context.Background(), TargetCodexCLI, state.InstallationID)
	if err != nil {
		t.Fatalf("ResolveInstallation() error = %v", err)
	}
	if resolved.TargetID != TargetCodexCLI || resolved.InstallationID != state.InstallationID || resolved.RealPath != candidate.RealPath || resolved.Version != "0.153.4" {
		t.Fatalf("resolved = %+v", resolved)
	}
	current, err := detector.ResolveCurrentInstallation(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("ResolveCurrentInstallation() error = %v", err)
	}
	if current != resolved {
		t.Fatalf("current = %+v, want %+v", current, resolved)
	}

	candidate.RealPath = "/private/changed/codex"
	if _, err := detector.ResolveInstallation(context.Background(), TargetCodexCLI, state.InstallationID); !errors.Is(err, ErrInstallationChanged) {
		t.Fatalf("changed installation error = %v", err)
	}
	if _, err := detector.ResolveInstallation(context.Background(), TargetClaudeCLI, state.InstallationID); !errors.Is(err, ErrInstallationChanged) {
		t.Fatalf("cross-target installation error = %v", err)
	}
}

func TestDetectorPicksTheInstallationTheUserRuns(t *testing.T) {
	t.Parallel()
	homebrew := Candidate{Path: "/opt/homebrew/bin/codex", RealPath: "/opt/homebrew/Cellar/codex/0.144.1/bin/codex", Source: SourceHomebrew}
	official := Candidate{Path: "/Users/test/.local/bin/codex", RealPath: "/Users/test/.codex/packages/standalone/0.153.4/bin/codex", Source: SourceOfficial}
	npm := Candidate{Path: "/Users/test/.nvm/versions/node/v24/bin/codex", RealPath: "/Users/test/.nvm/versions/node/v24/lib/node_modules/@openai/codex/bin/codex.js", Source: SourceNPM}
	npmSame := Candidate{Path: npm.Path, RealPath: npm.RealPath + ".same", Source: SourceNPM}
	unknown := Candidate{Path: "/Users/test/bin/codex", RealPath: "/Users/test/bin/codex", Source: SourceUnknown}
	preferred := func(candidate Candidate) Candidate {
		candidate.Preferred = true
		return candidate
	}
	versions := map[string]string{
		homebrew.RealPath: "0.144.1",
		official.RealPath: "0.153.4",
		npm.RealPath:      "0.154.0",
		npmSame.RealPath:  "0.153.4",
	}

	tests := []struct {
		name       string
		candidates []Candidate
		broken     map[string]error
		wantPath   string
		wantState  string
		wantError  string
	}{
		{
			name:       "the copy the user's shell resolves wins over a newer one",
			candidates: []Candidate{official, preferred(homebrew)},
			wantPath:   homebrew.RealPath, wantState: UIStateInstalledUnmanaged,
		},
		{
			name:       "without a preferred copy the highest version wins",
			candidates: []Candidate{official, homebrew, npm},
			wantPath:   npm.RealPath, wantState: UIStateInstalledUnmanaged,
		},
		{
			name:       "same version prefers official over npm",
			candidates: []Candidate{npmSame, official},
			wantPath:   official.RealPath, wantState: UIStateInstalledUnmanaged,
		},
		{
			// Repair installs Zhiban's own copy; reporting the broken
			// preferred copy again would keep the card on "安装已损坏".
			name:       "a broken preferred copy gives way to a working one",
			candidates: []Candidate{official, preferred(homebrew)},
			broken:     map[string]error{homebrew.RealPath: ErrProbeFailed},
			wantPath:   official.RealPath, wantState: UIStateInstalledUnmanaged,
		},
		{
			name:       "a broken preferred copy is reported when nothing works",
			candidates: []Candidate{official, preferred(homebrew)},
			broken:     map[string]error{homebrew.RealPath: ErrProbeFailed, official.RealPath: ErrProbeTimeout},
			wantPath:   homebrew.RealPath, wantState: UIStateRepairable, wantError: "LCT-CODEX_CLI-DETECT-DAMAGED",
		},
		{
			name:       "a broken copy loses to a working one when nothing is preferred",
			candidates: []Candidate{npm, official},
			broken:     map[string]error{npm.RealPath: ErrProbeFailed},
			wantPath:   official.RealPath, wantState: UIStateInstalledUnmanaged,
		},
		{
			name:       "untrusted copies are ignored, even the preferred one",
			candidates: []Candidate{preferred(unknown), homebrew},
			wantPath:   homebrew.RealPath, wantState: UIStateInstalledUnmanaged,
		},
		{
			name:       "every trusted copy broken reports the first",
			candidates: []Candidate{homebrew, official},
			broken:     map[string]error{homebrew.RealPath: ErrProbeTimeout, official.RealPath: ErrProbeFailed},
			wantPath:   homebrew.RealPath, wantState: UIStateRepairable, wantError: "LCT-CODEX_CLI-DETECT-TIMEOUT",
		},
		{
			name:       "only untrusted copies",
			candidates: []Candidate{unknown, {Path: "/tmp/codex", RealPath: "/tmp/codex", Source: SourceUnknown}},
			wantState:  UIStateUnsupported, wantError: "LCT-CODEX_CLI-DETECT-UNTRUSTED_PATH",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			probes := map[string]int{}
			var mu sync.Mutex
			detector, err := NewDetector(
				func(context.Context, string) ([]Candidate, error) { return tt.candidates, nil },
				func(_ context.Context, _ string, candidate Candidate) (string, error) {
					mu.Lock()
					probes[candidate.RealPath]++
					mu.Unlock()
					if probeErr := tt.broken[candidate.RealPath]; probeErr != nil {
						return "", probeErr
					}
					return versions[candidate.RealPath], nil
				},
				[]byte("0123456789abcdef0123456789abcdef"),
			)
			if err != nil {
				t.Fatal(err)
			}
			state, err := detector.Detect(context.Background(), TargetCodexCLI)
			if err != nil {
				t.Fatal(err)
			}
			if state.UIState != tt.wantState || state.ErrorCode != tt.wantError {
				t.Fatalf("state = %+v, want %s / %q", state, tt.wantState, tt.wantError)
			}
			encoded, _ := json.Marshal(state)
			for _, forbidden := range []string{"/opt/homebrew", "/Users/test", "/tmp/codex", "candidates", "MULTIPLE_INSTALLS"} {
				if strings.Contains(string(encoded), forbidden) {
					t.Fatalf("state leaks %q: %s", forbidden, encoded)
				}
			}
			for path, count := range probes {
				if count > 1 {
					t.Fatalf("%s probed %d times", path, count)
				}
			}
			if tt.wantPath == "" {
				return
			}
			if state.InstallationID == "" {
				t.Fatalf("picked state has no installation id: %+v", state)
			}
			if tt.wantState == UIStateInstalledUnmanaged {
				if state.InstalledVersion != versions[tt.wantPath] {
					t.Fatalf("version = %q, want %q", state.InstalledVersion, versions[tt.wantPath])
				}
				resolved, err := detector.ResolveInstallation(context.Background(), TargetCodexCLI, state.InstallationID)
				if err != nil || resolved.RealPath != tt.wantPath {
					t.Fatalf("ResolveInstallation(picked) = %+v, %v; want %s", resolved, err, tt.wantPath)
				}
			}
		})
	}
}

func TestDetectorPicksTheNewestDesktopBundle(t *testing.T) {
	t.Parallel()
	system := Candidate{Path: "/Applications/Codex.app", RealPath: "/Applications/Codex.app", Source: SourceOfficial}
	renamed := Candidate{Path: "/Applications/ChatGPT.app", RealPath: "/Applications/ChatGPT.app", Source: SourceOfficial}
	user := Candidate{Path: "/Users/test/Applications/Codex.app", RealPath: "/Users/test/Applications/Codex.app", Source: SourceOfficial}
	versions := map[string]string{system.RealPath: "26.623.141536", renamed.RealPath: "26.908.40834", user.RealPath: "26.908.40834"}
	detector, err := NewDetector(
		func(context.Context, string) ([]Candidate, error) { return []Candidate{system, renamed, user}, nil },
		func(_ context.Context, _ string, candidate Candidate) (string, error) {
			return versions[candidate.RealPath], nil
		},
		[]byte("0123456789abcdef0123456789abcdef"),
	)
	if err != nil {
		t.Fatal(err)
	}
	state, err := detector.Detect(context.Background(), TargetCodexDesktop)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := detector.ResolveInstallation(context.Background(), TargetCodexDesktop, state.InstallationID)
	if state.UIState != UIStateInstalledUnmanaged || state.InstalledVersion != "26.908.40834" || err != nil || resolved.RealPath != renamed.RealPath {
		t.Fatalf("state = %+v resolved = %+v, %v", state, resolved, err)
	}
	all, err := detector.ResolveCurrentInstallations(context.Background(), TargetCodexDesktop)
	if err != nil || len(all) != 3 {
		t.Fatalf("ResolveCurrentInstallations() = %+v, %v", all, err)
	}
}

// 2026-09-15 · A Codex older than the minimum switchable version is still
// reported installed (usable, openable, upgradable) but not switchable.
func TestDetectorMarksTooOldCodexNotSwitchable(t *testing.T) {
	t.Parallel()
	candidate := Candidate{Path: "/old/codex", RealPath: "/private/old/codex", Source: SourceNPM}
	detector, err := NewDetector(
		func(context.Context, string) ([]Candidate, error) { return []Candidate{candidate}, nil },
		func(context.Context, string, Candidate) (string, error) { return "0.130.0", nil },
		[]byte("0123456789abcdef0123456789abcdef"),
	)
	if err != nil {
		t.Fatal(err)
	}
	state, err := detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatal(err)
	}
	if state.UIState != UIStateInstalledUnmanaged || state.InstalledVersion != "0.130.0" || state.SupportsEnable ||
		state.MinimumVersion != "0.137.0" || state.ErrorCode != "LCT-CODEX_CLI-DETECT-VERSION_TOO_OLD" {
		t.Fatalf("state = %+v", state)
	}
}

// 2026-09-15 · A Claude Desktop that cannot read the third-party inference
// configuration is reported installed but not switchable; an unknown result
// never blocks.
func TestDetectorMarksDesktopWithoutThirdPartyInferenceNotSwitchable(t *testing.T) {
	t.Parallel()
	candidate := Candidate{Path: "/Applications/Claude.app", RealPath: "/Applications/Claude.app", Source: SourceOfficial}
	newDetector := func(supported, known bool) *Detector {
		detector, err := NewDetector(
			func(context.Context, string) ([]Candidate, error) { return []Candidate{candidate}, nil },
			func(context.Context, string, Candidate) (string, error) { return "0.9.1", nil },
			[]byte("0123456789abcdef0123456789abcdef"),
		)
		if err != nil {
			t.Fatal(err)
		}
		detector.SetThirdPartyInference(func(context.Context, string, Candidate) (bool, bool) { return supported, known })
		return detector
	}
	state, err := newDetector(false, true).Detect(context.Background(), TargetClaudeDesktop)
	if err != nil {
		t.Fatal(err)
	}
	if state.UIState != UIStateInstalledUnmanaged || state.SupportsEnable || state.ErrorCode != "LCT-CLAUDE_DESKTOP-DETECT-THIRD_PARTY_UNSUPPORTED" {
		t.Fatalf("old desktop state = %+v", state)
	}
	state, err = newDetector(false, false).Detect(context.Background(), TargetClaudeDesktop)
	if err != nil {
		t.Fatal(err)
	}
	if !state.SupportsEnable || state.ErrorCode != "" {
		t.Fatalf("unknown capability must not block: %+v", state)
	}
}
