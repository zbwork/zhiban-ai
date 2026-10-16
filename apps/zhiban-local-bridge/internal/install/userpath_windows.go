//go:build windows

package install

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

// The publishers' own Windows installers put %USERPROFILE%\.local\bin on the
// user's PATH so `codex` / `claude` work in any new terminal; the Bridge does
// the same after placing a launcher there. This is per-user (HKCU\Environment)
// and idempotent; the managed launch never depends on it (it runs the launcher
// by absolute path), so a failure here is reported but never fails an install.

const (
	hwndBroadcast     = 0xffff
	wmSettingChange   = 0x001a
	smtoAbortIfHung   = 0x0002
	settingChangeWait = 5000 // ms
)

var (
	modAdvapi32            = syscall.NewLazyDLL("advapi32.dll")
	procRegSetValueEx      = modAdvapi32.NewProc("RegSetValueExW")
	modUser32              = syscall.NewLazyDLL("user32.dll")
	procSendMessageTimeout = modUser32.NewProc("SendMessageTimeoutW")
)

// registerLauncherDir adds dir to the per-user PATH when no entry already
// names it and tells running shells' parents that the environment changed.
func registerLauncherDir(dir string) error {
	dir = filepath.Clean(dir)
	if !filepath.IsAbs(dir) {
		return errUnsafePath
	}
	keyPath, err := syscall.UTF16PtrFromString("Environment")
	if err != nil {
		return err
	}
	var key syscall.Handle
	if err := syscall.RegOpenKeyEx(syscall.HKEY_CURRENT_USER, keyPath, 0, syscall.KEY_READ|syscall.KEY_WRITE, &key); err != nil {
		return err
	}
	defer syscall.RegCloseKey(key)
	existing, valueType := regStringTyped(key, "Path")
	merged, changed := mergeUserPath(existing, dir)
	if !changed {
		return nil
	}
	if valueType != syscall.REG_SZ {
		valueType = syscall.REG_EXPAND_SZ
	}
	if err := regSetString(key, "Path", valueType, merged); err != nil {
		return err
	}
	broadcastEnvironmentChange()
	return nil
}

// mergeUserPath appends dir to the ';'-separated PATH value unless an entry
// already names it (case-insensitive, %VAR% entries expanded, trailing
// separators ignored). It returns the value to store and whether it changed.
func mergeUserPath(existing, dir string) (string, bool) {
	want := strings.ToLower(strings.TrimRight(filepath.Clean(dir), `\/`))
	for _, entry := range strings.Split(existing, ";") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		expanded := strings.ToLower(strings.TrimRight(filepath.Clean(expandWindowsEnv(entry)), `\/`))
		if expanded == want {
			return existing, false
		}
	}
	trimmed := strings.TrimRight(strings.TrimSpace(existing), ";")
	if trimmed == "" {
		return dir, true
	}
	return trimmed + ";" + dir, true
}

// expandWindowsEnv expands %NAME% references the way the shell does for
// REG_EXPAND_SZ values; unknown names are left as written.
func expandWindowsEnv(value string) string {
	var builder strings.Builder
	rest := value
	for {
		start := strings.IndexByte(rest, '%')
		if start < 0 {
			builder.WriteString(rest)
			return builder.String()
		}
		end := strings.IndexByte(rest[start+1:], '%')
		if end < 0 {
			builder.WriteString(rest)
			return builder.String()
		}
		name := rest[start+1 : start+1+end]
		builder.WriteString(rest[:start])
		if expanded, ok := os.LookupEnv(name); ok && name != "" {
			builder.WriteString(expanded)
		} else {
			builder.WriteString("%" + name + "%")
		}
		rest = rest[start+1+end+1:]
	}
}

func regStringTyped(key syscall.Handle, name string) (string, uint32) {
	namePtr, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return "", 0
	}
	var valueType, size uint32
	if err := syscall.RegQueryValueEx(key, namePtr, nil, &valueType, nil, &size); err != nil || size == 0 {
		return "", 0
	}
	if valueType != syscall.REG_SZ && valueType != syscall.REG_EXPAND_SZ {
		return "", 0
	}
	buf := make([]uint16, size/2+1)
	if err := syscall.RegQueryValueEx(key, namePtr, nil, &valueType, (*byte)(unsafe.Pointer(&buf[0])), &size); err != nil {
		return "", 0
	}
	return syscall.UTF16ToString(buf), valueType
}

func regSetString(key syscall.Handle, name string, valueType uint32, value string) error {
	namePtr, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	data, err := syscall.UTF16FromString(value)
	if err != nil {
		return err
	}
	r1, _, callErr := procRegSetValueEx.Call(
		uintptr(key),
		uintptr(unsafe.Pointer(namePtr)),
		0,
		uintptr(valueType),
		uintptr(unsafe.Pointer(&data[0])),
		uintptr(len(data)*2),
	)
	if r1 != 0 {
		if callErr != nil && !errors.Is(callErr, syscall.Errno(0)) {
			return callErr
		}
		return syscall.Errno(r1)
	}
	return nil
}

func broadcastEnvironmentChange() {
	environment, err := syscall.UTF16PtrFromString("Environment")
	if err != nil {
		return
	}
	var result uintptr
	_, _, _ = procSendMessageTimeout.Call(
		uintptr(hwndBroadcast),
		uintptr(wmSettingChange),
		0,
		uintptr(unsafe.Pointer(environment)),
		uintptr(smtoAbortIfHung),
		uintptr(settingChangeWait),
		uintptr(unsafe.Pointer(&result)),
	)
}
