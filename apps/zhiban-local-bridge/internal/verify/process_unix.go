//go:build !windows

package verify

import (
	"context"
	"os/exec"
	"syscall"
)

// verifyBaseEnvironment is the sanitized POSIX environment the L3 probe runs
// under on macOS/Unix.
func verifyBaseEnvironment(homeDir, temporary, _ string) []string {
	return []string{
		"HOME=" + homeDir,
		"TMPDIR=" + temporary,
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
		"LANG=en_US.UTF-8",
		"LC_ALL=en_US.UTF-8",
		"TERM=dumb",
		"NO_COLOR=1",
	}
}

// verifyCommand runs the CLI directly on Unix.
func verifyCommand(ctx context.Context, executable string, arguments []string) *exec.Cmd {
	return exec.CommandContext(ctx, executable, arguments...)
}

// isolateProcess runs the probe in its own process group so cancelling it
// also kills anything the CLI spawned.
func isolateProcess(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
}
