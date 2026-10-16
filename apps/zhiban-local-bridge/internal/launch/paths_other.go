//go:build !windows

package launch

import (
	"os"
	"path/filepath"
)

// appSupportBase is the per-user application-support root. On macOS (and other
// Unix) this is ~/Library/Application Support.
func appSupportBase(homeDir string) string {
	return filepath.Join(homeDir, "Library", "Application Support")
}

// helperModeOK enforces the Unix permission invariants for the bundled helper:
// it must be executable and not group/other-writable.
func helperModeOK(mode os.FileMode) bool {
	return mode.Perm()&0o111 != 0 && mode.Perm()&0o022 == 0
}

// execBitMissing reports whether a Unix executable bit is absent (used to
// reject a non-executable CLI). Meaningless on Windows.
func execBitMissing(mode os.FileMode) bool { return mode.Perm()&0o111 == 0 }

// trampolineScript is the one-shot launcher the terminal opens: it re-execs the
// bundled helper in "launch consume" mode. On macOS/Unix it is a .command
// shell script that exec-replaces itself with the helper.
func trampolineScript(helper, ticketID string) (string, []byte, os.FileMode) {
	content := []byte("#!/bin/sh\nexec " + shellQuoteFixed(helper) + " launch consume --ticket '" + ticketID + "'\n")
	return ticketID + ".command", content, 0o700
}

// dirWritableByOthers / ensureDirPrivate enforce the Unix private-directory
// invariants (not group/other-writable, 0700). On Windows these are synthetic.
func dirWritableByOthers(info os.FileInfo) bool { return info.Mode().Perm()&0o022 != 0 }

func ensureDirPrivate(directory *os.File, info os.FileInfo) error {
	if info.Mode().Perm() != 0o700 {
		return directory.Chmod(0o700)
	}
	return nil
}

// fileGroupOrOtherPerm reports whether a file grants any group/other
// permission (a protected ticket must be 0600). Synthetic on Windows.
func fileGroupOrOtherPerm(info os.FileInfo) bool { return info.Mode().Perm()&0o077 != 0 }
