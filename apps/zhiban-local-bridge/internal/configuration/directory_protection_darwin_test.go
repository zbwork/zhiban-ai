//go:build darwin && cgo

package configuration

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestPrivateAncestorCompatibility(t *testing.T) {
	for _, tc := range []struct {
		name        string
		libraryMode os.FileMode
		acl         string
		aclOnHome   bool
		allowed     bool
	}{
		{name: "private Library protects writable Application Support", libraryMode: 0o700, allowed: true},
		{name: "deny-only ACL preserves privacy", libraryMode: 0o700, acl: "everyone deny delete", allowed: true},
		{name: "no private ancestor", libraryMode: 0o755},
		{name: "allow ACL on Library", libraryMode: 0o700, acl: "everyone allow search"},
		{name: "allow ACL on earlier ancestor", libraryMode: 0o700, acl: "everyone allow add_subdirectory", aclOnHome: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			if err := os.Chmod(home, 0o755); err != nil {
				t.Fatal(err)
			}
			library := filepath.Join(home, "Library")
			support := filepath.Join(library, "Application Support")
			if err := os.MkdirAll(support, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(library, tc.libraryMode); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(support, 0o707); err != nil {
				t.Fatal(err)
			}
			if tc.acl != "" {
				path := library
				if tc.aclOnHome {
					path = home
				}
				t.Cleanup(func() {
					if output, err := exec.Command("/bin/chmod", "-N", path).CombinedOutput(); err != nil {
						t.Errorf("clear test ACL: %s: %v", output, err)
					}
				})
				if output, err := exec.Command("/bin/chmod", "+a", tc.acl, path).CombinedOutput(); err != nil {
					t.Fatalf("set test ACL: %s: %v", output, err)
				}
			}
			helper := writeExecutable(t, filepath.Join(home, "helper"))
			manager := newTestManager(t, home, helper, nil, nil, time.Now)
			path := manager.manifestPath(TargetCodexCLI)
			before, err := manager.snapshot(path, false)
			if tc.allowed {
				if err != nil {
					t.Fatalf("snapshot: %v", err)
				}
				if err := manager.atomicWriteCAS(path, []byte(`{"test":true}`), 0o600, before); err != nil {
					t.Fatalf("write protected state: %v", err)
				}
				got, err := manager.snapshot(path, false)
				if err != nil || string(got.Bytes) != `{"test":true}` {
					t.Fatalf("read state: %+v, %v", got, err)
				}
			} else {
				if !errors.Is(err, ErrUnsafePath) {
					t.Fatalf("snapshot: %v, want unsafe path", err)
				}
				if err := manager.atomicWriteCAS(path, []byte(`{"test":true}`), 0o600, fileSnapshot{}); !errors.Is(err, ErrUnsafePath) {
					t.Fatalf("write: %v, want unsafe path", err)
				}
				status, err := manager.Status(context.Background(), TargetCodexCLI)
				if err != nil || status.State != StateConflict || status.CurrentService != ServiceUnknown || status.ErrorCode != errorCode(TargetCodexCLI, "UNSAFE_PATH") {
					t.Fatalf("blocked status: %+v, %v", status, err)
				}
			}
			info, err := os.Stat(support)
			if err != nil || info.Mode().Perm() != 0o707 {
				t.Fatalf("directory permissions were changed: %v", err)
			}
		})
	}
}

func TestPrivateAncestorDoesNotRelaxLinksOrFilePermissions(t *testing.T) {
	home := t.TempDir()
	manager := newTestManager(t, home, writeExecutable(t, filepath.Join(home, "helper")), nil, nil, time.Now)
	outside := t.TempDir()
	link := filepath.Join(home, "linked")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.snapshot(filepath.Join(link, "state.json"), true); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("parent symlink: %v", err)
	}
	file := filepath.Join(home, "state.json")
	if err := os.Symlink(filepath.Join(outside, "state.json"), file); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.snapshot(file, false); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("file symlink: %v", err)
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(file, 0o666); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.snapshot(file, false); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("writable file: %v", err)
	}
}
