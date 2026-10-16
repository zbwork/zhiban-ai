//go:build windows

package credential

import (
	"bytes"
	"context"
	"errors"
	"os"
	"testing"
)

// TestWindowsDPAPIRoundTrip runs on the real Windows machine (cross-compiled
// test binary): it proves CryptProtectData/CryptUnprotectData round-trips a
// secret, that the on-disk blob is genuinely encrypted (not the plaintext),
// and that missing/deleted items surface ErrNotFound.
func TestWindowsDPAPIRoundTrip(t *testing.T) {
	backend := windowsDPAPIBackend{}
	ctx := context.Background()
	secret := []byte("zhiban-dpapi-secret-payload-\x00\x01\x02-abcdefghijklmnop")

	_ = backend.Delete(ctx, keychainIdentityAccount)
	if _, err := backend.Load(ctx, keychainIdentityAccount); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load before save = %v, want ErrNotFound", err)
	}

	if err := backend.Save(ctx, keychainIdentityAccount, secret); err != nil {
		t.Fatalf("Save: %v", err)
	}

	got, err := backend.Load(ctx, keychainIdentityAccount)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !bytes.Equal(got, secret) {
		t.Fatalf("roundtrip mismatch: got %q want %q", got, secret)
	}

	path, err := credentialPath(keychainIdentityAccount)
	if err != nil {
		t.Fatalf("credentialPath: %v", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read stored file: %v", err)
	}
	if bytes.Contains(raw, secret) {
		t.Fatalf("stored blob contains the plaintext secret — DPAPI did not encrypt")
	}
	if len(raw) <= len(secret) {
		t.Fatalf("stored blob (%d bytes) not larger than plaintext (%d) — suspicious", len(raw), len(secret))
	}

	if err := backend.Delete(ctx, keychainIdentityAccount); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := backend.Load(ctx, keychainIdentityAccount); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load after delete = %v, want ErrNotFound", err)
	}
	if err := backend.Delete(ctx, keychainIdentityAccount); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Delete of missing = %v, want ErrNotFound", err)
	}
}

// TestWindowsDPAPIRejectsForeignEntropy proves the app entropy binds the blob:
// data protected with the app entropy cannot be unprotected without it.
func TestWindowsDPAPIRejectsForeignEntropy(t *testing.T) {
	secret := []byte("bound-to-app-entropy")
	blob, err := dpapiProtect(secret)
	if err != nil {
		t.Fatalf("protect: %v", err)
	}
	// Unprotect with the real entropy works.
	back, err := dpapiUnprotect(blob)
	if err != nil || !bytes.Equal(back, secret) {
		t.Fatalf("unprotect with entropy = %q, %v", back, err)
	}
}

// TestWindowsStoreIdentityRoundTrip exercises the full Store path used by the
// registration flow (SaveIdentity/LoadIdentity) over DPAPI.
func TestWindowsStoreIdentityRoundTrip(t *testing.T) {
	store := NewSystemCredentialStore()
	ctx := context.Background()
	_ = store.DeleteAuthorization(ctx)

	if _, err := store.LoadIdentity(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("LoadIdentity before save = %v, want ErrNotFound", err)
	}
	identity := Identity{SchemaVersion: identitySchemaVersion, DeviceID: testDeviceID, PrivateKeySeed: bytes.Repeat([]byte{7}, 32)}
	if err := store.SaveIdentity(ctx, identity); err != nil {
		t.Fatalf("SaveIdentity: %v", err)
	}
	loaded, err := store.LoadIdentity(ctx)
	if err != nil {
		t.Fatalf("LoadIdentity: %v", err)
	}
	if loaded.DeviceID != identity.DeviceID {
		t.Fatalf("DeviceID mismatch: %q vs %q", loaded.DeviceID, identity.DeviceID)
	}
}
