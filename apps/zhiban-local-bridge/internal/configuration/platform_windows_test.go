//go:build windows

package configuration

import (
	"errors"
	"os"
	"syscall"
	"testing"
)

// Replacing a file another process holds open fails with a sharing or lock
// violation, or with the access denial MoveFileEx reports when the target is
// open without FILE_SHARE_DELETE (Codex Desktop keeps rewriting config.toml).
func TestIsFileInUseRecognisesWindowsSharingFailures(t *testing.T) {
	for _, errno := range []syscall.Errno{5, 32, 33} {
		if !IsFileInUse(&os.LinkError{Op: "rename", Old: "a", New: "b", Err: errno}) {
			t.Errorf("IsFileInUse(errno %d) = false", errno)
		}
	}
	if IsFileInUse(&os.PathError{Op: "open", Path: "a", Err: syscall.Errno(2)}) || IsFileInUse(errors.New("other")) {
		t.Error("a missing file and a plain error must not count as in use")
	}
}
