//go:build windows

package install

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

// minOSVersionWindows is Windows 10 1809 (build 17763), the floor both
// publishers document for their Windows CLIs.
const minOSVersionWindows = "10.0.17763"

var (
	modNtdll               = syscall.NewLazyDLL("ntdll.dll")
	procRtlGetVersion      = modNtdll.NewProc("RtlGetVersion")
	procGetDiskFreeSpaceEx = modKernel32.NewProc("GetDiskFreeSpaceExW")
)

// rtlOSVersionInfoEx mirrors RTL_OSVERSIONINFOEXW. RtlGetVersion is not
// subject to the manifest-based version lie that GetVersionEx applies.
type rtlOSVersionInfoEx struct {
	OSVersionInfoSize uint32
	MajorVersion      uint32
	MinorVersion      uint32
	BuildNumber       uint32
	PlatformID        uint32
	CSDVersion        [128]uint16
	ServicePackMajor  uint16
	ServicePackMinor  uint16
	SuiteMask         uint16
	ProductType       byte
	Reserved          byte
}

// defaultOSVersion reports "major.minor.build", e.g. "10.0.26100".
func defaultOSVersion() (string, error) {
	var info rtlOSVersionInfoEx
	info.OSVersionInfoSize = uint32(unsafe.Sizeof(info))
	r0, _, _ := procRtlGetVersion.Call(uintptr(unsafe.Pointer(&info)))
	if r0 != 0 {
		return "", syscall.EINVAL
	}
	return fmt.Sprintf("%d.%d.%d", info.MajorVersion, info.MinorVersion, info.BuildNumber), nil
}

func defaultFreeBytes(path string) (uint64, error) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	var freeToCaller, total, totalFree uint64
	r1, _, callErr := procGetDiskFreeSpaceEx.Call(
		uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&freeToCaller)),
		uintptr(unsafe.Pointer(&total)),
		uintptr(unsafe.Pointer(&totalFree)),
	)
	if r1 == 0 {
		if callErr != nil && !errors.Is(callErr, syscall.Errno(0)) {
			return 0, callErr
		}
		return 0, syscall.EIO
	}
	return freeToCaller, nil
}

// defaultWritable probes by creating and removing an exclusive scratch file:
// Windows permission bits are synthetic, so only the ACL-enforced attempt
// answers the question.
func defaultWritable(path string) bool {
	file, err := os.CreateTemp(path, ".zhiban-writable-")
	if err != nil {
		return false
	}
	name := file.Name()
	_ = file.Close()
	_ = os.Remove(name)
	return true
}

func minOSVersion() string { return minOSVersionWindows }

// osVersionSupported accepts Windows 10 build 17763 (1809) and anything newer
// (Windows 11 reports major 10 with build >= 22000).
func osVersionSupported(version string) bool {
	parts := strings.Split(strings.TrimSpace(version), ".")
	if len(parts) < 3 {
		return false
	}
	major, errMajor := strconv.Atoi(parts[0])
	build, errBuild := strconv.Atoi(parts[2])
	if errMajor != nil || errBuild != nil {
		return false
	}
	return major > 10 || (major == 10 && build >= 17763)
}
