package detect

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
)

const testHostLiteral = `{"version":"2.1.260","manifest":{"version":"2.1.260","platforms":{"darwin-arm64":{"binary":"claude.zst","checksum":"90c8e9f337f7461b7582862f35ce22f89ad13b8d529c150f2969e8fa6d3bf020","size":65758751,"bundle":{"checksum":"7639b52c3ff28116f770e198ffb9760f9ecd44632a7c2a0ff0200c4dcf1dd038","size":65759778}}}},"baseUrl":"https://downloads.claude.ai/claude-code-releases"}`

// M3 Task 8 · An installed Claude Desktop reports its Claude Code host
// component: the pinned version comes from the bundle's embedded manifest and
// the state from Claude-3p's storage under the home directory.
func TestDetectorReportsClaudeCodeHostComponent(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	discoverer, system, _ := newBundleFixture(t)
	home := t.TempDir()
	spec := desktopBundles[TargetClaudeDesktop]
	prober := BundleProber{Timeout: time.Second, Verify: func(context.Context, string) error { return nil }}
	detector, err := NewDetector(discoverer.Discover, prober.Probe, bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	detector.SetComponents(ClaudeDesktopComponents(home, claudecode.ArchARM64))

	official := writeFakeBundle(t, system, spec.Name, spec.Identifier, testClaudeDesktopVersion)
	markTeam(t, official, spec.TeamIdentifier)

	// No app.asar at all: the component is reported but unknown.
	state, err := detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != UIStateInstalledUnmanaged || len(state.Components) != 1 ||
		state.Components[0].ID != claudecode.ComponentID || state.Components[0].State != claudecode.StateUnknown {
		t.Fatalf("Detect(no manifest) = %+v, %v", state, err)
	}

	asar := filepath.Join(official, "Contents", "Resources", "app.asar")
	if err := os.MkdirAll(filepath.Dir(asar), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(asar, []byte(`junk{"x":1}function NXe(){return JSON.parse('`+testHostLiteral+`')}`), 0o644); err != nil {
		t.Fatal(err)
	}
	state, err = detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || len(state.Components) != 1 || state.Components[0].Version != "2.1.260" ||
		state.Components[0].State != claudecode.StateMissing {
		t.Fatalf("Detect(missing component) = %+v, %v", state, err)
	}

	binary := claudecode.BinaryPath(home, "2.1.260")
	if err := os.MkdirAll(filepath.Dir(binary), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binary, []byte{0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 1, 2, 3, 4}, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(claudecode.VerifiedPath(home, "2.1.260"), []byte("7639b52c3ff28116f770e198ffb9760f9ecd44632a7c2a0ff0200c4dcf1dd038"), 0o644); err != nil {
		t.Fatal(err)
	}
	state, err = detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || len(state.Components) != 1 || state.Components[0].State != claudecode.StatePresent {
		t.Fatalf("Detect(present component) = %+v, %v", state, err)
	}

	// Codex Desktop and the CLIs have no components.
	reporter := ClaudeDesktopComponents(home, claudecode.ArchARM64)
	for _, other := range []string{TargetCodexDesktop, TargetCodexCLI, TargetClaudeCLI} {
		if components := reporter(context.Background(), other, Candidate{RealPath: official}); components != nil {
			t.Fatalf("%s components = %+v, want none", other, components)
		}
	}
	if HostArch() == "" {
		t.Fatal("HostArch() must name the test architecture")
	}
}
