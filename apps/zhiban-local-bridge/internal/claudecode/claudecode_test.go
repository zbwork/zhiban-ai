package claudecode

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

const literal260 = `{"version":"2.1.260","manifest":{"version":"2.1.260","manifestSignatureEnforcement":"flag","commit":"e51f681183f733dbe9a81bf35921c786ee26dbc6","buildDate":"2026-09-03T19:52:17Z","platforms":{"darwin-arm64":{"binary":"claude.zst","checksum":"90c8e9f337f7461b7582862f35ce22f89ad13b8d529c150f2969e8fa6d3bf020","size":65758751,"bundle":{"checksum":"7639b52c3ff28116f770e198ffb9760f9ecd44632a7c2a0ff0200c4dcf1dd038","size":65759778}},"darwin-x64":{"binary":"claude.zst","checksum":"6f85206e0365f2edbcaff94058802d627d5c48d585d5630cf71e5fe1515f3e00","size":69805574,"bundle":{"checksum":"e81267bb7ff923e2b5d2b61dbe6e0767e2783dd88e306e0a1f308b8477cab96f","size":69807328}},"linux-x64":{"binary":"claude.zst","checksum":"ad1c0b3f2de334f4bcb4a783c275b1af7a5945c0c955a9c7352cf4fa0666a7e0","size":1}},"sdkCompat":{"testedWrapperVersions":["0.3.227"],"harnessSchema":1}},"baseUrl":"https://downloads.claude.ai/claude-code-releases","sdkWrapperVersion":"0.3.260"}`

// asarLike wraps the literal the way the desktop app's minified JS does and
// pads it with unrelated bytes (including a decoy `{"version":"` far away).
func asarLike(literal string) []byte {
	var buffer bytes.Buffer
	buffer.WriteString(`{"files":{"package.json":{"size":1694,"offset":"0"}}}`)
	buffer.Write(bytes.Repeat([]byte{0x00, 0x7f, 'x'}, 4096))
	buffer.WriteString(`function NXe(){return JSON.parse('`)
	buffer.WriteString(literal)
	buffer.WriteString(`')}function PXe(){return JSON.parse('{"version":"4534d8648b686881955c6f13baf46ae72ee72f4c","platforms":{}}')}`)
	buffer.Write(bytes.Repeat([]byte{'y'}, 2048))
	return buffer.Bytes()
}

func TestParseEmbeddedManifestFindsTheDesktopLiteral(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	manifest, err := ParseEmbeddedManifest(asarLike(literal260))
	if err != nil {
		t.Fatalf("ParseEmbeddedManifest() error = %v", err)
	}
	if manifest.Version != "2.1.260" || manifest.BaseURL != AllowedBaseURL || len(manifest.Platforms) != 3 {
		t.Fatalf("manifest = %+v", manifest)
	}
	bundle, ok := manifest.BundleFor(ArchARM64)
	if !ok || bundle.Checksum != "7639b52c3ff28116f770e198ffb9760f9ecd44632a7c2a0ff0200c4dcf1dd038" || bundle.Size != 65759778 {
		t.Fatalf("arm64 bundle = %+v, %v", bundle, ok)
	}
	if manifest.BundleURL(ArchARM64) != "https://downloads.claude.ai/claude-code-releases/2.1.260/darwin-arm64/claude.app.tar.zst" {
		t.Fatalf("BundleURL = %q", manifest.BundleURL(ArchARM64))
	}
	if url := manifest.BundleURL("x64"); !strings.HasSuffix(url, "/2.1.260/darwin-x64/claude.app.tar.zst") {
		t.Fatalf("x64 BundleURL = %q", url)
	}
	if _, ok := manifest.BundleFor("ppc"); ok {
		t.Fatal("unknown arch must have no bundle")
	}
}

func TestParseEmbeddedManifestRejectsUntrustedOrBrokenLiterals(t *testing.T) {
	t.Parallel()
	untrusted := strings.Replace(literal260, AllowedBaseURL, "https://downloads.claude.ai.evil.example/claude-code-releases", 1)
	if _, err := ParseEmbeddedManifest(asarLike(untrusted)); !errors.Is(err, ErrManifestNotFound) {
		// The marker is the exact allowed base URL, so a different base is simply not found.
		t.Fatalf("untrusted base error = %v", err)
	}
	// Same allowed base URL but the literal's version fields disagree.
	mismatch := strings.Replace(literal260, `"manifest":{"version":"2.1.260"`, `"manifest":{"version":"2.1.261"`, 1)
	if _, err := ParseEmbeddedManifest(asarLike(mismatch)); !errors.Is(err, ErrManifestInvalid) {
		t.Fatalf("version mismatch error = %v", err)
	}
	badHash := strings.Replace(literal260, "7639b52c3ff28116f770e198ffb9760f9ecd44632a7c2a0ff0200c4dcf1dd038", "not-a-hash", 1)
	if _, err := ParseEmbeddedManifest(asarLike(badHash)); !errors.Is(err, ErrManifestInvalid) {
		t.Fatalf("bad hash error = %v", err)
	}
	if _, err := ParseEmbeddedManifest([]byte("nothing here")); !errors.Is(err, ErrManifestNotFound) {
		t.Fatalf("missing error = %v", err)
	}
}

func TestDesktopRCManifest(t *testing.T) {
	data, err := os.ReadFile("testdata/desktop-2.9939.4-host.json")
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := ParseEmbeddedManifest(asarLike(strings.TrimSpace(string(data))))
	if err != nil {
		t.Fatal(err)
	}
	base := AllowedBaseURL + "/rc/16cbb4ddeeb473f57fd8d5b713764903d7928e66"
	if manifest.Version != "2.1.284" || manifest.BaseURL != base {
		t.Fatalf("manifest = %+v", manifest)
	}
	for _, arch := range []string{ArchARM64, ArchX64} {
		artifact := manifest.Platforms["darwin-"+arch].Bundle
		if artifact == nil || artifact.Size <= 0 || !sha256Pattern.MatchString(artifact.Checksum) {
			t.Fatalf("missing bundle for %s", arch)
		}
		key, _ := PlatformKey(arch)
		if runtime.GOOS != "windows" && manifest.BundleURL(arch) != base+"/2.1.284/"+key+"/claude.app.tar.zst" {
			t.Fatalf("bundle URL = %s", manifest.BundleURL(arch))
		}
	}
	if runtime.GOOS == "windows" {
		if got := HostArtifactURL(manifest, ArchX64); got != base+"/2.1.284/win32-x64/claude.exe.zst" {
			t.Fatalf("Windows URL = %s", got)
		}
		if _, ok := HostArtifact(manifest, ArchX64); !ok {
			t.Fatal("missing Windows host")
		}
	}
}

func TestRCManifestRejectsUnsafeBases(t *testing.T) {
	data, err := os.ReadFile("testdata/desktop-2.9939.4-host.json")
	if err != nil {
		t.Fatal(err)
	}
	const commit = "16cbb4ddeeb473f57fd8d5b713764903d7928e66"
	base := AllowedBaseURL + "/rc/" + commit
	for _, bad := range []string{
		base + "/extra", base + "/", base + "?x=1", base + "#x",
		AllowedBaseURL + "/rc/" + strings.Repeat("a", 40),
		AllowedBaseURL + "/rc/../" + commit,
		AllowedBaseURL + "/rc/%31" + commit[1:],
		AllowedBaseURL + "/rc/" + strings.ToUpper(commit),
		"https://downloads.claude.ai:443/claude-code-releases/rc/" + commit,
		"https://user@downloads.claude.ai/claude-code-releases/rc/" + commit,
		"https://downloads.claude.ai.evil.example/claude-code-releases/rc/" + commit,
	} {
		t.Run(bad, func(t *testing.T) {
			if _, err := ParseEmbeddedManifest([]byte(strings.ReplaceAll(string(data), base, bad))); err == nil {
				t.Fatal("unsafe base accepted")
			}
		})
	}
	// A trusted inner marker must not hide an untrusted outer download base.
	outerMismatch := strings.ReplaceAll(string(data), `"baseUrl":"`+base+`","sdkWrapperVersion"`, `"baseUrl":"https://evil.example","sdkWrapperVersion"`)
	if _, err := ParseEmbeddedManifest([]byte(outerMismatch)); !errors.Is(err, ErrManifestUntrusted) {
		t.Fatalf("outer mismatch = %v", err)
	}
}

func TestReadEmbeddedManifestFromABundle(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	bundle := filepath.Join(t.TempDir(), "Claude.app")
	if err := os.MkdirAll(filepath.Join(bundle, "Contents", "Resources"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bundle, "Contents", "Resources", "app.asar"), asarLike(literal260), 0o644); err != nil {
		t.Fatal(err)
	}
	manifest, err := ReadEmbeddedManifest(bundle)
	if err != nil || manifest.Version != "2.1.260" {
		t.Fatalf("ReadEmbeddedManifest() = %+v, %v", manifest, err)
	}
	// Second read is served from the cache and must agree.
	again, err := ReadEmbeddedManifest(bundle)
	if err != nil || again.Version != manifest.Version {
		t.Fatalf("cached ReadEmbeddedManifest() = %+v, %v", again, err)
	}
	if _, err := ReadEmbeddedManifest(filepath.Join(t.TempDir(), "Missing.app")); !errors.Is(err, ErrManifestNotFound) {
		t.Fatalf("missing bundle error = %v", err)
	}
}

func fakeMachO() []byte {
	return append([]byte{0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01}, bytes.Repeat([]byte{0x11}, 64)...)
}

func TestStatusReportsPresentMissingAndStale(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	manifest, err := ParseEmbeddedManifest(asarLike(literal260))
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	if got := Status(home, manifest, ArchARM64); got.State != StateMissing || got.Version != "2.1.260" || got.ID != ComponentID {
		t.Fatalf("fresh home status = %+v", got)
	}
	binary := BinaryPath(home, "2.1.260")
	if err := os.MkdirAll(filepath.Dir(binary), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binary, fakeMachO(), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Status(home, manifest, ArchARM64); got.State != StateStale {
		t.Fatalf("binary without marker status = %+v", got)
	}
	if err := os.WriteFile(VerifiedPath(home, "2.1.260"), []byte("7639b52c3ff28116f770e198ffb9760f9ecd44632a7c2a0ff0200c4dcf1dd038"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := Status(home, manifest, ArchARM64); got.State != StatePresent {
		t.Fatalf("complete status = %+v", got)
	}
	if err := os.WriteFile(VerifiedPath(home, "2.1.260"), []byte("e81267bb7ff923e2b5d2b61dbe6e0767e2783dd88e306e0a1f308b8477cab96f\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := Status(home, manifest, ArchARM64); got.State != StateStale {
		t.Fatalf("wrong marker status = %+v", got)
	}
	if err := os.Chmod(binary, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(VerifiedPath(home, "2.1.260"), []byte("7639b52c3ff28116f770e198ffb9760f9ecd44632a7c2a0ff0200c4dcf1dd038"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := Status(home, manifest, ArchARM64); got.State != StateStale {
		t.Fatalf("non-executable binary status = %+v", got)
	}
	if got := Status(home, manifest, "ppc"); got.State != StateUnknown {
		t.Fatalf("unknown arch status = %+v", got)
	}
}

func buildArchive(t *testing.T, members func(w *tar.Writer)) []byte {
	t.Helper()
	var tarBuffer bytes.Buffer
	writer := tar.NewWriter(&tarBuffer)
	members(writer)
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	var zstBuffer bytes.Buffer
	encoder, err := zstd.NewWriter(&zstBuffer)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := encoder.Write(tarBuffer.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := encoder.Close(); err != nil {
		t.Fatal(err)
	}
	return zstBuffer.Bytes()
}

func writeEntry(t *testing.T, w *tar.Writer, name string, mode int64, content []byte) {
	t.Helper()
	header := &tar.Header{Name: name, Mode: mode, Size: int64(len(content)), Typeflag: tar.TypeReg}
	if content == nil {
		header.Typeflag = tar.TypeDir
		header.Size = 0
	}
	if err := w.WriteHeader(header); err != nil {
		t.Fatal(err)
	}
	if content != nil {
		if _, err := w.Write(content); err != nil {
			t.Fatal(err)
		}
	}
}

func TestExtractHostBundleRoundTripsTheRealLayout(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS/POSIX fixture; Windows uses its platform-specific tests")
	}
	t.Parallel()
	archive := buildArchive(t, func(w *tar.Writer) {
		writeEntry(t, w, "claude.app/", 0o755, nil)
		writeEntry(t, w, "claude.app/Contents/", 0o755, nil)
		writeEntry(t, w, "claude.app/Contents/Info.plist", 0o644, []byte("<plist/>"))
		writeEntry(t, w, "claude.app/Contents/_CodeSignature/", 0o755, nil)
		writeEntry(t, w, "claude.app/Contents/_CodeSignature/CodeResources", 0o644, []byte("<seal/>"))
		writeEntry(t, w, "claude.app/Contents/MacOS/", 0o755, nil)
		writeEntry(t, w, "claude.app/Contents/MacOS/claude", 0o755, fakeMachO())
	})
	destination := t.TempDir()
	if err := ExtractHostBundle(context.Background(), bytes.NewReader(archive), destination); err != nil {
		t.Fatalf("ExtractHostBundle() error = %v", err)
	}
	binary := filepath.Join(destination, "claude.app", "Contents", "MacOS", "claude")
	info, err := os.Stat(binary)
	if err != nil || info.Mode().Perm() != 0o755 || info.Size() != int64(len(fakeMachO())) {
		t.Fatalf("binary = %v, %v", info, err)
	}
	plist, err := os.Stat(filepath.Join(destination, "claude.app", "Contents", "Info.plist"))
	if err != nil || plist.Mode().Perm() != 0o644 {
		t.Fatalf("plist = %v, %v", plist, err)
	}
	if !IsExecutableMachO(binary) {
		t.Fatal("extracted binary must pass the Mach-O check")
	}
}

func TestExtractHostBundleRejectsUnsafeArchives(t *testing.T) {
	t.Parallel()
	cases := map[string]func(w *tar.Writer){
		"symlink": func(w *tar.Writer) {
			writeEntry(t, w, "claude.app/", 0o755, nil)
			if err := w.WriteHeader(&tar.Header{Name: "claude.app/Contents", Typeflag: tar.TypeSymlink, Linkname: "/etc", Mode: 0o777}); err != nil {
				t.Fatal(err)
			}
		},
		"parent reference": func(w *tar.Writer) {
			writeEntry(t, w, "claude.app/../escape", 0o644, []byte("x"))
		},
		"absolute path": func(w *tar.Writer) {
			writeEntry(t, w, "/claude.app/Contents/MacOS/claude", 0o755, fakeMachO())
		},
		"foreign top level": func(w *tar.Writer) {
			writeEntry(t, w, "other.app/Contents/MacOS/claude", 0o755, fakeMachO())
		},
		"binary missing": func(w *tar.Writer) {
			writeEntry(t, w, "claude.app/Contents/Info.plist", 0o644, []byte("<plist/>"))
		},
		"binary not mach-o": func(w *tar.Writer) {
			writeEntry(t, w, "claude.app/Contents/MacOS/claude", 0o755, []byte("#!/bin/sh\nexit 3\n"))
		},
	}
	for name, members := range cases {
		archive := buildArchive(t, members)
		if err := ExtractHostBundle(context.Background(), bytes.NewReader(archive), t.TempDir()); !errors.Is(err, ErrArchiveInvalid) {
			t.Fatalf("%s: error = %v, want ErrArchiveInvalid", name, err)
		}
	}
	if err := ExtractHostBundle(context.Background(), bytes.NewReader([]byte("not zstd at all")), t.TempDir()); !errors.Is(err, ErrArchiveInvalid) {
		t.Fatalf("garbage archive error = %v", err)
	}
}

// Real-artifact checks, run only when the developer points at local copies:
//
//	ZHIBAN_CLAUDE_ASAR=/path/to/app.asar ZHIBAN_HOST_ARCHIVE=/path/to/claude.app.tar.zst go test ./internal/claudecode -run Real
func TestRealClaudeDesktopAsarWhenProvided(t *testing.T) {
	path := os.Getenv("ZHIBAN_CLAUDE_ASAR")
	if path == "" {
		t.Skip("ZHIBAN_CLAUDE_ASAR not set")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := ParseEmbeddedManifest(data)
	if err != nil {
		t.Fatalf("ParseEmbeddedManifest(real) error = %v", err)
	}
	bundle, ok := manifest.BundleFor(ArchARM64)
	if !ok || manifest.BaseURL != AllowedBaseURL || manifest.Version == "" || bundle.Size <= 0 {
		t.Fatalf("real manifest = %+v bundle=%+v", manifest, bundle)
	}
	t.Logf("real manifest: version=%s arm64 bundle=%s (%d bytes) x64=%v", manifest.Version, bundle.Checksum, bundle.Size, manifest.Platforms["darwin-x64"].Bundle)
}

func TestRealHostArchiveWhenProvided(t *testing.T) {
	path := os.Getenv("ZHIBAN_HOST_ARCHIVE")
	if path == "" {
		t.Skip("ZHIBAN_HOST_ARCHIVE not set")
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	destination := t.TempDir()
	if err := ExtractHostBundle(context.Background(), file, destination); err != nil {
		t.Fatalf("ExtractHostBundle(real) error = %v", err)
	}
	binary := filepath.Join(destination, BundleName, filepath.FromSlash(binaryRelativePath))
	info, err := os.Stat(binary)
	if err != nil || info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("real binary = %v, %v", info, err)
	}
	t.Logf("real binary: %d bytes mode %v", info.Size(), info.Mode().Perm())
}
