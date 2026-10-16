//go:build windows

package configuration

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// TestWindowsSecurePrimitives exercises the Windows secure_syscall layer step
// by step to localize any "Access is denied" failure in the swap/rename path.
func TestWindowsSecurePrimitives(t *testing.T) {
	dir := t.TempDir()

	parentFd, err := secureOpenDirectory(dir)
	if err != nil {
		t.Fatalf("secureOpenDirectory: %v", err)
	}
	defer secureClose(parentFd)

	// create a.tmp with "old"
	aFd, err := secureCreateExclusiveAt(parentFd, "a.tmp", 0o600)
	if err != nil {
		t.Fatalf("create a.tmp: %v", err)
	}
	af := os.NewFile(uintptr(aFd), filepath.Join(dir, "a.tmp"))
	if _, err := af.Write([]byte("old")); err != nil {
		t.Fatalf("write a.tmp: %v", err)
	}
	if err := af.Close(); err != nil {
		t.Fatalf("close a.tmp: %v", err)
	}

	// create b.tmp with "new"
	bFd, err := secureCreateExclusiveAt(parentFd, "b.tmp", 0o600)
	if err != nil {
		t.Fatalf("create b.tmp: %v", err)
	}
	bf := os.NewFile(uintptr(bFd), filepath.Join(dir, "b.tmp"))
	if _, err := bf.Write([]byte("new")); err != nil {
		t.Fatalf("write b.tmp: %v", err)
	}
	if err := bf.Close(); err != nil {
		t.Fatalf("close b.tmp: %v", err)
	}

	// swap b.tmp <-> a.tmp : a.tmp should become "new", b.tmp "old"
	if err := secureRenameSwapAt(parentFd, "b.tmp", parentFd, "a.tmp"); err != nil {
		t.Fatalf("secureRenameSwapAt: %v", err)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "a.tmp")); string(got) != "new" {
		t.Fatalf("after swap a.tmp = %q, want new", got)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "b.tmp")); string(got) != "old" {
		t.Fatalf("after swap b.tmp = %q, want old", got)
	}

	// exclusive rename b.tmp -> c.txt (target absent)
	if err := secureRenameExclusiveAt(parentFd, "b.tmp", parentFd, "c.txt"); err != nil {
		t.Fatalf("secureRenameExclusiveAt: %v", err)
	}
	// unlink c.txt
	if err := secureUnlinkAt(parentFd, "c.txt"); err != nil {
		t.Fatalf("secureUnlinkAt: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "c.txt")); !os.IsNotExist(err) {
		t.Fatalf("c.txt still exists after unlink: %v", err)
	}

	// rename with an OPEN handle on the source (share-delete must allow it)
	dFd, err := secureCreateExclusiveAt(parentFd, "d.tmp", 0o600)
	if err != nil {
		t.Fatalf("create d.tmp: %v", err)
	}
	df := os.NewFile(uintptr(dFd), filepath.Join(dir, "d.tmp"))
	// do NOT close df yet; try the swap against a.tmp while d is open
	swapErr := secureRenameSwapAt(parentFd, "d.tmp", parentFd, "a.tmp")
	_ = df.Close()
	if swapErr != nil {
		t.Fatalf("swap with open source handle: %v (errno %v)", swapErr, swapErr)
	}
	_ = syscall.Handle(0)
}
