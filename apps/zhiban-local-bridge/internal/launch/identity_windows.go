//go:build windows

package launch

import (
	"os"
	"syscall"
)

// fileIdentity returns the volume serial number and 64-bit file index of an
// open directory handle: the Windows counterpart of (st_dev, st_ino), stable
// for the lifetime of the directory on NTFS and ReFS. FileInfo.Sys() carries
// no identity on Windows, so a nil handle has none either.
func fileIdentity(directory *os.File, _ os.FileInfo) (projectIdentity, bool) {
	if directory == nil {
		return projectIdentity{}, false
	}
	var data syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(syscall.Handle(directory.Fd()), &data); err != nil {
		return projectIdentity{}, false
	}
	return projectIdentity{
		Device: uint64(data.VolumeSerialNumber),
		Inode:  uint64(data.FileIndexHigh)<<32 | uint64(data.FileIndexLow),
	}, true
}
