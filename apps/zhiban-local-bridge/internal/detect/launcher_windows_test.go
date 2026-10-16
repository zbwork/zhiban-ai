//go:build windows

package detect

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestLauncherShimRoundTrip(t *testing.T) {
	shim := `C:\Users\me\.local\bin\codex.cmd`
	target := `C:\Users\me\.codex\packages\standalone\0.154.0\bin\codex.exe`
	content, err := LauncherShim(shim, target)
	if err != nil {
		t.Fatalf("LauncherShim: %v", err)
	}
	want := "@echo off\r\n" +
		"rem zhiban-local-bridge launcher v1\r\n" +
		`rem target=..\..\.codex\packages\standalone\0.154.0\bin\codex.exe` + "\r\n" +
		`"%~dp0..\..\.codex\packages\standalone\0.154.0\bin\codex.exe" %*` + "\r\n" +
		"exit /b %ERRORLEVEL%\r\n"
	if string(content) != want {
		t.Fatalf("shim =\n%q\nwant\n%q", content, want)
	}
	for i := range content {
		if content[i] >= 0x80 {
			t.Fatal("shim must be ASCII")
		}
	}
	if got, ok := parseLauncherShim(shim, content); !ok || got != target {
		t.Fatalf("parseLauncherShim = %q, %v", got, ok)
	}
	// A target on another volume is written absolute and parsed back as is.
	other := `D:\tools\claude.exe`
	content, err = LauncherShim(shim, other)
	if err != nil {
		t.Fatalf("LauncherShim(other volume): %v", err)
	}
	if !strings.Contains(string(content), "rem target="+other+"\r\n") || !strings.Contains(string(content), `"`+other+`" %*`) {
		t.Fatalf("absolute shim = %q", content)
	}
	if got, ok := parseLauncherShim(shim, content); !ok || got != other {
		t.Fatalf("parseLauncherShim(absolute) = %q, %v", got, ok)
	}
	// Batch metacharacters, quotes and non-ASCII cannot be expressed.
	for _, bad := range []string{`C:\Users\me\.local\share\claude\versions\1"2.exe`, `C:\Users\me\a%b\claude.exe`, `C:\Users\张三\.local\share\claude\versions\2.1.267.exe`, `C:\Users\me\a&b\claude.exe`} {
		if _, err := LauncherShim(shim, bad); !errors.Is(err, ErrLauncherShimTarget) {
			t.Fatalf("LauncherShim(%q) err = %v", bad, err)
		}
	}
	if _, err := LauncherShim(`bin\codex.cmd`, target); err == nil {
		t.Fatal("relative shim path must be refused")
	}
	// Not our shim.
	for _, content := range []string{"", "@echo off\r\nnode codex.js %*\r\n", "@echo off\r\nrem zhiban-local-bridge launcher v1\r\n", "rem zhiban-local-bridge launcher v1\r\nrem target=x.exe\r\n"} {
		if got, ok := parseLauncherShim(shim, []byte(content)); ok {
			t.Fatalf("parseLauncherShim(%q) = %q, want not ok", content, got)
		}
	}
}

// Discovery resolves the Bridge's shim to the version file it runs, so the
// Codex layout check and the source rule see the versions layout; a shim
// whose version file is gone is not a candidate; a foreign .cmd stays itself.
func TestWindowsDiscoverResolvesLauncherShim(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, ".local", "bin")
	versionBin := filepath.Join(home, ".codex", "packages", "standalone", "0.154.0", "bin")
	for _, dir := range []string{bin, versionBin} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	exe := filepath.Join(versionBin, "codex.exe")
	for _, name := range []string{exe, filepath.Join(versionBin, "codex-code-mode-host.exe")} {
		if err := os.WriteFile(name, []byte("MZ"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	shim := filepath.Join(bin, "codex.cmd")
	content, err := LauncherShim(shim, exe)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(shim, content, 0o644); err != nil {
		t.Fatal(err)
	}
	discoverer := NewWindowsDiscoverer(home)
	discoverer.LookPath = func(string) (string, error) { return "", &exec.Error{Name: "codex", Err: exec.ErrNotFound} }
	discoverer.Glob = func(string) ([]string, error) { return nil, nil }
	discoverer.NpmPrefix = filepath.Join(home, "AppData", "Roaming", "npm")
	discoverer.LocalAppData = filepath.Join(home, "AppData", "Local")

	candidates, err := discoverer.Discover(context.Background(), TargetCodexCLI)
	if err != nil || len(candidates) != 1 {
		t.Fatalf("Discover = %+v, %v", candidates, err)
	}
	got := candidates[0]
	if !strings.EqualFold(got.RealPath, exe) || !strings.EqualFold(got.Path, shim) || got.Source != SourceOfficial {
		t.Fatalf("candidate = %+v", got)
	}
	if codexLayoutIncomplete(TargetCodexCLI, got) {
		t.Fatal("layout must be complete through the shim")
	}

	// Version file gone: the shim runs nothing.
	if err := os.Remove(exe); err != nil {
		t.Fatal(err)
	}
	candidates, err = discoverer.Discover(context.Background(), TargetCodexCLI)
	if err != nil || len(candidates) != 0 {
		t.Fatalf("Discover(dangling) = %+v, %v", candidates, err)
	}

	// A foreign .cmd in the same place is reported as itself.
	if err := os.WriteFile(shim, []byte("@echo off\r\nnode codex.js %*\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	candidates, err = discoverer.Discover(context.Background(), TargetCodexCLI)
	if err != nil || len(candidates) != 1 || !strings.EqualFold(candidates[0].RealPath, shim) {
		t.Fatalf("Discover(foreign) = %+v, %v", candidates, err)
	}
}
