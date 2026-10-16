//go:build !windows

package launch

import (
	"os"
	"syscall"
)

// fileIdentity returns the (device, inode) pair of an inspected directory. The
// open handle is unused here: stat already carries the identity.
func fileIdentity(_ *os.File, info os.FileInfo) (projectIdentity, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return projectIdentity{}, false
	}
	return projectIdentity{Device: uint64(stat.Dev), Inode: stat.Ino}, true
}
