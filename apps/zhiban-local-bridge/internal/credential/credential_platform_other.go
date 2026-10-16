//go:build !darwin && !windows

package credential

// NewSystemCredentialStore returns the (unavailable) store on platforms with no
// secure backend wired: any non-macOS, non-Windows target.
func NewSystemCredentialStore() Store {
	return NewMacOSKeychainStore()
}
