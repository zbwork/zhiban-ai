//go:build windows

package netproxy

import (
	"context"
	"errors"
	"strings"
	"syscall"
	"unsafe"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

// Windows: Codex reads the per-user Internet Settings proxy; NO_PROXY is a
// per-user environment variable (HKCU\Environment) that Explorer, and every
// terminal and app started from it afterwards, picks up once WM_SETTINGCHANGE
// is broadcast. Windows variables are case-insensitive: one NO_PROXY value.

const (
	hwndBroadcast     = 0xffff
	wmSettingChange   = 0x001a
	smtoAbortIfHung   = 0x0002
	settingChangeWait = 5000 // ms
)

const (
	internetSettingsKey = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`
	// InternetSetOption options that make WinINET clients re-read the proxy
	// settings (Chromium watches the registry key itself).
	internetOptionRefresh         = 37
	internetOptionSettingsChanged = 39
)

var (
	modAdvapi32            = syscall.NewLazyDLL("advapi32.dll")
	procRegSetValueEx      = modAdvapi32.NewProc("RegSetValueExW")
	modUser32              = syscall.NewLazyDLL("user32.dll")
	procSendMessageTimeout = modUser32.NewProc("SendMessageTimeoutW")
	modWininet             = syscall.NewLazyDLL("wininet.dll")
	procInternetSetOption  = modWininet.NewProc("InternetSetOptionW")
)

type windowsPlatform struct{}

func newPlatform(string, *shellenv.LoginShellLookup) platform { return windowsPlatform{} }

func (windowsPlatform) supported() bool { return true }

func (windowsPlatform) systemProxy(context.Context) SystemProxy {
	key, err := openKey(internetSettingsKey, syscall.KEY_READ)
	if err != nil {
		return SystemProxy{}
	}
	defer syscall.RegCloseKey(key)
	if regDWORD(key, "ProxyEnable") != 1 {
		return SystemProxy{}
	}
	server := strings.TrimSpace(regString(key, "ProxyServer"))
	if server == "" {
		return SystemProxy{}
	}
	// "host:port" or "http=host:port;https=host:port;socks=host:port".
	endpoint := server
	for _, part := range strings.Split(server, ";") {
		if scheme, value, found := strings.Cut(part, "="); found {
			if strings.EqualFold(scheme, "https") || endpoint == server {
				endpoint = value
			}
		}
	}
	return SystemProxy{Enabled: true, Endpoint: endpoint}
}

func (p windowsPlatform) coverage(ctx context.Context, hosts []string) map[string]bool {
	return map[string]bool{
		"user_env":          covers(p.noProxy(ctx), hosts),
		coveredSystemBypass: bypassCovers(p.proxyOverride(), plainHosts(hosts)),
	}
}

// proxyOverride is the system proxy bypass list ("a;b;<local>").
func (windowsPlatform) proxyOverride() []string {
	key, err := openKey(internetSettingsKey, syscall.KEY_READ)
	if err != nil {
		return nil
	}
	defer syscall.RegCloseKey(key)
	return strings.Split(regString(key, "ProxyOverride"), ";")
}

// applyProxyOverride adds the gateway to the system bypass list for clients on
// the system network stack (Claude Desktop's model discovery). Best effort: the
// status reports whether it took, NO_PROXY is what the CLIs need.
func (p windowsPlatform) applyProxyOverride(hosts []string) {
	merged, added := mergeBypass(p.proxyOverride(), bypassEntries(hosts))
	if len(added) == 0 {
		return
	}
	key, err := openKey(internetSettingsKey, syscall.KEY_READ|syscall.KEY_WRITE)
	if err != nil {
		return
	}
	defer syscall.RegCloseKey(key)
	if regSetString(key, "ProxyOverride", strings.Join(merged, ";")) != nil {
		return
	}
	_, _, _ = procInternetSetOption.Call(0, internetOptionSettingsChanged, 0, 0)
	_, _, _ = procInternetSetOption.Call(0, internetOptionRefresh, 0, 0)
}

func (windowsPlatform) noProxy(context.Context) string {
	key, err := openKey("Environment", syscall.KEY_READ)
	if err != nil {
		return ""
	}
	defer syscall.RegCloseKey(key)
	return regString(key, "NO_PROXY")
}

func (p windowsPlatform) apply(_ context.Context, hosts []string) error {
	p.applyProxyOverride(hosts)
	key, err := openKey("Environment", syscall.KEY_READ|syscall.KEY_WRITE)
	if err != nil {
		return err
	}
	defer syscall.RegCloseKey(key)
	merged, added := mergeList(regString(key, "NO_PROXY"), hosts)
	if len(added) == 0 {
		return nil
	}
	if err := regSetString(key, "NO_PROXY", merged); err != nil {
		return err
	}
	broadcastEnvironmentChange()
	return nil
}

func openKey(path string, access uint32) (syscall.Handle, error) {
	pathPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	var key syscall.Handle
	if err := syscall.RegOpenKeyEx(syscall.HKEY_CURRENT_USER, pathPtr, 0, access, &key); err != nil {
		return 0, err
	}
	return key, nil
}

func regString(key syscall.Handle, name string) string {
	namePtr, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return ""
	}
	var valueType, size uint32
	if err := syscall.RegQueryValueEx(key, namePtr, nil, &valueType, nil, &size); err != nil || size == 0 {
		return ""
	}
	if valueType != syscall.REG_SZ && valueType != syscall.REG_EXPAND_SZ {
		return ""
	}
	buf := make([]uint16, size/2+1)
	if err := syscall.RegQueryValueEx(key, namePtr, nil, &valueType, (*byte)(unsafe.Pointer(&buf[0])), &size); err != nil {
		return ""
	}
	return syscall.UTF16ToString(buf)
}

func regDWORD(key syscall.Handle, name string) uint32 {
	namePtr, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return 0
	}
	var valueType, value uint32
	size := uint32(4)
	if err := syscall.RegQueryValueEx(key, namePtr, nil, &valueType, (*byte)(unsafe.Pointer(&value)), &size); err != nil || valueType != syscall.REG_DWORD {
		return 0
	}
	return value
}

func regSetString(key syscall.Handle, name, value string) error {
	namePtr, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	data, err := syscall.UTF16FromString(value)
	if err != nil {
		return err
	}
	r1, _, callErr := procRegSetValueEx.Call(uintptr(key), uintptr(unsafe.Pointer(namePtr)), 0,
		uintptr(syscall.REG_SZ), uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)*2))
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
	_, _, _ = procSendMessageTimeout.Call(hwndBroadcast, wmSettingChange, 0,
		uintptr(unsafe.Pointer(environment)), smtoAbortIfHung, settingChangeWait, uintptr(unsafe.Pointer(&result)))
}
