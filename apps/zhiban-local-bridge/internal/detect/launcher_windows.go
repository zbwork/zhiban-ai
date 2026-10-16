//go:build windows

package detect

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// The Bridge's Windows launcher %USERPROFILE%\.local\bin\<tool>.cmd is a
// small batch shim that runs the retained version file by a path relative to
// the shim's own directory (%~dp0), the way the macOS launcher is a symlink
// into the versions layout. Symbolic links need a privilege on Windows, and a
// hard link (what the Bridge used until 2026-09-11) cannot say which version
// directory it belongs to: Codex needs the rest of its package beside the
// executable it runs, and a repair that replaces the version directory leaves
// the old hard link pointing at the moved-aside file.
//
// The format lives in the detect package because detection has to recognise
// the shim and resolve it to the executable it runs, exactly as EvalSymlinks
// resolves the macOS launcher: version probe, layout check, source
// classification and managed launch then all see the version file.
//
//	@echo off
//	rem zhiban-local-bridge launcher v1
//	rem target=..\..\.codex\packages\standalone\0.154.0\bin\codex.exe
//	"%~dp0..\..\.codex\packages\standalone\0.154.0\bin\codex.exe" %*
//	exit /b %ERRORLEVEL%
//
// The shim is pure ASCII (cmd.exe reads batch files in the console code
// page, so a literal profile path with a non-ASCII user name would be
// mangled); the relative form keeps the user's profile path out of it.

const (
	launcherShimHeader       = "@echo off"
	launcherShimMarker       = "rem zhiban-local-bridge launcher v1"
	launcherShimTargetPrefix = "rem target="
	launcherShimMaxBytes     = 4096
)

// ErrLauncherShimTarget reports a target the shim format cannot express.
var ErrLauncherShimTarget = errors.New("detect: launcher target cannot be expressed in a batch shim")

// LauncherShim renders the shim to place at shimPath so that it runs target.
// Both paths must be absolute; target normally lies under the same profile
// as the shim and is then written relative to the shim's directory.
func LauncherShim(shimPath, target string) ([]byte, error) {
	if !filepath.IsAbs(shimPath) || !filepath.IsAbs(target) {
		return nil, ErrLauncherShimTarget
	}
	target = filepath.Clean(target)
	reference := target
	command := `"` + target + `"`
	if rel, err := filepath.Rel(filepath.Dir(filepath.Clean(shimPath)), target); err == nil && !filepath.IsAbs(rel) {
		reference = rel
		command = `"%~dp0` + rel + `"`
	}
	if !shimSafe(reference) {
		return nil, ErrLauncherShimTarget
	}
	var out bytes.Buffer
	for _, line := range []string{
		launcherShimHeader,
		launcherShimMarker,
		launcherShimTargetPrefix + reference,
		command + " %*",
		"exit /b %ERRORLEVEL%",
	} {
		out.WriteString(line)
		out.WriteString("\r\n")
	}
	return out.Bytes(), nil
}

// shimSafe accepts a path that batch syntax passes through verbatim: printable
// ASCII without quotes, percent signs or the cmd metacharacters that would
// need escaping.
func shimSafe(path string) bool {
	if path == "" {
		return false
	}
	for i := 0; i < len(path); i++ {
		c := path[i]
		if c < 0x20 || c > 0x7e {
			return false
		}
		switch c {
		case '"', '%', '^', '&', '|', '<', '>', '!':
			return false
		}
	}
	return true
}

// LauncherShimTarget parses the shim at shimPath and returns the absolute
// path of the executable it runs. ok is false when the file is not a Bridge
// launcher shim.
func LauncherShimTarget(shimPath string) (target string, ok bool) {
	file, err := os.Open(shimPath)
	if err != nil {
		return "", false
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, launcherShimMaxBytes+1))
	if err != nil || len(content) > launcherShimMaxBytes {
		return "", false
	}
	return parseLauncherShim(shimPath, content)
}

func parseLauncherShim(shimPath string, content []byte) (string, bool) {
	lines := strings.Split(string(content), "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], "\r")
	}
	if len(lines) < 3 || lines[0] != launcherShimHeader || lines[1] != launcherShimMarker {
		return "", false
	}
	for _, line := range lines[2:] {
		if !strings.HasPrefix(line, launcherShimTargetPrefix) {
			continue
		}
		reference := strings.TrimPrefix(line, launcherShimTargetPrefix)
		if !shimSafe(reference) {
			return "", false
		}
		if filepath.IsAbs(reference) {
			return filepath.Clean(reference), true
		}
		return filepath.Clean(filepath.Join(filepath.Dir(filepath.Clean(shimPath)), reference)), true
	}
	return "", false
}
