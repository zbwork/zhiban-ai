//go:build windows

package configuration

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestWindowsClaudeDesktopHelperCopiesBridge covers the credential helper
// Claude Desktop runs on Windows: a copy of the whole Bridge executable,
// which is far larger than any managed config file. The first real-machine
// switch (2026-09-10) died on the managed-file size limit before writing
// anything.
func TestWindowsClaudeDesktopHelperCopiesBridge(t *testing.T) {
	home := t.TempDir()
	t.Setenv("LOCALAPPDATA", filepath.Join(home, "AppData", "Local"))
	source := filepath.Join(home, "Program Files", "ZhibanAI", "zhiban-local-bridge.exe")
	content := bytes.Repeat([]byte("bridge-bytes-"), (maxManagedFileBytes*3)/13)
	mustWriteFile(t, source, content, 0o700)
	manager := newTestManager(t, home, source, nil, nil, nil)

	path := manager.claudeDesktopHelperPath()
	if want := filepath.Join(home, "AppData", "Local", applicationSupportID, "local-coding-tools", ClaudeDesktopHelperExecutable); path != want {
		t.Fatalf("claudeDesktopHelperPath() = %q, want %q", path, want)
	}
	if err := manager.ensureClaudeDesktopHelper(); err != nil {
		t.Fatalf("ensureClaudeDesktopHelper() first copy error = %v", err)
	}
	if got := mustReadFile(t, path); !bytes.Equal(got, content) {
		t.Fatalf("helper copy has %d bytes, want %d", len(got), len(content))
	}

	// An identical copy is left alone.
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.ensureClaudeDesktopHelper(); err != nil {
		t.Fatalf("ensureClaudeDesktopHelper() repeat error = %v", err)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("an identical helper copy must not be rewritten")
	}

	// A Bridge update refreshes the copy in place.
	updated := append(append([]byte{}, content...), []byte("-v2")...)
	mustWriteFile(t, source, updated, 0o700)
	if err := manager.ensureClaudeDesktopHelper(); err != nil {
		t.Fatalf("ensureClaudeDesktopHelper() refresh error = %v", err)
	}
	if got := mustReadFile(t, path); !bytes.Equal(got, updated) {
		t.Fatalf("refreshed helper copy has %d bytes, want %d", len(got), len(updated))
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".zhiban-config-") || strings.HasPrefix(entry.Name(), ".zbswap-") {
			t.Fatalf("temporary %s left behind after the refresh", entry.Name())
		}
	}
}
