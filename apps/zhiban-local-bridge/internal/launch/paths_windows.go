//go:build windows

package launch

import (
	"os"
	"path/filepath"
	"strings"
)

// appSupportBase is the per-user application-support root. On Windows this is
// %LOCALAPPDATA% (…\AppData\Local), which lives inside the user profile and
// carries restrictive per-user ACLs.
func appSupportBase(homeDir string) string {
	if base := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); base != "" {
		return base
	}
	return filepath.Join(homeDir, "AppData", "Local")
}

// helperModeOK: Windows file permission bits reported by os.Lstat are
// synthetic, so the Unix executable/writable checks do not apply. Safety comes
// from the file being a real (non-reparse) regular file under a per-user,
// ACL-protected location, which the caller already verifies.
func helperModeOK(os.FileMode) bool { return true }

// execBitMissing: Windows has no executable bit; a real regular file with a
// launcher extension is runnable. Never treat it as missing here.
func execBitMissing(os.FileMode) bool { return false }

// trampolineScript on Windows is a .cmd batch file that runs the bundled helper
// in "launch consume" mode as a child (cmd has no exec-replace). The helper
// path is double-quoted (may contain spaces); the ticket ID is a validated
// opaque token with no shell metacharacters. CRLF line endings for cmd.exe.
//
// The file is UTF-8, but cmd.exe parses a batch file line by line in the
// console's current code page, and the console `start` creates uses the OEM
// code page (936 on zh-CN). The helper lives under `C:\Program Files\知办AI\`,
// so without a code-page switch the path line decodes as garbage and cmd
// reports "系统找不到指定的路径" (2026-09-10 Windows real machine). The first
// two lines are pure ASCII and parse under any code page; `chcp 65001` then
// makes cmd read the rest as UTF-8 and leaves the CLI a UTF-8 console.
func trampolineScript(helper, ticketID string) (string, []byte, os.FileMode) {
	quotedHelper := "\"" + helper + "\""
	line := "@echo off\r\n@chcp 65001 >nul\r\n" + quotedHelper + " launch consume --ticket \"" + ticketID + "\"\r\n"
	return ticketID + ".cmd", []byte(line), 0o600
}

// dirWritableByOthers / ensureDirPrivate: directory permission bits are
// synthetic on Windows, so the Unix "not other-writable" / "0700" invariants
// do not apply. Per-user ACLs under the profile provide the protection.
func dirWritableByOthers(os.FileInfo) bool         { return false }
func ensureDirPrivate(*os.File, os.FileInfo) error { return nil }

// fileGroupOrOtherPerm: file permission bits are synthetic on Windows.
func fileGroupOrOtherPerm(os.FileInfo) bool { return false }
