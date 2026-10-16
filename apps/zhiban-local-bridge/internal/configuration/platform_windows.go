//go:build windows

package configuration

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// desktopCodexCore: the Codex desktop app on Windows is the ChatGPT MSIX
// package, and although it does ship the core
// (<package>\app\resources\codex.exe) Windows refuses to run binaries inside
// %ProgramFiles%\WindowsApps directly — a normal user can stat the file and
// gets "access denied" on exec (2026-09-16 real machine). So there is nothing
// to probe here: the file is shared with codex_cli, whose own probe validates
// it. Reporting a missing core instead made every desktop switch fail with
// LCT-CODEX_DESKTOP-CONFIG-INSTALLATION_CHANGED while the switch had in fact
// succeeded.
func desktopCodexCore(string) (string, bool) { return "", false }

// IsFileInUse reports whether err is Windows refusing to replace or open a file
// another process holds: a sharing or lock violation, or the access denial
// MoveFileEx returns while the target is open without FILE_SHARE_DELETE (Codex
// Desktop keeps rewriting ~/.codex/config.toml, 2026-09-15 Windows 12012).
func IsFileInUse(err error) bool {
	var errno syscall.Errno
	if !errors.As(err, &errno) {
		return false
	}
	const (
		errorAccessDenied     = syscall.Errno(5)
		errorSharingViolation = syscall.Errno(32)
		errorLockViolation    = syscall.Errno(33)
	)
	return errno == errorSharingViolation || errno == errorLockViolation || errno == errorAccessDenied
}

// On Windows the permission bits reported by os.Stat/os.Lstat are synthetic, so
// the Unix world-writable / executable-bit invariants do not apply. Safety
// comes from the files being real (non-reparse) regular files under the
// per-user, ACL-protected profile, which the secure_syscall layer enforces.
func unsafeDirPerm(os.FileInfo) bool     { return false }
func unsafeFilePerm(os.FileMode) bool    { return false }
func notExecutablePerm(os.FileMode) bool { return false }

// shellQuote quotes the helper path for cmd.exe, which is what Claude Code runs
// apiKeyHelper through on Windows. POSIX single quotes are not quoting there:
// `'C:\Program Files\知办AI\zhiban-local-bridge.exe' credential get …` made cmd
// look for a command named `'C:\Program`, the helper "exited 1", and Claude
// reported 401 (2026-09-10 Windows real machine). Double quotes group the
// path; `"` cannot be escaped inside them and `%` / `!` still expand, so such
// paths are refused rather than written.
func shellQuote(value string) (string, error) {
	if unsafeHelperPath(value) || strings.ContainsAny(value, "\"%!") {
		return "", ErrUnsafePath
	}
	return "\"" + value + "\"", nil
}

// quietProbeCommand builds the config-load verification command on Windows: a
// .cmd/.bat npm shim runs through cmd.exe, a .ps1 through PowerShell, a native
// .exe directly, all with a real (but curated) Windows environment so Node can
// start and resolve HOME / CODEX_HOME.
func quietProbeCommand(ctx context.Context, homeDir, codexHome, executable string, arguments []string) *exec.Cmd {
	var command *exec.Cmd
	switch strings.ToLower(filepath.Ext(executable)) {
	case ".cmd", ".bat":
		comspec := os.Getenv("ComSpec")
		if strings.TrimSpace(comspec) == "" {
			comspec = filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
		}
		command = exec.CommandContext(ctx, comspec, append([]string{"/d", "/s", "/c", executable}, arguments...)...)
	case ".ps1":
		ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
		command = exec.CommandContext(ctx, ps, append([]string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", executable}, arguments...)...)
	default:
		command = exec.CommandContext(ctx, executable, arguments...)
	}
	command.Dir = homeDir
	command.Env = quietProbeEnv(homeDir, codexHome, executable)
	return command
}

// quietProbeEnv inherits the Bridge's already-curated Windows environment (a
// trimmed allow-list makes node-based CLIs hang) and only overrides HOME /
// USERPROFILE / CODEX_HOME plus a PATH whose front carries the CLI, npm and
// Node directories so the shim and its node resolve even under a stale PATH.
func quietProbeEnv(homeDir, codexHome, executable string) []string {
	env := os.Environ()
	env = setEnv(env, "PATH", windowsPathPrefix(executable)+envValue(env, "PATH"))
	env = setEnv(env, "HOME", homeDir)
	env = setEnv(env, "USERPROFILE", homeDir)
	env = setEnv(env, "CODEX_HOME", codexHome)
	env = append(env, "NO_COLOR=1")
	return env
}

// windowsPathPrefix are the directories prepended to PATH so a .cmd shim and
// the node it invokes resolve: the CLI's directory, the npm global bin and the
// Node install directory. Terminates with a path separator for concatenation.
func windowsPathPrefix(executable string) string {
	sep := string(os.PathListSeparator)
	parts := []string{filepath.Dir(executable)}
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

func setEnv(env []string, key, value string) []string {
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
