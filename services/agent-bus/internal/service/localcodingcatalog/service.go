// Package localcodingcatalog manages the F31 tool version catalog: Admin
// CRUD + package upload + publish (canary by tenant / current), and the
// signed per-tenant catalog the Bus hands to the desktop App for the Bridge.
// Plan: docs/features/F31-local-coding-tools-version-catalog-plan.md.
package localcodingcatalog

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	svcclientversion "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/clientversion"
)

const (
	// DefaultCatalogTTL bounds how long a signed catalog stays valid offline.
	DefaultCatalogTTL = 7 * 24 * time.Hour
	// PackagePathPrefix is the Bus redirect route the catalog points at when a
	// package lives in platform object storage (no CDN configured yet).
	PackagePathPrefix = "/api/agent-bus/v1/local-coding-tools/packages/"
	// packageSignTTL is the presigned object URL lifetime behind the redirect;
	// each Bridge (re)request hits the redirect again, so it can stay short.
	packageSignTTL = 10 * time.Minute

	codexDesktopBundleID  = "com.openai.codex"
	codexDesktopTeamID    = "2DC432GLL2"
	claudeDesktopBundleID = "com.anthropic.claudefordesktop"
	claudeDesktopTeamID   = "Q6L2SF6YDW"
)

var sha256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Service is the Admin + client facade.
type Service interface {
	List(ctx context.Context, f dom.Filter) ([]dom.Version, int64, error)
	Get(ctx context.Context, uuid string) (*dom.Version, error)
	Create(ctx context.Context, in dom.UpsertInput) (*dom.Version, error)
	Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Version, error)
	UploadPackage(ctx context.Context, uuid, filename, contentType string, body io.Reader, size int64, actorID int64) (*dom.Version, error)
	Publish(ctx context.Context, uuid string, in dom.PublishInput) (*dom.Version, error)
	Deprecate(ctx context.Context, uuid string, actorID int64) (*dom.Version, error)
	Delete(ctx context.Context, uuid string, actorID int64) error
	// MirrorPackage copies an external (https) package into the platform
	// object store so the catalog serves it through the Bus / CDN instead of
	// the third-party host. It runs in the background (mirror.go); the row's
	// mirror_state reports progress.
	MirrorPackage(ctx context.Context, uuid string, actorID int64) (*dom.Version, error)
	// RecoverInterruptedMirrors fails every row left at running by a
	// previous process (its copy died with it) so the operator can retry;
	// call it once at startup, only from the process that runs copies
	// (Admin), never from the Bus.
	RecoverInterruptedMirrors(ctx context.Context) (int64, error)
	// Catalog resolves canary/current/previous for the tenant and signs it.
	Catalog(ctx context.Context, tenantID int64, platform, arch string) (*SignedCatalog, error)
	// PackageLocation resolves how a published package is served to the
	// Bridge: a redirect to the signed / public https URL, or a stream
	// proxied by the Bus when the object store only speaks http.
	PackageLocation(ctx context.Context, uuid string) (*PackageLocation, error)
	// AdminPackageURL is the operator-side download (any status, drafts included).
	AdminPackageURL(ctx context.Context, uuid string) (string, error)
	// RefreshShareLinks generates / regenerates the drive share links that
	// stand in for a CDN (share.go); the Bus runs it periodically. No-op
	// when share links are not configured.
	RefreshShareLinks(ctx context.Context) (*ShareRefreshReport, error)
	// AutoSync runs one round of CLI and desktop auto sync (autosync.go): new Codex /
	// Claude CLI versions on the npm mirror are verified, recorded, copied
	// into the object store and published as current. Admin runs it
	// periodically; ErrAutoSyncDisabled when it is not configured.
	AutoSync(ctx context.Context) (*AutoSyncReport, error)
	// StartAutoSync runs a round in the background for the operator's
	// "check now" (a round downloads several hundred MB and would outlast
	// any HTTP request); AutoSyncStatus tells how it went.
	StartAutoSync(ctx context.Context) error
	AutoSyncStatus() AutoSyncStatus
}

// Catalog is the signed payload (see plan §2). Field order is irrelevant:
// signatures are computed over CanonicalJSON.
type Catalog struct {
	Schema       int                      `json:"schema"`
	IssuedAt     string                   `json:"issued_at"`
	ExpiresAt    string                   `json:"expires_at"`
	Platform     string                   `json:"platform"`
	Arch         string                   `json:"arch"`
	AllowedHosts []string                 `json:"allowed_hosts"`
	Targets      map[string]CatalogTarget `json:"targets"`
}

type CatalogTarget struct {
	Current  *CatalogVersion `json:"current"`
	Previous *CatalogVersion `json:"previous"`
}

type CatalogVersion struct {
	Version          string          `json:"version"`
	Layout           string          `json:"layout"`
	Member           string          `json:"member,omitempty"`
	BinarySHA256     string          `json:"binary_sha256,omitempty"`
	BundleIdentifier string          `json:"bundle_identifier,omitempty"`
	TeamIdentifier   string          `json:"team_identifier,omitempty"`
	ProfileVersion   string          `json:"profile_version,omitempty"`
	MinBridgeVersion string          `json:"min_bridge_version,omitempty"`
	MinAppVersion    string          `json:"min_app_version,omitempty"`
	ReleaseNotes     string          `json:"release_notes,omitempty"`
	Canary           bool            `json:"canary,omitempty"`
	Sources          []CatalogSource `json:"sources"`
}

type CatalogSource struct {
	Kind   string `json:"kind"`
	URL    string `json:"url"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type SignedCatalog struct {
	Catalog   Catalog `json:"catalog"`
	KID       string  `json:"kid"`
	Signature string  `json:"signature"`
}

type Deps struct {
	Logger AutoSyncLogger
	Repo   dom.Repository
	// Packages is the platform object store wrapper (prefix local-coding/).
	// Optional on read-only deployments.
	Packages *svcclientversion.PackageStore
	// Audit is optional; publish / deprecate are recorded when present.
	Audit domaudit.Store
	// Signer is required for Catalog(); Admin-only deployments may omit it.
	Signer *Signer
	// ExternalBaseURL is the public Bus origin used for package redirect URLs.
	ExternalBaseURL string
	// PublicBaseURL, when set, is the CDN origin fronting the object store:
	// oss://<key> becomes <PublicBaseURL>/<key> and no redirect is needed.
	PublicBaseURL string
	CatalogTTL    time.Duration
	Now           func() time.Time
	// HTTPClient downloads external packages for MirrorPackage (default: a
	// client honouring the process proxy settings). MirrorSync runs the copy
	// inline instead of in a goroutine (tests).
	HTTPClient *http.Client
	MirrorSync bool
	// Share / ShareCredentials enable the drive share links standing in for
	// a CDN (share.go); both must be set, Bus only.
	Share            *ShareConfig
	ShareCredentials ShareCredentials
	// AutoSync enables CLI and desktop auto sync (autosync.go); Admin only.
	AutoSync *AutoSyncConfig
}

type impl struct {
	logger       AutoSyncLogger
	repo         dom.Repository
	packages     *svcclientversion.PackageStore
	audit        domaudit.Store
	signer       *Signer
	externalBase string
	publicBase   string
	catalogTTL   time.Duration
	now          func() time.Time
	httpClient   *http.Client
	mirrorSync   bool
	share        *ShareConfig
	shareCreds   ShareCredentials
	autoSync     *AutoSyncConfig
	// autoSyncRunning / autoSyncLast describe this process's rounds (autosync.go).
	autoSyncMu      sync.Mutex
	autoSyncRunning bool
	autoSyncLast    *AutoSyncReport
	// mirrorSlots bounds concurrent copies (mirror.go).
	mirrorSlots chan struct{}

	// redirectHost caches the host the Bus package redirect lands on (the
	// object store's presigned URL); learned once per process.
	redirectMu   sync.Mutex
	redirectHost string
}

func New(deps Deps) Service {
	now := deps.Now
	if now == nil {
		now = time.Now
	}
	ttl := deps.CatalogTTL
	if ttl <= 0 {
		ttl = DefaultCatalogTTL
	}
	client := deps.HTTPClient
	if client == nil {
		client = &http.Client{}
	}
	return &impl{
		logger:     deps.Logger,
		httpClient: client, mirrorSync: deps.MirrorSync, mirrorSlots: make(chan struct{}, mirrorConcurrency),
		repo: deps.Repo, packages: deps.Packages, audit: deps.Audit, signer: deps.Signer,
		externalBase: strings.TrimRight(strings.TrimSpace(deps.ExternalBaseURL), "/"),
		publicBase:   strings.TrimRight(strings.TrimSpace(deps.PublicBaseURL), "/"),
		catalogTTL:   ttl, now: now,
		share: deps.Share, shareCreds: deps.ShareCredentials, autoSync: deps.AutoSync,
	}
}

// ---------------------------------------------------------------- Admin

func (s *impl) List(ctx context.Context, f dom.Filter) ([]dom.Version, int64, error) {
	f.TargetID = normalize(f.TargetID)
	f.Platform = normalize(f.Platform)
	f.Arch = normalize(f.Arch)
	f.Status = normalize(f.Status)
	f.Keyword = strings.TrimSpace(f.Keyword)
	if f.TargetID != "" && !dom.ValidTarget(f.TargetID) {
		return nil, 0, dom.ErrInvalidTarget
	}
	if f.Platform != "" && !dom.ValidPlatform(f.Platform) {
		return nil, 0, dom.ErrInvalidPlatform
	}
	if f.Arch != "" && !dom.ValidArch(f.Arch) {
		return nil, 0, dom.ErrInvalidArch
	}
	if f.Status != "" && !dom.ValidStatus(f.Status) {
		return nil, 0, dom.ErrInvalidStatus
	}
	if f.Limit <= 0 || f.Limit > 100 {
		f.Limit = 20
	}
	if f.Offset < 0 {
		f.Offset = 0
	}
	return s.repo.List(ctx, f)
}

func (s *impl) Get(ctx context.Context, uuid string) (*dom.Version, error) {
	return s.repo.GetByUUID(ctx, strings.TrimSpace(uuid))
}

func (s *impl) Create(ctx context.Context, in dom.UpsertInput) (*dom.Version, error) {
	normalized, err := normalizeInput(in)
	if err != nil {
		return nil, err
	}
	return s.repo.Create(ctx, normalized)
}

func (s *impl) Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Version, error) {
	normalized, err := normalizeInput(in)
	if err != nil {
		return nil, err
	}
	return s.repo.Update(ctx, strings.TrimSpace(uuid), normalized)
}

func (s *impl) UploadPackage(ctx context.Context, uuid, filename, contentType string, body io.Reader, size int64, actorID int64) (*dom.Version, error) {
	uuid = strings.TrimSpace(uuid)
	if s.packages == nil {
		return nil, dom.ErrPackageStoreMissing
	}
	item, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	// A published version whose package is still an external link may have
	// the same file uploaded: the bytes must match what was recorded, then
	// only the storage location changes (status and tenants untouched).
	replacing := item.Status != dom.StatusDraft
	if replacing && !item.IsExternalPackage() {
		return nil, dom.ErrNotDraft
	}
	uploaded, err := s.packages.Upload(ctx, uuid, filename, body, size, contentType)
	if err != nil {
		return nil, err
	}
	if replacing {
		if uploaded.SizeBytes != item.FileSizeBytes || uploaded.SHA256 != item.SHA256 {
			return nil, dom.ErrMirrorMismatch
		}
		replaced, err := s.repo.ReplaceStorage(ctx, uuid, uploaded.StorageURI, item.FileSizeBytes, item.SHA256, actorID)
		if err != nil {
			return nil, err
		}
		s.auditEvent(ctx, actorID, "local_coding.package_mirrored", replaced, map[string]any{
			"from_host": hostOf(item.StorageURI), "uploaded": true,
		})
		return replaced, nil
	}
	return s.repo.SetPackage(ctx, uuid, dom.PackageInput{
		StorageURI: uploaded.StorageURI, FileSizeBytes: uploaded.SizeBytes, SHA256: uploaded.SHA256, ActorID: actorID,
	})
}

func (s *impl) Publish(ctx context.Context, uuid string, in dom.PublishInput) (*dom.Version, error) {
	uuid = strings.TrimSpace(uuid)
	item, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	in.Mode = normalize(in.Mode)
	if in.Mode != dom.PublishModeCanary && in.Mode != dom.PublishModeCurrent {
		return nil, dom.ErrInvalidPublishMode
	}
	// Canary is a first release (draft) or a re-targeting of a running canary.
	// Current accepts those plus previous / deprecated: re-publishing an older
	// version as current is the platform-level rollback (the bad current is
	// demoted to previous so machines that took it can come back).
	if !publishableFrom(item.Status, in.Mode) {
		return nil, dom.ErrInvalidStatus
	}
	if !item.HasPackage() {
		return nil, dom.ErrPackageMissing
	}
	if strings.TrimSpace(item.ContractCheckRef) == "" {
		return nil, dom.ErrContractCheckMissing
	}
	if requiresBinarySHA(item.TargetID, item.Layout) && item.BinarySHA256 == "" {
		return nil, dom.ErrMissingBinarySHA
	}
	switch in.Mode {
	case dom.PublishModeCanary:
		in.TenantIDs = dedupeTenants(in.TenantIDs)
		if len(in.TenantIDs) == 0 {
			return nil, dom.ErrCanaryTenantsMissing
		}
	case dom.PublishModeCurrent:
		in.TenantIDs = nil
	default:
		return nil, dom.ErrInvalidPublishMode
	}
	published, err := s.repo.Publish(ctx, uuid, in)
	if err != nil {
		return nil, err
	}
	s.auditEvent(ctx, in.ActorID, "local_coding.version_published", published, map[string]any{
		"mode": in.Mode, "canary_tenant_ids": in.TenantIDs, "from_status": item.Status,
		"rollback": item.Status == dom.StatusPrevious || item.Status == dom.StatusDeprecated,
	})
	return published, nil
}

// publishableFrom says which statuses a publish mode accepts.
func publishableFrom(status, mode string) bool {
	switch mode {
	case dom.PublishModeCanary:
		return status == dom.StatusDraft || status == dom.StatusCanary
	case dom.PublishModeCurrent:
		return status == dom.StatusDraft || status == dom.StatusCanary ||
			status == dom.StatusPrevious || status == dom.StatusDeprecated
	default:
		return false
	}
}

func (s *impl) Deprecate(ctx context.Context, uuid string, actorID int64) (*dom.Version, error) {
	item, err := s.repo.Deprecate(ctx, strings.TrimSpace(uuid), actorID)
	if err != nil {
		return nil, err
	}
	s.auditEvent(ctx, actorID, "local_coding.version_deprecated", item, nil)
	return item, nil
}

func (s *impl) Delete(ctx context.Context, uuid string, actorID int64) error {
	return s.repo.Delete(ctx, strings.TrimSpace(uuid), actorID)
}

// ---------------------------------------------------------------- Client

func (s *impl) Catalog(ctx context.Context, tenantID int64, platform, arch string) (*SignedCatalog, error) {
	if s.signer == nil {
		return nil, dom.ErrSignerMissing
	}
	platform = normalize(platform)
	arch = normalize(arch)
	if !dom.ValidPlatform(platform) {
		return nil, dom.ErrInvalidPlatform
	}
	if !dom.ValidArch(arch) || arch == dom.ArchUniversal {
		return nil, dom.ErrInvalidArch
	}
	rows, err := s.repo.ListActive(ctx, platform, arch)
	if err != nil {
		return nil, err
	}
	now := s.now().UTC()
	catalog := Catalog{
		Schema:    dom.CatalogSchema,
		IssuedAt:  now.Format(time.RFC3339),
		ExpiresAt: now.Add(s.catalogTTL).Format(time.RFC3339),
		Platform:  platform,
		Arch:      arch,
		Targets:   map[string]CatalogTarget{},
	}
	hosts := map[string]struct{}{}
	byTarget := map[string][]dom.Version{}
	for _, row := range rows {
		byTarget[row.TargetID] = append(byTarget[row.TargetID], row)
	}
	for target, versions := range byTarget {
		current, previous := resolveForTenant(versions, tenantID, arch)
		if current == nil {
			continue
		}
		entry := CatalogTarget{Current: s.catalogVersion(*current, hosts)}
		entry.Current.Canary = current.Status == dom.StatusCanary
		if previous != nil {
			entry.Previous = s.catalogVersion(*previous, hosts)
		}
		catalog.Targets[target] = entry
	}
	if host := s.packageRedirectHost(ctx, rows); host != "" {
		hosts[host] = struct{}{}
	}
	catalog.AllowedHosts = sortedHosts(hosts)
	payload, err := CanonicalJSON(catalog)
	if err != nil {
		return nil, fmt.Errorf("catalog canonical json: %w", err)
	}
	return &SignedCatalog{Catalog: catalog, KID: s.signer.KeyID(), Signature: s.signer.Sign(payload)}, nil
}

// PackageLocation is how the Bus serves one published package. The Bridge
// follows https only (contract §2.7.4); an object store without TLS (the test
// environment's) would turn every redirect into PUBLISHER_MISMATCH, so such
// packages are streamed through the Bus instead (Proxy). The relay fetches
// through the store's internal endpoint: from inside the cluster the public
// read endpoint is typically unreachable or routed out through the egress
// proxy, while the internal one is what uploads already use.
type PackageLocation struct {
	// URL is where the bytes come from: the signed public URL, the CDN URL
	// or the external link when redirecting; the internally signed URL when
	// proxying.
	URL string
	// Proxy is set when the public URL is not https: the handler relays the
	// bytes itself.
	Proxy bool
	// FileName names the attachment when proxied.
	FileName string
}

func (s *impl) PackageLocation(ctx context.Context, uuid string) (*PackageLocation, error) {
	item, err := s.repo.GetByUUID(ctx, strings.TrimSpace(uuid))
	if err != nil {
		return nil, err
	}
	switch item.Status {
	case dom.StatusCanary, dom.StatusCurrent, dom.StatusPrevious:
	default:
		return nil, dom.ErrPackageNotDownloadable
	}
	u, err := s.signedPackageURL(ctx, item)
	if err != nil {
		return nil, err
	}
	location := &PackageLocation{URL: u, Proxy: !strings.HasPrefix(u, "https://"), FileName: path.Base(item.StorageURI)}
	if location.Proxy && strings.HasPrefix(item.StorageURI, "oss://") {
		if internal, err := s.packages.SignURLInternal(ctx, item.StorageURI, location.FileName, packageSignTTL); err == nil && internal != "" {
			location.URL = internal
		}
	}
	return location, nil
}

func (s *impl) AdminPackageURL(ctx context.Context, uuid string) (string, error) {
	item, err := s.repo.GetByUUID(ctx, strings.TrimSpace(uuid))
	if err != nil {
		return "", err
	}
	return s.signedPackageURL(ctx, item)
}

func (s *impl) signedPackageURL(ctx context.Context, item *dom.Version) (string, error) {
	if !item.HasPackage() {
		return "", dom.ErrPackageNotDownloadable
	}
	if isHTTP(item.StorageURI) {
		return item.StorageURI, nil
	}
	if s.packages == nil {
		return "", dom.ErrPackageStoreMissing
	}
	return s.packages.SignURL(ctx, item.StorageURI, path.Base(item.StorageURI), packageSignTTL)
}

// ---------------------------------------------------------------- helpers

// resolveForTenant picks current / previous for one target. A canary whose
// tenant list contains the tenant wins as current and pushes the global
// current down to previous; otherwise the global current / previous apply.
// Exact-arch rows are preferred over universal ones.
func resolveForTenant(versions []dom.Version, tenantID int64, arch string) (*dom.Version, *dom.Version) {
	pick := func(status string) *dom.Version {
		var universal *dom.Version
		for i := range versions {
			v := &versions[i]
			if v.Status != status {
				continue
			}
			if v.Arch == arch {
				return v
			}
			if v.Arch == dom.ArchUniversal && universal == nil {
				universal = v
			}
		}
		return universal
	}
	globalCurrent := pick(dom.StatusCurrent)
	globalPrevious := pick(dom.StatusPrevious)
	for i := range versions {
		v := &versions[i]
		if v.Status != dom.StatusCanary || (v.Arch != arch && v.Arch != dom.ArchUniversal) {
			continue
		}
		for _, id := range v.CanaryTenantIDs {
			if id == tenantID {
				if globalCurrent != nil {
					return v, globalCurrent
				}
				return v, globalPrevious
			}
		}
	}
	return globalCurrent, globalPrevious
}

func (s *impl) catalogVersion(v dom.Version, hosts map[string]struct{}) *CatalogVersion {
	entry := &CatalogVersion{
		Version: v.Version, Layout: v.Layout, Member: v.Member, BinarySHA256: v.BinarySHA256,
		BundleIdentifier: v.BundleIdentifier, TeamIdentifier: v.TeamIdentifier,
		ProfileVersion: v.ProfileVersion, MinBridgeVersion: v.MinBridgeVersion, MinAppVersion: v.MinAppVersion,
		ReleaseNotes: v.ReleaseNotes, Sources: []CatalogSource{},
	}
	if !v.HasPackage() {
		return entry
	}
	u := s.packageURL(v)
	if host := hostOf(u); host != "" {
		hosts[host] = struct{}{}
	}
	entry.Sources = append(entry.Sources, CatalogSource{
		Kind: dom.SourceKindZhibanPackage, URL: u, Size: v.FileSizeBytes, SHA256: v.SHA256,
	})
	return entry
}

// packageRedirectHost returns the host a Bus package redirect resolves to,
// so the Bridge's download allow-list admits the 302 target. Only versions
// served through the redirect (object storage without a CDN front) need it;
// the presigned host is learned from the first such version and cached
// because the store endpoint does not change while the process runs.
func (s *impl) packageRedirectHost(ctx context.Context, rows []dom.Version) string {
	if s.packages == nil || s.publicBase != "" {
		return ""
	}
	s.redirectMu.Lock()
	defer s.redirectMu.Unlock()
	if s.redirectHost != "" {
		return s.redirectHost
	}
	for _, row := range rows {
		if !strings.HasPrefix(row.StorageURI, "oss://") {
			continue
		}
		signed, err := s.packages.SignURL(ctx, row.StorageURI, path.Base(row.StorageURI), packageSignTTL)
		// An http-only store is never redirected to (PackageLocation proxies
		// it), so its host has no business in the allow-list.
		if err != nil || !strings.HasPrefix(signed, "https://") {
			continue
		}
		if host := hostOf(signed); host != "" {
			s.redirectHost = host
			return host
		}
	}
	return ""
}

// packageURL prefers a direct public URL — external, CDN-fronted key, or a
// still-fresh drive share link (share.go) — and falls back to the Bus
// redirect, which presigns the object per request.
func (s *impl) packageURL(v dom.Version) string {
	if isHTTP(v.StorageURI) {
		return v.StorageURI
	}
	if s.publicBase != "" && strings.HasPrefix(v.StorageURI, "oss://") {
		return s.publicBase + "/" + strings.TrimPrefix(v.StorageURI, "oss://")
	}
	if u := s.shareURLFor(v); u != "" {
		return u
	}
	return s.externalBase + PackagePathPrefix + v.UUID + "/download"
}

func (s *impl) auditEvent(ctx context.Context, actorID int64, kind string, item *dom.Version, extra map[string]any) {
	if s.audit == nil || item == nil {
		return
	}
	payload := map[string]any{
		"target_id": item.TargetID, "platform": item.Platform, "arch": item.Arch,
		"version": item.Version, "status": item.Status,
	}
	for k, v := range extra {
		payload[k] = v
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		raw = []byte(`{}`)
	}
	actor := domaudit.ActorUser
	if actorID == 0 {
		// The auto sync acts on its own (autosync.go): no operator to name.
		actor = domaudit.ActorSystem
	}
	_ = s.audit.Insert(ctx, domaudit.Event{
		OccurredAt: s.now().UTC(), AccountID: actorID, ActorKind: actor,
		Domain: "local_coding", EventKind: kind, Severity: domaudit.SeverityInfo,
		ResourceKind: "local_coding_tool_version", ResourceUUID: item.UUID, Payload: raw,
	})
}

func normalizeInput(in dom.UpsertInput) (dom.UpsertInput, error) {
	in.TargetID = normalize(in.TargetID)
	in.Platform = normalize(in.Platform)
	in.Arch = normalize(in.Arch)
	in.Layout = normalize(in.Layout)
	in.Version = strings.TrimSpace(in.Version)
	in.Member = strings.TrimSpace(in.Member)
	in.BinarySHA256 = strings.ToLower(strings.TrimSpace(in.BinarySHA256))
	in.SHA256 = strings.ToLower(strings.TrimSpace(in.SHA256))
	in.ExternalURL = strings.TrimSpace(in.ExternalURL)
	in.BundleIdentifier = strings.TrimSpace(in.BundleIdentifier)
	in.TeamIdentifier = strings.TrimSpace(in.TeamIdentifier)
	in.MinBridgeVersion = strings.TrimSpace(in.MinBridgeVersion)
	in.MinAppVersion = strings.TrimSpace(in.MinAppVersion)
	in.ProfileVersion = strings.TrimSpace(in.ProfileVersion)
	in.ContractCheckRef = strings.TrimSpace(in.ContractCheckRef)
	in.ReleaseNotes = strings.TrimSpace(in.ReleaseNotes)
	if !dom.ValidTarget(in.TargetID) {
		return in, dom.ErrInvalidTarget
	}
	if !dom.ValidPlatform(in.Platform) {
		return in, dom.ErrInvalidPlatform
	}
	if !dom.ValidArch(in.Arch) {
		return in, dom.ErrInvalidArch
	}
	if !dom.ValidLayout(in.Layout) {
		return in, dom.ErrInvalidLayout
	}
	if in.Version == "" {
		return in, dom.ErrMissingVersion
	}
	if (in.Layout == dom.LayoutTarballMember || in.Layout == dom.LayoutTarballTree) && in.Member == "" {
		return in, dom.ErrMissingMember
	}
	// The package tree is the Codex CLI's install unit; MSIX is how Windows
	// desktop apps ship and the only layout the Bridge installs there.
	if in.Layout == dom.LayoutTarballTree && in.TargetID != dom.TargetCodexCLI {
		return in, dom.ErrInvalidLayout
	}
	windowsDesktop := in.Platform == dom.PlatformWindows && !isCLI(in.TargetID) && in.TargetID != dom.TargetClaudeCodeHost
	if (in.Layout == dom.LayoutMSIX) != windowsDesktop {
		return in, dom.ErrInvalidLayout
	}
	if in.BinarySHA256 != "" && !sha256Pattern.MatchString(in.BinarySHA256) {
		return in, dom.ErrInvalidSHA256
	}
	if in.ExternalURL != "" {
		if !strings.HasPrefix(in.ExternalURL, "https://") || in.FileSizeBytes <= 0 || !sha256Pattern.MatchString(in.SHA256) {
			return in, dom.ErrInvalidSHA256
		}
	}
	if windowsDesktop {
		// A Windows package is identified by its package identity and
		// Authenticode signer, both compiled into the Bridge; the macOS
		// bundle facts must stay empty or the Bridge rejects the entry.
		in.BundleIdentifier, in.TeamIdentifier = "", ""
		return in, nil
	}
	switch in.TargetID {
	case dom.TargetCodexDesktop:
		if in.BundleIdentifier == "" {
			in.BundleIdentifier = codexDesktopBundleID
		}
		if in.TeamIdentifier == "" {
			in.TeamIdentifier = codexDesktopTeamID
		}
	case dom.TargetClaudeDesktop:
		if in.BundleIdentifier == "" {
			in.BundleIdentifier = claudeDesktopBundleID
		}
		if in.TeamIdentifier == "" {
			in.TeamIdentifier = claudeDesktopTeamID
		}
	}
	return in, nil
}

func isCLI(target string) bool {
	return target == dom.TargetCodexCLI || target == dom.TargetClaudeCLI
}

// requiresBinarySHA: the Bridge checks the extracted executable of a CLI and
// of a Claude Code host shipped as an npm tarball against binary_sha256, and
// silently skips a host row without it, so publishing one would change nothing.
func requiresBinarySHA(target, layout string) bool {
	return isCLI(target) || (target == dom.TargetClaudeCodeHost && layout == dom.LayoutHostBinaryNPMTgz)
}

func isHTTP(s string) bool {
	return strings.HasPrefix(s, "https://") || strings.HasPrefix(s, "http://")
}

func hostOf(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return strings.ToLower(u.Host)
}

func sortedHosts(hosts map[string]struct{}) []string {
	out := make([]string, 0, len(hosts))
	for h := range hosts {
		out = append(out, h)
	}
	sort.Strings(out)
	return out
}

func dedupeTenants(ids []int64) []int64 {
	seen := map[int64]struct{}{}
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if id <= 0 {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func normalize(v string) string {
	return strings.ToLower(strings.TrimSpace(v))
}
