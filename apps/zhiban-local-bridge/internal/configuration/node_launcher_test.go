//go:build !windows

package configuration

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// 2026-09-14: the post-switch probe runs `codex mcp list` with a sanitized
// PATH. For an npm launcher (`#!/usr/bin/env node`) that PATH must carry the
// Node of the package's prefix, or a good switch is rolled back as
// "切换未完成，原有配置已保留".
func TestGlobalProbeRunsAnNpmLauncherWithTheNodeOfItsPrefix(t *testing.T) {
	// Not parallel: the probe runs freshly written scripts under the real
	// probe timeout, and macOS assesses new executables on their first run.
	f := newGlobalFixture(t)
	f.manager.probeGlobalFunc = nil

	write := func(path, content string) {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	withNode := filepath.Join(f.home, ".nvm", "versions", "node", "v24.0.0")
	write(filepath.Join(withNode, "bin", "node"), "#!/bin/sh\nexit 0\n")
	launcher := filepath.Join(withNode, "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
	write(launcher, "#!/usr/bin/env node\n")
	if err := f.manager.probeGlobal(context.Background(), Installation{TargetID: TargetCodexCLI, Executable: launcher}); err != nil {
		t.Fatalf("probeGlobal(npm launcher with prefix node) error = %v", err)
	}

	// No node anywhere the Bridge can find: the probe still fails closed.
	orphan := filepath.Join(f.home, ".npm-global", "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
	write(orphan, "#!/usr/bin/env node\n")
	if err := f.manager.probeGlobal(context.Background(), Installation{TargetID: TargetCodexCLI, Executable: orphan}); !errors.Is(err, ErrValidationFailed) {
		t.Fatalf("probeGlobal(npm launcher without node) error = %v", err)
	}
}
