//go:build windows

package shellenv

import "context"

// Windows has no login shell to ask. What the user runs is answered from the
// registry PATH instead (detect/windows.go registryLookPath via
// shellpath.LookPath): this process's own PATH is a snapshot from when Zhiban
// started and goes stale once a takeover reorders the user PATH.
const loginShellSupported = false

func (l *LoginShellLookup) run(context.Context) []byte {
	return nil
}
