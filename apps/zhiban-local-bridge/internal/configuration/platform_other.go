//go:build !windows

package configuration

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// desktopCodexCore is the CLI core the Codex desktop app bundles, and whether
// a switch requires it: the app reads the same config.toml, so running it is
// how the switch validates the file it just wrote.
func desktopCodexCore(bundle string) (string, bool) {
	for _, relative := range []string{
		"Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
		"Contents/Resources/codex",
	} {
		core := filepath.Join(bundle, filepath.FromSlash(relative))
		if _, err := os.Lstat(core); os.IsNotExist(err) {
			continue
		}
		if validateExecutable(core) != nil {
			return "", true
		}
		// The new nested bundle must not resolve through a symlink outside
		// the verified application. Do not fall back from an unsafe core.
		for dir := filepath.Dir(core); ; dir = filepath.Dir(dir) {
			info, err := os.Lstat(dir)
			if err != nil || !info.IsDir() || unsafeDirPerm(info) {
				return "", true
			}
			if dir == filepath.Clean(bundle) {
				break
			}
		}
		return core, true
	}
	return "", true
}

// IsFileInUse is Windows-only: POSIX rename replaces a file other processes
// still hold open, so a busy file never fails a write here.
func IsFileInUse(error) bool { return false }

// unsafeDirPerm / unsafeFilePerm / notExecutablePerm enforce the Unix
// permission invariants for managed configuration files. On Windows these bits
// are synthetic (see platform_windows.go).
func unsafeDirPerm(info os.FileInfo) bool  { return info.Mode().Perm()&0o022 != 0 }
func unsafeFilePerm(mode os.FileMode) bool { return mode.Perm()&0o022 != 0 }
func notExecutablePerm(mode os.FileMode) bool {
	return mode.Perm()&0o111 == 0
}

// shellQuote quotes the helper path for /bin/sh, which is what Claude Code
// runs apiKeyHelper through on macOS: POSIX single quotes.
func shellQuote(value string) (string, error) {
	if unsafeHelperPath(value) {
		return "", ErrUnsafePath
	}
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'", nil
}

// quietProbeCommand builds the config-load verification command with a
// sanitized POSIX environment.
func quietProbeCommand(ctx context.Context, homeDir, codexHome, executable string, arguments []string) *exec.Cmd {
	command := exec.CommandContext(ctx, executable, arguments...)
	command.Dir = homeDir
	command.Env = []string{
		"HOME=" + homeDir,
		"CODEX_HOME=" + codexHome,
		"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
		"LANG=en_US.UTF-8",
		"LC_ALL=en_US.UTF-8",
	}
	return command
}
