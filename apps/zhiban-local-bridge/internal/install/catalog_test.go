package install

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const catalogTestKID = "lc-catalog-unit"

// catalogSigner signs test catalogs with an ephemeral key and hands the
// matching trusted-key table to the manager under test.
type catalogSigner struct {
	private ed25519.PrivateKey
	keys    map[string]string
}

func newCatalogSigner(t *testing.T) *catalogSigner {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	return &catalogSigner{private: private, keys: map[string]string{catalogTestKID: base64.StdEncoding.EncodeToString(public)}}
}

func (c *catalogSigner) sign(t *testing.T, document map[string]any) catalog.Signed {
	t.Helper()
	raw, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("marshal catalog: %v", err)
	}
	canonical, err := catalog.CanonicalJSON(raw)
	if err != nil {
		t.Fatalf("canonical: %v", err)
	}
	return catalog.Signed{Catalog: raw, KID: catalogTestKID, Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(c.private, canonical))}
}

func (c *catalogSigner) trust(f *fixture) {
	f.manager.catalogKeys = func(environment string) map[string]string {
		if environment == catalog.EnvironmentTest {
			return c.keys
		}
		return map[string]string{}
	}
}

func codexScriptFor(version string) []byte {
	return []byte("#!/bin/sh\necho \"codex-cli " + version + "\"\n")
}

// catalogVersion builds a codex_cli catalog entry served by the fixture server.
func catalogVersion(version, url string, archive []byte, script []byte) map[string]any {
	return map[string]any{
		"version": version, "layout": LayoutTarballTree, "member": codexPackagePrefix, "binary_sha256": digestOf(script),
		"release_notes": "notes for " + version,
		"sources":       []map[string]any{{"kind": catalog.SourceKindZhibanPackage, "url": url, "size": len(archive), "sha256": digestOf(archive)}},
	}
}

func catalogDocument(now time.Time, hosts []string, targets map[string]any) map[string]any {
	return map[string]any{
		"schema": catalog.Schema, "issued_at": now.UTC().Format(time.RFC3339), "expires_at": now.Add(7 * 24 * time.Hour).UTC().Format(time.RFC3339),
		"platform": "macos", "arch": ArchARM64, "allowed_hosts": hosts, "targets": targets,
	}
}

// catalogHandler serves the built-in fixture routes plus catalog packages
// under /catalog/, counting hits so tests can prove a download was skipped.
type catalogHandler struct {
	fallback http.Handler
	archives map[string][]byte
	hits     atomic.Int64
}

func (h *catalogHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if archive, ok := h.archives[r.URL.Path]; ok {
		h.hits.Add(1)
		w.Header().Set("Content-Length", itoa(len(archive)))
		_, _ = w.Write(archive)
		return
	}
	h.fallback.ServeHTTP(w, r)
}

func newCatalogFixture(t *testing.T) (*fixture, *catalogHandler, *catalogSigner) {
	t.Helper()
	handler := &catalogHandler{fallback: defaultHandler(t), archives: map[string][]byte{}}
	for _, version := range []string{"0.154.0", "0.155.0"} {
		handler.archives["/catalog/codex-"+version+".tar.gz"] = codexPackageTarball(t, codexScriptFor(version))
	}
	f := newFixture(t, handler, nil)
	signer := newCatalogSigner(t)
	signer.trust(f)
	return f, handler, signer
}

func (f *fixture) codexCatalog(t *testing.T, handler *catalogHandler, signer *catalogSigner, current, previous string) catalog.Signed {
	t.Helper()
	target := map[string]any{
		"current":  catalogVersion(current, f.server.URL+"/catalog/codex-"+current+".tar.gz", handler.archives["/catalog/codex-"+current+".tar.gz"], codexScriptFor(current)),
		"previous": nil,
	}
	if previous != "" {
		archive, ok := handler.archives["/catalog/codex-"+previous+".tar.gz"]
		if !ok {
			// The built-in fixture version: point at the fixture's own tarball.
			archive = codexPackageTarball(t, codexScript())
			target["previous"] = catalogVersion(previous, f.server.URL+"/codex.tar.gz", archive, codexScript())
		} else {
			target["previous"] = catalogVersion(previous, f.server.URL+"/catalog/codex-"+previous+".tar.gz", archive, codexScriptFor(previous))
		}
	}
	return signer.sign(t, catalogDocument(time.Now(), []string{"127.0.0.1"}, map[string]any{TargetCodexCLI: target}))
}

func (f *fixture) apply(t *testing.T, signed catalog.Signed) CatalogStatus {
	t.Helper()
	status, err := f.manager.ApplyCatalog(context.Background(), CatalogApplyInput{Environment: catalog.EnvironmentTest, Signed: signed})
	if err != nil {
		t.Fatalf("ApplyCatalog() error = %v", err)
	}
	return status
}

func (f *fixture) codexLink(t *testing.T) string {
	t.Helper()
	target, err := os.Readlink(filepath.Join(f.home, ".local", "bin", "codex"))
	if err != nil {
		t.Fatalf("Readlink(codex): %v", err)
	}
	return target
}

func (f *fixture) codexPath(version string) string {
	return filepath.Join(f.home, ".codex", "packages", "standalone", version, "bin", "codex")
}

func (f *fixture) availability(t *testing.T, targetID string) Availability {
	t.Helper()
	state, err := f.detector.Detect(context.Background(), targetID)
	if err != nil {
		t.Fatalf("Detect(%s): %v", targetID, err)
	}
	return f.manager.Availability(context.Background(), targetID, state)
}

func TestCatalogUpgradeRollbackAndRetention(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f, handler, signer := newCatalogFixture(t)

	// Fresh install of the built-in version, then apply a catalog whose
	// current is one version ahead and whose previous is the installed one.
	if final := f.runInstall(t, TargetCodexCLI, ModeInstall); final.State != operation.StateSucceeded {
		t.Fatalf("install final = %+v", final)
	}
	if avail := f.availability(t, TargetCodexCLI); avail.UpdateAvailable || avail.AvailableVersion != "" || avail.RollbackVersion != "" {
		t.Fatalf("availability without catalog = %+v", avail)
	}
	status := f.apply(t, f.codexCatalog(t, handler, signer, "0.154.0", testCodexVersion))
	if !status.Applied || status.Targets[TargetCodexCLI].CurrentVersion != "0.154.0" || status.Targets[TargetCodexCLI].PreviousVersion != testCodexVersion {
		t.Fatalf("apply status = %+v", status)
	}
	if requirements, err := f.manager.Requirements(context.Background(), TargetCodexCLI); err != nil || requirements.Version != "0.154.0" {
		t.Fatalf("Requirements() after catalog = %+v, %v", requirements, err)
	}
	avail := f.availability(t, TargetCodexCLI)
	if !avail.UpdateAvailable || avail.AvailableVersion != "0.154.0" || avail.RollbackVersion != "" || avail.ReleaseNotes != "notes for 0.154.0" {
		t.Fatalf("availability with catalog = %+v", avail)
	}
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeRollback); !isCode(err, "LCT-CODEX_CLI-INSTALL-NOT_ROLLBACKABLE") {
		t.Fatalf("Plan(rollback) with nothing older error = %v", err)
	}

	// Upgrade: downloads the catalog package, places it next to the old
	// version and re-points the link.
	plan, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeUpgrade)
	if err != nil || plan.Mode != ModeUpgrade || plan.Version != "0.154.0" || plan.FromVersion != testCodexVersion ||
		plan.Origin != OriginCatalog || plan.Local || plan.DownloadHost != "127.0.0.1" || plan.Source != SourceOfficialOpenAI {
		t.Fatalf("Plan(upgrade) = %+v, %v", plan, err)
	}
	final := f.executePlan(t, plan.PlanID)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("upgrade final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	result := final.Result.(Result)
	if result.ToolState.InstalledVersion != "0.154.0" || result.PreviousVersion != testCodexVersion ||
		len(result.RetainedVersions) != 1 || result.RetainedVersions[0] != testCodexVersion {
		t.Fatalf("upgrade result = %+v", result)
	}
	if f.codexLink(t) != f.codexPath("0.154.0") {
		t.Fatalf("link after upgrade -> %s", f.codexLink(t))
	}
	for _, version := range []string{testCodexVersion, "0.154.0"} {
		if info, err := os.Lstat(f.codexPath(version)); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("version %s missing after upgrade: %v", version, err)
		}
	}
	f.assertNoScratch(t)
	if hits := handler.hits.Load(); hits != 1 {
		t.Fatalf("catalog package downloads = %d, want 1", hits)
	}
	avail = f.availability(t, TargetCodexCLI)
	if avail.UpdateAvailable || avail.AvailableVersion != "" || avail.RollbackVersion != testCodexVersion {
		t.Fatalf("availability after upgrade = %+v", avail)
	}
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeUpgrade); !isCode(err, "LCT-CODEX_CLI-INSTALL-NOT_UPGRADABLE") {
		t.Fatalf("Plan(upgrade) when current error = %v", err)
	}

	// Rollback: the retained version is re-linked without any download.
	plan, err = f.manager.Plan(context.Background(), TargetCodexCLI, ModeRollback)
	if err != nil || plan.Mode != ModeRollback || plan.Version != testCodexVersion || !plan.Local || plan.Origin != OriginLocal ||
		plan.FromVersion != "0.154.0" || plan.DownloadSizeBytes != 0 || plan.DownloadHost != "" {
		t.Fatalf("Plan(rollback) = %+v, %v", plan, err)
	}
	final = f.executePlan(t, plan.PlanID)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("rollback final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	result = final.Result.(Result)
	if result.ToolState.InstalledVersion != testCodexVersion || result.PreviousVersion != "0.154.0" ||
		len(result.RetainedVersions) != 1 || result.RetainedVersions[0] != "0.154.0" {
		t.Fatalf("rollback result = %+v", result)
	}
	if f.codexLink(t) != f.codexPath(testCodexVersion) {
		t.Fatalf("link after rollback -> %s", f.codexLink(t))
	}
	if hits := handler.hits.Load(); hits != 1 {
		t.Fatalf("rollback downloaded something: hits = %d", hits)
	}

	// Re-upgrade reuses the retained 0.154.0 (hash verified) instead of
	// downloading it again.
	plan, err = f.manager.Plan(context.Background(), TargetCodexCLI, ModeUpgrade)
	if err != nil || plan.Version != "0.154.0" || plan.Local {
		t.Fatalf("Plan(re-upgrade) = %+v, %v", plan, err)
	}
	if final = f.executePlan(t, plan.PlanID); final.State != operation.StateSucceeded {
		t.Fatalf("re-upgrade final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if hits := handler.hits.Load(); hits != 1 {
		t.Fatalf("re-upgrade downloaded again: hits = %d", hits)
	}

	// Retention: with three older versions on disk, rolling back keeps the
	// two newest superseded versions and removes the oldest.
	for _, version := range []string{"0.100.0", "0.101.0"} {
		path := f.codexPath(version)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("MkdirAll: %v", err)
		}
		if err := os.WriteFile(path, codexScriptFor(version), 0o755); err != nil {
			t.Fatalf("WriteFile: %v", err)
		}
	}
	if avail = f.availability(t, TargetCodexCLI); avail.RollbackVersion != testCodexVersion {
		t.Fatalf("rollback candidate with extra versions = %+v", avail)
	}
	plan, err = f.manager.Plan(context.Background(), TargetCodexCLI, ModeRollback)
	if err != nil || plan.Version != testCodexVersion || !plan.Local {
		t.Fatalf("Plan(rollback 2) = %+v, %v", plan, err)
	}
	if final = f.executePlan(t, plan.PlanID); final.State != operation.StateSucceeded {
		t.Fatalf("rollback 2 final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	result = final.Result.(Result)
	if strings.Join(result.RetainedVersions, ",") != "0.154.0,0.101.0" {
		t.Fatalf("retained after prune = %v", result.RetainedVersions)
	}
	if _, err := os.Lstat(f.codexPath("0.100.0")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("oldest version not pruned: %v", err)
	}
	if _, err := os.Lstat(filepath.Dir(filepath.Dir(f.codexPath("0.100.0")))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("pruned version directory left behind: %v", err)
	}
	for _, version := range []string{testCodexVersion, "0.154.0", "0.101.0"} {
		if _, err := os.Lstat(f.codexPath(version)); err != nil {
			t.Fatalf("version %s should be retained: %v", version, err)
		}
	}

	// Clearing the catalog reverts fresh installs to the built-in manifest
	// and hides the upgrade.
	if status := f.apply(t, catalog.Signed{}); status.Applied || len(status.Targets) != 0 {
		t.Fatalf("clear status = %+v", status)
	}
	if requirements, _ := f.manager.Requirements(context.Background(), TargetCodexCLI); requirements.Version != testCodexVersion {
		t.Fatalf("Requirements() after clear = %+v", requirements)
	}
	if avail = f.availability(t, TargetCodexCLI); avail.UpdateAvailable || avail.RollbackVersion != "0.101.0" {
		t.Fatalf("availability after clear = %+v", avail)
	}
}

func (f *fixture) executePlan(t *testing.T, planID string) operation.Envelope {
	t.Helper()
	envelope, err := f.manager.Execute(context.Background(), planID)
	if err != nil {
		t.Fatalf("Execute(%s) error = %v", planID, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	final, err := f.registry.Wait(ctx, envelope.OperationID)
	if err != nil {
		t.Fatalf("Wait() error = %v", err)
	}
	return final
}

func TestCatalogFreshInstallUsesCatalogVersionAndPersists(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f, handler, signer := newCatalogFixture(t)
	store := catalog.NewStore(filepath.Join(f.home, "state", "catalog.json"))
	f.manager.catalogStore = store

	signed := f.codexCatalog(t, handler, signer, "0.155.0", "")
	f.apply(t, signed)
	if _, err := os.Stat(store.Path()); err != nil {
		t.Fatalf("catalog not persisted: %v", err)
	}
	plan, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeInstall)
	if err != nil || plan.Version != "0.155.0" || plan.Origin != OriginCatalog {
		t.Fatalf("Plan(install from catalog) = %+v, %v", plan, err)
	}
	if final := f.executePlan(t, plan.PlanID); final.State != operation.StateSucceeded || final.Result.(Result).ToolState.InstalledVersion != "0.155.0" {
		t.Fatalf("install from catalog final = %+v code=%s", final, describeCode(final.ErrorCode))
	}

	// A new Manager on the same home restores and re-verifies the stored
	// catalog with the environment's keys.
	restored, err := NewManager(ManagerConfig{
		HomeDir: f.home, Arch: ArchARM64, Assets: []Asset{f.assets[TargetCodexCLI], f.assets[TargetClaudeCLI]},
		Detect: f.detector.Detect, Operations: operation.NewRegistry(), CatalogStore: store,
		CatalogKeys: f.manager.catalogKeys,
	})
	if err != nil {
		t.Fatalf("NewManager(restored) error = %v", err)
	}
	if asset, ok := restored.assetFor(TargetCodexCLI); !ok || asset.Version != "0.155.0" || !asset.FromCatalog {
		t.Fatalf("restored asset = %+v, %v", asset, ok)
	}
	// Without the key the stored file is dropped, not trusted.
	untrusted, err := NewManager(ManagerConfig{
		HomeDir: f.home, Arch: ArchARM64, Assets: []Asset{f.assets[TargetCodexCLI]},
		Detect: f.detector.Detect, Operations: operation.NewRegistry(), CatalogStore: store,
		CatalogKeys: func(string) map[string]string { return map[string]string{} },
	})
	if err != nil {
		t.Fatalf("NewManager(untrusted) error = %v", err)
	}
	if asset, _ := untrusted.assetFor(TargetCodexCLI); asset.FromCatalog {
		t.Fatalf("untrusted manager used the stored catalog")
	}
	if _, err := os.Stat(store.Path()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unverifiable stored catalog kept: %v", err)
	}
}

// The platform rolled its release back: the catalog's current is now older
// than what this machine installed, so it is offered as the rollback target
// (downloaded, since nothing older is retained locally).
func TestCatalogPlatformRollbackOffersOlderCurrent(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f, handler, signer := newCatalogFixture(t)
	f.apply(t, f.codexCatalog(t, handler, signer, "0.155.0", ""))
	if final := f.runInstall(t, TargetCodexCLI, ModeInstall); final.State != operation.StateSucceeded ||
		final.Result.(Result).ToolState.InstalledVersion != "0.155.0" {
		t.Fatalf("install 0.155.0 final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	// Admin re-published 0.154.0 as current; the withdrawn 0.155.0 is previous.
	f.apply(t, f.codexCatalog(t, handler, signer, "0.154.0", "0.155.0"))
	avail := f.availability(t, TargetCodexCLI)
	if avail.UpdateAvailable || avail.AvailableVersion != "" || avail.RollbackVersion != "0.154.0" {
		t.Fatalf("availability after platform rollback = %+v", avail)
	}
	plan, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeRollback)
	if err != nil || plan.Version != "0.154.0" || plan.Local || plan.Origin != OriginCatalog || plan.FromVersion != "0.155.0" {
		t.Fatalf("Plan(rollback to older current) = %+v, %v", plan, err)
	}
	final := f.executePlan(t, plan.PlanID)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("rollback final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	result := final.Result.(Result)
	if result.ToolState.InstalledVersion != "0.154.0" || result.PreviousVersion != "0.155.0" ||
		strings.Join(result.RetainedVersions, ",") != "0.155.0" {
		t.Fatalf("rollback result = %+v", result)
	}
	if f.codexLink(t) != f.codexPath("0.154.0") {
		t.Fatalf("link after platform rollback -> %s", f.codexLink(t))
	}
	// On the platform's current now: nothing to upgrade to, nothing older to
	// fall back to (the retained 0.155.0 is newer, the catalog previous too).
	if avail = f.availability(t, TargetCodexCLI); avail.UpdateAvailable || avail.RollbackVersion != "" {
		t.Fatalf("availability on rolled-back current = %+v", avail)
	}
}

// The catalog's claude_code_host entry for the exact version the installed
// Claude.app pins is the first host component source, like every catalog
// install: it is used even while the official host is reachable (no speed
// race), and the official host is only the fallback when the catalog copy
// fails. A new host version becomes serviceable by a catalog row alone.
func TestComponentInstallUsesCatalogHostSourceFirst(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	official := fakeHostArchive(t)
	binary := fakeHostMachO()
	tarball := fakeNPMTarball(t, binary)
	var officialHits, catalogHits atomic.Int64
	var catalogDown atomic.Bool
	mux := http.NewServeMux()
	mux.HandleFunc("/claude-desktop.zip", func(w http.ResponseWriter, _ *http.Request) {
		zipped := fakeBundleZip(t)
		w.Header().Set("Content-Length", itoa(len(zipped)))
		_, _ = w.Write(zipped)
	})
	mux.HandleFunc("/host/"+testHostVersion+"/darwin-arm64/claude.app.tar.zst", func(w http.ResponseWriter, _ *http.Request) {
		officialHits.Add(1)
		w.Header().Set("Content-Length", itoa(len(official)))
		_, _ = w.Write(official)
	})
	mux.HandleFunc("/catalog/claude-code-host-"+testHostVersion+".tgz", func(w http.ResponseWriter, _ *http.Request) {
		catalogHits.Add(1)
		if catalogDown.Load() {
			w.WriteHeader(http.StatusGatewayTimeout)
			return
		}
		w.Header().Set("Content-Length", itoa(len(tarball)))
		_, _ = w.Write(tarball)
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
	signer := newCatalogSigner(t)
	signer.trust(f)
	if final := f.runInstall(t, TargetClaudeDesktop, ModeInstall); final.State != operation.StateSucceeded {
		t.Fatalf("install Claude Desktop final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	f.hostManifest = &claudecode.Manifest{
		Version: testHostVersion, BaseURL: f.server.URL + "/host",
		Platforms: map[string]claudecode.Platform{
			"darwin-arm64": {Binary: "claude.zst", Checksum: digestOf([]byte("zstd stream")), Size: 1234,
				Bundle: &claudecode.Artifact{Checksum: digestOf(official), Size: int64(len(official))}},
		},
	}
	// No compiled-in pin for this host version: without the catalog the only
	// source is the official one.
	plan, err := f.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID)
	if err != nil || len(plan.FallbackHosts) != 0 {
		t.Fatalf("PlanComponent() without catalog = %+v, %v", plan, err)
	}

	// The catalog lists the pinned host version (npm layout) plus an entry for
	// another version that must be ignored, and a bundle-layout source whose
	// checksum does not match the manifest (also ignored).
	document := catalogDocument(time.Now(), []string{"127.0.0.1"}, map[string]any{
		catalog.TargetClaudeCodeHost: map[string]any{
			"current": map[string]any{
				"version": testHostVersion, "layout": LayoutHostBinaryNPMTgz, "binary_sha256": digestOf(binary),
				"sources": []map[string]any{
					{"kind": catalog.SourceKindZhibanPackage, "url": f.server.URL + "/catalog/claude-code-host-" + testHostVersion + ".tgz", "size": len(tarball), "sha256": digestOf(tarball)},
				},
			},
			"previous": map[string]any{
				"version": "2.0.1", "layout": LayoutHostBundleTarZst,
				"sources": []map[string]any{
					{"kind": catalog.SourceKindZhibanPackage, "url": f.server.URL + "/catalog/other.tar.zst", "size": 10, "sha256": strings.Repeat("b", 64)},
				},
			},
		},
	})
	f.apply(t, signer.sign(t, document))

	plan, err = f.manager.PlanComponent(context.Background(), TargetClaudeDesktop, claudecode.ComponentID)
	if err != nil || len(plan.FallbackHosts) != 1 || plan.FallbackHosts[0] != "127.0.0.1" || plan.DownloadHost != "127.0.0.1" {
		t.Fatalf("PlanComponent() with catalog = %+v, %v", plan, err)
	}
	final := f.runComponent(t)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("component via catalog final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	// The reachable official host is not even probed.
	if officialHits.Load() != 0 || catalogHits.Load() != 1 {
		t.Fatalf("hits official=%d catalog=%d", officialHits.Load(), catalogHits.Load())
	}
	state, err := f.detector.Detect(context.Background(), TargetClaudeDesktop)
	if err != nil || !componentPresent(state) {
		t.Fatalf("component after catalog provisioning = %+v, %v", state, err)
	}
	// The executable the npm tarball carried is what got placed.
	placed, err := os.ReadFile(filepath.Join(claudecode.StorageDir(f.home), testHostVersion, claudecode.NPMBinaryName))
	if err != nil || digestOf(placed) != digestOf(binary) {
		t.Fatalf("placed executable = %v (hash match %v)", err, err == nil && digestOf(placed) == digestOf(binary))
	}

	// The catalog copy failing falls back to the official host.
	if err := os.RemoveAll(filepath.Join(claudecode.StorageDir(f.home), testHostVersion)); err != nil {
		t.Fatal(err)
	}
	catalogDown.Store(true)
	catalogHits.Store(0)
	final = f.runComponent(t)
	if final.State != operation.StateSucceeded || final.ErrorCode != nil {
		t.Fatalf("component via official fallback final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if officialHits.Load() != 1 || catalogHits.Load() != 1 {
		t.Fatalf("fallback hits official=%d catalog=%d", officialHits.Load(), catalogHits.Load())
	}
	if state, err := f.detector.Detect(context.Background(), TargetClaudeDesktop); err != nil || !componentPresent(state) {
		t.Fatalf("component after official fallback = %+v, %v", state, err)
	}
}

func TestCatalogApplyRejectsBadEnvelopes(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f, handler, signer := newCatalogFixture(t)
	good := f.codexCatalog(t, handler, signer, "0.154.0", "")

	apply := func(environment string, signed catalog.Signed) error {
		_, err := f.manager.ApplyCatalog(context.Background(), CatalogApplyInput{Environment: environment, Signed: signed})
		return err
	}
	if err := apply("staging", good); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("apply(bad environment) error = %v", err)
	}
	if err := apply(catalog.EnvironmentProd, good); !isCode(err, catalogCodeUntrustedKey) {
		t.Fatalf("apply(prod, test key) error = %v", err)
	}
	tampered := good
	tampered.Catalog = []byte(strings.Replace(string(good.Catalog), "0.154.0", "0.156.0", 1))
	if err := apply(catalog.EnvironmentTest, tampered); !isCode(err, catalogCodeInvalid) {
		t.Fatalf("apply(tampered) error = %v", err)
	}
	// A catalog that tries to change the publisher identity of a bundle is
	// rejected even though its signature is valid.
	document := catalogDocument(time.Now(), []string{"127.0.0.1"}, map[string]any{
		TargetClaudeDesktop: map[string]any{
			"current": map[string]any{
				"version": "1.50000.0", "layout": LayoutAppBundleDMG, "bundle_identifier": "com.example.other", "team_identifier": "Q6L2SF6YDW",
				"sources": []map[string]any{{"kind": catalog.SourceKindZhibanPackage, "url": f.server.URL + "/x.dmg", "size": 10, "sha256": strings.Repeat("a", 64)}},
			},
			"previous": nil,
		},
	})
	// The fixture manager knows no desktop asset: a catalog entry for a target
	// the Bridge cannot install on this platform is skipped, not fatal
	// (2026-09-10 Windows: the CLI entries must survive a desktop row).
	skipped, err := f.manager.ApplyCatalog(context.Background(), CatalogApplyInput{Environment: catalog.EnvironmentTest, Signed: signer.sign(t, document)})
	if err != nil || !skipped.Applied || len(skipped.Targets) != 0 {
		t.Fatalf("apply(unknown desktop target) = %+v, %v", skipped, err)
	}
	// A manager that does install Claude Desktop rejects the identity change
	// even though the signature is valid.
	desktopFixture := newFixture(t, defaultHandler(t), func(assets map[string]Asset) {
		assets[TargetClaudeDesktop] = Asset{
			TargetID: TargetClaudeDesktop, Arch: ArchARM64, Version: testDesktopVersion, Source: SourceOfficialAnthropic,
			BundleName: testDesktopBundle, BundleIdentifier: testDesktopID, TeamIdentifier: testDesktopTeam,
			Sources: []Source{{Kind: SourceKindOfficial, URL: "https://downloads.claude.ai/claude-desktop.zip", Size: 10, SHA256: strings.Repeat("b", 64), Layout: LayoutAppBundleZip}},
		}
	})
	signer.trust(desktopFixture)
	if _, err := desktopFixture.manager.ApplyCatalog(context.Background(), CatalogApplyInput{Environment: catalog.EnvironmentTest, Signed: signer.sign(t, document)}); !isCode(err, catalogCodeInvalid) {
		t.Fatalf("apply(publisher change) error = %v", err)
	}
	// A CLI version without a binary hash is rejected too.
	document = catalogDocument(time.Now(), []string{"127.0.0.1"}, map[string]any{
		TargetCodexCLI: map[string]any{
			"current": map[string]any{
				"version": "0.154.0", "layout": LayoutTarballSingle,
				"sources": []map[string]any{{"kind": catalog.SourceKindZhibanPackage, "url": f.server.URL + "/catalog/codex-0.154.0.tar.gz", "size": 10, "sha256": strings.Repeat("a", 64)}},
			},
			"previous": nil,
		},
	})
	if err := apply(catalog.EnvironmentTest, signer.sign(t, document)); !isCode(err, catalogCodeInvalid) {
		t.Fatalf("apply(no binary hash) error = %v", err)
	}
	// Nothing above changed the effective assets.
	if asset, _ := f.manager.assetFor(TargetCodexCLI); asset.FromCatalog {
		t.Fatalf("a rejected catalog was applied")
	}
	// An expired catalog stops applying mid-session.
	f.apply(t, good)
	f.manager.now = func() time.Time { return time.Now().Add(8 * 24 * time.Hour) }
	if asset, _ := f.manager.assetFor(TargetCodexCLI); asset.FromCatalog {
		t.Fatalf("expired catalog still in force")
	}
}

func TestCatalogHostsOnlyApplyToCatalogSources(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f, handler, signer := newCatalogFixture(t)
	// The built-in allow-list no longer knows the fixture server; only the
	// catalog names it.
	f.manager.client.allowedHosts = hostSet([]string{"nowhere.invalid"})
	f.apply(t, f.codexCatalog(t, handler, signer, "0.154.0", ""))

	if final := f.runInstall(t, TargetCodexCLI, ModeInstall); final.State != operation.StateSucceeded || final.Result.(Result).ToolState.InstalledVersion != "0.154.0" {
		t.Fatalf("catalog install with catalog host = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	final := f.runInstall(t, TargetClaudeCLI, ModeInstall)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CLAUDE_CLI-INSTALL-SOURCE_NOT_ALLOWED" {
		t.Fatalf("built-in install on a catalog-only host = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	state, err := f.detector.Detect(context.Background(), TargetClaudeCLI)
	if err != nil || state.UIState != detect.UIStateNotInstalled {
		t.Fatalf("claude state after denied download = %+v, %v", state, err)
	}
}

// TestAdoptTakesOverAnNPMInstall covers 接管安装 (2026-09-16): a copy the user
// installed with npm can neither be upgraded (upgrade needs the publisher's
// standard location) nor installed (install needs nothing installed), so users
// stuck on an old version had no button at all. Adopt puts the catalog version
// in the standard location, re-points the launcher and makes the user's own
// shell resolve it — and refuses if that last part cannot be arranged.
func TestAdoptTakesOverAnNPMInstall(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f, handler, signer := newCatalogFixture(t)

	// The user's own npm copy, 0.130.0, is what the shell resolves.
	npmPath := filepath.Join(f.home, ".npm-global", "lib", "node_modules", "@openai", "codex", "bin", "codex")
	if err := os.MkdirAll(filepath.Dir(npmPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(npmPath, codexScriptFor("0.130.0"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.discoverer.ShellLookup = func(context.Context, string) (string, bool) { return npmPath, true }

	state, err := f.detector.Detect(context.Background(), TargetCodexCLI)
	if err != nil || state.InstalledVersion != "0.130.0" || state.InstallSource != detect.SourceNPM {
		t.Fatalf("detect npm install = %+v, %v", state, err)
	}
	// 升级按钮的依据是 available_version:npm 装的给不出来,所以以前这类用户没有按钮。
	avail := f.manager.Availability(context.Background(), TargetCodexCLI, state)
	if avail.UpdateAvailable || avail.AvailableVersion != "" {
		t.Fatalf("npm install must not look upgradable: %+v", avail)
	}
	f.apply(t, f.codexCatalog(t, handler, signer, "0.154.0", ""))
	if avail = f.availability(t, TargetCodexCLI); avail.AdoptVersion != "0.154.0" {
		t.Fatalf("adopt_version after catalog = %+v", avail)
	}

	// PATH 安排不了就必须失败:否则接着写的配置会让用户终端里的旧 CLI 起不来。
	f.manager.ensureShellResolves = func(context.Context, string, string) error {
		return errors.New("login shell still resolves the npm copy")
	}
	plan, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeAdopt)
	if err != nil || plan.Mode != ModeAdopt || plan.Version != "0.154.0" || plan.FromVersion != "0.130.0" {
		t.Fatalf("Plan(adopt) = %+v, %v", plan, err)
	}
	final := f.executePlan(t, plan.PlanID)
	if final.State != operation.StateFailed || describeCode(final.ErrorCode) != "LCT-CODEX_CLI-INSTALL-PATH_NOT_APPLIED" {
		t.Fatalf("adopt without PATH = %+v code=%s", final, describeCode(final.ErrorCode))
	}

	// PATH 安排好之后:落位 + 换启动器,用户自己的 npm 那份原样留着。
	adopted := f.codexPath("0.154.0")
	f.manager.ensureShellResolves = func(_ context.Context, name, launcherPath string) error {
		if name != "codex" || launcherPath != filepath.Join(f.home, ".local", "bin", "codex") {
			return errors.New("unexpected launcher " + name + " " + launcherPath)
		}
		f.discoverer.ShellLookup = func(context.Context, string) (string, bool) { return launcherPath, true }
		return nil
	}
	plan, err = f.manager.Plan(context.Background(), TargetCodexCLI, ModeAdopt)
	if err != nil {
		t.Fatalf("Plan(adopt) retry error = %v", err)
	}
	if final = f.executePlan(t, plan.PlanID); final.State != operation.StateSucceeded {
		t.Fatalf("adopt final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	result := final.Result.(Result)
	if result.ToolState.InstalledVersion != "0.154.0" || result.ToolState.InstallSource != detect.SourceOfficial ||
		result.PreviousVersion != "0.130.0" {
		t.Fatalf("adopt result = %+v", result)
	}
	if f.codexLink(t) != adopted {
		t.Fatalf("link after adopt -> %s", f.codexLink(t))
	}
	if info, err := os.Lstat(npmPath); err != nil || !info.Mode().IsRegular() {
		t.Fatalf("the user's own copy must be left alone: %v", err)
	}
	// 接管完就归标准位置管:之后是升级,不再是接管。
	if avail = f.availability(t, TargetCodexCLI); avail.AdoptVersion != "" {
		t.Fatalf("adopt_version after adopt = %+v", avail)
	}
	if _, err := f.manager.Plan(context.Background(), TargetCodexCLI, ModeAdopt); !isCode(err, "LCT-CODEX_CLI-INSTALL-NOT_ADOPTABLE") {
		t.Fatalf("Plan(adopt) when already managed error = %v", err)
	}
}

// An install that placed the version and was then cut off (the App's RPC
// timed out during the first Windows adopt, 2026-09-18) leaves the version
// directory without a launcher. The next install must resume from it — no
// download, no "conflict" — and finish the launcher.
func TestInstallResumesFromItsOwnLeftover(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	f, handler, _ := newCatalogFixture(t)
	if final := f.runInstall(t, TargetCodexCLI, ModeInstall); final.State != operation.StateSucceeded {
		t.Fatalf("install final = %+v", final)
	}
	link := filepath.Join(f.home, ".local", "bin", "codex")
	if err := os.Remove(link); err != nil {
		t.Fatalf("remove launcher: %v", err)
	}
	hits := handler.hits.Load()
	final := f.runInstall(t, TargetCodexCLI, ModeInstall)
	if final.State != operation.StateSucceeded {
		t.Fatalf("resumed install final = %+v code=%s", final, describeCode(final.ErrorCode))
	}
	if handler.hits.Load() != hits {
		t.Fatalf("resumed install downloaded again: hits %d -> %d", hits, handler.hits.Load())
	}
	if f.codexLink(t) != f.codexPath(testCodexVersion) {
		t.Fatalf("launcher after resume -> %s", f.codexLink(t))
	}
}
