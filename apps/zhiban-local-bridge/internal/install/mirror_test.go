package install

// M3 Task 9: fallback download sources that are reachable from mainland China
// without a proxy — the community mirror's DMG for Claude Desktop and the
// npmmirror tarball of the Claude Code host executable.

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// unzipBytesInto expands a zip held in memory into destinationDir; it stands
// in for hdiutil+ditto in the DMG tests.
func unzipBytesInto(data []byte, destinationDir string) error {
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return err
	}
	for _, file := range reader.File {
		target := filepath.Join(destinationDir, filepath.FromSlash(file.Name))
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		source, err := file.Open()
		if err != nil {
			return err
		}
		content, err := io.ReadAll(source)
		_ = source.Close()
		if err != nil {
			return err
		}
		if err := os.WriteFile(target, content, file.Mode().Perm()|0o600); err != nil {
			return err
		}
	}
	return nil
}

// fakeNPMTarball is an @anthropic-ai/claude-code-darwin-arm64 tarball with the
// real member layout: package/package.json + package/claude (+ noise).
func fakeNPMTarball(t *testing.T, binary []byte) []byte {
	t.Helper()
	var tarBuffer bytes.Buffer
	writer := tar.NewWriter(&tarBuffer)
	add := func(name string, mode int64, content []byte) {
		header := &tar.Header{Name: name, Mode: mode, Typeflag: tar.TypeReg, Size: int64(len(content))}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(content); err != nil {
			t.Fatal(err)
		}
	}
	add("package/package.json", 0o644, []byte(`{"name":"@anthropic-ai/claude-code-darwin-arm64"}`))
	add("package/README.md", 0o644, []byte("# claude\n"))
	add("package/claude", 0o755, binary)
	add("package/LICENSE.md", 0o644, []byte("MIT-ish\n"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	var gzBuffer bytes.Buffer
	encoder := gzip.NewWriter(&gzBuffer)
	if _, err := encoder.Write(tarBuffer.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := encoder.Close(); err != nil {
		t.Fatal(err)
	}
	return gzBuffer.Bytes()
}

func TestClaudeDesktopFallsBackToCommunityMirrorDMG(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	dmg := []byte("pretend this is a 350 MB disk image\n")
	var officialHits, mirrorHits atomic.Int32
	mux := http.NewServeMux()
	// The official zip host is "unreachable": it never answers 200.
	mux.HandleFunc("/claude-desktop.zip", func(w http.ResponseWriter, _ *http.Request) {
		officialHits.Add(1)
		w.WriteHeader(http.StatusBadGateway)
	})
	mux.HandleFunc("/mirror/Claude-mac-universal.dmg", func(w http.ResponseWriter, _ *http.Request) {
		mirrorHits.Add(1)
		w.Header().Set("Content-Length", itoa(len(dmg)))
		_, _ = w.Write(dmg)
	})
	zipped := fakeBundleZip(t)
	f := newFixture(t, mux, func(assets map[string]Asset) {
		base := strings.TrimSuffix(assets[TargetCodexCLI].Sources[0].URL, "/codex.tar.gz")
		assets[TargetClaudeDesktop] = Asset{
			TargetID: TargetClaudeDesktop, Arch: ArchARM64, Version: testDesktopVersion, Source: SourceOfficialAnthropic,
			BundleName: testDesktopBundle, BundleIdentifier: testDesktopID, TeamIdentifier: testDesktopTeam,
			Sources: []Source{
				{Kind: SourceKindOfficial, URL: base + "/claude-desktop.zip", Size: int64(len(zipped)), SHA256: digestOf(zipped), Layout: LayoutAppBundleZip},
				{Kind: SourceKindCommunityMirror, URL: base + "/mirror/Claude-mac-universal.dmg", Size: int64(len(dmg)), SHA256: digestOf(dmg), Layout: LayoutAppBundleDMG},
			},
		}
	})

	requirements, err := f.manager.Requirements(context.Background(), TargetClaudeDesktop)
	if err != nil || requirements.DownloadHost != "127.0.0.1" || len(requirements.FallbackHosts) != 1 || requirements.FallbackHosts[0] != "127.0.0.1" {
		t.Fatalf("Requirements() = %+v, %v", requirements, err)
	}
	final := f.runInstall(t, TargetClaudeDesktop, ModeInstall)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("install via mirror DMG final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if mirrorHits.Load() == 0 {
		t.Fatalf("mirror was never tried (official hits=%d)", officialHits.Load())
	}
	installed := filepath.Join(f.systemApplications, testDesktopBundle)
	if info, err := os.Lstat(installed); err != nil || !info.IsDir() {
		t.Fatalf("bundle not placed from DMG: %v, %v", info, err)
	}
	if _, err := os.Lstat(filepath.Join(installed, "Contents", "MacOS", "Claude")); err != nil {
		t.Fatalf("bundle executable missing: %v", err)
	}
	if hidden := hiddenEntries(t, f.systemApplications); len(hidden) != 0 {
		t.Fatalf("staging left behind: %v", hidden)
	}
	f.assertNoScratch(t)
}

func TestDefaultAssetsCarryMirrorSources(t *testing.T) {
	t.Parallel()
	desktops := 0
	for _, asset := range DefaultAssets() {
		if asset.TargetID != TargetClaudeDesktop || asset.PlatformName() != PlatformMacOS {
			// The Windows package (MSIX) has its own shape; see
			// TestDefaultAssetsAreValid.
			continue
		}
		desktops++
		if len(asset.Sources) != 4 || asset.Sources[0].Kind != SourceKindOfficial || asset.Sources[0].Layout != LayoutAppBundleZip {
			t.Fatalf("Claude Desktop %s sources = %+v", asset.Arch, asset.Sources)
		}
		for _, mirror := range asset.Sources[1:] {
			if mirror.Kind != SourceKindCommunityMirror || mirror.Layout != LayoutAppBundleDMG ||
				!strings.Contains(mirror.URL, "github.com/Wangnov/claude-app-mirror/releases/download/claude-app-v"+LockedClaudeDesktopVersion+"/Claude-mac-universal.dmg") ||
				mirror.Size != asset.Sources[1].Size || mirror.SHA256 != asset.Sources[1].SHA256 {
				t.Fatalf("Claude Desktop %s mirror source = %+v", asset.Arch, mirror)
			}
			if !contains(DefaultAllowedHosts(), mirror.Host()) {
				t.Fatalf("mirror host %s not allowed", mirror.Host())
			}
		}
		if err := asset.Validate(); err != nil {
			t.Fatalf("Claude Desktop %s asset invalid: %v", asset.Arch, err)
		}
		// Fast GitHub proxies first, the crawling direct link last.
		if hosts := asset.FallbackHosts(); len(hosts) != 3 || hosts[0] != "gh-proxy.com" || hosts[1] != "ghfast.top" || hosts[2] != "github.com" {
			t.Fatalf("Claude Desktop fallback hosts = %v", hosts)
		}
	}
	if desktops != 2 {
		t.Fatalf("expected arm64 and x64 Claude Desktop assets, got %d", desktops)
	}
	// Layout / asset consistency: a DMG only fits a bundle asset; the host
	// layouts never fit a build-time asset.
	cli := DefaultAssets()[0]
	cli.Sources = []Source{{Kind: SourceKindCommunityMirror, Layout: LayoutAppBundleDMG, URL: "https://github.com/x/y.dmg", Size: 1, SHA256: strings.Repeat("a", 64)}}
	if err := cli.Validate(); err == nil {
		t.Fatal("a CLI asset must not carry a DMG source")
	}
	for _, layout := range []string{LayoutHostBundleTarZst, LayoutHostBinaryNPMTgz} {
		desktop := DefaultAssets()[len(DefaultAssets())-1]
		desktop.Sources = []Source{{Kind: SourceKindOfficial, Layout: layout, URL: "https://downloads.claude.ai/x", Size: 1, SHA256: strings.Repeat("a", 64)}}
		if err := desktop.Validate(); err == nil {
			t.Fatalf("assets must not carry the %s layout", layout)
		}
	}
	bad := Source{Kind: "random_site", Layout: LayoutAppBundleDMG, URL: "https://example.com/x.dmg", Size: 1, SHA256: strings.Repeat("a", 64)}
	if err := bad.Validate(); err == nil {
		t.Fatal("unknown source kinds must be rejected")
	}
}
