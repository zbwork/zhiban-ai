//go:build windows

package launch

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/appx"
)

func comspecPath() string {
	if v := strings.TrimSpace(os.Getenv("ComSpec")); v != "" {
		return v
	}
	root := os.Getenv("SystemRoot")
	if strings.TrimSpace(root) == "" {
		root = `C:\Windows`
	}
	return filepath.Join(root, "System32", "cmd.exe")
}

// NewMacOSTerminalOpener returns the platform terminal opener. On Windows it
// opens a fresh console window running the .cmd trampoline (via `cmd /c start`),
// the analogue of `open -a Terminal <script>` on macOS.
func NewMacOSTerminalOpener(homeDir string) TerminalOpener {
	home := filepath.Clean(homeDir)
	return func(ctx context.Context, scriptPath string) error {
		if !filepath.IsAbs(scriptPath) || strings.ToLower(filepath.Ext(scriptPath)) != ".cmd" {
			return ErrTerminalLaunchFailed
		}
		info, err := os.Lstat(scriptPath)
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return ErrTerminalLaunchFailed
		}
		// `start "" /D <home> <script>`: empty title, working directory home,
		// then the trampoline .cmd to run in a new console window.
		command := exec.CommandContext(ctx, comspecPath(), "/c", "start", "", "/D", home, scriptPath)
		command.Stdin = nil
		command.Stdout = io.Discard
		command.Stderr = io.Discard
		if err := command.Run(); err != nil {
			return ErrTerminalLaunchFailed
		}
		return nil
	}
}

// NewMacOSApplicationOpener returns the platform application opener. On
// Windows a desktop target is a registered app package: it is activated
// through the shell by its application user model id
// (shell:AppsFolder\<Family>!<AppId>), exactly like its Start menu tile —
// packaged executables must not be started by path.
func NewMacOSApplicationOpener() ApplicationOpener {
	return func(ctx context.Context, root string) error {
		if err := validateDesktopDirectory(filepath.Clean(root)); err != nil {
			return ErrProcessLaunchFailed
		}
		full, ok := appx.ParseFullName(filepath.Base(filepath.Clean(root)))
		if !ok {
			return ErrProcessLaunchFailed
		}
		manifest, err := appx.ReadManifestDir(root)
		if err != nil || manifest.Name != full.Name {
			return ErrProcessLaunchFailed
		}
		explorer := filepath.Join(systemRoot(), "explorer.exe")
		command := exec.CommandContext(ctx, explorer, `shell:AppsFolder\`+full.FamilyName()+"!"+manifest.AppID)
		command.Stdin = nil
		command.Stdout = io.Discard
		command.Stderr = io.Discard
		// explorer.exe hands the activation to the shell and exits at once;
		// its exit code carries no meaning, only a failure to start does.
		if err := command.Start(); err != nil {
			return ErrProcessLaunchFailed
		}
		_ = command.Wait()
		return nil
	}
}

func systemRoot() string {
	root := strings.TrimSpace(os.Getenv("SystemRoot"))
	if root == "" {
		return `C:\Windows`
	}
	return root
}

// NewMacOSExecutor returns the "launch consume" trampoline body. Windows has no
// exec-replace (syscall.Exec), so it verifies the project directory identity,
// then runs the CLI as a child that inherits the console's stdio and waits for
// it — the user sees the CLI in the window the terminal opener created.
func NewMacOSExecutor() ExecuteFunc {
	return func(ctx context.Context, execution Execution) error {
		if err := ctx.Err(); err != nil {
			return err
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
		identity, ok := fileIdentity(directory, info)
		if !ok || identity != execution.Identity {
			return ErrProjectChanged
		}
		command := windowsConsumeCommand(ctx, execution.Executable, execution.Arguments)
		command.Dir = execution.ProjectPath
		command.Env = execution.Environment
		command.Stdin = os.Stdin
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
		if err := command.Run(); err != nil {
			return ErrProcessLaunchFailed
		}
		return nil
	}
}

// windowsConsumeCommand runs the CLI the right way for its form: a .cmd/.bat npm
// shim through cmd.exe, a .ps1 through PowerShell, a native .exe directly.
func windowsConsumeCommand(ctx context.Context, executable string, arguments []string) *exec.Cmd {
	switch strings.ToLower(filepath.Ext(executable)) {
	case ".cmd", ".bat":
		return exec.CommandContext(ctx, comspecPath(), append([]string{"/d", "/s", "/c", executable}, arguments...)...)
	case ".ps1":
		root := os.Getenv("SystemRoot")
		if strings.TrimSpace(root) == "" {
			root = `C:\Windows`
		}
		ps := filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
		return exec.CommandContext(ctx, ps, append([]string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", executable}, arguments...)...)
	default:
		return exec.CommandContext(ctx, executable, arguments...)
	}
}
