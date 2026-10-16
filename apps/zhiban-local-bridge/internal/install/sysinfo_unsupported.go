//go:build !darwin && !windows

package install

import (
	"strconv"
	"strings"
	"syscall"
)

func defaultOSVersion() (string, error)       { return "", syscall.ENOTSUP }
func defaultFreeBytes(string) (uint64, error) { return 0, syscall.ENOTSUP }
func defaultWritable(string) bool             { return false }

func minOSVersion() string { return MinOSVersion }

func osVersionSupported(version string) bool {
	major, _, _ := strings.Cut(strings.TrimSpace(version), ".")
	value, err := strconv.Atoi(major)
	return err == nil && value >= 11
}
