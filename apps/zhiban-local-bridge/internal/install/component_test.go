package install

import (
	"archive/tar"
	"bytes"
	"context"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const testHostVersion = "2.1.260"

func fakeHostMachO() []byte {
	return append([]byte{0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01}, bytes.Repeat([]byte{0x42}, 256)...)
}

// fakeHostArchive is a claude.app.tar.zst with the real layout.
func fakeHostArchive(t *testing.T) []byte {
	t.Helper()
	var tarBuffer bytes.Buffer
	writer := tar.NewWriter(&tarBuffer)
	add := func(name string, mode int64, content []byte) {
		header := &tar.Header{Name: name, Mode: mode, Typeflag: tar.TypeDir}
		if content != nil {
			header.Typeflag = tar.TypeReg
			header.Size = int64(len(content))
		}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if content != nil {
			if _, err := writer.Write(content); err != nil {
				t.Fatal(err)
			}
		}
	}
	add("claude.app/", 0o755, nil)
	add("claude.app/Contents/", 0o755, nil)
	add("claude.app/Contents/Info.plist", 0o644, []byte("<plist/>"))
	add("claude.app/Contents/_CodeSignature/", 0o755, nil)
	add("claude.app/Contents/_CodeSignature/CodeResources", 0o644, []byte("<seal/>"))
	add("claude.app/Contents/MacOS/", 0o755, nil)
	add("claude.app/Contents/MacOS/claude", 0o755, fakeHostMachO())
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	var zstBuffer bytes.Buffer
	encoder, err := zstd.NewWriter(&zstBuffer)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := encoder.Write(tarBuffer.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := encoder.Close(); err != nil {
		t.Fatal(err)
	}
	return zstBuffer.Bytes()
}

// newComponentFixture installs Claude Desktop from the fake zip and points the
// pinned host manifest at archive served by the fixture's TLS server.
func newComponentFixture(t *testing.T, archive []byte, checksum string) *fixture {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/claude-desktop.zip", func(w http.ResponseWriter, _ *http.Request) {
		zipped := fakeBundleZip(t)
		w.Header().Set("Content-Length", itoa(len(zipped)))
		_, _ = w.Write(zipped)
	})
	mux.HandleFunc("/host/"+testHostVersion+"/darwin-arm64/claude.app.tar.zst", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", itoa(len(archive)))
		_, _ = w.Write(archive)
	})
	zipped := fakeBundleZip(t)
	f := newFixture(t, mux, func(assets map[string]Asset) {
		base := strings.TrimSuffix(assets[TargetCodexCLI].Sources[0].URL, "/codex.tar.gz")
		assets[TargetClaudeDesktop] = Asset{
			TargetID: TargetClaudeDesktop, Arch: ArchARM64, Version: testDesktopVersion, Source: SourceOfficialAnthropic,
			BundleName: testDesktopBundle, BundleIdentifier: testDesktopID, TeamIdentifier: testDesktopTeam,
			Sources: []Source{{Kind: SourceKindOfficial, URL: base + "/claude-desktop.zip", Size: int64(len(zipped)), SHA256: digestOf(zipped), Layout: LayoutAppBundleZip}},
		}
	})
	if final := f.runInstall(t, TargetClaudeDesktop, ModeInstall); final.State != operation.StateSucceeded {
		t.Fatalf("install Claude Desktop final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if checksum == "" {
		checksum = digestOf(archive)
	}
	f.hostManifest = &claudecode.Manifest{
		Version: testHostVersion, BaseURL: f.server.URL + "/host",
		Platforms: map[string]claudecode.Platform{
			"darwin-arm64": {Binary: "claude.zst", Checksum: digestOf(archive), Size: 1,
				Bundle: &claudecode.Artifact{Checksum: checksum, Size: int64(len(archive))}},
		},
	}
	return f
}

func (f *fixture) runComponent(t *testing.T) operation.Envelope {
	t.Helper()
	plan, err := f.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID)
	if err != nil {
		t.Fatalf("PlanComponent() error = %v", err)
	}
	if plan.Mode != ModeComponent || plan.Component != claudecode.ComponentID || plan.Version != testHostVersion ||
		plan.TargetID != TargetClaudeDesktop || plan.DownloadHost != "127.0.0.1" || plan.Source != SourceOfficialAnthropic {
		t.Fatalf("component plan = %+v", plan)
	}
	envelope, err := f.manager.Execute(context.Background(), plan.PlanID)
	if err != nil {
		t.Fatalf("Execute(component) error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	final, err := f.registry.Wait(ctx, envelope.OperationID)
	if err != nil {
		t.Fatalf("Wait() error = %v", err)
	}
	return final
}

func TestComponentInstallProvisionsClaudeCodeHostBundle(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	archive := fakeHostArchive(t)
	f := newComponentFixture(t, archive, "")

	before, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || len(before.Components) != 1 || before.Components[0].State != claudecode.StateMissing {
		t.Fatalf("Detect() before = %+v, %v", before, err)
	}

	final := f.runComponent(t)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("component final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	result, ok := final.Result.(Result)
	if !ok || len(result.ToolState.Components) != 1 || result.ToolState.Components[0].State != claudecode.StatePresent ||
		result.ToolState.Components[0].Version != testHostVersion {
		t.Fatalf("component result = %#v", final.Result)
	}
	binary := claudecode.BinaryPath(f.home, testHostVersion)
	if info, err := os.Stat(binary); err != nil || info.Mode().Perm()&0o111 == 0 || !claudecode.IsExecutableMachO(binary) {
		t.Fatalf("host binary = %v, %v", info, err)
	}
	marker, err := os.ReadFile(claudecode.VerifiedPath(f.home, testHostVersion))
	if err != nil || string(marker) != digestOf(archive) {
		t.Fatalf(".verified = %q, %v", marker, err)
	}
	if hidden := hiddenEntries(t, claudecode.StorageDir(f.home)); len(hidden) != 0 {
		t.Fatalf("staging left behind: %v", hidden)
	}
	if hidden := hiddenEntries(t, claudecode.VersionDir(f.home, testHostVersion)); len(hidden) != 0 {
		t.Fatalf("version dir scratch left behind: %v", hidden)
	}
	f.assertNoScratch(t)

	// Present → nothing more to plan.
	if _, err := f.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-ALREADY_INSTALLED") {
		t.Fatalf("PlanComponent() after install error = %v", err)
	}

	// A stale marker (e.g. Claude Desktop upgraded its pin) is replaced, but
	// never while the application is running.
	if err := os.WriteFile(claudecode.VerifiedPath(f.home, testHostVersion), []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.inUse.Store(true)
	if _, err := f.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-TARGET_IN_USE") {
		t.Fatalf("PlanComponent() while running error = %v", err)
	}
	f.inUse.Store(false)
	// Not being able to tell is refused too, but under its own name.
	f.inUseCheckBroken.Store(true)
	if _, err := f.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-RUNNING_CHECK_FAILED") {
		t.Fatalf("PlanComponent() with a broken check error = %v", err)
	}
	f.inUseCheckBroken.Store(false)
	if final := f.runComponent(t); final.State != operation.StateSucceeded {
		t.Fatalf("stale replacement final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	marker, err = os.ReadFile(claudecode.VerifiedPath(f.home, testHostVersion))
	if err != nil || string(marker) != digestOf(archive) {
		t.Fatalf(".verified after replacement = %q, %v", marker, err)
	}
	if hidden := hiddenEntries(t, claudecode.VersionDir(f.home, testHostVersion)); len(hidden) != 0 {
		t.Fatalf("aside bundle left behind: %v", hidden)
	}
}

func TestComponentInstallRejectsBadArchivesAndInputs(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	archive := fakeHostArchive(t)

	// Hash pinned by the manifest does not match what the host serves.
	f := newComponentFixture(t, archive, strings.Repeat("ab", 32))
	if final := f.runComponent(t); envelopeCode(final.ErrorCode) != "LCT-CLAUDE_DESKTOP-INSTALL-HASH_MISMATCH" {
		t.Fatalf("hash mismatch final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if _, err := os.Lstat(claudecode.VersionDir(f.home, testHostVersion)); err == nil {
		t.Fatal("nothing may be placed after a hash mismatch")
	}
	f.assertNoScratch(t)

	// The bytes verify but are not a host bundle archive.
	garbage := []byte("definitely not zstd")
	g := newComponentFixture(t, garbage, "")
	if final := g.runComponent(t); envelopeCode(final.ErrorCode) != "LCT-CLAUDE_DESKTOP-INSTALL-PUBLISHER_MISMATCH" {
		t.Fatalf("garbage archive final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if _, err := os.Lstat(claudecode.VersionDir(g.home, testHostVersion)); err == nil {
		t.Fatal("nothing may be placed after an invalid archive")
	}
	if hidden := hiddenEntries(t, claudecode.StorageDir(g.home)); len(hidden) != 0 {
		t.Fatalf("staging left behind: %v", hidden)
	}

	// Wrong target / component / no manifest / Claude Desktop not installed.
	if _, err := g.manager.PlanComponent(context.Background(), TargetCodexDesktop, claudecode.ComponentID); err != ErrInvalidInput {
		t.Fatalf("PlanComponent(codex_desktop) error = %v", err)
	}
	if _, err := g.manager.PlanComponent(context.Background(), TargetClaudeDesktop, "vm_bundle"); err != ErrInvalidInput {
		t.Fatalf("PlanComponent(unknown component) error = %v", err)
	}
	g.hostManifest = nil
	if _, err := g.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-COMPONENT_MANIFEST_UNREADABLE") {
		t.Fatalf("PlanComponent(no manifest) error = %v", err)
	}
	h := newFixture(t, defaultHandler(t), nil)
	if _, err := h.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID); !isCode(err, "LCT-CLAUDE_DESKTOP-INSTALL-NOT_INSTALLED") {
		t.Fatalf("PlanComponent(not installed) error = %v", err)
	}
	if state, err := h.detector.Detect(context.Background(), TargetClaudeDesktop); err != nil || state.UIState != detect.UIStateNotInstalled {
		t.Fatalf("Detect() = %+v, %v", state, err)
	}
}

func TestHostBundleSourceIsNeverABuildTimeAsset(t *testing.T) {
	t.Parallel()
	asset := DefaultAssets()[0]
	asset.Sources = []Source{{Kind: SourceKindOfficial, Layout: LayoutHostBundleTarZst, URL: "https://downloads.claude.ai/x.tar.zst", Size: 1, SHA256: strings.Repeat("a", 64)}}
	if err := asset.Validate(); err == nil {
		t.Fatal("assets must not carry the host bundle layout")
	}
	source := Source{Kind: SourceKindOfficial, Layout: LayoutHostBundleTarZst, URL: "https://downloads.claude.ai/x.tar.zst", Size: 1, SHA256: strings.Repeat("a", 64)}
	if err := source.Validate(); err != nil {
		t.Fatalf("host bundle source must validate on its own: %v", err)
	}
	filePath := filepath.Join(t.TempDir(), "unused")
	if filePath == "" {
		t.Fatal("unreachable")
	}
}

// envelopeCode unwraps an operation envelope's error code for comparisons.
func envelopeCode(code *string) string {
	if code == nil {
		return ""
	}
	return *code
}
