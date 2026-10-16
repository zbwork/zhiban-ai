//go:build windows

package install

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Windows permission bits reported by os.Stat are synthetic (0777 for every
// directory), so the Unix mode invariants do not apply; safety comes from the
// per-user ACLs of the profile the installer stays inside and from the
// secure_syscall layer refusing reparse points.
func dirModeUnsafe(os.FileInfo) bool         { return false }
func executableModeMissing(os.FileMode) bool { return false }

// executableFileName is the on-disk name of an executable: Windows needs the
// .exe extension for CreateProcess and PATHEXT lookups.
func executableFileName(base string) string { return base + ".exe" }

// launcherFileName is the on-disk name of the launcher in .local\bin: a
// batch shim (launcher_windows.go), so PATH lookups run it through cmd.exe
// like the npm shims of the same CLIs.
func launcherFileName(base string) string { return base + ".cmd" }

// platformDownloadDirParts is the scratch download directory under the home
// directory (%LOCALAPPDATA% in its default location).
func platformDownloadDirParts() []string {
	return []string{"AppData", "Local", applicationSupport, "local-coding-tools", "downloads"}
}

// hostArtifactLayout is the layout of the host artifact Claude Desktop
// downloads on Windows: the zstd stream of the bare executable.
const hostArtifactLayout = LayoutHostBinaryZst

// windowsAppsDir is where the OS keeps registered app packages.
func windowsAppsDir() string {
	root := strings.TrimSpace(os.Getenv("ProgramFiles"))
	if root == "" {
		root = `C:\Program Files`
	}
	return filepath.Join(root, "WindowsApps")
}

// packageFullName is the folder name the OS gives a registered package:
// Name_Version_Arch_ResourceId_PublisherId with a four-part version.
func packageFullName(asset Asset) string {
	return asset.PackageName + "_" + asset.Version + ".0_" + windowsPackageArch(asset.Arch) + "__" + asset.PackagePublisherID
}

func windowsPackageArch(arch string) string {
	if arch == ArchARM64 {
		return "arm64"
	}
	return "x64"
}

// bundleLayout for a Windows desktop asset is the package's registered
// folder: it exists exactly when that version is installed, which is what
// the conflict and in-use checks need. The Bridge never writes there; the OS
// does (installPackage).
func (m *Manager) bundleLayout(asset Asset) layout {
	return layout{
		baseDir: windowsAppsDir(), fileName: packageFullName(asset),
		locationKind: installLocationKindWindowsApps, bundle: true,
	}
}

// pathHeldByAnotherProcess reports the errors Windows returns for a rename or
// delete of a file (or a directory holding one) that another process — on the
// test machines the security software's on-access scan — still has open.
func pathHeldByAnotherProcess(err error) bool {
	return errors.Is(err, syscall.ERROR_ACCESS_DENIED) || errors.Is(err, errSharingViolation)
}

// errSharingViolation is ERROR_SHARING_VIOLATION (32), which syscall does not name.
const errSharingViolation = syscall.Errno(32)

// waitForPathRelease polls until directory\name can be opened with exclusive
// sharing, i.e. no other process holds it, for at most pathReleaseWait. It
// reports whether the path was released in time.
func waitForPathRelease(directory, name string) bool {
	deadline := time.Now().Add(pathReleaseWait)
	path, err := syscall.UTF16PtrFromString(filepath.Join(directory, name))
	if err != nil {
		return false
	}
	for time.Now().Before(deadline) {
		time.Sleep(pathReleasePoll)
		// FILE_FLAG_BACKUP_SEMANTICS lets CreateFile open a directory handle;
		// share mode 0 asks for exclusivity and fails while anyone else has
		// the object open.
		handle, err := syscall.CreateFile(path, syscall.GENERIC_READ, 0, nil, syscall.OPEN_EXISTING, syscall.FILE_FLAG_BACKUP_SEMANTICS, 0)
		if err == nil {
			_ = syscall.CloseHandle(handle)
			return true
		}
		if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) || errors.Is(err, syscall.ERROR_PATH_NOT_FOUND) {
			return false
		}
	}
	return false
}

const (
	pathReleaseWait = 10 * time.Second
	pathReleasePoll = 500 * time.Millisecond
)
