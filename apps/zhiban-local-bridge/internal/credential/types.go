package credential

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
)

const (
	TargetCodexCLI      = "codex_cli"
	TargetClaudeCLI     = "claude_cli"
	TargetCodexDesktop  = "codex_desktop"
	TargetClaudeDesktop = "claude_desktop"

	identitySchemaVersion      = 1
	authorizationSchemaVersion = 1
)

var (
	ErrNotFound                = errors.New("credential: item not found")
	ErrInvalidData             = errors.New("credential: invalid data")
	ErrDeviceMismatch          = errors.New("credential: device mismatch")
	ErrNoPendingRegistration   = errors.New("credential: no pending registration")
	ErrRegistrationExpired     = errors.New("credential: registration expired")
	ErrKeychainUnavailable     = errors.New("credential: keychain unavailable")
	ErrAuthorizationMissing    = errors.New("credential: authorization missing")
	ErrProfileUnsupported      = errors.New("credential: profile unsupported")
	ErrExchangeUnavailable     = errors.New("credential: exchange unavailable")
	ErrExchangeRejected        = errors.New("credential: exchange rejected")
	ErrInvalidExchangeResponse = errors.New("credential: invalid exchange response")
	uuidPattern                = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
)

// Exchange refusals where the device authorization is fine and re-authorizing
// changes nothing: the member's relay key itself is being withheld.
var (
	ErrInsufficientCredit = errors.New("credential: insufficient credit")
	ErrMemberKeyDisabled  = errors.New("credential: member key disabled")
)

type Environment string

const (
	EnvironmentDev  Environment = "dev"
	EnvironmentTest Environment = "test"
	EnvironmentProd Environment = "prod"
)

type Endpoints struct {
	RegisterURL string
	ExchangeURL string
}

type Identity struct {
	SchemaVersion  int    `json:"schema_version"`
	DeviceID       string `json:"device_id"`
	PrivateKeySeed []byte `json:"private_key_seed"`
}

type Authorization struct {
	SchemaVersion    int               `json:"schema_version"`
	DeviceID         string            `json:"device_id"`
	CredentialID     string            `json:"credential_id"`
	DeviceCredential string            `json:"device_credential"`
	Environment      Environment       `json:"environment"`
	ProfileVersions  map[string]string `json:"profile_versions"`
}

type Store interface {
	LoadIdentity(context.Context) (Identity, error)
	SaveIdentity(context.Context, Identity) error
	LoadAuthorization(context.Context) (Authorization, error)
	SaveAuthorization(context.Context, Authorization) error
	DeleteAuthorization(context.Context) error
}

type RegistrationPreparation struct {
	DeviceID        string          `json:"device_id"`
	DevicePublicJWK json.RawMessage `json:"device_public_jwk"`
	DPoPProof       string          `json:"dpop_proof"`
}

type RegistrationCommit struct {
	CredentialID     string
	DeviceCredential string
	ProfileVersions  map[string]string
}

type Status struct {
	IdentityPresent      bool              `json:"identity_present"`
	AuthorizationPresent bool              `json:"authorization_present"`
	DeviceID             string            `json:"device_id,omitempty"`
	Environment          Environment       `json:"environment,omitempty"`
	Targets              []string          `json:"targets"`
	ProfileVersions      map[string]string `json:"profile_versions"`
}

type ConfigurationProfile struct {
	Environment    Environment
	ProfileVersion string
}

func validUUID(value string) bool {
	return uuidPattern.MatchString(value)
}

func validTarget(value string) bool {
	return value == TargetCodexCLI || value == TargetClaudeCLI || value == TargetCodexDesktop || value == TargetClaudeDesktop
}

// IsTarget reports whether value names a credential target the helper serves.
func IsTarget(value string) bool {
	return validTarget(value)
}

// ScopeTarget maps a target to the CLI target whose gateway scope, profile
// version and Bus exchange it shares: Codex Desktop uses the Responses scope
// of codex_cli, Claude Desktop the Messages scope of claude_cli (M3). The Bus
// only knows the two CLI targets.
func ScopeTarget(value string) string {
	switch value {
	case TargetCodexDesktop:
		return TargetCodexCLI
	case TargetClaudeDesktop:
		return TargetClaudeCLI
	default:
		return value
	}
}

func parseDeviceCredential(value string) (string, bool) {
	parts := strings.Split(value, ".")
	if len(parts) != 3 || parts[0] != "lctd" || !validUUID(parts[1]) || len(parts[2]) != 48 {
		return "", false
	}
	for _, char := range parts[2] {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') {
			continue
		}
		return "", false
	}
	return parts[1], true
}
