//go:build !windows

package shellenv

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	loginShellSupported = true
	maxOutput           = 64 << 10
)

func (l *LoginShellLookup) run(ctx context.Context) []byte {
	timeout := l.Timeout
	if timeout <= 0 {
		timeout = lookupTimeout
	}
	runContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var script strings.Builder
	for _, name := range lookupNames {
		script.WriteString("printf '\\n" + marker + name + "=%s\\n' \"$(command -v " + name + " 2>/dev/null)\"\n")
	}
	for _, name := range lookupVariables {
		script.WriteString("printf '\\n" + variableMarker + name + "=%s\\n' \"$" + name + "\"\n")
	}
	command := exec.CommandContext(runContext, l.Shell, "-l", "-i", "-c", script.String())
	command.Dir = l.HomeDir
	command.Env = environment(l.HomeDir, l.Shell)
	var output cappedOutput
	command.Stdout = &output
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		// Startup files may leave children behind (agents, prompts); take the
		// whole group down, not just the shell.
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	command.WaitDelay = 500 * time.Millisecond
	_ = command.Run()
	if runContext.Err() != nil {
		return nil
	}
	return output.buffer.Bytes()
}

func environment(homeDir, shell string) []string {
	env := []string{
		"HOME=" + homeDir,
		"SHELL=" + shell,
		"TERM=dumb",
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
	}
	for _, key := range []string{"USER", "LOGNAME", "TMPDIR", "LANG"} {
		if value, ok := os.LookupEnv(key); ok {
			env = append(env, key+"="+value)
		}
	}
	return env
}

type cappedOutput struct {
	buffer bytes.Buffer
}

func (w *cappedOutput) Write(data []byte) (int, error) {
	if remaining := maxOutput - w.buffer.Len(); remaining > 0 {
		if len(data) > remaining {
			w.buffer.Write(data[:remaining])
		} else {
			w.buffer.Write(data)
		}
	}
	return len(data), nil
}
