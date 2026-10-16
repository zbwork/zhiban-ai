//go:build windows

package configuration

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// maxClaudeDesktopHelperBytes bounds the Bridge copy that serves as Claude
// Desktop's credential helper. The copy is a whole program (11 MB on
// 2026-09-10), far above the managed-file limit that governs config files.
const maxClaudeDesktopHelperBytes = 64 << 20

func localAppData(homeDir string) string {
	if value := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); value != "" {
		return value
	}
	return filepath.Join(homeDir, "AppData", "Local")
}

// claudeDesktopSupportRoot is where Claude Desktop keeps its third-party
// configuration on Windows: %LOCALAPPDATA%\Claude-3p (read out of the app's
// own path logic, 2026-09-10; unvirtualizedResources means the real folder).
func (m *Manager) claudeDesktopSupportRoot() string {
	return filepath.Join(localAppData(m.homeDir), claudeDesktopSupportDir)
}

// claudeDesktopHelperPath is the no-argument credential helper the app runs.
func (m *Manager) claudeDesktopHelperPath() string {
	return filepath.Join(localAppData(m.homeDir), applicationSupportID, "local-coding-tools", ClaudeDesktopHelperExecutable)
}

// ensureClaudeDesktopHelper copies the running Bridge executable to the
// helper path when the copy is missing or differs (a Bridge update refreshes
// it on the next switch). The copy takes the managed-file directory
// traversal and temporary-then-rename steps, but is compared and installed
// by streaming: snapshot / atomicWriteCAS refuse anything above
// maxManagedFileBytes, which turned the App's switch into an internal error
// on the 2026-09-10 real machine.
func (m *Manager) ensureClaudeDesktopHelper() error {
	content, err := os.ReadFile(m.helperExecutable)
	if err != nil {
		return err
	}
	if len(content) == 0 || len(content) > maxClaudeDesktopHelperBytes {
		return ErrInvalidInput
	}
	file, err := m.openManagedFile(m.claudeDesktopHelperPath(), true)
	if err != nil {
		return err
	}
	defer file.close()
	same, err := file.sameContent(content)
	if err != nil {
		return err
	}
	if same {
		return nil
	}
	return file.replaceContent(content, 0o700)
}

// sameContent reports whether the managed name holds exactly content.
func (file *managedFile) sameContent(content []byte) (bool, error) {
	fd, err := secureOpenReadOnlyAt(int(file.parent.Fd()), file.name)
	if errors.Is(err, syscall.ENOENT) {
		return false, nil
	}
	if err != nil {
		return false, mapPathError(err)
	}
	opened := os.NewFile(uintptr(fd), file.name)
	if opened == nil {
		_ = secureClose(fd)
		return false, ErrUnsafePath
	}
	defer opened.Close()
	info, err := opened.Stat()
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Size() != int64(len(content)) {
		return false, nil
	}
	buffer := make([]byte, 1<<20)
	offset := 0
	for {
		n, err := opened.Read(buffer)
		if offset+n > len(content) || !bytes.Equal(buffer[:n], content[offset:offset+n]) {
			return false, nil
		}
		offset += n
		if errors.Is(err, io.EOF) {
			return offset == len(content), nil
		}
		if err != nil {
			return false, err
		}
	}
}

// replaceContent installs content under the managed name through a temporary
// sibling. An existing copy is swapped out rather than overwritten (Windows
// lets a running executable be renamed but not replaced) and then deleted; a
// copy that is executing at that moment stays behind under its random
// temporary name in Zhiban's own folder, which is harmless.
func (file *managedFile) replaceContent(content []byte, mode os.FileMode) error {
	temporaryName, err := file.createTemporary(content, mode)
	if err != nil {
		return err
	}
	parent := int(file.parent.Fd())
	err = secureRenameExclusiveAt(parent, temporaryName, parent, file.name)
	if errors.Is(err, os.ErrExist) {
		if err = secureRenameSwapAt(parent, temporaryName, parent, file.name); err == nil {
			_ = secureUnlinkAt(parent, temporaryName)
			return file.sync()
		}
	}
	if err != nil {
		_ = secureUnlinkAt(parent, temporaryName)
		return mapPathError(err)
	}
	return file.sync()
}
