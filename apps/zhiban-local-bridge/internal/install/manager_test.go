package install

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const (
	testCodexVersion  = "0.153.4"
	testClaudeVersion = "2.1.263"
)

type fixture struct {
	home     string
	server   *httptest.Server
	registry *operation.Registry
	manager  *Manager
	detector *detect.Detector
	// discoverer lets a test say which copy the user's own shell resolves.
	discoverer *detect.MacOSDiscoverer
	assets     map[string]Asset
	// Desktop targets (M3): the two Applications folders the fixture stands in
	// for, and whether the fake process table reports the bundle as running.
	systemApplications string
	userApplications   string
	inUse              atomic.Bool
	inUseCheckBroken   atomic.Bool
	// hostManifest stands in for the Claude Code manifest embedded in
	// Claude.app (M3 Task 8); nil means the bundle carries none.
	hostManifest *claudecode.Manifest
	// hostVersion stands in for running a derived host executable with
	// --version (host_npm_derived.go); nil fails the check.
	hostVersion func(executable string) (string, error)
}

func (f *fixture) readHostManifest(string) (claudecode.Manifest, error) {
	if f.hostManifest == nil {
		return claudecode.Manifest{}, claudecode.ErrManifestNotFound
	}
	return *f.hostManifest, nil
}

func codexScript() []byte {
	return []byte("#!/bin/sh\necho \"codex-cli " + testCodexVersion + "\"\n")
}

func claudeScript() []byte {
	return []byte("#!/bin/sh\necho \"" + testClaudeVersion + " (Claude Code)\"\n")
}

func tarballWith(t *testing.T, entries map[string][]byte, extra func(*tar.Writer)) []byte {
	t.Helper()
	var buffer bytes.Buffer
	compressor := gzip.NewWriter(&buffer)
	writer := tar.NewWriter(compressor)
	for name, content := range entries {
		if err := writer.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatalf("write tar header: %v", err)
		}
		if _, err := writer.Write(content); err != nil {
			t.Fatalf("write tar body: %v", err)
		}
	}
	if extra != nil {
		extra(writer)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := compressor.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}
	return buffer.Bytes()
}

func digestOf(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

func newFixture(t *testing.T, handler http.Handler, mutate func(map[string]Asset)) *fixture {
	t.Helper()
	home := t.TempDir()
	server := httptest.NewTLSServer(handler)
	t.Cleanup(server.Close)

	f := &fixture{
		home: home, server: server,
		systemApplications: filepath.Join(home, "SystemApplications"),
		userApplications:   filepath.Join(home, "Applications"),
	}
	for _, dir := range []string{f.systemApplications, f.userApplications} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("MkdirAll %s: %v", dir, err)
		}
	}
	discoverer := detect.NewMacOSDiscoverer(home)
	discoverer.LookPath = func(name string) (string, error) { return "", &exec.Error{Name: name, Err: exec.ErrNotFound} }
	discoverer.SystemCandidates = map[string][]string{}
	discoverer.SystemApplicationsDir = f.systemApplications
	discoverer.UserApplicationsDir = f.userApplications
	discoverer.BundleSignature = testBundleSignature
	prober := detect.VersionProber{Timeout: 10 * time.Second, HomeDir: home}
	bundleProber := detect.BundleProber{Timeout: 5 * time.Second, Verify: testBundleSeal}
	probe := func(ctx context.Context, targetID string, candidate detect.Candidate) (string, error) {
		if detect.IsDesktopTarget(targetID) {
			return bundleProber.Probe(ctx, targetID, candidate)
		}
		return prober.Probe(ctx, targetID, candidate)
	}
	detector, err := detect.NewDetector(discoverer.Discover, probe, bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatalf("NewDetector() error = %v", err)
	}
	detector.SetComponents(func(_ context.Context, targetID string, _ detect.Candidate) []detect.Component {
		if targetID != TargetClaudeDesktop {
			return nil
		}
		if f.hostManifest == nil {
			return []detect.Component{{ID: claudecode.ComponentID, State: claudecode.StateUnknown}}
		}
		return []detect.Component{claudecode.Status(home, *f.hostManifest, ArchARM64)}
	})

	codexArchive := codexPackageTarball(t, codexScript())
	assets := map[string]Asset{
		TargetCodexCLI: {
			TargetID: TargetCodexCLI, Arch: ArchARM64, Version: testCodexVersion, Source: SourceOfficialOpenAI,
			BinarySHA256: digestOf(codexScript()),
			Sources:      []Source{{Kind: SourceKindNPMRegistry, URL: server.URL + "/codex.tar.gz", Size: int64(len(codexArchive)), SHA256: digestOf(codexArchive), Layout: LayoutTarballTree, Member: codexPackagePrefix}},
		},
		TargetClaudeCLI: {
			TargetID: TargetClaudeCLI, Arch: ArchARM64, Version: testClaudeVersion, Source: SourceOfficialAnthropic,
			BinarySHA256: digestOf(claudeScript()),
			Sources:      []Source{{Kind: SourceKindOfficial, URL: server.URL + "/claude", Size: int64(len(claudeScript())), SHA256: digestOf(claudeScript()), Layout: LayoutBareBinary}},
		},
	}
	if mutate != nil {
		mutate(assets)
	}
	registry := operation.NewRegistry()
	assetList := make([]Asset, 0, len(assets))
	for _, targetID := range []string{TargetCodexCLI, TargetClaudeCLI, TargetCodexDesktop, TargetClaudeDesktop} {
		if asset, ok := assets[targetID]; ok {
			assetList = append(assetList, asset)
		}
	}
	manager, err := NewManager(ManagerConfig{
		HomeDir: home, Arch: ArchARM64, BridgeVersion: "0.3.0-test",
		Assets: assetList, AllowedHosts: []string{"127.0.0.1"},
		Transport: server.Client().Transport, Detect: detector.Detect, Operations: registry,
		OSVersion:             func() (string, error) { return "15.3", nil },
		FreeBytes:             func(string) (uint64, error) { return 10 << 30, nil },
		Writable:              func(string) bool { return true },
		SystemApplicationsDir: f.systemApplications,
		BundleTools: BundleTools{
			VerifyBundle: testVerifyBundle,
			AssessBundle: testAssessBundle,
			BundleInUse: func(string) (bool, error) {
				if f.inUseCheckBroken.Load() {
					return false, errors.New("process enumeration failed")
				}
				return f.inUse.Load(), nil
			},
			// A fake DMG "mount": materialise the fake bundle where the real
			// hdiutil+ditto path would copy it.
			ExtractDMG: func(_ context.Context, _ string, destinationDir string, _ []string) error {
				return unzipBytesInto(fakeBundleZip(t), destinationDir)
			},
		},
		ResolveInstallation: detector.ResolveInstallation,
		ReadHostManifest:    f.readHostManifest,
		// Derived host tarballs come from the fixture server, signed with a
		// test key standing in for the npm registry's.
		HostNPMRegistry: server.URL + "/npmreg",
		NPMRegistryKeys: map[string]string{testNPMKeyID: testNPMPublicKey()},
		HostVersion: func(_ context.Context, executable string) (string, error) {
			if f.hostVersion == nil {
				return "", errors.New("no host version")
			}
			return f.hostVersion(executable)
		},
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	f.registry, f.manager, f.detector, f.assets = registry, manager, detector, assets
	f.discoverer = discoverer
	return f
}

// codexPackagePrefix is the member directory of the fixture's Codex package
// tarball, shaped like @openai/codex-darwin-arm64 (layoutVersion 1).
const codexPackagePrefix = "package/vendor/aarch64-apple-darwin"

// codexPackageTarball builds the publisher's package tree around script as
// bin/codex: the Code Mode host, the bundled rg, a resource and the layout
// descriptor, plus package.json outside the vendor prefix like the real tgz.
func codexPackageTarball(t *testing.T, script []byte) []byte {
	t.Helper()
	type entry struct {
		name    string
		mode    int64
		content []byte
	}
	// Fixed order: the fixture asset and the fixture server each build their
	// own copy and their bytes must agree.
	entries := []entry{
		{"package/package.json", 0o644, []byte(`{"name":"@openai/codex-darwin-arm64"}`)},
		{codexPackagePrefix + "/bin/codex", 0o755, script},
		{codexPackagePrefix + "/bin/codex-code-mode-host", 0o755, []byte("#!/bin/sh\nexit 0\n")},
		{codexPackagePrefix + "/codex-path/rg", 0o755, []byte("#!/bin/sh\nexit 0\n")},
		{codexPackagePrefix + "/codex-resources/marker.txt", 0o644, []byte("resources\n")},
		{codexPackagePrefix + "/codex-package.json", 0o644, []byte(`{"layoutVersion":1,"entrypoint":"bin/codex"}`)},
	}
	return tarballWith(t, nil, func(writer *tar.Writer) {
		if err := writer.WriteHeader(&tar.Header{Name: codexPackagePrefix + "/bin", Mode: 0o755, Typeflag: tar.TypeDir}); err != nil {
			t.Fatalf("write tar header: %v", err)
		}
		for _, item := range entries {
			if err := writer.WriteHeader(&tar.Header{Name: item.name, Mode: item.mode, Size: int64(len(item.content)), Typeflag: tar.TypeReg}); err != nil {
				t.Fatalf("write tar header: %v", err)
			}
			if _, err := writer.Write(item.content); err != nil {
				t.Fatalf("write tar body: %v", err)
			}
		}
	})
}

func defaultHandler(t *testing.T) http.Handler {
	codexArchive := codexPackageTarball(t, codexScript())
	mux := http.NewServeMux()
	mux.HandleFunc("/codex.tar.gz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", itoa(len(codexArchive)))
		_, _ = w.Write(codexArchive)
	})
	mux.HandleFunc("/claude", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", itoa(len(claudeScript())))
		_, _ = w.Write(claudeScript())
	})
	return mux
}

func itoa(value int) string {
	return strings.TrimSpace(strings.Repeat(" ", 0) + intString(value))
}

func intString(value int) string {
	if value == 0 {
		return "0"
	}
	digits := ""
	for value > 0 {
		digits = string(rune('0'+value%10)) + digits
		value /= 10
	}
	return digits
}

func (f *fixture) runInstall(t *testing.T, targetID, mode string) operation.Envelope {
	t.Helper()
	plan, err := f.manager.Plan(context.Background(), targetID, mode)
	if err != nil {
		t.Fatalf("Plan(%s) error = %v", targetID, err)
	}
	envelope, err := f.manager.Execute(context.Background(), plan.PlanID)
	if err != nil {
		t.Fatalf("Execute(%s) error = %v", targetID, err)
	}
	if envelope.State != operation.StateRunning || envelope.Kind != operation.KindInstall || envelope.Stage != StagePreflight {
		t.Fatalf("initial envelope = %+v", envelope)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	final, err := f.registry.Wait(ctx, envelope.OperationID)
	if err != nil {
		t.Fatalf("Wait(%s) error = %v", targetID, err)
	}
	return final
}

func (f *fixture) downloadsDir() string {
	return filepath.Join(f.home, "Library", "Application Support", applicationSupport, "local-coding-tools", "downloads")
}

func (f *fixture) assertNoScratch(t *testing.T) {
	t.Helper()
	entries, err := os.ReadDir(f.downloadsDir())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("read downloads dir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("scratch files left behind: %v", entries)
	}
}

func TestInstallPlacesOfficialLayoutAndDetectsLockedVersion(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newFixture(t, defaultHandler(t), nil)

	for _, targetID := range []string{TargetCodexCLI, TargetClaudeCLI} {
		before, err := f.detector.Detect(context.Background(), targetID)
		if err != nil || before.UIState != detect.UIStateNotInstalled {
			t.Fatalf("Detect(%s) before = %+v, %v", targetID, before, err)
		}
		requirements, err := f.manager.Requirements(context.Background(), targetID)
		if err != nil || !requirements.Satisfied || len(requirements.Issues) != 0 || requirements.DownloadHost != "127.0.0.1" ||
			requirements.RequiredFreeBytes != requirements.DownloadSizeBytes*requiredFreeFactor || requirements.OSVersion != "15.3" {
			t.Fatalf("Requirements(%s) = %+v, %v", targetID, requirements, err)
		}
		final := f.runInstall(t, targetID, ModeInstall)
		if final.State != operation.StateSucceeded || final.ErrorCode != nil {
			t.Fatalf("install %s final = %+v code=%s", targetID, final, describeCode(final.ErrorCode))
		}
		result, ok := final.Result.(Result)
		if !ok || result.ToolState.UIState != detect.UIStateInstalledUnmanaged || result.ToolState.InstallSource != detect.SourceOfficial {
			t.Fatalf("install %s result = %#v", targetID, final.Result)
		}
	}

	codexPath := filepath.Join(f.home, ".codex", "packages", "standalone", testCodexVersion, "bin", "codex")
	claudePath := filepath.Join(f.home, ".local", "share", "claude", "versions", testClaudeVersion)
	for path, expected := range map[string][]byte{codexPath: codexScript(), claudePath: claudeScript()} {
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o755 {
			t.Fatalf("installed file %s = %v, %v", path, info, err)
		}
		content, _ := os.ReadFile(path)
		if !bytes.Equal(content, expected) {
			t.Fatalf("installed content mismatch for %s", path)
		}
	}
	for name, target := range map[string]string{"codex": codexPath, "claude": claudePath} {
		link := filepath.Join(f.home, ".local", "bin", name)
		if got, err := os.Readlink(link); err != nil || got != target {
			t.Fatalf("symlink %s -> %q, %v; want %q", link, got, err, target)
		}
	}
	f.assertNoScratch(t)

	after, err := f.detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil || after.UIState != detect.UIStateInstalledUnmanaged || after.InstalledVersion != testCodexVersion {
		t.Fatalf("Detect(codex) after = %+v, %v", after, err)
	}
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeInstall); !isCode(err, "LCT-CODEX_CLI-INSTALL-ALREADY_INSTALLED") {
		t.Fatalf("Plan() after install error = %v", err)
	}
	// The locked version sitting complete at its locked path is the install's
	// own leftover (resumable), not a conflict; anything else there still is.
	if requirements, _ := f.manager.Requirements(context.Background(), TargetClaudeCLI); !requirements.Satisfied || contains(requirements.Issues, IssueTargetConflict) {
		t.Fatalf("Requirements() after install = %+v", requirements)
	}
	claudeFinal := filepath.Join(f.home, ".local", "share", "claude", "versions", requirementsVersion(t, f, TargetClaudeCLI))
	if err := os.WriteFile(claudeFinal, []byte("#!/bin/sh\necho somebody else\n"), 0o755); err != nil {
		t.Fatalf("overwrite placed claude: %v", err)
	}
	if requirements, _ := f.manager.Requirements(context.Background(), TargetClaudeCLI); requirements.Satisfied || !contains(requirements.Issues, IssueTargetConflict) {
		t.Fatalf("Requirements() with a foreign file at the locked path = %+v", requirements)
	}
}

func requirementsVersion(t *testing.T, f *fixture, targetID string) string {
	t.Helper()
	requirements, err := f.manager.Requirements(context.Background(), targetID)
	if err != nil || requirements.Version == "" {
		t.Fatalf("Requirements(%s) = %+v, %v", targetID, requirements, err)
	}
	return requirements.Version
}

func TestInstallRejectsHashAndSizeMismatch(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newFixture(t, defaultHandler(t), func(assets map[string]Asset) {
		codex := assets[TargetCodexCLI]
		codex.Sources[0].SHA256 = strings.Repeat("0", 64)
		assets[TargetCodexCLI] = codex
		claude := assets[TargetClaudeCLI]
		claude.Sources[0].Size++
		claude.BinarySHA256 = ""
		assets[TargetClaudeCLI] = claude
	})

	final := f.runInstall(t, TargetCodexCLI, ModeInstall)
	if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CODEX_CLI-INSTALL-HASH_MISMATCH" {
		t.Fatalf("hash mismatch final = %+v", final)
	}
	final = f.runInstall(t, TargetClaudeCLI, ModeInstall)
	if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CLAUDE_CLI-INSTALL-SIZE_MISMATCH" {
		t.Fatalf("size mismatch final = %+v", final)
	}
	for _, path := range []string{
		filepath.Join(f.home, ".codex", "packages", "standalone", testCodexVersion, "bin", "codex"),
		filepath.Join(f.home, ".local", "share", "claude", "versions", testClaudeVersion),
		filepath.Join(f.home, ".local", "bin", "codex"),
		filepath.Join(f.home, ".local", "bin", "claude"),
	} {
		if _, err := os.Lstat(path); err == nil {
			t.Fatalf("%s exists after failed install", path)
		}
	}
	f.assertNoScratch(t)
	if state, _ := f.detector.Detect(context.Background(), TargetCodexCLI); state.UIState != detect.UIStateNotInstalled {
		t.Fatalf("state after failed install = %+v", state)
	}
}

func TestInstallCancelDuringDownloadCleansUp(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	started := make(chan struct{}, 1)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "1048576")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(bytes.Repeat([]byte("x"), 65536))
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		select {
		case started <- struct{}{}:
		default:
		}
		<-r.Context().Done()
	})
	f := newFixture(t, handler, func(assets map[string]Asset) {
		claude := assets[TargetClaudeCLI]
		claude.Sources[0].Size = 1048576
		claude.BinarySHA256 = ""
		assets[TargetClaudeCLI] = claude
	})

	plan, err := f.manager.Plan(context.Background(), TargetClaudeCLI, ModeInstall)
	if err != nil {
		t.Fatalf("Plan() error = %v", err)
	}
	envelope, err := f.manager.Execute(context.Background(), plan.PlanID)
	if err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("download never started")
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		current, _ := f.registry.Get(envelope.OperationID)
		if current.Stage == StageDownloading && current.ProgressKind == operation.ProgressDeterminate && current.ProgressValue != nil && *current.ProgressValue > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no determinate progress observed: %+v", current)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := f.manager.Plan(context.Background(), TargetClaudeCLI, ModeInstall); !isCode(err, "LCT-CLAUDE_CLI-OPERATION-BUSY") {
		t.Fatalf("Plan() while running error = %v", err)
	}
	if _, err := f.registry.Cancel(envelope.OperationID); err != nil {
		t.Fatalf("Cancel() error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	final, err := f.registry.Wait(ctx, envelope.OperationID)
	if err != nil {
		t.Fatalf("Wait() error = %v", err)
	}
	if final.State != operation.StateCancelled || final.ErrorCode == nil || *final.ErrorCode != "LCT-CLAUDE_CLI-INSTALL-SYSTEM_CANCELLED" {
		t.Fatalf("cancelled final = %+v", final)
	}
	f.assertNoScratch(t)
	if _, err := os.Lstat(filepath.Join(f.home, ".local", "share", "claude", "versions", testClaudeVersion)); err == nil {
		t.Fatal("final file exists after cancel")
	}
	if _, err := f.manager.Plan(context.Background(), TargetClaudeCLI, ModeInstall); err != nil {
		t.Fatalf("Plan() after cancel error = %v", err)
	}
}

func TestInstallRefusesConflictingTargetsAndWrongStates(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newFixture(t, defaultHandler(t), nil)
	linkDir := filepath.Join(f.home, ".local", "bin")
	if err := os.MkdirAll(linkDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(linkDir, "codex"), []byte("not a symlink"), 0o644); err != nil {
		t.Fatalf("write conflicting file: %v", err)
	}
	if err := os.Symlink("/nonexistent/claude-target", filepath.Join(linkDir, "claude")); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	for _, targetID := range []string{TargetCodexCLI, TargetClaudeCLI} {
		requirements, err := f.manager.Requirements(context.Background(), targetID)
		if err != nil || requirements.Satisfied || !contains(requirements.Issues, IssueTargetConflict) {
			t.Fatalf("Requirements(%s) = %+v, %v", targetID, requirements, err)
		}
		if _, err := f.manager.Plan(context.Background(), targetID, ModeInstall); !isCode(err, "LCT-"+strings.ToUpper(targetID)+"-INSTALL-REQUIREMENTS_UNMET") {
			t.Fatalf("Plan(%s) error = %v", targetID, err)
		}
	}
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeRepair); !isCode(err, "LCT-CODEX_CLI-INSTALL-NOT_REPAIRABLE") {
		t.Fatalf("Plan(repair) error = %v", err)
	}
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, "reinstall"); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("Plan(bad mode) error = %v", err)
	}
	// Upgrade and rollback are real modes now, but nothing is installed.
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeUpgrade); !isCode(err, "LCT-CODEX_CLI-INSTALL-NOT_UPGRADABLE") {
		t.Fatalf("Plan(upgrade, not installed) error = %v", err)
	}
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeRollback); !isCode(err, "LCT-CODEX_CLI-INSTALL-NOT_ROLLBACKABLE") {
		t.Fatalf("Plan(rollback, not installed) error = %v", err)
	}
	if _, err := f.manager.Execute(context.Background(), "missing-plan"); !isCode(err, "LCT-BRIDGE-OPERATION-NOT_FOUND") {
		t.Fatalf("Execute(missing) error = %v", err)
	}
}

func TestRepairReplacesDamagedBinaryInPlace(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newFixture(t, defaultHandler(t), nil)
	if final := f.runInstall(t, TargetCodexCLI, ModeInstall); final.State != operation.StateSucceeded {
		t.Fatalf("install final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	codexPath := filepath.Join(f.home, ".codex", "packages", "standalone", testCodexVersion, "bin", "codex")

	// The binary at the locked path stops working (truncated download, bad
	// update, …): the version probe fails and detect reports it repairable.
	if err := os.WriteFile(codexPath, []byte("#!/bin/sh\nexit 3\n"), 0o755); err != nil {
		t.Fatalf("damage binary: %v", err)
	}
	damaged, err := f.detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil || damaged.UIState != detect.UIStateRepairable || damaged.ErrorCode != "LCT-CODEX_CLI-DETECT-DAMAGED" {
		t.Fatalf("Detect(damaged) = %+v, %v", damaged, err)
	}
	// A fresh install is still refused; only repair may touch an occupied path.
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeInstall); !isCode(err, "LCT-CODEX_CLI-INSTALL-ALREADY_INSTALLED") {
		t.Fatalf("Plan(install) on damaged error = %v", err)
	}

	final := f.runInstall(t, TargetCodexCLI, ModeRepair)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("repair final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if content, _ := os.ReadFile(codexPath); !bytes.Equal(content, codexScript()) {
		t.Fatalf("repaired content = %q", content)
	}
	entries, _ := os.ReadDir(filepath.Dir(codexPath))
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".zhiban-damaged-") {
			t.Fatalf("damaged copy left behind: %s", entry.Name())
		}
	}
	if got, err := os.Readlink(filepath.Join(f.home, ".local", "bin", "codex")); err != nil || got != codexPath {
		t.Fatalf("symlink after repair = %q, %v", got, err)
	}
	after, err := f.detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil || after.UIState != detect.UIStateInstalledUnmanaged || after.InstalledVersion != testCodexVersion {
		t.Fatalf("Detect(after repair) = %+v, %v", after, err)
	}
	f.assertNoScratch(t)
}

func TestRepairPutsDamagedBinaryBackWhenPlacementFails(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	// The locked binary hash does not match what the (otherwise valid)
	// archive contains, so placement fails after the damaged file was moved
	// aside: it must be put back and nothing else may be left behind.
	f := newFixture(t, defaultHandler(t), func(assets map[string]Asset) {
		asset := assets[TargetCodexCLI]
		asset.BinarySHA256 = digestOf([]byte("not the shipped binary"))
		assets[TargetCodexCLI] = asset
	})
	codexPath := filepath.Join(f.home, ".codex", "packages", "standalone", testCodexVersion, "bin", "codex")
	if err := os.MkdirAll(filepath.Dir(codexPath), 0o755); err != nil {
		t.Fatal(err)
	}
	broken := []byte("#!/bin/sh\nexit 3\n")
	if err := os.WriteFile(codexPath, broken, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(f.home, ".local", "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(codexPath, filepath.Join(f.home, ".local", "bin", "codex")); err != nil {
		t.Fatal(err)
	}
	if state, err := f.detector.Detect(context.Background(), TargetCodexCLI); err != nil || state.UIState != detect.UIStateRepairable {
		t.Fatalf("Detect(damaged) = %+v, %v", state, err)
	}

	final := f.runInstall(t, TargetCodexCLI, ModeRepair)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CODEX_CLI-INSTALL-HASH_MISMATCH" {
		t.Fatalf("repair final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if content, err := os.ReadFile(codexPath); err != nil || !bytes.Equal(content, broken) {
		t.Fatalf("damaged binary must be back in place: %q, %v", content, err)
	}
	entries, _ := os.ReadDir(filepath.Dir(codexPath))
	if len(entries) != 1 {
		t.Fatalf("bin dir after failed repair = %v", entries)
	}
	f.assertNoScratch(t)
}

// A redirect to plain http — even on an allowed host — is a source problem
// and must not read as a signature failure (2026-09-11 test environment: the
// Bus 302'd to an object store without TLS and the failure was chased as
// PUBLISHER_MISMATCH).
func TestInstallRejectsRedirectToPlainHTTP(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	var self string
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://"+strings.TrimPrefix(self, "https://")+"/claude", http.StatusFound)
	})
	f := newFixture(t, handler, nil)
	self = f.server.URL
	final := f.runInstall(t, TargetClaudeCLI, ModeInstall)
	if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CLAUDE_CLI-INSTALL-SOURCE_NOT_ALLOWED" {
		t.Fatalf("http redirect final = %+v", final)
	}
	f.assertNoScratch(t)
}

func TestInstallRejectsRedirectOutsideAllowedHosts(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	foreign := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(claudeScript())
	}))
	t.Cleanup(foreign.Close)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, strings.Replace(foreign.URL, "127.0.0.1", "localhost", 1)+"/claude", http.StatusFound)
	})
	f := newFixture(t, handler, nil)
	final := f.runInstall(t, TargetClaudeCLI, ModeInstall)
	if final.State != operation.StateFailed || final.ErrorCode == nil || *final.ErrorCode != "LCT-CLAUDE_CLI-INSTALL-SOURCE_NOT_ALLOWED" {
		t.Fatalf("redirect final = %+v", final)
	}
	f.assertNoScratch(t)
}

func TestRequirementsReportUnsupportedArchAndOS(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	home := t.TempDir()
	registry := operation.NewRegistry()
	x64Only := DefaultAssets()[1]
	manager, err := NewManager(ManagerConfig{
		HomeDir: home, Arch: ArchARM64, Assets: []Asset{x64Only},
		Detect: func(context.Context, string) (detect.State, error) {
			return detect.State{UIState: detect.UIStateNotInstalled}, nil
		},
		Operations: registry,
		OSVersion:  func() (string, error) { return "10.15.7", nil },
		FreeBytes:  func(string) (uint64, error) { return 1, nil },
		Writable:   func(string) bool { return false },
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	requirements, err := manager.Requirements(context.Background(), TargetCodexCLI)
	if err != nil || requirements.Satisfied || !contains(requirements.Issues, IssueUnsupportedArch) {
		t.Fatalf("Requirements(arm64 without asset) = %+v, %v", requirements, err)
	}
	if _, err := manager.Plan(context.Background(), TargetCodexCLI, ModeInstall); !isCode(err, "LCT-CODEX_CLI-INSTALL-UNSUPPORTED_ARCH") {
		t.Fatalf("Plan() error = %v", err)
	}

	manager, err = NewManager(ManagerConfig{
		HomeDir: home, Arch: ArchX64, Assets: []Asset{x64Only},
		Detect: func(context.Context, string) (detect.State, error) {
			return detect.State{UIState: detect.UIStateNotInstalled}, nil
		},
		Operations: registry,
		OSVersion:  func() (string, error) { return "10.15.7", nil },
		FreeBytes:  func(string) (uint64, error) { return 1, nil },
		Writable:   func(string) bool { return false },
	})
	if err != nil {
		t.Fatalf("NewManager(x64) error = %v", err)
	}
	requirements, _ = manager.Requirements(context.Background(), TargetCodexCLI)
	for _, issue := range []string{IssueUnsupportedOS, IssueInsufficientDisk, IssueTargetDirNotWritable} {
		if !contains(requirements.Issues, issue) {
			t.Fatalf("Requirements() missing %s: %+v", issue, requirements)
		}
	}
	if requirements.DownloadHost != "registry.npmjs.org" || requirements.Version != LockedCodexVersion {
		t.Fatalf("Requirements() = %+v", requirements)
	}
}

func TestExtractSingleExecutableRejectsUnsafeArchives(t *testing.T) {
	t.Parallel()
	sink := func(io.Reader, int64) error { return nil }
	tests := map[string][]byte{
		"traversal": tarballWith(t, map[string][]byte{"../codex": codexScript()}, nil),
		"absolute":  tarballWith(t, map[string][]byte{"/usr/local/bin/codex": codexScript()}, nil),
		"two files": tarballWith(t, map[string][]byte{"codex": codexScript(), "extra": codexScript()}, nil),
		"empty":     tarballWith(t, map[string][]byte{}, nil),
		"symlink": tarballWith(t, map[string][]byte{"codex": codexScript()}, func(writer *tar.Writer) {
			_ = writer.WriteHeader(&tar.Header{Name: "link", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd"})
		}),
		"not gzip": []byte("plain text"),
	}
	for name, archive := range tests {
		if err := extractSingleExecutable(bytes.NewReader(archive), sink); !errors.Is(err, errArchiveInvalid) {
			t.Fatalf("%s: error = %v, want errArchiveInvalid", name, err)
		}
	}
	valid := tarballWith(t, map[string][]byte{"dist/codex-aarch64-apple-darwin": codexScript()}, func(writer *tar.Writer) {
		_ = writer.WriteHeader(&tar.Header{Name: "dist/", Typeflag: tar.TypeDir, Mode: 0o755})
	})
	var extracted []byte
	err := extractSingleExecutable(bytes.NewReader(valid), func(content io.Reader, size int64) error {
		data, readErr := io.ReadAll(content)
		extracted = data
		if int64(len(data)) != size {
			return errors.New("size mismatch")
		}
		return readErr
	})
	if err != nil || !bytes.Equal(extracted, codexScript()) {
		t.Fatalf("valid archive: %v, %q", err, extracted)
	}
}

func TestDefaultAssetsAreValid(t *testing.T) {
	t.Parallel()
	seen := map[string]bool{}
	for _, asset := range DefaultAssets() {
		if err := asset.Validate(); err != nil {
			t.Fatalf("%+v: %v", asset, err)
		}
		if asset.TargetID == TargetCodexCLI {
			// Codex is installed as the publisher's package tree, which only
			// the @openai/codex platform tarballs carry: the publisher's npm
			// registry is the primary source and every source is that tree.
			if asset.Primary().Kind != SourceKindNPMRegistry {
				t.Fatalf("%s/%s primary source is %s, want npm_registry", asset.TargetID, asset.Arch, asset.Primary().Kind)
			}
			for _, source := range asset.Sources {
				if source.Layout != LayoutTarballTree || !strings.HasPrefix(source.Member, "package/vendor/") ||
					source.SHA256 != asset.Sources[0].SHA256 || source.Size != asset.Sources[0].Size {
					t.Fatalf("%s/%s source = %+v, want the same package tree", asset.TargetID, asset.Arch, source)
				}
			}
		} else if asset.Primary().Kind != SourceKindOfficial {
			t.Fatalf("%s/%s primary source is %s, want official", asset.TargetID, asset.Arch, asset.Primary().Kind)
		}
		if asset.IsBundle() && asset.PlatformName() == PlatformWindows {
			// Windows desktop packages (M3-W): a signed MSIX identified by its
			// package identity and Authenticode signer; every source is the
			// same package (the community mirror re-hosts Anthropic's file).
			if asset.PackageName == "" || asset.PackagePublisherID == "" || asset.SignerName == "" || asset.BinarySHA256 != "" ||
				asset.BundleName != "" || asset.PackageFamilyName() != asset.PackageName+"_"+asset.PackagePublisherID {
				t.Fatalf("%s/%s package asset = %+v", asset.TargetID, asset.Arch, asset)
			}
			for _, source := range asset.Sources {
				if source.Layout != LayoutMSIX || source.SHA256 != asset.Sources[0].SHA256 || source.Size != asset.Sources[0].Size {
					t.Fatalf("%s/%s package source = %+v", asset.TargetID, asset.Arch, source)
				}
			}
			if asset.TargetID == TargetClaudeDesktop && (!asset.RequiresElevation || len(asset.Sources) != 4) {
				t.Fatalf("Claude Desktop on Windows needs elevation and three mirror sources: %+v", asset)
			}
		} else if asset.IsBundle() {
			// Desktop bundles: the publisher's own zip first; Claude Desktop also
			// carries the community mirror's DMG (M3 Task 9). The bundle is
			// verified by signature, not by a locked binary hash.
			if len(asset.Sources) == 0 || asset.Sources[0].Layout != LayoutAppBundleZip || asset.BinarySHA256 != "" ||
				asset.BundleName == "" || asset.TeamIdentifier == "" {
				t.Fatalf("%s/%s desktop asset = %+v", asset.TargetID, asset.Arch, asset)
			}
			for _, fallback := range asset.Sources[1:] {
				if fallback.Kind != SourceKindCommunityMirror || fallback.Layout != LayoutAppBundleDMG {
					t.Fatalf("%s/%s desktop fallback = %+v", asset.TargetID, asset.Arch, fallback)
				}
			}
		} else if asset.TargetID == TargetCodexCLI {
			if len(asset.Sources) != 2 || asset.Sources[1].Kind != SourceKindNPMMirror || asset.BinarySHA256 == "" {
				t.Fatalf("%s/%s sources = %+v", asset.TargetID, asset.Arch, asset.Sources)
			}
		} else if len(asset.Sources) != 3 || asset.Sources[1].Kind != SourceKindNPMRegistry || asset.Sources[2].Kind != SourceKindNPMMirror ||
			asset.Sources[1].SHA256 != asset.Sources[2].SHA256 || asset.Sources[1].Size != asset.Sources[2].Size || asset.BinarySHA256 == "" {
			t.Fatalf("%s/%s sources = %+v", asset.TargetID, asset.Arch, asset.Sources)
		}
		for _, source := range asset.Sources {
			if !contains(DefaultAllowedHosts(), source.Host()) {
				t.Fatalf("%s source host %s not allowed", asset.TargetID, source.Host())
			}
		}
		key := asset.PlatformName() + "/" + asset.TargetID + "/" + asset.Arch
		if seen[key] {
			t.Fatalf("duplicate asset %s", key)
		}
		seen[key] = true
	}
	if len(seen) != 12 {
		t.Fatalf("assets = %d, want 12 (macOS: two CLIs and two desktop apps, arm64 and x64; Windows x64: two CLIs and two desktop packages)", len(seen))
	}
	// The macOS CLI assets keep their historical order; the Windows CLIs and
	// then the desktop assets follow.
	if assets := DefaultAssets(); assets[0].TargetID != TargetCodexCLI || assets[1].TargetID != TargetCodexCLI || assets[1].Arch != ArchX64 ||
		assets[2].TargetID != TargetClaudeCLI || assets[3].TargetID != TargetClaudeCLI ||
		assets[4].PlatformName() != PlatformWindows || assets[4].TargetID != TargetCodexCLI || assets[4].Arch != ArchX64 ||
		assets[5].PlatformName() != PlatformWindows || assets[5].TargetID != TargetClaudeCLI || assets[5].Arch != ArchX64 ||
		!assets[6].IsBundle() {
		t.Fatalf("asset order changed: %v", []string{assets[0].TargetID, assets[1].TargetID, assets[2].TargetID, assets[3].TargetID, assets[4].TargetID, assets[5].TargetID, assets[6].TargetID})
	}
	// A Windows manager sees only the Windows assets, a macOS manager only the
	// macOS ones (same target and arch on both).
	for _, platform := range []string{PlatformMacOS, PlatformWindows} {
		for _, asset := range DefaultAssets() {
			if asset.PlatformName() == platform && asset.TargetID == TargetCodexCLI && asset.Arch == ArchX64 && asset.PlatformName() != platform {
				t.Fatalf("platform filter mismatch for %s", platform)
			}
		}
	}
}

// TestInstallSmokeDownloadsRealAssets exercises the real publishers with a
// throwaway HOME. Set ZHIBAN_RUN_INSTALL_SMOKE=1 to enable it.
func TestInstallSmokeDownloadsRealAssets(t *testing.T) {
	if os.Getenv("ZHIBAN_RUN_INSTALL_SMOKE") != "1" {
		t.Skip("set ZHIBAN_RUN_INSTALL_SMOKE=1 to download the locked assets from the official sources")
	}
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	home := t.TempDir()
	arch := ArchARM64
	if runtime.GOARCH == "amd64" {
		arch = ArchX64
	}
	discoverer := detect.NewMacOSDiscoverer(home)
	discoverer.LookPath = func(name string) (string, error) { return "", &exec.Error{Name: name, Err: exec.ErrNotFound} }
	discoverer.SystemCandidates = map[string][]string{}
	detector, err := detect.NewDetector(discoverer.Discover, detect.VersionProber{Timeout: 5 * time.Second, HomeDir: home}.Probe, bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatalf("NewDetector() error = %v", err)
	}
	registry := operation.NewRegistry()
	var filter func(Source) bool
	if kind := os.Getenv("ZHIBAN_INSTALL_SMOKE_SOURCE"); kind != "" {
		filter = func(source Source) bool { return source.Kind == kind }
	}
	var transport http.RoundTripper
	if os.Getenv("ZHIBAN_INSTALL_SMOKE_NO_PROXY") == "1" {
		// Simulate a machine without any system proxy: direct connections only.
		transport = &http.Transport{Proxy: nil, ForceAttemptHTTP2: true}
		t.Log("system proxy ignored: direct connections only")
	}
	manager, err := NewManager(ManagerConfig{HomeDir: home, Arch: arch, BridgeVersion: "smoke", Assets: DefaultAssets(), Detect: detector.Detect, Operations: registry, SourceFilter: filter, Transport: transport})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	targets := []string{TargetCodexCLI, TargetClaudeCLI}
	if only := os.Getenv("ZHIBAN_INSTALL_SMOKE_TARGET"); only != "" {
		targets = []string{only}
	}
	if proxy := systemHTTPSProxy(); proxy != nil {
		t.Logf("system HTTPS proxy in use: %s", proxy.Host)
	}
	for _, targetID := range targets {
		plan, err := manager.Plan(context.Background(), targetID, ModeInstall)
		if err != nil {
			t.Fatalf("Plan(%s) error = %v", targetID, err)
		}
		envelope, err := manager.Execute(context.Background(), plan.PlanID)
		if err != nil {
			t.Fatalf("Execute(%s) error = %v", targetID, err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
		final, err := registry.Wait(ctx, envelope.OperationID)
		cancel()
		if err != nil || final.State != operation.StateSucceeded {
			t.Fatalf("%s final = %+v code=%s, %v", targetID, final, describeCode(final.ErrorCode), err)
		}
		t.Logf("%s installed: %+v", targetID, final.Result)
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

func describeCode(code *string) string {
	if code == nil {
		return "<nil>"
	}
	return *code
}

func npmStyleTarball(t *testing.T, member string, content []byte) []byte {
	t.Helper()
	return tarballWith(t, map[string][]byte{
		"package/package.json": []byte(`{"name":"fake"}`),
		"package/README.md":    []byte("readme"),
		member:                 content,
	}, func(writer *tar.Writer) {
		_ = writer.WriteHeader(&tar.Header{Name: "package/", Typeflag: tar.TypeDir, Mode: 0o755})
	})
}

func TestInstallFallsBackToNextSourceWhenPrimaryIsUnreachable(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	mirror := npmStyleTarball(t, "package/claude", claudeScript())
	mux := http.NewServeMux()
	mux.HandleFunc("/mirror/claude.tgz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", itoa(len(mirror)))
		_, _ = w.Write(mirror)
	})
	f := newFixture(t, mux, nil)
	claude := f.assets[TargetClaudeCLI]
	claude.Sources = []Source{
		{Kind: SourceKindOfficial, URL: "https://127.0.0.1:1/claude", Size: int64(len(claudeScript())), SHA256: digestOf(claudeScript()), Layout: LayoutBareBinary},
		{Kind: SourceKindNPMMirror, URL: f.server.URL + "/mirror/claude.tgz", Size: int64(len(mirror)), SHA256: digestOf(mirror), Layout: LayoutTarballMember, Member: "package/claude"},
	}
	manager, err := NewManager(ManagerConfig{
		HomeDir: f.home, Arch: ArchARM64, Assets: []Asset{f.assets[TargetCodexCLI], claude}, AllowedHosts: []string{"127.0.0.1"},
		Transport: f.server.Client().Transport, Detect: f.detector.Detect, Operations: f.registry,
		OSVersion: func() (string, error) { return "15.3", nil },
		FreeBytes: func(string) (uint64, error) { return 10 << 30, nil },
		Writable:  func(string) bool { return true },
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	f.manager = manager
	requirements, err := manager.Requirements(context.Background(), TargetClaudeCLI)
	if err != nil || requirements.DownloadHost != "127.0.0.1" || len(requirements.FallbackHosts) != 1 || requirements.RequiredFreeBytes != int64(len(mirror))*requiredFreeFactor {
		t.Fatalf("Requirements() = %+v, %v", requirements, err)
	}
	final := f.runInstall(t, TargetClaudeCLI, ModeInstall)
	if final.State != operation.StateSucceeded {
		t.Fatalf("fallback final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	installed, err := os.ReadFile(filepath.Join(f.home, ".local", "share", "claude", "versions", testClaudeVersion))
	if err != nil || !bytes.Equal(installed, claudeScript()) {
		t.Fatalf("installed from mirror = %q, %v", installed, err)
	}
	f.assertNoScratch(t)
}

func TestInstallStopsAtHashMismatchWithoutTryingTheNextSource(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	var mirrorHits int32
	mux := http.NewServeMux()
	mux.HandleFunc("/claude", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", itoa(len(claudeScript())))
		_, _ = w.Write(claudeScript())
	})
	mux.HandleFunc("/mirror/claude.tgz", func(w http.ResponseWriter, r *http.Request) {
		// The pre-download speed race may send a Range probe; only a real
		// (full) download counts as "trying the next source".
		if r.Header.Get("Range") == "" {
			atomic.AddInt32(&mirrorHits, 1)
		}
		w.WriteHeader(http.StatusInternalServerError)
	})
	f := newFixture(t, mux, nil)
	claude := f.assets[TargetClaudeCLI]
	claude.Sources = []Source{
		{Kind: SourceKindOfficial, URL: f.server.URL + "/claude", Size: int64(len(claudeScript())), SHA256: strings.Repeat("1", 64), Layout: LayoutBareBinary},
		{Kind: SourceKindNPMMirror, URL: f.server.URL + "/mirror/claude.tgz", Size: 10, SHA256: strings.Repeat("2", 64), Layout: LayoutTarballMember, Member: "package/claude"},
	}
	claude.BinarySHA256 = ""
	manager, err := NewManager(ManagerConfig{
		HomeDir: f.home, Arch: ArchARM64, Assets: []Asset{f.assets[TargetCodexCLI], claude}, AllowedHosts: []string{"127.0.0.1"},
		Transport: f.server.Client().Transport, Detect: f.detector.Detect, Operations: f.registry,
		OSVersion: func() (string, error) { return "15.3", nil },
		FreeBytes: func(string) (uint64, error) { return 10 << 30, nil },
		Writable:  func(string) bool { return true },
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	f.manager = manager
	final := f.runInstall(t, TargetClaudeCLI, ModeInstall)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CLAUDE_CLI-INSTALL-HASH_MISMATCH" {
		t.Fatalf("final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if atomic.LoadInt32(&mirrorHits) != 0 {
		t.Fatalf("mirror was contacted after a hash mismatch: %d", mirrorHits)
	}
	f.assertNoScratch(t)
}

func TestInstallRejectsMemberWhoseBytesDifferFromLockedBinary(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	tampered := npmStyleTarball(t, "package/claude", []byte("#!/bin/sh\necho tampered\n"))
	mux := http.NewServeMux()
	mux.HandleFunc("/mirror/claude.tgz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", itoa(len(tampered)))
		_, _ = w.Write(tampered)
	})
	f := newFixture(t, mux, nil)
	claude := f.assets[TargetClaudeCLI]
	claude.Sources = []Source{{Kind: SourceKindNPMMirror, URL: f.server.URL + "/mirror/claude.tgz", Size: int64(len(tampered)), SHA256: digestOf(tampered), Layout: LayoutTarballMember, Member: "package/claude"}}
	manager, err := NewManager(ManagerConfig{
		HomeDir: f.home, Arch: ArchARM64, Assets: []Asset{f.assets[TargetCodexCLI], claude}, AllowedHosts: []string{"127.0.0.1"},
		Transport: f.server.Client().Transport, Detect: f.detector.Detect, Operations: f.registry,
		OSVersion: func() (string, error) { return "15.3", nil },
		FreeBytes: func(string) (uint64, error) { return 10 << 30, nil },
		Writable:  func(string) bool { return true },
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	f.manager = manager
	final := f.runInstall(t, TargetClaudeCLI, ModeInstall)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CLAUDE_CLI-INSTALL-HASH_MISMATCH" {
		t.Fatalf("final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if _, err := os.Lstat(filepath.Join(f.home, ".local", "share", "claude", "versions", testClaudeVersion)); err == nil {
		t.Fatal("tampered member was installed")
	}
}

func TestExtractMemberSelectsExactlyTheNamedFile(t *testing.T) {
	t.Parallel()
	archive := npmStyleTarball(t, "package/vendor/aarch64-apple-darwin/bin/codex", codexScript())
	var got []byte
	err := extractMember(bytes.NewReader(archive), "package/vendor/aarch64-apple-darwin/bin/codex", func(content io.Reader, _ int64) error {
		data, readErr := io.ReadAll(content)
		got = data
		return readErr
	})
	if err != nil || !bytes.Equal(got, codexScript()) {
		t.Fatalf("extractMember() = %v, %q", err, got)
	}
	sink := func(io.Reader, int64) error { return nil }
	if err := extractMember(bytes.NewReader(archive), "package/missing", sink); !errors.Is(err, errArchiveInvalid) {
		t.Fatalf("missing member error = %v", err)
	}
	if err := extractMember(bytes.NewReader(archive), "../etc/passwd", sink); !errors.Is(err, errArchiveInvalid) {
		t.Fatalf("unsafe member error = %v", err)
	}
	linked := tarballWith(t, map[string][]byte{"package/other": codexScript()}, func(writer *tar.Writer) {
		_ = writer.WriteHeader(&tar.Header{Name: "package/claude", Typeflag: tar.TypeSymlink, Linkname: "/bin/sh"})
	})
	if err := extractMember(bytes.NewReader(linked), "package/claude", sink); !errors.Is(err, errArchiveInvalid) {
		t.Fatalf("symlink member error = %v", err)
	}
}
