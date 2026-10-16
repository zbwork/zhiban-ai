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

// An official standalone Codex install is held to the publisher's package
// shape: without bin/codex-code-mode-host beside it Codex refuses Code Mode
// on every session, so the probe reports the layout incomplete (repairable)
// instead of a version. npm installs are not the Bridge's layout to judge.
func TestVersionProberReportsIncompleteCodexLayoutForOfficialInstalls(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell scripts")
	}
	home := t.TempDir()
	binDir := filepath.Join(home, ".codex", "packages", "standalone", "0.153.4", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(binDir, "codex")
	mustWriteExecutable(t, executable, "#!/bin/sh\nprintf 'codex-cli 0.153.4\\n'\n")
	prober := VersionProber{Timeout: 5 * time.Second, HomeDir: home}

	official := Candidate{Path: filepath.Join(home, ".local", "bin", "codex"), RealPath: executable, Source: SourceOfficial}
	if _, err := prober.Probe(context.Background(), TargetCodexCLI, official); !errors.Is(err, ErrLayoutIncomplete) {
		t.Fatalf("Probe(bare official binary) error = %v, want ErrLayoutIncomplete", err)
	}
	if CodexLayoutComplete(executable) {
		t.Fatal("CodexLayoutComplete() must be false without the host")
	}
	// The same bare binary from npm is probed normally.
	npm := Candidate{Path: executable, RealPath: executable, Source: SourceNPM}
	if version, err := prober.Probe(context.Background(), TargetCodexCLI, npm); err != nil || version != "0.153.4" {
		t.Fatalf("Probe(npm) = %q, %v", version, err)
	}
	// A host that is not executable does not count; an executable one does.
	host := filepath.Join(binDir, "codex-code-mode-host")
	if err := os.WriteFile(host, []byte("#!/bin/sh\nexit 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := prober.Probe(context.Background(), TargetCodexCLI, official); !errors.Is(err, ErrLayoutIncomplete) {
		t.Fatalf("Probe(non-executable host) error = %v, want ErrLayoutIncomplete", err)
	}
	if err := os.Chmod(host, 0o755); err != nil {
		t.Fatal(err)
	}
	if version, err := prober.Probe(context.Background(), TargetCodexCLI, official); err != nil || version != "0.153.4" {
		t.Fatalf("Probe(complete layout) = %q, %v", version, err)
	}
	if !CodexLayoutComplete(executable) {
		t.Fatal("CodexLayoutComplete() must be true with the host")
	}
}
