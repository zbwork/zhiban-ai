package detect

import (
	"os"
	"path/filepath"
	"runtime"
)

// codexCodeModeHostName is the helper Codex spawns from its own bin/ for
// Code Mode (a stable, default-on feature since 0.153); the publisher's
// package ships it beside codex.
const codexCodeModeHostName = "codex-code-mode-host"

// CodexLayoutComplete reports whether the Codex executable at path has the
// rest of the publisher's package beside it. A bare binary (what the Bridge
// installed before 2026-09-11) makes Codex print "Code Mode is unavailable …
// host executable was not found" on every session and refuse Code Mode, so
// an official standalone install without the host is reported repairable.
func CodexLayoutComplete(executable string) bool {
	name := codexCodeModeHostName
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	info, err := os.Stat(filepath.Join(filepath.Dir(executable), name))
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o111 == 0 {
		return false
	}
	return true
}

// codexLayoutIncomplete is the probe-side check: only the Bridge's own
// standalone layout (source official) is held to the package shape; npm and
// Homebrew installs have their own.
func codexLayoutIncomplete(targetID string, candidate Candidate) bool {
	return targetID == TargetCodexCLI && candidate.Source == SourceOfficial && !CodexLayoutComplete(candidate.RealPath)
}
