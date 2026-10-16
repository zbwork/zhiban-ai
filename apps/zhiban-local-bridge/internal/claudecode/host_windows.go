//go:build windows

package claudecode

import (
	"encoding/binary"
	"io"
	"os"
	"path/filepath"
)

// Windows host component facts (M3-W, read out of Claude Desktop 1.49585.0's
// app.asar on 2026-09-10 and confirmed on the test machine). The app uses no
// bundle here: it downloads <baseUrl>/<version>/win32-x64/claude.exe.zst,
// verifies that stream against platforms["win32-x64"].checksum, decompresses
// it to %LOCALAPPDATA%\Claude-3p\claude-code\<version>\claude.exe, writes
// .payload ({"sha256": <exe>, "size": <bytes>}) and .verified holding the
// *zst* checksum. Readiness = claude.exe present and .verified equal to that
// checksum. The Bridge lays the same files down.

const (
	// asarRelativePath is relative to the package root folder
	// (C:\Program Files\WindowsApps\<PackageFullName>).
	asarRelativePath = `app\resources\app.asar`
	// binaryRelativePath only exists for the shared bundle extractor to
	// compile; Windows never extracts a bundle.
	binaryRelativePath = "Contents/MacOS/claude"

	// npmMemberName is the bare executable inside an
	// @anthropic-ai/claude-code-win32-<arch> npm tarball.
	npmMemberName = "package/claude.exe"
	// NPMBinaryName is the executable's file name in the version directory,
	// for both the npm and the zst source.
	NPMBinaryName = "claude.exe"

	// SignerName is the Authenticode subject CN the host executable must
	// carry (checked on 2.1.260, 2026-09-10).
	SignerName = "Anthropic, PBC"
)

// PlatformKey maps the Bridge's architecture names onto the manifest keys.
func PlatformKey(arch string) (string, bool) {
	switch arch {
	case ArchARM64:
		return "win32-arm64", true
	case ArchX64:
		return "win32-x64", true
	default:
		return "", false
	}
}

// StorageDirParts is Claude Desktop's host component directory relative to
// the home directory (%LOCALAPPDATA% in its default location).
func StorageDirParts() []string {
	return []string{"AppData", "Local", "Claude-3p", "claude-code"}
}

// BinaryPath is the executable Claude Desktop spawns.
func BinaryPath(homeDir, version string) string {
	return filepath.Join(VersionDir(homeDir, version), NPMBinaryName)
}

// HostArtifact is the zstd stream of the bare executable; its checksum is
// what .verified must hold.
func HostArtifact(m Manifest, arch string) (Artifact, bool) {
	platform, ok := m.PlatformFor(arch)
	if !ok || platform.Binary != windowsArchiveName || !sha256Pattern.MatchString(platform.Checksum) || platform.Size <= 0 {
		return Artifact{}, false
	}
	return Artifact{Checksum: platform.Checksum, Size: platform.Size}, true
}

// HostArtifactURL is the only URL the host artifact may be fetched from.
func HostArtifactURL(m Manifest, arch string) string {
	key, ok := PlatformKey(arch)
	if !ok {
		return ""
	}
	return m.BaseURL + "/" + m.Version + "/" + key + "/" + windowsArchiveName
}

// hostBinaryReady checks a legacy or checksum-named install directory.
func hostBinaryReady(installDir string) bool {
	return IsExecutablePE(filepath.Join(installDir, NPMBinaryName))
}

// IsExecutableImage is the platform executable-header check.
func IsExecutableImage(path string) bool { return IsExecutablePE(path) }

// IsExecutablePE reports whether path is a regular file starting with the
// MZ DOS header every Windows executable carries (permission bits are
// synthetic on Windows, so only the header is checked).
func IsExecutablePE(path string) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() < 64 {
		return false
	}
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	header := make([]byte, 2)
	if _, err := io.ReadFull(file, header); err != nil {
		return false
	}
	return binary.LittleEndian.Uint16(header) == 0x5a4d // "MZ"
}

// HostSignatureRequirement is what the placed host executable's Authenticode
// signature must carry: a valid chain and this signer subject CN.
func HostSignatureRequirement() string { return SignerName }
