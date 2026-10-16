//go:build windows

package detect

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// WindowsVersionProber runs "<cli> --version". Unlike the macOS prober it must
// account for Windows realities: npm ships the CLI as a .cmd shim that only
// runs through cmd.exe, and node-based CLIs need a real Windows environment
// (SystemRoot, ComSpec, PATHEXT, the user profile dirs, the full PATH) to start
// at all. It inherits the Bridge's already-curated, secret-free environment
// rather than rebuilding a trimmed one.
type WindowsVersionProber struct {
	Timeout time.Duration
	HomeDir string
}

// windowsProbeTimeout is the budget for one "<cli> --version" run. Warm, the
// CLIs answer in 25–80 ms; the budget only matters on the first launch of a
// 200–300 MB executable the security software has not scanned yet (YunShu +
// Defender on the 2026-09-17 test machine: 4.2–4.4 s cold, then 30 ms).
const windowsProbeTimeout = 8 * time.Second

func (p WindowsVersionProber) Probe(ctx context.Context, targetID string, candidate Candidate) (string, error) {
	if codexLayoutIncomplete(targetID, candidate) {
		return "", ErrLayoutIncomplete
	}
	version, err := p.probeOnce(ctx, targetID, candidate)
	if errors.Is(err, ErrProbeTimeout) && ctx.Err() == nil {
		// A cold start that ran out of budget has still filled the scanner's
		// cache, so one more attempt answers in milliseconds. Without it the
		// timeout was reported as DETECT-TIMEOUT ("需要处理") on every first
		// detection after a reboot, a definitions update or a fresh install,
		// and right after placing a version made pick() fall back to an older
		// copy that happened to be warm (2026-09-18 Windows 12800).
		version, err = p.probeOnce(ctx, targetID, candidate)
	}
	return version, err
}

func (p WindowsVersionProber) probeOnce(ctx context.Context, targetID string, candidate Candidate) (string, error) {
	timeout := p.Timeout
	if timeout <= 0 || timeout > 2*windowsProbeTimeout {
		timeout = windowsProbeTimeout
	}
	probeContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	command := windowsProbeCommand(probeContext, candidate.RealPath)
	command.Dir = p.HomeDir
	command.Env = windowsProbeEnv(candidate)
	var output cappedBuffer
	command.Stdout = &output
	command.Stderr = &cappedBuffer{}
	err := command.Run()
	if errors.Is(probeContext.Err(), context.DeadlineExceeded) {
		return "", ErrProbeTimeout
	}
	if err != nil {
		return "", ErrProbeFailed
	}
	if output.overflow {
		return "", ErrVersionUnrecognized
	}
	return parseVersion(targetID, output.Bytes())
}

// windowsProbeCommand builds the right invocation for the CLI form: a .cmd/.bat
// npm shim runs through cmd.exe /c, a .ps1 through PowerShell, a native .exe
// directly.
func windowsProbeCommand(ctx context.Context, realPath string) *exec.Cmd {
	switch strings.ToLower(filepath.Ext(realPath)) {
	case ".cmd", ".bat":
		comspec := os.Getenv("ComSpec")
		if strings.TrimSpace(comspec) == "" {
			comspec = filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
		}
		return exec.CommandContext(ctx, comspec, "/d", "/s", "/c", realPath, "--version")
	case ".ps1":
		ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
		return exec.CommandContext(ctx, ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", realPath, "--version")
	default:
		return exec.CommandContext(ctx, realPath, "--version")
	}
}

func windowsProbeEnv(candidate Candidate) []string {
	// Node-based CLIs (notably Claude Code) hang under a heavily trimmed
	// environment/PATH — some spawn a node subprocess that needs the full user
	// PATH. The Bridge already runs with a curated, secret-free Windows
	// environment (assembled by the app before launch), so inheriting it is
	// both robust and safe. Only the CLI's own directory is prepended to PATH
	// so the shim resolves, and NO_COLOR/CI keep the output plain.
	env := os.Environ()
	env = replaceEnv(env, "PATH", probePathPrefix(candidate)+envValue(env, "PATH"))
	env = append(env, "NO_COLOR=1")
	return env
}

// probePathPrefix are the directories prepended to PATH so the CLI shim and the
// node it invokes resolve even if the inherited PATH is stale (e.g. captured
// before Node was installed): the CLI's own directory, the npm global bin and
// the Node install directory.
func probePathPrefix(candidate Candidate) string {
	sep := string(os.PathListSeparator)
	parts := []string{filepath.Dir(candidate.RealPath), filepath.Dir(candidate.Path)}
	if appData := os.Getenv("APPDATA"); appData != "" {
		parts = append(parts, filepath.Join(appData, "npm"))
	}
	for _, key := range []string{"ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"} {
		if pf := os.Getenv(key); pf != "" {
			parts = append(parts, filepath.Join(pf, "nodejs"))
		}
	}
	seen := make(map[string]struct{}, len(parts))
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		clean := filepath.Clean(part)
		key := strings.ToLower(clean)
		if _, dup := seen[key]; dup || clean == "." {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, clean)
	}
	return strings.Join(out, sep) + sep
}

func envValue(env []string, key string) string {
	lowerKey := strings.ToLower(key)
	for _, item := range env {
		name, value, ok := strings.Cut(item, "=")
		if ok && strings.ToLower(name) == lowerKey {
			return value
		}
	}
	return ""
}

// replaceEnv returns env with key set to value (replacing any existing entry,
// case-insensitively as Windows treats variable names).
func replaceEnv(env []string, key, value string) []string {
	lowerKey := strings.ToLower(key)
	out := env[:0:0]
	for _, item := range env {
		name, _, _ := strings.Cut(item, "=")
		if strings.ToLower(name) == lowerKey {
			continue
		}
		out = append(out, item)
	}
	return append(out, key+"="+value)
}
