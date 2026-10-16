package install

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const (
	ModeInstall = "install"
	ModeRepair  = "repair"
	// ModeComponent installs a runtime component the application needs
	// (M3 Task 8: Claude Desktop's Claude Code host bundle).
	ModeComponent = "component"

	StagePreflight   = "preflight"
	StageAuthorizing = "authorizing"
	StageDownloading = "downloading"
	StageVerifying   = "verifying"
	StageInstalling  = "installing"
	StageDetecting   = "detecting"

	IssueUnsupportedOS        = "UNSUPPORTED_OS"
	IssueUnsupportedArch      = "UNSUPPORTED_ARCH"
	IssueInsufficientDisk     = "INSUFFICIENT_DISK"
	IssueTargetDirNotWritable = "TARGET_DIR_NOT_WRITABLE"
	IssueTargetConflict       = "TARGET_CONFLICT"
	// IssueAdminRequired: the package needs an administrator to register and
	// this account cannot elevate (Windows desktop targets, M3-W).
	IssueAdminRequired             = "ADMIN_REQUIRED"
	installLocationKindUserHom     = "user_home"
	installLocationKindWindowsApps = "windows_apps"

	planTTL            = 2 * time.Minute
	requiredFreeFactor = 3
	applicationSupport = "cn.qkfintech.zhiban"
)

var (
	ErrInvalidInput = errors.New("install: invalid input")
)

// DetectFunc runs a fresh detection for a target.
type DetectFunc func(context.Context, string) (detect.State, error)

// ManagerConfig wires the installer into the Bridge process.
type ManagerConfig struct {
	HomeDir       string
	Arch          string
	BridgeVersion string
	Assets        []Asset
	AllowedHosts  []string
	Transport     http.RoundTripper
	Detect        DetectFunc
	Operations    *operation.Registry
	OSVersion     func() (string, error)
	FreeBytes     func(string) (uint64, error)
	Writable      func(string) bool
	Now           func() time.Time
	Random        io.Reader
	// SourceFilter optionally restricts which sources are attempted (tests and
	// the real-download smoke use it to pin one source).
	SourceFilter func(Source) bool
	// ProbeWindow bounds the pre-download source speed race (tests shorten it).
	ProbeWindow time.Duration
	// SystemApplicationsDir is where desktop bundles go when the user may write
	// to it (default /Applications); otherwise ~/Applications is used.
	SystemApplicationsDir string
	// BundleTools override the system operations bundle installation uses.
	BundleTools BundleTools
	// ResolveInstallation binds an installation id to its real path; component
	// installs (M3 Task 8) need the Claude Desktop bundle path to read the
	// pinned host manifest. Optional: without it PlanComponent is refused.
	ResolveInstallation ResolveInstallationFunc
	// ReadHostManifest reads the pinned Claude Code host manifest from a Claude
	// Desktop bundle (default: claudecode.ReadEmbeddedManifest).
	ReadHostManifest ReadHostManifestFunc
	// HostNPMRegistry and NPMRegistryKeys let the Bridge derive the host
	// tarball for a version with no pin from the registry's signed package
	// document (host_npm_derived.go; defaults DefaultHostNPMRegistry and
	// DefaultNPMRegistryKeys). HostVersion runs a staged derived executable
	// with --version (default: an isolated exec).
	HostNPMRegistry string
	NPMRegistryKeys map[string]string
	HostVersion     func(ctx context.Context, executable string) (string, error)
	// EnsureShellResolves makes the user's own login shell resolve the managed
	// launcher (ModeAdopt only; internal/shellpath). Without it an adopt is
	// refused: leaving the launcher pointing at Zhiban's copy while the user's
	// terminal still runs an npm one would break that terminal as soon as
	// Zhiban writes its configuration.
	EnsureShellResolves EnsureShellResolvesFunc
	// Platform names the catalog platform this Bridge runs on (default macos).
	Platform string
	// CatalogKeys returns the trusted catalog signing keys of an environment
	// (default: catalog.PublicKeys). CatalogStore persists the applied
	// catalog across Bridge processes; nil keeps it in memory only.
	CatalogKeys  func(environment string) map[string]string
	CatalogStore *catalog.Store
}

// Requirements is the requirements.get result.
type Requirements struct {
	TargetID            string   `json:"target_id"`
	Version             string   `json:"version"`
	Platform            string   `json:"platform"`
	Arch                string   `json:"arch"`
	MinOS               string   `json:"min_os"`
	OSVersion           string   `json:"os_version"`
	DownloadSizeBytes   int64    `json:"download_size_bytes"`
	RequiredFreeBytes   int64    `json:"required_free_bytes"`
	AvailableFreeBytes  int64    `json:"available_free_bytes"`
	DownloadHost        string   `json:"download_host"`
	FallbackHosts       []string `json:"fallback_hosts"`
	InstallLocationKind string   `json:"install_location_kind"`
	Satisfied           bool     `json:"satisfied"`
	Issues              []string `json:"issues"`
}

// Plan is the install.plan result.
type Plan struct {
	PlanID   string `json:"plan_id"`
	TargetID string `json:"target_id"`
	Mode     string `json:"mode"`
	// Component is set for component installs (mode "component", M3 Task 8).
	Component string `json:"component,omitempty"`
	Version   string `json:"version"`
	Source    string `json:"source"`
	// Origin says where Version comes from: builtin (compiled-in manifest),
	// catalog (signed platform catalog) or local (a retained version already
	// on disk; rollback only, nothing is downloaded).
	Origin string `json:"origin,omitempty"`
	// FromVersion is the installed version an upgrade or rollback starts from.
	FromVersion string `json:"from_version,omitempty"`
	// Local is set when the plan downloads nothing (rollback to a retained version).
	Local bool `json:"local,omitempty"`
	// PublisherAutoUpdateMayOverride flags desktop upgrades and rollbacks:
	// the publisher's own updater may move the bundle again afterwards.
	PublisherAutoUpdateMayOverride bool     `json:"publisher_auto_update_may_override,omitempty"`
	DownloadHost                   string   `json:"download_host"`
	FallbackHosts                  []string `json:"fallback_hosts"`
	DownloadSizeBytes              int64    `json:"download_size_bytes"`
	SHA256                         string   `json:"sha256"`
	ExpiresAt                      string   `json:"expires_at"`
}

// Result is the succeeded envelope payload.
type Result struct {
	ToolState detect.State `json:"tool_state"`
	// PreviousVersion is the version an upgrade or rollback moved away from.
	PreviousVersion string `json:"previous_version,omitempty"`
	// RetainedVersions lists the superseded CLI versions still on disk after
	// an upgrade or rollback (newest first; at most retainedOldVersions).
	RetainedVersions []string `json:"retained_versions,omitempty"`
	// PublisherAutoUpdateMayOverride mirrors the plan flag for desktop targets.
	PublisherAutoUpdateMayOverride bool `json:"publisher_auto_update_may_override,omitempty"`
}

type pendingPlan struct {
	public    Plan
	asset     Asset
	component *componentPlan
	expiresAt time.Time
	// fromVersion / local carry the upgrade or rollback selection.
	fromVersion string
	local       bool
}

type layout struct {
	// baseDir is the absolute directory targetDir is relative to (the home
	// directory for CLIs, the parent of the Applications folder for bundles).
	baseDir   string
	targetDir []string
	fileName  string
	// unitDir/unitName name the directory a package tree is installed as a
	// unit (Codex: ~/.codex/packages/standalone/<version>) and unitExecutable
	// is the "/"-separated path of the locked executable inside it; only set
	// for targets whose sources may use LayoutTarballTree.
	unitDir        []string
	unitName       string
	unitExecutable string
	// linkDir/linkName are relative to the home directory and only set for CLIs.
	linkDir      []string
	linkName     string
	locationKind string
	bundle       bool
}

func (l layout) finalPath() string {
	return filepath.Join(append([]string{l.baseDir}, append(l.targetDir, l.fileName)...)...)
}

// Manager implements requirements.get, install.plan and install.execute.
type Manager struct {
	homeDir             string
	arch                string
	assets              map[string]Asset
	detect              DetectFunc
	operations          *operation.Registry
	client              *downloadClient
	osVersion           func() (string, error)
	freeBytes           func(string) (uint64, error)
	writable            func(string) bool
	now                 func() time.Time
	random              io.Reader
	filter              func(Source) bool
	prepareRegistration func(context.Context, *operation.Reporter, Asset, string, string) (packageRegistration, error)

	systemApplicationsDir string
	ensureShellResolves   EnsureShellResolvesFunc
	bundleTools           BundleTools
	resolveInstallation   ResolveInstallationFunc
	readHostManifest      ReadHostManifestFunc
	hostNPMRegistry       string
	npmRegistryKeys       map[string]string
	hostVersion           func(ctx context.Context, executable string) (string, error)

	platform     string
	catalogKeys  func(environment string) map[string]string
	catalogStore *catalog.Store
	catalogMu    sync.RWMutex
	catalog      *catalogState

	mu    sync.Mutex
	plans map[string]pendingPlan
}

// NewManager validates config and builds a Manager.
func NewManager(config ManagerConfig) (*Manager, error) {
	homeDir := filepath.Clean(strings.TrimSpace(config.HomeDir))
	if homeDir == "." || !filepath.IsAbs(homeDir) || (config.Arch != ArchARM64 && config.Arch != ArchX64) ||
		config.Detect == nil || config.Operations == nil || len(config.Assets) == 0 {
		return nil, ErrInvalidInput
	}
	platform := strings.TrimSpace(config.Platform)
	if platform == "" {
		platform = PlatformMacOS
	}
	assets := make(map[string]Asset, 4)
	for _, asset := range config.Assets {
		if err := asset.Validate(); err != nil {
			return nil, err
		}
		if asset.Arch != config.Arch || asset.PlatformName() != platform {
			continue
		}
		if _, duplicate := assets[asset.TargetID]; duplicate {
			return nil, ErrInvalidManifest
		}
		assets[asset.TargetID] = asset
	}
	allowedHosts := config.AllowedHosts
	if len(allowedHosts) == 0 {
		allowedHosts = DefaultAllowedHosts()
	}
	userAgent := "zhiban-local-bridge/" + strings.TrimSpace(config.BridgeVersion)
	if strings.TrimSpace(config.BridgeVersion) == "" {
		userAgent = "zhiban-local-bridge"
	}
	manager := &Manager{
		homeDir: homeDir, arch: config.Arch, assets: assets, detect: config.Detect, operations: config.Operations,
		client:    newDownloadClient(config.Transport, allowedHosts, userAgent),
		osVersion: config.OSVersion, freeBytes: config.FreeBytes, writable: config.Writable,
		now: config.Now, random: config.Random, filter: config.SourceFilter, plans: make(map[string]pendingPlan),
		systemApplicationsDir: filepath.Clean(strings.TrimSpace(config.SystemApplicationsDir)),
		bundleTools:           config.BundleTools.withDefaults(),
		prepareRegistration:   preparePackageRegistration,
		ensureShellResolves:   config.EnsureShellResolves,
		resolveInstallation:   config.ResolveInstallation,
		readHostManifest:      config.ReadHostManifest,
		hostNPMRegistry:       strings.TrimSpace(config.HostNPMRegistry),
		npmRegistryKeys:       config.NPMRegistryKeys,
		hostVersion:           config.HostVersion,
		platform:              platform,
		catalogKeys:           config.CatalogKeys,
		catalogStore:          config.CatalogStore,
	}
	if manager.catalogKeys == nil {
		manager.catalogKeys = catalog.PublicKeys
	}
	if manager.readHostManifest == nil {
		manager.readHostManifest = claudecode.ReadEmbeddedManifest
	}
	if manager.hostNPMRegistry == "" {
		manager.hostNPMRegistry = DefaultHostNPMRegistry
	}
	if manager.npmRegistryKeys == nil {
		manager.npmRegistryKeys = DefaultNPMRegistryKeys()
	}
	if manager.hostVersion == nil {
		manager.hostVersion = defaultHostVersion
	}
	if manager.systemApplicationsDir == "." || !filepath.IsAbs(manager.systemApplicationsDir) {
		manager.systemApplicationsDir = defaultSystemApplicationsDir
	}
	manager.client.probeWindow = config.ProbeWindow
	if manager.osVersion == nil {
		manager.osVersion = defaultOSVersion
	}
	if manager.freeBytes == nil {
		manager.freeBytes = defaultFreeBytes
	}
	if manager.writable == nil {
		manager.writable = defaultWritable
	}
	if manager.now == nil {
		manager.now = time.Now
	}
	if manager.random == nil {
		manager.random = rand.Reader
	}
	manager.loadStoredCatalog()
	return manager, nil
}

// Requirements implements requirements.get.
func (m *Manager) Requirements(_ context.Context, targetID string) (Requirements, error) {
	if !validTarget(targetID) {
		return Requirements{}, ErrInvalidInput
	}
	asset, ok := m.assetFor(targetID)
	if !ok {
		return Requirements{
			TargetID: targetID, Platform: m.platform, Arch: m.arch, MinOS: minOSVersion(),
			InstallLocationKind: installLocationKindUserHom, Satisfied: false, Issues: []string{IssueUnsupportedArch},
		}, nil
	}
	return m.requirements(asset), nil
}

// requirements reports the install-mode view, which is what requirements.get
// shows the user before a fresh install.
func (m *Manager) requirements(asset Asset) Requirements {
	return m.requirementsFor(asset, ModeInstall)
}

// requirementsFor evaluates the preconditions for mode. Repair expects the
// damaged binary to still occupy the locked path, so that alone is not a
// conflict there.
func (m *Manager) requirementsFor(asset Asset, mode string) Requirements {
	result := Requirements{
		TargetID: asset.TargetID, Version: asset.Version, Platform: m.platform, Arch: m.arch, MinOS: minOSVersion(),
		DownloadSizeBytes: asset.Primary().Size, RequiredFreeBytes: largestSourceSize(asset) * requiredFreeFactor,
		DownloadHost: asset.Host(), FallbackHosts: asset.FallbackHosts(),
		InstallLocationKind: installLocationKindUserHom, Issues: []string{},
	}
	paths := m.layoutFor(asset)
	if paths.locationKind != "" {
		result.InstallLocationKind = paths.locationKind
	}
	if version, err := m.osVersion(); err == nil {
		result.OSVersion = version
		if !osVersionSupported(version) {
			result.Issues = append(result.Issues, IssueUnsupportedOS)
		}
	} else {
		result.Issues = append(result.Issues, IssueUnsupportedOS)
	}
	if free, err := m.freeBytes(m.homeDir); err == nil {
		if free > uint64(1<<62) {
			free = 1 << 62
		}
		result.AvailableFreeBytes = int64(free)
		if int64(free) < result.RequiredFreeBytes {
			result.Issues = append(result.Issues, IssueInsufficientDisk)
		}
	} else {
		result.Issues = append(result.Issues, IssueInsufficientDisk)
	}
	writable := m.ancestorWritable(m.homeDir, m.downloadDirParts())
	if paths.locationKind != installLocationKindWindowsApps && !m.ancestorWritable(paths.baseDir, paths.targetDir) {
		// App packages are written by the OS, never by the Bridge.
		writable = false
	}
	if len(paths.linkDir) > 0 && !m.ancestorWritable(m.homeDir, paths.linkDir) {
		writable = false
	}
	if !writable {
		result.Issues = append(result.Issues, IssueTargetDirNotWritable)
	}
	if (asset.RequiresElevation || (asset.PlatformName() == PlatformWindows && asset.IsBundle())) && !canElevate() {
		result.Issues = append(result.Issues, IssueAdminRequired)
	}
	if m.hasConflict(asset, paths, mode) {
		result.Issues = append(result.Issues, IssueTargetConflict)
	}
	result.Satisfied = len(result.Issues) == 0
	return result
}

// Plan implements install.plan.
func (m *Manager) Plan(ctx context.Context, targetID, mode string) (Plan, error) {
	if !validTarget(targetID) {
		return Plan{}, ErrInvalidInput
	}
	if mode == "" {
		mode = ModeInstall
	}
	if !validMode(mode) {
		return Plan{}, ErrInvalidInput
	}
	if m.operations.Running(targetID) {
		return Plan{}, operation.Fail(operationCode(targetID, "BUSY"), nil)
	}
	chosen, err := m.selectAsset(ctx, targetID, mode)
	if err != nil {
		return Plan{}, err
	}
	asset := chosen.asset
	if requirements := m.requirementsFor(asset, mode); !requirements.Satisfied {
		return Plan{}, operation.Fail(installCode(targetID, "REQUIREMENTS_UNMET"), errors.New(strings.Join(requirements.Issues, ",")))
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneLocked()
	planID, err := m.newPlanIDLocked()
	if err != nil {
		return Plan{}, err
	}
	expiresAt := m.now().UTC().Add(planTTL)
	public := Plan{
		PlanID: planID, TargetID: targetID, Mode: mode, Version: asset.Version, Source: asset.Source,
		Origin: chosen.origin, FromVersion: chosen.fromVersion, Local: chosen.local,
		PublisherAutoUpdateMayOverride: asset.IsBundle() && switchingMode(mode),
		DownloadHost:                   asset.Host(), FallbackHosts: asset.FallbackHosts(),
		DownloadSizeBytes: asset.Primary().Size, SHA256: asset.Primary().SHA256,
		ExpiresAt: expiresAt.Format(time.RFC3339),
	}
	m.plans[planID] = pendingPlan{
		public: public, asset: asset, expiresAt: expiresAt, fromVersion: chosen.fromVersion, local: chosen.local,
	}
	return public, nil
}

func validMode(mode string) bool {
	return mode == ModeInstall || mode == ModeRepair || mode == ModeUpgrade || mode == ModeRollback || mode == ModeAdopt
}

// EnsureShellResolvesFunc makes the user's login shell resolve commandName at
// launcherPath, and reports why it could not.
type EnsureShellResolvesFunc func(ctx context.Context, commandName, launcherPath string) error

// switchingMode reports whether mode moves an installed tool between versions.
// Adopt counts: it places a version beside whatever is there and re-points the
// launcher at it, exactly like an upgrade does.
func switchingMode(mode string) bool {
	return mode == ModeUpgrade || mode == ModeRollback || mode == ModeAdopt
}

// selection is the asset a plan installs plus how it was chosen.
type selection struct {
	asset       Asset
	fromVersion string
	local       bool
	origin      string
}

// selectAsset runs a fresh detection and picks the asset for mode: the
// catalog's current (else built-in) version for install and repair, the
// catalog's newer current for upgrade, and the rollback candidate for
// rollback. It fails with the contract code when mode does not apply.
func (m *Manager) selectAsset(ctx context.Context, targetID, mode string) (selection, error) {
	state, err := m.detect(ctx, targetID)
	if err != nil {
		return selection{}, operation.Fail(installCode(targetID, "DETECT_MISMATCH"), err)
	}
	var chosen selection
	switch mode {
	case ModeInstall, ModeRepair:
		asset, ok := m.assetFor(targetID)
		if !ok {
			return selection{}, operation.Fail(installCode(targetID, "UNSUPPORTED_ARCH"), nil)
		}
		chosen = selection{asset: asset, origin: originOf(asset)}
	case ModeUpgrade:
		if !installedOfficial(state) {
			return selection{}, operation.Fail(installCode(targetID, "NOT_UPGRADABLE"), nil)
		}
		entry, ok := m.catalogEntry(targetID)
		if !ok || catalog.CompareVersions(entry.current.Version, state.InstalledVersion) <= 0 {
			return selection{}, operation.Fail(installCode(targetID, "NOT_UPGRADABLE"), nil)
		}
		chosen = selection{asset: entry.current, fromVersion: state.InstalledVersion, origin: OriginCatalog}
	case ModeAdopt:
		asset, ok := m.adoptAsset(targetID, state)
		if !ok {
			return selection{}, operation.Fail(installCode(targetID, "NOT_ADOPTABLE"), nil)
		}
		chosen = selection{asset: asset, fromVersion: state.InstalledVersion, origin: originOf(asset)}
	case ModeRollback:
		if !installedOfficial(state) {
			return selection{}, operation.Fail(installCode(targetID, "NOT_ROLLBACKABLE"), nil)
		}
		candidate, ok := m.rollbackCandidate(targetID, state.InstalledVersion)
		if !ok {
			return selection{}, operation.Fail(installCode(targetID, "NOT_ROLLBACKABLE"), nil)
		}
		chosen = selection{asset: candidate.asset, fromVersion: state.InstalledVersion, local: candidate.local, origin: originOf(candidate.asset)}
		if candidate.local {
			chosen.origin = OriginLocal
		}
	default:
		return selection{}, ErrInvalidInput
	}
	if err := m.checkState(state, chosen, mode); err != nil {
		return selection{}, err
	}
	return chosen, nil
}

// Execute implements install.execute: it consumes the plan and starts the
// download/verify/install/detect operation.
func (m *Manager) Execute(ctx context.Context, planID string) (operation.Envelope, error) {
	if strings.TrimSpace(planID) == "" || len(planID) > 128 {
		return operation.Envelope{}, ErrInvalidInput
	}
	m.mu.Lock()
	plan, ok := m.plans[planID]
	if ok {
		delete(m.plans, planID)
	}
	m.mu.Unlock()
	if !ok || m.now().After(plan.expiresAt) {
		return operation.Envelope{}, operation.Fail("LCT-BRIDGE-OPERATION-NOT_FOUND", nil)
	}
	targetID := plan.public.TargetID
	scratch := &scratchFile{}
	envelope, err := m.operations.Start(operation.Spec{
		TargetID: targetID, Kind: operation.KindInstall, InitialStage: StagePreflight, Cancellable: true,
		CancelCode: installCode(targetID, "SYSTEM_CANCELLED"), FailureCode: installCode(targetID, "DOWNLOAD_FAILED"),
		Run: func(ctx context.Context, report *operation.Reporter) (any, error) {
			return m.run(ctx, report, plan, scratch)
		},
		Cleanup: scratch.remove,
	})
	if err != nil {
		if errors.Is(err, operation.ErrBusy) {
			return operation.Envelope{}, operation.Fail(operationCode(targetID, "BUSY"), nil)
		}
		return operation.Envelope{}, err
	}
	return envelope, nil
}

type scratchFile struct {
	mu   sync.Mutex
	path string
}

func (s *scratchFile) set(path string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.path = path
}

func (s *scratchFile) remove() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.path != "" {
		_ = os.Remove(s.path)
		s.path = ""
	}
}

func (m *Manager) run(ctx context.Context, report *operation.Reporter, plan pendingPlan, scratch *scratchFile) (any, error) {
	if plan.component != nil {
		return m.runComponent(ctx, report, plan, scratch)
	}
	asset := plan.asset
	targetID := asset.TargetID
	mode := plan.public.Mode
	chosen := selection{asset: asset, fromVersion: plan.fromVersion, local: plan.local}
	report.Stage(StagePreflight, true)
	if err := m.checkInstallable(ctx, chosen, mode); err != nil {
		return nil, err
	}
	if requirements := m.requirementsFor(asset, mode); !requirements.Satisfied {
		return nil, operation.Fail(installCode(targetID, "REQUIREMENTS_UNMET"), nil)
	}
	paths := m.layoutFor(asset)
	finalPath := paths.finalPath()

	if plan.local {
		// Rollback to a retained version: the executable already sits at its
		// locked path, only the launcher link moves.
		report.Stage(StageVerifying, true)
		if err := verifyLocalExecutable(finalPath, asset.BinarySHA256); err != nil {
			return nil, m.mapPlaceError(targetID, err)
		}
		report.Stage(StageInstalling, false)
		return m.switchLink(ctx, report, plan, paths)
	}
	if !asset.IsBundle() && m.versionPlaced(asset, finalPath) {
		// The target version is still on disk from an earlier run: a rollback
		// followed by a re-upgrade, or an install / adopt that placed the
		// version and was then cut off before the launcher, the PATH or the
		// detection that follows (2026-09-18 Windows: the App's RPC timed out
		// during the first adopt, the retry then met its own version directory
		// and reported it as a conflict). Reuse it instead of downloading.
		report.Stage(StageInstalling, false)
		if switchingMode(mode) {
			return m.switchLink(ctx, report, plan, paths)
		}
		return m.finishExecutable(ctx, report, plan, paths)
	}

	downloads, err := openDirectoryChain(m.homeDir, m.downloadDirParts(), true, 0o700)
	if err != nil {
		return nil, operation.Fail(installCode(targetID, "DOWNLOAD_FAILED"), err)
	}
	temporary, temporaryName, err := createTemporaryAt(downloads, targetID+"-")
	_ = downloads.Close()
	if err != nil {
		return nil, operation.Fail(installCode(targetID, "DOWNLOAD_FAILED"), err)
	}
	scratch.set(temporary.Name())
	defer temporary.Close()
	_ = temporaryName

	registration, err := m.prepareRegistration(ctx, report, asset, temporary.Name()+".msix", mode)
	if err != nil {
		return nil, err
	}
	if registration != nil {
		defer registration.Close()
	}

	// Sources are raced for a few seconds and then tried fastest-first. A
	// source that cannot be reached is skipped; a source that answers with the
	// wrong size or hash stops the install, because that is either tampering
	// or a stale lock, never a network issue.
	report.Progress(StageDownloading, 0, true)
	candidates := make([]Source, 0, len(asset.Sources))
	for _, candidate := range asset.Sources {
		if m.filter == nil || m.filter(candidate) {
			candidates = append(candidates, candidate)
		}
	}
	candidates = m.client.rankSources(ctx, candidates)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	var source Source
	var lastErr error
	downloaded := false
	for _, candidate := range candidates {
		if err := temporary.Truncate(0); err != nil {
			return nil, operation.Fail(installCode(targetID, "DOWNLOAD_FAILED"), err)
		}
		if _, err := temporary.Seek(0, io.SeekStart); err != nil {
			return nil, operation.Fail(installCode(targetID, "DOWNLOAD_FAILED"), err)
		}
		report.Progress(StageDownloading, 0, true)
		err := m.client.fetch(ctx, candidate, temporary, func(percent int) {
			report.Progress(StageDownloading, percent, true)
		})
		if err == nil {
			source = candidate
			downloaded = true
			break
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if errors.Is(err, errDownloadFailed) {
			lastErr = err
			continue
		}
		return nil, m.mapDownloadError(ctx, targetID, err)
	}
	if !downloaded {
		return nil, operation.Fail(installCode(targetID, "DOWNLOAD_FAILED"), lastErr)
	}

	report.Stage(StageVerifying, true)
	if err := verifyFile(ctx, temporary, source); err != nil {
		return nil, m.mapDownloadError(ctx, targetID, err)
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	report.Stage(StageInstalling, false)
	if asset.IsBundle() && source.Layout == LayoutMSIX {
		// Windows app package: verified and registered by the OS, never
		// unpacked into a directory the Bridge owns. The signature interface
		// and the deployment API open the file without sharing writers, so
		// the download handle is closed first (2026-09-10 test machine:
		// "file in use by another process" → PUBLISHER_MISMATCH otherwise).
		_ = temporary.Close()
		return m.installPackage(ctx, report, plan, temporary.Name(), registration)
	}
	if source.Layout == LayoutTarballTree {
		// The whole package directory is the install unit (Codex):
		// extracted into a staging directory beside the version directory
		// and swapped in, see placeTree.
		if err := m.placeTreeFor(paths, temporary, source, asset.BinarySHA256, mode); err != nil {
			return nil, m.mapPlaceError(targetID, err)
		}
		return m.finishExecutable(ctx, report, plan, paths)
	}
	targetDir, err := openDirectoryChain(paths.baseDir, paths.targetDir, true, 0o755)
	if err != nil {
		return nil, operation.Fail(installCode(targetID, "CONFLICT"), err)
	}
	if asset.IsBundle() {
		placeErr := m.placeBundle(ctx, targetDir, asset, temporary.Name(), source.Layout, mode)
		_ = targetDir.Close()
		if placeErr != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, m.mapPlaceError(targetID, placeErr)
		}
		result, err := m.detectInstalled(ctx, report, targetID, asset)
		if err != nil {
			if switchingMode(mode) && ctx.Err() == nil {
				return nil, operation.Fail(installCode(targetID, switchFailure(mode)), err)
			}
			return nil, err
		}
		if switchingMode(mode) {
			result.PreviousVersion = plan.fromVersion
			result.PublisherAutoUpdateMayOverride = true
		}
		return result, nil
	}
	// Placement never overwrites. Repair therefore moves the damaged binary
	// aside inside the same directory first, removes it once the verified
	// replacement is in place, and moves it back if placement fails so the
	// user is never left with nothing at the locked path. Upgrade and
	// rollback treat a leftover of the target version the same way.
	aside := ""
	if mode != ModeInstall {
		aside, err = moveAsideAt(targetDir, paths.fileName)
		if err != nil {
			if aside != "" {
				_ = secureRenameExclusiveAt(int(targetDir.Fd()), aside, int(targetDir.Fd()), paths.fileName)
			}
			_ = targetDir.Close()
			return nil, m.mapPlaceError(targetID, err)
		}
	}
	placeErr := m.place(targetDir, paths.fileName, temporary, source, asset.BinarySHA256)
	if aside != "" {
		if placeErr != nil {
			_ = secureRenameExclusiveAt(int(targetDir.Fd()), aside, int(targetDir.Fd()), paths.fileName)
		} else {
			_ = secureUnlinkAt(int(targetDir.Fd()), aside)
		}
		_ = secureFsync(int(targetDir.Fd()))
	}
	_ = targetDir.Close()
	if placeErr != nil {
		return nil, m.mapPlaceError(targetID, placeErr)
	}
	return m.finishExecutable(ctx, report, plan, paths)
}

// finishExecutable is the common tail of a CLI placement: an upgrade or
// rollback re-points the launcher, a fresh install or repair makes sure the
// launcher exists, then detection must recognise the placed version.
func (m *Manager) finishExecutable(ctx context.Context, report *operation.Reporter, plan pendingPlan, paths layout) (any, error) {
	asset := plan.asset
	targetID := asset.TargetID
	if switchingMode(plan.public.Mode) {
		return m.switchLink(ctx, report, plan, paths)
	}
	linkDir, err := openDirectoryChain(m.homeDir, paths.linkDir, true, 0o755)
	if err != nil {
		return nil, operation.Fail(installCode(targetID, "CONFLICT"), err)
	}
	linkErr := ensureLauncherAt(linkDir, paths.linkName, paths.finalPath())
	linkDirPath := linkDir.Name()
	_ = linkDir.Close()
	if linkErr != nil {
		return nil, m.mapPlaceError(targetID, linkErr)
	}
	// Windows: put the launcher directory on the user's PATH like the
	// publishers' installers do; never fatal, the managed launch runs the
	// launcher by absolute path.
	_ = registerLauncherDir(linkDirPath)
	result, err := m.detectInstalled(ctx, report, targetID, asset)
	if err != nil {
		return nil, err
	}
	return result, nil
}

// switchLink re-points ~/.local/bin/<tool> at the target version, confirms
// detection sees that version, and otherwise puts the previous link back and
// fails with the mode's code. On success superseded versions beyond the
// retention limit are removed.
func (m *Manager) switchLink(ctx context.Context, report *operation.Reporter, plan pendingPlan, paths layout) (any, error) {
	asset := plan.asset
	targetID := asset.TargetID
	finalPath := paths.finalPath()
	linkDir, err := openDirectoryChain(m.homeDir, paths.linkDir, true, 0o755)
	if err != nil {
		return nil, operation.Fail(installCode(targetID, "CONFLICT"), err)
	}
	previous, linkErr := replaceLauncherAt(linkDir, paths.linkName, finalPath)
	_ = linkDir.Close()
	if linkErr != nil {
		return nil, m.mapPlaceError(targetID, linkErr)
	}
	// Adopt is only finished when the user's own terminal runs this copy too.
	// Anything else and the next step — writing Zhiban's configuration — would
	// hand that terminal a file its old CLI cannot parse.
	if plan.public.Mode == ModeAdopt {
		if err := m.ensureShellPrefers(ctx, targetID, paths); err != nil {
			m.restoreLauncher(paths, previous)
			return nil, err
		}
	}
	result, err := m.detectInstalled(ctx, report, targetID, asset)
	if err != nil {
		m.restoreLauncher(paths, previous)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, operation.Fail(installCode(targetID, switchFailure(plan.public.Mode)), err)
	}
	if previous != "" {
		if linkDir, openErr := openDirectoryChain(m.homeDir, paths.linkDir, false, 0o755); openErr == nil {
			commitLauncher(linkDir, previous)
			_ = linkDir.Close()
		}
	}
	result.PreviousVersion = plan.fromVersion
	result.RetainedVersions = m.pruneRetained(targetID)
	return result, nil
}

func (m *Manager) restoreLauncher(paths layout, previous string) {
	if previous == "" {
		return
	}
	if linkDir, openErr := openDirectoryChain(m.homeDir, paths.linkDir, false, 0o755); openErr == nil {
		_ = restoreLauncherAt(linkDir, paths.linkName, previous)
		_ = linkDir.Close()
	}
}

// ensureShellPrefers arranges the user's login shell PATH so the managed
// launcher is what `codex` / `claude` runs there.
func (m *Manager) ensureShellPrefers(ctx context.Context, targetID string, paths layout) error {
	if m.ensureShellResolves == nil {
		return operation.Fail(installCode(targetID, "PATH_NOT_APPLIED"), nil)
	}
	name, err := targetCommandName(targetID)
	if err != nil {
		return operation.Fail(installCode(targetID, "PATH_NOT_APPLIED"), err)
	}
	linkPath := filepath.Join(append([]string{m.homeDir}, append(paths.linkDir, paths.linkName)...)...)
	if err := m.ensureShellResolves(ctx, name, linkPath); err != nil {
		return operation.Fail(installCode(targetID, "PATH_NOT_APPLIED"), err)
	}
	return nil
}

func targetCommandName(targetID string) (string, error) {
	switch targetID {
	case TargetCodexCLI:
		return "codex", nil
	case TargetClaudeCLI:
		return "claude", nil
	default:
		return "", ErrInvalidInput
	}
}

func switchFailure(mode string) string {
	switch mode {
	case ModeRollback:
		return "ROLLBACK_FAILED"
	case ModeAdopt:
		return "ADOPT_FAILED"
	default:
		return "UPGRADE_FAILED"
	}
}

// detectInstalled re-runs detection until the freshly placed installation is
// recognised as the locked official version.
func (m *Manager) detectInstalled(ctx context.Context, report *operation.Reporter, targetID string, asset Asset) (Result, error) {
	report.Stage(StageDetecting, false)
	// A freshly downloaded binary is scanned by macOS on its first launch,
	// which can exceed the 2 s version probe; retry a few times before
	// concluding the installation does not match.
	var state detect.State
	var err error
	for attempt := 0; attempt < 4; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return Result{}, ctx.Err()
			case <-time.After(time.Duration(attempt) * 2 * time.Second):
			}
		}
		state, err = m.detect(ctx, targetID)
		if err == nil && state.UIState == detect.UIStateInstalledUnmanaged && state.InstalledVersion == asset.Version &&
			state.InstallSource == detect.SourceOfficial {
			return Result{ToolState: state}, nil
		}
	}
	return Result{}, operation.Fail(installCode(targetID, "DETECT_MISMATCH"), err)
}

func (m *Manager) place(targetDir *os.File, fileName string, scratch *os.File, source Source, binarySHA256 string) error {
	if _, err := scratch.Seek(0, io.SeekStart); err != nil {
		return errHashMismatch
	}
	sink := func(content io.Reader, size int64) error {
		return writeRegularAt(targetDir, fileName, content, size, 0o755, binarySHA256)
	}
	switch source.Layout {
	case LayoutBareBinary:
		return sink(scratch, source.Size)
	case LayoutTarballSingle:
		return extractSingleExecutable(scratch, sink)
	case LayoutTarballMember:
		return extractMember(scratch, source.Member, sink)
	default:
		return ErrInvalidManifest
	}
}

func largestSourceSize(asset Asset) int64 {
	var largest int64
	for _, source := range asset.Sources {
		if source.Size > largest {
			largest = source.Size
		}
	}
	return largest
}

// checkInstallable re-runs detection right before the operation and applies
// the same gate as planning, so a state change between plan and execute is
// caught.
func (m *Manager) checkInstallable(ctx context.Context, chosen selection, mode string) error {
	state, err := m.detect(ctx, chosen.asset.TargetID)
	if err != nil {
		return operation.Fail(installCode(chosen.asset.TargetID, "DETECT_MISMATCH"), err)
	}
	return m.checkState(state, chosen, mode)
}

func (m *Manager) checkState(state detect.State, chosen selection, mode string) error {
	targetID := chosen.asset.TargetID
	switch mode {
	case ModeInstall:
		if state.UIState != detect.UIStateNotInstalled {
			return operation.Fail(installCode(targetID, "ALREADY_INSTALLED"), nil)
		}
	case ModeRepair:
		if state.UIState != detect.UIStateRepairable {
			return operation.Fail(installCode(targetID, "NOT_REPAIRABLE"), nil)
		}
	case ModeAdopt:
		if _, ok := m.adoptAsset(targetID, state); !ok {
			return operation.Fail(installCode(targetID, "NOT_ADOPTABLE"), nil)
		}
		if state.InstalledVersion != chosen.fromVersion {
			return operation.Fail(installCode(targetID, "DETECT_MISMATCH"), nil)
		}
	case ModeUpgrade, ModeRollback:
		reason := "NOT_UPGRADABLE"
		if mode == ModeRollback {
			reason = "NOT_ROLLBACKABLE"
		}
		if !installedOfficial(state) {
			return operation.Fail(installCode(targetID, reason), nil)
		}
		if state.InstalledVersion != chosen.fromVersion {
			// Something replaced the installation since the plan was made.
			return operation.Fail(installCode(targetID, "DETECT_MISMATCH"), nil)
		}
	default:
		return ErrInvalidInput
	}
	if chosen.asset.IsBundle() {
		if err := m.bundleInUse(chosen.asset, m.layoutFor(chosen.asset)); err != nil {
			return operation.Fail(installCode(targetID, inUseReason(err)), err)
		}
	}
	return nil
}

// inUseReason names a refusal of the running-application check: the target is
// running, or the check itself could not be made.
func inUseReason(err error) string {
	if errors.Is(err, errRunningCheckFailed) {
		return "RUNNING_CHECK_FAILED"
	}
	return "TARGET_IN_USE"
}

func (m *Manager) mapDownloadError(ctx context.Context, targetID string, err error) error {
	switch {
	case ctx.Err() != nil && (errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)):
		return ctx.Err()
	case errors.Is(err, errSizeMismatch):
		return operation.Fail(installCode(targetID, "SIZE_MISMATCH"), err)
	case errors.Is(err, errHashMismatch):
		return operation.Fail(installCode(targetID, "HASH_MISMATCH"), err)
	case errors.Is(err, errHostDenied):
		// The download URL (or a redirect it followed) is not https or its
		// host is outside the allow-list. This is a source problem, not a
		// signature one: reporting it as PUBLISHER_MISMATCH sent the
		// 2026-09-11 test-environment failure (Bus 302 to a plain-http
		// object store) down a codesign rabbit hole.
		return operation.Fail(installCode(targetID, "SOURCE_NOT_ALLOWED"), err)
	default:
		return operation.Fail(installCode(targetID, "DOWNLOAD_FAILED"), err)
	}
}

func (m *Manager) mapPlaceError(targetID string, err error) error {
	var failure *operation.Failure
	if errors.As(err, &failure) {
		return err
	}
	switch {
	case errors.Is(err, errPublisherMismatch):
		return operation.FailDetail(installCode(targetID, "PUBLISHER_MISMATCH"), bundleFailureDetail(err), err)
	case errors.Is(err, errTargetInUse), errors.Is(err, errRunningCheckFailed):
		return operation.Fail(installCode(targetID, inUseReason(err)), err)
	case errors.Is(err, errInstallCancelled):
		return operation.Fail(installCode(targetID, "SYSTEM_CANCELLED"), err)
	case errors.Is(err, errConflict), errors.Is(err, errUnsafePath):
		return operation.Fail(installCode(targetID, "CONFLICT"), err)
	case pathHeldByAnotherProcess(err):
		// Windows: a rename or delete refused while the security software
		// still holds the freshly placed files (ERROR_ACCESS_DENIED /
		// ERROR_SHARING_VIOLATION) is not a conflict with the user's own
		// files; the App's wording for CONFLICT sent 12800 testers hunting
		// for settings they never changed.
		return operation.Fail(installCode(targetID, "TARGET_IN_USE"), err)
	case errors.Is(err, errArchiveInvalid):
		return operation.FailDetail(installCode(targetID, "PUBLISHER_MISMATCH"), bundleFailureDetail(err), err)
	case errors.Is(err, errSizeMismatch):
		return operation.Fail(installCode(targetID, "SIZE_MISMATCH"), err)
	case errors.Is(err, errHashMismatch):
		return operation.Fail(installCode(targetID, "HASH_MISMATCH"), err)
	default:
		return operation.Fail(installCode(targetID, "CONFLICT"), err)
	}
}

// versionPlaced reports whether the locked executable of asset already sits
// at finalPath with the locked hash and the rest of its package beside it.
func (m *Manager) versionPlaced(asset Asset, finalPath string) bool {
	return asset.BinarySHA256 != "" && verifyLocalExecutable(finalPath, asset.BinarySHA256) == nil && localVersionComplete(asset, finalPath)
}

// layoutFor mirrors the publishers' own installers so a Bridge install is
// indistinguishable from a native one: Codex keeps versions under
// ~/.codex/packages/standalone/<version>/bin, Claude Code under
// ~/.local/share/claude/versions/<version>, and both are launched through
// ~/.local/bin/<tool>. Windows adds .exe to the executable names, uses the
// same directories under %USERPROFILE%, and its launcher is a .cmd shim
// (launcher_windows.go).
func (m *Manager) layoutFor(asset Asset) layout {
	switch asset.TargetID {
	case TargetCodexCLI:
		return layout{
			baseDir:   m.homeDir,
			targetDir: []string{".codex", "packages", "standalone", asset.Version, "bin"}, fileName: executableFileName("codex"),
			unitDir: []string{".codex", "packages", "standalone"}, unitName: asset.Version, unitExecutable: "bin/" + executableFileName("codex"),
			linkDir: []string{".local", "bin"}, linkName: launcherFileName("codex"), locationKind: installLocationKindUserHom,
		}
	case TargetCodexDesktop, TargetClaudeDesktop:
		return m.bundleLayout(asset)
	default:
		return layout{
			baseDir:   m.homeDir,
			targetDir: []string{".local", "share", "claude", "versions"}, fileName: executableFileName(asset.Version),
			linkDir: []string{".local", "bin"}, linkName: launcherFileName("claude"), locationKind: installLocationKindUserHom,
		}
	}
}

func (m *Manager) downloadDirParts() []string {
	return platformDownloadDirParts()
}

// ancestorWritable finds the deepest existing component of parts under home
// and requires it to be a real, writable directory reached without symlinks.
func (m *Manager) ancestorWritable(baseDir string, parts []string) bool {
	current := baseDir
	for _, part := range parts {
		next := filepath.Join(current, part)
		info, err := os.Lstat(next)
		if err != nil {
			break
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return false
		}
		current = next
	}
	info, err := os.Lstat(current)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return false
	}
	return m.writable(current)
}

func (m *Manager) hasConflict(asset Asset, paths layout, mode string) bool {
	finalPath := paths.finalPath()
	if info, err := os.Lstat(finalPath); err == nil {
		// Install never replaces anything. Repair replaces the damaged
		// installation at the locked path (a regular file for a CLI, a bundle
		// directory for a desktop app); upgrade and rollback replace a
		// leftover of the target version or re-point at a retained one.
		// Anything of the wrong kind (a symlink, a directory for a CLI) is a
		// conflict in every mode.
		expectedKind := info.Mode().IsRegular()
		if paths.bundle {
			expectedKind = info.IsDir() && info.Mode()&os.ModeSymlink == 0
		}
		if !expectedKind {
			return true
		}
		// A fresh install only tolerates its own leftover: exactly the locked
		// version, complete, at the locked path (resumed, see Execute).
		if mode == ModeInstall && (paths.bundle || !m.versionPlaced(asset, finalPath)) {
			return true
		}
	}
	if paths.bundle {
		// The other names the publisher ships the bundle under are held to
		// the same rule (Codex Desktop: ChatGPT.app next to Codex.app).
		for _, alias := range asset.BundleAliases {
			info, err := os.Lstat(filepath.Join(filepath.Dir(finalPath), alias))
			if err == nil && (mode == ModeInstall || !info.IsDir() || info.Mode()&os.ModeSymlink != 0) {
				return true
			}
		}
	}
	if len(paths.linkDir) == 0 {
		return false
	}
	linkPath := filepath.Join(append([]string{m.homeDir}, append(paths.linkDir, paths.linkName)...)...)
	info, err := os.Lstat(linkPath)
	if err != nil {
		return false
	}
	if switchingMode(mode) {
		// The launcher is re-pointed: it only has to be a launcher (or absent).
		return !launcherKindOK(info)
	}
	return launcherConflicts(linkPath, finalPath)
}

func (m *Manager) pruneLocked() {
	now := m.now()
	for id, plan := range m.plans {
		if now.After(plan.expiresAt) {
			delete(m.plans, id)
		}
	}
}

func (m *Manager) newPlanIDLocked() (string, error) {
	for attempt := 0; attempt < 4; attempt++ {
		value := make([]byte, 32)
		if _, err := io.ReadFull(m.random, value); err != nil {
			return "", errors.Join(ErrInvalidInput, err)
		}
		id := base64.RawURLEncoding.EncodeToString(value)
		if _, exists := m.plans[id]; !exists {
			return id, nil
		}
	}
	return "", ErrInvalidInput
}

func validTarget(targetID string) bool {
	return targetID == TargetCodexCLI || targetID == TargetClaudeCLI || targetID == TargetCodexDesktop || targetID == TargetClaudeDesktop
}

func installCode(targetID, reason string) string {
	return "LCT-" + strings.ToUpper(targetID) + "-INSTALL-" + reason
}

func operationCode(targetID, reason string) string {
	return "LCT-" + strings.ToUpper(targetID) + "-OPERATION-" + reason
}
