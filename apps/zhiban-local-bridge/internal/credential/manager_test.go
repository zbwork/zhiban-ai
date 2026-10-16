package credential

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

const (
	testDeviceID     = "11111111-1111-4111-8111-111111111111"
	testCredentialID = "22222222-2222-4222-8222-222222222222"
)

type memoryStore struct {
	identity           *Identity
	authorization      *Authorization
	saveIdentityErr    error
	saveAuthorizeErr   error
	deleteAuthorizeErr error
	identitySaved      bool
}

func (s *memoryStore) LoadIdentity(context.Context) (Identity, error) {
	if s.identity == nil {
		return Identity{}, ErrNotFound
	}
	return cloneIdentity(*s.identity), nil
}

func (s *memoryStore) SaveIdentity(_ context.Context, identity Identity) error {
	if s.saveIdentityErr != nil {
		return s.saveIdentityErr
	}
	copy := cloneIdentity(identity)
	s.identity = &copy
	s.identitySaved = true
	return nil
}

func (s *memoryStore) LoadAuthorization(context.Context) (Authorization, error) {
	if s.authorization == nil {
		return Authorization{}, ErrNotFound
	}
	return cloneAuthorization(*s.authorization), nil
}

func (s *memoryStore) SaveAuthorization(_ context.Context, authorization Authorization) error {
	if s.saveAuthorizeErr != nil {
		return s.saveAuthorizeErr
	}
	copy := cloneAuthorization(authorization)
	s.authorization = &copy
	return nil
}

func (s *memoryStore) DeleteAuthorization(context.Context) error {
	if s.deleteAuthorizeErr != nil {
		return s.deleteAuthorizeErr
	}
	s.authorization = nil
	return nil
}

func cloneIdentity(value Identity) Identity {
	value.PrivateKeySeed = append([]byte(nil), value.PrivateKeySeed...)
	return value
}

func cloneAuthorization(value Authorization) Authorization {
	profiles := make(map[string]string, len(value.ProfileVersions))
	for target, version := range value.ProfileVersions {
		profiles[target] = version
	}
	value.ProfileVersions = profiles
	return value
}

func testManager(t *testing.T, store Store, now func() time.Time, random io.Reader) *Manager {
	t.Helper()
	manager, err := NewManager(ManagerConfig{
		Store: store,
		Endpoints: map[Environment]Endpoints{
			EnvironmentProd: {
				RegisterURL: "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/devices",
				ExchangeURL: "https://zb.qkfintech.cn/api/agent-bus/v1/local-coding-tools/credentials/exchange",
			},
		},
		Now:    now,
		Random: random,
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	return manager
}

func TestPrepareRegistrationPersistsIdentityBeforeReturningDPoP(t *testing.T) {
	t.Parallel()

	store := &memoryStore{}
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	manager := testManager(t, store, func() time.Time { return now }, strings.NewReader(strings.Repeat("a", 256)))

	prepared, err := manager.PrepareRegistration(context.Background(), testDeviceID, EnvironmentProd)
	if err != nil {
		t.Fatalf("PrepareRegistration() error = %v", err)
	}
	if !store.identitySaved || store.identity == nil {
		t.Fatal("identity must be persisted before prepare succeeds")
	}
	if prepared.DeviceID != testDeviceID || prepared.DPoPProof == "" {
		t.Fatalf("preparation = %+v", prepared)
	}
	assertRegistrationProof(t, prepared, store.identity.PrivateKeySeed, now)
}

func TestConfigurationProfileRequiresMatchingIdentityAndReturnsOnlyMetadata(t *testing.T) {
	t.Parallel()

	store := &memoryStore{
		identity: &Identity{
			SchemaVersion: identitySchemaVersion, DeviceID: testDeviceID,
			PrivateKeySeed: []byte(strings.Repeat("I", 32)),
		},
		authorization: &Authorization{
			SchemaVersion:    authorizationSchemaVersion,
			DeviceID:         testDeviceID,
			CredentialID:     testCredentialID,
			DeviceCredential: "lctd." + testCredentialID + "." + strings.Repeat("A", 48),
			Environment:      EnvironmentProd,
			ProfileVersions:  map[string]string{TargetCodexCLI: "2026.09.07.1"},
		},
	}
	manager := testManager(t, store, time.Now, strings.NewReader(strings.Repeat("a", 256)))
	profile, err := manager.ConfigurationProfile(context.Background(), TargetCodexCLI)
	if err != nil {
		t.Fatalf("ConfigurationProfile() error = %v", err)
	}
	if profile.Environment != EnvironmentProd || profile.ProfileVersion != "2026.09.07.1" {
		t.Fatalf("profile = %+v", profile)
	}
	if _, err := manager.ConfigurationProfile(context.Background(), TargetClaudeCLI); !errors.Is(err, ErrProfileUnsupported) {
		t.Fatalf("missing target error = %v", err)
	}
	store.identity.DeviceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	if _, err := manager.ConfigurationProfile(context.Background(), TargetCodexCLI); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("mismatched identity error = %v", err)
	}
	store.identity.DeviceID = testDeviceID
	store.authorization = nil
	if _, err := manager.ConfigurationProfile(context.Background(), TargetCodexCLI); !errors.Is(err, ErrAuthorizationMissing) {
		t.Fatalf("missing authorization error = %v", err)
	}
}

func TestPrepareRegistrationReusesIdentityAndRotatesOnDeviceMismatch(t *testing.T) {
	t.Parallel()

	store := &memoryStore{}
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	randomBytes := make([]byte, 512)
	for index := range randomBytes {
		randomBytes[index] = byte(index)
	}
	manager := testManager(t, store, func() time.Time { return now }, bytes.NewReader(randomBytes))

	first, err := manager.PrepareRegistration(context.Background(), testDeviceID, EnvironmentProd)
	if err != nil {
		t.Fatal(err)
	}
	firstSeed := append([]byte(nil), store.identity.PrivateKeySeed...)
	second, err := manager.PrepareRegistration(context.Background(), testDeviceID, EnvironmentProd)
	if err != nil {
		t.Fatal(err)
	}
	if string(firstSeed) != string(store.identity.PrivateKeySeed) {
		t.Fatal("existing private key seed was replaced")
	}
	if string(first.DevicePublicJWK) != string(second.DevicePublicJWK) || first.DPoPProof == second.DPoPProof {
		t.Fatalf("identity/proof reuse invariant violated: first=%+v second=%+v", first, second)
	}

	// App data reset / reinstall: the App presents a new device_id while the
	// Keychain still holds the old identity + authorization. Prepare must
	// rotate the identity and drop the stale authorization instead of
	// failing closed (that surfaced as an opaque rpc -32603 on 2026-09-09).
	store.authorization = &Authorization{
		SchemaVersion: authorizationSchemaVersion, DeviceID: testDeviceID, CredentialID: testCredentialID,
		DeviceCredential: "zbdc_" + testCredentialID + ".secret", Environment: EnvironmentProd,
		ProfileVersions: map[string]string{TargetCodexCLI: "2026.09.07.1"},
	}
	const newDeviceID = "33333333-3333-4333-8333-333333333333"
	third, err := manager.PrepareRegistration(context.Background(), newDeviceID, EnvironmentProd)
	if err != nil {
		t.Fatalf("PrepareRegistration(new device) error = %v, want rotation", err)
	}
	if third.DeviceID != newDeviceID || store.identity == nil || store.identity.DeviceID != newDeviceID {
		t.Fatalf("identity not rotated to new device: prep=%+v identity=%+v", third, store.identity)
	}
	if string(firstSeed) == string(store.identity.PrivateKeySeed) {
		t.Fatal("stale private key seed kept after device_id change")
	}
	if string(third.DevicePublicJWK) == string(first.DevicePublicJWK) {
		t.Fatal("public JWK unchanged after identity rotation")
	}
	if store.authorization != nil {
		t.Fatal("stale authorization survived identity rotation")
	}
	status, err := manager.Status(context.Background())
	if err != nil || !status.IdentityPresent || status.AuthorizationPresent || status.DeviceID != newDeviceID {
		t.Fatalf("status after rotation = %+v, %v", status, err)
	}
}

func TestPrepareRegistrationFailsClosedWhenIdentityCannotBeStored(t *testing.T) {
	t.Parallel()

	store := &memoryStore{saveIdentityErr: errors.New("keychain unavailable")}
	manager := testManager(t, store, time.Now, strings.NewReader(strings.Repeat("c", 256)))

	prepared, err := manager.PrepareRegistration(context.Background(), testDeviceID, EnvironmentProd)
	if err == nil {
		t.Fatal("PrepareRegistration() unexpectedly succeeded")
	}
	if prepared.DPoPProof != "" || prepared.DevicePublicJWK != nil {
		t.Fatalf("failed prepare leaked usable material: %+v", prepared)
	}
}

func TestCommitRegistrationStoresAuthorizationAndReturnsNonSecretStatus(t *testing.T) {
	t.Parallel()

	store := &memoryStore{}
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	manager := testManager(t, store, func() time.Time { return now }, strings.NewReader(strings.Repeat("d", 512)))
	if _, err := manager.PrepareRegistration(context.Background(), testDeviceID, EnvironmentProd); err != nil {
		t.Fatal(err)
	}
	deviceCredential := "lctd." + testCredentialID + "." + strings.Repeat("A", 48)
	err := manager.CommitRegistration(context.Background(), RegistrationCommit{
		CredentialID:     testCredentialID,
		DeviceCredential: deviceCredential,
		ProfileVersions: map[string]string{
			TargetCodexCLI:  "2026.09.07.1",
			TargetClaudeCLI: "2026.09.07.1",
		},
	})
	if err != nil {
		t.Fatalf("CommitRegistration() error = %v", err)
	}
	if store.authorization == nil || store.authorization.DeviceCredential != deviceCredential || store.authorization.DeviceID != testDeviceID {
		t.Fatalf("stored authorization = %+v", store.authorization)
	}
	status, err := manager.Status(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !status.IdentityPresent || !status.AuthorizationPresent || status.DeviceID != testDeviceID || status.Environment != EnvironmentProd || len(status.Targets) != 2 {
		t.Fatalf("status = %+v", status)
	}
	if status.ProfileVersions[TargetCodexCLI] != "2026.09.07.1" || status.ProfileVersions[TargetClaudeCLI] != "2026.09.07.1" {
		t.Fatalf("status profile versions = %+v", status.ProfileVersions)
	}
	encoded, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{deviceCredential, testCredentialID, "private_key_seed", "dpop"} {
		if strings.Contains(strings.ToLower(string(encoded)), strings.ToLower(secret)) {
			t.Fatalf("status leaked %q: %s", secret, encoded)
		}
	}
	if err := manager.ClearAuthorization(context.Background()); err != nil {
		t.Fatal(err)
	}
	if store.authorization != nil || store.identity == nil {
		t.Fatalf("clear removed wrong items: identity=%+v authorization=%+v", store.identity, store.authorization)
	}
}

func TestCommitRegistrationRejectsMismatchExpiryAndReuse(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	store := &memoryStore{}
	manager := testManager(t, store, func() time.Time { return now }, strings.NewReader(strings.Repeat("e", 512)))
	if _, err := manager.PrepareRegistration(context.Background(), testDeviceID, EnvironmentProd); err != nil {
		t.Fatal(err)
	}
	wrongCredential := "lctd.33333333-3333-4333-8333-333333333333." + strings.Repeat("B", 48)
	if err := manager.CommitRegistration(context.Background(), RegistrationCommit{
		CredentialID: testCredentialID, DeviceCredential: wrongCredential,
		ProfileVersions: map[string]string{TargetCodexCLI: "2026.09.07.1"},
	}); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("mismatch error = %v, want ErrInvalidData", err)
	}
	validCredential := "lctd." + testCredentialID + "." + strings.Repeat("C", 48)
	now = now.Add(pendingRegistrationTTL + time.Second)
	if err := manager.CommitRegistration(context.Background(), RegistrationCommit{
		CredentialID: testCredentialID, DeviceCredential: validCredential,
		ProfileVersions: map[string]string{TargetCodexCLI: "2026.09.07.1"},
	}); !errors.Is(err, ErrRegistrationExpired) {
		t.Fatalf("expiry error = %v, want ErrRegistrationExpired", err)
	}
	if err := manager.CommitRegistration(context.Background(), RegistrationCommit{
		CredentialID: testCredentialID, DeviceCredential: validCredential,
		ProfileVersions: map[string]string{TargetCodexCLI: "2026.09.07.1"},
	}); !errors.Is(err, ErrNoPendingRegistration) {
		t.Fatalf("reuse error = %v, want ErrNoPendingRegistration", err)
	}
}

func TestCommitRegistrationSaveFailurePreservesPreviousAuthorization(t *testing.T) {
	t.Parallel()

	oldCredentialID := "44444444-4444-4444-8444-444444444444"
	oldCredential := "lctd." + oldCredentialID + "." + strings.Repeat("D", 48)
	store := &memoryStore{authorization: &Authorization{
		SchemaVersion: authorizationSchemaVersion, DeviceID: testDeviceID,
		CredentialID: oldCredentialID, DeviceCredential: oldCredential,
		Environment: EnvironmentProd, ProfileVersions: map[string]string{TargetCodexCLI: "old"},
	}}
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	manager := testManager(t, store, func() time.Time { return now }, strings.NewReader(strings.Repeat("f", 512)))
	if _, err := manager.PrepareRegistration(context.Background(), testDeviceID, EnvironmentProd); err != nil {
		t.Fatal(err)
	}
	store.saveAuthorizeErr = errors.New("keychain update failed")
	newCredential := "lctd." + testCredentialID + "." + strings.Repeat("E", 48)
	if err := manager.CommitRegistration(context.Background(), RegistrationCommit{
		CredentialID: testCredentialID, DeviceCredential: newCredential,
		ProfileVersions: map[string]string{TargetCodexCLI: "2026.09.07.1"},
	}); err == nil {
		t.Fatal("CommitRegistration() unexpectedly succeeded")
	}
	if store.authorization == nil || store.authorization.DeviceCredential != oldCredential {
		t.Fatalf("previous authorization was lost: %+v", store.authorization)
	}
}

func TestStatusRejectsAuthorizationWithoutIdentity(t *testing.T) {
	t.Parallel()

	store := authorizedStore()
	store.identity = nil
	manager := testManager(t, store, time.Now, strings.NewReader(strings.Repeat("g", 64)))
	if _, err := manager.Status(context.Background()); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("Status() error = %v, want ErrInvalidData", err)
	}
}
