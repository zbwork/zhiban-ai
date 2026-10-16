package catalog

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// busFixture is a catalog envelope produced by the Bus implementation
// (services/agent-bus/internal/service/localcodingcatalog) with an
// ephemeral key: canonical bytes, signature and public key. It pins the two
// sides to the same canonical form.
type busFixture struct {
	PublicKey string `json:"public_key"`
	Canonical string `json:"canonical"`
	Signed    Signed `json:"signed"`
}

func loadBusFixture(t *testing.T) busFixture {
	t.Helper()
	content, err := os.ReadFile(filepath.Join("testdata", "bus_signed.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fixture busFixture
	if err := json.Unmarshal(content, &fixture); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return fixture
}

func TestCanonicalJSONMatchesBusBytes(t *testing.T) {
	t.Parallel()
	fixture := loadBusFixture(t)
	// The fixture stores the catalog pretty-printed with keys in struct
	// order and non-ASCII text, i.e. not in canonical form.
	if string(fixture.Signed.Catalog) == fixture.Canonical {
		t.Fatalf("fixture catalog is already canonical; the test proves nothing")
	}
	canonical, err := CanonicalJSON(fixture.Signed.Catalog)
	if err != nil {
		t.Fatalf("CanonicalJSON() error = %v", err)
	}
	if string(canonical) != fixture.Canonical {
		t.Fatalf("canonical form differs from Bus:\n got %s\nwant %s", canonical, fixture.Canonical)
	}
	// A re-encoding pass (what the App's JSON library does) must not change it.
	var generic any
	if err := json.Unmarshal(fixture.Signed.Catalog, &generic); err != nil {
		t.Fatalf("decode: %v", err)
	}
	reencoded, _ := json.Marshal(generic)
	again, err := CanonicalJSON(reencoded)
	if err != nil || string(again) != fixture.Canonical {
		t.Fatalf("canonical after re-encoding = %s, %v", again, err)
	}
}

func TestVerifyAcceptsBusSignedCatalog(t *testing.T) {
	t.Parallel()
	fixture := loadBusFixture(t)
	keys := map[string]string{"lc-catalog-fixture": fixture.PublicKey}
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)

	document, err := Verify(keys, fixture.Signed, now, "macos", "arm64")
	if err != nil {
		t.Fatalf("Verify() error = %v", err)
	}
	codex := document.Targets[TargetCodexCLI]
	if codex.Current == nil || codex.Current.Version != "0.154.0" || !codex.Current.Canary || codex.Previous == nil || codex.Previous.Version != "0.153.4" {
		t.Fatalf("codex target = %+v", codex)
	}
	if codex.Current.Sources[0].Size != 87323149 || codex.Current.Sources[0].Host() != "aigc-chat-web.yixin.com" {
		t.Fatalf("codex source = %+v", codex.Current.Sources[0])
	}
	if !strings.Contains(codex.Current.ReleaseNotes, "<html>") {
		t.Fatalf("release notes lost HTML characters: %q", codex.Current.ReleaseNotes)
	}
	if len(document.AllowedHosts) != 2 || document.AllowedHosts[1] != "zhiban-test.oss-cn-beijing.aliyuncs.com" {
		t.Fatalf("allowed hosts = %v", document.AllowedHosts)
	}

	cases := map[string]struct {
		mutate func(*Signed, *map[string]string, *time.Time, *string, *string)
		want   error
	}{
		"unknown kid": {mutate: func(s *Signed, _ *map[string]string, _ *time.Time, _ *string, _ *string) { s.KID = "other" }, want: ErrUnknownKey},
		"no keys":     {mutate: func(_ *Signed, k *map[string]string, _ *time.Time, _ *string, _ *string) { *k = map[string]string{} }, want: ErrUnknownKey},
		"tampered document": {mutate: func(s *Signed, _ *map[string]string, _ *time.Time, _ *string, _ *string) {
			s.Catalog = []byte(strings.Replace(string(s.Catalog), "0.154.0", "0.155.0", 1))
		}, want: ErrBadSignature},
		"bad signature": {mutate: func(s *Signed, _ *map[string]string, _ *time.Time, _ *string, _ *string) { s.Signature = "AAAA" }, want: ErrBadSignature},
		"expired": {mutate: func(_ *Signed, _ *map[string]string, n *time.Time, _ *string, _ *string) {
			*n = time.Date(2040, 1, 1, 0, 0, 0, 0, time.UTC)
		}, want: ErrExpired},
		"other arch":     {mutate: func(_ *Signed, _ *map[string]string, _ *time.Time, _ *string, a *string) { *a = "x64" }, want: ErrMismatch},
		"other platform": {mutate: func(_ *Signed, _ *map[string]string, _ *time.Time, p *string, _ *string) { *p = "windows" }, want: ErrMismatch},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			signed := fixture.Signed
			keys := map[string]string{"lc-catalog-fixture": fixture.PublicKey}
			at, platform, arch := now, "macos", "arm64"
			tc.mutate(&signed, &keys, &at, &platform, &arch)
			if _, err := Verify(keys, signed, at, platform, arch); !errors.Is(err, tc.want) {
				t.Fatalf("Verify() error = %v, want %v", err, tc.want)
			}
		})
	}
}

func signCatalog(t *testing.T, document any) (Signed, string) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	raw, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	canonical, err := CanonicalJSON(raw)
	if err != nil {
		t.Fatalf("CanonicalJSON: %v", err)
	}
	signature := ed25519.Sign(private, canonical)
	return Signed{Catalog: raw, KID: "k1", Signature: base64.RawURLEncoding.EncodeToString(signature)},
		base64.StdEncoding.EncodeToString(public)
}

func validDocument() map[string]any {
	return map[string]any{
		"schema": 1, "issued_at": "2026-09-10T00:00:00Z", "expires_at": "2026-09-17T00:00:00Z",
		"platform": "macos", "arch": "arm64", "allowed_hosts": []string{"dl.example.cn"},
		"targets": map[string]any{
			"claude_cli": map[string]any{
				"current": map[string]any{
					"version": "2.1.270", "layout": "bare_binary",
					"binary_sha256": strings.Repeat("a", 64),
					"sources":       []map[string]any{{"kind": "zhiban_package", "url": "https://dl.example.cn/claude", "size": 10, "sha256": strings.Repeat("a", 64)}},
				},
				"previous": nil,
			},
		},
	}
}

func TestValidateRejectsMalformedDocuments(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	cases := map[string]func(map[string]any){
		"schema":   func(d map[string]any) { d["schema"] = 2 },
		"bad host": func(d map[string]any) { d["allowed_hosts"] = []string{"Bad Host"} },
		"unknown tgt": func(d map[string]any) {
			d["targets"].(map[string]any)["vim"] = d["targets"].(map[string]any)["claude_cli"]
		},
		"no current":    func(d map[string]any) { d["targets"].(map[string]any)["claude_cli"].(map[string]any)["current"] = nil },
		"bad version":   func(d map[string]any) { current(d)["version"] = "2.1" },
		"bad layout":    func(d map[string]any) { current(d)["layout"] = "zip" },
		"member escape": func(d map[string]any) { current(d)["layout"] = "tarball_member"; current(d)["member"] = "../x" },
		"http source": func(d map[string]any) {
			current(d)["sources"].([]map[string]any)[0]["url"] = "http://dl.example.cn/claude"
		},
		"foreign kind": func(d map[string]any) { current(d)["sources"].([]map[string]any)[0]["kind"] = "official" },
		"no sources":   func(d map[string]any) { current(d)["sources"] = []map[string]any{} },
		"same previous": func(d map[string]any) {
			d["targets"].(map[string]any)["claude_cli"].(map[string]any)["previous"] = current(d)
		},
		"window": func(d map[string]any) { d["expires_at"] = "2026-09-09T00:00:00Z" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			document := validDocument()
			mutate(document)
			signed, public := signCatalog(t, document)
			if _, err := Verify(map[string]string{"k1": public}, signed, now, "macos", "arm64"); err == nil {
				t.Fatalf("Verify() accepted %s", name)
			}
		})
	}
	signed, public := signCatalog(t, validDocument())
	if _, err := Verify(map[string]string{"k1": public}, signed, now, "macos", "arm64"); err != nil {
		t.Fatalf("Verify(valid) error = %v", err)
	}
}

// Windows desktop apps come as MSIX packages without macOS bundle facts; the
// catalog carries them and install.catalogAsset ties the layout to Windows.
func TestValidateAcceptsWindowsPackageLayout(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	document := validDocument()
	document["platform"], document["arch"] = "windows", "x64"
	document["targets"] = map[string]any{
		"claude_desktop": map[string]any{
			"current": map[string]any{
				"version": "1.49585.0", "layout": "msix",
				"sources": []map[string]any{{"kind": "zhiban_package", "url": "https://dl.example.cn/Claude-win-x64.msix", "size": 277248271, "sha256": strings.Repeat("b", 64)}},
			},
			"previous": nil,
		},
	}
	signed, public := signCatalog(t, document)
	verified, err := Verify(map[string]string{"k1": public}, signed, now, "windows", "x64")
	if err != nil {
		t.Fatalf("Verify(windows msix) error = %v", err)
	}
	if got := verified.Targets["claude_desktop"].Current.Layout; got != LayoutMSIX {
		t.Fatalf("layout = %q", got)
	}
	// A member makes no sense for a package.
	document["targets"].(map[string]any)["claude_desktop"].(map[string]any)["current"].(map[string]any)["member"] = "x"
	signed, public = signCatalog(t, document)
	if _, err := Verify(map[string]string{"k1": public}, signed, now, "windows", "x64"); err == nil {
		t.Fatal("Verify accepted msix with a member")
	}
}

func current(d map[string]any) map[string]any {
	return d["targets"].(map[string]any)["claude_cli"].(map[string]any)["current"].(map[string]any)
}

func TestCompareVersions(t *testing.T) {
	t.Parallel()
	cases := []struct {
		a, b string
		want int
	}{
		{"0.153.4", "0.154.0", -1}, {"0.154.0", "0.153.4", 1}, {"2.1.263", "2.1.263", 0},
		{"2.1.263", "2.1.1000", -1}, {"26.623.141536", "26.700.1", -1}, {"1.46388.4", "1.46388.10", -1},
		{"1.0", "1.0.0", 0}, {"1.0.1", "1.0", 1}, {"", "1.0.0", -1},
	}
	for _, tc := range cases {
		if got := CompareVersions(tc.a, tc.b); got != tc.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestStoreRoundTrip(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	store := NewStore(filepath.Join(dir, "state", "catalog.json"))
	if _, err := store.Load(); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load() before save error = %v, want ErrNotFound", err)
	}
	signed, _ := signCatalog(t, validDocument())
	record := Record{Environment: EnvironmentTest, KID: signed.KID, Signature: signed.Signature, Catalog: signed.Catalog}
	if err := store.Save(record); err != nil {
		t.Fatalf("Save() error = %v", err)
	}
	info, err := os.Stat(store.Path())
	if err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != 0o600) {
		t.Fatalf("stored file mode = %v, %v", info, err)
	}
	if parent, err := os.Stat(filepath.Dir(store.Path())); err != nil || (runtime.GOOS != "windows" && parent.Mode().Perm() != 0o700) {
		t.Fatalf("state dir mode = %v, %v", parent, err)
	}
	loaded, err := store.Load()
	if err != nil || loaded.Environment != EnvironmentTest || loaded.KID != "k1" || string(loaded.Catalog) != string(signed.Catalog) {
		t.Fatalf("Load() = %+v, %v", loaded, err)
	}
	if err := store.Save(Record{Environment: "staging", Catalog: signed.Catalog}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("Save(bad environment) error = %v", err)
	}
	if err := store.Clear(); err != nil {
		t.Fatalf("Clear() error = %v", err)
	}
	if _, err := store.Load(); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Load() after clear error = %v", err)
	}
	if NewStore("relative/path") != nil || NewStore("") != nil {
		t.Fatalf("NewStore accepted a non-absolute path")
	}
}

func TestPublicKeysPerEnvironment(t *testing.T) {
	t.Parallel()
	if keys := PublicKeys(EnvironmentTest); len(keys) != 1 || keys["lc-catalog-test"] == "" {
		t.Fatalf("test keys = %v", keys)
	}
	// Production trusts exactly its own key: the test key must never verify a
	// production catalog and vice versa.
	if keys := PublicKeys(EnvironmentProd); len(keys) != 1 || keys["lc-catalog-prod"] == "" || keys["lc-catalog-test"] != "" ||
		keys["lc-catalog-prod"] == PublicKeys(EnvironmentTest)["lc-catalog-test"] {
		t.Fatalf("prod keys = %v", keys)
	}
	if PublicKeys("staging") != nil {
		t.Fatalf("unknown environment returned keys")
	}
	keys := PublicKeys(EnvironmentTest)
	keys["lc-catalog-test"] = "tampered"
	if PublicKeys(EnvironmentTest)["lc-catalog-test"] == "tampered" {
		t.Fatalf("PublicKeys returned the shared map")
	}
}
