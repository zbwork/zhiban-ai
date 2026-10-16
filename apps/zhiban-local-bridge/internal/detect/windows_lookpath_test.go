//go:build windows

package detect

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The discoverer's lookup answers from the registry PATH (what a new terminal
// runs) before this process's PATH (the snapshot Zhiban started with).
func TestRegistryLookPathPrefersRegistryThenProcessPath(t *testing.T) {
	dir := t.TempDir()
	registryCopy := filepath.Join(dir, "registry", "codex.cmd")
	processCopy := filepath.Join(dir, "process", "codex.cmd")
	for _, path := range []string{registryCopy, processCopy} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("@echo off\r\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", filepath.Dir(processCopy))
	t.Setenv("PATHEXT", ".COM;.EXE;.BAT;.CMD")

	previous := registryResolve
	t.Cleanup(func() { registryResolve = previous })

	registryResolve = func(name string) (string, bool) { return registryCopy, name == "codex" }
	if resolved, err := registryLookPath("codex"); err != nil || !strings.EqualFold(resolved, registryCopy) {
		t.Fatalf("registry answer = %q, %v", resolved, err)
	}

	registryResolve = func(string) (string, bool) { return "", false }
	if resolved, err := registryLookPath("codex"); err != nil || !strings.EqualFold(resolved, processCopy) {
		t.Fatalf("process PATH fallback = %q, %v", resolved, err)
	}

	if _, err := registryLookPath("no-such-cli"); err == nil {
		t.Fatal("missing command must fail like exec.LookPath")
	} else if _, isExecError := err.(*exec.Error); !isExecError {
		t.Fatalf("missing command error = %T, want *exec.Error", err)
	}
}
