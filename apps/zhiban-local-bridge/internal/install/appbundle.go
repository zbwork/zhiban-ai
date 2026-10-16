package install

// Desktop application bundles (M3). A desktop asset is a zip whose only
// top-level entry is <Name>.app. Placement never overwrites: the archive is
// unpacked into a hidden staging folder inside the destination Applications
// folder, the bundle's code seal and Developer ID requirement are verified
// there, and only then is the bundle renamed into place exclusively. Repair
// moves the damaged bundle aside first and puts it back if anything fails.
// Gatekeeper is asked explicitly after placement because files the Bridge
// downloads carry no quarantine attribute and would otherwise never be
// assessed.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
)

const (
	installLocationKindApplications     = "applications"
	installLocationKindUserApplications = "user_applications"
	defaultSystemApplicationsDir        = "/Applications"
	userApplicationsDirName             = "Applications"
	bundleStagingPrefix                 = ".zhiban-install-"
)

var (
	errPublisherMismatch  = errors.New("install: bundle signature or gatekeeper assessment rejected")
	errTargetInUse        = errors.New("install: target application is running")
	errRunningCheckFailed = errors.New("install: could not tell whether the target application is running")
	// errInstallCancelled: the user declined the elevation prompt a package
	// registration needed (Windows).
	errInstallCancelled = errors.New("install: elevation declined by the user")
)

// BundleTools are the macOS operations bundle installation delegates to the
// system. Production uses the darwin defaults (ditto, codesign, spctl, ps);
// tests inject fakes.
type BundleTools struct {
	// ExtractZip unpacks zipPath into destinationDir preserving the bundle
	// exactly (symlinks, permissions, resource forks).
	ExtractZip func(ctx context.Context, zipPath, destinationDir string) error
	// VerifyBundle validates the bundle's code seal in full, nested code
	// included, and checks that it satisfies the designated requirement.
	VerifyBundle func(ctx context.Context, bundlePath, requirement string) error
	// AssessBundle asks Gatekeeper whether the placed bundle may execute.
	AssessBundle func(ctx context.Context, bundlePath string) error
	// BundleInUse reports whether a running process executes from inside the bundle.
	BundleInUse func(bundlePath string) (bool, error)
	// ExtractHostBundle unpacks a Claude Code host archive (claude.app.tar.zst)
	// into destinationDir. The default is the pure-Go extractor in claudecode;
	// tests may substitute one.
	ExtractHostBundle func(ctx context.Context, archive *os.File, destinationDir string) error
	// ExtractDMG mounts a disk image read-only and copies the unique bundle
	// matching the compiled-in allowed names from its volume root.
	ExtractDMG func(ctx context.Context, dmgPath, destinationDir string, bundleNames []string) error
	// ExtractHostBinary builds the host bundle layout in destinationDir from
	// the bare executable inside a Claude Code npm tarball, checking the
	// executable against the size and SHA-256 Claude Desktop pins.
	ExtractHostBinary func(ctx context.Context, archive *os.File, destinationDir string, size int64, sha256 string) error
}

func (t BundleTools) withDefaults() BundleTools {
	defaults := defaultBundleTools()
	if t.ExtractHostBundle == nil {
		t.ExtractHostBundle = extractHostBundleArchive
	}
	if t.ExtractHostBinary == nil {
		t.ExtractHostBinary = extractHostBinaryNPM
	}
	if t.ExtractZip == nil {
		t.ExtractZip = defaults.ExtractZip
	}
	if t.ExtractDMG == nil {
		t.ExtractDMG = defaults.ExtractDMG
	}
	if t.VerifyBundle == nil {
		t.VerifyBundle = defaults.VerifyBundle
	}
	if t.AssessBundle == nil {
		t.AssessBundle = defaults.AssessBundle
	}
	if t.BundleInUse == nil {
		t.BundleInUse = defaults.BundleInUse
	}
	return t
}

// extractHostBundleArchive is the default ExtractHostBundle: claudecode's
// pure-Go zstd + tar extractor, which only accepts the host bundle layout.
func extractHostBundleArchive(ctx context.Context, archive *os.File, destinationDir string) error {
	return claudecode.ExtractHostBundle(ctx, archive, destinationDir)
}

// extractHostBinaryNPM is the default ExtractHostBinary: claudecode's pure-Go
// gzip + tar member extractor for the npm tarball layout.
func extractHostBinaryNPM(ctx context.Context, archive *os.File, destinationDir string, size int64, sha256 string) error {
	return claudecode.ExtractHostBinaryFromNPM(ctx, archive, destinationDir, size, sha256)
}

// bundleRequirement is the Developer ID designated requirement an installed
// bundle must satisfy: Apple's Developer ID chain, the publisher's Team and
// the expected bundle identifier.
func bundleRequirement(asset Asset) string {
	return fmt.Sprintf(`anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = %q and identifier %q`,
		asset.TeamIdentifier, asset.BundleIdentifier)
}

// applicationsLayout decides where a bundle goes: the system Applications
// folder when the current user may write to it, otherwise ~/Applications.
// The Bridge never escalates privileges.
func (m *Manager) applicationsLayout(asset Asset) layout {
	system := filepath.Clean(m.systemApplicationsDir)
	if info, err := os.Lstat(system); err == nil && info.Mode()&os.ModeSymlink == 0 && info.IsDir() && m.writable(system) {
		return layout{
			baseDir: filepath.Dir(system), targetDir: []string{filepath.Base(system)}, fileName: asset.BundleName,
			locationKind: installLocationKindApplications, bundle: true,
		}
	}
	return layout{
		baseDir: m.homeDir, targetDir: []string{userApplicationsDirName}, fileName: asset.BundleName,
		locationKind: installLocationKindUserApplications, bundle: true,
	}
}

// placeBundle unpacks, verifies and installs the bundle from archivePath
// (a zip or, for the community mirror, a DMG — layoutKind says which) into
// targetDir. See the package comment for the order of operations.
func (m *Manager) placeBundle(ctx context.Context, targetDir *os.File, asset Asset, archivePath, layoutKind, mode string) error {
	stagingName, err := randomName(bundleStagingPrefix)
	if err != nil {
		return err
	}
	if err := secureMkdirAt(int(targetDir.Fd()), stagingName, 0o700); err != nil {
		return mapPathError(err)
	}
	stagingPath := filepath.Join(targetDir.Name(), stagingName)
	defer func() { _ = os.RemoveAll(stagingPath) }()
	stagingFD, err := secureOpenDirectoryAt(int(targetDir.Fd()), stagingName)
	if err != nil {
		return mapPathError(err)
	}
	staging := os.NewFile(uintptr(stagingFD), stagingPath)
	if staging == nil {
		_ = secureClose(stagingFD)
		return errUnsafePath
	}
	defer staging.Close()

	var extractErr error
	switch layoutKind {
	case LayoutAppBundleDMG:
		extractErr = m.bundleTools.ExtractDMG(ctx, archivePath, stagingPath, asset.bundleNames())
	default:
		extractErr = m.bundleTools.ExtractZip(ctx, archivePath, stagingPath)
	}
	if extractErr != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return newBundleFailure(errArchiveInvalid, "解压安装包", extractErr)
	}
	// The archive carries the bundle under one of the names the asset allows
	// (Codex Desktop: Codex.app or ChatGPT.app); it is placed under that name.
	name := ""
	for _, candidate := range asset.bundleNames() {
		if info, err := os.Lstat(filepath.Join(stagingPath, candidate)); err == nil && info.IsDir() {
			if name != "" {
				return newBundleFailure(errArchiveInvalid, "检查应用目录", errors.New("安装包包含多个候选应用"))
			}
			name = candidate
		}
	}
	if name == "" {
		return newBundleFailure(errArchiveInvalid, "检查应用目录", errors.New("未找到预期的应用目录"))
	}
	stagedBundle := filepath.Join(stagingPath, name)
	if err := m.bundleTools.VerifyBundle(ctx, stagedBundle, bundleRequirement(asset)); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return newBundleFailure(errPublisherMismatch, "验证应用签名（codesign）", err)
	}

	// Install never replaces anything, under any of the names. Repair, upgrade
	// and rollback move the existing bundle aside under every name, so an
	// upgrade from Codex.app to ChatGPT.app leaves no second installation.
	var asides []parkedBundle
	if mode == ModeInstall {
		for _, existing := range asset.bundleNames() {
			if _, err := os.Lstat(filepath.Join(targetDir.Name(), existing)); err == nil {
				return errConflict
			}
		}
	} else {
		for _, existing := range asset.bundleNames() {
			aside, err := moveAsideAt(targetDir, existing)
			if aside != "" {
				asides = append(asides, parkedBundle{aside: aside, name: existing})
			}
			if err != nil {
				m.restoreAsides(targetDir, asides)
				return err
			}
		}
	}
	if err := secureRenameExclusiveAt(int(staging.Fd()), name, int(targetDir.Fd()), name); err != nil {
		m.restoreAsides(targetDir, asides)
		if errors.Is(err, syscall.EEXIST) {
			return errConflict
		}
		return mapPathError(err)
	}
	_ = secureFsync(int(targetDir.Fd()))

	finalPath := filepath.Join(targetDir.Name(), name)
	if err := m.bundleTools.AssessBundle(ctx, finalPath); err != nil {
		// Undo: park the rejected bundle back in staging (removed on return)
		// and put the previous bundles back where they were.
		_ = secureRenameExclusiveAt(int(targetDir.Fd()), name, int(staging.Fd()), name)
		m.restoreAsides(targetDir, asides)
		_ = secureFsync(int(targetDir.Fd()))
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return newBundleFailure(errPublisherMismatch, "系统安全检查（Gatekeeper）", err)
	}
	for _, parked := range asides {
		_ = os.RemoveAll(filepath.Join(targetDir.Name(), parked.aside))
	}
	_ = secureFsync(int(targetDir.Fd()))
	return nil
}

// parkedBundle is an existing bundle moved aside under a hidden name.
type parkedBundle struct {
	aside string
	name  string
}

func (m *Manager) restoreAsides(targetDir *os.File, asides []parkedBundle) {
	for index := len(asides) - 1; index >= 0; index-- {
		m.restoreAside(targetDir, asides[index].aside, asides[index].name)
	}
}

func (m *Manager) restoreAside(targetDir *os.File, aside, name string) {
	if aside == "" {
		return
	}
	_ = secureRenameExclusiveAt(int(targetDir.Fd()), aside, int(targetDir.Fd()), name)
}

// bundleInUse reports whether a bundle the asset would replace is running,
// under any of the names the asset allows. macOS lets a running bundle be
// renamed, so the Bridge refuses to replace one on its own.
//
// A Windows package has no bundle name: its target is the registered package
// folder, the layout's final path. Joining the empty name onto the parent
// made the target all of WindowsApps, so any running Store app — Terminal,
// Notepad, Widgets — counted and installing a desktop app through the Bridge
// always reported TARGET_IN_USE (7baae83e, found on a user's machine
// 2026-09-20).
//
// A check that could not be made still refuses the install, but says so
// instead of sending the user after a process that does not exist.
func (m *Manager) bundleInUse(asset Asset, paths layout) error {
	directory := filepath.Dir(paths.finalPath())
	for _, name := range asset.bundleNames() {
		target := paths.finalPath()
		if name != "" {
			target = filepath.Join(directory, name)
		}
		inUse, err := m.bundleTools.BundleInUse(target)
		if err != nil {
			return fmt.Errorf("%w: %v", errRunningCheckFailed, err)
		}
		if inUse {
			return errTargetInUse
		}
	}
	return nil
}
