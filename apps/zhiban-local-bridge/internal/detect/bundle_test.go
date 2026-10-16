package detect

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

const testClaudeDesktopVersion = "1.46388.4"

// writeFakeBundle lays out <dir>/<name>/Contents/{Info.plist,MacOS/<exe>} with an
// XML Info.plist declaring identifier and version.
func writeFakeBundle(t *testing.T, dir, name, identifier, version string) string {
	t.Helper()
	bundle := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Join(bundle, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatalf("MkdirAll bundle: %v", err)
	}
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>` + identifier + `</string>
	<key>CFBundleName</key>
	<string>Fake</string>
	<key>CFBundleShortVersionString</key>
	<string>` + version + `</string>
	<key>CFBundleVersion</key>
	<string>4753</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
</dict>
</plist>
`
	if err := os.WriteFile(filepath.Join(bundle, "Contents", "Info.plist"), []byte(plist), 0o644); err != nil {
		t.Fatalf("write Info.plist: %v", err)
	}
	mustWriteExecutable(t, filepath.Join(bundle, "Contents", "MacOS", strings.TrimSuffix(name, ".app")), "#!/bin/sh\nexit 0\n")
	return bundle
}

// signatureByMarker fakes codesign: the Team is whatever Contents/team.txt says.
func signatureByMarker(identifier string) BundleSignatureFunc {
	return func(_ context.Context, bundlePath string) (BundleSignature, error) {
		team, err := os.ReadFile(filepath.Join(bundlePath, "Contents", "team.txt"))
		if err != nil {
			return BundleSignature{}, err
		}
		return BundleSignature{Identifier: identifier, TeamIdentifier: strings.TrimSpace(string(team))}, nil
	}
}

func markTeam(t *testing.T, bundle, team string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(bundle, "Contents", "team.txt"), []byte(team+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func newBundleFixture(t *testing.T) (*MacOSDiscoverer, string, string) {
	t.Helper()
	home := t.TempDir()
	system := filepath.Join(home, "SystemApplications")
	user := filepath.Join(home, "Applications")
	for _, dir := range []string{system, user} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	discoverer := NewMacOSDiscoverer(home)
	discoverer.SystemApplicationsDir = system
	discoverer.UserApplicationsDir = user
	spec := desktopBundles[TargetClaudeDesktop]
	discoverer.BundleSignature = signatureByMarker(spec.Identifier)
	return discoverer, system, user
}

func TestBundleDiscoveryUsesFixedFoldersAndClassifiesBySignature(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	discoverer, system, user := newBundleFixture(t)
	spec := desktopBundles[TargetClaudeDesktop]

	// Nothing installed.
	candidates, err := discoverer.Discover(context.Background(), TargetClaudeDesktop)
	if err != nil || len(candidates) != 0 {
		t.Fatalf("Discover(empty) = %+v, %v", candidates, err)
	}

	// One bundle in the system folder signed by the publisher.
	official := writeFakeBundle(t, system, spec.Name, spec.Identifier, testClaudeDesktopVersion)
	markTeam(t, official, spec.TeamIdentifier)
	candidates, err = discoverer.Discover(context.Background(), TargetClaudeDesktop)
	if err != nil || len(candidates) != 1 || candidates[0].Source != SourceOfficial || candidates[0].Path != official {
		t.Fatalf("Discover(official) = %+v, %v", candidates, err)
	}

	// A second copy in the user folder with a foreign Team is untrusted but listed.
	foreign := writeFakeBundle(t, user, spec.Name, spec.Identifier, "9.9.9")
	markTeam(t, foreign, "ZZZZZZZZZZ")
	candidates, err = discoverer.Discover(context.Background(), TargetClaudeDesktop)
	if err != nil || len(candidates) != 2 || candidates[0].Source != SourceOfficial || candidates[1].Source != SourceUnknown {
		t.Fatalf("Discover(two) = %+v, %v", candidates, err)
	}

	// The same bundle reached through a symlinked user folder is deduplicated.
	if err := os.RemoveAll(foreign); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(official, filepath.Join(user, spec.Name)); err != nil {
		t.Fatal(err)
	}
	candidates, err = discoverer.Discover(context.Background(), TargetClaudeDesktop)
	if err != nil || len(candidates) != 1 {
		t.Fatalf("Discover(symlink dedupe) = %+v, %v", candidates, err)
	}

	// A folder that is not a bundle (no Contents/MacOS) is ignored.
	if err := os.RemoveAll(filepath.Join(user, spec.Name)); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(user, spec.Name, "Contents"), 0o755); err != nil {
		t.Fatal(err)
	}
	candidates, err = discoverer.Discover(context.Background(), TargetClaudeDesktop)
	if err != nil || len(candidates) != 1 {
		t.Fatalf("Discover(not a bundle) = %+v, %v", candidates, err)
	}

	// A bundle with the expected name but another identifier is not ours; a
	// bundle under any other name that declares our identifier is (publishers
	// rename bundles in updates: Codex.app became ChatGPT.app on 2026-09-09).
	if err := os.RemoveAll(filepath.Join(user, spec.Name)); err != nil {
		t.Fatal(err)
	}
	impostor := writeFakeBundle(t, user, spec.Name, "com.example.other", "1.0.0")
	markTeam(t, impostor, spec.TeamIdentifier)
	renamed := writeFakeBundle(t, user, "Claude Renamed.app", spec.Identifier, "1.50000.0")
	markTeam(t, renamed, spec.TeamIdentifier)
	candidates, err = discoverer.Discover(context.Background(), TargetClaudeDesktop)
	if err != nil || len(candidates) != 2 || candidates[1].Path != renamed || candidates[1].Source != SourceOfficial {
		t.Fatalf("Discover(renamed bundle) = %+v, %v", candidates, err)
	}
	if err := os.RemoveAll(impostor); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(renamed); err != nil {
		t.Fatal(err)
	}

	// CLI targets are unaffected by the Applications folders.
	discoverer.LookPath = func(string) (string, error) { return "", &exec.Error{Name: "claude", Err: exec.ErrNotFound} }
	discoverer.SystemCandidates = map[string][]string{}
	if cli, err := discoverer.Discover(context.Background(), TargetClaudeCLI); err != nil || len(cli) != 0 {
		t.Fatalf("Discover(cli) = %+v, %v", cli, err)
	}
}

func TestDetectorReportsDesktopStates(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	discoverer, system, user := newBundleFixture(t)
	spec := desktopBundles[TargetClaudeDesktop]
	verifyErr := map[string]error{}
	prober := BundleProber{
		Timeout: time.Second,
		Verify: func(_ context.Context, bundlePath string) error {
			return verifyErr[bundlePath]
		},
	}
	detector, err := NewDetector(discoverer.Discover, prober.Probe, bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}

	state, err := detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != UIStateNotInstalled || state.FormFactor != FormFactorDesktop || !state.SupportsEnable {
		t.Fatalf("Detect(not installed) = %+v, %v", state, err)
	}
	codex, err := detector.Detect(context.Background(), TargetCodexDesktop)
	if err != nil || codex.UIState != UIStateNotInstalled || !codex.SupportsEnable || codex.FormFactor != FormFactorDesktop {
		t.Fatalf("Detect(codex desktop) = %+v, %v", codex, err)
	}

	official := writeFakeBundle(t, system, spec.Name, spec.Identifier, testClaudeDesktopVersion)
	markTeam(t, official, spec.TeamIdentifier)
	state, err = detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != UIStateInstalledUnmanaged || state.InstalledVersion != testClaudeDesktopVersion ||
		state.InstallSource != SourceOfficial || state.InstallationID == "" {
		t.Fatalf("Detect(installed) = %+v, %v", state, err)
	}
	canonicalOfficial, err := filepath.EvalSymlinks(official)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := detector.ResolveInstallation(context.Background(), TargetClaudeDesktop, state.InstallationID)
	if err != nil || resolved.RealPath != canonicalOfficial || resolved.Version != testClaudeDesktopVersion {
		t.Fatalf("ResolveInstallation() = %+v, %v", resolved, err)
	}

	// Seal no longer verifies: damaged, repairable.
	verifyErr[canonicalOfficial] = errors.New("code object is not signed at all")
	state, err = detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != UIStateRepairable || state.ErrorCode != "LCT-CLAUDE_DESKTOP-DETECT-DAMAGED" {
		t.Fatalf("Detect(damaged) = %+v, %v", state, err)
	}
	delete(verifyErr, canonicalOfficial)

	// Foreign signature: untrusted.
	markTeam(t, official, "ZZZZZZZZZZ")
	state, err = detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != UIStateUnsupported || state.ErrorCode != "LCT-CLAUDE_DESKTOP-DETECT-UNTRUSTED_PATH" {
		t.Fatalf("Detect(untrusted) = %+v, %v", state, err)
	}
	markTeam(t, official, spec.TeamIdentifier)

	// Two trusted copies (contract §2.7, 2026-09-14): no user choice, the
	// newest copy is reported.
	second := writeFakeBundle(t, user, spec.Name, spec.Identifier, "1.46388.3")
	markTeam(t, second, spec.TeamIdentifier)
	state, err = detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != UIStateInstalledUnmanaged || state.ErrorCode != "" ||
		state.InstalledVersion != testClaudeDesktopVersion {
		t.Fatalf("Detect(two copies) = %+v, %v", state, err)
	}
	resolved, err = detector.ResolveInstallation(context.Background(), TargetClaudeDesktop, state.InstallationID)
	if err != nil || resolved.RealPath != canonicalOfficial {
		t.Fatalf("ResolveInstallation(two copies) = %+v, %v", resolved, err)
	}

	// An unparsable version string is unsupported, not damaged.
	if err := os.RemoveAll(second); err != nil {
		t.Fatal(err)
	}
	odd := writeFakeBundle(t, user, spec.Name, spec.Identifier, "beta")
	markTeam(t, odd, spec.TeamIdentifier)
	if err := os.RemoveAll(official); err != nil {
		t.Fatal(err)
	}
	state, err = detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || state.UIState != UIStateUnsupported || state.ErrorCode != "LCT-CLAUDE_DESKTOP-DETECT-VERSION_UNKNOWN" {
		t.Fatalf("Detect(odd version) = %+v, %v", state, err)
	}
}

func TestBundleProberTimeoutAndUnsupportedTarget(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	bundle := writeFakeBundle(t, home, "Claude.app", "com.anthropic.claudefordesktop", testClaudeDesktopVersion)
	slow := BundleProber{Timeout: 50 * time.Millisecond, Verify: func(ctx context.Context, _ string) error {
		<-ctx.Done()
		return ctx.Err()
	}}
	if _, err := slow.Probe(context.Background(), TargetClaudeDesktop, Candidate{RealPath: bundle}); !errors.Is(err, ErrProbeTimeout) {
		t.Fatalf("slow verify error = %v", err)
	}
	ok := BundleProber{Verify: func(context.Context, string) error { return nil }}
	if _, err := ok.Probe(context.Background(), TargetClaudeCLI, Candidate{RealPath: bundle}); !errors.Is(err, ErrUnsupportedTarget) {
		t.Fatalf("cli target error = %v", err)
	}
	if _, err := ok.Probe(context.Background(), TargetClaudeDesktop, Candidate{RealPath: filepath.Join(home, "Missing.app")}); !errors.Is(err, ErrProbeFailed) {
		t.Fatalf("missing bundle error = %v", err)
	}
}

func TestReadBundleVersionHandlesXMLAndBinaryPlists(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	bundle := writeFakeBundle(t, home, "Codex.app", "com.openai.codex", "26.623.141536")
	version, err := readBundleVersion(bundle)
	if err != nil || version != "26.623.141536" {
		t.Fatalf("readBundleVersion(xml) = %q, %v", version, err)
	}
	if runtime.GOOS != "darwin" {
		t.Skip("binary plist conversion needs plutil")
	}
	plist := filepath.Join(bundle, "Contents", "Info.plist")
	if output, err := exec.Command("/usr/bin/plutil", "-convert", "binary1", plist).CombinedOutput(); err != nil {
		t.Fatalf("plutil -convert binary1: %v %s", err, output)
	}
	head, _ := os.ReadFile(plist)
	if !bytes.HasPrefix(head, binaryPlistMagic) {
		t.Fatalf("plist not binary: %q", head[:8])
	}
	version, err = readBundleVersion(bundle)
	if err != nil || version != "26.623.141536" {
		t.Fatalf("readBundleVersion(binary) = %q, %v", version, err)
	}
}

func TestParseCodesignSignature(t *testing.T) {
	t.Parallel()
	sample := "Executable=/Applications/Codex.app/Contents/MacOS/Codex\nIdentifier=com.openai.codex\nFormat=app bundle with Mach-O universal (x86_64 arm64)\nCodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=30+7 location=embedded\nSignature size=9034\nAuthority=Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)\nTeamIdentifier=2DC432GLL2\nRuntime Version=15.0.0\n"
	signature, err := parseCodesignSignature([]byte(sample))
	if err != nil || signature.Identifier != "com.openai.codex" || signature.TeamIdentifier != "2DC432GLL2" {
		t.Fatalf("parseCodesignSignature() = %+v, %v", signature, err)
	}
	if _, err := parseCodesignSignature([]byte("Identifier=com.example.adhoc\nTeamIdentifier=not set\n")); err == nil {
		t.Fatal("ad-hoc signature must be rejected")
	}
	if _, err := parseCodesignSignature([]byte("code object is not signed at all")); err == nil {
		t.Fatal("unsigned output must be rejected")
	}
}

func TestDesktopTargetHelpers(t *testing.T) {
	t.Parallel()
	if !IsDesktopTarget(TargetCodexDesktop) || !IsDesktopTarget(TargetClaudeDesktop) || IsDesktopTarget(TargetCodexCLI) || IsDesktopTarget("desktop") {
		t.Fatal("IsDesktopTarget mismatch")
	}
	if FormFactor(TargetCodexCLI) != FormFactorCLI || FormFactor(TargetClaudeDesktop) != FormFactorDesktop {
		t.Fatal("FormFactor mismatch")
	}
	spec, ok := BundleSpecFor(TargetCodexDesktop)
	if !ok || spec.Name != "Codex.app" || spec.TeamIdentifier != "2DC432GLL2" {
		t.Fatalf("BundleSpecFor(codex) = %+v, %v", spec, ok)
	}
	if _, ok := BundleSpecFor(TargetCodexCLI); ok {
		t.Fatal("cli target must have no bundle spec")
	}
}
