package credential

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

const pendingRegistrationTTL = 2 * time.Minute

type ManagerConfig struct {
	Store      Store
	Endpoints  map[Environment]Endpoints
	Now        func() time.Time
	Random     io.Reader
	HTTPClient HTTPDoer
}

type pendingRegistration struct {
	DeviceID    string
	Environment Environment
	ExpiresAt   time.Time
}

type Manager struct {
	store      Store
	endpoints  map[Environment]Endpoints
	now        func() time.Time
	random     io.Reader
	httpClient HTTPDoer

	mu      sync.Mutex
	pending *pendingRegistration
}

func NewManager(config ManagerConfig) (*Manager, error) {
	if config.Store == nil {
		return nil, errors.New("credential: store is required")
	}
	endpoints := make(map[Environment]Endpoints, len(config.Endpoints))
	for environment, pair := range config.Endpoints {
		if !validEnvironment(environment) || validateEndpoint(environment, pair.RegisterURL, "/api/agent-bus/v1/local-coding-tools/devices") != nil ||
			validateEndpoint(environment, pair.ExchangeURL, "/api/agent-bus/v1/local-coding-tools/credentials/exchange") != nil {
			return nil, fmt.Errorf("credential: invalid %s endpoints", environment)
		}
		endpoints[environment] = pair
	}
	if len(endpoints) == 0 {
		return nil, errors.New("credential: endpoints are required")
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	random := config.Random
	if random == nil {
		random = rand.Reader
	}
	httpClient := config.HTTPClient
	if httpClient == nil {
		httpClient = NewSecureHTTPClient()
	}
	return &Manager{store: config.Store, endpoints: endpoints, now: now, random: random, httpClient: httpClient}, nil
}

func (m *Manager) PrepareRegistration(ctx context.Context, deviceID string, environment Environment) (RegistrationPreparation, error) {
	if !validUUID(deviceID) {
		return RegistrationPreparation{}, ErrInvalidData
	}
	pair, ok := m.endpoints[environment]
	if !ok {
		return RegistrationPreparation{}, ErrInvalidData
	}
	identity, err := m.store.LoadIdentity(ctx)
	generate := errors.Is(err, ErrNotFound)
	if err == nil && identity.DeviceID != deviceID {
		// The App owns device_id (SharedPreferences). After an App data reset
		// or reinstall it regenerates one while the Keychain identity from the
		// previous install survives. The old identity and its authorization
		// are useless for the new device_id, and rejecting here bricked
		// registration behind an opaque -32603 (11910 test Mac, 2026-09-09).
		// Rotate: drop the stale authorization and mint a fresh identity.
		zeroBytes(identity.PrivateKeySeed)
		if deleteErr := m.store.DeleteAuthorization(ctx); deleteErr != nil && !errors.Is(deleteErr, ErrNotFound) {
			return RegistrationPreparation{}, fmt.Errorf("credential: delete stale authorization: %w", deleteErr)
		}
		generate = true
	}
	if generate {
		_, privateKey, generateErr := ed25519.GenerateKey(m.random)
		if generateErr != nil {
			return RegistrationPreparation{}, fmt.Errorf("credential: generate identity: %w", generateErr)
		}
		identity = Identity{
			SchemaVersion:  identitySchemaVersion,
			DeviceID:       deviceID,
			PrivateKeySeed: append([]byte(nil), privateKey.Seed()...),
		}
		zeroBytes(privateKey)
		if saveErr := m.store.SaveIdentity(ctx, identity); saveErr != nil {
			zeroBytes(identity.PrivateKeySeed)
			return RegistrationPreparation{}, fmt.Errorf("credential: save identity: %w", saveErr)
		}
	} else if err != nil {
		return RegistrationPreparation{}, fmt.Errorf("credential: load identity: %w", err)
	}
	defer zeroBytes(identity.PrivateKeySeed)
	if identity.SchemaVersion != identitySchemaVersion || len(identity.PrivateKeySeed) != ed25519.SeedSize || !validUUID(identity.DeviceID) {
		return RegistrationPreparation{}, ErrInvalidData
	}
	if identity.DeviceID != deviceID {
		return RegistrationPreparation{}, ErrDeviceMismatch
	}
	proof, publicJWK, err := newDPoPProof(identity.PrivateKeySeed, "POST", pair.RegisterURL, "", m.now(), m.random)
	if err != nil {
		return RegistrationPreparation{}, err
	}
	m.mu.Lock()
	m.pending = &pendingRegistration{DeviceID: deviceID, Environment: environment, ExpiresAt: m.now().Add(pendingRegistrationTTL)}
	m.mu.Unlock()
	return RegistrationPreparation{DeviceID: deviceID, DevicePublicJWK: publicJWK, DPoPProof: proof}, nil
}

func (m *Manager) CommitRegistration(ctx context.Context, input RegistrationCommit) error {
	parsedCredentialID, ok := parseDeviceCredential(input.DeviceCredential)
	if !ok || !validUUID(input.CredentialID) || parsedCredentialID != input.CredentialID {
		return ErrInvalidData
	}
	profiles, err := validateProfiles(input.ProfileVersions)
	if err != nil {
		return err
	}
	m.mu.Lock()
	pending := m.pending
	if pending == nil {
		m.mu.Unlock()
		return ErrNoPendingRegistration
	}
	if m.now().After(pending.ExpiresAt) {
		m.pending = nil
		m.mu.Unlock()
		return ErrRegistrationExpired
	}
	m.pending = nil
	m.mu.Unlock()

	authorization := Authorization{
		SchemaVersion:    authorizationSchemaVersion,
		DeviceID:         pending.DeviceID,
		CredentialID:     input.CredentialID,
		DeviceCredential: input.DeviceCredential,
		Environment:      pending.Environment,
		ProfileVersions:  profiles,
	}
	if err := m.store.SaveAuthorization(ctx, authorization); err != nil {
		return fmt.Errorf("credential: save authorization: %w", err)
	}
	return nil
}

func (m *Manager) Status(ctx context.Context) (Status, error) {
	status := Status{Targets: []string{}, ProfileVersions: map[string]string{}}
	identity, err := m.store.LoadIdentity(ctx)
	if err == nil {
		if identity.SchemaVersion != identitySchemaVersion || !validUUID(identity.DeviceID) || len(identity.PrivateKeySeed) != ed25519.SeedSize {
			zeroBytes(identity.PrivateKeySeed)
			return Status{}, ErrInvalidData
		}
		status.IdentityPresent = true
		status.DeviceID = identity.DeviceID
		zeroBytes(identity.PrivateKeySeed)
	} else if !errors.Is(err, ErrNotFound) {
		return Status{}, fmt.Errorf("credential: load identity: %w", err)
	}
	authorization, err := m.store.LoadAuthorization(ctx)
	if errors.Is(err, ErrNotFound) {
		return status, nil
	}
	if err != nil {
		return Status{}, fmt.Errorf("credential: load authorization: %w", err)
	}
	if !status.IdentityPresent {
		return Status{}, ErrInvalidData
	}
	if authorization.SchemaVersion != authorizationSchemaVersion || !validEnvironment(authorization.Environment) ||
		!validUUID(authorization.DeviceID) || (status.IdentityPresent && authorization.DeviceID != status.DeviceID) {
		return Status{}, ErrInvalidData
	}
	profiles, err := validateProfiles(authorization.ProfileVersions)
	if err != nil {
		return Status{}, err
	}
	status.AuthorizationPresent = true
	status.Environment = authorization.Environment
	for target, version := range profiles {
		status.Targets = append(status.Targets, target)
		status.ProfileVersions[target] = version
	}
	sort.Strings(status.Targets)
	return status, nil
}

// ConfigurationProfile returns only the non-secret authorization metadata a
// local configuration plan needs. Device credentials never cross this API.
func (m *Manager) ConfigurationProfile(ctx context.Context, targetID string) (ConfigurationProfile, error) {
	if !validTarget(targetID) {
		return ConfigurationProfile{}, ErrInvalidData
	}
	authorization, err := m.store.LoadAuthorization(ctx)
	if errors.Is(err, ErrNotFound) {
		return ConfigurationProfile{}, ErrAuthorizationMissing
	}
	if err != nil {
		return ConfigurationProfile{}, fmt.Errorf("credential: load authorization: %w", err)
	}
	if err := validateAuthorization(authorization); err != nil {
		return ConfigurationProfile{}, err
	}
	identity, err := m.store.LoadIdentity(ctx)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return ConfigurationProfile{}, ErrInvalidData
		}
		return ConfigurationProfile{}, fmt.Errorf("credential: load identity: %w", err)
	}
	defer zeroBytes(identity.PrivateKeySeed)
	if identity.SchemaVersion != identitySchemaVersion || !validUUID(identity.DeviceID) ||
		len(identity.PrivateKeySeed) != ed25519.SeedSize || identity.DeviceID != authorization.DeviceID {
		return ConfigurationProfile{}, ErrInvalidData
	}
	profileVersion, ok := authorization.ProfileVersions[ScopeTarget(targetID)]
	if !ok || !validSafeVersion(profileVersion) {
		return ConfigurationProfile{}, ErrProfileUnsupported
	}
	return ConfigurationProfile{
		Environment:    authorization.Environment,
		ProfileVersion: profileVersion,
	}, nil
}

func (m *Manager) ClearAuthorization(ctx context.Context) error {
	if err := m.store.DeleteAuthorization(ctx); err != nil && !errors.Is(err, ErrNotFound) {
		return fmt.Errorf("credential: delete authorization: %w", err)
	}
	m.mu.Lock()
	m.pending = nil
	m.mu.Unlock()
	return nil
}

func validateProfiles(input map[string]string) (map[string]string, error) {
	if len(input) == 0 || len(input) > 2 {
		return nil, ErrInvalidData
	}
	profiles := make(map[string]string, len(input))
	for target, version := range input {
		if !validTarget(target) || !validSafeVersion(version) {
			return nil, ErrInvalidData
		}
		profiles[target] = version
	}
	return profiles, nil
}

func validEnvironment(value Environment) bool {
	return value == EnvironmentDev || value == EnvironmentTest || value == EnvironmentProd
}

func validateEndpoint(environment Environment, raw, expectedPath string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Path != expectedPath || parsed.Host == "" {
		return ErrInvalidData
	}
	if parsed.Scheme == "https" {
		return nil
	}
	host := parsed.Hostname()
	if environment == EnvironmentDev && parsed.Scheme == "http" && (host == "localhost" || net.ParseIP(host).IsLoopback()) {
		return nil
	}
	return ErrInvalidData
}

func validSafeVersion(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || strings.ContainsRune("-_.+", char) {
			continue
		}
		return false
	}
	return true
}
