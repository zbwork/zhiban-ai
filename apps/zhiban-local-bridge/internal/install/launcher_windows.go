//go:build windows

package install

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
)

// On Windows the launcher %USERPROFILE%\.local\bin\<tool>.cmd is a batch shim
// that runs the retained version file (format: detect.LauncherShim). Symbolic
// links need SeCreateSymbolicLinkPrivilege or Developer Mode; the hard link
// the Bridge used until 2026-09-11 was the same file as the version file and
// so could not say which version directory it belonged to — Codex needs the
// rest of its package beside the executable it runs, and a repair that
// replaces the version directory left the old link pointing at the
// moved-aside file, which failed the next install as a conflict.
//
// "Which version does the launcher run" is answered by parsing the shim
// (launcherPointsTo). Writing is atomic: the shim is built in a hidden
// temporary file and renamed over the launcher name. Switching (upgrade /
// rollback) renames the old shim aside first so a failed switch can put it
// back; the aside name is the opaque token replaceLauncherAt returns.
//
// A regular <tool>.exe beside the shim (the older Bridge's hard link, or the
// copy a publisher's native installer drops there) would shadow the shim on
// PATH (PATHEXT tries .EXE before .CMD), so writing the launcher retires it:
// renamed aside — a running executable can be renamed but not deleted — and
// deleted when possible. Its bytes are the retained version file's.

const (
	launcherAsidePrefix     = ".zhiban-link-prev-"
	launcherTemporaryPrefix = ".zhiban-launcher-"
)

func validLauncherName(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsAny(name, `\/`)
}

func samePath(a, b string) bool {
	return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}

func ensureLauncherAt(directory *os.File, name, target string) error {
	if !validLauncherName(name) || !filepath.IsAbs(target) {
		return errUnsafePath
	}
	linkPath := filepath.Join(directory.Name(), name)
	if info, err := os.Lstat(linkPath); err == nil {
		if !info.Mode().IsRegular() {
			return errConflict
		}
		if launcherPointsTo(linkPath, target) {
			return retireLegacyLauncher(directory, name)
		}
		if launcherConflicts(linkPath, target) {
			return errConflict
		}
		// A shim of ours whose version file is gone: rewrite it below.
	} else if !errors.Is(err, os.ErrNotExist) {
		return mapPathError(err)
	}
	if err := writeLauncherAt(directory, name, target); err != nil {
		return err
	}
	return retireLegacyLauncher(directory, name)
}

func replaceLauncherAt(directory *os.File, name, target string) (string, error) {
	if !validLauncherName(name) || !filepath.IsAbs(target) {
		return "", errUnsafePath
	}
	linkPath := filepath.Join(directory.Name(), name)
	previous := ""
	if info, err := os.Lstat(linkPath); err == nil {
		if !info.Mode().IsRegular() {
			return "", errConflict
		}
		if launcherPointsTo(linkPath, target) {
			return "", retireLegacyLauncher(directory, name)
		}
		aside, err := moveAsidePrefixedAt(directory, name, launcherAsidePrefix)
		if err != nil {
			return "", err
		}
		previous = aside
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", mapPathError(err)
	}
	if err := writeLauncherAt(directory, name, target); err != nil {
		if previous != "" {
			_ = secureRenameExclusiveAt(int(directory.Fd()), previous, int(directory.Fd()), name)
		}
		return "", err
	}
	if err := retireLegacyLauncher(directory, name); err != nil {
		if previous != "" {
			_ = restoreLauncherAt(directory, name, previous)
		}
		return "", err
	}
	return previous, nil
}

func restoreLauncherAt(directory *os.File, name, previous string) error {
	if !validLauncherName(name) || !validLauncherName(previous) {
		return errUnsafePath
	}
	if err := secureUnlinkAt(int(directory.Fd()), name); err != nil && !errors.Is(err, syscall.ENOENT) {
		return mapPathError(err)
	}
	return secureRenameExclusiveAt(int(directory.Fd()), previous, int(directory.Fd()), name)
}

// commitLauncher deletes the aside old launcher. When it is still open the
// delete fails and the hidden file stays until the next switch; it is never
// on PATH by name and harms nothing.
func commitLauncher(directory *os.File, previous string) {
	if previous == "" || !validLauncherName(previous) {
		return
	}
	_ = secureUnlinkAt(int(directory.Fd()), previous)
}

// launcherPointsTo reports whether the shim at linkPath runs finalPath.
func launcherPointsTo(linkPath, finalPath string) bool {
	target, ok := detect.LauncherShimTarget(linkPath)
	return ok && samePath(target, finalPath)
}

// launcherConflicts reports whether what occupies linkPath stops a
// non-switching install of finalPath. A foreign file does; a shim of ours
// that runs finalPath, or whose version file no longer exists (nothing to
// preserve), does not.
func launcherConflicts(linkPath, finalPath string) bool {
	target, ok := detect.LauncherShimTarget(linkPath)
	if !ok {
		return true
	}
	if samePath(target, finalPath) {
		return false
	}
	_, err := os.Stat(target)
	return err == nil
}

func launcherKindOK(info os.FileInfo) bool { return info.Mode().IsRegular() }

// writeLauncherAt renders the shim for target into a hidden temporary file
// and renames it over name.
func writeLauncherAt(directory *os.File, name, target string) error {
	content, err := detect.LauncherShim(filepath.Join(directory.Name(), name), target)
	if err != nil {
		return errUnsafePath
	}
	temporary, temporaryName, err := createTemporaryAt(directory, launcherTemporaryPrefix)
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = secureUnlinkAt(int(directory.Fd()), temporaryName)
		}
	}()
	if _, err := temporary.Write(content); err != nil {
		return mapPathError(err)
	}
	if err := temporary.Sync(); err != nil {
		return mapPathError(err)
	}
	if err := temporary.Close(); err != nil {
		return mapPathError(err)
	}
	if err := secureRenameAt(int(directory.Fd()), temporaryName, int(directory.Fd()), name); err != nil {
		return mapPathError(err)
	}
	committed = true
	return secureFsync(int(directory.Fd()))
}

// retireLegacyLauncher moves a regular <tool>.exe beside the shim aside and
// deletes it when it is not running. Anything else under that name (a
// directory, a link) is left alone.
func retireLegacyLauncher(directory *os.File, name string) error {
	legacy := strings.TrimSuffix(name, filepath.Ext(name)) + ".exe"
	if !validLauncherName(legacy) || strings.EqualFold(legacy, name) {
		return nil
	}
	info, err := os.Lstat(filepath.Join(directory.Name(), legacy))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return mapPathError(err)
	}
	if !info.Mode().IsRegular() {
		return nil
	}
	aside, err := moveAsidePrefixedAt(directory, legacy, launcherAsidePrefix)
	if err != nil {
		return err
	}
	commitLauncher(directory, aside)
	return nil
}
