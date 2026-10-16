//go:build darwin && cgo

package configuration

/*
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

static int zb_open_directory(const char *path) {
	return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

static int zb_open_directory_at(int directory_fd, const char *path) {
	return openat(directory_fd, path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

static int zb_open_readonly_at(int directory_fd, const char *path) {
	return openat(directory_fd, path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
}

static int zb_create_exclusive_at(int directory_fd, const char *path, uint32_t mode) {
	return openat(directory_fd, path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, (mode_t)mode);
}

static int zb_mkdir_at(int directory_fd, const char *path, uint32_t mode) {
	return mkdirat(directory_fd, path, (mode_t)mode);
}

static int zb_rename_exclusive_at(int from_fd, const char *from, int to_fd, const char *to) {
	return renameatx_np(from_fd, from, to_fd, to, RENAME_EXCL);
}

static int zb_rename_swap_at(int from_fd, const char *from, int to_fd, const char *to) {
	return renameatx_np(from_fd, from, to_fd, to, RENAME_SWAP);
}

static int zb_unlink_at(int directory_fd, const char *path) {
	return unlinkat(directory_fd, path, 0);
}
*/
import "C"

import (
	"syscall"
	"unsafe"
)

func secureOpenDirectory(path string) (int, error) {
	return callOpen(path, func(value *C.char) (C.int, error) {
		result, callErr := C.zb_open_directory(value)
		return result, callErr
	})
}

func secureOpenDirectoryAt(directoryFD int, path string) (int, error) {
	return callOpen(path, func(value *C.char) (C.int, error) {
		result, callErr := C.zb_open_directory_at(C.int(directoryFD), value)
		return result, callErr
	})
}

func secureOpenReadOnlyAt(directoryFD int, path string) (int, error) {
	return callOpen(path, func(value *C.char) (C.int, error) {
		result, callErr := C.zb_open_readonly_at(C.int(directoryFD), value)
		return result, callErr
	})
}

func secureCreateExclusiveAt(directoryFD int, path string, mode uint32) (int, error) {
	return callOpen(path, func(value *C.char) (C.int, error) {
		result, callErr := C.zb_create_exclusive_at(C.int(directoryFD), value, C.uint32_t(mode))
		return result, callErr
	})
}

func secureMkdirAt(directoryFD int, path string, mode uint32) error {
	return callPath(path, func(value *C.char) (C.int, error) {
		result, callErr := C.zb_mkdir_at(C.int(directoryFD), value, C.uint32_t(mode))
		return result, callErr
	})
}

func secureRenameExclusiveAt(fromFD int, from string, toFD int, to string) error {
	return callTwoPaths(from, to, func(fromValue, toValue *C.char) (C.int, error) {
		result, callErr := C.zb_rename_exclusive_at(C.int(fromFD), fromValue, C.int(toFD), toValue)
		return result, callErr
	})
}

func secureRenameSwapAt(fromFD int, from string, toFD int, to string) error {
	return callTwoPaths(from, to, func(fromValue, toValue *C.char) (C.int, error) {
		result, callErr := C.zb_rename_swap_at(C.int(fromFD), fromValue, C.int(toFD), toValue)
		return result, callErr
	})
}

func secureUnlinkAt(directoryFD int, path string) error {
	return callPath(path, func(value *C.char) (C.int, error) {
		result, callErr := C.zb_unlink_at(C.int(directoryFD), value)
		return result, callErr
	})
}

func secureFsync(fd int) error {
	if err := syscall.Fsync(fd); err != nil {
		return err
	}
	return nil
}

func secureClose(fd int) error {
	return syscall.Close(fd)
}

func callOpen(path string, call func(*C.char) (C.int, error)) (int, error) {
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

func callPath(path string, call func(*C.char) (C.int, error)) error {
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

func callTwoPaths(from, to string, call func(*C.char, *C.char) (C.int, error)) error {
	fromValue := C.CString(from)
	defer C.free(unsafe.Pointer(fromValue))
	toValue := C.CString(to)
	defer C.free(unsafe.Pointer(toValue))
	result, callErr := call(fromValue, toValue)
	if result != 0 {
		if callErr != nil {
			return callErr
		}
		return syscall.EIO
	}
	return nil
}
