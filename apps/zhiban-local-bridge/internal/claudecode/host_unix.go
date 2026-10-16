//go:build !windows

package claudecode

import "path/filepath"

// macOS host component facts (M3 Task 8/9). Claude Desktop keeps the host as
// an application bundle: <version>/claude.app with the executable at
// Contents/MacOS/claude, downloaded as claude.app.tar.zst, and .verified holds
// the bundle archive's SHA-256.

const (
	asarRelativePath   = "Contents/Resources/app.asar"
	binaryRelativePath = "Contents/MacOS/claude"

	// npmMemberName is the bare executable inside an
	// @anthropic-ai/claude-code-darwin-<arch> npm tarball.
	npmMemberName = "package/claude"

	// NPMBinaryName is the flat file ExtractHostBinaryFromNPM writes into the
	// destination directory and where it stays: the executable is verified
	// there, as a plain Mach-O, and ArrangeHostBinary then only *links* it into
	// the bundle layout. A standalone-signed binary must never be a real file
	// under *.app/Contents/MacOS/: codesign infers a bundle and demands the
	// CodeResources seal the npm package does not ship, and on macOS 26 the
	// kernel kills such a process at exec (exit 137, "Blocked by endpoint
	// security" in Claude Desktop; 11915/11916 test Mac). Executed through a
	// symlink the same bytes run normally, because the kernel judges the
	// bundle context by the resolved path.
	NPMBinaryName = "claude"
)

// PlatformKey maps the Bridge's architecture names onto the manifest keys.
func PlatformKey(arch string) (string, bool) {
	switch arch {
	case ArchARM64:
		return "darwin-arm64", true
	case ArchX64:
		return "darwin-x64", true
	default:
		return "", false
	}
}

// StorageDirParts is Claude Desktop's host component directory relative to
// the home directory.
func StorageDirParts() []string {
	return []string{"Library", "Application Support", "Claude-3p", "claude-code"}
}

// BinaryPath is the executable Claude Desktop spawns.
func BinaryPath(homeDir, version string) string {
	return filepath.Join(BundlePath(homeDir, version), binaryRelativePath)
}

// HostArtifact is the file the Bridge provisions for this platform: the host
// bundle archive, whose SHA-256 is what .verified must hold.
func HostArtifact(m Manifest, arch string) (Artifact, bool) {
	return m.BundleFor(arch)
}

// HostArtifactURL is the only URL the host artifact may be fetched from.
func HostArtifactURL(m Manifest, arch string) string {
	return m.BundleURL(arch)
}

// hostBinaryReady checks a legacy or checksum-named install directory,
// following symlinks only within that install as Claude Desktop spawns it.
func hostBinaryReady(installDir string) bool {
	binary := filepath.Join(installDir, BundleName, binaryRelativePath)
	return IsExecutableMachO(binary) && binaryWithinVersionDir(binary, installDir)
}

// IsExecutableImage is the platform executable-header check.
func IsExecutableImage(path string) bool { return IsExecutableMachO(path) }

// HostSignatureRequirement is what the placed host executable's signature
// must satisfy (the Developer ID designated requirement on macOS).
func HostSignatureRequirement() string { return DeveloperIDRequirement() }
