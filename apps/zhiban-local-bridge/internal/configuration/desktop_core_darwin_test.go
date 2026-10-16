//go:build darwin

package configuration

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// This opt-in check uses the untouched official ZIP and an isolated home. It
// never changes the user's installed application, credentials, or config.toml.
func TestOfficialCodexDesktopConfiguration(t *testing.T) {
	archive := os.Getenv("ZHIBAN_TEST_CODEX_ARCHIVE")
	if archive == "" {
		t.Skip("set ZHIBAN_TEST_CODEX_ARCHIVE to an official Mac ZIP")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	extracted := t.TempDir()
	if output, err := exec.CommandContext(ctx, "/usr/bin/ditto", "-x", "-k", archive, extracted).CombinedOutput(); err != nil {
		t.Fatalf("extract: %v: %s", err, output)
	}
	bundles, err := filepath.Glob(filepath.Join(extracted, "*.app"))
	if err != nil || len(bundles) != 1 {
		t.Fatalf("bundles: %v, %v", bundles, err)
	}
	bundle := bundles[0]
	if output, err := exec.CommandContext(ctx, "/usr/bin/codesign", "--verify", "--deep", "--strict", bundle).CombinedOutput(); err != nil {
		t.Fatalf("signature: %v: %s", err, output)
	}
	f := newGlobalFixture(t)
	f.installs[TargetCodexDesktop] = Installation{TargetID: TargetCodexDesktop, InstallationID: "official-desktop", Executable: bundle, Version: "26.924.22138"}
	f.manager.probeGlobalFunc = nil // exercise the actual bundled core with mcp list
	core, required := desktopCodexCore(bundle)
	if core == "" || !required {
		t.Fatal("official core not resolved")
	}
	versionCmd := exec.CommandContext(ctx, core, "--version")
	versionCmd.Env = []string{"HOME=" + f.home, "CODEX_HOME=" + filepath.Dir(f.codexPath), "PATH=/usr/bin:/bin"}
	version, err := versionCmd.CombinedOutput()
	if err != nil || !strings.Contains(string(version), "codex-cli") {
		t.Fatalf("core version: %v: %s", err, version)
	}
	t.Logf("official bundled core: %s", strings.TrimSpace(string(version)))
	status := f.switchTo(t, TargetCodexDesktop)
	if !status.GlobalSwitched || status.CurrentService != ServiceZhiban {
		t.Fatalf("switch: %+v", status)
	}
	f.manager.codexExecutables = func(context.Context) ([]string, error) { return []string{bundle}, nil }
	entries, ok := f.manager.localCodexExecutables(ctx, true)
	if !ok || len(entries) != 1 || entries[0].Path != core {
		t.Fatalf("catalog core: %+v, %v", entries, ok)
	}
}
