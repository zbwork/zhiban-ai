// Package localcodingcatalog is the F31 local coding tool version catalog:
// Admin uploads tool packages and publishes versions (canary by tenant or
// current for everyone); Bus signs a per-tenant catalog for the Bridge.
// Plan: docs/features/F31-local-coding-tools-version-catalog-plan.md.
package localcodingcatalog

import (
	"context"
	"errors"
	"strings"
	"time"
)

const (
	TargetCodexCLI       = "codex_cli"
	TargetClaudeCLI      = "claude_cli"
	TargetCodexDesktop   = "codex_desktop"
	TargetClaudeDesktop  = "claude_desktop"
	TargetClaudeCodeHost = "claude_code_host"

	PlatformMacOS   = "macos"
	PlatformWindows = "windows"

	ArchArm64     = "arm64"
	ArchX64       = "x64"
	ArchUniversal = "universal"

	LayoutTarballSingle    = "tarball_single"
	LayoutTarballMember    = "tarball_member"
	LayoutTarballTree      = "tarball_tree" // codex_cli: member is the whole package subtree
	LayoutBareBinary       = "bare_binary"
	LayoutMSIX             = "msix" // Windows desktop packages (Add-AppxPackage)
	LayoutAppBundleZip     = "app_bundle_zip"
	LayoutAppBundleDMG     = "app_bundle_dmg"
	LayoutHostBinaryNPMTgz = "host_binary_npm_tgz"
	LayoutHostBundleTarZst = "host_bundle_tar_zst"

	StatusDraft      = "draft"
	StatusCanary     = "canary"
	StatusCurrent    = "current"
	StatusPrevious   = "previous"
	StatusDeprecated = "deprecated"

	// PublishModeCanary makes the version current only for CanaryTenantIDs;
	// PublishModeCurrent makes it current for everyone and demotes the old
	// current to previous (and the old previous to deprecated).
	PublishModeCanary  = "canary"
	PublishModeCurrent = "current"

	// SourceKindZhibanPackage is the catalog source kind for packages hosted
	// by the platform (object storage behind a Bus redirect, or a CDN URL).
	SourceKindZhibanPackage = "zhiban_package"

	// Mirror states of an external (https) package being copied into the
	// platform object store; "" means never attempted.
	MirrorStateRunning = "running"
	MirrorStateDone    = "done"
	MirrorStateFailed  = "failed"

	// AutoSyncRefPrefix starts the contract_check_ref of a row recorded by
	// the CLI auto sync (plan §2.2). It is the only marker of such a row: no
	// column was added, so deploying the code never depends on a migration.
	// An operator who rewrites the field takes the row over, and the auto
	// sync then leaves it alone.
	AutoSyncRefPrefix = "autosync:"

	CatalogSchema = 1
)

var (
	ErrInvalidTarget          = errors.New("local_coding_catalog.invalid_target")
	ErrInvalidPlatform        = errors.New("local_coding_catalog.invalid_platform")
	ErrInvalidArch            = errors.New("local_coding_catalog.invalid_arch")
	ErrInvalidLayout          = errors.New("local_coding_catalog.invalid_layout")
	ErrInvalidStatus          = errors.New("local_coding_catalog.invalid_status")
	ErrMissingVersion         = errors.New("local_coding_catalog.missing_version")
	ErrMissingMember          = errors.New("local_coding_catalog.missing_member")
	ErrMissingBinarySHA       = errors.New("local_coding_catalog.missing_binary_sha256")
	ErrInvalidSHA256          = errors.New("local_coding_catalog.invalid_sha256")
	ErrDuplicateVersion       = errors.New("local_coding_catalog.duplicate_version")
	ErrNotDraft               = errors.New("local_coding_catalog.not_draft")
	ErrPackageMissing         = errors.New("local_coding_catalog.package_missing")
	ErrContractCheckMissing   = errors.New("local_coding_catalog.contract_check_missing")
	ErrInvalidPublishMode     = errors.New("local_coding_catalog.invalid_publish_mode")
	ErrCanaryTenantsMissing   = errors.New("local_coding_catalog.canary_tenants_missing")
	ErrCanaryTenantOverlap    = errors.New("local_coding_catalog.canary_tenant_overlap")
	ErrNotPublished           = errors.New("local_coding_catalog.not_published")
	ErrPackageStoreMissing    = errors.New("local_coding_catalog.package_store_missing")
	ErrSignerMissing          = errors.New("local_coding_catalog.signer_missing")
	ErrPackageNotDownloadable = errors.New("local_coding_catalog.package_not_downloadable")
	ErrPackageNotExternal     = errors.New("local_coding_catalog.package_not_external")
	ErrMirrorRunning          = errors.New("local_coding_catalog.mirror_running")
	ErrMirrorMismatch         = errors.New("local_coding_catalog.mirror_mismatch")
	ErrAutoSyncDisabled       = errors.New("local_coding_catalog.auto_sync_disabled")
	ErrAutoSyncRunning        = errors.New("local_coding_catalog.auto_sync_running")
)

// Version is one published-or-draft tool package row.
type Version struct {
	ID               int64   `json:"-"`
	UUID             string  `json:"uuid"`
	TargetID         string  `json:"target_id"`
	Platform         string  `json:"platform"`
	Arch             string  `json:"arch"`
	Version          string  `json:"version"`
	Layout           string  `json:"layout"`
	Member           string  `json:"member"`
	StorageURI       string  `json:"storage_uri"`
	FileSizeBytes    int64   `json:"file_size_bytes"`
	SHA256           string  `json:"sha256"`
	BinarySHA256     string  `json:"binary_sha256"`
	BundleIdentifier string  `json:"bundle_identifier"`
	TeamIdentifier   string  `json:"team_identifier"`
	MinBridgeVersion string  `json:"min_bridge_version"`
	MinAppVersion    string  `json:"min_app_version"`
	ProfileVersion   string  `json:"profile_version"`
	ContractCheckRef string  `json:"contract_check_ref"`
	ReleaseNotes     string  `json:"release_notes"`
	Status           string  `json:"status"`
	CanaryTenantIDs  []int64 `json:"canary_tenant_ids"`
	// MirrorState / MirrorError track copying an external package into the
	// platform object store (Repository.ReplaceStorage).
	MirrorState string `json:"mirror_state"`
	MirrorError string `json:"mirror_error,omitempty"`
	// ShareCode / ShareURL / ShareExpiresAt are the PaaS drive share link
	// standing in for a CDN (plan §2.1): generated by the Bus for published
	// object-store packages, cleared whenever the package changes.
	ShareCode      string     `json:"share_code"`
	ShareURL       string     `json:"share_url"`
	ShareExpiresAt *time.Time `json:"share_expires_at,omitempty"`
	PublishedAt    *time.Time `json:"published_at,omitempty"`
	CreatedBy      *int64     `json:"created_by,omitempty"`
	UpdatedBy      *int64     `json:"updated_by,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`

	// AutoSynced is derived from ContractCheckRef (AutoSyncRefPrefix), not stored.
	AutoSynced bool `json:"auto_synced"`
}

// IsAutoSyncRef reports whether ref marks a row recorded by the auto sync.
func IsAutoSyncRef(ref string) bool {
	return strings.HasPrefix(strings.TrimSpace(ref), AutoSyncRefPrefix)
}

// HasPackage reports whether a package has been uploaded (or an external URL set).
func (v Version) HasPackage() bool {
	return v.StorageURI != "" && v.FileSizeBytes > 0 && v.SHA256 != ""
}

// IsExternalPackage reports whether the package is served from an external
// https address rather than the platform object store.
func (v Version) IsExternalPackage() bool {
	return strings.HasPrefix(v.StorageURI, "https://")
}

// IsObjectStorePackage reports whether the package lives in the platform
// object store (oss://), i.e. is served through the Bus redirect, the CDN
// or a share link rather than an external address.
func (v Version) IsObjectStorePackage() bool {
	return strings.HasPrefix(v.StorageURI, "oss://")
}

// IsPublished reports whether the row is visible to catalogs.
func (v Version) IsPublished() bool {
	switch v.Status {
	case StatusCanary, StatusCurrent, StatusPrevious:
		return true
	default:
		return false
	}
}

// ShareLinkRemaining is how long the share link stays valid from now; zero
// when there is none or it has expired.
func (v Version) ShareLinkRemaining(now time.Time) time.Duration {
	if v.ShareURL == "" || v.ShareExpiresAt == nil {
		return 0
	}
	if remaining := v.ShareExpiresAt.Sub(now); remaining > 0 {
		return remaining
	}
	return 0
}

// IsDesktop reports whether the target installs an application bundle.
func (v Version) IsDesktop() bool {
	return v.TargetID == TargetCodexDesktop || v.TargetID == TargetClaudeDesktop
}

// UpsertInput carries the Admin-editable fields (package fields are set by
// UploadPackage, status by Publish / Deprecate).
type UpsertInput struct {
	TargetID         string
	Platform         string
	Arch             string
	Version          string
	Layout           string
	Member           string
	BinarySHA256     string
	BundleIdentifier string
	TeamIdentifier   string
	MinBridgeVersion string
	MinAppVersion    string
	ProfileVersion   string
	ContractCheckRef string
	ReleaseNotes     string
	// ExternalURL, when set, records a publicly hosted package (e.g. CDN)
	// instead of an uploaded one; size and sha256 must then be given too.
	ExternalURL   string
	FileSizeBytes int64
	SHA256        string
	ActorID       int64
}

// ShareLinkInput is a freshly generated share link (Repository.SetShareLink).
type ShareLinkInput struct {
	Code      string
	URL       string
	ExpiresAt time.Time
}

// PackageInput is what UploadPackage records after a successful upload.
type PackageInput struct {
	StorageURI    string
	FileSizeBytes int64
	SHA256        string
	ActorID       int64
}

type Filter struct {
	TargetID string
	Platform string
	Arch     string
	Status   string
	Keyword  string
	Limit    int
	Offset   int
}

// PublishInput is the state transition request.
type PublishInput struct {
	Mode      string
	TenantIDs []int64
	ActorID   int64
}

type Repository interface {
	List(ctx context.Context, f Filter) ([]Version, int64, error)
	GetByUUID(ctx context.Context, uuid string) (*Version, error)
	Create(ctx context.Context, in UpsertInput) (*Version, error)
	Update(ctx context.Context, uuid string, in UpsertInput) (*Version, error)
	SetPackage(ctx context.Context, uuid string, in PackageInput) (*Version, error)
	// Publish applies the transition atomically: canary → status=canary with
	// tenant list (rejecting overlap with other canaries of the same key);
	// current → demote the existing current to previous and the existing
	// previous to deprecated, then promote this row.
	Publish(ctx context.Context, uuid string, in PublishInput) (*Version, error)
	Deprecate(ctx context.Context, uuid string, actorID int64) (*Version, error)
	Delete(ctx context.Context, uuid string, actorID int64) error
	// SetMirrorState records the progress of copying an external package into
	// the object store; message is the operator-facing failure reason.
	SetMirrorState(ctx context.Context, uuid, state, message string) error
	// ReplaceStorage points the row at the object store copy of the same
	// bytes: it only applies when sizeBytes / sha256 equal the row's, in any
	// status (the content does not change), and marks the mirror done.
	ReplaceStorage(ctx context.Context, uuid, storageURI string, sizeBytes int64, sha256 string, actorID int64) (*Version, error)
	// ResetRunningMirrors marks every row still at mirror_state=running as
	// failed with message and returns how many it touched. A copy lives in
	// the memory of the Admin process that started it, so rows left at
	// running after that process died would stay there forever; Admin
	// clears them at startup.
	ResetRunningMirrors(ctx context.Context, message string) (int64, error)
	// VersionEverRecorded reports whether the exact version was ever recorded
	// for the key, deleted rows included: the auto sync must not bring back a
	// version an operator removed.
	VersionEverRecorded(ctx context.Context, targetID, platform, arch, version string) (bool, error)
	// TryAutoSyncLock takes the cross-process lock of one auto sync round
	// without waiting; release must be called when acquired is true.
	TryAutoSyncLock(ctx context.Context) (release func(), acquired bool, err error)
	// ListActive returns every canary / current / previous row for the
	// platform + arch (plus universal), newest first, for catalog resolution.
	ListActive(ctx context.Context, platform, arch string) ([]Version, error)
	// ListShareRefreshCandidates returns published object-store rows whose
	// share link is missing or expires before `before`, soonest expiry
	// first (missing links first), at most limit rows.
	ListShareRefreshCandidates(ctx context.Context, before time.Time, limit int) ([]Version, error)
	// SetShareLink records a generated share link on the row.
	SetShareLink(ctx context.Context, uuid string, in ShareLinkInput) error
}

func ValidTarget(v string) bool {
	switch v {
	case TargetCodexCLI, TargetClaudeCLI, TargetCodexDesktop, TargetClaudeDesktop, TargetClaudeCodeHost:
		return true
	default:
		return false
	}
}

func ValidPlatform(v string) bool {
	return v == PlatformMacOS || v == PlatformWindows
}

func ValidArch(v string) bool {
	return v == ArchArm64 || v == ArchX64 || v == ArchUniversal
}

func ValidLayout(v string) bool {
	switch v {
	case LayoutTarballSingle, LayoutTarballMember, LayoutTarballTree, LayoutBareBinary, LayoutAppBundleZip,
		LayoutAppBundleDMG, LayoutMSIX, LayoutHostBinaryNPMTgz, LayoutHostBundleTarZst:
		return true
	default:
		return false
	}
}

func ValidStatus(v string) bool {
	switch v {
	case StatusDraft, StatusCanary, StatusCurrent, StatusPrevious, StatusDeprecated:
		return true
	default:
		return false
	}
}
