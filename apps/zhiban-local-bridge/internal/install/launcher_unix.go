//go:build !windows

package install

import (
	"os"
	"path/filepath"
)

// The launcher ~/.local/bin/<tool> is a symlink into the versions layout on
// macOS (the publishers' own installers do the same). The launcher_* files
// hide the mechanism from the install pipeline: Windows uses a batch shim
// instead (launcher_windows.go).

func ensureLauncherAt(directory *os.File, name, target string) error {
	return ensureSymlinkAt(directory, name, target)
}

// replaceLauncherAt re-points the launcher at target and returns an opaque
// restore token for restoreLauncherAt ("" when nothing has to be undone).
func replaceLauncherAt(directory *os.File, name, target string) (string, error) {
	previous, err := replaceSymlinkAt(directory, name, target)
	if err != nil || previous == filepath.Clean(target) {
		return "", err
	}
	return previous, nil
}

func restoreLauncherAt(directory *os.File, name, previous string) error {
	_, err := replaceSymlinkAt(directory, name, previous)
	return err
}

// commitLauncher finalises a successful switch; nothing is left behind by a
// symlink swap.
func commitLauncher(*os.File, string) {}

// launcherPointsTo reports whether the launcher at linkPath runs finalPath.
func launcherPointsTo(linkPath, finalPath string) bool {
	return existingSymlinkTarget(linkPath) == filepath.Clean(finalPath)
}

// launcherConflicts reports whether what occupies linkPath stops a
// non-switching install of finalPath: anything that does not already run it.
func launcherConflicts(linkPath, finalPath string) bool {
	return !launcherPointsTo(linkPath, finalPath)
}

// launcherKindOK reports whether what occupies the launcher name is the kind
// of entry the switch may replace.
func launcherKindOK(info os.FileInfo) bool { return info.Mode()&os.ModeSymlink != 0 }
