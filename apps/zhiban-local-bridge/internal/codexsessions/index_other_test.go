//go:build !windows

package codexsessions

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRemapUpdatesTheIndexDatabaseWhenSqliteIsAvailable(t *testing.T) {
	sqlite := sqliteBinary()
	if sqlite == "" {
		t.Skip("no sqlite3 on this machine")
	}
	home := t.TempDir()
	database := filepath.Join(home, "state_5.sqlite")
	setup := "CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT, rollout_path TEXT);" +
		"INSERT INTO threads VALUES('a','zhiban_ai_managed','/x/a.jsonl'),('b','openai','/x/b.jsonl'),('c','zhiban_ai_managed','/x/c.jsonl');"
	if output, err := exec.Command(sqlite, "-batch", database, setup).CombinedOutput(); err != nil {
		t.Fatalf("seed sqlite: %v: %s", err, output)
	}

	result := Remap(context.Background(), home, "zhiban_ai_managed", "openai", time.Now())
	if result.IndexRows != 2 || len(result.Errors) != 0 {
		t.Fatalf("Remap() = %+v", result)
	}
	output, err := exec.Command(sqlite, "-batch", database, "SELECT id||'='||model_provider FROM threads ORDER BY id;").CombinedOutput()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(output)); got != "a=openai\nb=openai\nc=openai" {
		t.Fatalf("threads after remap = %q", got)
	}
}
