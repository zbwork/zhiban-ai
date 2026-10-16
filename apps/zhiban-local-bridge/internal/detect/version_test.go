package detect

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestParseVersion(t *testing.T) {
	t.Parallel()

	tests := []struct {
		target string
		output string
		want   string
	}{
		{target: TargetCodexCLI, output: "codex-cli 0.153.4\n", want: "0.153.4"},
		{target: TargetCodexCLI, output: "codex 0.154.0-alpha.3", want: "0.154.0-alpha.3"},
		{target: TargetClaudeCLI, output: "2.1.263 (Claude Code)\n", want: "2.1.263"},
	}
	for _, tt := range tests {
		if got, err := parseVersion(tt.target, []byte(tt.output)); err != nil || got != tt.want {
			t.Fatalf("parseVersion(%q, %q) = %q, %v; want %q", tt.target, tt.output, got, err, tt.want)
		}
	}
	if _, err := parseVersion(TargetCodexCLI, []byte("development build")); !errors.Is(err, ErrVersionUnrecognized) {
		t.Fatalf("parseVersion() error = %v, want ErrVersionUnrecognized", err)
	}
}

func readTestFile(t *testing.T, path string) string {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%q): %v", path, err)
	}
	return string(content)
}

func TestVersionProberRunsFixedVersionArgumentWithBoundedEnvironment(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Setenv("SECRET_SHOULD_NOT_LEAK", "super-secret")
	dir := t.TempDir()
	argsFile := filepath.Join(dir, "args")
	envFile := filepath.Join(dir, "env")
	executable := filepath.Join(dir, "codex")
	mustWriteExecutable(t, executable, "#!/bin/sh\nprintf '%s' \"$*\" > '"+argsFile+"'\nprintf '%s' \"${SECRET_SHOULD_NOT_LEAK-}\" > '"+envFile+"'\nprintf 'codex-cli 0.153.4\\n'\n")

	// This case validates fixed argv and the bounded environment, not timeout
	// behavior. Leave enough headroom for cold, cross-package test builds on
	// loaded macOS runners; the dedicated timeout case below uses 20 ms.
	prober := VersionProber{Timeout: 5 * time.Second, HomeDir: dir}
	version, err := prober.Probe(context.Background(), TargetCodexCLI, Candidate{Path: executable, RealPath: executable, Source: SourceNPM})
	if err != nil {
		t.Fatalf("Probe() error = %v", err)
	}
	if version != "0.153.4" {
		t.Fatalf("version = %q", version)
	}
	if got := readTestFile(t, argsFile); got != "--version" {
		t.Fatalf("args = %q, want --version", got)
	}
	if got := readTestFile(t, envFile); got != "" {
		t.Fatalf("inherited secret = %q, want empty", got)
	}
}

func TestVersionProberMapsTimeoutAndCommandFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()

	dir := t.TempDir()
	slow := filepath.Join(dir, "slow")
	failing := filepath.Join(dir, "failing")
	mustWriteExecutable(t, slow, "#!/bin/sh\nexec sleep 1\n")
	mustWriteExecutable(t, failing, "#!/bin/sh\nexit 9\n")

	timeoutProber := VersionProber{Timeout: 20 * time.Millisecond, HomeDir: dir}
	_, err := timeoutProber.Probe(context.Background(), TargetClaudeCLI, Candidate{Path: slow, RealPath: slow, Source: SourceOfficial})
	if !errors.Is(err, ErrProbeTimeout) {
		t.Fatalf("slow Probe() error = %v, want ErrProbeTimeout", err)
	}
	failureProber := VersionProber{Timeout: 5 * time.Second, HomeDir: dir}
	_, err = failureProber.Probe(context.Background(), TargetClaudeCLI, Candidate{Path: failing, RealPath: failing, Source: SourceOfficial})
	if !errors.Is(err, ErrProbeFailed) {
		t.Fatalf("failing Probe() error = %v, want ErrProbeFailed", err)
	}
}
