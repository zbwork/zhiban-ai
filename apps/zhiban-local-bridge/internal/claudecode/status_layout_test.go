package claudecode

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestStatusSurvivesDesktopHostMigration(t *testing.T) {
	t.Parallel()
	checksum := strings.Repeat("a", 64)
	platformKey, _ := PlatformKey(ArchX64)
	manifest := Manifest{Version: "2.1.293", Platforms: map[string]Platform{
		platformKey: {Binary: windowsArchiveName, Checksum: checksum, Size: 100,
			Bundle: &Artifact{Checksum: checksum, Size: 100}},
	}}
	home := t.TempDir()
	versionDir := VersionDir(home, manifest.Version)
	writeStatusBinary(t, versionDir)
	writeStatusMarker(t, versionDir, checksum)
	if got := Status(home, manifest, ArchX64); got.State != StatePresent {
		t.Fatalf("before desktop launch = %+v", got)
	}
	// Claude moves the existing install into a checksum-named child at launch.
	migrated := filepath.Join(versionDir, checksum[:12])
	if err := os.MkdirAll(migrated, 0o755); err != nil {
		t.Fatal(err)
	}
	binaryName := BundleName
	if runtime.GOOS == "windows" {
		binaryName = NPMBinaryName
	}
	for _, name := range []string{binaryName, verifiedName} {
		if err := os.Rename(filepath.Join(versionDir, name), filepath.Join(migrated, name)); err != nil {
			t.Fatal(err)
		}
	}
	if got := Status(home, manifest, ArchX64); got.State != StatePresent {
		t.Fatalf("after desktop migration = %+v", got)
	}
}

func TestStatusRequiresMatchingFilesInOneHostDirectory(t *testing.T) {
	t.Parallel()
	checksum := strings.Repeat("a", 64)
	key, _ := PlatformKey(ArchX64)
	manifest := Manifest{Version: "2.1.293", Platforms: map[string]Platform{
		key: {Binary: windowsArchiveName, Checksum: checksum, Size: 100,
			Bundle: &Artifact{Checksum: checksum, Size: 100}},
	}}
	for _, test := range []struct {
		name, binaryDir, markerDir, marker string
		want                               string
	}{
		{"missing", "", "", "", StateMissing},
		{"new layout", "aaaaaaaaaaaa", "aaaaaaaaaaaa", checksum, StatePresent},
		{"other checksum directory", "bbbbbbbbbbbb", "bbbbbbbbbbbb", checksum, StateStale},
		{"same prefix wrong full hash", "aaaaaaaaaaaa", "aaaaaaaaaaaa", checksum[:12] + strings.Repeat("b", 52), StateStale},
		{"marker only", "", "aaaaaaaaaaaa", checksum, StateStale},
		{"binary only", "aaaaaaaaaaaa", "", "", StateStale},
		{"legacy binary new marker", ".", "aaaaaaaaaaaa", checksum, StateStale},
		{"new binary legacy marker", "aaaaaaaaaaaa", ".", checksum, StateStale},
		{"other version", "../2.1.292/aaaaaaaaaaaa", "../2.1.292/aaaaaaaaaaaa", checksum, StateMissing},
	} {
		t.Run(test.name, func(t *testing.T) {
			home := t.TempDir()
			root := VersionDir(home, manifest.Version)
			if test.binaryDir != "" {
				writeStatusBinary(t, filepath.Join(root, test.binaryDir))
			}
			if test.markerDir != "" {
				writeStatusMarker(t, filepath.Join(root, test.markerDir), test.marker)
			}
			if got := Status(home, manifest, ArchX64); got.State != test.want {
				t.Fatalf("status = %+v, want %s", got, test.want)
			}
		})
	}
}

func writeStatusBinary(t *testing.T, dir string) {
	t.Helper()
	name := filepath.Join(dir, BundleName, binaryRelativePath)
	data := fakeMachO()
	if runtime.GOOS == "windows" {
		name = filepath.Join(dir, NPMBinaryName)
		data = append([]byte("MZ"), bytes.Repeat([]byte{1}, 126)...)
	}
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, data, 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeStatusMarker(t *testing.T, dir, checksum string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, verifiedName), []byte(checksum), 0o644); err != nil {
		t.Fatal(err)
	}
}
