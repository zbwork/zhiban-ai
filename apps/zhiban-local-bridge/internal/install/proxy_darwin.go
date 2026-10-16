//go:build darwin && cgo

package install

/*
#cgo LDFLAGS: -framework CoreFoundation -framework CFNetwork
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>

// zb_install_https_proxy copies the user's system HTTPS proxy (System
// Settings > Network > Proxies) into host/port. Returns 1 when an explicit
// HTTPS proxy is enabled, 0 otherwise. PAC configurations are not evaluated.
static int zb_install_https_proxy(char *host, int host_len, int *port) {
	CFDictionaryRef settings = CFNetworkCopySystemProxySettings();
	if (settings == NULL) {
		return 0;
	}
	int result = 0;
	int enabled = 0;
	CFNumberRef enable = (CFNumberRef)CFDictionaryGetValue(settings, kCFNetworkProxiesHTTPSEnable);
	if (enable != NULL && CFGetTypeID(enable) == CFNumberGetTypeID()) {
		CFNumberGetValue(enable, kCFNumberIntType, &enabled);
	}
	if (enabled) {
		CFStringRef proxy_host = (CFStringRef)CFDictionaryGetValue(settings, kCFNetworkProxiesHTTPSProxy);
		CFNumberRef proxy_port = (CFNumberRef)CFDictionaryGetValue(settings, kCFNetworkProxiesHTTPSPort);
		if (proxy_host != NULL && proxy_port != NULL &&
			CFGetTypeID(proxy_host) == CFStringGetTypeID() && CFGetTypeID(proxy_port) == CFNumberGetTypeID() &&
			CFStringGetCString(proxy_host, host, host_len, kCFStringEncodingUTF8) &&
			CFNumberGetValue(proxy_port, kCFNumberIntType, port)) {
			result = 1;
		}
	}
	CFRelease(settings);
	return result;
}
*/
import "C"

import (
	"net"
	"net/url"
	"strconv"
	"strings"
	"unsafe"
)

// systemHTTPSProxy returns the enabled system HTTPS proxy as an http:// URL,
// or nil when none is configured. The Bridge is launched with a minimal
// environment, so this is the only proxy source it consults.
func systemHTTPSProxy() *url.URL {
	buffer := make([]byte, 256)
	var port C.int
	if C.zb_install_https_proxy((*C.char)(unsafe.Pointer(&buffer[0])), C.int(len(buffer)), &port) != 1 {
		return nil
	}
	host := strings.TrimSpace(C.GoString((*C.char)(unsafe.Pointer(&buffer[0]))))
	if host == "" || port <= 0 || port > 65535 || strings.ContainsAny(host, " /\\@?#") {
		return nil
	}
	if net.ParseIP(host) == nil {
		for _, label := range strings.Split(host, ".") {
			if label == "" || len(label) > 63 {
				return nil
			}
		}
	}
	return &url.URL{Scheme: "http", Host: net.JoinHostPort(host, strconv.Itoa(int(port)))}
}
