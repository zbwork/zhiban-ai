//go:build darwin

package install

import (
	"strconv"
	"strings"
	"syscall"
)

func defaultOSVersion() (string, error) {
	value, err := syscall.Sysctl("kern.osproductversion")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(value), nil
}

func defaultFreeBytes(path string) (uint64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, err
	}
	return stat.Bavail * uint64(stat.Bsize), nil
}

func defaultWritable(path string) bool {
	return syscall.Access(path, 0x2) == nil
}

func minOSVersion() string { return MinOSVersion }

// osVersionSupported accepts macOS 11 (Big Sur) and newer.
func osVersionSupported(version string) bool {
	major, _, _ := strings.Cut(strings.TrimSpace(version), ".")
	value, err := strconv.Atoi(major)
	return err == nil && value >= 11
}
