//go:build windows

package launch

import (
	"errors"
	"syscall"
	"unsafe"
)

// Windows counterpart of the darwin secure_syscall layer. macOS uses openat/
// O_NOFOLLOW for TOCTOU-safe, handle-relative traversal; Windows has no openat,
// so each step re-derives the child path from the parent handle
// (GetFinalPathNameByHandleW, which returns a fully symlink-resolved path) and
// re-opens it with FILE_FLAG_OPEN_REPARSE_POINT so the final component is never
// traversed as a symlink/junction — the O_NOFOLLOW equivalent. Callers pass
// single, pre-validated path components (no separators, no "."/".."), and the
// target directories live under the per-user profile with restrictive ACLs.
// This is a documented, slightly weaker compromise than openat for the final
// re-open step; hardening to handle-relative NtCreateFile is a follow-up.

const (
	fileFlagBackupSemantics  = 0x02000000
	fileFlagOpenReparsePoint = 0x00200000
)

const moveFileWriteThrough = 0x8

var (
	modKernel32                  = syscall.NewLazyDLL("kernel32.dll")
	procGetFinalPathNameByHandle = modKernel32.NewProc("GetFinalPathNameByHandleW")
	procMoveFileEx               = modKernel32.NewProc("MoveFileExW")
)

func moveFileExclusive(from, to *uint16) error {
	// No MOVEFILE_REPLACE_EXISTING => fails if the target exists, matching
	// renameatx_np(..., RENAME_EXCL).
	r1, _, callErr := procMoveFileEx.Call(
		uintptr(unsafe.Pointer(from)),
		uintptr(unsafe.Pointer(to)),
		uintptr(moveFileWriteThrough),
	)
	if r1 == 0 {
		if callErr != nil && !errors.Is(callErr, syscall.Errno(0)) {
			return callErr
		}
		return syscall.EIO
	}
	return nil
}

func handlePath(fd int) (string, error) {
	buf := make([]uint16, 32768)
	r0, _, callErr := procGetFinalPathNameByHandle.Call(
		uintptr(syscall.Handle(fd)),
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf)),
		0, // FILE_NAME_NORMALIZED | VOLUME_NAME_DOS
	)
	n := uint32(r0)
	if n == 0 || int(n) >= len(buf) {
		if callErr != nil && !errors.Is(callErr, syscall.Errno(0)) {
			return "", callErr
		}
		return "", syscall.EINVAL
	}
	return syscall.UTF16ToString(buf[:n]), nil
}

func childPath(parentFD int, name string) (string, error) {
	parent, err := handlePath(parentFD)
	if err != nil {
		return "", err
	}
	return parent + `\` + name, nil
}

func createHandle(path string, access, createmode, flags uint32) (int, error) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return -1, err
	}
	share := uint32(syscall.FILE_SHARE_READ | syscall.FILE_SHARE_WRITE | syscall.FILE_SHARE_DELETE)
	handle, err := syscall.CreateFile(p, access, share, nil, createmode, flags|fileFlagOpenReparsePoint, 0)
	if err != nil {
		return -1, err
	}
	return int(handle), nil
}

func handleAttributes(fd int) (uint32, error) {
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(syscall.Handle(fd), &info); err != nil {
		return 0, err
	}
	return info.FileAttributes, nil
}

// rejectReparse fails a freshly opened handle that turned out to be a symlink
// or junction (the O_NOFOLLOW guarantee for the final component).
func rejectReparse(fd int) error {
	attrs, err := handleAttributes(fd)
	if err != nil {
		return err
	}
	if attrs&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return syscall.ELOOP
	}
	return nil
}

func requireDirectory(fd int) error {
	attrs, err := handleAttributes(fd)
	if err != nil {
		return err
	}
	if attrs&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return syscall.ELOOP
	}
	if attrs&syscall.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return syscall.ENOTDIR
	}
	return nil
}

func secureOpenDirectory(path string) (int, error) {
	fd, err := createHandle(path, syscall.GENERIC_READ, syscall.OPEN_EXISTING, fileFlagBackupSemantics)
	if err != nil {
		return -1, err
	}
	if err := requireDirectory(fd); err != nil {
		_ = syscall.CloseHandle(syscall.Handle(fd))
		return -1, err
	}
	return fd, nil
}

func secureOpenDirectoryAt(directoryFD int, name string) (int, error) {
	path, err := childPath(directoryFD, name)
	if err != nil {
		return -1, err
	}
	return secureOpenDirectory(path)
}

func secureOpenReadOnlyAt(directoryFD int, name string) (int, error) {
	path, err := childPath(directoryFD, name)
	if err != nil {
		return -1, err
	}
	fd, err := createHandle(path, syscall.GENERIC_READ, syscall.OPEN_EXISTING, 0)
	if err != nil {
		return -1, err
	}
	if err := rejectReparse(fd); err != nil {
		_ = syscall.CloseHandle(syscall.Handle(fd))
		return -1, err
	}
	return fd, nil
}

func secureCreateExclusiveAt(directoryFD int, name string, _ uint32) (int, error) {
	path, err := childPath(directoryFD, name)
	if err != nil {
		return -1, err
	}
	// CREATE_NEW is the O_CREAT|O_EXCL equivalent: it fails if the name exists.
	fd, err := createHandle(path, syscall.GENERIC_READ|syscall.GENERIC_WRITE, syscall.CREATE_NEW, 0)
	if err != nil {
		return -1, err
	}
	return fd, nil
}

func secureMkdirAt(directoryFD int, name string, _ uint32) error {
	path, err := childPath(directoryFD, name)
	if err != nil {
		return err
	}
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	return syscall.CreateDirectory(p, nil)
}

func secureRenameExclusiveAt(fromFD int, from string, toFD int, to string) error {
	fromPath, err := childPath(fromFD, from)
	if err != nil {
		return err
	}
	toPath, err := childPath(toFD, to)
	if err != nil {
		return err
	}
	fromPtr, err := syscall.UTF16PtrFromString(fromPath)
	if err != nil {
		return err
	}
	toPtr, err := syscall.UTF16PtrFromString(toPath)
	if err != nil {
		return err
	}
	return moveFileExclusive(fromPtr, toPtr)
}

func secureUnlinkAt(directoryFD int, name string) error {
	path, err := childPath(directoryFD, name)
	if err != nil {
		return err
	}
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	return syscall.DeleteFile(p)
}

func secureFsync(fd int) error {
	// FlushFileBuffers on a directory handle opened read-only returns
	// ERROR_ACCESS_DENIED, and unlike Unix fsync-on-dir, flushing a directory
	// is neither required nor supported for rename durability on NTFS. Flush
	// file handles; treat directory handles as a no-op.
	if attrs, err := handleAttributes(fd); err == nil && attrs&syscall.FILE_ATTRIBUTE_DIRECTORY != 0 {
		return nil
	}
	return syscall.FlushFileBuffers(syscall.Handle(fd))
}
func secureClose(fd int) error { return syscall.CloseHandle(syscall.Handle(fd)) }
