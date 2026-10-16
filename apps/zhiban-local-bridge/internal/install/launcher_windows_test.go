//go:build windows

package install

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
)

func openDir(t *testing.T, path string) *os.File {
	t.Helper()
	fd, err := secureOpenDirectory(path)
	if err != nil {
		t.Fatalf("secureOpenDirectory(%s): %v", path, err)
	}
	dir := os.NewFile(uintptr(fd), path)
	t.Cleanup(func() { _ = dir.Close() })
	return dir
}

// The Windows launcher is a batch shim into the versions layout: creating it
// needs no privilege, it names the version file it runs, and switching
// versions moves the old shim aside so a failed switch can be undone.
func TestWindowsLauncherIsShimAndSwitchesAtomically(t *testing.T) {
	home := t.TempDir()
	versions := filepath.Join(home, "versions")
	bin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(versions, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	v1 := filepath.Join(versions, "1.0.0.exe")
	v2 := filepath.Join(versions, "2.0.0.exe")
	if err := os.WriteFile(v1, []byte("MZ v1"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(v2, []byte("MZ v2"), 0o755); err != nil {
		t.Fatal(err)
	}
	binDir := openDir(t, bin)
	launcher := filepath.Join(bin, "tool.cmd")

	if err := ensureLauncherAt(binDir, "tool.cmd", v1); err != nil {
		t.Fatalf("ensureLauncherAt: %v", err)
	}
	if !launcherPointsTo(launcher, v1) || launcherPointsTo(launcher, v2) {
		t.Fatalf("launcher target wrong after install")
	}
	got, _ := os.ReadFile(launcher)
	if !strings.HasPrefix(string(got), "@echo off\r\nrem zhiban-local-bridge launcher v1\r\n") ||
		!strings.Contains(string(got), "\r\nrem target=..\\..\\versions\\1.0.0.exe\r\n") ||
		!strings.Contains(string(got), "\r\n\"%~dp0..\\..\\versions\\1.0.0.exe\" %*\r\n") {
		t.Fatalf("launcher content = %q", got)
	}
	if target, ok := detect.LauncherShimTarget(launcher); !ok || !strings.EqualFold(target, v1) {
		t.Fatalf("LauncherShimTarget = %q, %v", target, ok)
	}
	// Idempotent for the same target, a conflict for another retained one.
	if err := ensureLauncherAt(binDir, "tool.cmd", v1); err != nil {
		t.Fatalf("ensureLauncherAt again: %v", err)
	}
	if err := ensureLauncherAt(binDir, "tool.cmd", v2); !errors.Is(err, errConflict) {
		t.Fatalf("ensureLauncherAt(other target) err = %v, want errConflict", err)
	}
	if !launcherConflicts(launcher, v2) || launcherConflicts(launcher, v1) {
		t.Fatalf("launcherConflicts wrong for a shim that runs v1")
	}
	info, _ := os.Lstat(launcher)
	if !launcherKindOK(info) {
		t.Fatalf("shim launcher must count as a launcher")
	}

	// Upgrade: the launcher now runs v2; the aside token restores v1.
	previous, err := replaceLauncherAt(binDir, "tool.cmd", v2)
	if err != nil || previous == "" {
		t.Fatalf("replaceLauncherAt = %q, %v", previous, err)
	}
	if !launcherPointsTo(launcher, v2) {
		t.Fatalf("launcher does not run v2 after replace")
	}
	if _, err := os.Lstat(filepath.Join(bin, previous)); err != nil {
		t.Fatalf("aside launcher missing: %v", err)
	}
	if err := restoreLauncherAt(binDir, "tool.cmd", previous); err != nil {
		t.Fatalf("restoreLauncherAt: %v", err)
	}
	if !launcherPointsTo(launcher, v1) {
		t.Fatalf("launcher does not run v1 after restore")
	}
	if _, err := os.Lstat(filepath.Join(bin, previous)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("aside launcher still present after restore: %v", err)
	}

	// Replace again and commit: the aside is gone, v1 stays retained.
	previous, err = replaceLauncherAt(binDir, "tool.cmd", v2)
	if err != nil || previous == "" {
		t.Fatalf("replaceLauncherAt (second) = %q, %v", previous, err)
	}
	commitLauncher(binDir, previous)
	if _, err := os.Lstat(filepath.Join(bin, previous)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("aside launcher still present after commit: %v", err)
	}
	if _, err := os.Lstat(v1); err != nil {
		t.Fatalf("retained version removed by launcher switch: %v", err)
	}
	// Already pointing at the target: nothing to undo.
	if previous, err := replaceLauncherAt(binDir, "tool.cmd", v2); err != nil || previous != "" {
		t.Fatalf("replaceLauncherAt(same target) = %q, %v", previous, err)
	}
	// A directory occupying the launcher name is a conflict.
	if err := os.Mkdir(filepath.Join(bin, "dir.cmd"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := replaceLauncherAt(binDir, "dir.cmd", v2); !errors.Is(err, errConflict) {
		t.Fatalf("replaceLauncherAt(directory) err = %v, want errConflict", err)
	}
	// A foreign file (someone else's shim) is a conflict for install and is
	// what launcherKindOK lets a switch replace.
	foreign := filepath.Join(bin, "other.cmd")
	if err := os.WriteFile(foreign, []byte("@echo off\r\nnode other.js %*\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ensureLauncherAt(binDir, "other.cmd", v1); !errors.Is(err, errConflict) {
		t.Fatalf("ensureLauncherAt(foreign) err = %v, want errConflict", err)
	}
	if !launcherConflicts(foreign, v1) {
		t.Fatal("foreign launcher must conflict")
	}
}

// A shim of ours whose version file is gone runs nothing: install rewrites it
// rather than reporting a conflict, and the older Bridge's hard-link launcher
// <tool>.exe beside the shim is retired because PATHEXT would run it first.
func TestWindowsLauncherRewritesDanglingShimAndRetiresLegacyExe(t *testing.T) {
	home := t.TempDir()
	versions := filepath.Join(home, "versions")
	bin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(versions, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	gone := filepath.Join(versions, "0.9.0.exe")
	v1 := filepath.Join(versions, "1.0.0.exe")
	if err := os.WriteFile(v1, []byte("MZ v1"), 0o755); err != nil {
		t.Fatal(err)
	}
	binDir := openDir(t, bin)
	launcher := filepath.Join(bin, "tool.cmd")
	content, err := detect.LauncherShim(launcher, gone)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(launcher, content, 0o644); err != nil {
		t.Fatal(err)
	}
	legacy := filepath.Join(bin, "tool.exe")
	if err := os.WriteFile(legacy, []byte("MZ old"), 0o755); err != nil {
		t.Fatal(err)
	}
	if launcherConflicts(launcher, v1) {
		t.Fatal("dangling shim must not conflict")
	}
	if err := ensureLauncherAt(binDir, "tool.cmd", v1); err != nil {
		t.Fatalf("ensureLauncherAt over dangling shim: %v", err)
	}
	if !launcherPointsTo(launcher, v1) {
		t.Fatal("launcher does not run v1 after rewrite")
	}
	if _, err := os.Lstat(legacy); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy tool.exe still present: %v", err)
	}
	entries, _ := os.ReadDir(bin)
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), launcherAsidePrefix) || strings.HasPrefix(entry.Name(), launcherTemporaryPrefix) {
			t.Fatalf("leftover %s in launcher dir", entry.Name())
		}
	}
	// The legacy executable is retired on a switch as well.
	if err := os.WriteFile(legacy, []byte("MZ old"), 0o755); err != nil {
		t.Fatal(err)
	}
	v2 := filepath.Join(versions, "2.0.0.exe")
	if err := os.WriteFile(v2, []byte("MZ v2"), 0o755); err != nil {
		t.Fatal(err)
	}
	previous, err := replaceLauncherAt(binDir, "tool.cmd", v2)
	if err != nil || previous == "" {
		t.Fatalf("replaceLauncherAt = %q, %v", previous, err)
	}
	commitLauncher(binDir, previous)
	if _, err := os.Lstat(legacy); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy tool.exe still present after switch: %v", err)
	}
}

func TestWindowsSysinfoAndUserPathMerge(t *testing.T) {
	version, err := defaultOSVersion()
	if err != nil || !osVersionSupported(version) {
		t.Fatalf("defaultOSVersion = %q, %v (supported=%v)", version, err, osVersionSupported(version))
	}
	if osVersionSupported("10.0.17134") || osVersionSupported("6.3.9600") || osVersionSupported("10.0") {
		t.Fatal("old builds must not be supported")
	}
	if !osVersionSupported("10.0.17763") || !osVersionSupported("10.0.22631") || !osVersionSupported("11.0.1") {
		t.Fatal("1809 and newer must be supported")
	}
	free, err := defaultFreeBytes(t.TempDir())
	if err != nil || free == 0 {
		t.Fatalf("defaultFreeBytes = %d, %v", free, err)
	}
	if !defaultWritable(t.TempDir()) {
		t.Fatal("temp dir must be writable")
	}
	if minOSVersion() != "10.0.17763" {
		t.Fatalf("minOSVersion = %q", minOSVersion())
	}

	dir := `C:\Users\me\.local\bin`
	if merged, changed := mergeUserPath(`C:\Windows;C:\Tools\`, dir); !changed || merged != `C:\Windows;C:\Tools\;`+dir {
		t.Fatalf("mergeUserPath append = %q, %v", merged, changed)
	}
	if _, changed := mergeUserPath(`C:\Windows;c:\users\ME\.local\BIN\`, dir); changed {
		t.Fatal("case-insensitive match with trailing separator must not change PATH")
	}
	t.Setenv("USERPROFILE", `C:\Users\me`)
	if _, changed := mergeUserPath(`%USERPROFILE%\.local\bin;C:\Windows`, dir); changed {
		t.Fatal("USERPROFILE-relative entry must match after expansion")
	}
	if merged, changed := mergeUserPath("", dir); !changed || merged != dir {
		t.Fatalf("mergeUserPath empty = %q, %v", merged, changed)
	}
	if merged, changed := mergeUserPath(`C:\Windows;`, dir); !changed || merged != `C:\Windows;`+dir {
		t.Fatalf("mergeUserPath trailing ; = %q, %v", merged, changed)
	}
}

func TestWindowsDownloadDirAndLayoutNames(t *testing.T) {
	if executableFileName("codex") != "codex.exe" || executableFileName("2.1.263") != "2.1.263.exe" {
		t.Fatal("executables need .exe on Windows")
	}
	if launcherFileName("codex") != "codex.cmd" || launcherFileName("claude") != "claude.cmd" {
		t.Fatal("launchers are .cmd shims on Windows")
	}
	parts := platformDownloadDirParts()
	if len(parts) != 5 || parts[0] != "AppData" || parts[1] != "Local" || parts[2] != applicationSupport {
		t.Fatalf("download dir parts = %v", parts)
	}
	if got := parseProxyHostPort("proxy.example.com:3128"); got == nil || got.String() != "http://proxy.example.com:3128" {
		t.Fatalf("parseProxyHostPort = %v", got)
	}
	// Synthetic userinfo exercises rejection; keep credentials out of URL literals.
	if got := parseProxyHostPort("http://" + "user:pw@proxy.example.com:3128"); got != nil {
		t.Fatal("credentials in a proxy value must be refused")
	}
}
