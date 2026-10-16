//go:build windows

package configuration

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"syscall"
	"unsafe"
)

// Windows secure_syscall layer for the configuration package. Same approach as
// the launch package (handle-relative traversal re-derived via
// GetFinalPathNameByHandleW, reparse-point rejection for O_NOFOLLOW), plus
// secureRenameSwapAt which macOS gets from renameatx_np(RENAME_SWAP). Windows
// has no atomic two-file swap, so the swap is emulated by a three-step rename
// through a random scratch name in the target directory. It is therefore not
// crash-atomic; the callers (managedFile CAS + rollback) re-snapshot after
// every swap and the managed config lives under the per-user ~/.codex /
// ~/.claude tree with low write contention. Hardening to a crash-atomic
// primitive is a follow-up.

const (
	fileFlagBackupSemantics  = 0x02000000
	fileFlagOpenReparsePoint = 0x00200000
	moveFileWriteThrough     = 0x8
)

var (
	modKernel32                  = syscall.NewLazyDLL("kernel32.dll")
	procGetFinalPathNameByHandle = modKernel32.NewProc("GetFinalPathNameByHandleW")
	procMoveFileEx               = modKernel32.NewProc("MoveFileExW")
)

func handlePath(fd int) (string, error) {
	buf := make([]uint16, 32768)
	r0, _, callErr := procGetFinalPathNameByHandle.Call(
		uintptr(syscall.Handle(fd)),
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf)),
		0,
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

func moveExclusive(from, to string) error {
	fromPtr, err := syscall.UTF16PtrFromString(from)
	if err != nil {
		return err
	}
	toPtr, err := syscall.UTF16PtrFromString(to)
	if err != nil {
		return err
	}
	r1, _, callErr := procMoveFileEx.Call(
		uintptr(unsafe.Pointer(fromPtr)),
		uintptr(unsafe.Pointer(toPtr)),
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
	return moveExclusive(fromPath, toPath)
}

// secureRenameSwapAt emulates RENAME_SWAP with a three-step rename through a
// random scratch name in the target directory. Not crash-atomic (see file
// header); callers re-snapshot after every swap.
func secureRenameSwapAt(fromFD int, from string, toFD int, to string) error {
	fromPath, err := childPath(fromFD, from)
	if err != nil {
		return err
	}
	toParent, err := handlePath(toFD)
	if err != nil {
		return err
	}
	toPath := toParent + `\` + to
	scratch, err := randomScratchName()
	if err != nil {
		return err
	}
	scratchPath := toParent + `\` + scratch

	// to -> scratch
	if err := moveExclusive(toPath, scratchPath); err != nil {
		return err
	}
	// from -> to
	if err := moveExclusive(fromPath, toPath); err != nil {
		// put `to` back and surface the failure
		_ = moveExclusive(scratchPath, toPath)
		return err
	}
	// scratch -> from
	if err := moveExclusive(scratchPath, fromPath); err != nil {
		// best-effort unwind: to -> from, scratch -> to
		_ = moveExclusive(toPath, fromPath)
		_ = moveExclusive(scratchPath, toPath)
		return err
	}
	return nil
}

func randomScratchName() (string, error) {
	var raw [12]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return ".zbswap-" + hex.EncodeToString(raw[:]), nil
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
