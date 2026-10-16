//go:build !windows

package install

import (
	"context"
	"os"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

// dirModeUnsafe enforces the Unix invariant that a directory the installer
// traverses or writes into is not group/world-writable.
func dirModeUnsafe(info os.FileInfo) bool { return info.Mode().Perm()&0o022 != 0 }

// executableModeMissing reports a retained CLI file without the owner
// executable bit.
func executableModeMissing(mode os.FileMode) bool { return mode.Perm()&0o100 == 0 }

// executableFileName is the on-disk name of an executable: bare on Unix.
func executableFileName(base string) string { return base }

// launcherFileName is the on-disk name of the launcher in ~/.local/bin: the
// bare tool name (a symlink, launcher_unix.go).
func launcherFileName(base string) string { return base }

// platformDownloadDirParts is the scratch download directory under the home
// directory (macOS application support).
func platformDownloadDirParts() []string {
	return []string{"Library", "Application Support", applicationSupport, "local-coding-tools", "downloads"}
}

// registerLauncherDir: ~/.local/bin is on PATH by convention on macOS; the
// Bridge does not edit shell profiles.
func registerLauncherDir(string) error { return nil }

// hostArtifactLayout is the layout of the host artifact Claude Desktop
// downloads on this platform (the bundle archive on macOS).
const hostArtifactLayout = LayoutHostBundleTarZst

// bundleLayout is where a desktop application goes on this platform.
func (m *Manager) bundleLayout(asset Asset) layout { return m.applicationsLayout(asset) }

// placeHostPlatform: the shared bundle placement applies on macOS.
func (m *Manager) placeHostPlatform(context.Context, *os.File, *os.File, componentPlan, *os.File, Source) (bool, error) {
	return false, nil
}

// installPackage: app packages (MSIX) are a Windows layout only.
func (m *Manager) installPackage(context.Context, *operation.Reporter, pendingPlan, string, packageRegistration) (any, error) {
	return nil, ErrInvalidManifest
}

func preparePackageRegistration(context.Context, *operation.Reporter, Asset, string, string) (packageRegistration, error) {
	return nil, nil
}

// canElevate: the Bridge never escalates on macOS.
func canElevate() bool { return false }

// pathHeldByAnotherProcess: Unix renames are not refused for open files.
func pathHeldByAnotherProcess(error) bool { return false }

func waitForPathRelease(string, string) bool { return false }
