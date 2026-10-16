//go:build !windows

package codexsessions

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
)

// indexEngineAvailable reports whether a sqlite3 command is at hand.
func indexEngineAvailable() bool {
	return sqliteBinary() != ""
}

// updateIndex runs statement on database through the sqlite3 command and
// returns the number of rows it changed.
func updateIndex(ctx context.Context, database, statement string) (int, error) {
	sqlite := sqliteBinary()
	if sqlite == "" {
		return 0, fmt.Errorf("sqlite3 not available")
	}
	runCtx, cancel := context.WithTimeout(ctx, sqliteTimeout)
	defer cancel()
	cmd := exec.CommandContext(runCtx, sqlite, "-batch", "-cmd", ".timeout "+strconv.Itoa(sqliteBusyMillis), database, statement+" SELECT changes();")
	output, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(output))
	if err != nil {
		return 0, fmt.Errorf("%w: %s", err, text)
	}
	changed, convErr := strconv.Atoi(text)
	if convErr != nil {
		return 0, fmt.Errorf("unexpected sqlite3 output %q", text)
	}
	return changed, nil
}

// sqliteBinary prefers the system's own sqlite3 over anything on PATH.
func sqliteBinary() string {
	if runtime.GOOS == "darwin" {
		if info, err := os.Stat("/usr/bin/sqlite3"); err == nil && info.Mode().IsRegular() {
			return "/usr/bin/sqlite3"
		}
	}
	if path, err := exec.LookPath("sqlite3"); err == nil {
		return path
	}
	return ""
}
