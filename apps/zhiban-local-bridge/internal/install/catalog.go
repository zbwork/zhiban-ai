package install

// Signed version catalog integration (F31 version catalog plan §4). After
// catalog.apply verified a catalog for the App's environment, the catalog's
// current version replaces the compiled-in asset of every target it lists
// (install and repair use it), an installed official tool can be upgraded to
// it or rolled back to a retained or previous version, and downloads of
// catalog sources may use the hosts the catalog allows. Everything else —
// placement, verification, detection — is the same code path as a build-time
// asset, and a catalog that fails verification leaves the built-in manifest
// in force.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

const (
	// ModeUpgrade installs the catalog's current version next to the installed
	// one and re-points the launcher link; ModeRollback re-points it at a
	// retained older version or reinstalls the catalog's previous one.
	ModeUpgrade  = "upgrade"
	ModeRollback = "rollback"

	// ModeAdopt takes over a copy the user installed from somewhere else (npm,
	// Homebrew): it puts the catalog's current version in the publisher's own
	// standard location, points the launcher at it and makes sure the user's
	// shell resolves it. The user's own copy is never removed — it just stops
	// being the one that runs. Without this, a copy from npm or Homebrew can
	// neither be upgraded (upgrade only works on the standard location) nor
	// installed (install requires nothing installed), so a user stuck on an
	// old version had no button at all (2026-09-16).
	ModeAdopt = "adopt"

	// OriginBuiltin, OriginCatalog and OriginLocal say where a plan's version
	// comes from: the compiled-in manifest, the verified catalog, or a version
	// already on disk (rollback without download).
	OriginBuiltin = "builtin"
	OriginCatalog = "catalog"
	OriginLocal   = "local"

	// retainedOldVersions is how many superseded CLI versions stay on disk
	// after an upgrade or rollback (the linked one is never counted or removed).
	retainedOldVersions = 2

	catalogCodeInvalid      = "LCT-BRIDGE-CATALOG-INVALID"
	catalogCodeUntrustedKey = "LCT-BRIDGE-CATALOG-UNTRUSTED_KEY"
)

// CatalogApplyInput is catalog.apply's request: the App's environment (which
// selects the trusted keys) and the envelope as the Bus returned it. An
// empty or null catalog clears the applied catalog.
type CatalogApplyInput struct {
	Environment string
	Signed      catalog.Signed
}

// CatalogStatus is catalog.apply's result.
type CatalogStatus struct {
	Applied   bool                           `json:"applied"`
	IssuedAt  string                         `json:"issued_at,omitempty"`
	ExpiresAt string                         `json:"expires_at,omitempty"`
	Targets   map[string]CatalogTargetStatus `json:"targets"`
}

// CatalogTargetStatus summarises one target of the applied catalog.
type CatalogTargetStatus struct {
	CurrentVersion  string `json:"current_version"`
	PreviousVersion string `json:"previous_version,omitempty"`
	Canary          bool   `json:"canary,omitempty"`
}

// Availability is merged into tool.detect results: the catalog version an
// installed official tool can move up to, the version it can fall back to,
// and whether an upgrade is offered.
type Availability struct {
	AvailableVersion string `json:"available_version,omitempty"`
	RollbackVersion  string `json:"rollback_version,omitempty"`
	UpdateAvailable  bool   `json:"update_available"`
	ReleaseNotes     string `json:"release_notes,omitempty"`
	// AdoptVersion is the version ModeAdopt would install for a copy that did
	// not come from the publisher's standard location. Empty when the installed
	// copy is already there (use AvailableVersion) or nothing can be adopted.
	AdoptVersion string `json:"adopt_version,omitempty"`
}

type catalogEntry struct {
	current  Asset
	previous *Asset
	canary   bool
	notes    string
}

type catalogState struct {
	environment string
	issuedAt    string
	expiresAt   string
	expires     time.Time
	hosts       []string
	entries     map[string]catalogEntry
	// hostEntries are the claude_code_host versions the catalog serves,
	// keyed by version (see catalog_host.go).
	hostEntries map[string]hostCatalogEntry
}

func (s *catalogState) status() CatalogStatus {
	status := CatalogStatus{Applied: true, IssuedAt: s.issuedAt, ExpiresAt: s.expiresAt, Targets: map[string]CatalogTargetStatus{}}
	for targetID, entry := range s.entries {
		item := CatalogTargetStatus{CurrentVersion: entry.current.Version, Canary: entry.canary}
		if entry.previous != nil {
			item.PreviousVersion = entry.previous.Version
		}
		status.Targets[targetID] = item
	}
	return status
}

// ApplyCatalog implements catalog.apply: verify, convert, remember and persist
// the catalog, or clear it when the App sends none.
func (m *Manager) ApplyCatalog(_ context.Context, input CatalogApplyInput) (CatalogStatus, error) {
	if !catalog.ValidEnvironment(input.Environment) {
		return CatalogStatus{}, ErrInvalidInput
	}
	document := bytes.TrimSpace(input.Signed.Catalog)
	if len(document) == 0 || string(document) == "null" {
		m.setCatalog(nil)
		_ = m.catalogStore.Clear()
		return CatalogStatus{Applied: false, Targets: map[string]CatalogTargetStatus{}}, nil
	}
	state, err := m.buildCatalog(input.Environment, input.Signed, m.now())
	if err != nil {
		if errors.Is(err, catalog.ErrUnknownKey) {
			return CatalogStatus{}, operation.Fail(catalogCodeUntrustedKey, err)
		}
		return CatalogStatus{}, operation.Fail(catalogCodeInvalid, err)
	}
	m.setCatalog(state)
	// Persistence is best effort: the in-memory catalog serves this session
	// either way, and the next process re-verifies whatever it finds.
	_ = m.catalogStore.Save(catalog.Record{
		Environment: input.Environment, KID: input.Signed.KID, Signature: input.Signed.Signature, Catalog: input.Signed.Catalog,
	})
	return state.status(), nil
}

// Availability reports the upgrade / rollback options for a detected state.
func (m *Manager) Availability(_ context.Context, targetID string, state detect.State) Availability {
	var result Availability
	if !validTarget(targetID) {
		return result
	}
	if !installedOfficial(state) {
		// A copy from npm / Homebrew cannot be upgraded in place, but Zhiban
		// can take the target over (ModeAdopt) as long as that does not move
		// the user backwards.
		if asset, ok := m.adoptAsset(targetID, state); ok {
			result.AdoptVersion = asset.Version
		}
		return result
	}
	if entry, ok := m.catalogEntry(targetID); ok && catalog.CompareVersions(entry.current.Version, state.InstalledVersion) > 0 {
		result.AvailableVersion = entry.current.Version
		result.UpdateAvailable = true
		result.ReleaseNotes = entry.notes
	}
	if candidate, ok := m.rollbackCandidate(targetID, state.InstalledVersion); ok {
		result.RollbackVersion = candidate.asset.Version
	}
	return result
}

func installedOfficial(state detect.State) bool {
	return state.UIState == detect.UIStateInstalledUnmanaged && state.InstallSource == detect.SourceOfficial && state.InstalledVersion != ""
}

// adoptAsset is the version ModeAdopt would install: the catalog's current
// (else the built-in manifest), for an installed CLI that came from somewhere
// other than the publisher's standard location, and only when it is not older
// than what the user already runs — taking a target over must never move the
// user backwards. Desktop applications are never adopted: a bundle that is not
// `official` failed signature checks, and installing next to it would leave two.
func (m *Manager) adoptAsset(targetID string, state detect.State) (Asset, bool) {
	if state.UIState != detect.UIStateInstalledUnmanaged || state.InstalledVersion == "" ||
		state.InstallSource == detect.SourceOfficial || state.InstallSource == detect.SourceUnknown {
		return Asset{}, false
	}
	asset, ok := m.assetFor(targetID)
	if !ok || asset.IsBundle() || catalog.CompareVersions(asset.Version, state.InstalledVersion) < 0 {
		return Asset{}, false
	}
	return asset, true
}

// loadStoredCatalog restores the last applied catalog, re-verifying it with
// the keys of the environment it was stored for. Anything that no longer
// verifies (expired, tampered, key rotated away) is deleted.
func (m *Manager) loadStoredCatalog() {
	record, err := m.catalogStore.Load()
	if err != nil {
		return
	}
	state, err := m.buildCatalog(record.Environment, record.Signed(), m.now())
	if err != nil {
		_ = m.catalogStore.Clear()
		return
	}
	m.setCatalog(state)
}

func (m *Manager) buildCatalog(environment string, signed catalog.Signed, now time.Time) (*catalogState, error) {
	if !catalog.ValidEnvironment(environment) {
		return nil, catalog.ErrUnknownKey
	}
	document, err := catalog.Verify(m.catalogKeys(environment), signed, now, m.platform, m.arch)
	if err != nil {
		return nil, err
	}
	expires, _ := time.Parse(time.RFC3339, document.ExpiresAt)
	state := &catalogState{
		environment: environment, issuedAt: document.IssuedAt, expiresAt: document.ExpiresAt, expires: expires,
		hosts: append([]string(nil), document.AllowedHosts...), entries: map[string]catalogEntry{},
	}
	for targetID, target := range document.Targets {
		if targetID == catalog.TargetClaudeCodeHost {
			// The host component's version is pinned by the installed
			// Claude.app; catalog entries only add sources for that version.
			state.hostEntries = hostCatalogEntries(target)
			continue
		}
		if !validTarget(targetID) {
			continue
		}
		if _, ok := m.assets[targetID]; !ok {
			// The catalog is per platform, but a Bridge may lag the catalog:
			// a target it has no compiled-in asset for here (e.g. a desktop
			// target before that platform's implementation ships) is skipped,
			// so the entries it can consume stay in force instead of the
			// whole catalog being rejected (2026-09-10 Windows).
			continue
		}
		if target.Current == nil {
			return nil, fmt.Errorf("%w: %s has no current", catalog.ErrInvalid, targetID)
		}
		current, err := m.catalogAsset(targetID, *target.Current)
		if err != nil {
			return nil, err
		}
		entry := catalogEntry{current: current, canary: target.Current.Canary, notes: target.Current.ReleaseNotes}
		if target.Previous != nil {
			previous, err := m.catalogAsset(targetID, *target.Previous)
			if err != nil {
				return nil, err
			}
			entry.previous = &previous
		}
		state.entries[targetID] = entry
	}
	return state, nil
}

// catalogAsset turns a catalog version into an installable asset. The
// publisher identity (source label, bundle name, bundle and team identifiers)
// always comes from the compiled-in asset: a catalog may restate it but never
// change it, so a signing-key compromise still cannot install a bundle from
// another publisher under a tool's name.
func (m *Manager) catalogAsset(targetID string, version catalog.Version) (Asset, error) {
	base, ok := m.assets[targetID]
	if !ok {
		return Asset{}, fmt.Errorf("%w: no built-in asset for %s/%s", catalog.ErrInvalid, targetID, m.arch)
	}
	asset := Asset{
		TargetID: targetID, Platform: m.platform, Arch: m.arch, Version: version.Version, Source: base.Source,
		BinarySHA256: version.BinarySHA256, FromCatalog: true,
	}
	if base.IsBundle() {
		asset.BundleName, asset.BundleIdentifier, asset.TeamIdentifier = base.BundleName, base.BundleIdentifier, base.TeamIdentifier
		asset.BundleAliases = base.BundleAliases
		// Windows packages: identity, signer and the elevation need come from
		// the built-in asset as well (M3-W).
		asset.PackageName, asset.PackagePublisherID = base.PackageName, base.PackagePublisherID
		asset.SignerName, asset.RequiresElevation = base.SignerName, base.RequiresElevation
		if (version.BundleIdentifier != "" && version.BundleIdentifier != base.BundleIdentifier) ||
			(version.TeamIdentifier != "" && version.TeamIdentifier != base.TeamIdentifier) {
			return Asset{}, fmt.Errorf("%w: %s %s changes the publisher identity", catalog.ErrInvalid, targetID, version.Version)
		}
	} else if version.BinarySHA256 == "" {
		return Asset{}, fmt.Errorf("%w: %s %s has no binary_sha256", catalog.ErrInvalid, targetID, version.Version)
	}
	layout, member := version.Layout, version.Member
	if targetID == TargetCodexCLI {
		var err error
		if layout, member, err = codexCatalogLayout(layout, member); err != nil {
			return Asset{}, fmt.Errorf("%w: %s %s: %v", catalog.ErrInvalid, targetID, version.Version, err)
		}
	}
	for _, source := range version.Sources {
		asset.Sources = append(asset.Sources, Source{
			Kind: SourceKindZhibanPackage, URL: source.URL, Size: source.Size, SHA256: source.SHA256,
			Layout: layout, Member: member,
		})
	}
	if err := asset.Validate(); err != nil {
		return Asset{}, fmt.Errorf("%w: %s %s: %v", catalog.ErrInvalid, targetID, version.Version, err)
	}
	return asset, nil
}

// codexCatalogLayout maps a catalog entry onto the package tree the Codex
// CLI is installed as (tree.go). tarball_tree is taken as is; a
// tarball_member entry naming <package>/bin/codex — the shape the catalog
// carried before the tree layout existed — installs the whole <package>;
// single-binary layouts cannot provide the Code Mode host and are refused
// rather than installing a layout detect would immediately report repairable.
func codexCatalogLayout(layout, member string) (string, string, error) {
	switch layout {
	case LayoutTarballTree:
		return layout, member, nil
	case LayoutTarballMember:
		base := path.Base(member)
		if (base == "codex" || base == "codex.exe") && path.Base(path.Dir(member)) == "bin" && path.Dir(path.Dir(member)) != "." {
			return LayoutTarballTree, path.Dir(path.Dir(member)), nil
		}
		return "", "", errors.New("tarball_member must name <package>/bin/codex")
	default:
		return "", "", errors.New("layout " + layout + " cannot install the Codex package tree")
	}
}

func (m *Manager) setCatalog(state *catalogState) {
	m.catalogMu.Lock()
	m.catalog = state
	m.catalogMu.Unlock()
	if state == nil {
		m.client.setCatalogHosts(nil)
		return
	}
	m.client.setCatalogHosts(state.hosts)
}

// currentCatalog returns the applied catalog while it is still valid.
func (m *Manager) currentCatalog() *catalogState {
	m.catalogMu.RLock()
	state := m.catalog
	m.catalogMu.RUnlock()
	if state == nil || !m.now().Before(state.expires) {
		return nil
	}
	return state
}

func (m *Manager) catalogEntry(targetID string) (catalogEntry, bool) {
	state := m.currentCatalog()
	if state == nil {
		return catalogEntry{}, false
	}
	entry, ok := state.entries[targetID]
	return entry, ok
}

// assetFor returns the asset a fresh install or a repair uses: the catalog's
// current version when a catalog lists the target, else the built-in one.
func (m *Manager) assetFor(targetID string) (Asset, bool) {
	if entry, ok := m.catalogEntry(targetID); ok {
		return entry.current, true
	}
	asset, ok := m.assets[targetID]
	return asset, ok
}

func originOf(asset Asset) string {
	if asset.FromCatalog {
		return OriginCatalog
	}
	return OriginBuiltin
}

// rollbackCandidate is the version a rollback moves to, in order: for CLIs
// the newest retained version on disk older than the installed one (no
// download); then the catalog's current when it is older than the installed
// one (the platform rolled its release back and this machine already took the
// withdrawn version); then the catalog's previous when it is older.
type rollbackCandidate struct {
	asset Asset
	local bool
}

func (m *Manager) rollbackCandidate(targetID, installed string) (rollbackCandidate, bool) {
	entry, hasEntry := m.catalogEntry(targetID)
	if !isBundleTarget(targetID) {
		for _, version := range m.retainedVersions(targetID) {
			if catalog.CompareVersions(version, installed) >= 0 {
				continue
			}
			base, ok := m.assets[targetID]
			if !ok {
				break
			}
			asset := Asset{TargetID: targetID, Platform: m.platform, Arch: m.arch, Version: version, Source: base.Source}
			if hasEntry {
				// Verify the retained copy against the catalog when it knows
				// this version.
				if entry.current.Version == version {
					asset.BinarySHA256 = entry.current.BinarySHA256
				} else if entry.previous != nil && entry.previous.Version == version {
					asset.BinarySHA256 = entry.previous.BinarySHA256
				}
			}
			return rollbackCandidate{asset: asset, local: true}, true
		}
	}
	if !hasEntry {
		return rollbackCandidate{}, false
	}
	if catalog.CompareVersions(entry.current.Version, installed) < 0 {
		return rollbackCandidate{asset: entry.current}, true
	}
	if entry.previous != nil && catalog.CompareVersions(entry.previous.Version, installed) < 0 {
		return rollbackCandidate{asset: *entry.previous}, true
	}
	return rollbackCandidate{}, false
}

func isBundleTarget(targetID string) bool {
	return targetID == TargetCodexDesktop || targetID == TargetClaudeDesktop
}

// versionsLayout is where a CLI keeps its versions under the locked layout,
// how a version maps to its executable, and the launcher link name.
type versionsLayout struct {
	root       string
	executable func(version string) string
	linkName   string
}

func (m *Manager) versionsLayout(targetID string) (versionsLayout, bool) {
	switch targetID {
	case TargetCodexCLI:
		root := filepath.Join(m.homeDir, ".codex", "packages", "standalone")
		return versionsLayout{
			root: root, linkName: launcherFileName("codex"),
			executable: func(version string) string { return filepath.Join(root, version, "bin", executableFileName("codex")) },
		}, true
	case TargetClaudeCLI:
		root := filepath.Join(m.homeDir, ".local", "share", "claude", "versions")
		return versionsLayout{
			root: root, linkName: launcherFileName("claude"),
			executable: func(version string) string { return filepath.Join(root, executableFileName(version)) },
		}, true
	default:
		return versionsLayout{}, false
	}
}

// retainedVersions lists the CLI versions present on disk under the locked
// layout, newest first, excluding the one ~/.local/bin/<tool> points at.
func (m *Manager) retainedVersions(targetID string) []string {
	layoutInfo, ok := m.versionsLayout(targetID)
	if !ok {
		return nil
	}
	root, executable := layoutInfo.root, layoutInfo.executable
	launcher := filepath.Join(m.homeDir, ".local", "bin", layoutInfo.linkName)
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	versions := make([]string, 0, len(entries))
	for _, entry := range entries {
		// Claude keeps versions as files named by version (plus .exe on
		// Windows); Codex as directories named by version.
		name := strings.TrimSuffix(entry.Name(), executableFileName(""))
		if !versionPattern.MatchString(name) {
			continue
		}
		path := executable(name)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || launcherPointsTo(launcher, path) {
			continue
		}
		versions = append(versions, name)
	}
	sort.SliceStable(versions, func(i, j int) bool { return catalog.CompareVersions(versions[i], versions[j]) > 0 })
	return versions
}

// pruneRetained removes superseded CLI versions beyond the retention limit
// and returns the versions that remain (newest first). The linked version is
// never removed; a directory that holds anything else is left alone.
func (m *Manager) pruneRetained(targetID string) []string {
	retained := m.retainedVersions(targetID)
	if len(retained) <= retainedOldVersions {
		return retained
	}
	layoutInfo, ok := m.versionsLayout(targetID)
	if !ok {
		return retained
	}
	for _, version := range retained[retainedOldVersions:] {
		path := layoutInfo.executable(version)
		if info, err := os.Lstat(path); err != nil || !info.Mode().IsRegular() {
			continue
		}
		if targetID == TargetCodexCLI {
			// <version>/bin/codex: the version directory is the install
			// unit (bin/, codex-path/, codex-resources/), remove it whole.
			_ = os.RemoveAll(filepath.Dir(filepath.Dir(path)))
			continue
		}
		_ = os.Remove(path)
	}
	return m.retainedVersions(targetID)
}

// verifyLocalExecutable checks the retained file a rollback re-points at: a
// regular executable and, when the catalog knows the version, its exact hash.
func verifyLocalExecutable(path, expectedSHA256 string) error {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || executableModeMissing(info.Mode()) {
		return errConflict
	}
	if expectedSHA256 == "" {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return errConflict
	}
	defer file.Close()
	return verifyFile(context.Background(), file, Source{Size: info.Size(), SHA256: expectedSHA256})
}
