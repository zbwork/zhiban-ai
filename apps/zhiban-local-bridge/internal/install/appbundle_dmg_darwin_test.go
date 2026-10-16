//go:build darwin

package install

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
)

func TestDMGExtractAllowedBundleNames(t *testing.T) {
	for _, tc := range []struct {
		name    string
		bundles []string
		link    bool
		want    string
	}{
		{name: "primary", bundles: []string{"Codex.app"}, want: "Codex.app"},
		{name: "alias", bundles: []string{"ChatGPT.app"}, want: "ChatGPT.app"},
		{name: "ambiguous", bundles: []string{"Codex.app", "ChatGPT.app"}},
		{name: "unknown", bundles: []string{"Other.app"}},
		{name: "symlink", bundles: []string{"Other.app"}, link: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			source := filepath.Join(root, "source")
			for _, name := range tc.bundles {
				if err := os.MkdirAll(filepath.Join(source, name, "Contents"), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(source, name, "Contents", "marker"), []byte("preserved"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if tc.link {
				if err := os.Symlink("Other.app", filepath.Join(source, "ChatGPT.app")); err != nil {
					t.Fatal(err)
				}
			}
			dmg := filepath.Join(root, "test.dmg")
			if out, err := exec.Command("/usr/bin/hdiutil", "create", "-srcfolder", source, "-format", "UDZO", "-volname", "BundleTest", dmg).CombinedOutput(); err != nil {
				t.Fatalf("create: %v: %s", err, out)
			}
			dest := filepath.Join(root, "dest")
			if err := os.Mkdir(dest, 0o700); err != nil {
				t.Fatal(err)
			}
			err := hdiutilExtract(context.Background(), dmg, dest, []string{"Codex.app", "ChatGPT.app"})
			if tc.want == "" {
				if !errors.Is(err, errArchiveInvalid) {
					t.Fatalf("error = %v, want invalid archive", err)
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				data, err := os.ReadFile(filepath.Join(dest, tc.want, "Contents", "marker"))
				if err != nil || string(data) != "preserved" {
					t.Fatalf("copied content = %q, %v", data, err)
				}
			}
			entries, err := os.ReadDir(dest)
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if entry.Name() != tc.want {
					t.Fatalf("unexpected extraction artifact %s", entry.Name())
				}
			}
		})
	}
}

// Explicit opt-in: verify an official local archive with the production
// extraction, publisher and Gatekeeper checks, placing it only in a temp dir.
func TestOfficialCodexArchivePlacement(t *testing.T) {
	archive := os.Getenv("ZHIBAN_TEST_CODEX_ARCHIVE")
	if archive == "" {
		t.Skip("set ZHIBAN_TEST_CODEX_ARCHIVE for official archive smoke")
	}
	layout := LayoutAppBundleZip
	if strings.HasSuffix(archive, ".dmg") {
		layout = LayoutAppBundleDMG
	}
	dir := t.TempDir()
	target, err := os.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	asset := Asset{BundleName: "Codex.app", BundleAliases: []string{"ChatGPT.app"}, BundleIdentifier: "com.openai.codex", TeamIdentifier: "2DC432GLL2"}
	m := &Manager{bundleTools: defaultBundleTools()}
	if err := m.placeBundle(context.Background(), target, asset, archive, layout, ModeInstall); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(filepath.Join(dir, "ChatGPT.app")); err != nil || !info.IsDir() {
		t.Fatalf("placed alias: %v", err)
	}
	if hidden := hiddenEntries(t, dir); len(hidden) != 0 {
		t.Fatalf("staging remains: %v", hidden)
	}
}

func TestOfficialClaudeArchivePlacement(t *testing.T) {
	archive := os.Getenv("ZHIBAN_TEST_CLAUDE_ARCHIVE")
	if archive == "" {
		t.Skip("set ZHIBAN_TEST_CLAUDE_ARCHIVE for official archive smoke")
	}
	dir := t.TempDir()
	target, err := os.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	asset := Asset{BundleName: "Claude.app", BundleIdentifier: "com.anthropic.claudefordesktop", TeamIdentifier: "Q6L2SF6YDW"}
	m := &Manager{bundleTools: defaultBundleTools()}
	if err := m.placeBundle(context.Background(), target, asset, archive, LayoutAppBundleDMG, ModeInstall); err != nil {
		t.Fatal(err)
	}
	t.Log("official Claude DMG placement, publisher signature and Gatekeeper passed")
	bundle := filepath.Join(dir, "Claude.app")
	supported, known := claudecode.SupportsThirdPartyInference(bundle)
	t.Logf("third-party inference markers: supported=%t known=%t", supported, known)
	manifest, manifestErr := claudecode.ReadEmbeddedManifest(bundle)
	t.Logf("host manifest: version=%q error=%v", manifest.Version, manifestErr)
	if !known || !supported || manifestErr != nil {
		t.Fatal("Claude integration preflight did not pass")
	}
}

func TestOfficialClaudeHostPlacement(t *testing.T) {
	archivePath := os.Getenv("ZHIBAN_TEST_CLAUDE_HOST_ARCHIVE")
	if archivePath == "" {
		t.Skip("set ZHIBAN_TEST_CLAUDE_HOST_ARCHIVE for official host smoke")
	}
	arch := os.Getenv("ZHIBAN_TEST_CLAUDE_HOST_ARCH")
	data, err := os.ReadFile("../claudecode/testdata/desktop-2.9939.4-host.json")
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := claudecode.ParseEmbeddedManifest(data)
	if err != nil {
		t.Fatal(err)
	}
	artifact, ok := claudecode.HostArtifact(manifest, arch)
	if !ok {
		t.Fatal("unsupported architecture")
	}
	archive, err := os.Open(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	defer archive.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, archive)
	if err != nil || size != artifact.Size || hex.EncodeToString(hash.Sum(nil)) != artifact.Checksum {
		t.Fatal("host archive does not match signed desktop manifest")
	}
	home := t.TempDir()
	dir := filepath.Join(append([]string{home}, claudecode.StorageDirParts()...)...)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	storage, err := os.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer storage.Close()
	m := &Manager{bundleTools: BundleTools{}.withDefaults()}
	component := componentPlan{manifest: manifest, artifact: artifact}
	if err := m.placeHostBundle(context.Background(), storage, component, archive, Source{Layout: LayoutHostBundleTarZst}); err != nil {
		t.Fatal(err)
	}
	if state := claudecode.Status(home, manifest, arch); state.State != claudecode.StatePresent {
		t.Fatalf("host state = %+v", state)
	}
	if arch == runtime.GOARCH {
		cmd := exec.Command(claudecode.BinaryPath(home, manifest.Version), "--version")
		cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin:/usr/sbin:/sbin"}
		out, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(out), manifest.Version) {
			t.Fatalf("host version = %q, %v", out, err)
		}
	}
}
