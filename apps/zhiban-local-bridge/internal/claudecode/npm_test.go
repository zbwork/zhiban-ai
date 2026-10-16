package claudecode

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func npmTarball(t *testing.T, members map[string][]byte, order []string) []byte {
	t.Helper()
	var tarBuffer bytes.Buffer
	writer := tar.NewWriter(&tarBuffer)
	for _, name := range order {
		content := members[name]
		header := &tar.Header{Name: name, Mode: 0o644, Typeflag: tar.TypeReg, Size: int64(len(content))}
		if name == "package/claude" {
			header.Mode = 0o755
		}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(content); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	gz := gzip.NewWriter(&out)
	if _, err := gz.Write(tarBuffer.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func sha256Hex(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

func TestExtractHostBinaryFromNPMBuildsBundleLayout(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	binary := append([]byte{0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01}, bytes.Repeat([]byte{0x11}, 300)...)
	tarball := npmTarball(t, map[string][]byte{
		"package/package.json": []byte(`{"name":"@anthropic-ai/claude-code-darwin-arm64","version":"2.1.260"}`),
		"package/claude":       binary,
		"package/README.md":    []byte("readme"),
	}, []string{"package/package.json", "package/claude", "package/README.md"})

	dir := t.TempDir()
	if err := ExtractHostBinaryFromNPM(context.Background(), bytes.NewReader(tarball), dir, int64(len(binary)), sha256Hex(binary)); err != nil {
		t.Fatalf("ExtractHostBinaryFromNPM() error = %v", err)
	}
	// Flat first: this is the path codesign verifies as a plain Mach-O.
	flat := filepath.Join(dir, NPMBinaryName)
	content, err := os.ReadFile(flat)
	if err != nil || !bytes.Equal(content, binary) {
		t.Fatalf("flat binary = %d bytes, %v", len(content), err)
	}
	if info, err := os.Stat(flat); err != nil || info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("binary mode = %v, %v", info, err)
	}
	if entries, err := os.ReadDir(dir); err != nil || len(entries) != 1 {
		t.Fatalf("only the executable may be materialised: %v, %v", entries, err)
	}
	if err := ArrangeHostBinary(dir); err != nil {
		t.Fatalf("ArrangeHostBinary() error = %v", err)
	}
	placed := filepath.Join(dir, BundleName, filepath.FromSlash(BinaryRelativePath()))
	if content, err := os.ReadFile(placed); err != nil || !bytes.Equal(content, binary) {
		t.Fatalf("placed binary = %d bytes, %v", len(content), err)
	}
	// The executable stays flat; the bundle only links to it (a real file
	// inside *.app/Contents/MacOS/ is killed at exec on macOS 26).
	if info, err := os.Lstat(flat); err != nil || !info.Mode().IsRegular() {
		t.Fatalf("flat executable must stay in place: %v, %v", info, err)
	}
	if info, err := os.Lstat(placed); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("bundle entry must be a symlink: %v, %v", info, err)
	}
	if link, err := os.Readlink(placed); err != nil || link != "../../../claude" {
		t.Fatalf("symlink target = %q, %v", link, err)
	}
	if !IsExecutableMachO(placed) {
		t.Fatal("IsExecutableMachO must follow the symlink")
	}
	// Only the executable is materialised; package metadata never lands in the bundle.
	entries, err := os.ReadDir(filepath.Join(dir, BundleName, "Contents"))
	if err != nil || len(entries) != 1 || entries[0].Name() != "MacOS" {
		t.Fatalf("bundle contents = %v, %v", entries, err)
	}
	if err := ArrangeHostBinary(t.TempDir()); err == nil {
		t.Fatal("ArrangeHostBinary without an extracted executable must fail")
	}
}

func TestExtractHostBinaryFromNPMRejectsMismatches(t *testing.T) {
	t.Parallel()
	binary := append([]byte{0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01}, bytes.Repeat([]byte{0x22}, 100)...)
	good := npmTarball(t, map[string][]byte{"package/claude": binary}, []string{"package/claude"})

	cases := map[string]struct {
		archive []byte
		size    int64
		sha     string
	}{
		"wrong sha":   {good, int64(len(binary)), sha256Hex([]byte("other"))},
		"wrong size":  {good, int64(len(binary)) + 1, sha256Hex(binary)},
		"no member":   {npmTarball(t, map[string][]byte{"package/other": binary}, []string{"package/other"}), int64(len(binary)), sha256Hex(binary)},
		"not gzip":    {[]byte("plain text"), int64(len(binary)), sha256Hex(binary)},
		"not mach-o":  {npmTarball(t, map[string][]byte{"package/claude": []byte("#!/bin/sh\n")}, []string{"package/claude"}), 10, sha256Hex([]byte("#!/bin/sh\n"))},
		"traversal":   {npmTarball(t, map[string][]byte{"package/../claude": binary}, []string{"package/../claude"}), int64(len(binary)), sha256Hex(binary)},
		"bad pin sha": {good, int64(len(binary)), "short"},
	}
	for name, tc := range cases {
		dir := t.TempDir()
		err := ExtractHostBinaryFromNPM(context.Background(), bytes.NewReader(tc.archive), dir, tc.size, tc.sha)
		if !errors.Is(err, ErrArchiveInvalid) {
			t.Fatalf("%s: error = %v, want ErrArchiveInvalid", name, err)
		}
	}
}

// A version catalog entry carries only the executable's hash: size 0 means
// "unknown", the member is then bounded by maxExtractedBytes and checked by
// hash alone; a wrong hash still fails.
func TestExtractHostBinaryFromNPMAcceptsHashOnlyPin(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	binary := append([]byte{0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01}, bytes.Repeat([]byte{0x33}, 100)...)
	tarball := npmTarball(t, map[string][]byte{"package/claude": binary}, []string{"package/claude"})
	dir := t.TempDir()
	if err := ExtractHostBinaryFromNPM(context.Background(), bytes.NewReader(tarball), dir, 0, sha256Hex(binary)); err != nil {
		t.Fatalf("hash-only extraction error = %v", err)
	}
	placed, err := os.ReadFile(filepath.Join(dir, NPMBinaryName))
	if err != nil || !bytes.Equal(placed, binary) {
		t.Fatalf("placed executable mismatch: %v", err)
	}
	if err := ExtractHostBinaryFromNPM(context.Background(), bytes.NewReader(tarball), t.TempDir(), 0, sha256Hex([]byte("other"))); !errors.Is(err, ErrArchiveInvalid) {
		t.Fatalf("hash-only with wrong hash error = %v, want ErrArchiveInvalid", err)
	}
	if err := ExtractHostBinaryFromNPM(context.Background(), bytes.NewReader(tarball), t.TempDir(), -1, sha256Hex(binary)); !errors.Is(err, ErrArchiveInvalid) {
		t.Fatalf("negative size error = %v, want ErrArchiveInvalid", err)
	}
}

// TestRealNPMTarballWhenProvided runs the extractor against a real
// @anthropic-ai/claude-code-darwin-<arch> tarball: ZHIBAN_NPM_TGZ=<path>
// ZHIBAN_NPM_BINARY_SIZE=<bytes> ZHIBAN_NPM_BINARY_SHA256=<hex>.
func TestRealNPMTarballWhenProvided(t *testing.T) {
	path := os.Getenv("ZHIBAN_NPM_TGZ")
	if path == "" {
		t.Skip("ZHIBAN_NPM_TGZ not set")
	}
	var size int64
	if _, err := fmt.Sscan(os.Getenv("ZHIBAN_NPM_BINARY_SIZE"), &size); err != nil {
		t.Fatalf("ZHIBAN_NPM_BINARY_SIZE: %v", err)
	}
	sha := os.Getenv("ZHIBAN_NPM_BINARY_SHA256")
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	dir := t.TempDir()
	if err := ExtractHostBinaryFromNPM(context.Background(), file, dir, size, sha); err != nil {
		t.Fatalf("ExtractHostBinaryFromNPM(real tarball) error = %v", err)
	}
	flat := filepath.Join(dir, NPMBinaryName)
	info, err := os.Stat(flat)
	if err != nil || info.Size() != size || !IsExecutableMachO(flat) {
		t.Fatalf("flat = %v, %v", info, err)
	}
	if err := ArrangeHostBinary(dir); err != nil {
		t.Fatalf("ArrangeHostBinary() error = %v", err)
	}
	t.Logf("real npm tarball extracted and arranged: %d bytes", info.Size())
}
