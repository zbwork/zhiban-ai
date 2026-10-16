package claudecode

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// Claude Desktop only reads the third-party inference configuration library
// (Claude-3p configLibrary: inferenceProvider / inferenceGatewayBaseUrl /
// inferenceCredentialHelper) from a certain release on; an older app ignores
// what Zhiban writes and keeps using the official service while the card would
// claim "已配置" (2026-09-15). The app's archive names those keys, so their
// absence identifies an app that cannot be switched. The check is by capability
// rather than version number: Anthropic does not document the first release.
var thirdPartyInferenceMarkers = [][]byte{
	[]byte("inferenceGatewayBaseUrl"),
	[]byte("inferenceCredentialHelper"),
}

var thirdPartyCache sync.Map // manifestCacheKey -> bool

// SupportsThirdPartyInference reports whether the Claude Desktop bundle at
// bundlePath understands the third-party inference configuration. known is
// false when the archive cannot be read; callers must not block on that.
func SupportsThirdPartyInference(bundlePath string) (supported, known bool) {
	asarPath := filepath.Join(filepath.Clean(bundlePath), asarRelativePath)
	info, err := os.Lstat(asarPath)
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxAsarBytes {
		return false, false
	}
	key := manifestCacheKey{path: asarPath, size: info.Size(), modTime: info.ModTime().UnixNano()}
	if cached, ok := thirdPartyCache.Load(key); ok {
		return cached.(bool), true
	}
	file, err := os.Open(asarPath)
	if err != nil {
		return false, false
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxAsarBytes+1))
	if err != nil || int64(len(data)) != info.Size() {
		return false, false
	}
	supported = true
	for _, marker := range thirdPartyInferenceMarkers {
		if !bytes.Contains(data, marker) {
			supported = false
			break
		}
	}
	thirdPartyCache.Store(key, supported)
	return supported, true
}
