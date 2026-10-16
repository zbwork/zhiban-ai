//go:build windows

package codexsessions

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRemapUpdatesTheIndexDatabaseThroughWinSQLite(t *testing.T) {
	if !indexEngineAvailable() {
		t.Skip("winsqlite3.dll not available")
	}
	home := t.TempDir()
	database := filepath.Join(home, "state_5.sqlite")
	seed := "CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT, rollout_path TEXT);" +
		"PRAGMA journal_mode=WAL;" +
		"INSERT INTO threads VALUES('a','zhiban_ai_managed','x'),('b','openai','y'),('c','zhiban_ai_managed','z');"
	if _, err := runSQL(database, seed, sqliteOpenReadWrite|sqliteOpenCreate); err != nil {
		t.Fatalf("seed: %v", err)
	}

	result := Remap(context.Background(), home, "zhiban_ai_managed", "openai", time.Now())
	if result.IndexRows != 2 || len(result.Errors) != 0 {
		t.Fatalf("Remap() = %+v", result)
	}
	remaining, err := runSQL(database, "UPDATE threads SET rollout_path = rollout_path WHERE model_provider = 'zhiban_ai_managed';", sqliteOpenReadWrite)
	if err != nil {
		t.Fatal(err)
	}
	if remaining != 0 {
		t.Fatalf("%d threads still name the Zhiban provider", remaining)
	}
	all, err := runSQL(database, "UPDATE threads SET rollout_path = rollout_path WHERE model_provider = 'openai';", sqliteOpenReadWrite)
	if err != nil || all != 3 {
		t.Fatalf("threads on openai = %d, %v", all, err)
	}
	if _, err := updateIndex(context.Background(), filepath.Join(home, "missing.sqlite"), "SELECT 1;"); err == nil || !strings.Contains(err.Error(), "sqlite3_open_v2") {
		t.Fatalf("opening a missing database must fail without creating it, got %v", err)
	}
}
