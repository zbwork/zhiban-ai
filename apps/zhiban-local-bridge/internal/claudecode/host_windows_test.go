//go:build windows

package claudecode

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

func TestWindowsHostManifestAndExtraction(t *testing.T) {
	t.Parallel()
	binary := append([]byte("MZ"), bytes.Repeat([]byte{0x11}, 126)...)
	encoder, err := zstd.NewWriter(nil)
	if err != nil {
		t.Fatal(err)
	}
	compressed := encoder.EncodeAll(binary, nil)
	encoder.Close()
	manifest := Manifest{Version: "2.1.260", BaseURL: AllowedBaseURL, Platforms: map[string]Platform{
		"win32-x64": {Binary: "claude.exe.zst", Checksum: sha256Hex(compressed), Size: int64(len(compressed))},
	}}
	artifact, ok := HostArtifact(manifest, ArchX64)
	if !ok || artifact.Checksum != sha256Hex(compressed) || artifact.Size != int64(len(compressed)) {
		t.Fatalf("artifact = %+v, %v", artifact, ok)
	}
	if got := HostArtifactURL(manifest, ArchX64); got != AllowedBaseURL+"/2.1.260/win32-x64/claude.exe.zst" {
		t.Fatal(got)
	}
	if _, ok := HostArtifact(manifest, ArchARM64); ok {
		t.Fatal("missing architecture accepted")
	}
	dir := t.TempDir()
	hash, size, err := ExtractHostBinaryZst(context.Background(), bytes.NewReader(compressed), dir)
	if err != nil || hash != sha256Hex(binary) || size != int64(len(binary)) {
		t.Fatalf("extract = %s, %d, %v", hash, size, err)
	}
	placed, err := os.ReadFile(filepath.Join(dir, "claude.exe"))
	if err != nil || !bytes.Equal(placed, binary) {
		t.Fatalf("placed binary differs: %v", err)
	}
	if _, _, err := ExtractHostBinaryZst(context.Background(), bytes.NewReader(compressed), dir); err == nil {
		t.Fatal("existing executable overwritten")
	}
	bad := encoderForWindowsTest(t, []byte("not a PE executable"))
	if _, _, err := ExtractHostBinaryZst(context.Background(), bytes.NewReader(bad), t.TempDir()); !errors.Is(err, ErrArchiveInvalid) {
		t.Fatalf("invalid image accepted: %v", err)
	}
}

func encoderForWindowsTest(t *testing.T, content []byte) []byte {
	t.Helper()
	encoder, err := zstd.NewWriter(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Close()
	return encoder.EncodeAll(content, nil)
}

func TestWindowsNPMHostExtractionChecksHash(t *testing.T) {
	t.Parallel()
	binary := append([]byte("MZ"), bytes.Repeat([]byte{0x22}, 126)...)
	archive := npmTarball(t, map[string][]byte{"package/claude.exe": binary}, []string{"package/claude.exe"})
	for _, size := range []int64{0, int64(len(binary))} {
		dir := t.TempDir()
		if err := ExtractHostBinaryFromNPM(context.Background(), bytes.NewReader(archive), dir, size, sha256Hex(binary)); err != nil {
			t.Fatal(err)
		}
		if !IsExecutablePE(filepath.Join(dir, "claude.exe")) {
			t.Fatal("PE missing")
		}
	}
	if err := ExtractHostBinaryFromNPM(context.Background(), bytes.NewReader(archive), t.TempDir(), int64(len(binary)), strings.Repeat("0", 64)); !errors.Is(err, ErrArchiveInvalid) {
		t.Fatalf("wrong hash accepted: %v", err)
	}
}
