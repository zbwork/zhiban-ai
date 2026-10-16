//go:build windows

package verify

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// verifyBaseEnvironment: the L3 probe (a node-based CLI making a real gateway
// request) needs a full Windows environment. It inherits the Bridge's curated
// environment and overrides HOME/USERPROFILE and the temp dirs to the isolated
// probe workspace, prepending the CLI/npm/Node directories to PATH.
func verifyBaseEnvironment(homeDir, temporary, executable string) []string {
	env := os.Environ()
	env = setVerifyEnv(env, "PATH", verifyPathPrefix(executable)+verifyEnvValue(env, "PATH"))
	env = setVerifyEnv(env, "HOME", homeDir)
	env = setVerifyEnv(env, "USERPROFILE", homeDir)
	env = setVerifyEnv(env, "TMPDIR", temporary)
	env = setVerifyEnv(env, "TEMP", temporary)
	env = setVerifyEnv(env, "TMP", temporary)
	env = append(env, "TERM=dumb", "NO_COLOR=1")
	return env
}

// verifyCommand runs a .cmd/.bat shim through cmd.exe, a .ps1 through
// PowerShell, and a native .exe directly.
func verifyCommand(ctx context.Context, executable string, arguments []string) *exec.Cmd {
	switch strings.ToLower(filepath.Ext(executable)) {
	case ".cmd", ".bat":
		comspec := os.Getenv("ComSpec")
		if strings.TrimSpace(comspec) == "" {
			comspec = filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
		}
		return exec.CommandContext(ctx, comspec, append([]string{"/d", "/s", "/c", executable}, arguments...)...)
	case ".ps1":
		ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
		return exec.CommandContext(ctx, ps, append([]string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", executable}, arguments...)...)
	default:
		return exec.CommandContext(ctx, executable, arguments...)
	}
}

func verifyPathPrefix(executable string) string {
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

func verifyEnvValue(env []string, key string) string {
	lowerKey := strings.ToLower(key)
	for _, item := range env {
		name, value, ok := strings.Cut(item, "=")
		if ok && strings.ToLower(name) == lowerKey {
			return value
		}
	}
	return ""
}

func setVerifyEnv(env []string, key, value string) []string {
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

// createNoWindow is CREATE_NO_WINDOW, which package syscall does not export:
// the probe must not flash a console when the Bridge itself runs without one.
const createNoWindow = 0x08000000

// isolateProcess starts the probe in a new process group without a console
// window. Windows has no process-group kill, so cancelling runs
// taskkill /T /F from System32 (never from PATH) to end the CLI and whatever
// it spawned, falling back to killing the direct child.
func isolateProcess(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | createNoWindow}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		if root := os.Getenv("SystemRoot"); root != "" {
			kill := exec.Command(filepath.Join(root, "System32", "taskkill.exe"), "/T", "/F", "/PID", strconv.Itoa(command.Process.Pid))
			kill.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow, HideWindow: true}
			if kill.Run() == nil {
				return nil
			}
		}
		return command.Process.Kill()
	}
}
