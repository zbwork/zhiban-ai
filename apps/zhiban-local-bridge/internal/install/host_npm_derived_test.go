package install

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// The real npm document of @anthropic-ai/claude-code-darwin-arm64@2.1.260 as
// npmmirror served it on 2026-09-15 (dist fields only), signed by the npm
// registry key in DefaultNPMRegistryKeys.
const realHostNPMDocument = `{"name":"@anthropic-ai/claude-code-darwin-arm64","version":"2.1.260","dist":{"shasum":"11dbc6d4dfd4b7631328cb8ad588086d4fbf6c07","tarball":"https://registry.npmmirror.com/@anthropic-ai/claude-code-darwin-arm64/-/claude-code-darwin-arm64-2.1.260.tgz","fileCount":4,"integrity":"sha512-rhLCelO/hob3gj5qHEdDTWd+QQzr5JOT10VY86YdRFmLObm4+JSvDDVvkySlpyGThf+2iZDLrGJuSUfnTOwF5w==","signatures":[{"sig":"MEUCIAW5EHFY8ywtaomNNJyGhK3iJ5q9km/6B9Fsny5UdncLAiEAwrOXD8aLyxzc0RckzbSukXJ5MsILPC3YZr2ZP6MvF3U=","keyid":"SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U"}],"unpackedSize":198290017,"size":86819946}}`

func TestVerifyHostNPMDocumentAcceptsTheRealRegistrySignature(t *testing.T) {
	const name = "@anthropic-ai/claude-code-darwin-arm64"
	pin, err := verifyHostNPMDocument([]byte(realHostNPMDocument), DefaultHostNPMRegistry, name, "2.1.260", DefaultNPMRegistryKeys())
	if err != nil {
		t.Fatalf("verifyHostNPMDocument() error = %v", err)
	}
	// Same tarball the Bridge used to pin at build time (86819946 bytes).
	if pin.Source.URL != "https://registry.npmmirror.com/@anthropic-ai/claude-code-darwin-arm64/-/claude-code-darwin-arm64-2.1.260.tgz" ||
		pin.Source.Size != 86819946 {
		t.Fatalf("derived pin source = %+v", pin.Source)
	}
	if !pin.Derived || pin.Validate() != nil || pin.Source.SHA256 != "" || len(pin.Source.SHA512) != 128 {
		t.Fatalf("derived pin = %+v", pin)
	}

	tampered := func(mutate func(map[string]any)) []byte {
		var document map[string]any
		_ = json.Unmarshal([]byte(realHostNPMDocument), &document)
		mutate(document)
		encoded, _ := json.Marshal(document)
		return encoded
	}
	dist := func(document map[string]any) map[string]any { return document["dist"].(map[string]any) }
	cases := map[string][]byte{
		"integrity swapped": tampered(func(d map[string]any) {
			dist(d)["integrity"] = "sha512-" + base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 64))
		}),
		"tarball elsewhere": tampered(func(d map[string]any) {
			dist(d)["tarball"] = "https://evil.example/claude-code-darwin-arm64-2.1.260.tgz"
		}),
		"other version": tampered(func(d map[string]any) { d["version"] = "2.1.261" }),
		"no signature":  tampered(func(d map[string]any) { dist(d)["signatures"] = []any{} }),
	}
	for label, document := range cases {
		if _, err := verifyHostNPMDocument(document, DefaultHostNPMRegistry, name, "2.1.260", DefaultNPMRegistryKeys()); err == nil {
			t.Fatalf("%s: verifyHostNPMDocument() accepted a tampered document", label)
		}
	}
	if _, err := verifyHostNPMDocument([]byte(realHostNPMDocument), DefaultHostNPMRegistry, name, "2.1.260", map[string]string{}); err == nil {
		t.Fatal("a document must not verify without a trusted key")
	}
}

func TestSourceDigestRulesForDerivedHostTarballs(t *testing.T) {
	sha512Hex := strings.Repeat("ab", 64)
	derived := Source{Kind: SourceKindNPMMirror, Layout: LayoutHostBinaryNPMTgz, URL: "https://registry.npmmirror.com/x.tgz", Size: 1, SHA512: sha512Hex}
	if err := derived.Validate(); err != nil {
		t.Fatalf("derived host tarball source rejected: %v", err)
	}
	for label, source := range map[string]Source{
		"sha512 on a CLI tarball": {Kind: SourceKindNPMMirror, Layout: LayoutTarballMember, Member: "package/bin/codex", URL: "https://registry.npmmirror.com/x.tgz", Size: 1, SHA512: sha512Hex},
		"sha512 from the catalog": {Kind: SourceKindZhibanPackage, Layout: LayoutHostBinaryNPMTgz, URL: "https://s3.example/x.tgz", Size: 1, SHA512: sha512Hex},
		"no digest at all":        {Kind: SourceKindNPMMirror, Layout: LayoutHostBinaryNPMTgz, URL: "https://registry.npmmirror.com/x.tgz", Size: 1},
		"malformed sha512":        {Kind: SourceKindNPMMirror, Layout: LayoutHostBinaryNPMTgz, URL: "https://registry.npmmirror.com/x.tgz", Size: 1, SHA512: "abc"},
	} {
		if source.Validate() == nil {
			t.Fatalf("%s: Validate() accepted %+v", label, source)
		}
	}
}

var (
	testNPMKeyOnce sync.Once
	testNPMKey     *ecdsa.PrivateKey
)

const testNPMKeyID = "SHA256:test-npm-registry-key"

func testNPMPrivateKey() *ecdsa.PrivateKey {
	testNPMKeyOnce.Do(func() {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			panic(err)
		}
		testNPMKey = key
	})
	return testNPMKey
}

func testNPMPublicKey() string {
	der, err := x509.MarshalPKIXPublicKey(&testNPMPrivateKey().PublicKey)
	if err != nil {
		panic(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

// signedNPMDocument builds a package document for tarball, signed like the
// npm registry signs (ECDSA over "<name>@<version>:<integrity>").
func signedNPMDocument(t *testing.T, registry, name, version string, tarball []byte) []byte {
	t.Helper()
	sum := sha512.Sum512(tarball)
	integrity := "sha512-" + base64.StdEncoding.EncodeToString(sum[:])
	message := sha256.Sum256([]byte(name + "@" + version + ":" + integrity))
	signature, err := ecdsa.SignASN1(rand.Reader, testNPMPrivateKey(), message[:])
	if err != nil {
		t.Fatal(err)
	}
	document, err := json.Marshal(map[string]any{
		"name": name, "version": version,
		"dist": map[string]any{
			"tarball": hostNPMTarballURL(registry, name, version), "integrity": integrity, "size": len(tarball),
			"signatures": []any{map[string]any{"keyid": testNPMKeyID, "sig": base64.StdEncoding.EncodeToString(signature)}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return document
}

// Claude Desktop pins a host version the Bridge has no pin or catalog row
// for: the tarball is derived from the registry-signed document, checked by
// sha512, signature and --version, and placed like a pinned one.
func TestComponentInstallDerivesUnpinnedHostFromSignedNPMDocument(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	const unpinned = "2.1.299"
	const name = "@anthropic-ai/claude-code-darwin-arm64"
	official := fakeHostArchive(t)
	binary := fakeHostMachO()
	tarball := fakeNPMTarball(t, binary)
	served := tarball // what the tarball URL returns; the document always signs tarball
	var npmHits atomic.Int32
	mux := http.NewServeMux()
	var registry string
	mux.HandleFunc("/claude-desktop.zip", func(w http.ResponseWriter, _ *http.Request) {
		zipped := fakeBundleZip(t)
		w.Header().Set("Content-Length", itoa(len(zipped)))
		_, _ = w.Write(zipped)
	})
	mux.HandleFunc("/host/"+unpinned+"/darwin-arm64/claude.app.tar.zst", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusGatewayTimeout) // downloads.claude.ai stand-in: unreachable
	})
	mux.HandleFunc("/npmreg/"+name+"/"+unpinned, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(signedNPMDocument(t, registry, name, unpinned, tarball))
	})
	mux.HandleFunc("/npmreg/"+name+"/-/claude-code-darwin-arm64-"+unpinned+".tgz", func(w http.ResponseWriter, _ *http.Request) {
		npmHits.Add(1)
		w.Header().Set("Content-Length", itoa(len(served)))
		_, _ = w.Write(served)
	})
	zipped := fakeBundleZip(t)
	f := newFixture(t, mux, func(assets map[string]Asset) {
		base := strings.TrimSuffix(assets[TargetCodexCLI].Sources[0].URL, "/codex.tar.gz")
		assets[TargetClaudeDesktop] = Asset{
			TargetID: TargetClaudeDesktop, Arch: ArchARM64, Version: testDesktopVersion, Source: SourceOfficialAnthropic,
			BundleName: testDesktopBundle, BundleIdentifier: testDesktopID, TeamIdentifier: testDesktopTeam,
			Sources: []Source{{Kind: SourceKindOfficial, URL: base + "/claude-desktop.zip", Size: int64(len(zipped)), SHA256: digestOf(zipped), Layout: LayoutAppBundleZip}},
		}
	})
	registry = f.server.URL + "/npmreg"
	if final := f.runInstall(t, TargetClaudeDesktop, ModeInstall); final.State != operation.StateSucceeded {
		t.Fatalf("install Claude Desktop final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	f.hostManifest = &claudecode.Manifest{
		Version: unpinned, BaseURL: f.server.URL + "/host",
		Platforms: map[string]claudecode.Platform{
			"darwin-arm64": {Binary: "claude.zst", Checksum: digestOf([]byte("zstd stream")), Size: 1234,
				Bundle: &claudecode.Artifact{Checksum: digestOf(official), Size: int64(len(official))}},
		},
	}
	var checked atomic.Value
	f.hostVersion = func(executable string) (string, error) {
		checked.Store(executable)
		return unpinned + " (Claude Code)", nil
	}

	final := runComponentVersion(t, f, unpinned)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("component via derived npm final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if npmHits.Load() == 0 {
		t.Fatal("derived npm tarball was never downloaded")
	}
	if path, _ := checked.Load().(string); filepath.Base(path) != claudecode.NPMBinaryName {
		t.Fatalf("--version was not checked on the staged executable: %q", path)
	}
	content, err := os.ReadFile(claudecode.BinaryPath(f.home, unpinned))
	if err != nil || !bytes.Equal(content, binary) {
		t.Fatalf("placed host binary = %d bytes, %v", len(content), err)
	}
	marker, err := os.ReadFile(claudecode.VerifiedPath(f.home, unpinned))
	if err != nil || string(marker) != digestOf(official) {
		t.Fatalf(".verified = %q, %v", marker, err)
	}
	// npm layout (formerly covered by the build-time pin test): the executable
	// is the flat <version>/claude, the bundle entry a relative symlink to it
	// (a real file there is killed at exec), and nothing is left in staging.
	placed := claudecode.BinaryPath(f.home, unpinned)
	if info, err := os.Lstat(placed); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("bundle entry must be a symlink: %v, %v", info, err)
	}
	flat := filepath.Join(claudecode.VersionDir(f.home, unpinned), claudecode.NPMBinaryName)
	if info, err := os.Lstat(flat); err != nil || !info.Mode().IsRegular() || info.Size() != int64(len(binary)) || !claudecode.IsExecutableMachO(flat) {
		t.Fatalf("flat executable = %v, %v", info, err)
	}
	if hidden := hiddenEntries(t, claudecode.StorageDir(f.home)); len(hidden) != 0 {
		t.Fatalf("staging left behind: %v", hidden)
	}
	f.assertNoScratch(t)

	// A signed executable reporting another version is refused and nothing
	// is placed.
	if err := os.RemoveAll(claudecode.VersionDir(f.home, unpinned)); err != nil {
		t.Fatal(err)
	}
	f.hostVersion = func(string) (string, error) { return "2.1.260 (Claude Code)", nil }
	if final := runComponentVersion(t, f, unpinned); envelopeCode(final.ErrorCode) != "LCT-CLAUDE_DESKTOP-INSTALL-PUBLISHER_MISMATCH" {
		t.Fatalf("wrong reported version final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if _, err := os.Lstat(claudecode.VersionDir(f.home, unpinned)); err == nil {
		t.Fatal("nothing may be placed when the executable reports another version")
	}

	// A tarball that does not match the signed integrity is refused.
	f.hostVersion = func(string) (string, error) { return unpinned, nil }
	served = fakeNPMTarball(t, append(append([]byte(nil), binary...), 0))
	if final := runComponentVersion(t, f, unpinned); final.State == operation.StateSucceeded {
		t.Fatalf("tarball not matching the signed integrity was accepted: %+v", final)
	}
	if _, err := os.Lstat(claudecode.VersionDir(f.home, unpinned)); err == nil {
		t.Fatal("nothing may be placed when the tarball does not match the signed integrity")
	}
}

// runComponentVersion plans and runs the host component like
// fixture.runComponent, for a host version other than testHostVersion.
func runComponentVersion(t *testing.T, f *fixture, version string) operation.Envelope {
	t.Helper()
	plan, err := f.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID)
	if err != nil {
		t.Fatalf("PlanComponent() error = %v", err)
	}
	if plan.Mode != ModeComponent || plan.Version != version || plan.DownloadHost != "127.0.0.1" {
		t.Fatalf("component plan = %+v", plan)
	}
	envelope, err := f.manager.Execute(context.Background(), plan.PlanID)
	if err != nil {
		t.Fatalf("Execute(component) error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	final, err := f.registry.Wait(ctx, envelope.OperationID)
	if err != nil {
		t.Fatalf("Wait() error = %v", err)
	}
	return final
}
