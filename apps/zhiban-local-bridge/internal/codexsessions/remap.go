// Package codexsessions re-points the provider id Codex recorded in its
// threads (contract §2.7.2 "Codex 恢复官方配置后的历史会话", 2026-09-18).
//
// Codex stores the provider a thread was created under in two places. The
// index database ($CODEX_HOME/state_*.sqlite, threads.model_provider) is what
// thread/resume reads: the desktop app re-loads the configuration with that
// id as an override and, once "恢复官方配置" has removed the
// [model_providers.zhiban_ai_managed] table, fails with "failed to load
// configuration: Model provider `zhiban_ai_managed` not found" (codex 0.155
// app-server thread_processor.rs load_and_apply_persisted_resume_metadata;
// nine threads on a production user's machine 2026-09-17, four on the test
// machine 2026-09-18 — updating the index and restarting the app is what
// made them open again). The rollout files ($CODEX_HOME/sessions/**/
// rollout-*.jsonl: session_meta "model_provider", thread-settings events'
// "model_provider_id") are what the index is rebuilt from, so they are
// rewritten too or a later backfill would bring the old id back.
//
// Remap is best effort: nothing here may fail the restore.
package codexsessions

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	// activeWindow: a rollout written this recently belongs to a running
	// Codex that is still appending to it; it is left for a later restore.
	// The index row is updated regardless — the app reads it afresh once it
	// is restarted.
	activeWindow = 2 * time.Minute
	// maxRolloutBytes guards the whole-file rewrite against a runaway file.
	maxRolloutBytes = 256 << 20
	// sqliteBusyMillis is how long the engine waits for a lock the desktop
	// app may hold on the index.
	sqliteBusyMillis = 5000
	sqliteTimeout    = 15 * time.Second
)

// providerIDPattern keeps the ids we splice into JSON and SQL literal-safe.
var providerIDPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

// Result counts what Remap did.
type Result struct {
	// IndexRows is the number of threads rows updated across the index
	// databases; -1 when no index step ran (no index file, or no sqlite3
	// on the machine).
	IndexRows int
	// Rollouts is the number of rollout files rewritten.
	Rollouts int
	// SkippedActive is the number of matching rollouts left alone because
	// they were written within activeWindow.
	SkippedActive int
	// Errors lists what failed, for the caller's log.
	Errors []string
}

// Remap rewrites every thread under codexHome recorded with fromID so it
// names toID instead. now decides which rollouts count as active.
func Remap(ctx context.Context, codexHome, fromID, toID string, now time.Time) Result {
	result := Result{IndexRows: -1}
	if !providerIDPattern.MatchString(fromID) || !providerIDPattern.MatchString(toID) {
		result.Errors = append(result.Errors, "provider id not literal-safe")
		return result
	}
	if fromID == toID || strings.TrimSpace(codexHome) == "" {
		return result
	}
	remapIndex(ctx, codexHome, fromID, toID, &result)
	remapRollouts(ctx, codexHome, fromID, toID, now, &result)
	return result
}

// remapIndex runs the UPDATE on every index database. The SQL engine is
// the platform's own: the sqlite3 command on macOS, winsqlite3.dll on
// Windows (index_windows.go) — the Bridge ships no SQLite of its own.
func remapIndex(ctx context.Context, codexHome, fromID, toID string, result *Result) {
	databases, _ := filepath.Glob(filepath.Join(codexHome, "state_*.sqlite"))
	if len(databases) == 0 {
		return
	}
	if !indexEngineAvailable() {
		result.Errors = append(result.Errors, "no SQLite engine on this machine; index left as is")
		return
	}
	result.IndexRows = 0
	statement := fmt.Sprintf("UPDATE threads SET model_provider = '%s' WHERE model_provider = '%s';", toID, fromID)
	for _, database := range databases {
		changed, err := updateIndex(ctx, database, statement)
		if err != nil {
			result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", filepath.Base(database), err))
			continue
		}
		result.IndexRows += changed
	}
}

func remapRollouts(ctx context.Context, codexHome, fromID, toID string, now time.Time, result *Result) {
	root := filepath.Join(codexHome, "sessions")
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return
	}
	metaNeedle := []byte(`"model_provider":"` + fromID + `"`)
	eventNeedle := []byte(`"model_provider_id":"` + fromID + `"`)
	metaReplacement := []byte(`"model_provider":"` + toID + `"`)
	eventReplacement := []byte(`"model_provider_id":"` + toID + `"`)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if walkErr != nil {
			result.Errors = append(result.Errors, walkErr.Error())
			return nil
		}
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".jsonl") || !strings.HasPrefix(entry.Name(), "rollout-") {
			return nil
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			return nil
		}
		if info.Size() > maxRolloutBytes {
			return nil
		}
		// The first line is the session_meta; only it decides whether the
		// thread is ours, so the hundreds of other rollouts are never read.
		if !firstLineContains(path, metaNeedle) {
			return nil
		}
		if now.Sub(info.ModTime()) < activeWindow {
			result.SkippedActive++
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			result.Errors = append(result.Errors, err.Error())
			return nil
		}
		rewritten := bytes.ReplaceAll(content, metaNeedle, metaReplacement)
		rewritten = bytes.ReplaceAll(rewritten, eventNeedle, eventReplacement)
		if err := replaceFile(path, rewritten, info.Mode().Perm()); err != nil {
			result.Errors = append(result.Errors, err.Error())
			return nil
		}
		// Keep the file's own modification time. Only the provider id changed,
		// so the session is no more recent than it was; and the next Remap —
		// 恢复官方 then 一键接入 within two minutes (2026-09-21) — would take our
		// own rewrite for a running Codex and leave the rollout behind.
		_ = os.Chtimes(path, info.ModTime(), info.ModTime())
		result.Rollouts++
		return nil
	})
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
		result.Errors = append(result.Errors, err.Error())
	}
}

// firstLineContains reports whether the file's first line holds needle.
func firstLineContains(path string, needle []byte) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	reader := bufio.NewReaderSize(file, 64<<10)
	line, err := reader.ReadBytes('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false
	}
	return bytes.Contains(line, needle)
}

// replaceFile writes content next to path and renames it over, so a reader
// sees either the old or the new file.
func replaceFile(path string, content []byte, perm fs.FileMode) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".zhiban-remap-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	cleanup := func() { _ = os.Remove(tempPath) }
	if _, err := temp.Write(content); err != nil {
		_ = temp.Close()
		cleanup()
		return err
	}
	if err := temp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Chmod(tempPath, perm); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		cleanup()
		return err
	}
	return nil
}
