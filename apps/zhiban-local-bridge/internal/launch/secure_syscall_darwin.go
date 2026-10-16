//go:build darwin && cgo

package launch

/*
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

static int zb_launch_open_directory(const char *path) {
	return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}
static int zb_launch_open_directory_at(int directory_fd, const char *path) {
	return openat(directory_fd, path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}
static int zb_launch_open_readonly_at(int directory_fd, const char *path) {
	return openat(directory_fd, path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
}
static int zb_launch_create_exclusive_at(int directory_fd, const char *path, uint32_t mode) {
	return openat(directory_fd, path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, (mode_t)mode);
}
static int zb_launch_mkdir_at(int directory_fd, const char *path, uint32_t mode) {
	return mkdirat(directory_fd, path, (mode_t)mode);
}
static int zb_launch_rename_exclusive_at(int from_fd, const char *from, int to_fd, const char *to) {
	return renameatx_np(from_fd, from, to_fd, to, RENAME_EXCL);
}
static int zb_launch_unlink_at(int directory_fd, const char *path) {
	return unlinkat(directory_fd, path, 0);
}
*/
import "C"

import (
	"syscall"
	"unsafe"
)

func secureOpenDirectory(path string) (int, error) {
	return launchCallOpen(path, func(value *C.char) (C.int, error) {
		result, err := C.zb_launch_open_directory(value)
		return result, err
	})
}
func secureOpenDirectoryAt(directoryFD int, path string) (int, error) {
	return launchCallOpen(path, func(value *C.char) (C.int, error) {
		result, err := C.zb_launch_open_directory_at(C.int(directoryFD), value)
		return result, err
	})
}
func secureOpenReadOnlyAt(directoryFD int, path string) (int, error) {
	return launchCallOpen(path, func(value *C.char) (C.int, error) {
		result, err := C.zb_launch_open_readonly_at(C.int(directoryFD), value)
		return result, err
	})
}
func secureCreateExclusiveAt(directoryFD int, path string, mode uint32) (int, error) {
	return launchCallOpen(path, func(value *C.char) (C.int, error) {
		result, err := C.zb_launch_create_exclusive_at(C.int(directoryFD), value, C.uint32_t(mode))
		return result, err
	})
}
func secureMkdirAt(directoryFD int, path string, mode uint32) error {
	return launchCallPath(path, func(value *C.char) (C.int, error) {
		result, err := C.zb_launch_mkdir_at(C.int(directoryFD), value, C.uint32_t(mode))
		return result, err
	})
}
func secureRenameExclusiveAt(fromFD int, from string, toFD int, to string) error {
	return launchCallTwoPaths(from, to, func(left, right *C.char) (C.int, error) {
		result, err := C.zb_launch_rename_exclusive_at(C.int(fromFD), left, C.int(toFD), right)
		return result, err
	})
}
func secureUnlinkAt(directoryFD int, path string) error {
	return launchCallPath(path, func(value *C.char) (C.int, error) {
		result, err := C.zb_launch_unlink_at(C.int(directoryFD), value)
		return result, err
	})
}
func secureFsync(fd int) error { return syscall.Fsync(fd) }
func secureClose(fd int) error { return syscall.Close(fd) }

func launchCallOpen(path string, call func(*C.char) (C.int, error)) (int, error) {
	value := C.CString(path)
	defer C.free(unsafe.Pointer(value))
	result, callErr := call(value)
	if result < 0 {
		if callErr != nil {
			return -1, callErr
		}
		return -1, syscall.EIO
	}
	return int(result), nil
}
func launchCallPath(path string, call func(*C.char) (C.int, error)) error {
	value := C.CString(path)
	defer C.free(unsafe.Pointer(value))
	result, callErr := call(value)
	if result != 0 {
		if callErr != nil {
			return callErr
		}
		return syscall.EIO
	}
	return nil
}
func launchCallTwoPaths(left, right string, call func(*C.char, *C.char) (C.int, error)) error {
	leftValue := C.CString(left)
	defer C.free(unsafe.Pointer(leftValue))
	rightValue := C.CString(right)
	defer C.free(unsafe.Pointer(rightValue))
	result, callErr := call(leftValue, rightValue)
	if result != 0 {
		if callErr != nil {
			return callErr
		}
		return syscall.EIO
	}
	return nil
}
