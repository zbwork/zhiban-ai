//go:build !windows

package launch

import (
	"os"
	"path/filepath"
)

// validateDesktopDirectory accepts an application bundle: a real directory
// named *.app with a Contents/MacOS folder.
func validateDesktopDirectory(bundle string) error {
	info, err := os.Lstat(bundle)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || filepath.Ext(bundle) != ".app" {
		return ErrInstallationChanged
	}
	if executables, err := os.Lstat(filepath.Join(bundle, "Contents", "MacOS")); err != nil || !executables.IsDir() {
		return ErrInstallationChanged
	}
	return nil
}
