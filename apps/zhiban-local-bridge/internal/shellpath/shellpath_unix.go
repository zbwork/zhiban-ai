//go:build !windows

package shellpath

import "context"

// resolves asks the user's login shell which copy it runs. Only the login
// shell sees nvm / fnm / asdf and custom npm prefixes, so nothing else can
// answer this.
func (e *Ensurer) resolves(ctx context.Context, name, launcherPath string) bool {
	if e.Lookup == nil {
		return false
	}
	resolved, ok := e.Lookup(ctx, name)
	if !ok {
		return false
	}
	return sameFile(resolved, launcherPath)
}

// arrange adds the marked block to the login shell's startup file.
func (e *Ensurer) arrange(string) error {
	if e.Lookup == nil {
		return ErrUnsupportedShell
	}
	startupFile, line, ok := e.startupFile()
	if !ok {
		return ErrUnsupportedShell
	}
	return e.appendBlock(startupFile, line)
}
