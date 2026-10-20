package credential

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strings"
	"unicode"
)

// BYOKSettings is accepted only over the local stdio RPC, never an HTTP API.
type BYOKSettings struct {
	Revision string `json:"revision,omitempty"`
	TargetID string `json:"target_id"`
	BaseURL  string `json:"base_url"`
	Model    string `json:"model"`
	APIKey   string `json:"api_key,omitempty"`
	Save     bool   `json:"save,omitempty"`
	Delete   bool   `json:"delete,omitempty"`
}
type BYOKInfo struct {
	ProfileVersion string `json:"profile_version"`
	BaseURL        string `json:"base_url"`
	Model          string `json:"model"`
	KeyConfigured  bool   `json:"key_configured"`
}

// CommunityManager uses separate secure items from platform device credentials.
// It never registers a device, calls BeeBridge or exchanges platform tokens.
type CommunityManager struct{ backend secureItemBackend }

func NewCommunityManager() (*CommunityManager, error) {
	store, ok := NewSystemCredentialStore().(*keychainStore)
	if !ok {
		return nil, ErrKeychainUnavailable
	}
	return &CommunityManager{backend: store.backend}, nil
}
func byokTarget(target string) (string, error) {
	target = ScopeTarget(target)
	if target != TargetCodexCLI && target != TargetClaudeCLI {
		return "", ErrInvalidData
	}
	return target, nil
}
func (m *CommunityManager) load(ctx context.Context, target string) (BYOKSettings, error) {
	target, err := byokTarget(target)
	if err != nil {
		return BYOKSettings{}, err
	}
	raw, err := m.backend.Load(ctx, "community-byok-"+target+"-v1")
	if err != nil {
		return BYOKSettings{}, err
	}
	defer zeroBytes(raw)
	var value BYOKSettings
	if len(raw) > maxKeychainItemBytes || json.Unmarshal(raw, &value) != nil || !validBYOK(value) {
		return BYOKSettings{}, ErrInvalidData
	}
	return value, nil
}
func validBYOK(v BYOKSettings) bool {
	u, e := url.Parse(v.BaseURL)
	if e != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || len(v.BaseURL) > 2048 {
		return false
	}
	if u.Scheme != "https" {
		ip := net.ParseIP(u.Hostname())
		if u.Scheme != "http" || (u.Hostname() != "localhost" && (ip == nil || !ip.IsLoopback())) {
			return false
		}
	}
	if len(v.Model) == 0 || len(v.Model) > 256 || len(v.APIKey) == 0 || len(v.APIKey) > 8192 {
		return false
	}
	if strings.IndexFunc(v.Model, unicode.IsSpace) >= 0 {
		return false
	}
	for _, s := range []string{v.BaseURL, v.Model, v.APIKey} {
		if strings.IndexFunc(s, unicode.IsControl) >= 0 {
			return false
		}
	}
	return true
}
func (m *CommunityManager) Settings(ctx context.Context, v BYOKSettings) (BYOKInfo, error) {
	target, err := byokTarget(v.TargetID)
	if err != nil || (v.Save && v.Delete) {
		return BYOKInfo{}, ErrInvalidData
	}
	if v.Delete {
		if err = m.backend.Delete(ctx, "community-byok-"+target+"-v1"); err != nil && !errors.Is(err, ErrNotFound) {
			return BYOKInfo{}, ErrKeychainUnavailable
		}
		return BYOKInfo{}, nil
	}
	if v.Save {
		v.TargetID = target
		v.BaseURL = strings.TrimRight(strings.TrimSpace(v.BaseURL), "/")
		v.Model = strings.TrimSpace(v.Model)
		if v.APIKey == "" {
			old, e := m.load(ctx, target)
			if e == nil {
				v.APIKey = old.APIKey
			} else if !errors.Is(e, ErrNotFound) {
				return BYOKInfo{}, ErrKeychainUnavailable
			}
		}
		if !validBYOK(v) {
			return BYOKInfo{}, ErrInvalidData
		}
		revision := make([]byte, 16)
		if _, e := rand.Read(revision); e != nil {
			return BYOKInfo{}, ErrKeychainUnavailable
		}
		v.Revision = "byok-" + hex.EncodeToString(revision)
		v.Save = false
		v.Delete = false
		raw, e := json.Marshal(v)
		if e != nil {
			return BYOKInfo{}, ErrInvalidData
		}
		defer zeroBytes(raw)
		if e = m.backend.Save(ctx, "community-byok-"+target+"-v1", raw); e != nil {
			return BYOKInfo{}, ErrKeychainUnavailable
		}
	}
	stored, err := m.load(ctx, target)
	if errors.Is(err, ErrNotFound) {
		return BYOKInfo{}, nil
	}
	if err != nil {
		return BYOKInfo{}, ErrKeychainUnavailable
	}
	return BYOKInfo{ProfileVersion: stored.Revision, BaseURL: stored.BaseURL, Model: stored.Model, KeyConfigured: stored.APIKey != ""}, nil
}
func (m *CommunityManager) ExchangeToken(ctx context.Context, target string) (string, error) {
	v, e := m.load(ctx, target)
	if e != nil {
		return "", ErrAuthorizationMissing
	}
	return v.APIKey, nil
}
func (m *CommunityManager) ConfigurationProfile(ctx context.Context, target string) (ConfigurationProfile, error) {
	v, e := m.load(ctx, target)
	if e != nil {
		return ConfigurationProfile{}, ErrAuthorizationMissing
	}
	return ConfigurationProfile{Environment: EnvironmentDev, ProfileVersion: v.Revision}, nil
}
func (m *CommunityManager) Status(context.Context) (Status, error) {
	return Status{Targets: []string{}, ProfileVersions: map[string]string{}}, nil
}
func (m *CommunityManager) ClearAuthorization(context.Context) error { return nil }
func (m *CommunityManager) PrepareRegistration(context.Context, string, Environment) (RegistrationPreparation, error) {
	return RegistrationPreparation{}, ErrProfileUnsupported
}
func (m *CommunityManager) CommitRegistration(context.Context, RegistrationCommit) error {
	return ErrProfileUnsupported
}
