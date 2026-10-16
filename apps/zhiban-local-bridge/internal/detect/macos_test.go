package detect

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func TestMacOSDiscovererClassifiesClaudeNativeAndDeduplicatesSymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()

	home := t.TempDir()
	realBinary := filepath.Join(home, ".local", "share", "claude", "versions", "2.1.263")
	launcher := filepath.Join(home, ".local", "bin", "claude")
	mustWriteExecutable(t, realBinary, "#!/bin/sh\nprintf '2.1.263 (Claude Code)\\n'\n")
	if err := os.MkdirAll(filepath.Dir(launcher), 0o700); err != nil {
		t.Fatalf("MkdirAll launcher: %v", err)
	}
	if err := os.Symlink(realBinary, launcher); err != nil {
		t.Fatalf("Symlink launcher: %v", err)
	}

	discoverer := NewMacOSDiscoverer(home)
	discoverer.SystemCandidates = map[string][]string{TargetClaudeCLI: nil, TargetCodexCLI: nil}
	discoverer.LookPath = func(name string) (string, error) {
		if name != "claude" {
			t.Fatalf("LookPath name = %q", name)
		}
		return launcher, nil
	}
	candidates, err := discoverer.Discover(context.Background(), TargetClaudeCLI)
	if err != nil {
		t.Fatalf("Discover() error = %v", err)
	}
	if len(candidates) != 1 {
		t.Fatalf("candidates = %+v, want one", candidates)
	}
	canonicalBinary, err := filepath.EvalSymlinks(realBinary)
	if err != nil {
		t.Fatalf("EvalSymlinks binary: %v", err)
	}
	if candidates[0].Source != SourceOfficial || candidates[0].RealPath != canonicalBinary {
		t.Fatalf("candidate = %+v", candidates[0])
	}
}

func TestMacOSDiscovererClassifiesNPMAndHomebrew(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	tests := []struct {
		name     string
		target   string
		path     string
		realPath string
		want     InstallSource
	}{
		{
			name: "codex official standalone", target: TargetCodexCLI,
			path:     filepath.Join(home, ".local", "bin", "codex"),
			realPath: filepath.Join(home, ".codex", "packages", "standalone", "current", "bin", "codex"),
			want:     SourceOfficial,
		},
		{
			name: "codex npm", target: TargetCodexCLI,
			path:     filepath.Join(home, ".nvm", "versions", "node", "v24.0.0", "bin", "codex"),
			realPath: filepath.Join(home, ".nvm", "versions", "node", "v24.0.0", "lib", "node_modules", "@openai", "codex", "bin", "codex"),
			want:     SourceNPM,
		},
		{
			name: "claude npm", target: TargetClaudeCLI,
			path:     filepath.Join(home, ".nvm", "versions", "node", "v24.0.0", "bin", "claude"),
			realPath: filepath.Join(home, ".nvm", "versions", "node", "v24.0.0", "lib", "node_modules", "@anthropic-ai", "claude-code", "cli", "claude"),
			want:     SourceNPM,
		},
		{
			name: "homebrew", target: TargetCodexCLI,
			path: "/opt/homebrew/bin/codex", realPath: "/opt/homebrew/Caskroom/codex/0.153.4/codex-aarch64-apple-darwin",
			want: SourceHomebrew,
		},
		{
			name: "spoofed npm launcher", target: TargetCodexCLI,
			path:     filepath.Join(home, ".nvm", "versions", "node", "v24.0.0", "bin", "codex"),
			realPath: filepath.Join(home, "Downloads", "untrusted-codex"),
			want:     SourceUnknown,
		},
		{
			name: "spoofed homebrew launcher", target: TargetClaudeCLI,
			path: "/opt/homebrew/bin/claude", realPath: filepath.Join(home, "Downloads", "untrusted-claude"),
			want: SourceUnknown,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := classifyMacOSSource(tt.target, tt.path, tt.realPath, home); got != tt.want {
				t.Fatalf("classifyMacOSSource() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestMacOSDiscovererRejectsErrDotWithoutExecutingCandidate(t *testing.T) {
	t.Parallel()

	discoverer := NewMacOSDiscoverer(t.TempDir())
	discoverer.SystemCandidates = map[string][]string{TargetClaudeCLI: nil, TargetCodexCLI: nil}
	discoverer.LookPath = func(string) (string, error) {
		return "codex", &exec.Error{Name: "codex", Err: exec.ErrDot}
	}
	_, err := discoverer.Discover(context.Background(), TargetCodexCLI)
	if !errors.Is(err, ErrUntrustedSearchPath) {
		t.Fatalf("Discover() error = %v, want ErrUntrustedSearchPath", err)
	}
}

func TestMacOSDiscovererMarksUnknownAndSkipsWorldWritableFiles(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()

	home := t.TempDir()
	unknown := filepath.Join(home, "bin", "codex")
	mustWriteExecutable(t, unknown, "#!/bin/sh\nexit 0\n")
	discoverer := NewMacOSDiscoverer(home)
	discoverer.SystemCandidates = map[string][]string{TargetClaudeCLI: nil, TargetCodexCLI: nil}
	discoverer.LookPath = func(string) (string, error) { return unknown, nil }
	candidates, err := discoverer.Discover(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("Discover() error = %v", err)
	}
	if len(candidates) != 1 || candidates[0].Source != SourceUnknown {
		t.Fatalf("candidates = %+v", candidates)
	}

	if err := os.Chmod(unknown, 0o777); err != nil {
		t.Fatalf("Chmod: %v", err)
	}
	candidates, err = discoverer.Discover(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("Discover() world writable error = %v", err)
	}
	if len(candidates) != 0 {
		t.Fatalf("world writable candidates = %+v, want none", candidates)
	}
}

func mustWriteExecutable(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
}

func TestMacOSDiscovererPrefersTheLoginShellResolution(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	nvmPackage := filepath.Join(home, ".nvm", "versions", "node", "v24.0.0", "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
	nvmLauncher := filepath.Join(home, ".nvm", "versions", "node", "v24.0.0", "bin", "codex")
	official := filepath.Join(home, ".codex", "packages", "standalone", "0.144.1", "bin", "codex")
	officialLauncher := filepath.Join(home, ".local", "bin", "codex")
	mustWriteExecutable(t, nvmPackage, "#!/bin/sh\nexit 0\n")
	mustWriteExecutable(t, official, "#!/bin/sh\nexit 0\n")
	mustSymlink(t, nvmPackage, nvmLauncher)
	mustSymlink(t, official, officialLauncher)

	discoverer := NewMacOSDiscoverer(home)
	discoverer.SystemCandidates = map[string][]string{TargetClaudeCLI: nil, TargetCodexCLI: nil}
	discoverer.LookPath = func(string) (string, error) { return "", &exec.Error{Name: "codex", Err: exec.ErrNotFound} }
	discoverer.ShellLookup = func(_ context.Context, name string) (string, bool) {
		if name != "codex" {
			t.Fatalf("ShellLookup name = %q", name)
		}
		return nvmLauncher, true
	}
	candidates, err := discoverer.Discover(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("Discover() error = %v", err)
	}
	if len(candidates) != 2 {
		t.Fatalf("candidates = %+v, want two", candidates)
	}
	if !candidates[0].Preferred || candidates[0].Source != SourceNPM || candidates[1].Preferred || candidates[1].Source != SourceOfficial {
		t.Fatalf("candidates = %+v", candidates)
	}

	// A relative answer (alias, function, PATH containing ".") is not a path.
	discoverer.ShellLookup = func(context.Context, string) (string, bool) { return "codex", true }
	candidates, err = discoverer.Discover(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("Discover(relative) error = %v", err)
	}
	for _, candidate := range candidates {
		if candidate.Preferred {
			t.Fatalf("relative shell answer marked preferred: %+v", candidates)
		}
	}
}

func TestMacOSDiscovererFindsInstallsOutsideTheDefaultLocations(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		target   string
		launcher func(home string) string
		real     func(home string) string
	}{
		{
			name: "bun global", target: TargetCodexCLI,
			launcher: func(h string) string { return filepath.Join(h, ".bun", "bin", "codex") },
			real: func(h string) string {
				return filepath.Join(h, ".bun", "install", "global", "node_modules", "@openai", "codex", "bin", "codex.js")
			},
		},
		{
			name: "claude local installer", target: TargetClaudeCLI,
			launcher: func(h string) string { return filepath.Join(h, ".claude", "local", "node_modules", ".bin", "claude") },
			real: func(h string) string {
				return filepath.Join(h, ".claude", "local", "node_modules", "@anthropic-ai", "claude-code", "cli.js")
			},
		},
		{
			name: "asdf nodejs", target: TargetClaudeCLI,
			launcher: func(h string) string {
				return filepath.Join(h, ".asdf", "installs", "nodejs", "22.1.0", "bin", "claude")
			},
			real: func(h string) string {
				return filepath.Join(h, ".asdf", "installs", "nodejs", "22.1.0", "lib", "node_modules", "@anthropic-ai", "claude-code", "cli.js")
			},
		},
		{
			name: "mise node", target: TargetCodexCLI,
			launcher: func(h string) string {
				return filepath.Join(h, ".local", "share", "mise", "installs", "node", "22.1.0", "bin", "codex")
			},
			real: func(h string) string {
				return filepath.Join(h, ".local", "share", "mise", "installs", "node", "22.1.0", "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
			},
		},
		{
			name: "fnm node", target: TargetCodexCLI,
			launcher: func(h string) string {
				return filepath.Join(h, "Library", "Application Support", "fnm", "node-versions", "v22.1.0", "installation", "bin", "codex")
			},
			real: func(h string) string {
				return filepath.Join(h, "Library", "Application Support", "fnm", "node-versions", "v22.1.0", "installation", "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
			},
		},
		{
			name: "volta package", target: TargetCodexCLI,
			launcher: func(h string) string {
				return filepath.Join(h, ".volta", "tools", "image", "packages", "@openai", "codex", "bin", "codex")
			},
			real: func(h string) string {
				return filepath.Join(h, ".volta", "tools", "image", "packages", "@openai", "codex", "lib", "node_modules", "@openai", "codex", "bin", "codex.js")
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			home := t.TempDir()
			mustWriteExecutable(t, tt.real(home), "#!/bin/sh\nexit 0\n")
			mustSymlink(t, tt.real(home), tt.launcher(home))
			discoverer := NewMacOSDiscoverer(home)
			discoverer.SystemCandidates = map[string][]string{TargetClaudeCLI: nil, TargetCodexCLI: nil}
			discoverer.LookPath = func(name string) (string, error) {
				return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
			}
			candidates, err := discoverer.Discover(context.Background(), tt.target)
			if err != nil {
				t.Fatalf("Discover() error = %v", err)
			}
			if len(candidates) != 1 || candidates[0].Source != SourceNPM {
				t.Fatalf("candidates = %+v, want one npm install", candidates)
			}
		})
	}
}

func mustSymlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatalf("Symlink: %v", err)
	}
}
