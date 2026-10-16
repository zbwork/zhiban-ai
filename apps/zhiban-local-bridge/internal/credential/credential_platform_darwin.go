//go:build darwin

package credential

// NewSystemCredentialStore returns the data-protection Keychain store on macOS.
func NewSystemCredentialStore() Store {
	return NewMacOSKeychainStore()
}
