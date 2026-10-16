package codexsessions

import (
	"context"
	"os"
	"testing"
	"time"
)

// TestRemapOnARealCodexHome is a manual check (REMAP_LIVE_HOME=<a
// real ~/.codex>, REMAP_LIVE_FROM / REMAP_LIVE_TO): the real index database,
// the real rollouts, a desktop app that may be running. Back the directory up
// first; this rewrites it.
func TestRemapOnARealCodexHome(t *testing.T) {
	home := os.Getenv("REMAP_LIVE_HOME")
	if home == "" {
		t.Skip("set REMAP_LIVE_HOME to re-point the threads of a real Codex home")
	}
	started := time.Now()
	result := Remap(context.Background(), home, os.Getenv("REMAP_LIVE_FROM"), os.Getenv("REMAP_LIVE_TO"), time.Now())
	t.Logf("took %s: index rows %d, rollouts %d, skipped active %d, errors %v",
		time.Since(started).Round(time.Millisecond), result.IndexRows, result.Rollouts, result.SkippedActive, result.Errors)
	if len(result.Errors) != 0 {
		t.Fatalf("errors: %v", result.Errors)
	}
}
