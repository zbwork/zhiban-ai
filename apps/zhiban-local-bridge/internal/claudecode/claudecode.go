// Package claudecode knows the Claude Code host component that Claude Desktop
// needs before it can run a single 3P-mode chat turn (M3 plan Task 8).
//
// Claude Desktop pins the host version and the download checksums inside its
// own JavaScript (a JSON literal in Contents/Resources/app.asar). At first use
// it downloads <baseUrl>/<version>/darwin-<arch>/claude.app.tar.zst into
// ~/Library/Application Support/Claude-3p/claude-code/<version>/ and writes a
// .verified marker holding the bundle's SHA-256. Networks that cannot reach
// downloads.claude.ai leave the app stuck on "preparing session" forever, so
// the Bridge provisions the same files itself: it reads the pinned manifest
// from the (signature-verified) Claude.app, downloads the bundle from the
// pinned base URL only, checks size and hash, verifies the extracted bundle's
// Developer ID signature, and places it exactly where the app looks.
package claudecode

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/klauspost/compress/zstd"
)

const (
	// ComponentID is the component identifier surfaced to the App.
	ComponentID = "claude_code_host"

	StatePresent = "present"
	StateMissing = "missing"
	StateStale   = "stale"
	StateUnknown = "unknown"

	// AllowedBaseURL is the stable download base. Signed desktop manifests may
	// also pin /rc/<commit>, strictly validated against their manifest commit.
	AllowedBaseURL = "https://downloads.claude.ai/claude-code-releases"
	// BundleIdentifier and TeamIdentifier are what the host bundle's code
	// signature must declare (verified on 2.1.260, 2026-09-09).
	BundleIdentifier = "com.anthropic.claude-code"
	TeamIdentifier   = "Q6L2SF6YDW"
	// BundleName is the top-level entry of the host archive.
	BundleName = "claude.app"

	ArchARM64 = "arm64"
	ArchX64   = "x64"

	verifiedName = ".verified"
	// PayloadName is the sidecar Claude Desktop writes next to a bare host
	// executable on Windows: {"sha256": <exe>, "size": <bytes>}.
	PayloadName = ".payload"
	archiveName = "claude.app.tar.zst"
	// windowsArchiveName is the zstd-compressed bare executable Windows
	// downloads instead of a bundle.
	windowsArchiveName = "claude.exe.zst"
	maxAsarBytes       = 512 << 20
	maxVerifiedBytes   = 256
	// maxExtractedBytes bounds a single extraction (the 2.1.260 bundle is ~198 MB).
	maxExtractedBytes = 2 << 30
)

var (
	ErrManifestNotFound  = errors.New("claudecode: embedded manifest not found")
	ErrManifestInvalid   = errors.New("claudecode: embedded manifest invalid")
	ErrManifestUntrusted = errors.New("claudecode: embedded manifest names an unexpected download base")
	ErrArchiveInvalid    = errors.New("claudecode: host bundle archive invalid")

	versionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	sha256Pattern  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	commitPattern  = regexp.MustCompile(`^[0-9a-f]{40}$`)

	manifestStart  = []byte(`{"version":"`)
	manifestMarker = []byte(`"baseUrl":"` + AllowedBaseURL)
)

// Artifact is one downloadable file the manifest describes.
type Artifact struct {
	Checksum string `json:"checksum"`
	Size     int64  `json:"size"`
}

// Platform is the manifest entry for one OS/architecture.
type Platform struct {
	Binary   string    `json:"binary"`
	Checksum string    `json:"checksum"`
	Size     int64     `json:"size"`
	Bundle   *Artifact `json:"bundle,omitempty"`
}

// Manifest is the host component manifest pinned inside Claude Desktop.
type Manifest struct {
	Version   string
	BaseURL   string
	Platforms map[string]Platform
}

// Component is the state reported to the App in tool.detect.
type Component struct {
	ID      string `json:"id"`
	Version string `json:"version,omitempty"`
	State   string `json:"state"`
}

type embeddedLiteral struct {
	Version  string `json:"version"`
	Manifest *struct {
		Version   string              `json:"version"`
		Platforms map[string]Platform `json:"platforms"`
		Commit    string              `json:"commit"`
		BaseURL   string              `json:"baseUrl"`
	} `json:"manifest"`
	BaseURL string `json:"baseUrl"`
}

// BundleFor returns the host bundle artifact for the architecture (macOS
// manifest entries only carry a bundle; see HostArtifact for the per-platform
// artifact the Bridge provisions).
func (m Manifest) BundleFor(arch string) (Artifact, bool) {
	key, ok := PlatformKey(arch)
	if !ok {
		return Artifact{}, false
	}
	platform, ok := m.Platforms[key]
	if !ok || platform.Bundle == nil {
		return Artifact{}, false
	}
	return *platform.Bundle, true
}

// PlatformFor returns the whole manifest entry for the architecture: the
// bare executable's checksum and size plus the bundle artifact.
func (m Manifest) PlatformFor(arch string) (Platform, bool) {
	key, ok := PlatformKey(arch)
	if !ok {
		return Platform{}, false
	}
	platform, ok := m.Platforms[key]
	return platform, ok
}

// BundleURL is the only URL the bundle may be fetched from.
func (m Manifest) BundleURL(arch string) string {
	key, ok := PlatformKey(arch)
	if !ok {
		return ""
	}
	return m.BaseURL + "/" + m.Version + "/" + key + "/" + archiveName
}

// StorageDir is Claude Desktop's host component directory (StorageDirParts
// under the home directory; see host_unix.go / host_windows.go).
func StorageDir(homeDir string) string {
	return filepath.Join(append([]string{homeDir}, StorageDirParts()...)...)
}

// VersionDir holds one host version.
func VersionDir(homeDir, version string) string {
	return filepath.Join(StorageDir(homeDir), version)
}

// BundlePath is the placed host bundle.
func BundlePath(homeDir, version string) string {
	return filepath.Join(VersionDir(homeDir, version), BundleName)
}

// VerifiedPath is the marker Claude Desktop checks before trusting the binary.
func VerifiedPath(homeDir, version string) string {
	return filepath.Join(VersionDir(homeDir, version), verifiedName)
}

// VerifiedName is the marker file name inside a version directory.
func VerifiedName() string { return verifiedName }

// BinaryRelativePath is the executable's path inside the bundle.
func BinaryRelativePath() string { return binaryRelativePath }

// DeveloperIDRequirement is the codesign designated requirement the host
// bundle must satisfy.
func DeveloperIDRequirement() string {
	return `anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "` +
		TeamIdentifier + `" and identifier "` + BundleIdentifier + `"`
}

type manifestCacheKey struct {
	path    string
	size    int64
	modTime int64
}

var manifestCache sync.Map // manifestCacheKey -> Manifest

// ReadEmbeddedManifest extracts the pinned host manifest from the Claude
// Desktop bundle at bundlePath. Results are cached per (path, size, mtime) so
// repeated detections do not rescan the archive.
func ReadEmbeddedManifest(bundlePath string) (Manifest, error) {
	asarPath := filepath.Join(filepath.Clean(bundlePath), asarRelativePath)
	info, err := os.Lstat(asarPath)
	if err != nil {
		return Manifest{}, ErrManifestNotFound
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxAsarBytes {
		return Manifest{}, ErrManifestInvalid
	}
	key := manifestCacheKey{path: asarPath, size: info.Size(), modTime: info.ModTime().UnixNano()}
	if cached, ok := manifestCache.Load(key); ok {
		return cached.(Manifest), nil
	}
	file, err := os.Open(asarPath)
	if err != nil {
		return Manifest{}, ErrManifestNotFound
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxAsarBytes+1))
	if err != nil || int64(len(data)) != info.Size() {
		return Manifest{}, ErrManifestInvalid
	}
	manifest, err := ParseEmbeddedManifest(data)
	if err != nil {
		return Manifest{}, err
	}
	manifestCache.Store(key, manifest)
	return manifest, nil
}

// ParseEmbeddedManifest finds the manifest literal in raw archive bytes.
func ParseEmbeddedManifest(data []byte) (Manifest, error) {
	marker := bytes.Index(data, manifestMarker)
	if marker < 0 {
		return Manifest{}, ErrManifestNotFound
	}
	// The literal is the nearest `{"version":"` object before the base URL that
	// still encloses it (the nested "manifest" object also starts with
	// `{"version":"`, so candidates are tried from the nearest backwards). The
	// search window is bounded so a stray prefix elsewhere cannot hijack it.
	windowStart := marker - 64<<10
	if windowStart < 0 {
		windowStart = 0
	}
	cursor := marker
	for cursor > windowStart {
		start := bytes.LastIndex(data[windowStart:cursor], manifestStart)
		if start < 0 {
			break
		}
		start += windowStart
		end, ok := balancedJSONEnd(data, start)
		if ok && end > marker {
			var literal embeddedLiteral
			if err := json.Unmarshal(data[start:end], &literal); err != nil {
				return Manifest{}, ErrManifestInvalid
			}
			// New manifests repeat baseUrl inside manifest itself. That inner
			// object is not the envelope; keep looking for its enclosing object.
			if literal.Manifest != nil {
				return validateLiteral(literal)
			}
		}
		cursor = start
	}
	return Manifest{}, ErrManifestNotFound
}

func validateLiteral(literal embeddedLiteral) (Manifest, error) {
	if literal.Manifest == nil || !versionPattern.MatchString(literal.Version) || literal.Manifest.Version != literal.Version ||
		len(literal.Manifest.Platforms) == 0 {
		return Manifest{}, ErrManifestInvalid
	}
	if literal.Manifest.BaseURL != "" && literal.Manifest.BaseURL != literal.BaseURL {
		return Manifest{}, ErrManifestUntrusted
	}
	if literal.BaseURL != AllowedBaseURL &&
		(!commitPattern.MatchString(literal.Manifest.Commit) || literal.BaseURL != AllowedBaseURL+"/rc/"+literal.Manifest.Commit) {
		return Manifest{}, ErrManifestUntrusted
	}
	platforms := make(map[string]Platform, len(literal.Manifest.Platforms))
	for key, platform := range literal.Manifest.Platforms {
		if platform.Bundle != nil {
			if !sha256Pattern.MatchString(platform.Bundle.Checksum) || platform.Bundle.Size <= 0 {
				return Manifest{}, ErrManifestInvalid
			}
		}
		platforms[key] = platform
	}
	return Manifest{Version: literal.Version, BaseURL: literal.BaseURL, Platforms: platforms}, nil
}

// balancedJSONEnd returns the index just past the object that starts at start.
func balancedJSONEnd(data []byte, start int) (int, bool) {
	depth := 0
	inString := false
	escaped := false
	for index := start; index < len(data); index++ {
		char := data[index]
		if inString {
			switch {
			case escaped:
				escaped = false
			case char == '\\':
				escaped = true
			case char == '"':
				inString = false
			}
			continue
		}
		switch char {
		case '"':
			inString = true
		case '{', '[':
			depth++
		case '}', ']':
			depth--
			if depth == 0 {
				return index + 1, true
			}
			if depth < 0 {
				return 0, false
			}
		case '\n', '\r':
			return 0, false
		}
	}
	return 0, false
}

// Status reports whether the host component the manifest pins is present.
func Status(homeDir string, manifest Manifest, arch string) Component {
	component := Component{ID: ComponentID, Version: manifest.Version, State: StateUnknown}
	artifact, ok := HostArtifact(manifest, arch)
	if !ok || manifest.Version == "" {
		return component
	}
	versionDir := VersionDir(homeDir, manifest.Version)
	// Newer desktops migrate an existing install into <version>/<sha256[:12]>.
	// Only check the directory pinned by this platform's full artifact hash;
	// the binary and full marker must be valid in the SAME directory.
	if sha256Pattern.MatchString(artifact.Checksum) {
		for _, dir := range []string{filepath.Join(versionDir, artifact.Checksum[:12]), versionDir} {
			if hostBinaryReady(dir) && verifiedMatches(filepath.Join(dir, verifiedName), artifact.Checksum) {
				component.State = StatePresent
				return component
			}
		}
	}
	if !exists(versionDir) {
		component.State = StateMissing
	} else {
		component.State = StateStale
	}
	return component
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func verifiedMatches(path, checksum string) bool {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxVerifiedBytes {
		return false
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(content)) == checksum
}

// IsExecutableMachO reports whether path (symlinks followed, as Claude
// Desktop's open/spawn do) is a regular executable file whose header is a
// Mach-O (thin 64-bit or universal) image — the same check Claude Desktop
// applies before spawning the host binary.
func IsExecutableMachO(path string) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return false
	}
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	header := make([]byte, 4)
	if _, err := io.ReadFull(file, header); err != nil {
		return false
	}
	switch binary.BigEndian.Uint32(header) {
	case 0xCAFEBABE, 0xCAFEBABF: // universal binary
		return true
	}
	switch binary.LittleEndian.Uint32(header) {
	case 0xFEEDFACF, 0xFEEDFACE: // thin Mach-O, 64/32-bit
		return true
	}
	return false
}

// ExtractHostBundle unpacks a claude.app.tar.zst archive into destinationDir.
// Only directories and regular files under claude.app/ are accepted; symlinks,
// devices, absolute paths and parent references make the archive invalid.
func ExtractHostBundle(ctx context.Context, archive io.Reader, destinationDir string) error {
	decoder, err := zstd.NewReader(archive, zstd.WithDecoderConcurrency(1), zstd.WithDecoderMaxMemory(256<<20))
	if err != nil {
		return ErrArchiveInvalid
	}
	defer decoder.Close()
	reader := tar.NewReader(decoder)
	var total int64
	sawBinary := false
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return ErrArchiveInvalid
		}
		name, ok := safeMemberName(header.Name)
		if !ok {
			return ErrArchiveInvalid
		}
		target := filepath.Join(destinationDir, filepath.FromSlash(name))
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if header.Size < 0 {
				return ErrArchiveInvalid
			}
			total += header.Size
			if total > maxExtractedBytes {
				return ErrArchiveInvalid
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			mode := os.FileMode(header.Mode) & 0o777
			if mode&0o400 == 0 {
				mode |= 0o600
			}
			if err := writeMember(target, reader, header.Size, mode); err != nil {
				return err
			}
			if name == BundleName+"/"+binaryRelativePath {
				sawBinary = true
			}
		default:
			return ErrArchiveInvalid
		}
	}
	if !sawBinary || !IsExecutableMachO(filepath.Join(destinationDir, BundleName, filepath.FromSlash(binaryRelativePath))) {
		return ErrArchiveInvalid
	}
	return nil
}

// npmLinkTarget is the relative symlink from
// claude.app/Contents/MacOS/claude back to <version>/claude.
const npmLinkTarget = "../../../" + NPMBinaryName

// ExtractHostBinaryFromNPM writes the bare executable inside a Claude Code npm
// tarball (gzip tar, member package/claude) to destinationDir/claude. The
// member must match the pinned SHA-256 and, when expectedSize is positive,
// the pinned size (a version catalog entry carries only the hash; the member
// is then bounded by maxExtractedBytes); everything else in the tarball is
// ignored (M3 Task 9: npmmirror as the host component fallback source). Call
// ArrangeHostBinary after verifying the executable's signature.
func ExtractHostBinaryFromNPM(ctx context.Context, archive io.Reader, destinationDir string, expectedSize int64, expectedSHA256 string) error {
	// An empty expectedSHA256 is only passed for a registry-derived host pin,
	// whose executable is checked by code signature and version afterwards.
	if expectedSize < 0 || expectedSize > maxExtractedBytes || (expectedSHA256 != "" && len(expectedSHA256) != 64) {
		return ErrArchiveInvalid
	}
	decoder, err := gzip.NewReader(archive)
	if err != nil {
		return ErrArchiveInvalid
	}
	defer decoder.Close()
	reader := tar.NewReader(decoder)
	target := filepath.Join(destinationDir, NPMBinaryName)
	found := false
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return ErrArchiveInvalid
		}
		if header.Name == "" || strings.HasPrefix(header.Name, "/") || strings.Contains(header.Name, "\\") || strings.ContainsRune(header.Name, 0) {
			return ErrArchiveInvalid
		}
		name := path.Clean(header.Name)
		if name == ".." || strings.HasPrefix(name, "../") || strings.Contains(name, "/../") {
			return ErrArchiveInvalid
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeDir {
			return ErrArchiveInvalid
		}
		if name != npmMemberName {
			continue // package.json, README.md, LICENSE.md
		}
		if found || header.Typeflag != tar.TypeReg || header.Size <= 0 || header.Size > maxExtractedBytes ||
			(expectedSize > 0 && header.Size != expectedSize) {
			return ErrArchiveInvalid
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		hasher := sha256.New()
		if err := writeMember(target, io.TeeReader(reader, hasher), header.Size, 0o755); err != nil {
			return err
		}
		if expectedSHA256 != "" && hex.EncodeToString(hasher.Sum(nil)) != expectedSHA256 {
			return ErrArchiveInvalid
		}
		found = true
	}
	if !found || !IsExecutableImage(target) {
		return ErrArchiveInvalid
	}
	return nil
}

// ExtractHostBinaryZst decompresses a zstd stream of the bare host executable
// (Windows: <baseUrl>/<version>/win32-<arch>/claude.exe.zst) into
// destinationDir/<NPMBinaryName> and returns the executable's SHA-256 and
// size — what Claude Desktop records in the .payload sidecar. The stream is
// bounded like every other extraction.
func ExtractHostBinaryZst(ctx context.Context, archive io.Reader, destinationDir string) (sha256Hex string, size int64, err error) {
	if ctx.Err() != nil {
		return "", 0, ctx.Err()
	}
	decoder, err := zstd.NewReader(archive, zstd.WithDecoderConcurrency(1), zstd.WithDecoderMaxMemory(256<<20))
	if err != nil {
		return "", 0, ErrArchiveInvalid
	}
	defer decoder.Close()
	target := filepath.Join(destinationDir, NPMBinaryName)
	file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o755)
	if err != nil {
		return "", 0, err
	}
	hasher := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(decoder, maxExtractedBytes+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || written <= 0 || written > maxExtractedBytes {
		_ = os.Remove(target)
		return "", 0, ErrArchiveInvalid
	}
	if !IsExecutableImage(target) {
		_ = os.Remove(target)
		return "", 0, ErrArchiveInvalid
	}
	return hex.EncodeToString(hasher.Sum(nil)), written, nil
}

// ArrangeHostBinary builds destinationDir/claude.app/Contents/MacOS/claude as
// a relative symlink to destinationDir/claude, which stays where it is. The
// resulting bundle carries no Info.plist or code seal: Claude Desktop only
// checks the Mach-O header and the .verified marker, and spawns through the
// link (see NPMBinaryName for why the executable must not live inside the
// bundle itself).
func ArrangeHostBinary(destinationDir string) error {
	flat := filepath.Join(destinationDir, NPMBinaryName)
	if info, err := os.Lstat(flat); err != nil || !info.Mode().IsRegular() || !IsExecutableMachO(flat) {
		return ErrArchiveInvalid
	}
	target := filepath.Join(destinationDir, BundleName, filepath.FromSlash(binaryRelativePath))
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	return os.Symlink(npmLinkTarget, target)
}

// binaryWithinVersionDir reports whether the spawned path resolves (through
// symlinks) to a file inside versionDir, so a link cannot point the host at
// an arbitrary executable elsewhere.
func binaryWithinVersionDir(binary, versionDir string) bool {
	resolved, err := filepath.EvalSymlinks(binary)
	if err != nil {
		return false
	}
	root, err := filepath.EvalSymlinks(versionDir)
	if err != nil {
		return false
	}
	return resolved == root || strings.HasPrefix(resolved, root+string(filepath.Separator))
}

func safeMemberName(raw string) (string, bool) {
	if raw == "" || strings.HasPrefix(raw, "/") || strings.Contains(raw, "\\") || strings.ContainsRune(raw, 0) {
		return "", false
	}
	name := path.Clean(raw)
	if name == "." || name == ".." || strings.HasPrefix(name, "../") || strings.Contains(name, "/../") {
		return "", false
	}
	if name != BundleName && !strings.HasPrefix(name, BundleName+"/") {
		return "", false
	}
	return name, true
}

func writeMember(target string, source io.Reader, size int64, mode os.FileMode) error {
	file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	written, copyErr := io.Copy(file, io.LimitReader(source, size+1))
	closeErr := file.Close()
	if copyErr != nil {
		return ErrArchiveInvalid
	}
	if written != size || closeErr != nil {
		return ErrArchiveInvalid
	}
	// The archive stores the intended mode; umask must not weaken the
	// executable bit Claude Desktop relies on.
	return os.Chmod(target, mode)
}
