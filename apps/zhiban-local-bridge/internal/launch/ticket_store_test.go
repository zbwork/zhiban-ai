package launch

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestFileTicketStoreCreatesAndAtomicallyClaimsProtectedTicket(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	home := t.TempDir()
	helper := filepath.Join(home, "Zhiban Local Bridge.app", "Contents", "MacOS", "zhiban-local-bridge")
	mustExecutable(t, helper)
	root := filepath.Join(home, "Library", "Application Support", "cn.qkfintech.zhiban", "local-coding-tools", "launch")
	store, err := NewFileTicketStore(home, root, helper)
	if err != nil {
		t.Fatal(err)
	}
	ticket := launchTicket{
		SchemaVersion: 1, ID: strings.Repeat("A", 43), Bookmark: []byte("opaque-bookmark"),
		ProjectIdentity: projectIdentity{Device: 10, Inode: 20}, TargetID: TargetCodexCLI,
		InstallationFingerprint: strings.Repeat("B", 43), InstallationVersion: "0.153.4",
		ProfileVersion: "2026.09.07.1", CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Minute),
	}
	scriptPath, err := store.Create(ticket)
	if err != nil {
		t.Fatal(err)
	}
	if scriptPath != filepath.Join(store.rootDir, ticket.ID+".command") {
		t.Fatalf("script path = %q", scriptPath)
	}
	assertMode(t, filepath.Join(root, ticket.ID+".ticket"), 0o600)
	assertMode(t, scriptPath, 0o700)
	assertMode(t, root, 0o700)
	script, err := os.ReadFile(scriptPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(script), " launch consume --ticket '"+strings.Repeat("A", 43)+"'") ||
		strings.Contains(string(script), "opaque-bookmark") || strings.Contains(string(script), "0.153.4") {
		t.Fatalf("unsafe trampoline: %s", script)
	}

	claimed, err := store.Claim(ticket.ID)
	if err != nil {
		t.Fatal(err)
	}
	encodedWant, _ := json.Marshal(ticket)
	encodedGot, _ := json.Marshal(claimed)
	if string(encodedGot) != string(encodedWant) {
		t.Fatalf("claimed = %s, want %s", encodedGot, encodedWant)
	}
	if _, err := os.Lstat(filepath.Join(root, ticket.ID+".ticket")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("ticket remained: %v", err)
	}
	if _, err := os.Lstat(scriptPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("trampoline remained: %v", err)
	}
	if _, err := store.Claim(ticket.ID); !errors.Is(err, ErrTicketNotFound) {
		t.Fatalf("replay error = %v, want ErrTicketNotFound", err)
	}
}

func TestFileTicketStoreRejectsSymlinkedRootAndUnknownTicketFields(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	helper := filepath.Join(home, "helper")
	mustExecutable(t, helper)
	root := filepath.Join(home, "launch")
	outside := t.TempDir()
	if err := os.Symlink(outside, root); err != nil {
		t.Fatal(err)
	}
	store, err := NewFileTicketStore(home, root, helper)
	if err != nil {
		t.Fatal(err)
	}
	ticket := launchTicket{SchemaVersion: 1, ID: strings.Repeat("C", 43)}
	if _, err := store.Create(ticket); !errors.Is(err, ErrTicketStoreFailed) {
		t.Fatalf("symlink root error = %v, want ErrTicketStoreFailed", err)
	}
	if entries, err := os.ReadDir(outside); err != nil || len(entries) != 0 {
		t.Fatalf("symlink destination changed: entries=%v err=%v", entries, err)
	}

	if err := os.Remove(root); err != nil {
		t.Fatal(err)
	}
	store, err = NewFileTicketStore(home, root, helper)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Create(ticket); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, ticket.ID+".ticket")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	content = append(content[:len(content)-1], []byte(`,"command":"whoami"}`)...)
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Claim(ticket.ID); !errors.Is(err, ErrTicketStoreFailed) {
		t.Fatalf("unknown field error = %v, want ErrTicketStoreFailed", err)
	}
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("mode(%s) = %#o, want %#o", filepath.Base(path), got, want)
	}
}
