//go:build (!darwin || !cgo) && !windows

package install

import "net/url"

func systemHTTPSProxy() *url.URL { return nil }
