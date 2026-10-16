//go:build darwin && cgo

package credential

import (
	"errors"
	"testing"
)

func TestNewMacOSKeychainStoreIsAvailableWithoutTouchingKeychain(t *testing.T) {
	t.Parallel()

	store := NewMacOSKeychainStore()
	if store == nil {
		t.Fatal("NewMacOSKeychainStore() returned nil")
	}
}

func TestKeychainStatusMappingIsFailClosed(t *testing.T) {
	t.Parallel()

	if err := keychainStatusError(keychainStatusSuccess); err != nil {
		t.Fatalf("success status error = %v", err)
	}
	if err := keychainStatusError(keychainStatusItemNotFound); !errors.Is(err, ErrNotFound) {
		t.Fatalf("not-found status error = %v", err)
	}
	if err := keychainStatusError(-34018); !errors.Is(err, ErrKeychainUnavailable) {
		t.Fatalf("missing-entitlement status error = %v", err)
	}
}
