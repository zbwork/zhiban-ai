//go:build !darwin || !cgo

package credential

import "context"

type unavailableKeychainBackend struct{}

func NewMacOSKeychainStore() Store {
	return newKeychainStore(unavailableKeychainBackend{})
}

func (unavailableKeychainBackend) Load(context.Context, string) ([]byte, error) {
	return nil, ErrKeychainUnavailable
}

func (unavailableKeychainBackend) Save(context.Context, string, []byte) error {
	return ErrKeychainUnavailable
}

func (unavailableKeychainBackend) Delete(context.Context, string) error {
	return ErrKeychainUnavailable
}
