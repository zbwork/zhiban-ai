package configuration

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

type managedFile struct {
	parent *os.File
	name   string
	// limit is the largest content read or written: maxManagedFileBytes, or
	// maxCodexCatalogBytes for the Codex model catalog (it carries every
	// model's instructions, several hundred KB).
	limit int
}

func (m *Manager) openManagedFile(path string, createParent bool) (*managedFile, error) {
	cleanPath := filepath.Clean(path)
	if !pathInsideOrEqual(cleanPath, m.homeDir) {
		return nil, ErrUnsafePath
	}
	relative, err := filepath.Rel(m.homeDir, filepath.Dir(cleanPath))
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return nil, ErrUnsafePath
	}
	name := filepath.Base(cleanPath)
	if name == "." || name == ".." || name == "" || strings.ContainsRune(name, filepath.Separator) {
		return nil, ErrUnsafePath
	}

	rootFD, err := secureOpenDirectory(m.homeDir)
	if err != nil {
		return nil, mapPathError(err)
	}
	current := os.NewFile(uintptr(rootFD), m.homeDir)
	if current == nil {
		_ = secureClose(rootFD)
		return nil, ErrUnsafePath
	}
	if err := validateDirectory(current); err != nil {
		_ = current.Close()
		return nil, err
	}
	trustedPath, privateAncestor := directoryProtection(current)

	parts := []string{}
	if relative != "." {
		parts = strings.Split(relative, string(filepath.Separator))
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			_ = current.Close()
			return nil, ErrUnsafePath
		}
		nextFD, openErr := secureOpenDirectoryAt(int(current.Fd()), part)
		if errors.Is(openErr, syscall.ENOENT) && createParent {
			if mkdirErr := secureMkdirAt(int(current.Fd()), part, 0o700); mkdirErr != nil && !errors.Is(mkdirErr, syscall.EEXIST) {
				_ = current.Close()
				return nil, mapPathError(mkdirErr)
			}
			nextFD, openErr = secureOpenDirectoryAt(int(current.Fd()), part)
		}
		if openErr != nil {
			_ = current.Close()
			return nil, mapPathError(openErr)
		}
		next := os.NewFile(uintptr(nextFD), part)
		if next == nil {
			_ = secureClose(nextFD)
			_ = current.Close()
			return nil, ErrUnsafePath
		}
		trusted, private := directoryProtection(next)
		if err := validateDirectory(next); err != nil && !(errors.Is(err, ErrUnsafePath) && trustedPath && privateAncestor && trusted) {
			_ = next.Close()
			_ = current.Close()
			return nil, err
		}
		// Only a current-user-owned, ACL-checked path can inherit protection
		// from an earlier private directory. Never relax O_NOFOLLOW or files.
		trustedPath = trustedPath && trusted
		privateAncestor = trustedPath && (privateAncestor || private)
		_ = current.Close()
		current = next
	}
	limit := maxManagedFileBytes
	if cleanPath == filepath.Clean(m.codexCatalogPath()) {
		limit = maxCodexCatalogBytes
	}
	return &managedFile{parent: current, name: name, limit: limit}, nil
}

func validateDirectory(directory *os.File) error {
	info, err := directory.Stat()
	if err != nil {
		return err
	}
	if !info.IsDir() || unsafeDirPerm(info) {
		return ErrUnsafePath
	}
	return nil
}

func (file *managedFile) close() {
	if file != nil && file.parent != nil {
		_ = file.parent.Close()
	}
}

func (file *managedFile) snapshot() (fileSnapshot, error) {
	return file.snapshotName(file.name)
}

func (file *managedFile) snapshotName(name string) (fileSnapshot, error) {
	fd, err := secureOpenReadOnlyAt(int(file.parent.Fd()), name)
	if errors.Is(err, syscall.ENOENT) {
		return fileSnapshot{}, nil
	}
	if err != nil {
		return fileSnapshot{}, mapPathError(err)
	}
	opened := os.NewFile(uintptr(fd), name)
	if opened == nil {
		_ = secureClose(fd)
		return fileSnapshot{}, ErrUnsafePath
	}
	defer opened.Close()

	before, err := opened.Stat()
	if err != nil {
		return fileSnapshot{}, err
	}
	if before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() || unsafeFilePerm(before.Mode()) || before.Size() < 0 || before.Size() > int64(file.limit) {
		return fileSnapshot{}, ErrUnsafePath
	}
	content, err := io.ReadAll(io.LimitReader(opened, int64(file.limit)+1))
	if err != nil {
		return fileSnapshot{}, err
	}
	if len(content) > file.limit {
		return fileSnapshot{}, ErrUnsafePath
	}
	after, err := opened.Stat()
	if err != nil {
		return fileSnapshot{}, err
	}
	if !sameFileInfo(before, after) {
		return fileSnapshot{}, ErrPreconditionChanged
	}
	return fileSnapshot{
		Exists: true,
		Bytes:  content,
		Mode:   before.Mode().Perm(),
		SHA256: digest(content),
	}, nil
}

func (m *Manager) snapshot(path string, createParent bool) (fileSnapshot, error) {
	file, err := m.openManagedFile(path, createParent)
	if errors.Is(err, syscall.ENOENT) {
		return fileSnapshot{}, nil
	}
	if err != nil {
		return fileSnapshot{}, err
	}
	defer file.close()
	return file.snapshot()
}

func (m *Manager) atomicWriteCAS(path string, content []byte, mode os.FileMode, expected fileSnapshot) error {
	file, err := m.openManagedFile(path, true)
	if err != nil {
		return err
	}
	defer file.close()
	if len(content) == 0 || len(content) > file.limit {
		return ErrInvalidInput
	}
	return file.atomicWriteCAS(content, mode, expected)
}

func (file *managedFile) atomicWriteCAS(content []byte, mode os.FileMode, expected fileSnapshot) error {
	temporaryName, err := file.createTemporary(content, mode)
	if err != nil {
		return err
	}
	cleanupTemporary := true
	defer func() {
		if cleanupTemporary {
			_ = secureUnlinkAt(int(file.parent.Fd()), temporaryName)
		}
	}()

	current, err := file.snapshot()
	if err != nil {
		return err
	}
	if !sameSnapshot(current, expected) {
		return ErrPreconditionChanged
	}

	if !expected.Exists {
		if err := secureRenameExclusiveAt(
			int(file.parent.Fd()), temporaryName,
			int(file.parent.Fd()), file.name,
		); err != nil {
			if errors.Is(err, syscall.EEXIST) || errors.Is(err, syscall.ENOENT) {
				return ErrPreconditionChanged
			}
			return mapPathError(err)
		}
		cleanupTemporary = false
		return file.sync()
	}

	if err := secureRenameSwapAt(
		int(file.parent.Fd()), temporaryName,
		int(file.parent.Fd()), file.name,
	); err != nil {
		if errors.Is(err, syscall.ENOENT) {
			return ErrPreconditionChanged
		}
		return mapPathError(err)
	}
	old, snapshotErr := file.snapshotName(temporaryName)
	if snapshotErr != nil || !sameSnapshot(old, expected) {
		var rollbackErr error
		cleanupTemporary, rollbackErr = file.rollbackSwappedWrite(
			temporaryName,
			snapshotForContent(content, mode),
		)
		if rollbackErr != nil {
			return rollbackErr
		}
		if snapshotErr != nil && errors.Is(snapshotErr, ErrUnsafePath) {
			return errors.Join(ErrPreconditionChanged, ErrUnsafePath)
		}
		return ErrPreconditionChanged
	}
	if err := secureUnlinkAt(int(file.parent.Fd()), temporaryName); err != nil {
		cleanupTemporary = false
		return err
	}
	cleanupTemporary = false
	return file.sync()
}

func (file *managedFile) rollbackSwappedWrite(temporaryName string, desired fileSnapshot) (bool, error) {
	currentTarget, err := file.snapshot()
	if err != nil || !sameSnapshot(currentTarget, desired) {
		return false, errors.Join(ErrPreconditionChanged, ErrRollbackFailed)
	}
	if err := secureRenameSwapAt(
		int(file.parent.Fd()), temporaryName,
		int(file.parent.Fd()), file.name,
	); err != nil {
		return false, errors.Join(ErrPreconditionChanged, ErrRollbackFailed)
	}

	swappedOut, err := file.snapshotName(temporaryName)
	if err != nil || !sameSnapshot(swappedOut, desired) {
		// A writer changed the target between the pre-swap snapshot and the
		// swap. Put that value back at the public target name, but keep the
		// displaced old file under its random sibling name so no bytes are
		// silently destroyed.
		if restoreErr := secureRenameSwapAt(
			int(file.parent.Fd()), temporaryName,
			int(file.parent.Fd()), file.name,
		); restoreErr != nil {
			return false, errors.Join(ErrPreconditionChanged, ErrRollbackFailed)
		}
		_ = file.sync()
		return false, errors.Join(ErrPreconditionChanged, ErrRollbackFailed)
	}
	if err := file.sync(); err != nil {
		return true, errors.Join(ErrPreconditionChanged, ErrRollbackFailed)
	}
	return true, nil
}

func (m *Manager) restoreSnapshotCAS(path string, applied, before fileSnapshot) error {
	current, err := m.snapshot(path, false)
	if err != nil {
		return err
	}
	if sameSnapshot(current, before) {
		return nil
	}
	if !sameSnapshot(current, applied) {
		return ErrPreconditionChanged
	}
	if before.Exists {
		mode := before.Mode
		if mode == 0 {
			mode = 0o600
		}
		return m.atomicWriteCAS(path, before.Bytes, mode, applied)
	}
	return m.removeSnapshotCAS(path, applied)
}

func (m *Manager) removeSnapshotCAS(path string, expected fileSnapshot) error {
	file, err := m.openManagedFile(path, false)
	if errors.Is(err, syscall.ENOENT) {
		if expected.Exists {
			return ErrPreconditionChanged
		}
		return nil
	}
	if err != nil {
		return err
	}
	defer file.close()
	current, err := file.snapshot()
	if err != nil {
		return err
	}
	if !sameSnapshot(current, expected) {
		return ErrPreconditionChanged
	}
	if !expected.Exists {
		return nil
	}

	var movedName string
	for attempt := 0; attempt < 8; attempt++ {
		movedName, err = randomTemporaryName()
		if err != nil {
			return err
		}
		err = secureRenameExclusiveAt(
			int(file.parent.Fd()), file.name,
			int(file.parent.Fd()), movedName,
		)
		if errors.Is(err, syscall.EEXIST) {
			continue
		}
		break
	}
	if err != nil {
		if errors.Is(err, syscall.ENOENT) {
			return ErrPreconditionChanged
		}
		return mapPathError(err)
	}
	cleanupMoved := true
	defer func() {
		if cleanupMoved {
			_ = secureUnlinkAt(int(file.parent.Fd()), movedName)
		}
	}()

	moved, snapshotErr := file.snapshotName(movedName)
	if snapshotErr != nil || !sameSnapshot(moved, expected) {
		if restoreErr := secureRenameExclusiveAt(
			int(file.parent.Fd()), movedName,
			int(file.parent.Fd()), file.name,
		); restoreErr != nil {
			cleanupMoved = false
			return errors.Join(ErrPreconditionChanged, ErrRollbackFailed)
		}
		cleanupMoved = false
		if syncErr := file.sync(); syncErr != nil {
			return errors.Join(ErrPreconditionChanged, ErrRollbackFailed)
		}
		return ErrPreconditionChanged
	}
	if err := secureUnlinkAt(int(file.parent.Fd()), movedName); err != nil {
		cleanupMoved = false
		return err
	}
	cleanupMoved = false
	return file.sync()
}

func (file *managedFile) createTemporary(content []byte, mode os.FileMode) (string, error) {
	for attempt := 0; attempt < 8; attempt++ {
		name, err := randomTemporaryName()
		if err != nil {
			return "", err
		}
		fd, err := secureCreateExclusiveAt(int(file.parent.Fd()), name, 0o600)
		if errors.Is(err, syscall.EEXIST) {
			continue
		}
		if err != nil {
			return "", mapPathError(err)
		}
		temporary := os.NewFile(uintptr(fd), name)
		if temporary == nil {
			_ = secureClose(fd)
			return "", ErrUnsafePath
		}
		committed := false
		defer func() {
			_ = temporary.Close()
			if !committed {
				_ = secureUnlinkAt(int(file.parent.Fd()), name)
			}
		}()
		if err := temporary.Chmod(mode); err != nil {
			return "", err
		}
		if _, err := temporary.Write(content); err != nil {
			return "", err
		}
		if err := temporary.Sync(); err != nil {
			return "", err
		}
		if err := temporary.Close(); err != nil {
			return "", err
		}
		committed = true
		return name, nil
	}
	return "", ErrPreconditionChanged
}

func (file *managedFile) sync() error {
	return secureFsync(int(file.parent.Fd()))
}

func randomTemporaryName() (string, error) {
	randomBytes := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, randomBytes); err != nil {
		return "", err
	}
	return ".zhiban-config-" + hex.EncodeToString(randomBytes), nil
}

func mapPathError(err error) error {
	if errors.Is(err, syscall.ELOOP) || errors.Is(err, syscall.ENOTDIR) || errors.Is(err, syscall.ENOTSUP) {
		return ErrUnsafePath
	}
	return err
}
