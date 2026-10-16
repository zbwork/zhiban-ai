//go:build !windows

package shellenv

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeShellTimeout is generous: macOS assesses a freshly written executable on
// its first run, which takes seconds when the whole suite runs in parallel.
const fakeShellTimeout = 10 * time.Second

func writeExecutable(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
		t.Fatal(err)
	}
}

func TestLoginShellLookupParsesOnlyAbsolutePathsDespiteNoise(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	counter := filepath.Join(home, "runs")
	shell := filepath.Join(home, "fake-shell")
	// The fake "login shell" behaves like a noisy rc file: banners, escape
	// sequences, an alias for claude. It records every run.
	writeExecutable(t, shell, "#!/bin/sh\n"+
		"echo run >> '"+counter+"'\n"+
		"printf 'Welcome back\\n\\033]0;title\\007'\n"+
		"printf '__ZHIBAN_LOOKUP__codex=/opt/tools/bin/codex\\n'\n"+
		"printf '__ZHIBAN_LOOKUP__claude=alias claude=~/.claude/local/claude\\n'\n"+
		"printf '__ZHIBAN_LOOKUP__node=/opt/node/bin/node\\n'\n")
	lookup := &LoginShellLookup{HomeDir: home, Shell: shell, Timeout: fakeShellTimeout, TTL: time.Minute}

	if path, ok := lookup.Lookup(context.Background(), "codex"); !ok || path != "/opt/tools/bin/codex" {
		t.Fatalf("Lookup(codex) = %q, %v", path, ok)
	}
	if path, ok := lookup.Lookup(context.Background(), "claude"); ok {
		t.Fatalf("Lookup(claude alias) = %q, want no path", path)
	}
	if path, ok := lookup.Lookup(context.Background(), "node"); !ok || path != "/opt/node/bin/node" {
		t.Fatalf("Lookup(node) = %q, %v", path, ok)
	}
	runs, _ := os.ReadFile(counter)
	if strings.Count(string(runs), "run") != 1 {
		t.Fatalf("shell ran %q times, want once for every name", runs)
	}
	var none *LoginShellLookup
	if _, ok := none.Lookup(context.Background(), "codex"); ok {
		t.Fatal("a nil lookup must answer nothing")
	}
}

func TestLoginShellLookupGivesUpAtTheTimeout(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	shell := filepath.Join(home, "slow-shell")
	writeExecutable(t, shell, "#!/bin/sh\nsleep 30 &\nsleep 30\n")
	lookup := &LoginShellLookup{HomeDir: home, Shell: shell, Timeout: 200 * time.Millisecond, TTL: time.Minute}

	started := time.Now()
	if path, ok := lookup.Lookup(context.Background(), "codex"); ok {
		t.Fatalf("Lookup() = %q, want nothing", path)
	}
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatalf("Lookup() took %s", elapsed)
	}
}

func TestLoginShellFallsBackWhenSHELLIsNotARegisteredShell(t *testing.T) {
	t.Parallel()
	shells := "# comment\n/bin/bash\n/bin/zsh\n"
	if got := chooseLoginShell("/bin/bash", shells); got != "/bin/bash" {
		t.Fatalf("registered shell = %q", got)
	}
	for _, value := range []string{"", "bash", "/tmp/evil-shell", "/bin/zsh -x"} {
		if got := chooseLoginShell(value, shells); got != "/bin/zsh" {
			t.Fatalf("chooseLoginShell(%q) = %q, want /bin/zsh", value, got)
		}
	}
}

func TestNodeDirsFindsThePrefixNodeThenTheLoginShellNode(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	// nvm-style prefix: node sits in the bin next to the npm launcher.
	nvm := filepath.Join(home, ".nvm", "versions", "node", "v24.0.0")
	writeExecutable(t, filepath.Join(nvm, "bin", "node"), "#!/bin/sh\n")
	codexJS := filepath.Join(nvm, "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
	writeExecutable(t, codexJS, "#!/usr/bin/env node\n")
	launcher := filepath.Join(nvm, "bin", "codex")
	if err := os.Symlink(codexJS, launcher); err != nil {
		t.Fatal(err)
	}
	if got := NodeDirs(context.Background(), launcher, nil); len(got) != 1 || got[0] != filepath.Join(nvm, "bin") {
		// EvalSymlinks may canonicalise the temp dir (/private/var on macOS).
		if len(got) != 1 || !strings.HasSuffix(got[0], filepath.Join(".nvm", "versions", "node", "v24.0.0", "bin")) {
			t.Fatalf("NodeDirs(nvm launcher) = %v", got)
		}
	}

	// Custom npm prefix: no node beside the package; the login shell's node.
	custom := filepath.Join(home, ".npm-global", "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
	writeExecutable(t, custom, "#!/usr/bin/env node\n")
	shellNode := filepath.Join(home, "runtimes", "node", "bin", "node")
	writeExecutable(t, shellNode, "#!/bin/sh\n")
	shell := filepath.Join(home, "fake-shell")
	writeExecutable(t, shell, "#!/bin/sh\nprintf '__ZHIBAN_LOOKUP__node="+shellNode+"\\n'\n")
	lookup := &LoginShellLookup{HomeDir: home, Shell: shell, Timeout: fakeShellTimeout, TTL: time.Minute}
	got := NodeDirs(context.Background(), custom, lookup)
	if len(got) != 1 || got[0] != filepath.Dir(shellNode) {
		t.Fatalf("NodeDirs(custom prefix) = %v", got)
	}

	// Not a node script (native binary, shell script): nothing is added and
	// the login shell is not even asked.
	native := filepath.Join(home, ".local", "share", "claude", "versions", "2.1.270")
	writeExecutable(t, native, "\xcf\xfa\xed\xfe native")
	if got := NodeDirs(context.Background(), native, lookup); len(got) != 0 {
		t.Fatalf("NodeDirs(native) = %v", got)
	}
}

func TestPrependPath(t *testing.T) {
	t.Parallel()
	env := []string{"HOME=/h", "PATH=/usr/bin:/bin"}
	got := PrependPath(env, []string{"/n/bin", "/m/bin"})
	if got[1] != "PATH=/n/bin:/m/bin:/usr/bin:/bin" || env[1] != "PATH=/usr/bin:/bin" {
		t.Fatalf("PrependPath() = %v (input %v)", got, env)
	}
	if got := PrependPath([]string{"HOME=/h"}, []string{"/n/bin"}); got[1] != "PATH=/n/bin" {
		t.Fatalf("PrependPath(no PATH) = %v", got)
	}
}
