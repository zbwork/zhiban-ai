package install

// Runtime components (M3 Task 8). Claude Desktop cannot run a single 3P chat
// turn until its pinned Claude Code host bundle sits in
// ~/Library/Application Support/Claude-3p/claude-code/<version>/. The app
// downloads that bundle itself from downloads.claude.ai on first use, which
// never succeeds on networks that cannot reach the host, so the Bridge
// provisions it: the pinned version and checksum come from the installed
// (signature-verified) Claude.app, the archive is fetched from the pinned base
// URL or — when that host is unreachable — from the pinned npmmirror tarball of
// the same executable (M3 Task 9), checked against the pinned size and hash,
// extracted into a hidden staging folder, verified against Anthropic's
// Developer ID requirement, and then renamed into place together with the
// .verified marker the app checks.

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const (
	installLocationKindClaudeSupport = "claude_desktop_support"
	componentStagingPrefix           = ".zhiban-stage-"
	// A host bundle expands to roughly three times its archive; keep the
	// archive, the extracted copy and headroom.
	componentRequiredFreeFactor = 5
)

// ResolveInstallationFunc binds an installation id to its real path.
type ResolveInstallationFunc func(context.Context, string, string) (detect.ResolvedInstallation, error)

// ReadHostManifestFunc reads the pinned host manifest from a Claude Desktop bundle.
type ReadHostManifestFunc func(bundlePath string) (claudecode.Manifest, error)

type componentPlan struct {
	componentID    string
	installationID string
	bundlePath     string
	manifest       claudecode.Manifest
	artifact       claudecode.Artifact
	// npmPin, when set, is the build-time pinned npmmirror tarball plus the
	// exact executable expected inside it (the second source).
	npmPin *HostNPMPin
	// sources are tried in order: the catalog copies then the official host
	// when the catalog lists this host version (catalogFirst, no speed race),
	// else the official host and the derived npmmirror tarball, ranked by a
	// short probe; source is the first one, for display.
	source       Source
	sources      []Source
	catalogFirst bool
	stale        bool
}

func componentFallbackHosts(component componentPlan) []string {
	hosts := []string{}
	for index, source := range component.sources {
		if index == 0 {
			continue
		}
		hosts = append(hosts, source.Host())
	}
	return hosts
}

// PlanComponent implements install.plan with a component: it checks that the
// installed Claude Desktop pins a host bundle the Bridge may fetch and that
// the component is not already present.
func (m *Manager) PlanComponent(ctx context.Context, targetID, componentID string) (Plan, error) {
	if targetID != TargetClaudeDesktop || componentID != claudecode.ComponentID || m.resolveInstallation == nil {
		return Plan{}, ErrInvalidInput
	}
	if m.operations.Running(targetID) {
		return Plan{}, operation.Fail(operationCode(targetID, "BUSY"), nil)
	}
	component, err := m.prepareComponent(ctx, targetID)
	if err != nil {
		return Plan{}, err
	}
	if requirements := m.componentRequirements(component); !requirements.Satisfied {
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
		PlanID: planID, TargetID: targetID, Mode: ModeComponent, Component: componentID,
		Version: component.manifest.Version, Source: SourceOfficialAnthropic,
		DownloadHost: component.source.Host(), FallbackHosts: componentFallbackHosts(component),
		DownloadSizeBytes: component.artifact.Size, SHA256: component.artifact.Checksum,
		ExpiresAt: expiresAt.Format(time.RFC3339),
	}
	m.plans[planID] = pendingPlan{public: public, component: &component, expiresAt: expiresAt}
	return public, nil
}

// prepareComponent resolves the installed Claude Desktop, reads the host
// manifest it pins and decides whether the component needs provisioning.
func (m *Manager) prepareComponent(ctx context.Context, targetID string) (componentPlan, error) {
	state, err := m.detect(ctx, targetID)
	if err != nil {
		return componentPlan{}, operation.Fail(installCode(targetID, "DETECT_MISMATCH"), err)
	}
	if state.UIState != detect.UIStateInstalledUnmanaged || state.InstallationID == "" {
		return componentPlan{}, operation.Fail(installCode(targetID, "NOT_INSTALLED"), nil)
	}
	resolved, err := m.resolveInstallation(ctx, targetID, state.InstallationID)
	if err != nil || resolved.RealPath == "" || !filepath.IsAbs(resolved.RealPath) {
		return componentPlan{}, operation.Fail(installCode(targetID, "DETECT_MISMATCH"), err)
	}
	manifest, err := m.readHostManifest(resolved.RealPath)
	if err != nil {
		if errors.Is(err, claudecode.ErrManifestUntrusted) {
			return componentPlan{}, operation.Fail(installCode(targetID, "COMPONENT_MANIFEST_UNTRUSTED"), err)
		}
		return componentPlan{}, operation.Fail(installCode(targetID, "COMPONENT_MANIFEST_UNREADABLE"), err)
	}
	// The bundle archive on macOS, the zstd stream of the bare executable on
	// Windows (claudecode host_*.go); .verified holds the artifact's checksum.
	artifact, ok := claudecode.HostArtifact(manifest, m.arch)
	if !ok {
		return componentPlan{}, operation.Fail(installCode(targetID, "UNSUPPORTED_ARCH"), nil)
	}
	source := Source{
		Kind: SourceKindOfficial, Layout: hostArtifactLayout,
		URL: claudecode.HostArtifactURL(manifest, m.arch), Size: artifact.Size, SHA256: artifact.Checksum,
	}
	if err := source.Validate(); err != nil {
		return componentPlan{}, operation.Fail(installCode(targetID, "COMPONENT_MANIFEST_UNTRUSTED"), err)
	}
	sources := []Source{source}
	// Host versions are managed in the signed catalog only (2026-09-15: no
	// build-time pins): platform-hosted copies of the exact pinned version
	// (Admin → object storage / CDN). See catalog_host.go. Like every other
	// catalog install they come first, in order and without a speed race; the
	// official host is only the fallback when all of them fail.
	var npmPin *HostNPMPin
	catalogSources := m.catalogHostSources(manifest.Version, artifact)
	if len(catalogSources) > 0 {
		sources = append(append([]Source{}, catalogSources...), source)
	}
	// Catalog has nothing for this host version (not uploaded yet, catalog not
	// fetched or expired): derive the npmmirror tarball from the npm registry's
	// signed package document (host_npm_derived.go).
	if len(catalogSources) == 0 {
		if pin, ok := m.derivedHostNPMPin(ctx, manifest.Version); ok {
			npmPin = &pin
			sources = append(sources, pin.Source)
		}
	}
	status := claudecode.Status(m.homeDir, manifest, m.arch)
	switch status.State {
	case claudecode.StatePresent:
		return componentPlan{}, operation.Fail(installCode(targetID, "ALREADY_INSTALLED"), nil)
	case claudecode.StateStale:
		// Replacing files under a running Claude Desktop races its own
		// download; the user has to quit it first.
		inUse, err := m.bundleTools.BundleInUse(resolved.RealPath)
		if err != nil {
			return componentPlan{}, operation.Fail(installCode(targetID, "RUNNING_CHECK_FAILED"), err)
		}
		if inUse {
			return componentPlan{}, operation.Fail(installCode(targetID, "TARGET_IN_USE"), nil)
		}
	}
	return componentPlan{
		componentID: claudecode.ComponentID, installationID: state.InstallationID, bundlePath: resolved.RealPath,
		manifest: manifest, artifact: artifact, npmPin: npmPin, source: sources[0], sources: sources,
		catalogFirst: len(catalogSources) > 0, stale: status.State == claudecode.StateStale,
	}, nil
}

// componentRequirements evaluates the preconditions for provisioning.
func (m *Manager) componentRequirements(component componentPlan) Requirements {
	result := Requirements{
		TargetID: TargetClaudeDesktop, Version: component.manifest.Version, Platform: m.platform, Arch: m.arch, MinOS: minOSVersion(),
		DownloadSizeBytes: component.artifact.Size, RequiredFreeBytes: component.artifact.Size * componentRequiredFreeFactor,
		DownloadHost: component.source.Host(), FallbackHosts: componentFallbackHosts(component),
		InstallLocationKind: installLocationKindClaudeSupport, Issues: []string{},
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
	if !m.ancestorWritable(m.homeDir, claudecode.StorageDirParts()) || !m.ancestorWritable(m.homeDir, m.downloadDirParts()) {
		result.Issues = append(result.Issues, IssueTargetDirNotWritable)
	}
	result.Satisfied = len(result.Issues) == 0
	return result
}

func (m *Manager) runComponent(ctx context.Context, report *operation.Reporter, plan pendingPlan, scratch *scratchFile) (any, error) {
	planned := *plan.component
	targetID := plan.public.TargetID
	report.Stage(StagePreflight, true)
	component, err := m.prepareComponent(ctx, targetID)
	if err != nil {
		return nil, err
	}
	if component.manifest.Version != planned.manifest.Version || component.artifact != planned.artifact ||
		component.bundlePath != planned.bundlePath {
		return nil, operation.Fail(installCode(targetID, "DETECT_MISMATCH"), nil)
	}
	if requirements := m.componentRequirements(component); !requirements.Satisfied {
		return nil, operation.Fail(installCode(targetID, "REQUIREMENTS_UNMET"), nil)
	}

	downloads, err := openDirectoryChain(m.homeDir, m.downloadDirParts(), true, 0o700)
	if err != nil {
		return nil, operation.Fail(installCode(targetID, "DOWNLOAD_FAILED"), err)
	}
	temporary, _, err := createTemporaryAt(downloads, targetID+"-component-")
	_ = downloads.Close()
	if err != nil {
		return nil, operation.Fail(installCode(targetID, "DOWNLOAD_FAILED"), err)
	}
	scratch.set(temporary.Name())
	defer temporary.Close()

	// Catalog copies are tried first in order, the official host after them.
	// Without a catalog entry the official host and the derived npmmirror
	// tarball are ranked by a short speed probe. As for CLI assets, an
	// unreachable source is skipped while a wrong size or hash stops the
	// install.
	report.Progress(StageDownloading, 0, true)
	candidates := make([]Source, 0, len(component.sources))
	for _, candidate := range component.sources {
		if m.filter == nil || m.filter(candidate) {
			candidates = append(candidates, candidate)
		}
	}
	if !component.catalogFirst {
		candidates = m.client.rankSources(ctx, candidates)
	}
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
	storage, err := openDirectoryChain(m.homeDir, claudecode.StorageDirParts(), true, 0o700)
	if err != nil {
		return nil, m.mapPlaceError(targetID, err)
	}
	placeErr := m.placeHostBundle(ctx, storage, component, temporary, source)
	_ = storage.Close()
	if placeErr != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, m.mapPlaceError(targetID, placeErr)
	}
	return m.detectComponentInstalled(ctx, report, targetID)
}

// placeHostBundle extracts the verified archive into a hidden staging folder
// inside storage, checks the bundle's signature there, then renames it into
// <version>/claude.app exclusively and writes the .verified marker. A stale
// bundle is moved aside first and put back if anything fails.
func (m *Manager) placeHostBundle(ctx context.Context, storage *os.File, component componentPlan, archive *os.File, source Source) error {
	stagingName, err := randomName(componentStagingPrefix)
	if err != nil {
		return err
	}
	if err := secureMkdirAt(int(storage.Fd()), stagingName, 0o700); err != nil {
		return mapPathError(err)
	}
	stagingPath := filepath.Join(storage.Name(), stagingName)
	defer func() { _ = os.RemoveAll(stagingPath) }()
	stagingFD, err := secureOpenDirectoryAt(int(storage.Fd()), stagingName)
	if err != nil {
		return mapPathError(err)
	}
	staging := os.NewFile(uintptr(stagingFD), stagingPath)
	if staging == nil {
		_ = secureClose(stagingFD)
		return errUnsafePath
	}
	defer staging.Close()

	if _, err := archive.Seek(0, io.SeekStart); err != nil {
		return errArchiveInvalid
	}
	if placed, err := m.placeHostPlatform(ctx, storage, staging, component, archive, source); placed {
		// Windows lays down a bare executable plus markers (platform_windows.go).
		return err
	}
	stagedBundle := filepath.Join(stagingPath, claudecode.BundleName)
	switch source.Layout {
	case LayoutHostBinaryNPMTgz:
		// The npm tarball only carries the executable. Verify it as a plain
		// Mach-O *before* it sits inside claude.app/: in a bundle folder
		// codesign demands the CodeResources seal the npm package does not
		// ship and fails with "code has no resources but signature indicates
		// they must be present" (11915 test Mac).
		pin, ok := m.hostPinFor(component, source)
		if !ok || (!pin.Derived && !sha256Pattern.MatchString(pin.BinarySHA256)) {
			return errArchiveInvalid
		}
		if err := m.bundleTools.ExtractHostBinary(ctx, archive, stagingPath, pin.BinarySize, pin.BinarySHA256); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return errArchiveInvalid
		}
		flat := filepath.Join(stagingPath, claudecode.NPMBinaryName)
		if err := m.bundleTools.VerifyBundle(ctx, flat, claudecode.DeveloperIDRequirement()); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return errPublisherMismatch
		}
		// A derived pin has no executable hash: after the signature, the
		// executable must also report exactly the pinned version.
		if pin.Derived {
			if err := m.checkHostVersion(ctx, flat, component.manifest.Version); err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				return errPublisherMismatch
			}
		}
		if err := claudecode.ArrangeHostBinary(stagingPath); err != nil {
			return errArchiveInvalid
		}
	default:
		if err := m.bundleTools.ExtractHostBundle(ctx, archive, stagingPath); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return errArchiveInvalid
		}
		if info, err := os.Lstat(stagedBundle); err != nil || !info.IsDir() {
			return errArchiveInvalid
		}
		if err := m.bundleTools.VerifyBundle(ctx, stagedBundle, claudecode.DeveloperIDRequirement()); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return errPublisherMismatch
		}
	}
	if info, err := os.Lstat(stagedBundle); err != nil || !info.IsDir() {
		return errArchiveInvalid
	}

	version := component.manifest.Version
	if err := secureMkdirAt(int(storage.Fd()), version, 0o700); err != nil && !errors.Is(err, syscall.EEXIST) {
		return mapPathError(err)
	}
	versionFD, err := secureOpenDirectoryAt(int(storage.Fd()), version)
	if err != nil {
		return mapPathError(err)
	}
	versionDir := os.NewFile(uintptr(versionFD), filepath.Join(storage.Name(), version))
	if versionDir == nil {
		_ = secureClose(versionFD)
		return errUnsafePath
	}
	defer versionDir.Close()
	if err := validateDirectory(versionDir); err != nil {
		return err
	}
	// The official archive yields claude.app only; the npm path also yields
	// the flat executable the bundle's symlink points at. Whatever a previous
	// layout left under either name is moved aside first and restored if
	// anything fails.
	names := []string{claudecode.BundleName}
	if source.Layout == LayoutHostBinaryNPMTgz {
		names = []string{claudecode.NPMBinaryName, claudecode.BundleName}
	}
	asides := map[string]string{}
	rollback := func() {
		for name, aside := range asides {
			m.restoreAside(versionDir, aside, name)
		}
		_ = secureFsync(int(versionDir.Fd()))
	}
	for _, name := range []string{claudecode.NPMBinaryName, claudecode.BundleName} {
		aside, err := moveAsideAt(versionDir, name)
		if aside != "" {
			asides[name] = aside
		}
		if err != nil {
			rollback()
			return err
		}
	}
	if err := secureUnlinkAt(int(versionDir.Fd()), claudecode.VerifiedName()); err != nil && !errors.Is(err, syscall.ENOENT) {
		rollback()
		return mapPathError(err)
	}
	placed := []string{}
	unplace := func() {
		// Park the placed entries back in staging (removed on return).
		for _, name := range placed {
			_ = secureRenameExclusiveAt(int(versionDir.Fd()), name, int(staging.Fd()), name)
		}
	}
	for _, name := range names {
		if err := secureRenameExclusiveAt(int(staging.Fd()), name, int(versionDir.Fd()), name); err != nil {
			unplace()
			rollback()
			if errors.Is(err, syscall.EEXIST) {
				return errConflict
			}
			return mapPathError(err)
		}
		placed = append(placed, name)
	}
	checksum := component.artifact.Checksum
	if err := writeRegularAt(versionDir, claudecode.VerifiedName(), strings.NewReader(checksum), int64(len(checksum)), 0o644, ""); err != nil {
		unplace()
		rollback()
		return err
	}
	for _, aside := range asides {
		_ = os.RemoveAll(filepath.Join(versionDir.Name(), aside))
	}
	_ = secureFsync(int(versionDir.Fd()))
	return nil
}

// detectComponentInstalled re-runs detection until the component is present.
func (m *Manager) detectComponentInstalled(ctx context.Context, report *operation.Reporter, targetID string) (any, error) {
	report.Stage(StageDetecting, false)
	var state detect.State
	var err error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(time.Duration(attempt) * time.Second):
			}
		}
		state, err = m.detect(ctx, targetID)
		if err == nil && state.UIState == detect.UIStateInstalledUnmanaged && componentPresent(state) {
			return Result{ToolState: state}, nil
		}
	}
	return nil, operation.Fail(installCode(targetID, "DETECT_MISMATCH"), err)
}

func componentPresent(state detect.State) bool {
	for _, component := range state.Components {
		if component.ID == claudecode.ComponentID {
			return component.State == claudecode.StatePresent
		}
	}
	return false
}
