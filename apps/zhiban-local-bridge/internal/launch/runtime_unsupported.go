//go:build !darwin && !windows

package launch

import "context"

func NewMacOSTerminalOpener(string) TerminalOpener {
	return func(context.Context, string) error { return ErrTerminalLaunchFailed }
}

func NewMacOSExecutor() ExecuteFunc {
	return func(context.Context, Execution) error { return ErrProcessLaunchFailed }
}

func NewMacOSApplicationOpener() ApplicationOpener {
	return func(context.Context, string) error { return ErrProcessLaunchFailed }
}
