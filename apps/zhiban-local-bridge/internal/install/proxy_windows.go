//go:build windows

package install

import (
	"net/url"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

// systemHTTPSProxy returns the user's Windows proxy for https as an http://
// URL: the WinINet setting (HKCU\...\Internet Settings ProxyEnable /
// ProxyServer, which is what "Settings → Network → Proxy" writes), falling back
// to HTTPS_PROXY / https_proxy when the App passed those through. Integrity of
// downloads never depends on the transport, so an unusable proxy only costs
// reachability.
func systemHTTPSProxy() *url.URL {
	if proxy := internetSettingsHTTPSProxy(); proxy != nil {
		return proxy
	}
	for _, name := range []string{"HTTPS_PROXY", "https_proxy"} {
		if value := strings.TrimSpace(os.Getenv(name)); value != "" {
			return parseProxyHostPort(value)
		}
	}
	return nil
}

func internetSettingsHTTPSProxy() *url.URL {
	keyPath, err := syscall.UTF16PtrFromString(`Software\Microsoft\Windows\CurrentVersion\Internet Settings`)
	if err != nil {
		return nil
	}
	var key syscall.Handle
	if err := syscall.RegOpenKeyEx(syscall.HKEY_CURRENT_USER, keyPath, 0, syscall.KEY_READ, &key); err != nil {
		return nil
	}
	defer syscall.RegCloseKey(key)
	if regDWORD(key, "ProxyEnable") != 1 {
		return nil
	}
	server := strings.TrimSpace(regString(key, "ProxyServer"))
	if server == "" {
		return nil
	}
	// Either "host:port" for every protocol or "http=…;https=…;ftp=…;socks=…".
	if strings.Contains(server, "=") {
		chosen := ""
		for _, entry := range strings.Split(server, ";") {
			scheme, address, ok := strings.Cut(strings.TrimSpace(entry), "=")
			if !ok {
				continue
			}
			switch strings.ToLower(strings.TrimSpace(scheme)) {
			case "https":
				chosen = address
			case "http":
				if chosen == "" {
					chosen = address
				}
			}
		}
		server = chosen
	}
	return parseProxyHostPort(server)
}

// parseProxyHostPort accepts "host:port" or "http://host:port" and returns an
// http:// proxy URL, or nil when the value is not a plain host and port.
func parseProxyHostPort(value string) *url.URL {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	if !strings.Contains(value, "://") {
		value = "http://" + value
	}
	parsed, err := url.Parse(value)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" ||
		parsed.Port() == "" || parsed.User != nil || parsed.Path != "" && parsed.Path != "/" {
		return nil
	}
	parsed.Path = ""
	return parsed
}

func regDWORD(key syscall.Handle, name string) uint32 {
	namePtr, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return 0
	}
	var valueType, size uint32 = 0, 4
	var value uint32
	if err := syscall.RegQueryValueEx(key, namePtr, nil, &valueType, (*byte)(unsafe.Pointer(&value)), &size); err != nil {
		return 0
	}
	if valueType != syscall.REG_DWORD {
		return 0
	}
	return value
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
