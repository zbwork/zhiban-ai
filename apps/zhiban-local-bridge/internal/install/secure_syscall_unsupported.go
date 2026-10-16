//go:build (!darwin || !cgo) && !windows

package install

import "syscall"

func secureOpenDirectory(string) (int, error)                  { return -1, syscall.ENOTSUP }
func secureOpenDirectoryAt(int, string) (int, error)           { return -1, syscall.ENOTSUP }
func secureOpenReadOnlyAt(int, string) (int, error)            { return -1, syscall.ENOTSUP }
func secureCreateExclusiveAt(int, string, uint32) (int, error) { return -1, syscall.ENOTSUP }
func secureMkdirAt(int, string, uint32) error                  { return syscall.ENOTSUP }
func secureRenameExclusiveAt(int, string, int, string) error   { return syscall.ENOTSUP }
func secureRenameAt(int, string, int, string) error            { return syscall.ENOTSUP }
func secureUnlinkAt(int, string) error                         { return syscall.ENOTSUP }
func secureSymlinkAt(string, int, string) error                { return syscall.ENOTSUP }
func secureFsync(int) error                                    { return syscall.ENOTSUP }
func secureClose(int) error                                    { return syscall.ENOTSUP }
