package credential

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestCommunityFilePersistence(t *testing.T) {
	root := filepath.Join(t.TempDir(), "credentials")
	backend := &communityFileBackend{root: root}
	manager := &CommunityManager{backend: backend}
	ctx := context.Background()
	settings := BYOKSettings{TargetID: TargetCodexCLI, BaseURL: "https://one.example/v1", Model: "test-model", APIKey: "fixture-key", Save: true}
	if _, err := manager.Settings(ctx, settings); err != nil {
		t.Fatal(err)
	}
	reopened := &CommunityManager{backend: &communityFileBackend{root: root}}
	key, err := reopened.ExchangeToken(ctx, TargetCodexCLI)
	if err != nil || key != "fixture-key" {
		t.Fatal("reopen failed", err)
	}
	path, err := backend.path("community-byok-" + TargetCodexCLI + "-v1")
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		info, _ := os.Stat(path)
		dir, _ := os.Stat(root)
		if info.Mode().Perm() != 0600 || dir.Mode().Perm() != 0700 {
			t.Fatal("incorrect permissions")
		}
	}
	settings.APIKey = ""
	settings.BaseURL = "https://two.example/v1"
	if _, err := reopened.Settings(ctx, settings); !errors.Is(err, ErrInvalidData) {
		t.Fatal("address changed without key")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "target")
	if err := os.WriteFile(target, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
		if _, err := backend.Load(ctx, "community-byok-"+TargetCodexCLI+"-v1"); !errors.Is(err, ErrInvalidData) {
			t.Fatal("symlink accepted")
		}
		if err := backend.Delete(ctx, "community-byok-"+TargetCodexCLI+"-v1"); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(target)
	if err != nil || string(raw) != "keep" {
		t.Fatal("source modified")
	}
	if _, err := backend.path("../escape"); !errors.Is(err, ErrInvalidData) {
		t.Fatal("traversal accepted")
	}
}
