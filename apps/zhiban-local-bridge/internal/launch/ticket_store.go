package launch

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const maxTicketBytes = 128 << 10

type FileTicketStore struct {
	homeDir          string
	rootDir          string
	helperExecutable string
}

func NewFileTicketStore(homeDir, rootDir, helperExecutable string) (*FileTicketStore, error) {
	rawHome := filepath.Clean(strings.TrimSpace(homeDir))
	rawRoot := filepath.Clean(strings.TrimSpace(rootDir))
	if !filepath.IsAbs(rawHome) || !pathInside(rawRoot, rawHome) {
		return nil, ErrInvalidInput
	}
	relativeRoot, err := filepath.Rel(rawHome, rawRoot)
	if err != nil {
		return nil, ErrInvalidInput
	}
	home, err := filepath.EvalSymlinks(rawHome)
	if err != nil {
		return nil, ErrInvalidInput
	}
	root := filepath.Join(home, relativeRoot)
	helper, err := filepath.EvalSymlinks(filepath.Clean(strings.TrimSpace(helperExecutable)))
	if err != nil || !filepath.IsAbs(helper) || validateHelperExecutable(helper) != nil {
		return nil, ErrInvalidInput
	}
	return &FileTicketStore{homeDir: home, rootDir: root, helperExecutable: helper}, nil
}

func DefaultLaunchRoot(homeDir string) string {
	return filepath.Join(appSupportBase(homeDir), "cn.qkfintech.zhiban", "local-coding-tools", "launch")
}

func (s *FileTicketStore) Create(ticket launchTicket) (string, error) {
	if !validOpaqueID(ticket.ID) {
		return "", ErrTicketStoreFailed
	}
	encoded, err := json.Marshal(ticket)
	if err != nil || len(encoded) == 0 || len(encoded) > maxTicketBytes {
		return "", ErrTicketStoreFailed
	}
	encoded = append(encoded, '\n')
	root, err := s.openRoot(true)
	if err != nil {
		return "", ErrTicketStoreFailed
	}
	defer root.Close()

	ticketName := ticket.ID + ".ticket"
	if err := createProtectedFileAt(root, ticketName, encoded, 0o600); err != nil {
		return "", ErrTicketStoreFailed
	}
	scriptName, script, scriptMode := trampolineScript(s.helperExecutable, ticket.ID)
	if err := createProtectedFileAt(root, scriptName, script, scriptMode); err != nil {
		_ = secureUnlinkAt(int(root.Fd()), ticketName)
		_ = secureFsync(int(root.Fd()))
		return "", ErrTicketStoreFailed
	}
	if err := secureFsync(int(root.Fd())); err != nil {
		_ = secureUnlinkAt(int(root.Fd()), ticketName)
		_ = secureUnlinkAt(int(root.Fd()), scriptName)
		return "", ErrTicketStoreFailed
	}
	return filepath.Join(s.rootDir, scriptName), nil
}

func (s *FileTicketStore) Claim(ticketID string) (launchTicket, error) {
	if !validOpaqueID(ticketID) {
		return launchTicket{}, ErrTicketNotFound
	}
	root, err := s.openRoot(false)
	if err != nil {
		return launchTicket{}, ErrTicketNotFound
	}
	defer root.Close()
	ticketName := ticketID + ".ticket"
	claimedName := ".claimed-" + ticketID
	if err := secureRenameExclusiveAt(int(root.Fd()), ticketName, int(root.Fd()), claimedName); err != nil {
		if errors.Is(err, syscall.ENOENT) {
			return launchTicket{}, ErrTicketNotFound
		}
		return launchTicket{}, ErrTicketStoreFailed
	}
	// Remove the trampoline script for whichever platform wrote it (.command on
	// macOS, .cmd on Windows); best-effort, the ticket is already claimed.
	_ = secureUnlinkAt(int(root.Fd()), ticketID+".command")
	_ = secureUnlinkAt(int(root.Fd()), ticketID+".cmd")
	defer func() {
		_ = secureUnlinkAt(int(root.Fd()), claimedName)
		_ = secureFsync(int(root.Fd()))
	}()

	content, err := readProtectedFileAt(root, claimedName)
	if err != nil {
		return launchTicket{}, ErrTicketStoreFailed
	}
	var ticket launchTicket
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&ticket) != nil || decoder.Decode(&struct{}{}) != io.EOF || ticket.ID != ticketID {
		return launchTicket{}, ErrTicketStoreFailed
	}
	return ticket, nil
}

func (s *FileTicketStore) Remove(ticketID string) error {
	if !validOpaqueID(ticketID) {
		return ErrTicketStoreFailed
	}
	root, err := s.openRoot(false)
	if err != nil {
		return ErrTicketStoreFailed
	}
	defer root.Close()
	for _, name := range []string{ticketID + ".ticket", ticketID + ".command"} {
		if err := secureUnlinkAt(int(root.Fd()), name); err != nil && !errors.Is(err, syscall.ENOENT) {
			return ErrTicketStoreFailed
		}
	}
	if err := secureFsync(int(root.Fd())); err != nil {
		return ErrTicketStoreFailed
	}
	return nil
}

func (s *FileTicketStore) openRoot(create bool) (*os.File, error) {
	rootFD, err := secureOpenDirectory(s.homeDir)
	if err != nil {
		return nil, err
	}
	current := os.NewFile(uintptr(rootFD), s.homeDir)
	if current == nil {
		_ = secureClose(rootFD)
		return nil, ErrTicketStoreFailed
	}
	if err := validatePrivateDirectory(current, false); err != nil {
		_ = current.Close()
		return nil, err
	}
	relative, err := filepath.Rel(s.homeDir, s.rootDir)
	if err != nil || relative == "." || strings.HasPrefix(relative, "..") {
		_ = current.Close()
		return nil, ErrTicketStoreFailed
	}
	parts := strings.Split(relative, string(filepath.Separator))
	for index, part := range parts {
		if part == "" || part == "." || part == ".." {
			_ = current.Close()
			return nil, ErrTicketStoreFailed
		}
		nextFD, openErr := secureOpenDirectoryAt(int(current.Fd()), part)
		if errors.Is(openErr, syscall.ENOENT) && create {
			if mkdirErr := secureMkdirAt(int(current.Fd()), part, 0o700); mkdirErr != nil && !errors.Is(mkdirErr, syscall.EEXIST) {
				_ = current.Close()
				return nil, mkdirErr
			}
			nextFD, openErr = secureOpenDirectoryAt(int(current.Fd()), part)
		}
		if openErr != nil {
			_ = current.Close()
			return nil, openErr
		}
		next := os.NewFile(uintptr(nextFD), part)
		if next == nil {
			_ = secureClose(nextFD)
			_ = current.Close()
			return nil, ErrTicketStoreFailed
		}
		if err := validatePrivateDirectory(next, index == len(parts)-1); err != nil {
			_ = next.Close()
			_ = current.Close()
			return nil, err
		}
		_ = current.Close()
		current = next
	}
	return current, nil
}

func validatePrivateDirectory(directory *os.File, requirePrivate bool) error {
	info, err := directory.Stat()
	if err != nil || !info.IsDir() || dirWritableByOthers(info) {
		return ErrTicketStoreFailed
	}
	if requirePrivate {
		if err := ensureDirPrivate(directory, info); err != nil {
			return ErrTicketStoreFailed
		}
	}
	return nil
}

func createProtectedFileAt(directory *os.File, name string, content []byte, mode os.FileMode) error {
	fd, err := secureCreateExclusiveAt(int(directory.Fd()), name, uint32(mode.Perm()))
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		_ = secureClose(fd)
		return ErrTicketStoreFailed
	}
	remove := true
	defer func() {
		_ = file.Close()
		if remove {
			_ = secureUnlinkAt(int(directory.Fd()), name)
		}
	}()
	if err := file.Chmod(mode); err != nil {
		return err
	}
	if _, err := file.Write(content); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	remove = false
	return nil
}

func readProtectedFileAt(directory *os.File, name string) ([]byte, error) {
	fd, err := secureOpenReadOnlyAt(int(directory.Fd()), name)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		_ = secureClose(fd)
		return nil, ErrTicketStoreFailed
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || fileGroupOrOtherPerm(info) || info.Size() <= 0 || info.Size() > maxTicketBytes {
		return nil, ErrTicketStoreFailed
	}
	content, err := io.ReadAll(io.LimitReader(file, maxTicketBytes+1))
	if err != nil || len(content) > maxTicketBytes {
		return nil, ErrTicketStoreFailed
	}
	return content, nil
}

func validateHelperExecutable(path string) error {
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || !helperModeOK(info.Mode()) {
		return ErrInvalidInput
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || !samePath(resolved, path) {
		return ErrInvalidInput
	}
	return nil
}

func pathInside(path, root string) bool {
	path = filepath.Clean(path)
	root = filepath.Clean(root)
	return path != root && strings.HasPrefix(path, root+string(filepath.Separator))
}

func shellQuoteFixed(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
