// Package catalog is the Bridge side of the F31 local coding tool version
// catalog. The Bus signs a per-tenant catalog (Ed25519 over canonical JSON)
// that names the current and previous version of every tool together with
// the hosts their packages may be fetched from; the App fetches it and hands
// it to the Bridge (catalog.apply). The Bridge verifies it against the
// public keys compiled in for the App's environment, keeps the verified
// envelope on disk for sessions without the App online, and the installer
// plans installs, upgrades and rollbacks from it. A catalog that fails any
// check is ignored and the built-in manifest applies.
//
// Wire contract: docs/contracts/local-coding-tools-contract.md §4.5; the
// canonical form and signature are produced by
// services/agent-bus/internal/service/localcodingcatalog/signer.go and must
// stay byte-for-byte compatible with CanonicalJSON below.
package catalog

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	// Schema is the only catalog schema this Bridge understands.
	Schema = 1

	// SourceKindZhibanPackage marks a package hosted by the platform (object
	// storage behind a Bus redirect, a CDN in front of it, or an external
	// https address an operator entered).
	SourceKindZhibanPackage = "zhiban_package"

	TargetCodexCLI       = "codex_cli"
	TargetClaudeCLI      = "claude_cli"
	TargetCodexDesktop   = "codex_desktop"
	TargetClaudeDesktop  = "claude_desktop"
	TargetClaudeCodeHost = "claude_code_host"

	EnvironmentDev  = "dev"
	EnvironmentTest = "test"
	EnvironmentProd = "prod"

	LayoutTarballSingle    = "tarball_single"
	LayoutTarballMember    = "tarball_member"
	LayoutTarballTree      = "tarball_tree"
	LayoutBareBinary       = "bare_binary"
	LayoutAppBundleZip     = "app_bundle_zip"
	LayoutAppBundleDMG     = "app_bundle_dmg"
	LayoutMSIX             = "msix" // Windows desktop packages; install.Asset.Validate ties it to Windows
	LayoutHostBinaryNPMTgz = "host_binary_npm_tgz"
	LayoutHostBundleTarZst = "host_bundle_tar_zst"

	// maxCatalogBytes bounds what catalog.apply accepts before parsing.
	maxCatalogBytes = 1 << 20
)

var (
	ErrUnknownKey   = errors.New("catalog: no trusted key for kid")
	ErrBadSignature = errors.New("catalog: signature mismatch")
	ErrExpired      = errors.New("catalog: expired")
	ErrSchema       = errors.New("catalog: unsupported schema")
	ErrMismatch     = errors.New("catalog: platform or arch mismatch")
	ErrInvalid      = errors.New("catalog: invalid content")
	ErrTooLarge     = errors.New("catalog: too large")

	sha256Pattern  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	versionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	hostPattern    = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$`)
	kidPattern     = regexp.MustCompile(`^[0-9A-Za-z._-]{1,64}$`)
)

// Signed is the envelope the Bus returns and the App forwards verbatim: the
// catalog document as raw JSON (so the signed bytes can be reproduced), the
// key id and the base64url Ed25519 signature.
type Signed struct {
	Catalog   json.RawMessage `json:"catalog"`
	KID       string          `json:"kid"`
	Signature string          `json:"signature"`
}

// Catalog mirrors the Bus document. Unknown fields are tolerated: the
// signature covers the raw bytes, and a newer Bus may add fields.
type Catalog struct {
	Schema       int               `json:"schema"`
	IssuedAt     string            `json:"issued_at"`
	ExpiresAt    string            `json:"expires_at"`
	Platform     string            `json:"platform"`
	Arch         string            `json:"arch"`
	AllowedHosts []string          `json:"allowed_hosts"`
	Targets      map[string]Target `json:"targets"`
}

// Target is the current / previous pair of one tool; Previous may be nil.
type Target struct {
	Current  *Version `json:"current"`
	Previous *Version `json:"previous"`
}

// Version is one published tool package.
type Version struct {
	Version          string   `json:"version"`
	Layout           string   `json:"layout"`
	Member           string   `json:"member,omitempty"`
	BinarySHA256     string   `json:"binary_sha256,omitempty"`
	BundleIdentifier string   `json:"bundle_identifier,omitempty"`
	TeamIdentifier   string   `json:"team_identifier,omitempty"`
	ProfileVersion   string   `json:"profile_version,omitempty"`
	MinBridgeVersion string   `json:"min_bridge_version,omitempty"`
	MinAppVersion    string   `json:"min_app_version,omitempty"`
	ReleaseNotes     string   `json:"release_notes,omitempty"`
	Canary           bool     `json:"canary,omitempty"`
	Sources          []Source `json:"sources"`
}

// Source is one download location of a version.
type Source struct {
	Kind   string `json:"kind"`
	URL    string `json:"url"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// CanonicalJSON reproduces the bytes the Bus signed: the document decoded
// with UseNumber (integers stay integers) and re-encoded with keys sorted at
// every level, no insignificant whitespace and no HTML escaping. It is the
// exact counterpart of the Bus implementation.
func CanonicalJSON(raw []byte) ([]byte, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, ErrInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var generic any
	if err := decoder.Decode(&generic); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	if decoder.More() {
		return nil, ErrInvalid
	}
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(generic); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	return bytes.TrimRight(out.Bytes(), "\n"), nil
}

// Verify checks the envelope against the trusted keys (kid → base64 public
// key), reproduces the signed bytes, checks the signature, decodes the
// document and validates it for platform / arch at now. Only a catalog that
// passes every step is returned.
func Verify(keys map[string]string, signed Signed, now time.Time, platform, arch string) (Catalog, error) {
	if len(signed.Catalog) > maxCatalogBytes {
		return Catalog{}, ErrTooLarge
	}
	kid := strings.TrimSpace(signed.KID)
	if !kidPattern.MatchString(kid) {
		return Catalog{}, ErrUnknownKey
	}
	encodedKey, ok := keys[kid]
	if !ok {
		return Catalog{}, ErrUnknownKey
	}
	publicKey, err := decodeBase64Any(encodedKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		return Catalog{}, ErrUnknownKey
	}
	signature, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(strings.TrimSpace(signed.Signature), "="))
	if err != nil || len(signature) != ed25519.SignatureSize {
		return Catalog{}, ErrBadSignature
	}
	payload, err := CanonicalJSON(signed.Catalog)
	if err != nil {
		return Catalog{}, err
	}
	if !ed25519.Verify(ed25519.PublicKey(publicKey), payload, signature) {
		return Catalog{}, ErrBadSignature
	}
	var document Catalog
	if err := json.Unmarshal(signed.Catalog, &document); err != nil {
		return Catalog{}, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	if err := document.Validate(now, platform, arch); err != nil {
		return Catalog{}, err
	}
	return document, nil
}

// Validate checks the decoded document: schema, validity window, platform /
// arch, host names and every version entry.
func (c Catalog) Validate(now time.Time, platform, arch string) error {
	if c.Schema != Schema {
		return ErrSchema
	}
	if c.Platform != platform || c.Arch != arch {
		return ErrMismatch
	}
	issuedAt, err := time.Parse(time.RFC3339, c.IssuedAt)
	if err != nil {
		return fmt.Errorf("%w: issued_at", ErrInvalid)
	}
	expiresAt, err := time.Parse(time.RFC3339, c.ExpiresAt)
	if err != nil {
		return fmt.Errorf("%w: expires_at", ErrInvalid)
	}
	if !expiresAt.After(issuedAt) {
		return fmt.Errorf("%w: validity window", ErrInvalid)
	}
	if !now.Before(expiresAt) {
		return ErrExpired
	}
	for _, host := range c.AllowedHosts {
		if !hostPattern.MatchString(host) {
			return fmt.Errorf("%w: allowed host %q", ErrInvalid, host)
		}
	}
	for targetID, target := range c.Targets {
		if !ValidTarget(targetID) {
			return fmt.Errorf("%w: target %q", ErrInvalid, targetID)
		}
		if target.Current == nil {
			return fmt.Errorf("%w: %s has no current", ErrInvalid, targetID)
		}
		if err := target.Current.Validate(targetID); err != nil {
			return err
		}
		if target.Previous != nil {
			if err := target.Previous.Validate(targetID); err != nil {
				return err
			}
			if target.Previous.Version == target.Current.Version {
				return fmt.Errorf("%w: %s previous equals current", ErrInvalid, targetID)
			}
		}
	}
	return nil
}

// Validate checks one version entry for target.
func (v Version) Validate(targetID string) error {
	if !versionPattern.MatchString(v.Version) {
		return fmt.Errorf("%w: %s version %q", ErrInvalid, targetID, v.Version)
	}
	if v.BinarySHA256 != "" && !sha256Pattern.MatchString(v.BinarySHA256) {
		return fmt.Errorf("%w: %s binary_sha256", ErrInvalid, targetID)
	}
	switch v.Layout {
	case LayoutTarballSingle, LayoutBareBinary, LayoutAppBundleZip, LayoutAppBundleDMG, LayoutMSIX, LayoutHostBinaryNPMTgz, LayoutHostBundleTarZst:
		if v.Member != "" {
			return fmt.Errorf("%w: %s member", ErrInvalid, targetID)
		}
	case LayoutTarballMember, LayoutTarballTree:
		if v.Member == "" || path.Clean(v.Member) != v.Member || strings.HasPrefix(v.Member, "/") ||
			strings.HasPrefix(v.Member, "../") || strings.Contains(v.Member, "/../") {
			return fmt.Errorf("%w: %s member", ErrInvalid, targetID)
		}
	default:
		return fmt.Errorf("%w: %s layout %q", ErrInvalid, targetID, v.Layout)
	}
	if len(v.Sources) == 0 {
		return fmt.Errorf("%w: %s has no sources", ErrInvalid, targetID)
	}
	for _, source := range v.Sources {
		if err := source.Validate(); err != nil {
			return fmt.Errorf("%w (%s)", err, targetID)
		}
	}
	return nil
}

// Validate checks one source: platform kind, https URL, positive size and a
// SHA-256 of the archive.
func (s Source) Validate() error {
	if s.Kind != SourceKindZhibanPackage || s.Size <= 0 || !sha256Pattern.MatchString(s.SHA256) {
		return fmt.Errorf("%w: source", ErrInvalid)
	}
	parsed, err := url.Parse(s.URL)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil ||
		parsed.Fragment != "" || strings.TrimSpace(s.URL) != s.URL {
		return fmt.Errorf("%w: source url", ErrInvalid)
	}
	return nil
}

// Host returns the source host for display.
func (s Source) Host() string {
	parsed, err := url.Parse(s.URL)
	if err != nil {
		return ""
	}
	return parsed.Hostname()
}

// ValidTarget reports whether targetID is a catalog target.
func ValidTarget(targetID string) bool {
	switch targetID {
	case TargetCodexCLI, TargetClaudeCLI, TargetCodexDesktop, TargetClaudeDesktop, TargetClaudeCodeHost:
		return true
	default:
		return false
	}
}

// ValidEnvironment reports whether environment names a Bridge environment.
func ValidEnvironment(environment string) bool {
	return environment == EnvironmentDev || environment == EnvironmentTest || environment == EnvironmentProd
}

// CompareVersions orders two dotted numeric versions ("0.153.4", "2.1.263",
// "26.623.141536"): -1 when a < b, 0 when equal, 1 when a > b. Components
// are compared numerically, a missing component counts as zero, and a
// non-numeric component falls back to string order so nothing panics on an
// unexpected value.
func CompareVersions(a, b string) int {
	partsA := strings.Split(strings.TrimSpace(a), ".")
	partsB := strings.Split(strings.TrimSpace(b), ".")
	for i := 0; i < len(partsA) || i < len(partsB); i++ {
		left, right := "0", "0"
		if i < len(partsA) && partsA[i] != "" {
			left = partsA[i]
		}
		if i < len(partsB) && partsB[i] != "" {
			right = partsB[i]
		}
		if left == right {
			continue
		}
		leftValue, leftErr := strconv.ParseUint(left, 10, 64)
		rightValue, rightErr := strconv.ParseUint(right, 10, 64)
		if leftErr == nil && rightErr == nil {
			if leftValue < rightValue {
				return -1
			}
			if leftValue > rightValue {
				return 1
			}
			continue
		}
		return strings.Compare(left, right)
	}
	return 0
}

func decodeBase64Any(encoded string) ([]byte, error) {
	encoded = strings.TrimSpace(encoded)
	if encoded == "" {
		return nil, errors.New("empty")
	}
	for _, encoding := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if raw, err := encoding.DecodeString(encoded); err == nil {
			return raw, nil
		}
	}
	return nil, errors.New("not base64")
}
