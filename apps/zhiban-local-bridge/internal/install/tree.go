package install

// Package trees (LayoutTarballTree). The Codex CLI is not one file: the
// publisher's package is bin/codex, bin/codex-code-mode-host (the Code Mode
// host Codex spawns from its own bin/, a stable default-on feature since
// 0.153), codex-path/rg and codex-resources/. A bare codex binary runs but
// prints "Code Mode is unavailable … host executable was not found" on every
// session and refuses Code Mode (2026-09-10 test machines), so the install
// unit is the whole version directory: the tree is extracted into a hidden
// staging directory beside it, the locked executable's hash is checked while
// it is written, and the staging directory is renamed into place. Repair,
// upgrade and rollback move an existing version directory aside first and
// remove it once the new one is in (or put it back when the swap fails).
// Nothing is ever overwritten in place.

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/detect"
)

const treeStagingPrefix = ".zhiban-staging-"

// placeTreeFor resolves the version directory of paths and installs the
// source's package tree there.
func (m *Manager) placeTreeFor(paths layout, scratch *os.File, source Source, binarySHA256, mode string) error {
	if len(paths.unitDir) == 0 || paths.unitName == "" || paths.unitExecutable == "" {
		return ErrInvalidManifest
	}
	versionsDir, err := openDirectoryChain(paths.baseDir, paths.unitDir, true, 0o755)
	if err != nil {
		return err
	}
	defer versionsDir.Close()
	return m.placeTree(versionsDir, paths.unitName, scratch, source.Member, paths.unitExecutable, binarySHA256, mode)
}

// placeTree extracts the files below prefix in the gzip tarball scratch into
// a fresh staging directory inside versionsDir and swaps it in as unitName.
// executableRel names the locked executable inside the tree; it must be
// present and, when binarySHA256 is set, hash to it.
func (m *Manager) placeTree(versionsDir *os.File, unitName string, scratch *os.File, prefix, executableRel, binarySHA256, mode string) error {
	if unitName == "" || unitName == "." || unitName == ".." || strings.ContainsRune(unitName, filepath.Separator) ||
		strings.HasPrefix(unitName, ".") {
		return errUnsafePath
	}
	if _, err := scratch.Seek(0, io.SeekStart); err != nil {
		return errHashMismatch
	}
	stagingName, err := randomName(treeStagingPrefix)
	if err != nil {
		return err
	}
	if err := secureMkdirAt(int(versionsDir.Fd()), stagingName, 0o755); err != nil {
		return mapPathError(err)
	}
	stagingPath := filepath.Join(versionsDir.Name(), stagingName)
	defer func() { _ = os.RemoveAll(stagingPath) }()

	executableSeen := false
	err = extractTree(scratch, prefix, func(relative string, executable bool, content io.Reader, size int64) error {
		parts := strings.Split(relative, "/")
		directory, err := openDirectoryChain(stagingPath, parts[:len(parts)-1], true, 0o755)
		if err != nil {
			return err
		}
		defer directory.Close()
		name := parts[len(parts)-1]
		fileMode := os.FileMode(0o644)
		if executable {
			fileMode = 0o755
		}
		expected := ""
		if relative == executableRel {
			executableSeen = true
			expected = binarySHA256
			fileMode = 0o755
		}
		if size == 0 {
			return writeEmptyAt(directory, name, fileMode)
		}
		return writeRegularAt(directory, name, content, size, fileMode, expected)
	})
	if err != nil {
		return err
	}
	if !executableSeen {
		return errArchiveInvalid
	}

	aside := ""
	if mode != ModeInstall {
		aside, err = moveAsideAt(versionsDir, unitName)
		if err != nil {
			m.restoreAside(versionsDir, aside, unitName)
			return err
		}
	}
	if err := secureRenameExclusiveAt(int(versionsDir.Fd()), stagingName, int(versionsDir.Fd()), unitName); err != nil {
		m.restoreAside(versionsDir, aside, unitName)
		if errors.Is(err, syscall.EEXIST) {
			return errConflict
		}
		return mapPathError(err)
	}
	_ = secureFsync(int(versionsDir.Fd()))
	if aside != "" {
		_ = os.RemoveAll(filepath.Join(versionsDir.Name(), aside))
		_ = secureFsync(int(versionsDir.Fd()))
	}
	return nil
}

// writeEmptyAt creates an empty regular file exclusively at directory/name.
func writeEmptyAt(directory *os.File, name string, mode os.FileMode) error {
	if name == "" || name == "." || name == ".." || strings.ContainsRune(name, filepath.Separator) {
		return errUnsafePath
	}
	temporary, temporaryName, err := createTemporaryAt(directory, ".zhiban-install-")
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
	if err := temporary.Chmod(mode); err != nil {
		return mapPathError(err)
	}
	if err := temporary.Close(); err != nil {
		return mapPathError(err)
	}
	if err := secureRenameExclusiveAt(int(directory.Fd()), temporaryName, int(directory.Fd()), name); err != nil {
		if errors.Is(err, syscall.EEXIST) {
			return errConflict
		}
		return mapPathError(err)
	}
	committed = true
	return secureFsync(int(directory.Fd()))
}

// localVersionComplete reports whether a version already on disk can be
// re-linked without a download: a Codex version directory must carry the
// whole package, not the bare binary an earlier Bridge left there.
func localVersionComplete(asset Asset, executable string) bool {
	if asset.TargetID != TargetCodexCLI {
		return true
	}
	return detect.CodexLayoutComplete(executable)
}
