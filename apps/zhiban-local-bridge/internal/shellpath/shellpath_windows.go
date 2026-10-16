//go:build windows

package shellpath

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

// Windows has no login shell to ask: a GUI process inherits the user's
// environment, and what `codex` runs in a new terminal is decided by the
// per-user PATH (HKCU\Environment) laid after the machine PATH. So arranging
// the PATH here means putting the managed launcher directory **first** in the
// user PATH — appending it (what the publishers' installers do) loses against
// an npm prefix that is already there — and resolving by hand against the
// value that will apply, because this process's own PATH is a snapshot taken
// when Zhiban started.
//
// The previous value is written to the backup directory before the change, so
// it can be put back by hand.

var (
	modUser32              = syscall.NewLazyDLL("user32.dll")
	procSendMessageTimeout = modUser32.NewProc("SendMessageTimeoutW")
)

func (e *Ensurer) resolves(_ context.Context, name, launcherPath string) bool {
	user, machine, err := e.readPath()
	if err != nil {
		return false
	}
	resolved, ok := resolveInPath(name, machine, user)
	return ok && sameFile(resolved, launcherPath)
}

func (e *Ensurer) arrange(launcherPath string) error {
	directory := filepath.Dir(filepath.Clean(launcherPath))
	if !filepath.IsAbs(directory) {
		return ErrUnsupportedShell
	}
	user, _, err := e.readPath()
	if err != nil {
		return fmt.Errorf("%w: user PATH", ErrWriteFailed)
	}
	updated, changed := prependPath(user, directory)
	if !changed {
		// Already first and the command still resolves elsewhere: the machine
		// PATH wins, which this cannot fix.
		return ErrNotApplied
	}
	if err := e.backup("user-path", []byte(user)); err != nil {
		return err
	}
	if err := e.writePath(updated); err != nil {
		return fmt.Errorf("%w: user PATH", ErrWriteFailed)
	}
	broadcastEnvironmentChange()
	return nil
}

// prependPath puts directory first, removing an entry that already names it.
func prependPath(existing, directory string) (string, bool) {
	want := normalizePathEntry(directory)
	kept := make([]string, 0, 16)
	for index, entry := range strings.Split(existing, ";") {
		trimmed := strings.TrimSpace(entry)
		if trimmed == "" {
			continue
		}
		if normalizePathEntry(expandWindowsEnv(trimmed)) == want {
			if index == 0 {
				return existing, false
			}
			continue
		}
		kept = append(kept, trimmed)
	}
	return strings.Join(append([]string{directory}, kept...), ";"), true
}

func normalizePathEntry(value string) string {
	return strings.ToLower(strings.TrimRight(filepath.Clean(value), `\/`))
}

// LookPath answers what a terminal opened from now on runs for name, from the
// registry's machine and user PATH rather than this process's own (the
// snapshot Zhiban started with, stale once arrange() has put the launcher
// directory first). ok is false when the registry cannot be read or nothing
// on that PATH names the command; callers fall back to exec.LookPath then.
func LookPath(name string) (string, bool) {
	if name == "" || strings.ContainsAny(name, `\/:`) {
		return "", false
	}
	user, machine, err := readRegistryPaths()
	if err != nil {
		return "", false
	}
	return resolveInPath(name, machine, user)
}

// resolveInPath answers what a new terminal would run for name: the machine
// PATH first, then the user PATH, each entry tried with every PATHEXT suffix.
func resolveInPath(name, machine, user string) (string, bool) {
	extensions := strings.Split(strings.ToLower(os.Getenv("PATHEXT")), ";")
	if len(extensions) == 0 || strings.TrimSpace(extensions[0]) == "" {
		extensions = []string{".com", ".exe", ".bat", ".cmd"}
	}
	for _, entry := range append(strings.Split(machine, ";"), strings.Split(user, ";")...) {
		entry = strings.TrimSpace(expandWindowsEnv(entry))
		if entry == "" || !filepath.IsAbs(entry) {
			continue
		}
		for _, extension := range extensions {
			extension = strings.TrimSpace(extension)
			if extension == "" {
				continue
			}
			candidate := filepath.Join(entry, name+extension)
			if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
				return candidate, true
			}
		}
	}
	return "", false
}

func (e *Ensurer) readPath() (string, string, error) {
	if e.ReadPath != nil {
		return e.ReadPath()
	}
	return readRegistryPaths()
}

func (e *Ensurer) writePath(value string) error {
	if e.WritePath != nil {
		return e.WritePath(value)
	}
	return writeUserPath(value)
}

func readRegistryPaths() (string, string, error) {
	user, _, err := readRegistryString(syscall.HKEY_CURRENT_USER, `Environment`, "Path")
	if err != nil {
		return "", "", err
	}
	machine, _, machineErr := readRegistryString(syscall.HKEY_LOCAL_MACHINE,
		`SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, "Path")
	if machineErr != nil {
		machine = ""
	}
	return user, machine, nil
}

func readRegistryString(root syscall.Handle, keyPath, name string) (string, uint32, error) {
	pathPointer, err := syscall.UTF16PtrFromString(keyPath)
	if err != nil {
		return "", 0, err
	}
	var key syscall.Handle
	if err := syscall.RegOpenKeyEx(root, pathPointer, 0, syscall.KEY_READ, &key); err != nil {
		return "", 0, err
	}
	defer syscall.RegCloseKey(key)
	namePointer, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return "", 0, err
	}
	var valueType uint32
	var size uint32
	if err := syscall.RegQueryValueEx(key, namePointer, nil, &valueType, nil, &size); err != nil {
		return "", 0, err
	}
	buffer := make([]uint16, size/2+1)
	if err := syscall.RegQueryValueEx(key, namePointer, nil, &valueType,
		(*byte)(unsafe.Pointer(&buffer[0])), &size); err != nil {
		return "", 0, err
	}
	return syscall.UTF16ToString(buffer), valueType, nil
}

func writeUserPath(value string) error {
	keyPath, err := syscall.UTF16PtrFromString(`Environment`)
	if err != nil {
		return err
	}
	var key syscall.Handle
	if err := syscall.RegOpenKeyEx(syscall.HKEY_CURRENT_USER, keyPath, 0,
		syscall.KEY_READ|syscall.KEY_WRITE, &key); err != nil {
		return err
	}
	defer syscall.RegCloseKey(key)
	namePointer, err := syscall.UTF16PtrFromString("Path")
	if err != nil {
		return err
	}
	encoded, err := syscall.UTF16FromString(value)
	if err != nil {
		return err
	}
	// REG_EXPAND_SZ keeps %VAR% entries the user already had working.
	return regSetValue(key, namePointer, syscall.REG_EXPAND_SZ, encoded)
}

func regSetValue(key syscall.Handle, name *uint16, valueType uint32, encoded []uint16) error {
	procRegSetValueEx := syscall.NewLazyDLL("advapi32.dll").NewProc("RegSetValueExW")
	result, _, _ := procRegSetValueEx.Call(
		uintptr(key), uintptr(unsafe.Pointer(name)), 0, uintptr(valueType),
		uintptr(unsafe.Pointer(&encoded[0])), uintptr(len(encoded)*2),
	)
	if result != 0 {
		return syscall.Errno(result)
	}
	return nil
}

// expandWindowsEnv expands %NAME% references the way the shell does for
// REG_EXPAND_SZ values; unknown names are left as written.
func expandWindowsEnv(value string) string {
	var builder strings.Builder
	for {
		start := strings.Index(value, "%")
		if start < 0 {
			builder.WriteString(value)
			return builder.String()
		}
		end := strings.Index(value[start+1:], "%")
		if end < 0 {
			builder.WriteString(value)
			return builder.String()
		}
		name := value[start+1 : start+1+end]
		builder.WriteString(value[:start])
		if resolved, ok := os.LookupEnv(name); ok {
			builder.WriteString(resolved)
		} else {
			builder.WriteString("%" + name + "%")
		}
		value = value[start+end+2:]
	}
}

// broadcastEnvironmentChange tells Explorer (and through it new terminals)
// that the environment changed, so the user does not have to log out.
func broadcastEnvironmentChange() {
	const (
		hwndBroadcast   = 0xFFFF
		wmSettingChange = 0x001A
		smtoAbortIfHung = 0x0002
	)
	message, err := syscall.UTF16PtrFromString("Environment")
	if err != nil {
		return
	}
	var result uintptr
	_, _, _ = procSendMessageTimeout.Call(
		uintptr(hwndBroadcast), uintptr(wmSettingChange), 0,
		uintptr(unsafe.Pointer(message)), uintptr(smtoAbortIfHung), 5000,
		uintptr(unsafe.Pointer(&result)),
	)
}
