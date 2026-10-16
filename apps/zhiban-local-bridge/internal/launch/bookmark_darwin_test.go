//go:build darwin && cgo

package launch

import (
	"context"
	"path/filepath"
	"testing"
)

func TestMacOSBookmarkResolverRoundTrip(t *testing.T) {
	t.Parallel()
	project := filepath.Join(t.TempDir(), "project")
	mustMkdir(t, project)
	bookmark, err := createBookmarkForTest(project)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := NewMacOSBookmarkResolver()(context.Background(), bookmark)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(project)
	if err != nil {
		t.Fatal(err)
	}
	got, err := filepath.EvalSymlinks(resolved.Path)
	if err != nil {
		t.Fatal(err)
	}
	if got != want || resolved.Stale {
		t.Fatalf("resolved = %+v, want path %q and fresh", resolved, want)
	}
}

func TestMacOSBookmarkResolverRejectsInvalidData(t *testing.T) {
	t.Parallel()
	if _, err := NewMacOSBookmarkResolver()(context.Background(), []byte("not-a-bookmark")); err == nil {
		t.Fatal("invalid bookmark resolved")
	}
}
