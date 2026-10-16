//go:build darwin

package launch

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func NewMacOSTerminalOpener(homeDir string) TerminalOpener {
	home := filepath.Clean(homeDir)
	return func(ctx context.Context, scriptPath string) error {
		if !filepath.IsAbs(scriptPath) || filepath.Ext(scriptPath) != ".command" {
			return ErrTerminalLaunchFailed
		}
		info, err := os.Lstat(scriptPath)
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm() != 0o700 {
			return ErrTerminalLaunchFailed
		}
		command := exec.CommandContext(ctx, "/usr/bin/open", "-a", "Terminal", scriptPath)
		command.Env = []string{
			"HOME=" + home,
			"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
			"LANG=en_US.UTF-8",
		}
		command.Stdin = nil
		command.Stdout = io.Discard
		command.Stderr = io.Discard
		if err := command.Run(); err != nil {
			return ErrTerminalLaunchFailed
		}
		return nil
	}
}

// NewMacOSApplicationOpener opens an application bundle through LaunchServices
// (`open -a <bundle>`), exactly like a double-click in Finder.
func NewMacOSApplicationOpener() ApplicationOpener {
	return func(ctx context.Context, bundlePath string) error {
		bundle := filepath.Clean(bundlePath)
		info, err := os.Lstat(bundle)
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || filepath.Ext(bundle) != ".app" || !filepath.IsAbs(bundle) {
			return ErrProcessLaunchFailed
		}
		command := exec.CommandContext(ctx, "/usr/bin/open", "-a", bundle)
		command.Env = []string{
			"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
			"LANG=en_US.UTF-8",
		}
		command.Stdin = nil
		command.Stdout = io.Discard
		command.Stderr = io.Discard
		if err := command.Run(); err != nil {
			return ErrProcessLaunchFailed
		}
		return nil
	}
}

func NewMacOSExecutor() ExecuteFunc {
	return func(ctx context.Context, execution Execution) error {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if validateExecutablePath(execution.Executable) != nil {
			return ErrProcessLaunchFailed
		}
		fd, err := secureOpenDirectory(execution.ProjectPath)
		if err != nil {
			return ErrProjectChanged
		}
		directory := os.NewFile(uintptr(fd), execution.ProjectPath)
		if directory == nil {
			_ = secureClose(fd)
			return ErrProjectChanged
		}
		defer directory.Close()
		info, err := directory.Stat()
		if err != nil || !info.IsDir() {
			return ErrProjectChanged
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || (projectIdentity{Device: uint64(stat.Dev), Inode: stat.Ino}) != execution.Identity {
			return ErrProjectChanged
		}
		if err := syscall.Fchdir(fd); err != nil {
			return ErrProjectChanged
		}
		arguments := append([]string{execution.Executable}, execution.Arguments...)
		if err := syscall.Exec(execution.Executable, arguments, execution.Environment); err != nil {
			return ErrProcessLaunchFailed
		}
		return nil
	}
}
