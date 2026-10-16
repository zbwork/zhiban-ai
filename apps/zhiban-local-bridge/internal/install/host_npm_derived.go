package install

// Claude Code host component for host versions nobody pinned in advance
// (contract §2.7.3 运行组件, 2026-09-15). Claude Desktop updates itself and may
// start pinning a newer host version; mainland China cannot reach
// downloads.claude.ai, and the compiled-in npm pin or a catalog row only cover
// versions prepared beforehand. The Bridge therefore derives the npmmirror
// tarball of exactly the version the installed Claude.app pins:
//
//  1. the package document (<registry>/<package>/<version>) must name that
//     package and version and point at the canonical tarball URL;
//  2. its dist.integrity (sha512) must carry a valid npm registry signature —
//     ECDSA P-256 over "<name>@<version>:<integrity>" with the registry's
//     published key compiled in — so a tampering mirror cannot forge it;
//  3. the downloaded tarball must match that size and sha512;
//  4. the executable inside must carry Anthropic's code signature (checked by
//     the caller exactly as for pinned versions) and report the pinned version
//     from --version before it is placed.

import (
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	// DefaultHostNPMRegistry serves the derived host tarballs (mainland
	// reachable; it mirrors npm's documents including their signatures).
	DefaultHostNPMRegistry = "https://registry.npmmirror.com"

	npmDocumentMaxBytes   = 1 << 20
	hostTarballMaxBytes   = 512 << 20
	npmDocumentTimeout    = 15 * time.Second
	hostVersionTimeout    = 20 * time.Second
	hostVersionOutputMax  = 4096
	npmIntegrityPrefix    = "sha512-"
	npmIntegrityDigestLen = 64
)

// DefaultNPMRegistryKeys are the npm registry's package signing keys by key
// id (https://registry.npmjs.org/-/npm/v1/keys, fetched 2026-09-15; the key
// with no expiry). Only these verify a derived host tarball's integrity.
func DefaultNPMRegistryKeys() map[string]string {
	return map[string]string{
		"SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEY6Ya7W++7aUPzvMTrezH6Ycx3c+HOKYCcNGybJZSCJq/fd7Qa8uuAKtdIkUQtQiEKERhAmE5lMMJhP8OkDOa2g==",
	}
}

var errNPMDocumentInvalid = errors.New("install: npm package document invalid")

// hostNPMPackage names Anthropic's per-platform npm package that carries the
// bare Claude Code executable.
func hostNPMPackage(platform, arch string) (string, bool) {
	switch {
	case platform == PlatformMacOS && arch == ArchARM64:
		return "@anthropic-ai/claude-code-darwin-arm64", true
	case platform == PlatformMacOS && arch == ArchX64:
		return "@anthropic-ai/claude-code-darwin-x64", true
	case platform == PlatformWindows && arch == ArchX64:
		return "@anthropic-ai/claude-code-win32-x64", true
	default:
		return "", false
	}
}

// hostNPMTarballURL is the canonical tarball URL of a scoped package version.
func hostNPMTarballURL(registry, name, version string) string {
	base := name[strings.LastIndex(name, "/")+1:]
	return strings.TrimRight(registry, "/") + "/" + name + "/-/" + base + "-" + version + ".tgz"
}

type npmPackageDocument struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Dist    struct {
		Tarball    string `json:"tarball"`
		Integrity  string `json:"integrity"`
		Size       int64  `json:"size"`
		Signatures []struct {
			KeyID string `json:"keyid"`
			Sig   string `json:"sig"`
		} `json:"signatures"`
	} `json:"dist"`
}

// verifyHostNPMDocument checks a package document against the expected
// package, version, canonical tarball URL and a registry signature, and
// returns the derived pin.
func verifyHostNPMDocument(document []byte, registry, name, version string, keys map[string]string) (HostNPMPin, error) {
	var parsed npmPackageDocument
	if err := json.Unmarshal(document, &parsed); err != nil {
		return HostNPMPin{}, errNPMDocumentInvalid
	}
	tarball := hostNPMTarballURL(registry, name, version)
	if parsed.Name != name || parsed.Version != version || parsed.Dist.Tarball != tarball ||
		parsed.Dist.Size <= 0 || parsed.Dist.Size > hostTarballMaxBytes {
		return HostNPMPin{}, errNPMDocumentInvalid
	}
	if !strings.HasPrefix(parsed.Dist.Integrity, npmIntegrityPrefix) {
		return HostNPMPin{}, errNPMDocumentInvalid
	}
	digest, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(parsed.Dist.Integrity, npmIntegrityPrefix))
	if err != nil || len(digest) != npmIntegrityDigestLen {
		return HostNPMPin{}, errNPMDocumentInvalid
	}
	message := sha256.Sum256([]byte(name + "@" + version + ":" + parsed.Dist.Integrity))
	signed := false
	for _, signature := range parsed.Dist.Signatures {
		encodedKey, ok := keys[signature.KeyID]
		if !ok {
			continue
		}
		public, err := parseECDSAPublicKey(encodedKey)
		if err != nil {
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(signature.Sig)
		if err != nil {
			continue
		}
		if ecdsa.VerifyASN1(public, message[:], raw) {
			signed = true
			break
		}
	}
	if !signed {
		return HostNPMPin{}, errNPMDocumentInvalid
	}
	pin := HostNPMPin{
		Source: Source{
			Kind: SourceKindNPMMirror, Layout: LayoutHostBinaryNPMTgz,
			URL: tarball, Size: parsed.Dist.Size, SHA512: hex.EncodeToString(digest),
		},
		Derived: true,
	}
	if err := pin.Validate(); err != nil {
		return HostNPMPin{}, errNPMDocumentInvalid
	}
	return pin, nil
}

func parseECDSAPublicKey(encoded string) (*ecdsa.PublicKey, error) {
	der, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	key, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	public, ok := key.(*ecdsa.PublicKey)
	if !ok {
		return nil, errNPMDocumentInvalid
	}
	return public, nil
}

// derivedHostNPMPin fetches and verifies the package document of the pinned
// host version. Any failure (unreachable registry, unpublished version, bad
// signature) simply means no derived source: the official URL stays.
func (m *Manager) derivedHostNPMPin(ctx context.Context, version string) (HostNPMPin, bool) {
	name, ok := hostNPMPackage(m.platform, m.arch)
	if !ok || m.hostNPMRegistry == "" {
		return HostNPMPin{}, false
	}
	document, err := m.client.getDocument(ctx, strings.TrimRight(m.hostNPMRegistry, "/")+"/"+name+"/"+version, npmDocumentMaxBytes)
	if err != nil {
		return HostNPMPin{}, false
	}
	pin, err := verifyHostNPMDocument(document, m.hostNPMRegistry, name, version, m.npmRegistryKeys)
	if err != nil {
		return HostNPMPin{}, false
	}
	return pin, true
}

// getDocument GETs a small JSON document from an allowed host.
func (d *downloadClient) getDocument(ctx context.Context, rawURL string, limit int64) ([]byte, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, errHostDenied
	}
	if err := d.validateURL(parsed, false); err != nil {
		return nil, err
	}
	requestCtx, cancel := context.WithTimeout(ctx, npmDocumentTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, errDownloadFailed
	}
	request.Header.Set("User-Agent", d.userAgent)
	request.Header.Set("Accept", "application/json")
	response, err := d.client.Do(request)
	if err != nil {
		return nil, classifyTransport(ctx, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, errDownloadFailed
	}
	if err := d.validateURL(response.Request.URL, false); err != nil {
		return nil, err
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil || int64(len(body)) > limit {
		return nil, errDownloadFailed
	}
	return body, nil
}

// checkHostVersion runs a signature-verified derived executable with
// --version and requires it to report the pinned version, so another
// Anthropic-signed release cannot stand in for the one Claude Desktop pins.
func (m *Manager) checkHostVersion(ctx context.Context, executable, version string) error {
	output, err := m.hostVersion(ctx, executable)
	if err != nil {
		return err
	}
	for _, field := range strings.Fields(output) {
		if strings.Trim(field, "v(),") == version {
			return nil
		}
	}
	return errPublisherMismatch
}

// defaultHostVersion executes the staged host with an isolated home so the
// check cannot read or write the user's Claude Code configuration.
func defaultHostVersion(ctx context.Context, executable string) (string, error) {
	home, err := os.MkdirTemp("", "zhiban-host-version-")
	if err != nil {
		return "", err
	}
	defer func() { _ = os.RemoveAll(home) }()
	runCtx, cancel := context.WithTimeout(ctx, hostVersionTimeout)
	defer cancel()
	command := exec.CommandContext(runCtx, executable, "--version")
	command.Dir = home
	command.Env = []string{
		"HOME=" + home, "USERPROFILE=" + home, "CLAUDE_CONFIG_DIR=" + home,
		"PATH=" + os.Getenv("PATH"), "DISABLE_AUTOUPDATER=1", "CI=1",
	}
	var output limitedWriter
	output.limit = hostVersionOutputMax
	command.Stdout = &output
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return "", err
	}
	return output.String(), nil
}

type limitedWriter struct {
	strings.Builder
	limit int
}

func (w *limitedWriter) Write(p []byte) (int, error) {
	if remaining := w.limit - w.Len(); remaining > 0 {
		if len(p) > remaining {
			_, _ = w.Builder.Write(p[:remaining])
		} else {
			_, _ = w.Builder.Write(p)
		}
	}
	return len(p), nil
}

// fileSHA256 returns the SHA-256 and size of a regular file.
func fileSHA256(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()
	hasher := sha256.New()
	size, err := io.Copy(hasher, file)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(hasher.Sum(nil)), size, nil
}
