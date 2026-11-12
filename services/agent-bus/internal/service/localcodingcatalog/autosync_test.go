package localcodingcatalog

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	svcclientversion "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientversion"
)

// fakeRegistry is an npm mirror: tag documents, signed per-platform package
// documents and their tarballs, all on one TLS host.
type fakeRegistry struct {
	t      *testing.T
	key    *ecdsa.PrivateKey
	keyID  string
	server *httptest.Server

	mu    sync.Mutex
	docs  map[string][]byte
	blobs map[string][]byte
	// redirects sends a tarball path elsewhere (npmmirror answers 302 to its CDN host).
	redirects map[string]string
}

func newFakeRegistry(t *testing.T) *fakeRegistry {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	r := &fakeRegistry{t: t, key: key, keyID: "SHA256:test-key", docs: map[string][]byte{}, blobs: map[string][]byte{}, redirects: map[string]string{}}
	r.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		r.mu.Lock()
		doc, isDoc := r.docs[req.URL.Path]
		blob, isBlob := r.blobs[req.URL.Path]
		target, isRedirect := r.redirects[req.URL.Path]
		r.mu.Unlock()
		switch {
		case isRedirect:
			http.Redirect(w, req, target, http.StatusFound)
		case isDoc:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(doc)
		case isBlob:
			w.Header().Set("Content-Length", itoa(len(blob)))
			_, _ = w.Write(blob)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(r.server.Close)
	return r
}

func (r *fakeRegistry) keys() map[string]string {
	der, err := x509.MarshalPKIXPublicKey(&r.key.PublicKey)
	if err != nil {
		r.t.Fatal(err)
	}
	return map[string]string{r.keyID: base64.StdEncoding.EncodeToString(der)}
}

// tag publishes the document npm serves at /<package>/<tag>.
func (r *fakeRegistry) tag(pkg, tag, version string, publishedAt time.Time) {
	doc, _ := json.Marshal(map[string]any{"name": pkg, "version": version, "publish_time": publishedAt.UnixMilli()})
	r.mu.Lock()
	r.docs["/"+pkg+"/"+tag] = doc
	r.mu.Unlock()
}

type publishOptions struct {
	badSignature bool
	servedBlob   []byte // when set, the tarball served differs from the signed one
	declaredSize int64  // when set, dist.size lies
	tarballURL   string // when set, dist.tarball is not the canonical address
}

// publish signs and serves one platform package version; it returns the tarball.
func (r *fakeRegistry) publish(name, version string, members map[string][]byte, opts publishOptions) []byte {
	blob := tgz(r.t, members)
	digest := sha512.Sum512(blob)
	integrity := "sha512-" + base64.StdEncoding.EncodeToString(digest[:])
	message := sha256.Sum256([]byte(name + "@" + version + ":" + integrity))
	signature, err := ecdsa.SignASN1(rand.Reader, r.key, message[:])
	if err != nil {
		r.t.Fatal(err)
	}
	if opts.badSignature {
		signature[len(signature)-1] ^= 0xff
	}
	base := name[strings.LastIndex(name, "/")+1:]
	path := "/" + name + "/-/" + base + "-" + version + ".tgz"
	tarball := r.server.URL + path
	if opts.tarballURL != "" {
		tarball = opts.tarballURL
	}
	size := int64(len(blob))
	if opts.declaredSize != 0 {
		size = opts.declaredSize
	}
	doc, _ := json.Marshal(map[string]any{
		"name": name, "version": version,
		"dist": map[string]any{
			"tarball": tarball, "integrity": integrity, "size": size,
			"signatures": []map[string]string{{"keyid": r.keyID, "sig": base64.StdEncoding.EncodeToString(signature)}},
		},
	})
	served := blob
	if opts.servedBlob != nil {
		served = opts.servedBlob
	}
	r.mu.Lock()
	r.docs["/"+name+"/"+version] = doc
	r.blobs[path] = served
	r.mu.Unlock()
	return blob
}

func tgz(t *testing.T, members map[string][]byte) []byte {
	t.Helper()
	var buffer bytes.Buffer
	zipped := gzip.NewWriter(&buffer)
	archive := tar.NewWriter(zipped)
	for name, content := range members {
		if err := archive.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := archive.Write(content); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := zipped.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// publishAll serves Codex <codex> and Claude <claude> for the three platforms
// and returns the expected executable per "<target>/<platform>/<arch>".
func (r *fakeRegistry) publishAll(codex, claude string, codexPublishedAt time.Time) map[string][]byte {
	executables := map[string][]byte{}
	r.tag("@openai/codex", "latest", codex, codexPublishedAt)
	for _, p := range []struct{ key, suffix, triple, exe string }{
		{"codex_cli/macos/arm64", "darwin-arm64", "aarch64-apple-darwin", "codex"},
		{"codex_cli/macos/x64", "darwin-x64", "x86_64-apple-darwin", "codex"},
		{"codex_cli/windows/x64", "win32-x64", "x86_64-pc-windows-msvc", "codex.exe"},
	} {
		exe := []byte("codex " + codex + " " + p.suffix)
		executables[p.key] = exe
		r.publish("@openai/codex", codex+"-"+p.suffix, map[string][]byte{
			"package/package.json":                                  []byte(`{}`),
			"package/vendor/" + p.triple + "/bin/" + p.exe:          exe,
			"package/vendor/" + p.triple + "/bin/codex-other-thing": []byte("host"),
		}, publishOptions{})
	}
	r.tag("@anthropic-ai/claude-code", "stable", claude, time.Now())
	for _, p := range []struct{ key, pkg, exe string }{
		{"claude_cli/macos/arm64", "@anthropic-ai/claude-code-darwin-arm64", "claude"},
		{"claude_cli/macos/x64", "@anthropic-ai/claude-code-darwin-x64", "claude"},
		{"claude_cli/windows/x64", "@anthropic-ai/claude-code-win32-x64", "claude.exe"},
	} {
		exe := []byte("claude " + claude + " " + p.pkg)
		executables[p.key] = exe
		r.publish(p.pkg, claude, map[string][]byte{"package/package.json": []byte(`{}`), "package/" + p.exe: exe}, publishOptions{})
	}
	return executables
}

type autoSyncFixture struct {
	svc      Service
	repo     *fakeRepo
	audit    *fakeAudit
	store    *putStore
	registry *fakeRegistry
}

func newAutoSyncFixture(t *testing.T) *autoSyncFixture {
	t.Helper()
	registry := newFakeRegistry(t)
	repo := newFakeRepo()
	audit := &fakeAudit{}
	store := &putStore{objects: map[string][]byte{}}
	packages := svcclientversion.NewPackageStoreWithResolver(presignResolver{store: store}, svcclientversion.PackageStoreConfig{Prefix: "local-coding/", SignTTL: 10 * time.Minute})
	svc := New(Deps{
		Repo: repo, Audit: audit, Packages: packages, HTTPClient: registry.server.Client(), ExternalBaseURL: "https://bus.example.com",
		AutoSync: &AutoSyncConfig{Registry: registry.server.URL, MinAge: 48 * time.Hour, NPMKeys: registry.keys(), desktopSync: func(context.Context) []AutoSyncResult { return nil }},
	})
	return &autoSyncFixture{svc: svc, repo: repo, audit: audit, store: store, registry: registry}
}

func (f *autoSyncFixture) row(target, platform, arch, version string) *dom.Version {
	for _, v := range f.repo.rows {
		if v.TargetID == target && v.Platform == platform && v.Arch == arch && v.Version == version {
			return v
		}
	}
	return nil
}

func outcomes(report *AutoSyncReport) map[string]string {
	out := map[string]string{}
	for _, r := range report.Results {
		out[r.TargetID+"/"+r.Platform+"/"+r.Arch] = r.Outcome
	}
	return out
}

func TestAutoSyncRecordsVerifiedVersionsAndPublishesCurrent(t *testing.T) {
	ctx := context.Background()
	f := newAutoSyncFixture(t)
	executables := f.registry.publishAll("0.155.1", "2.1.267", time.Now().Add(-72*time.Hour))

	// The running current row of one platform: the new row inherits its gates.
	current := codexInput()
	current.MinBridgeVersion, current.MinAppVersion = "0.5.0", "1.3.0"
	seeded, err := f.svc.Create(ctx, current)
	if err != nil {
		t.Fatal(err)
	}
	withPackage(f.repo, seeded.UUID)
	if _, err := f.svc.Publish(ctx, seeded.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent, ActorID: 7}); err != nil {
		t.Fatal(err)
	}

	report, err := f.svc.AutoSync(ctx)
	if err != nil {
		t.Fatalf("AutoSync: %v", err)
	}
	if len(report.Results) != 6 {
		t.Fatalf("results = %d, want 6: %+v", len(report.Results), report.Results)
	}
	for key, outcome := range outcomes(report) {
		if outcome != AutoSyncPublishedCurrent {
			t.Fatalf("%s outcome = %s, want %s (%+v)", key, outcome, AutoSyncPublishedCurrent, report.Results)
		}
	}

	codex := f.row("codex_cli", "macos", "arm64", "0.155.1")
	if codex == nil {
		t.Fatal("codex macos arm64 row missing")
	}
	if codex.Status != dom.StatusCurrent || len(codex.CanaryTenantIDs) != 0 {
		t.Fatalf("status = %s tenants = %v", codex.Status, codex.CanaryTenantIDs)
	}
	if codex.Layout != dom.LayoutTarballTree || codex.Member != "package/vendor/aarch64-apple-darwin" {
		t.Fatalf("layout/member = %s / %s", codex.Layout, codex.Member)
	}
	if codex.BinarySHA256 != sha256Of(executables["codex_cli/macos/arm64"]) {
		t.Fatalf("binary sha = %s", codex.BinarySHA256)
	}
	if !strings.HasPrefix(codex.StorageURI, "oss://local-coding/"+codex.UUID+"/codex-0.155.1-darwin-arm64.tgz") || codex.MirrorState != dom.MirrorStateDone {
		t.Fatalf("storage = %s mirror = %s", codex.StorageURI, codex.MirrorState)
	}
	stored := f.store.objects[strings.TrimPrefix(codex.StorageURI, "oss://")]
	if codex.SHA256 != sha256Of(stored) || codex.FileSizeBytes != int64(len(stored)) || len(stored) == 0 {
		t.Fatalf("stored object does not match the row: size %d sha %s", codex.FileSizeBytes, codex.SHA256)
	}
	if !dom.IsAutoSyncRef(codex.ContractCheckRef) || !strings.Contains(codex.ContractCheckRef, "未做网关合同检查") {
		t.Fatalf("contract check ref = %q", codex.ContractCheckRef)
	}
	if codex.MinBridgeVersion != "0.5.0" || codex.MinAppVersion != "1.3.0" || codex.ProfileVersion != current.ProfileVersion {
		t.Fatalf("gates not inherited from current: %+v", codex)
	}
	if f.repo.rows[seeded.UUID].Status != dom.StatusPrevious {
		t.Fatalf("the old current must become previous, got %s", f.repo.rows[seeded.UUID].Status)
	}

	claude := f.row("claude_cli", "windows", "x64", "2.1.267")
	if claude == nil || claude.Layout != dom.LayoutTarballMember || claude.Member != "package/claude.exe" ||
		claude.BinarySHA256 != sha256Of(executables["claude_cli/windows/x64"]) || claude.Status != dom.StatusCurrent {
		t.Fatalf("claude windows row = %+v", claude)
	}
	var recorded int
	for _, event := range f.audit.events {
		if event.EventKind == "local_coding.version_autosynced" {
			recorded++
			// Nobody operated the auto sync: the record must not name a user.
			if event.ActorKind != domaudit.ActorSystem || event.AccountID != 0 {
				t.Fatalf("auto sync audit actor = %s / %d", event.ActorKind, event.AccountID)
			}
		}
	}
	if recorded != 6 {
		t.Fatalf("version_autosynced audit events = %d, want 6", recorded)
	}

	// A second round finds everything already recorded and moves no bytes.
	objects := len(f.store.objects)
	again, err := f.svc.AutoSync(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for key, outcome := range outcomes(again) {
		if outcome != AutoSyncSkippedExists {
			t.Fatalf("second round %s outcome = %s", key, outcome)
		}
	}
	if len(f.store.objects) != objects || len(f.repo.rows) != 7 {
		t.Fatalf("second round changed state: objects %d rows %d", len(f.store.objects), len(f.repo.rows))
	}
}

func TestAutoSyncSkipsWhatItMustNotRecord(t *testing.T) {
	ctx := context.Background()
	f := newAutoSyncFixture(t)
	// Codex latest is one day old (< 48 h); Claude stable has no age gate.
	f.registry.publishAll("0.155.1", "2.1.267", time.Now().Add(-24*time.Hour))

	// Claude macOS arm64 already runs a newer version than stable.
	newer := dom.UpsertInput{TargetID: "claude_cli", Platform: "macos", Arch: "arm64", Version: "2.1.270",
		Layout: "tarball_member", Member: "package/claude", BinarySHA256: sha, ContractCheckRef: "manual", ActorID: 7}
	seeded, err := f.svc.Create(ctx, newer)
	if err != nil {
		t.Fatal(err)
	}
	withPackage(f.repo, seeded.UUID)
	if _, err := f.svc.Publish(ctx, seeded.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent, ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	// An operator recorded Claude macOS x64 2.1.267 and then deleted it.
	f.repo.deleted = append(f.repo.deleted, "claude_cli/macos/x64/2.1.267")

	report, err := f.svc.AutoSync(ctx)
	if err != nil {
		t.Fatal(err)
	}
	got := outcomes(report)
	want := map[string]string{
		"codex_cli/macos/arm64":  AutoSyncSkippedTooNew,
		"codex_cli/macos/x64":    AutoSyncSkippedTooNew,
		"codex_cli/windows/x64":  AutoSyncSkippedTooNew,
		"claude_cli/macos/arm64": AutoSyncSkippedNotNewer,
		"claude_cli/macos/x64":   AutoSyncSkippedExists,
		"claude_cli/windows/x64": AutoSyncPublishedCurrent, // no tenant configuration needed
	}
	for key, outcome := range want {
		if got[key] != outcome {
			t.Fatalf("%s outcome = %s, want %s (%+v)", key, got[key], outcome, report.Results)
		}
	}
	draft := f.row("claude_cli", "windows", "x64", "2.1.267")
	if draft == nil || draft.Status != dom.StatusCurrent {
		t.Fatalf("without tenant configuration the row must become current: %+v", draft)
	}
	if f.row("claude_cli", "macos", "x64", "2.1.267") != nil || f.row("codex_cli", "macos", "arm64", "0.155.1") != nil {
		t.Fatal("a skipped version was recorded")
	}
}

func TestAutoSyncRefusesUntrustedPackages(t *testing.T) {
	members := map[string][]byte{"package/claude": []byte("claude")}
	other := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("elsewhere")) }))
	defer other.Close()

	tests := []struct {
		name    string
		prepare func(r *fakeRegistry)
		detail  string
	}{
		{name: "signature does not verify", detail: "签名", prepare: func(r *fakeRegistry) {
			r.publish("@anthropic-ai/claude-code-darwin-arm64", "2.1.267", members, publishOptions{badSignature: true})
		}},
		{name: "tarball changed after signing", detail: "完整性", prepare: func(r *fakeRegistry) {
			signed := tgz(r.t, members)
			r.publish("@anthropic-ai/claude-code-darwin-arm64", "2.1.267", members, publishOptions{servedBlob: bytes.Repeat([]byte("x"), len(signed))})
		}},
		{name: "declared size is wrong", detail: "大小", prepare: func(r *fakeRegistry) {
			r.publish("@anthropic-ai/claude-code-darwin-arm64", "2.1.267", members, publishOptions{declaredSize: 5})
		}},
		{name: "tarball is not the canonical address", detail: "地址", prepare: func(r *fakeRegistry) {
			r.publish("@anthropic-ai/claude-code-darwin-arm64", "2.1.267", members, publishOptions{tarballURL: other.URL + "/claude.tgz"})
		}},
		{name: "download redirects to a host outside the allow list", detail: "下载", prepare: func(r *fakeRegistry) {
			r.publish("@anthropic-ai/claude-code-darwin-arm64", "2.1.267", members, publishOptions{})
			r.redirects["/@anthropic-ai/claude-code-darwin-arm64/-/claude-code-darwin-arm64-2.1.267.tgz"] = other.URL + "/claude.tgz"
		}},
		{name: "executable is not in the package", detail: "可执行文件", prepare: func(r *fakeRegistry) {
			r.publish("@anthropic-ai/claude-code-darwin-arm64", "2.1.267", map[string][]byte{"package/README.md": []byte("x")}, publishOptions{})
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newAutoSyncFixture(t)
			f.registry.tag("@anthropic-ai/claude-code", "stable", "2.1.267", time.Now())
			tt.prepare(f.registry)
			report, err := f.svc.AutoSync(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			var result *AutoSyncResult
			for i := range report.Results {
				if report.Results[i].TargetID == "claude_cli" && report.Results[i].Platform == "macos" && report.Results[i].Arch == "arm64" {
					result = &report.Results[i]
				}
			}
			if result == nil || result.Outcome != AutoSyncFailed || !strings.Contains(result.Detail, tt.detail) {
				t.Fatalf("result = %+v, want failed mentioning %q", result, tt.detail)
			}
			if len(f.repo.rows) != 0 || len(f.store.objects) != 0 {
				t.Fatalf("an untrusted package left state behind: rows %d objects %d", len(f.repo.rows), len(f.store.objects))
			}
		})
	}
}

func TestAutoSyncRefusesPrereleaseTags(t *testing.T) {
	f := newAutoSyncFixture(t)
	f.registry.tag("@openai/codex", "latest", "0.156.0-alpha.9", time.Now().Add(-96*time.Hour))
	report, err := f.svc.AutoSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range report.Results {
		if r.TargetID == "codex_cli" && (r.Outcome != AutoSyncFailed || !strings.Contains(r.Detail, "版本号")) {
			t.Fatalf("prerelease result = %+v", r)
		}
	}
	if len(f.repo.rows) != 0 {
		t.Fatal("a prerelease was recorded")
	}
}

func TestAutoSyncRetiresOnlyItsOwnUnpromotedRows(t *testing.T) {
	ctx := context.Background()
	f := newAutoSyncFixture(t)
	f.registry.publishAll("0.155.1", "2.1.267", time.Now().Add(-72*time.Hour))

	create := func(in dom.UpsertInput, tenants []int64) *dom.Version {
		t.Helper()
		v, err := f.svc.Create(ctx, in)
		if err != nil {
			t.Fatal(err)
		}
		withPackage(f.repo, v.UUID)
		if tenants != nil {
			if _, err := f.svc.Publish(ctx, v.UUID, dom.PublishInput{Mode: dom.PublishModeCanary, TenantIDs: tenants, ActorID: 7}); err != nil {
				t.Fatal(err)
			}
		}
		return v
	}
	// Last week's auto canary that nobody promoted: it holds tenant 581.
	staleAuto := codexInput()
	staleAuto.Version, staleAuto.ContractCheckRef = "0.154.5", dom.AutoSyncRefPrefix+"npm 2026-09-13"
	stale := create(staleAuto, []int64{581})
	// An operator's own canary on another platform, and an operator's draft.
	manualCanary := codexInput()
	manualCanary.Arch, manualCanary.Version = "x64", "0.154.9"
	keptCanary := create(manualCanary, []int64{999})
	manualDraft := codexInput()
	manualDraft.Version = "0.154.7"
	keptDraft := create(manualDraft, nil)

	report, err := f.svc.AutoSync(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got := outcomes(report)["codex_cli/macos/arm64"]; got != AutoSyncPublishedCurrent {
		t.Fatalf("codex macos arm64 outcome = %s (%+v)", got, report.Results)
	}
	if _, ok := f.repo.rows[stale.UUID]; ok {
		t.Fatal("the unpromoted auto canary must be retired")
	}
	var retired bool
	for _, event := range f.audit.events {
		if event.EventKind == "local_coding.version_autosync_retired" && event.ResourceUUID == stale.UUID && event.ActorKind == domaudit.ActorSystem {
			retired = true
		}
	}
	if !retired {
		t.Fatal("retiring a row on its own must be audited as a system action")
	}
	if v := f.repo.rows[keptCanary.UUID]; v == nil || v.Status != dom.StatusCanary {
		t.Fatalf("the operator's canary was touched: %+v", v)
	}
	if v := f.repo.rows[keptDraft.UUID]; v == nil || v.Status != dom.StatusDraft {
		t.Fatalf("the operator's draft was touched: %+v", v)
	}
}

func TestAutoSyncIsOffUnlessConfiguredAndRunsOneRoundAtATime(t *testing.T) {
	ctx := context.Background()
	off := New(Deps{Repo: newFakeRepo()})
	if _, err := off.AutoSync(ctx); !errors.Is(err, dom.ErrAutoSyncDisabled) {
		t.Fatalf("AutoSync without config error = %v", err)
	}
	f := newAutoSyncFixture(t)
	f.repo.syncLocked = true // another process is in the middle of a round
	if _, err := f.svc.AutoSync(ctx); !errors.Is(err, dom.ErrAutoSyncRunning) {
		t.Fatalf("AutoSync while locked error = %v", err)
	}
}

func TestAutoSyncStatusAndBackgroundStart(t *testing.T) {
	ctx := context.Background()
	off := New(Deps{Repo: newFakeRepo()})
	if status := off.AutoSyncStatus(); status.Enabled || status.LastReport != nil {
		t.Fatalf("status without config = %+v", status)
	}
	if err := off.StartAutoSync(ctx); !errors.Is(err, dom.ErrAutoSyncDisabled) {
		t.Fatalf("StartAutoSync without config error = %v", err)
	}

	f := newAutoSyncFixture(t)
	f.registry.publishAll("0.155.1", "2.1.267", time.Now().Add(-72*time.Hour))
	if status := f.svc.AutoSyncStatus(); !status.Enabled || status.Running || status.LastReport != nil {
		t.Fatalf("status before the first round = %+v", status)
	}
	// The operator's request returns at once; the round outlives it.
	requestCtx, cancel := context.WithCancel(ctx)
	if err := f.svc.StartAutoSync(requestCtx); err != nil {
		t.Fatal(err)
	}
	cancel()
	deadline := time.Now().Add(10 * time.Second)
	for {
		status := f.svc.AutoSyncStatus()
		if !status.Running && status.LastReport != nil {
			if len(status.LastReport.Results) != 6 {
				t.Fatalf("last report = %+v", status.LastReport)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("background round did not finish: %+v", status)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if f.row("codex_cli", "macos", "arm64", "0.155.1") == nil {
		t.Fatal("the background round recorded nothing")
	}
}

func TestParseAutoSyncSettings(t *testing.T) {
	cfg, every, err := ParseAutoSyncSettings("", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if every != DefaultAutoSyncInterval || cfg.MinAge != DefaultAutoSyncMinAge || cfg.Registry != DefaultAutoSyncRegistry {
		t.Fatalf("defaults = %+v every %s", cfg, every)
	}
	cfg, every, err = ParseAutoSyncSettings("30m", "72h", "https://registry.example.cn/")
	if err != nil || every != 30*time.Minute || cfg.MinAge != 72*time.Hour {
		t.Fatalf("explicit = %+v every %s err %v", cfg, every, err)
	}
	for name, in := range map[string][3]string{
		"interval too short":     {"1m", "", ""},
		"interval unreadable":    {"often", "", ""},
		"min age not positive":   {"", "0s", ""},
		"registry without https": {"", "", "http://registry.npmmirror.com"},
	} {
		if _, _, err := ParseAutoSyncSettings(in[0], in[1], in[2]); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
}

func TestCLIAutoDraftRetriesAfterStorageReturns(t *testing.T) {
	f := newAutoSyncFixture(t)
	f.registry.publishAll("0.155.1", "2.1.267", time.Now().Add(-72*time.Hour))
	s := f.svc.(*impl)
	store := s.packages
	s.packages = nil
	first, err := s.AutoSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range first.Results {
		if r.Outcome != AutoSyncFailed {
			t.Fatal(r)
		}
	}
	if len(f.repo.rows) != 6 {
		t.Fatalf("rows=%d", len(f.repo.rows))
	}
	s.packages = store
	second, err := s.AutoSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range second.Results {
		if r.Outcome != AutoSyncPublishedCurrent {
			t.Fatal(r)
		}
	}
	if len(f.repo.rows) != 6 || len(f.store.objects) != 6 {
		t.Fatal("failed drafts were not resumed")
	}
}

func TestCLIUploadedLegacyAutoDraftPublishesWithoutDownloadOrUpload(t *testing.T) {
	f := newAutoSyncFixture(t)
	f.registry.publishAll("0.155.1", "2.1.277", time.Now().Add(-72*time.Hour))
	s := f.svc.(*impl)
	repo := &autoPublishFailureRepo{Repository: f.repo, fail: true}
	s.repo = repo
	first, err := s.AutoSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, result := range first.Results {
		if result.Outcome != AutoSyncFailed {
			t.Fatal(result)
		}
	}
	for _, row := range f.repo.rows {
		if row.Status != dom.StatusDraft || !row.IsObjectStorePackage() {
			t.Fatalf("not an uploaded draft: %+v", row)
		}
		row.ContractCheckRef = dom.AutoSyncRefPrefix + "npm legacy automatic draft"
	}
	// The next round must use stored bytes even if upstream downloads and
	// storage writes are unavailable. Tag discovery remains available.
	f.registry.mu.Lock()
	f.registry.blobs = map[string][]byte{}
	f.registry.mu.Unlock()
	f.store.putErr = errors.New("must not upload again")
	repo.fail = false
	second, err := s.AutoSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Results) != 6 {
		t.Fatal(second)
	}
	for _, result := range second.Results {
		if result.Outcome != AutoSyncPublishedCurrent {
			t.Fatal(result)
		}
	}
	for _, row := range f.repo.rows {
		if row.Status != dom.StatusCurrent || len(row.CanaryTenantIDs) != 0 {
			t.Fatalf("not globally published: %+v", row)
		}
	}
	if len(f.repo.rows) != 6 || len(f.store.objects) != 6 {
		t.Fatal("retry created duplicate versions or objects")
	}
}
