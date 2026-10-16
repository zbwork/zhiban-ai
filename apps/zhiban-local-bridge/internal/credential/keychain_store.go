package credential

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const (
	keychainIdentityAccount      = "device-identity-v1"
	keychainAuthorizationAccount = "device-authorization-v1"
	maxKeychainItemBytes         = 16 << 10
)

type secureItemBackend interface {
	Load(context.Context, string) ([]byte, error)
	Save(context.Context, string, []byte) error
	Delete(context.Context, string) error
}

type keychainStore struct {
	backend secureItemBackend
}

func newKeychainStore(backend secureItemBackend) *keychainStore {
	return &keychainStore{backend: backend}
}

func (s *keychainStore) LoadIdentity(ctx context.Context) (Identity, error) {
	var identity Identity
	if err := s.load(ctx, keychainIdentityAccount, &identity); err != nil {
		return Identity{}, err
	}
	if err := validateIdentity(identity); err != nil {
		zeroBytes(identity.PrivateKeySeed)
		return Identity{}, err
	}
	return identity, nil
}

func (s *keychainStore) SaveIdentity(ctx context.Context, identity Identity) error {
	if err := validateIdentity(identity); err != nil {
		return err
	}
	return s.save(ctx, keychainIdentityAccount, identity)
}

func (s *keychainStore) LoadAuthorization(ctx context.Context) (Authorization, error) {
	var authorization Authorization
	if err := s.load(ctx, keychainAuthorizationAccount, &authorization); err != nil {
		return Authorization{}, err
	}
	if err := validateAuthorization(authorization); err != nil {
		return Authorization{}, err
	}
	return authorization, nil
}

func (s *keychainStore) SaveAuthorization(ctx context.Context, authorization Authorization) error {
	if err := validateAuthorization(authorization); err != nil {
		return err
	}
	return s.save(ctx, keychainAuthorizationAccount, authorization)
}

func (s *keychainStore) DeleteAuthorization(ctx context.Context) error {
	if s == nil || s.backend == nil {
		return ErrInvalidData
	}
	return s.backend.Delete(ctx, keychainAuthorizationAccount)
}

func (s *keychainStore) load(ctx context.Context, account string, destination any) error {
	if s == nil || s.backend == nil {
		return ErrInvalidData
	}
	raw, err := s.backend.Load(ctx, account)
	if err != nil {
		return err
	}
	defer zeroBytes(raw)
	if len(raw) == 0 || len(raw) > maxKeychainItemBytes {
		return ErrInvalidData
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return ErrInvalidData
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return ErrInvalidData
	}
	return nil
}

func (s *keychainStore) save(ctx context.Context, account string, value any) error {
	if s == nil || s.backend == nil {
		return ErrInvalidData
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("credential: encode keychain item: %w", err)
	}
	defer zeroBytes(raw)
	if len(raw) == 0 || len(raw) > maxKeychainItemBytes {
		return ErrInvalidData
	}
	return s.backend.Save(ctx, account, raw)
}

func validateIdentity(identity Identity) error {
	if identity.SchemaVersion != identitySchemaVersion || !validUUID(identity.DeviceID) || len(identity.PrivateKeySeed) != ed25519.SeedSize {
		return ErrInvalidData
	}
	return nil
}

func validateAuthorization(authorization Authorization) error {
	credentialID, ok := parseDeviceCredential(authorization.DeviceCredential)
	if authorization.SchemaVersion != authorizationSchemaVersion || !validUUID(authorization.DeviceID) ||
		!validUUID(authorization.CredentialID) || !ok || credentialID != authorization.CredentialID || !validEnvironment(authorization.Environment) {
		return ErrInvalidData
	}
	if _, err := validateProfiles(authorization.ProfileVersions); err != nil {
		return err
	}
	return nil
}
