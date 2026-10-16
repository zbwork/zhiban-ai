//go:build windows

package install

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/claudecode"
)

func TestHostRenameWaitsForFileRelease(t *testing.T) {
	for _, mode := range []string{"released", "timeout", "cancel", "existing target"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			source := filepath.Join(root, "staging")
			target := filepath.Join(root, "version")
			for _, p := range []string{source, target} {
				if err := os.Mkdir(p, 0700); err != nil {
					t.Fatal(err)
				}
			}
			path := filepath.Join(source, claudecode.NPMBinaryName)
			if err := os.WriteFile(path, []byte("verified fixture"), 0600); err != nil {
				t.Fatal(err)
			}
			a, err := secureOpenDirectory(source)
			if err != nil {
				t.Fatal(err)
			}
			b, err := secureOpenDirectory(target)
			if err != nil {
				t.Fatal(err)
			}
			staging, version := os.NewFile(uintptr(a), source), os.NewFile(uintptr(b), target)
			defer staging.Close()
			defer version.Close()
			if mode == "existing target" {
				if err := os.WriteFile(filepath.Join(target, claudecode.NPMBinaryName), []byte("keep me"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			ptr, err := syscall.UTF16PtrFromString(path)
			if err != nil {
				t.Fatal(err)
			}
			h, err := syscall.CreateFile(ptr, syscall.GENERIC_READ, syscall.FILE_SHARE_READ, nil, syscall.OPEN_EXISTING, 0, 0)
			if err != nil {
				t.Fatal(err)
			}
			closed := make(chan struct{})
			if mode == "released" {
				go func() { time.Sleep(70 * time.Millisecond); syscall.CloseHandle(h); close(closed) }()
			} else {
				defer syscall.CloseHandle(h)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if mode == "cancel" {
				cancel()
			}
			err = renameHostExecutable(ctx, staging, version, 300*time.Millisecond)
			switch mode {
			case "released":
				<-closed
				if err != nil {
					t.Fatal(err)
				}
			case "cancel":
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("got %v", err)
				}
			case "timeout":
				if !pathHeldByAnotherProcess(err) {
					t.Fatalf("got %v", err)
				}
			case "existing target":
				if err == nil {
					t.Fatal("overwrote target")
				}
				data, _ := os.ReadFile(filepath.Join(target, claudecode.NPMBinaryName))
				if string(data) != "keep me" {
					t.Fatal("target changed")
				}
			}
		})
	}
}
