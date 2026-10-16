// Package shellpath makes the user's own command line resolve the launcher
// Zhiban manages (contract §2.7 "接管安装", 2026-09-16).
//
// Taking a target over is not finished when the launcher under ~/.local/bin
// points at Zhiban's copy: if the user's PATH resolves an npm or Homebrew copy
// first, their terminal keeps running the old one — and once Zhiban writes its
// configuration, that old copy refuses to start at all. So an adopt either
// makes the login shell resolve the managed launcher or it fails; it never
// leaves the two halves disagreeing.
//
// The edit is one marked block appended to the shell's own startup file, the
// same line the publishers' installers add. The original file is copied to the
// backup directory first, and deleting the block restores the old behaviour.
package shellpath

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	// BlockStart and blockEnd delimit the block this package owns. Everything
	// between them is Zhiban's; everything outside is the user's and is never
	// read, reordered or rewritten.
	BlockStart = "# >>> zhiban local coding tools >>>"
	blockEnd   = "# <<< zhiban local coding tools <<<"
)

var (
	// ErrUnsupportedShell: no startup file is known for this login shell, so
	// the PATH cannot be arranged for the user.
	ErrUnsupportedShell = errors.New("shellpath: unsupported login shell")
	// ErrNotApplied: the startup file was written but the login shell still
	// resolves another copy (another startup file puts it earlier).
	ErrNotApplied = errors.New("shellpath: login shell still resolves another copy")
	// ErrWriteFailed: the startup file could not be written.
	ErrWriteFailed = errors.New("shellpath: startup file not writable")
)

// Ensurer arranges the user's own PATH so a command runs the managed launcher.
//
// Unix: the login shell's startup file (Lookup reports which absolute path that
// shell resolves a name to; Invalidate drops what it cached). Windows: the
// per-user PATH in the registry — there is no login shell there, the GUI
// inherits the user's environment, so ReadPath / WritePath stand in for it.
type Ensurer struct {
	HomeDir   string
	Shell     string
	BackupDir string
	// Lookup / Invalidate: Unix only.
	Lookup     func(ctx context.Context, name string) (string, bool)
	Invalidate func()
	// ReadPath / WritePath: Windows only; nil uses the real registry.
	ReadPath  func() (user string, machine string, err error)
	WritePath func(user string) error
	Now       func() time.Time
}

// Ensure makes the user's own command line resolve name at launcherPath. It
// returns nil when it already does, after arranging the PATH when it did not,
// and an error when it still does not.
func (e *Ensurer) Ensure(ctx context.Context, name, launcherPath string) error {
	if e == nil {
		return ErrUnsupportedShell
	}
	if e.resolves(ctx, name, launcherPath) {
		return nil
	}
	if err := e.arrange(launcherPath); err != nil {
		return err
	}
	if e.Invalidate != nil {
		e.Invalidate()
	}
	if !e.resolves(ctx, name, launcherPath) {
		return ErrNotApplied
	}
	return nil
}

// sameFile compares by identity, not by spelling: the launcher is reached
// through a symlink on macOS, so string comparison would miss the match.
func sameFile(left, right string) bool {
	if left == "" || right == "" {
		return false
	}
	if filepath.Clean(left) == filepath.Clean(right) {
		return true
	}
	leftInfo, err := os.Stat(left)
	if err != nil {
		return false
	}
	rightInfo, err := os.Stat(right)
	if err != nil {
		return false
	}
	return os.SameFile(leftInfo, rightInfo)
}

// startupFile is the file this shell reads when it starts, plus the line that
// puts ~/.local/bin first in it. Unix only.
func (e *Ensurer) startupFile() (string, string, bool) {
	home := filepath.Clean(e.HomeDir)
	if home == "." || !filepath.IsAbs(home) {
		return "", "", false
	}
	switch filepath.Base(strings.TrimSpace(e.Shell)) {
	case "zsh":
		return filepath.Join(home, ".zshrc"), `export PATH="$HOME/.local/bin:$PATH"`, true
	case "bash", "sh":
		// macOS starts login shells, which read .bash_profile, not .bashrc.
		return filepath.Join(home, ".bash_profile"), `export PATH="$HOME/.local/bin:$PATH"`, true
	case "fish":
		return filepath.Join(home, ".config", "fish", "config.fish"),
			"set -gx PATH $HOME/.local/bin $PATH", true
	default:
		return "", "", false
	}
}

// appendBlock adds the marked block to path, once. The file is replaced
// atomically and its original content is backed up first; content outside the
// block is copied through byte for byte.
func (e *Ensurer) appendBlock(path, line string) error {
	existing, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: %s", ErrWriteFailed, filepath.Base(path))
	}
	if strings.Contains(string(existing), BlockStart) {
		// Already ours: the shell resolving something else means another
		// startup file wins, which appending again would not fix.
		return ErrNotApplied
	}
	if err := e.backup(path, existing); err != nil {
		return err
	}
	block := "\n" + BlockStart + "\n" +
		"# 知办接管的 AI 编程工具命令行在这里；删掉本段即可恢复原来的 PATH。\n" +
		line + "\n" + blockEnd + "\n"
	content := string(existing)
	if content != "" && !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	return writeFileAtomic(path, []byte(content+block))
}

// backup keeps the original before a change. name is the startup file's path
// on Unix and a plain label ("user-path") on Windows.
func (e *Ensurer) backup(path string, content []byte) error {
	if len(content) == 0 || strings.TrimSpace(e.BackupDir) == "" {
		return nil
	}
	if err := os.MkdirAll(e.BackupDir, 0o700); err != nil {
		return fmt.Errorf("%w: backup dir", ErrWriteFailed)
	}
	now := time.Now
	if e.Now != nil {
		now = e.Now
	}
	name := fmt.Sprintf("%s.%s.bak", filepath.Base(path), now().UTC().Format("20060102T150405Z"))
	if err := os.WriteFile(filepath.Join(e.BackupDir, name), content, 0o600); err != nil {
		return fmt.Errorf("%w: backup", ErrWriteFailed)
	}
	return nil
}

func writeFileAtomic(path string, content []byte) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return fmt.Errorf("%w: %s", ErrWriteFailed, filepath.Base(path))
	}
	mode := os.FileMode(0o644)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	temporary, err := os.CreateTemp(directory, ".zhiban-shellrc-")
	if err != nil {
		return fmt.Errorf("%w: %s", ErrWriteFailed, filepath.Base(path))
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err := io.Copy(temporary, strings.NewReader(string(content))); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("%w: %s", ErrWriteFailed, filepath.Base(path))
	}
	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("%w: %s", ErrWriteFailed, filepath.Base(path))
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("%w: %s", ErrWriteFailed, filepath.Base(path))
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("%w: %s", ErrWriteFailed, filepath.Base(path))
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("%w: %s", ErrWriteFailed, filepath.Base(path))
	}
	return nil
}
