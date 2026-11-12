package localcodingcatalog

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ---------------------------------------------------------------- fakes

type fakeRepo struct {
	rows   map[string]*dom.Version
	nextID int64
	// deleted keeps "<target>/<platform>/<arch>/<version>" of removed rows
	// (the real table soft-deletes); syncLocked simulates another process
	// holding the auto sync lock.
	deleted    []string
	syncLocked bool
}

func newFakeRepo() *fakeRepo { return &fakeRepo{rows: map[string]*dom.Version{}} }

func (r *fakeRepo) List(context.Context, dom.Filter) ([]dom.Version, int64, error) {
	out := []dom.Version{}
	for _, v := range r.rows {
		out = append(out, *v)
	}
	return out, int64(len(out)), nil
}

func (r *fakeRepo) GetByUUID(_ context.Context, uuid string) (*dom.Version, error) {
	v, ok := r.rows[uuid]
	if !ok {
		return nil, apperr.ErrNotFound.Withf("nf")
	}
	c := *v
	return &c, nil
}

func (r *fakeRepo) Create(_ context.Context, in dom.UpsertInput) (*dom.Version, error) {
	for _, v := range r.rows {
		if v.TargetID == in.TargetID && v.Platform == in.Platform && v.Arch == in.Arch && v.Version == in.Version {
			return nil, dom.ErrDuplicateVersion
		}
	}
	r.nextID++
	v := &dom.Version{
		ID: r.nextID, UUID: fmt.Sprintf("uuid-%d", r.nextID), TargetID: in.TargetID, Platform: in.Platform,
		Arch: in.Arch, Version: in.Version, Layout: in.Layout, Member: in.Member, BinarySHA256: in.BinarySHA256,
		BundleIdentifier: in.BundleIdentifier, TeamIdentifier: in.TeamIdentifier, ProfileVersion: in.ProfileVersion,
		MinBridgeVersion: in.MinBridgeVersion, MinAppVersion: in.MinAppVersion,
		ContractCheckRef: in.ContractCheckRef, ReleaseNotes: in.ReleaseNotes, Status: dom.StatusDraft,
		CanaryTenantIDs: []int64{}, CreatedAt: time.Now(), UpdatedAt: time.Now(),
		AutoSynced: dom.IsAutoSyncRef(in.ContractCheckRef),
	}
	if in.ExternalURL != "" {
		v.StorageURI, v.FileSizeBytes, v.SHA256 = in.ExternalURL, in.FileSizeBytes, in.SHA256
	}
	r.rows[v.UUID] = v
	c := *v
	return &c, nil
}

func (r *fakeRepo) Update(_ context.Context, uuid string, in dom.UpsertInput) (*dom.Version, error) {
	v, ok := r.rows[uuid]
	if !ok {
		return nil, apperr.ErrNotFound.Withf("nf")
	}
	if v.Status != dom.StatusDraft {
		return nil, dom.ErrNotDraft
	}
	v.ReleaseNotes, v.ContractCheckRef, v.BinarySHA256 = in.ReleaseNotes, in.ContractCheckRef, in.BinarySHA256
	c := *v
	return &c, nil
}

func (r *fakeRepo) SetPackage(_ context.Context, uuid string, in dom.PackageInput) (*dom.Version, error) {
	v := r.rows[uuid]
	v.StorageURI, v.FileSizeBytes, v.SHA256 = in.StorageURI, in.FileSizeBytes, in.SHA256
	v.ShareCode, v.ShareURL, v.ShareExpiresAt = "", "", nil
	c := *v
	return &c, nil
}

func (r *fakeRepo) ListShareRefreshCandidates(_ context.Context, before time.Time, limit int) ([]dom.Version, error) {
	out := []dom.Version{}
	for _, v := range r.rows {
		if !v.IsPublished() || !v.IsObjectStorePackage() {
			continue
		}
		if v.ShareURL == "" || v.ShareExpiresAt == nil || v.ShareExpiresAt.Before(before) {
			out = append(out, *v)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (r *fakeRepo) SetShareLink(_ context.Context, uuid string, in dom.ShareLinkInput) error {
	v, ok := r.rows[uuid]
	if !ok {
		return apperr.ErrNotFound
	}
	expires := in.ExpiresAt
	v.ShareCode, v.ShareURL, v.ShareExpiresAt = in.Code, in.URL, &expires
	return nil
}

func (r *fakeRepo) SetMirrorState(_ context.Context, uuid, state, message string) error {
	v, ok := r.rows[uuid]
	if !ok {
		return apperr.ErrNotFound
	}
	v.MirrorState, v.MirrorError = state, message
	return nil
}

func (r *fakeRepo) ResetRunningMirrors(_ context.Context, message string) (int64, error) {
	var n int64
	for _, v := range r.rows {
		if v.MirrorState == dom.MirrorStateRunning {
			v.MirrorState, v.MirrorError = dom.MirrorStateFailed, message
			n++
		}
	}
	return n, nil
}

func (r *fakeRepo) ReplaceStorage(_ context.Context, uuid, storageURI string, sizeBytes int64, sha256 string, _ int64) (*dom.Version, error) {
	v, ok := r.rows[uuid]
	if !ok {
		return nil, apperr.ErrNotFound
	}
	if v.FileSizeBytes != sizeBytes || v.SHA256 != sha256 {
		return nil, dom.ErrMirrorMismatch
	}
	v.StorageURI, v.MirrorState, v.MirrorError = storageURI, dom.MirrorStateDone, ""
	v.ShareCode, v.ShareURL, v.ShareExpiresAt = "", "", nil
	c := *v
	return &c, nil
}

func (r *fakeRepo) Publish(_ context.Context, uuid string, in dom.PublishInput) (*dom.Version, error) {
	v, ok := r.rows[uuid]
	if !ok {
		return nil, apperr.ErrNotFound.Withf("nf")
	}
	switch in.Mode {
	case dom.PublishModeCanary:
		for _, o := range r.rows {
			if o.UUID != uuid && o.Status == dom.StatusCanary && sameKey(o, v) && overlap(o.CanaryTenantIDs, in.TenantIDs) {
				return nil, dom.ErrCanaryTenantOverlap
			}
		}
		v.Status, v.CanaryTenantIDs = dom.StatusCanary, in.TenantIDs
	case dom.PublishModeCurrent:
		for _, o := range r.rows {
			if o.UUID == uuid || !sameKey(o, v) {
				continue
			}
			if o.Status == dom.StatusPrevious {
				o.Status = dom.StatusDeprecated
			}
		}
		for _, o := range r.rows {
			if o.UUID != uuid && sameKey(o, v) && o.Status == dom.StatusCurrent {
				o.Status = dom.StatusPrevious
			}
		}
		v.Status, v.CanaryTenantIDs = dom.StatusCurrent, []int64{}
	default:
		return nil, dom.ErrInvalidPublishMode
	}
	now := time.Now()
	v.PublishedAt = &now
	c := *v
	return &c, nil
}

func (r *fakeRepo) Deprecate(_ context.Context, uuid string, _ int64) (*dom.Version, error) {
	v := r.rows[uuid]
	v.Status = dom.StatusDeprecated
	c := *v
	return &c, nil
}

func (r *fakeRepo) Delete(_ context.Context, uuid string, _ int64) error {
	if v, ok := r.rows[uuid]; ok {
		r.deleted = append(r.deleted, versionKey(v.TargetID, v.Platform, v.Arch, v.Version))
	}
	delete(r.rows, uuid)
	return nil
}

func versionKey(targetID, platform, arch, version string) string {
	return targetID + "/" + platform + "/" + arch + "/" + version
}

func (r *fakeRepo) VersionEverRecorded(_ context.Context, targetID, platform, arch, version string) (bool, error) {
	key := versionKey(targetID, platform, arch, version)
	for _, v := range r.rows {
		if versionKey(v.TargetID, v.Platform, v.Arch, v.Version) == key {
			return true, nil
		}
	}
	for _, deleted := range r.deleted {
		if deleted == key {
			return true, nil
		}
	}
	return false, nil
}

func (r *fakeRepo) TryAutoSyncLock(context.Context) (func(), bool, error) {
	if r.syncLocked {
		return nil, false, nil
	}
	r.syncLocked = true
	return func() { r.syncLocked = false }, true, nil
}

func (r *fakeRepo) ListActive(_ context.Context, platform, arch string) ([]dom.Version, error) {
	out := []dom.Version{}
	for _, v := range r.rows {
		if v.Platform != platform || (v.Arch != arch && v.Arch != dom.ArchUniversal) {
			continue
		}
		switch v.Status {
		case dom.StatusCanary, dom.StatusCurrent, dom.StatusPrevious:
			out = append(out, *v)
		}
	}
	return out, nil
}

func sameKey(a, b *dom.Version) bool {
	return a.TargetID == b.TargetID && a.Platform == b.Platform && a.Arch == b.Arch
}

func overlap(a, b []int64) bool {
	for _, x := range a {
		for _, y := range b {
			if x == y {
				return true
			}
		}
	}
	return false
}

type fakeAudit struct{ events []domaudit.Event }

func (f *fakeAudit) Insert(_ context.Context, e domaudit.Event) error {
	f.events = append(f.events, e)
	return nil
}

func (f *fakeAudit) InsertMany(_ context.Context, es []domaudit.Event) error {
	f.events = append(f.events, es...)
	return nil
}

// ---------------------------------------------------------------- helpers

const sha = "8cf911ea676523bfb2121ec561848d2aba564890ad536db4d8a3353f2b9850b1"

func newTestSigner(t *testing.T) (*Signer, string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := NewSignerFromBase64(base64.StdEncoding.EncodeToString(priv.Seed()), "test-kid")
	if err != nil {
		t.Fatal(err)
	}
	return signer, base64.StdEncoding.EncodeToString(pub)
}

func codexInput() dom.UpsertInput {
	return dom.UpsertInput{
		TargetID: "codex_cli", Platform: "macos", Arch: "arm64", Version: "0.154.0",
		Layout: "tarball_single", BinarySHA256: sha, ProfileVersion: "2026.09.07.1",
		ContractCheckRef: "checker run 2026-09-10", ActorID: 7,
	}
}

func withPackage(repo *fakeRepo, uuid string) {
	repo.rows[uuid].StorageURI = "oss://local-coding/" + uuid + "/codex.tar.gz"
	repo.rows[uuid].FileSizeBytes = 87323149
	repo.rows[uuid].SHA256 = sha
}

// ---------------------------------------------------------------- tests

func TestCreateValidatesAndDefaultsDesktopIdentity(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	svc := New(Deps{Repo: repo})

	if _, err := svc.Create(ctx, dom.UpsertInput{TargetID: "nope", Platform: "macos", Arch: "arm64", Version: "1", Layout: "bare_binary"}); !errors.Is(err, dom.ErrInvalidTarget) {
		t.Fatalf("invalid target: %v", err)
	}
	if _, err := svc.Create(ctx, dom.UpsertInput{TargetID: "codex_cli", Platform: "macos", Arch: "arm64", Version: "1", Layout: "tarball_member"}); !errors.Is(err, dom.ErrMissingMember) {
		t.Fatalf("member required: %v", err)
	}
	if _, err := svc.Create(ctx, dom.UpsertInput{TargetID: "codex_cli", Platform: "macos", Arch: "arm64", Version: "1", Layout: "bare_binary", BinarySHA256: "zz"}); !errors.Is(err, dom.ErrInvalidSHA256) {
		t.Fatalf("sha format: %v", err)
	}
	desktop, err := svc.Create(ctx, dom.UpsertInput{TargetID: " Claude_Desktop ", Platform: "MACOS", Arch: "universal", Version: "1.46388.4", Layout: "app_bundle_zip"})
	if err != nil {
		t.Fatal(err)
	}
	if desktop.BundleIdentifier != claudeDesktopBundleID || desktop.TeamIdentifier != claudeDesktopTeamID || desktop.TargetID != "claude_desktop" {
		t.Fatalf("desktop defaults not applied: %+v", desktop)
	}
	if _, err := svc.Create(ctx, dom.UpsertInput{TargetID: "claude_desktop", Platform: "macos", Arch: "universal", Version: "1.46388.4", Layout: "app_bundle_zip"}); !errors.Is(err, dom.ErrDuplicateVersion) {
		t.Fatalf("duplicate: %v", err)
	}

	// Windows desktop apps ship as MSIX and carry no macOS bundle identity:
	// the Bridge takes package identity and signer from its built-in asset.
	msix, err := svc.Create(ctx, dom.UpsertInput{TargetID: "claude_desktop", Platform: "windows", Arch: "x64", Version: "1.49585.0", Layout: "msix", BundleIdentifier: "com.anthropic.claudefordesktop"})
	if err != nil {
		t.Fatal(err)
	}
	if msix.BundleIdentifier != "" || msix.TeamIdentifier != "" || msix.Layout != dom.LayoutMSIX {
		t.Fatalf("windows desktop row: %+v", msix)
	}
	for name, in := range map[string]dom.UpsertInput{
		"msix on macos":            {TargetID: "claude_desktop", Platform: "macos", Arch: "universal", Version: "1.49585.0", Layout: "msix"},
		"windows desktop not msix": {TargetID: "codex_desktop", Platform: "windows", Arch: "x64", Version: "26.903.8094", Layout: "app_bundle_zip"},
		"msix for a cli":           {TargetID: "claude_cli", Platform: "windows", Arch: "x64", Version: "2.1.267", Layout: "msix"},
		"tree for claude":          {TargetID: "claude_cli", Platform: "macos", Arch: "arm64", Version: "2.1.267", Layout: "tarball_tree", Member: "package"},
	} {
		if _, err := svc.Create(ctx, in); !errors.Is(err, dom.ErrInvalidLayout) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if _, err := svc.Create(ctx, dom.UpsertInput{TargetID: "codex_cli", Platform: "windows", Arch: "x64", Version: "0.155.0", Layout: "tarball_tree"}); !errors.Is(err, dom.ErrMissingMember) {
		t.Fatalf("tree member required: %v", err)
	}
	if _, err := svc.Create(ctx, dom.UpsertInput{TargetID: "codex_cli", Platform: "windows", Arch: "x64", Version: "0.155.0", Layout: "tarball_tree", Member: "package/vendor/x86_64-pc-windows-msvc"}); err != nil {
		t.Fatalf("codex tree: %v", err)
	}
}

func TestPublishGatesAndTransitions(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	audit := &fakeAudit{}
	svc := New(Deps{Repo: repo, Audit: audit})

	v1, err := svc.Create(ctx, codexInput())
	if err != nil {
		t.Fatal(err)
	}
	// package missing
	if _, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); !errors.Is(err, dom.ErrPackageMissing) {
		t.Fatalf("package gate: %v", err)
	}
	withPackage(repo, v1.UUID)
	// contract check missing
	repo.rows[v1.UUID].ContractCheckRef = ""
	if _, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); !errors.Is(err, dom.ErrContractCheckMissing) {
		t.Fatalf("contract gate: %v", err)
	}
	repo.rows[v1.UUID].ContractCheckRef = "ok"
	// CLI needs binary sha
	repo.rows[v1.UUID].BinarySHA256 = ""
	if _, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); !errors.Is(err, dom.ErrMissingBinarySHA) {
		t.Fatalf("binary sha gate: %v", err)
	}
	repo.rows[v1.UUID].BinarySHA256 = sha
	// So does a Claude Code host npm tarball: the Bridge skips the row without it.
	host, err := svc.Create(ctx, dom.UpsertInput{
		TargetID: "claude_code_host", Platform: "macos", Arch: "x64", Version: "2.1.260",
		Layout: "host_binary_npm_tgz", ContractCheckRef: "ok", ActorID: 7,
	})
	if err != nil {
		t.Fatal(err)
	}
	withPackage(repo, host.UUID)
	if _, err := svc.Publish(ctx, host.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); !errors.Is(err, dom.ErrMissingBinarySHA) {
		t.Fatalf("host binary sha gate: %v", err)
	}
	// canary needs tenants
	if _, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "canary", ActorID: 7}); !errors.Is(err, dom.ErrCanaryTenantsMissing) {
		t.Fatalf("canary tenants gate: %v", err)
	}
	if _, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "beta", TenantIDs: []int64{1}, ActorID: 7}); !errors.Is(err, dom.ErrInvalidPublishMode) {
		t.Fatalf("mode gate: %v", err)
	}
	// canary → current
	canary, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "Canary", TenantIDs: []int64{581, 581, 0, 1}, ActorID: 7})
	if err != nil {
		t.Fatal(err)
	}
	if canary.Status != dom.StatusCanary || fmt.Sprint(canary.CanaryTenantIDs) != "[1 581]" {
		t.Fatalf("canary state: %+v", canary)
	}
	current, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "current", ActorID: 7})
	if err != nil {
		t.Fatal(err)
	}
	if current.Status != dom.StatusCurrent || len(current.CanaryTenantIDs) != 0 {
		t.Fatalf("current state: %+v", current)
	}
	// second version becomes current, first demoted to previous
	in2 := codexInput()
	in2.Version = "0.155.0"
	v2, _ := svc.Create(ctx, in2)
	withPackage(repo, v2.UUID)
	if _, err := svc.Publish(ctx, v2.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	if repo.rows[v1.UUID].Status != dom.StatusPrevious {
		t.Fatalf("v1 should be previous, got %s", repo.rows[v1.UUID].Status)
	}
	// published rows are immutable
	if _, err := svc.Update(ctx, v2.UUID, in2); !errors.Is(err, dom.ErrNotDraft) {
		t.Fatalf("immutable: %v", err)
	}
	if len(audit.events) != 3 || audit.events[0].EventKind != "local_coding.version_published" || audit.events[0].AccountID != 7 {
		t.Fatalf("audit: %+v", audit.events)
	}
	if strings.Contains(string(audit.events[0].Payload), "oss://") {
		t.Fatal("audit must not carry storage uris")
	}

	// Platform-level rollback: the previous version is re-published as
	// current, the withdrawn current becomes previous.
	rolled, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "current", ActorID: 7})
	if err != nil {
		t.Fatalf("rollback publish: %v", err)
	}
	if rolled.Status != dom.StatusCurrent || repo.rows[v2.UUID].Status != dom.StatusPrevious {
		t.Fatalf("after rollback: v1=%s v2=%s", rolled.Status, repo.rows[v2.UUID].Status)
	}
	last := audit.events[len(audit.events)-1]
	if !strings.Contains(string(last.Payload), `"rollback":true`) || !strings.Contains(string(last.Payload), `"from_status":"previous"`) {
		t.Fatalf("rollback audit payload: %s", last.Payload)
	}
	// A current version cannot be published again; previous cannot go canary.
	if _, err := svc.Publish(ctx, v1.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); !errors.Is(err, dom.ErrInvalidStatus) {
		t.Fatalf("republish current: %v", err)
	}
	if _, err := svc.Publish(ctx, v2.UUID, dom.PublishInput{Mode: "canary", TenantIDs: []int64{1}, ActorID: 7}); !errors.Is(err, dom.ErrInvalidStatus) {
		t.Fatalf("previous to canary: %v", err)
	}
	// A deprecated version can come back as current too (the old previous is
	// deprecated, the old current becomes previous).
	in3 := codexInput()
	in3.Version = "0.156.0"
	v3, _ := svc.Create(ctx, in3)
	withPackage(repo, v3.UUID)
	if _, err := svc.Publish(ctx, v3.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	// now: v3 current, v1 previous, v2 deprecated
	if repo.rows[v2.UUID].Status != dom.StatusDeprecated {
		t.Fatalf("v2 should be deprecated, got %s", repo.rows[v2.UUID].Status)
	}
	if _, err := svc.Publish(ctx, v2.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatalf("deprecated back to current: %v", err)
	}
	if repo.rows[v2.UUID].Status != dom.StatusCurrent || repo.rows[v3.UUID].Status != dom.StatusPrevious || repo.rows[v1.UUID].Status != dom.StatusDeprecated {
		t.Fatalf("after deprecated rollback: v1=%s v2=%s v3=%s", repo.rows[v1.UUID].Status, repo.rows[v2.UUID].Status, repo.rows[v3.UUID].Status)
	}
}

func TestCatalogResolvesCanaryPerTenantAndSigns(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	signer, pub := newTestSigner(t)
	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	svc := New(Deps{
		Repo: repo, Signer: signer, ExternalBaseURL: "https://bus.example.com/",
		Now: func() time.Time { return now },
	})

	cur, _ := svc.Create(ctx, codexInput())
	withPackage(repo, cur.UUID)
	if _, err := svc.Publish(ctx, cur.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	in2 := codexInput()
	in2.Version = "0.155.0"
	can, _ := svc.Create(ctx, in2)
	withPackage(repo, can.UUID)
	if _, err := svc.Publish(ctx, can.UUID, dom.PublishInput{Mode: "canary", TenantIDs: []int64{581}, ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	// desktop universal with external CDN url
	desk, err := svc.Create(ctx, dom.UpsertInput{
		TargetID: "claude_desktop", Platform: "macos", Arch: "universal", Version: "1.46388.4", Layout: "app_bundle_dmg",
		ContractCheckRef: "ok", ExternalURL: "https://dl.example.cn/local-coding/claude.dmg", FileSizeBytes: 353897855, SHA256: sha,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Publish(ctx, desk.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}

	// tenant 1: global current
	signed, err := svc.Catalog(ctx, 1, "macos", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	codex := signed.Catalog.Targets["codex_cli"]
	if codex.Current == nil || codex.Current.Version != "0.154.0" || codex.Previous != nil || codex.Current.Canary {
		t.Fatalf("tenant 1 resolution: %+v", codex)
	}
	if got := codex.Current.Sources[0].URL; got != "https://bus.example.com/api/agent-bus/v1/local-coding-tools/packages/"+cur.UUID+"/download" {
		t.Fatalf("redirect url: %s", got)
	}
	if fmt.Sprint(signed.Catalog.AllowedHosts) != "[bus.example.com dl.example.cn]" {
		t.Fatalf("allowed hosts: %v", signed.Catalog.AllowedHosts)
	}
	if signed.Catalog.Targets["claude_desktop"].Current.Sources[0].URL != "https://dl.example.cn/local-coding/claude.dmg" {
		t.Fatalf("external url must pass through")
	}
	if signed.Catalog.IssuedAt != "2026-09-10T12:00:00Z" || signed.Catalog.ExpiresAt != "2026-09-17T12:00:00Z" {
		t.Fatalf("validity window: %s → %s", signed.Catalog.IssuedAt, signed.Catalog.ExpiresAt)
	}

	// tenant 581: canary is current, global current becomes previous
	signed581, err := svc.Catalog(ctx, 581, "macos", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	codex581 := signed581.Catalog.Targets["codex_cli"]
	if codex581.Current == nil || codex581.Current.Version != "0.155.0" || !codex581.Current.Canary ||
		codex581.Previous == nil || codex581.Previous.Version != "0.154.0" {
		t.Fatalf("tenant 581 resolution: %+v", codex581)
	}

	// signature verifies with the public key over canonical JSON, and is
	// tamper-evident.
	payload, err := CanonicalJSON(signed.Catalog)
	if err != nil {
		t.Fatal(err)
	}
	if signed.KID != "test-kid" || !Verify(pub, signed.Signature, payload) {
		t.Fatal("signature must verify")
	}
	tampered := signed.Catalog
	tampered.Targets = map[string]CatalogTarget{}
	tamperedPayload, _ := CanonicalJSON(tampered)
	if Verify(pub, signed.Signature, tamperedPayload) {
		t.Fatal("tampered catalog must not verify")
	}
	// canonical JSON keeps integers intact and sorts keys
	if !strings.Contains(string(payload), `"size":87323149`) {
		t.Fatalf("size must stay an integer: %s", payload)
	}
	var generic map[string]any
	if err := json.Unmarshal(payload, &generic); err != nil {
		t.Fatal(err)
	}
	if strings.Index(string(payload), `"allowed_hosts"`) > strings.Index(string(payload), `"targets"`) {
		t.Fatalf("keys must be sorted: %s", payload)
	}
}

func TestCatalogRequiresSignerAndValidArch(t *testing.T) {
	ctx := context.Background()
	if _, err := New(Deps{Repo: newFakeRepo()}).Catalog(ctx, 1, "macos", "arm64"); !errors.Is(err, dom.ErrSignerMissing) {
		t.Fatalf("signer gate: %v", err)
	}
	signer, _ := newTestSigner(t)
	svc := New(Deps{Repo: newFakeRepo(), Signer: signer})
	if _, err := svc.Catalog(ctx, 1, "macos", "universal"); !errors.Is(err, dom.ErrInvalidArch) {
		t.Fatalf("universal is not a client arch: %v", err)
	}
	if _, err := svc.Catalog(ctx, 1, "linux", "x64"); !errors.Is(err, dom.ErrInvalidPlatform) {
		t.Fatalf("platform gate: %v", err)
	}
}

func TestPackageRedirectOnlyForPublished(t *testing.T) {
	ctx := context.Background()
	repo := newFakeRepo()
	svc := New(Deps{Repo: repo})
	v, _ := svc.Create(ctx, codexInput())
	withPackage(repo, v.UUID)
	if _, err := svc.PackageLocation(ctx, v.UUID); !errors.Is(err, dom.ErrPackageNotDownloadable) {
		t.Fatalf("draft must not be downloadable: %v", err)
	}
	if _, err := svc.Publish(ctx, v.UUID, dom.PublishInput{Mode: "current", ActorID: 7}); err != nil {
		t.Fatal(err)
	}
	// oss:// needs a package store; external https passes through.
	if _, err := svc.PackageLocation(ctx, v.UUID); !errors.Is(err, dom.ErrPackageStoreMissing) {
		t.Fatalf("store gate: %v", err)
	}
	repo.rows[v.UUID].StorageURI = "https://dl.example.cn/x.tar.gz"
	if got, err := svc.PackageLocation(ctx, v.UUID); err != nil || got.URL != "https://dl.example.cn/x.tar.gz" || got.Proxy {
		t.Fatalf("external passthrough: %+v %v", got, err)
	}
}

func TestSignerAcceptsSeedAndFullKey(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	fromSeed, err := NewSignerFromBase64(base64.RawURLEncoding.EncodeToString(priv.Seed()), "")
	if err != nil {
		t.Fatal(err)
	}
	fromFull, err := NewSignerFromBase64(base64.StdEncoding.EncodeToString(priv), "k2")
	if err != nil {
		t.Fatal(err)
	}
	if fromSeed.PublicKeyBase64() != base64.StdEncoding.EncodeToString(pub) || fromFull.PublicKeyBase64() != fromSeed.PublicKeyBase64() {
		t.Fatal("public keys must match")
	}
	if fromSeed.KeyID() != "lc-catalog" || fromFull.KeyID() != "k2" {
		t.Fatal("kid defaults")
	}
	if _, err := NewSignerFromBase64("not-a-key", ""); err == nil {
		t.Fatal("garbage must be rejected")
	}
	msg := []byte(`{"a":1}`)
	if !Verify(fromSeed.PublicKeyBase64(), fromSeed.Sign(msg), msg) {
		t.Fatal("round trip")
	}
}
