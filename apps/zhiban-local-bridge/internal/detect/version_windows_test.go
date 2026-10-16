//go:build windows

package detect

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A real Windows executable replaces the POSIX /bin/sh process fixture.
func TestMain(m *testing.M) {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		if os.Getenv("SECRET_SHOULD_NOT_LEAK") != "" {
			os.Exit(9)
		}
		switch filepath.Base(os.Args[0]) {
		case "slow.exe":
			time.Sleep(time.Second)
		case "failing.exe":
			os.Exit(9)
		case "coldstart.exe":
			// Like a binary the security software scans on first launch:
			// slow once, instant afterwards.
			marker := filepath.Join(filepath.Dir(os.Args[0]), "coldstart.marker")
			if _, err := os.Stat(marker); err != nil {
				_ = os.WriteFile(marker, nil, 0o600)
				time.Sleep(600 * time.Millisecond)
			}
		}
		fmt.Println("2.1.267 (Claude Code)")
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestWindowsVersionProberEnvironmentTimeoutAndFailure(t *testing.T) {
	t.Setenv("SECRET_SHOULD_NOT_LEAK", "test-only-marker")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for _, name := range []string{"normal.exe", "slow.exe", "failing.exe"} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, content, 0o700); err != nil {
			t.Fatal(err)
		}
		budget := 5 * time.Second
		if name == "slow.exe" {
			budget = 20 * time.Millisecond
		}
		prober := VersionProber{Timeout: budget, HomeDir: dir}
		version, err := prober.Probe(context.Background(), TargetClaudeCLI, Candidate{Path: path, RealPath: path, Source: SourceOfficial})
		switch name {
		case "normal.exe":
			if err != nil || version != "2.1.267" {
				t.Fatalf("probe = %q, %v", version, err)
			}
		case "slow.exe":
			if !errors.Is(err, ErrProbeTimeout) {
				t.Fatalf("timeout = %v", err)
			}
		case "failing.exe":
			if !errors.Is(err, ErrProbeFailed) {
				t.Fatalf("failure = %v", err)
			}
		}
	}
}

// A first launch held by the on-access scanner runs out of the probe budget;
// the retry lands on a warm cache and must succeed instead of reporting
// DETECT-TIMEOUT. A binary that is slow every time still times out.
func TestWindowsVersionProberRetriesOnceAfterColdStart(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for _, name := range []string{"coldstart.exe", "slow.exe"} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, content, 0o700); err != nil {
			t.Fatal(err)
		}
		prober := WindowsVersionProber{Timeout: 200 * time.Millisecond, HomeDir: dir}
		version, err := prober.Probe(context.Background(), TargetClaudeCLI, Candidate{Path: path, RealPath: path, Source: SourceOfficial})
		switch name {
		case "coldstart.exe":
			if err != nil || version != "2.1.267" {
				t.Fatalf("cold start probe = %q, %v", version, err)
			}
			if _, err := os.Stat(filepath.Join(dir, "coldstart.marker")); err != nil {
				t.Fatalf("first attempt did not run: %v", err)
			}
		case "slow.exe":
			if !errors.Is(err, ErrProbeTimeout) {
				t.Fatalf("always-slow probe = %q, %v", version, err)
			}
		}
	}
}
