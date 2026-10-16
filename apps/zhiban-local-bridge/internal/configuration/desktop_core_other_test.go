//go:build !windows

package configuration

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestCodexDesktopNestedCoreSwitchAndCatalog(t *testing.T) {
	f := newGlobalFixture(t)
	bundle, _ := f.withDesktop(t)
	if err := os.Remove(filepath.Join(bundle, "Contents", "Resources", "codex")); err != nil {
		t.Fatal(err)
	}
	core := writeExecutable(t, filepath.Join(bundle, "Contents", "Resources", "codex-cli", "CodexCLI.app", "Contents", "MacOS", "codex"))
	f.manager.probeGlobalFunc = func(_ context.Context, installation Installation) error {
		if installation.Executable != core {
			t.Fatalf("probed %q, want %q", installation.Executable, core)
		}
		return nil
	}
	status := f.switchTo(t, TargetCodexDesktop)
	if !status.GlobalSwitched {
		t.Fatal("desktop was not switched")
	}
	f.manager.codexExecutables = func(context.Context) ([]string, error) { return []string{bundle}, nil }
	entries, ok := f.manager.localCodexExecutables(context.Background(), true)
	if !ok || len(entries) != 1 || entries[0].Path != core {
		t.Fatalf("catalog cores = %+v, %v", entries, ok)
	}
}

func TestCodexDesktopRejectsUnsafeNestedCore(t *testing.T) {
	for _, kind := range []string{"symlink", "writable", "nonexecutable", "parent_symlink"} {
		t.Run(kind, func(t *testing.T) {
			f := newGlobalFixture(t)
			bundle, _ := f.withDesktop(t) // a safe old core must not hide an unsafe new one
			core := filepath.Join(bundle, "Contents", "Resources", "codex-cli", "CodexCLI.app", "Contents", "MacOS", "codex")
			writeExecutable(t, core)
			switch kind {
			case "symlink":
				if err := os.Remove(core); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(f.helper, core); err != nil {
					t.Fatal(err)
				}
			case "writable":
				if err := os.Chmod(core, 0o777); err != nil {
					t.Fatal(err)
				}
			case "nonexecutable":
				if err := os.Chmod(core, 0o644); err != nil {
					t.Fatal(err)
				}
			case "parent_symlink":
				parent := filepath.Dir(core)
				if err := os.Rename(parent, parent+"-real"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(parent+"-real", parent); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := desktopProbeInstallation(f.installs[TargetCodexDesktop]); !errors.Is(err, ErrInstallationChanged) {
				t.Fatalf("error = %v", err)
			}
		})
	}
}
