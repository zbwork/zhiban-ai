package install

import (
	"archive/tar"
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// The Codex CLI is installed as the publisher's package tree (tree.go): a
// bare codex binary makes Codex refuse Code Mode on every session
// (2026-09-10 test machines).

func TestExtractTreeKeepsPathsModesAndRejectsUnsafeEntries(t *testing.T) {
	t.Parallel()
	archive := codexPackageTarball(t, codexScript())
	got := map[string]struct {
		executable bool
		content    []byte
	}{}
	err := extractTree(bytes.NewReader(archive), codexPackagePrefix, func(relative string, executable bool, content io.Reader, size int64) error {
		data, err := io.ReadAll(content)
		if err != nil || int64(len(data)) != size {
			t.Fatalf("read %s: %v (%d of %d bytes)", relative, err, len(data), size)
		}
		got[relative] = struct {
			executable bool
			content    []byte
		}{executable, data}
		return nil
	})
	if err != nil {
		t.Fatalf("extractTree() error = %v", err)
	}
	// package.json sits outside the prefix and is not extracted; the bin
	// directory entry is implied.
	if len(got) != 5 {
		t.Fatalf("extracted %d files, want 5: %v", len(got), got)
	}
	if entry := got["bin/codex"]; !entry.executable || !bytes.Equal(entry.content, codexScript()) {
		t.Fatalf("bin/codex = %+v", entry)
	}
	if entry := got["bin/codex-code-mode-host"]; !entry.executable {
		t.Fatalf("host must keep its executable bit: %+v", entry)
	}
	if entry := got["codex-package.json"]; entry.executable || !strings.Contains(string(entry.content), "layoutVersion") {
		t.Fatalf("codex-package.json = %+v", entry)
	}
	if _, ok := got["codex-resources/marker.txt"]; !ok {
		t.Fatalf("nested resource missing: %v", got)
	}

	unsafe := map[string][]byte{
		"symlink inside the tree": tarballWith(t, map[string][]byte{codexPackagePrefix + "/bin/codex": codexScript()}, func(writer *tar.Writer) {
			_ = writer.WriteHeader(&tar.Header{Name: codexPackagePrefix + "/bin/host", Linkname: "../../../../etc/passwd", Typeflag: tar.TypeSymlink})
		}),
		"hard link inside the tree": tarballWith(t, map[string][]byte{codexPackagePrefix + "/bin/codex": codexScript()}, func(writer *tar.Writer) {
			_ = writer.WriteHeader(&tar.Header{Name: codexPackagePrefix + "/bin/host", Linkname: "bin/codex", Typeflag: tar.TypeLink})
		}),
		"traversal":       tarballWith(t, map[string][]byte{codexPackagePrefix + "/../codex": codexScript()}, nil),
		"nothing in tree": tarballWith(t, map[string][]byte{"package/package.json": []byte("{}")}, nil),
		"not gzip":        []byte("plain"),
	}
	for name, archive := range unsafe {
		err := extractTree(bytes.NewReader(archive), codexPackagePrefix, func(string, bool, io.Reader, int64) error { return nil })
		if err == nil {
			t.Fatalf("%s: extractTree() accepted the archive", name)
		}
	}
	if err := extractTree(bytes.NewReader(codexPackageTarball(t, codexScript())), "../package", func(string, bool, io.Reader, int64) error { return nil }); err == nil {
		t.Fatal("an unsafe prefix must be rejected")
	}
}

func TestInstallPlacesCodexPackageTreeAndRepairsBareBinaryLayout(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newFixture(t, defaultHandler(t), nil)
	versionDir := filepath.Join(f.home, ".codex", "packages", "standalone", testCodexVersion)
	codexPath := filepath.Join(versionDir, "bin", "codex")

	// The Bridge before 2026-09-11 left only bin/codex: detect reports the
	// layout incomplete and repairable, never "running normally".
	if err := os.MkdirAll(filepath.Dir(codexPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(codexPath, codexScript(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(f.home, ".local", "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(codexPath, filepath.Join(f.home, ".local", "bin", "codex")); err != nil {
		t.Fatal(err)
	}
	incomplete, err := f.detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil || incomplete.UIState != detect.UIStateRepairable || incomplete.ErrorCode != "LCT-CODEX_CLI-DETECT-LAYOUT_INCOMPLETE" {
		t.Fatalf("Detect(bare binary) = %+v, %v", incomplete, err)
	}
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeInstall); !isCode(err, "LCT-CODEX_CLI-INSTALL-ALREADY_INSTALLED") {
		t.Fatalf("Plan(install) on incomplete layout error = %v", err)
	}

	// Repair replaces the whole version directory with the package tree.
	final := f.runInstall(t, TargetCodexCLI, ModeRepair)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("repair final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	for relative, wantMode := range map[string]os.FileMode{
		"bin/codex": 0o755, "bin/codex-code-mode-host": 0o755, "codex-path/rg": 0o755,
		"codex-resources/marker.txt": 0o644, "codex-package.json": 0o644,
	} {
		info, err := os.Lstat(filepath.Join(versionDir, filepath.FromSlash(relative)))
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != wantMode {
			t.Fatalf("%s = %v, %v; want regular %o", relative, info, err, wantMode)
		}
	}
	if content, _ := os.ReadFile(codexPath); !bytes.Equal(content, codexScript()) {
		t.Fatalf("bin/codex content = %q", content)
	}
	if _, err := os.Lstat(filepath.Join(versionDir, "package.json")); !os.IsNotExist(err) {
		t.Fatal("files outside the package prefix must not be extracted")
	}
	entries, _ := os.ReadDir(filepath.Dir(versionDir))
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".zhiban-") {
			t.Fatalf("staging or aside directory left behind: %s", entry.Name())
		}
	}
	if got, err := os.Readlink(filepath.Join(f.home, ".local", "bin", "codex")); err != nil || got != codexPath {
		t.Fatalf("launcher after repair = %q, %v", got, err)
	}
	after, err := f.detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil || after.UIState != detect.UIStateInstalledUnmanaged || after.InstalledVersion != testCodexVersion || after.InstallSource != detect.SourceOfficial {
		t.Fatalf("Detect(after repair) = %+v, %v", after, err)
	}
	f.assertNoScratch(t)
}

func TestCodexTreeRepairPutsOldDirectoryBackWhenHashMismatches(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f := newFixture(t, defaultHandler(t), func(assets map[string]Asset) {
		asset := assets[TargetCodexCLI]
		asset.BinarySHA256 = digestOf([]byte("not the shipped binary"))
		assets[TargetCodexCLI] = asset
	})
	versionDir := filepath.Join(f.home, ".codex", "packages", "standalone", testCodexVersion)
	codexPath := filepath.Join(versionDir, "bin", "codex")
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
	final := f.runInstall(t, TargetCodexCLI, ModeRepair)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CODEX_CLI-INSTALL-HASH_MISMATCH" {
		t.Fatalf("repair final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	// The hash is checked while staging, before the old directory is touched.
	if content, _ := os.ReadFile(codexPath); !bytes.Equal(content, broken) {
		t.Fatalf("old bin/codex changed: %q", content)
	}
	entries, _ := os.ReadDir(filepath.Dir(versionDir))
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".zhiban-") {
			t.Fatalf("staging or aside directory left behind: %s", entry.Name())
		}
	}
	f.assertNoScratch(t)
}

func TestCodexCatalogLayoutNormalisesMemberEntries(t *testing.T) {
	t.Parallel()
	cases := []struct {
		layout, member string
		wantLayout     string
		wantMember     string
		wantErr        bool
	}{
		{LayoutTarballTree, "package/vendor/aarch64-apple-darwin", LayoutTarballTree, "package/vendor/aarch64-apple-darwin", false},
		{LayoutTarballMember, "package/vendor/aarch64-apple-darwin/bin/codex", LayoutTarballTree, "package/vendor/aarch64-apple-darwin", false},
		{LayoutTarballMember, "package/vendor/x86_64-pc-windows-msvc/bin/codex.exe", LayoutTarballTree, "package/vendor/x86_64-pc-windows-msvc", false},
		{LayoutTarballMember, "bin/codex", "", "", true},
		{LayoutTarballMember, "package/claude", "", "", true},
		{LayoutTarballSingle, "", "", "", true},
		{LayoutBareBinary, "", "", "", true},
	}
	for _, item := range cases {
		layout, member, err := codexCatalogLayout(item.layout, item.member)
		if (err != nil) != item.wantErr || layout != item.wantLayout || member != item.wantMember {
			t.Fatalf("codexCatalogLayout(%s, %s) = %s, %s, %v", item.layout, item.member, layout, member, err)
		}
	}
}
