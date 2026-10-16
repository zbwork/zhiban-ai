//go:build windows

package shellpath

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrependPathPutsTheManagedDirectoryFirst(t *testing.T) {
	// 追加到末尾(发行方安装器的做法)抢不过已经在前面的 npm 前缀,所以必须前置。
	existing := `C:\Users\u\AppData\Roaming\npm;C:\Windows\System32`
	updated, changed := prependPath(existing, `C:\Users\u\.local\bin`)
	if !changed || !strings.HasPrefix(updated, `C:\Users\u\.local\bin;`) {
		t.Fatalf("prependPath = %q (changed=%v)", updated, changed)
	}
	if strings.Count(strings.ToLower(updated), `\.local\bin`) != 1 {
		t.Fatalf("directory must appear once: %q", updated)
	}
	// 已经在第一位:不重复改写。
	if _, changed := prependPath(updated, `C:\Users\u\.local\bin`); changed {
		t.Fatal("already first must not change the value")
	}
	// 已存在但不在第一位:移到前面,不留重复项。
	moved, changed := prependPath(`C:\Windows;C:\Users\u\.local\bin`, `C:\Users\u\.local\bin`)
	if !changed || !strings.HasPrefix(moved, `C:\Users\u\.local\bin;`) ||
		strings.Count(strings.ToLower(moved), `\.local\bin`) != 1 {
		t.Fatalf("prependPath(existing later) = %q (changed=%v)", moved, changed)
	}
}

func TestResolveInPathPrefersMachineThenUserOrder(t *testing.T) {
	root := t.TempDir()
	npm := filepath.Join(root, "npm")
	managed := filepath.Join(root, "local", "bin")
	for _, dir := range []string{npm, managed} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "codex.cmd"), []byte("@echo off\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATHEXT", ".COM;.EXE;.BAT;.CMD")
	resolved, ok := resolveInPath("codex", "", managed+";"+npm)
	if !ok || !strings.HasPrefix(resolved, managed) {
		t.Fatalf("resolveInPath = %q (%v), want the managed copy", resolved, ok)
	}
	// 机器 PATH 排在用户 PATH 之前:用户 PATH 里前置也抢不过它。
	resolved, ok = resolveInPath("codex", npm, managed)
	if !ok || !strings.HasPrefix(resolved, npm) {
		t.Fatalf("machine PATH must win: %q (%v)", resolved, ok)
	}
}

func TestEnsureOnWindowsWritesTheUserPathAndVerifies(t *testing.T) {
	root := t.TempDir()
	npm := filepath.Join(root, "npm")
	managed := filepath.Join(root, "local", "bin")
	for _, dir := range []string{npm, managed} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "codex.cmd"), []byte("@echo off\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATHEXT", ".CMD")
	user := npm
	ensurer := &Ensurer{
		HomeDir:   root,
		BackupDir: filepath.Join(root, "backups"),
		ReadPath:  func() (string, string, error) { return user, "", nil },
		WritePath: func(value string) error { user = value; return nil },
	}
	launcher := filepath.Join(managed, "codex.cmd")
	if err := ensurer.Ensure(context.Background(), "codex", launcher); err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	if !strings.HasPrefix(user, managed+";") {
		t.Fatalf("user PATH after ensure = %q", user)
	}
	entries, err := os.ReadDir(filepath.Join(root, "backups"))
	if err != nil || len(entries) != 1 {
		t.Fatalf("expected one backup of the old PATH: %v (%v)", entries, err)
	}

	// 机器 PATH 里有更靠前的一份:改用户 PATH 也没用,必须如实报未生效。
	user = npm
	stubborn := &Ensurer{
		HomeDir:   root,
		ReadPath:  func() (string, string, error) { return user, npm, nil },
		WritePath: func(value string) error { user = value; return nil },
	}
	if err := stubborn.Ensure(context.Background(), "codex", launcher); !errors.Is(err, ErrNotApplied) {
		t.Fatalf("expected ErrNotApplied, got %v", err)
	}
}
