package billing

import "strings"

// NormalizeEntitlementLimitBytes folds a storage entitlement value/unit into bytes.
// nil value means unlimited and is returned as nil.
func NormalizeEntitlementLimitBytes(value *int64, unit *string) *int64 {
	if value == nil {
		return nil
	}
	v := *value
	u := ""
	if unit != nil {
		u = strings.ToUpper(strings.TrimSpace(*unit))
	}
	switch u {
	case "GB", "G":
		v *= 1073741824
	case "MB", "M":
		v *= 1048576
	case "KB", "K":
		v *= 1024
	}
	return &v
}

func IsStorageFeature(code string) bool {
	switch strings.TrimSpace(code) {
	case "knowledge_file_storage_limit", "drive_file_storage_limit":
		return true
	default:
		return false
	}
}
