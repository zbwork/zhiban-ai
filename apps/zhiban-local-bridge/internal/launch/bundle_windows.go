//go:build windows

package launch

import (
	"os"
	"path/filepath"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/appx"
)

// validateDesktopDirectory accepts a registered app package folder: a real
// directory whose name is a package full name and which holds the manifest.
func validateDesktopDirectory(root string) error {
	info, err := os.Lstat(root)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return ErrInstallationChanged
	}
	if _, ok := appx.ParseFullName(filepath.Base(root)); !ok {
		return ErrInstallationChanged
	}
	if _, err := appx.ReadManifestDir(root); err != nil {
		return ErrInstallationChanged
	}
	return nil
}
