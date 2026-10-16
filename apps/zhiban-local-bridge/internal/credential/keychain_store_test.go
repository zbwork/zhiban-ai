package credential

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
)

type memoryItemBackend struct {
	items      map[string][]byte
	saveErr    error
	loadErr    error
	deleteErr  error
	deletedKey string
}

func (b *memoryItemBackend) Load(_ context.Context, account string) ([]byte, error) {
	if b.loadErr != nil {
		return nil, b.loadErr
	}
	value, ok := b.items[account]
	if !ok {
		return nil, ErrNotFound
	}
	return append([]byte(nil), value...), nil
}

func (b *memoryItemBackend) Save(_ context.Context, account string, value []byte) error {
	if b.saveErr != nil {
		return b.saveErr
	}
	if b.items == nil {
		b.items = make(map[string][]byte)
	}
	b.items[account] = append([]byte(nil), value...)
	return nil
}

func (b *memoryItemBackend) Delete(_ context.Context, account string) error {
	if b.deleteErr != nil {
		return b.deleteErr
	}
	b.deletedKey = account
	if _, ok := b.items[account]; !ok {
		return ErrNotFound
	}
	delete(b.items, account)
	return nil
}

func TestKeychainStoreRoundTripsIdentityAndAuthorization(t *testing.T) {
	t.Parallel()

	backend := &memoryItemBackend{}
	store := newKeychainStore(backend)
	identity := Identity{SchemaVersion: identitySchemaVersion, DeviceID: testDeviceID, PrivateKeySeed: bytes.Repeat([]byte{7}, 32)}
	if err := store.SaveIdentity(context.Background(), identity); err != nil {
		t.Fatal(err)
	}
	loadedIdentity, err := store.LoadIdentity(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if loadedIdentity.DeviceID != identity.DeviceID || !bytes.Equal(loadedIdentity.PrivateKeySeed, identity.PrivateKeySeed) {
		t.Fatalf("identity round trip = %+v", loadedIdentity)
	}

	deviceCredential := "lctd." + testCredentialID + "." + strings.Repeat("A", 48)
	authorization := Authorization{
		SchemaVersion: authorizationSchemaVersion, DeviceID: testDeviceID,
		CredentialID: testCredentialID, DeviceCredential: deviceCredential,
		Environment: EnvironmentProd, ProfileVersions: map[string]string{TargetCodexCLI: "2026.09.07.1"},
	}
	if err := store.SaveAuthorization(context.Background(), authorization); err != nil {
		t.Fatal(err)
	}
	loadedAuthorization, err := store.LoadAuthorization(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if loadedAuthorization.DeviceCredential != deviceCredential || loadedAuthorization.ProfileVersions[TargetCodexCLI] != "2026.09.07.1" {
		t.Fatalf("authorization round trip = %+v", loadedAuthorization)
	}
	if err := store.DeleteAuthorization(context.Background()); err != nil {
		t.Fatal(err)
	}
	if backend.deletedKey != keychainAuthorizationAccount {
		t.Fatalf("deleted account = %q", backend.deletedKey)
	}
	if _, err := store.LoadIdentity(context.Background()); err != nil {
		t.Fatalf("identity was deleted with authorization: %v", err)
	}
}

func TestKeychainStoreRejectsInvalidOrCorruptItems(t *testing.T) {
	t.Parallel()

	backend := &memoryItemBackend{items: map[string][]byte{
		keychainIdentityAccount:      []byte(`{"schema_version":1,"device_id":"bad","private_key_seed":"AA=="}`),
		keychainAuthorizationAccount: []byte(`{"schema_version":1,"device_id":"` + testDeviceID + `","unexpected":"secret"}`),
	}}
	store := newKeychainStore(backend)
	if _, err := store.LoadIdentity(context.Background()); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("corrupt identity error = %v, want ErrInvalidData", err)
	}
	if _, err := store.LoadAuthorization(context.Background()); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("corrupt authorization error = %v, want ErrInvalidData", err)
	}
	if err := store.SaveIdentity(context.Background(), Identity{}); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("invalid identity save error = %v, want ErrInvalidData", err)
	}
	if err := store.SaveAuthorization(context.Background(), Authorization{}); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("invalid authorization save error = %v, want ErrInvalidData", err)
	}
	backend.items[keychainIdentityAccount] = bytes.Repeat([]byte("x"), maxKeychainItemBytes+1)
	if _, err := store.LoadIdentity(context.Background()); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("oversized identity error = %v, want ErrInvalidData", err)
	}
}

func TestKeychainStorePropagatesBackendFailureWithoutFallback(t *testing.T) {
	t.Parallel()

	backendFailure := errors.New("keychain locked")
	store := newKeychainStore(&memoryItemBackend{loadErr: backendFailure})
	if _, err := store.LoadIdentity(context.Background()); !errors.Is(err, backendFailure) {
		t.Fatalf("LoadIdentity() error = %v", err)
	}
	if _, err := store.LoadAuthorization(context.Background()); !errors.Is(err, backendFailure) {
		t.Fatalf("LoadAuthorization() error = %v", err)
	}
}
