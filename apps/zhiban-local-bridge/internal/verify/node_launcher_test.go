//go:build !windows

package verify

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// 2026-09-14: a Codex installed with npm under nvm is `#!/usr/bin/env node`.
// The L3 probe runs with a sanitized PATH, so without the Node prefix on it
// the CLI never starts and a working switch shows "无法连接".
func TestVerifyRunsAnNpmLauncherWithTheNodeOfItsPrefix(t *testing.T) {
	prefix := filepath.Join(t.TempDir(), ".nvm", "versions", "node", "v24.0.0")
	node := filepath.Join(prefix, "bin", "node")
	codexJS := filepath.Join(prefix, "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
	for path, content := range map[string]string{
		// Stand-in for node: run the "JavaScript" file as a shell script.
		node:    "#!/bin/sh\nscript=\"$1\"; shift; exec /bin/sh \"$script\" \"$@\"\n",
		codexJS: "#!/usr/bin/env node\n" + strings.SplitN(successScript, "\n", 2)[1],
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	f := newFixture(t, successScript, func(config *ManagerConfig) {
		resolve := config.ResolveInstallation
		config.ResolveInstallation = func(ctx context.Context, targetID, installationID string) (Installation, error) {
			installation, err := resolve(ctx, targetID, installationID)
			installation.Executable = codexJS
			return installation, err
		}
	})

	final := f.execute(t, TargetCodexCLI)
	if final.State != operation.StateSucceeded {
		t.Fatalf("npm launcher final = %+v", final)
	}
	path := ""
	for _, item := range f.invocation.Environment {
		if value, ok := strings.CutPrefix(item, "PATH="); ok {
			path = value
		}
	}
	canonical, _ := filepath.EvalSymlinks(filepath.Dir(node))
	if !strings.HasPrefix(path, canonical+":") && !strings.HasPrefix(path, filepath.Dir(node)+":") {
		t.Fatalf("PATH = %q, want the Node prefix first", path)
	}
}
