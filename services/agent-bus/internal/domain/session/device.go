package session

import "strings"

// DeviceClass groups platforms exactly as the client IM device policy does.
// Unknown clients do not displace a known desktop or phone login.
func DeviceClass(platform string) string {
	switch strings.ToLower(strings.TrimSpace(platform)) {
	case "desktop", "macos", "macosx", "darwin", "windows", "linux":
		return "desktop"
	case "mobile", "ios", "android":
		return "mobile"
	case "web":
		return "web"
	default:
		return ""
	}
}

func DeviceClassPlatforms(platform string) []string {
	switch DeviceClass(platform) {
	case "desktop":
		return []string{"desktop", "macos", "macosx", "darwin", "windows", "linux"}
	case "mobile":
		return []string{"mobile", "ios", "android"}
	case "web":
		return []string{"web"}
	default:
		return []string{}
	}
}
