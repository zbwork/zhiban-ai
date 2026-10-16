package install

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"hash"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

var (
	errUnsafePath = errors.New("install: unsafe path")
	errConflict   = errors.New("install: target conflict")
)

// openDirectoryChain opens baseDir and then every part with O_DIRECTORY and
// O_NOFOLLOW, creating missing parts with mode when create is set. Every
// directory on the way must be a real directory that is not group or world
// writable; the one exception is the system /Applications folder, which macOS
// ships group-writable for administrators. The returned handle is the last part.
func openDirectoryChain(baseDir string, parts []string, create bool, mode uint32) (*os.File, error) {
	rootFD, err := secureOpenDirectory(baseDir)
	if err != nil {
		return nil, mapPathError(err)
	}
	current := os.NewFile(uintptr(rootFD), baseDir)
	if current == nil {
		_ = secureClose(rootFD)
		return nil, errUnsafePath
	}
	if err := validateDirectory(current); err != nil {
		_ = current.Close()
		return nil, err
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." || strings.ContainsRune(part, filepath.Separator) {
			_ = current.Close()
			return nil, errUnsafePath
		}
		nextFD, openErr := secureOpenDirectoryAt(int(current.Fd()), part)
		if errors.Is(openErr, syscall.ENOENT) && create {
			if mkdirErr := secureMkdirAt(int(current.Fd()), part, mode); mkdirErr != nil && !errors.Is(mkdirErr, syscall.EEXIST) {
				_ = current.Close()
				return nil, mapPathError(mkdirErr)
			}
			nextFD, openErr = secureOpenDirectoryAt(int(current.Fd()), part)
		}
		if openErr != nil {
			_ = current.Close()
			return nil, mapPathError(openErr)
		}
		next := os.NewFile(uintptr(nextFD), filepath.Join(current.Name(), part))
		if next == nil {
			_ = secureClose(nextFD)
			_ = current.Close()
			return nil, errUnsafePath
		}
		validate := validateDirectory
		if filepath.Clean(next.Name()) == defaultSystemApplicationsDir {
			validate = validateSystemApplicationsDirectory
		}
		if err := validate(next); err != nil {
			_ = next.Close()
			_ = current.Close()
			return nil, err
		}
		_ = current.Close()
		current = next
	}
	return current, nil
}

func validateDirectory(directory *os.File) error {
	info, err := directory.Stat()
	if err != nil {
		return err
	}
	if !info.IsDir() || dirModeUnsafe(info) {
		return errUnsafePath
	}
	return nil
}

// createTemporaryAt creates an exclusive 0600 scratch file inside directory.
func createTemporaryAt(directory *os.File, prefix string) (*os.File, string, error) {
	for attempt := 0; attempt < 8; attempt++ {
		name, err := randomName(prefix)
		if err != nil {
			return nil, "", err
		}
		fd, err := secureCreateExclusiveAt(int(directory.Fd()), name, 0o600)
		if errors.Is(err, syscall.EEXIST) {
			continue
		}
		if err != nil {
			return nil, "", mapPathError(err)
		}
		file := os.NewFile(uintptr(fd), filepath.Join(directory.Name(), name))
		if file == nil {
			_ = secureClose(fd)
			return nil, "", errUnsafePath
		}
		return file, name, nil
	}
	return nil, "", errUnsafePath
}

// writeRegularAt streams exactly size bytes from source into a temporary file
// inside directory, sets mode, syncs, then renames it exclusively to finalName.
// When expectedSHA256 is set the bytes must hash to it before the rename. An
// existing entry with that name is a conflict and is never replaced.
func writeRegularAt(directory *os.File, finalName string, source io.Reader, size int64, mode os.FileMode, expectedSHA256 string) error {
	if finalName == "" || finalName == "." || finalName == ".." || strings.ContainsRune(finalName, filepath.Separator) || size <= 0 {
		return errUnsafePath
	}
	var hasher hash.Hash
	if expectedSHA256 != "" {
		hasher = sha256.New()
		source = io.TeeReader(source, hasher)
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
	written, err := io.Copy(temporary, io.LimitReader(source, size+1))
	if err != nil {
		return errDownloadFailed
	}
	if written != size {
		return errSizeMismatch
	}
	if hasher != nil && hex.EncodeToString(hasher.Sum(nil)) != expectedSHA256 {
		return errHashMismatch
	}
	if err := temporary.Chmod(mode); err != nil {
		return mapPathError(err)
	}
	if err := temporary.Sync(); err != nil {
		return mapPathError(err)
	}
	if err := temporary.Close(); err != nil {
		return mapPathError(err)
	}
	if err := secureRenameExclusiveAt(int(directory.Fd()), temporaryName, int(directory.Fd()), finalName); err != nil {
		if errors.Is(err, syscall.EEXIST) {
			return errConflict
		}
		return mapPathError(err)
	}
	committed = true
	return secureFsync(int(directory.Fd()))
}

// moveAsideAt renames directory/name to a fresh hidden name in the same
// directory so a replacement can be placed exclusively, and returns that
// name. It returns "" when nothing occupied name.
func moveAsideAt(directory *os.File, name string) (string, error) {
	return moveAsidePrefixedAt(directory, name, ".zhiban-damaged-")
}

// moveAsidePrefixedAt is moveAsideAt with the caller's hidden-name prefix
// (the Windows launcher swap keeps the old launcher under its own prefix).
func moveAsidePrefixedAt(directory *os.File, name, prefix string) (string, error) {
	if name == "" || name == "." || name == ".." || strings.ContainsRune(name, filepath.Separator) {
		return "", errUnsafePath
	}
	for attempt := 0; attempt < 8; attempt++ {
		aside, err := randomName(prefix)
		if err != nil {
			return "", err
		}
		err = secureRenameExclusiveAt(int(directory.Fd()), name, int(directory.Fd()), aside)
		if pathHeldByAnotherProcess(err) && waitForPathRelease(directory.Name(), name) {
			// Windows: the on-access scanner (YunShu / Defender on the test
			// machine) keeps handles open inside a directory whose files
			// were just written or run; the rename fails with access denied
			// for a few seconds and then goes through.
			err = secureRenameExclusiveAt(int(directory.Fd()), name, int(directory.Fd()), aside)
		}
		switch {
		case err == nil:
			if err := secureFsync(int(directory.Fd())); err != nil {
				return aside, mapPathError(err)
			}
			return aside, nil
		case errors.Is(err, syscall.ENOENT):
			return "", nil
		case errors.Is(err, syscall.EEXIST):
			continue
		default:
			return "", mapPathError(err)
		}
	}
	return "", errUnsafePath
}

// ensureSymlinkAt creates directory/name -> target, reusing an identical
// existing symlink and refusing anything else that occupies the name.
func ensureSymlinkAt(directory *os.File, name, target string) error {
	if name == "" || name == "." || name == ".." || strings.ContainsRune(name, filepath.Separator) || !filepath.IsAbs(target) {
		return errUnsafePath
	}
	err := secureSymlinkAt(target, int(directory.Fd()), name)
	if err == nil {
		return secureFsync(int(directory.Fd()))
	}
	if !errors.Is(err, syscall.EEXIST) {
		return mapPathError(err)
	}
	if existingSymlinkTarget(filepath.Join(directory.Name(), name)) == target {
		return nil
	}
	return errConflict
}

// replaceSymlinkAt points directory/name at target atomically (upgrade and
// rollback re-point ~/.local/bin/<tool>): a fresh symlink is created under a
// hidden name and renamed over name, so a reader sees either the old or the
// new link and never nothing. Only a missing entry or an existing symlink may
// be replaced; a regular file or directory occupying name is a conflict. It
// returns the previous link target ("" when there was none) so a failed
// switch can be undone.
func replaceSymlinkAt(directory *os.File, name, target string) (string, error) {
	if name == "" || name == "." || name == ".." || strings.ContainsRune(name, filepath.Separator) || !filepath.IsAbs(target) {
		return "", errUnsafePath
	}
	linkPath := filepath.Join(directory.Name(), name)
	previous := ""
	if info, err := os.Lstat(linkPath); err == nil {
		if info.Mode()&os.ModeSymlink == 0 {
			return "", errConflict
		}
		previous = existingSymlinkTarget(linkPath)
		if previous == filepath.Clean(target) {
			return previous, nil
		}
	}
	for attempt := 0; attempt < 8; attempt++ {
		temporary, err := randomName(".zhiban-link-")
		if err != nil {
			return previous, err
		}
		err = secureSymlinkAt(target, int(directory.Fd()), temporary)
		if errors.Is(err, syscall.EEXIST) {
			continue
		}
		if err != nil {
			return previous, mapPathError(err)
		}
		if err := secureRenameAt(int(directory.Fd()), temporary, int(directory.Fd()), name); err != nil {
			_ = secureUnlinkAt(int(directory.Fd()), temporary)
			return previous, mapPathError(err)
		}
		return previous, secureFsync(int(directory.Fd()))
	}
	return previous, errUnsafePath
}

// existingSymlinkTarget returns the absolute target of path when it is a
// symlink, or "" for anything else (missing, regular file, directory).
func existingSymlinkTarget(path string) string {
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		return ""
	}
	target, err := os.Readlink(path)
	if err != nil || !filepath.IsAbs(target) {
		return ""
	}
	return filepath.Clean(target)
}

func randomName(prefix string) (string, error) {
	value := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, value); err != nil {
		return "", err
	}
	return prefix + hex.EncodeToString(value), nil
}

func mapPathError(err error) error {
	if errors.Is(err, syscall.ELOOP) || errors.Is(err, syscall.ENOTDIR) || errors.Is(err, syscall.ENOTSUP) {
		return errUnsafePath
	}
	return err
}
