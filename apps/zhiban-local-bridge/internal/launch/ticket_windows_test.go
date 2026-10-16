//go:build windows

package launch

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestWindowsCreateProtectedFile isolates createProtectedFileAt on Windows to
// localize the "ticket store failed" bug (Chmod/Sync on a secure handle).
func TestWindowsCreateProtectedFile(t *testing.T) {
	dir := t.TempDir()
	fd, err := secureOpenDirectory(dir)
	if err != nil {
		t.Fatalf("secureOpenDirectory: %v", err)
	}
	root := os.NewFile(uintptr(fd), dir)
	if root == nil {
		t.Fatal("os.NewFile nil")
	}
	defer root.Close()
	if err := createProtectedFileAt(root, "x.ticket", []byte("hello"), 0o600); err != nil {
		t.Fatalf("createProtectedFileAt: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "x.ticket"))
	if err != nil || string(got) != "hello" {
		t.Fatalf("content = %q, err %v", got, err)
	}
}

// TestWindowsTicketStoreCreatesCmdTrampoline verifies the ticket store
// mechanics on Windows: a .cmd trampoline is written, it invokes the helper in
// "launch consume" mode, and it never leaks the bookmark or version.
func TestWindowsTicketStoreCreatesCmdTrampoline(t *testing.T) {
	home := t.TempDir()
	helper := filepath.Join(home, "zhiban-local-bridge.exe")
	if err := os.WriteFile(helper, []byte("MZ binary placeholder"), 0o600); err != nil {
		t.Fatalf("write helper: %v", err)
	}
	root := filepath.Join(home, "AppData", "Local", "cn.qkfintech.zhiban", "local-coding-tools", "launch")
	store, err := NewFileTicketStore(home, root, helper)
	if err != nil {
		t.Fatalf("NewFileTicketStore: %v", err)
	}
	ticket := launchTicket{
		SchemaVersion: 1, ID: strings.Repeat("A", 43), Bookmark: []byte("opaque-bookmark"),
		ProjectIdentity: projectIdentity{Device: 10, Inode: 20}, TargetID: TargetCodexCLI,
		InstallationFingerprint: strings.Repeat("B", 43), InstallationVersion: "0.153.4",
		ProfileVersion: "2026.09.07.1", CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Minute),
	}
	scriptPath, err := store.Create(ticket)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if filepath.Ext(scriptPath) != ".cmd" {
		t.Fatalf("script path = %q, want .cmd", scriptPath)
	}
	script, err := os.ReadFile(scriptPath)
	if err != nil {
		t.Fatalf("read script: %v", err)
	}
	if !strings.Contains(string(script), "launch consume --ticket \""+strings.Repeat("A", 43)+"\"") {
		t.Fatalf("trampoline missing consume line: %s", script)
	}
	if strings.Contains(string(script), "opaque-bookmark") || strings.Contains(string(script), "0.153.4") {
		t.Fatalf("trampoline leaks sensitive data: %s", script)
	}
	if !strings.Contains(string(script), "\""+helper+"\"") {
		t.Fatalf("trampoline does not quote the helper path: %s", script)
	}
	// The console `start` opens uses the OEM code page (936 on zh-CN) while the
	// file is UTF-8: the helper path (`C:\Program Files\知办AI\…`) only parses
	// after an ASCII `chcp 65001` line that precedes it.
	if !strings.HasPrefix(string(script), "@echo off\r\n@chcp 65001 >nul\r\n\""+helper+"\"") {
		t.Fatalf("trampoline must switch the console to UTF-8 before the helper line: %q", script)
	}

	// The ticket file exists and can be claimed exactly once.
	if _, err := os.Stat(filepath.Join(root, ticket.ID+".ticket")); err != nil {
		t.Fatalf("ticket file missing: %v", err)
	}
	claimed, err := store.Claim(ticket.ID)
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if claimed.ID != ticket.ID {
		t.Fatalf("claimed wrong ticket: %q", claimed.ID)
	}
	if _, err := store.Claim(ticket.ID); err == nil {
		t.Fatalf("second Claim succeeded, want single-use failure")
	}
}
