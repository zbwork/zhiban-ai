//go:build !windows

package shellpath

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureDoesNothingWhenShellAlreadyResolvesTheLauncher(t *testing.T) {
	home := t.TempDir()
	launcher := filepath.Join(home, ".local", "bin", "codex")
	writeExecutable(t, launcher)
	rc := filepath.Join(home, ".zshrc")
	if err := os.WriteFile(rc, []byte("alias ll='ls -l'\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ensurer := &Ensurer{
		HomeDir: home, Shell: "/bin/zsh",
		Lookup: func(context.Context, string) (string, bool) { return launcher, true },
	}
	if err := ensurer.Ensure(context.Background(), "codex", launcher); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	content, _ := os.ReadFile(rc)
	if strings.Contains(string(content), BlockStart) {
		t.Fatal("startup file must not be touched when the shell already agrees")
	}
}

func TestEnsureAddsOneBlockAndBacksUpTheOriginal(t *testing.T) {
	home := t.TempDir()
	backups := filepath.Join(home, "backups")
	launcher := filepath.Join(home, ".local", "bin", "codex")
	writeExecutable(t, launcher)
	npm := filepath.Join(home, "npm", "codex")
	writeExecutable(t, npm)
	rc := filepath.Join(home, ".zshrc")
	if err := os.WriteFile(rc, []byte("export EDITOR=vim"), 0o600); err != nil {
		t.Fatal(err)
	}

	resolved := npm
	ensurer := &Ensurer{
		HomeDir: home, Shell: "/bin/zsh", BackupDir: backups,
		Lookup:     func(context.Context, string) (string, bool) { return resolved, true },
		Invalidate: func() { resolved = launcher },
	}
	if err := ensurer.Ensure(context.Background(), "codex", launcher); err != nil {
		t.Fatalf("ensure: %v", err)
	}

	content, _ := os.ReadFile(rc)
	text := string(content)
	if !strings.HasPrefix(text, "export EDITOR=vim\n") {
		t.Fatalf("existing content must be kept verbatim: %q", text)
	}
	if strings.Count(text, BlockStart) != 1 || !strings.Contains(text, `export PATH="$HOME/.local/bin:$PATH"`) {
		t.Fatalf("expected exactly one block: %q", text)
	}
	info, err := os.Stat(rc)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode must be preserved: %v %v", info, err)
	}
	entries, err := os.ReadDir(backups)
	if err != nil || len(entries) != 1 {
		t.Fatalf("expected one backup, got %v (%v)", entries, err)
	}
	backup, _ := os.ReadFile(filepath.Join(backups, entries[0].Name()))
	if string(backup) != "export EDITOR=vim" {
		t.Fatalf("backup must hold the original: %q", backup)
	}
}

func TestEnsureFailsWhenTheShellStillResolvesAnotherCopy(t *testing.T) {
	// 另一个启动文件(比如 .zprofile 里的 nvm)排在更前面:加了块也没用,必须如实报错,
	// 否则接下来写的配置会让用户终端里的旧 CLI 起不来。
	home := t.TempDir()
	launcher := filepath.Join(home, ".local", "bin", "codex")
	writeExecutable(t, launcher)
	npm := filepath.Join(home, "npm", "codex")
	writeExecutable(t, npm)
	ensurer := &Ensurer{
		HomeDir: home, Shell: "/bin/zsh",
		Lookup: func(context.Context, string) (string, bool) { return npm, true },
	}
	if err := ensurer.Ensure(context.Background(), "codex", launcher); !errors.Is(err, ErrNotApplied) {
		t.Fatalf("expected ErrNotApplied, got %v", err)
	}
	// 块只加一次:再次调用时发现已存在,直接报未生效,不重复往用户文件里追加。
	if err := ensurer.Ensure(context.Background(), "codex", launcher); !errors.Is(err, ErrNotApplied) {
		t.Fatalf("expected ErrNotApplied on retry, got %v", err)
	}
	content, _ := os.ReadFile(filepath.Join(home, ".zshrc"))
	if strings.Count(string(content), BlockStart) != 1 {
		t.Fatalf("block must not be duplicated: %q", content)
	}
}

func TestEnsureRejectsShellsWithoutAKnownStartupFile(t *testing.T) {
	home := t.TempDir()
	ensurer := &Ensurer{
		HomeDir: home, Shell: "/usr/local/bin/nushell",
		Lookup: func(context.Context, string) (string, bool) { return "", false },
	}
	if err := ensurer.Ensure(context.Background(), "codex", filepath.Join(home, "codex")); !errors.Is(err, ErrUnsupportedShell) {
		t.Fatalf("expected ErrUnsupportedShell, got %v", err)
	}
}

func writeExecutable(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}
