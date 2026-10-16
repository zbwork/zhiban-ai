//go:build darwin

package install

import (
	"os"
	"syscall"
)

// validateSystemApplicationsDirectory accepts /Applications as macOS ships it:
// owned by root, group admin (gid 80) and group-writable so administrator
// accounts can install applications without escalating, never world-writable.
func validateSystemApplicationsDirectory(directory *os.File) error {
	info, err := directory.Stat()
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || stat.Uid != 0 || stat.Gid != 80 || info.Mode().Perm()&0o002 != 0 {
		return errUnsafePath
	}
	return nil
}
