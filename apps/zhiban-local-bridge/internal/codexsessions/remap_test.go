package codexsessions

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

const (
	zhibanMeta  = `{"timestamp":"2026-09-17T07:21:00.000Z","type":"session_meta","payload":{"id":"a","cwd":"/Users/x","model_provider":"zhiban_ai_managed","cli_version":"0.144.1"}}`
	zhibanEvent = `{"timestamp":"2026-09-17T07:21:01.000Z","type":"event_msg","payload":{"type":"session_configured","model":"gpt-5.6","model_provider_id":"zhiban_ai_managed"}}`
	openaiMeta  = `{"timestamp":"2026-09-16T07:21:00.000Z","type":"session_meta","payload":{"id":"b","model_provider":"openai"}}`
	userText    = `{"timestamp":"2026-09-17T07:21:02.000Z","type":"response_item","payload":{"type":"message","content":[{"type":"input_text","text":"provider zhiban_ai_managed is mentioned in prose, model_provider: zhiban_ai_managed too"}]}}`
)

func writeRollout(t *testing.T, home, day, name string, lines ...string) string {
	t.Helper()
	dir := filepath.Join(home, "sessions", "2026", "09", day)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func age(t *testing.T, path string, by time.Duration) {
	t.Helper()
	old := time.Now().Add(-by)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
}

func TestRemapRewritesOnlyTheProviderTokensOfSettledZhibanRollouts(t *testing.T) {
	home := t.TempDir()
	settled := writeRollout(t, home, "17", "rollout-2026-09-17T15-21-00-a.jsonl", zhibanMeta, zhibanEvent, userText)
	age(t, settled, time.Hour)
	official := writeRollout(t, home, "16", "rollout-2026-09-16T15-21-00-b.jsonl", openaiMeta)
	age(t, official, time.Hour)
	active := writeRollout(t, home, "18", "rollout-2026-09-18T09-00-00-c.jsonl", zhibanMeta, zhibanEvent)
	other := writeRollout(t, home, "17", "notes.jsonl", zhibanMeta)
	age(t, other, time.Hour)

	result := Remap(context.Background(), home, "zhiban_ai_managed", "beeai", time.Now())
	if result.Rollouts != 1 || result.SkippedActive != 1 {
		t.Fatalf("Remap() = %+v", result)
	}
	got := string(mustRead(t, settled))
	want := strings.Join([]string{
		strings.ReplaceAll(zhibanMeta, `"model_provider":"zhiban_ai_managed"`, `"model_provider":"beeai"`),
		strings.ReplaceAll(zhibanEvent, `"model_provider_id":"zhiban_ai_managed"`, `"model_provider_id":"beeai"`),
		userText,
	}, "\n") + "\n"
	if got != want {
		t.Fatalf("rewritten rollout =\n%s\nwant\n%s", got, want)
	}
	if info, err := os.Stat(settled); runtime.GOOS != "windows" && (err != nil || info.Mode().Perm() != 0o600) {
		t.Fatalf("rewritten rollout mode = %v, %v", info.Mode(), err)
	}
	if string(mustRead(t, official)) != openaiMeta+"\n" {
		t.Fatalf("an official rollout was touched: %s", mustRead(t, official))
	}
	if !strings.Contains(string(mustRead(t, active)), `"model_provider":"zhiban_ai_managed"`) {
		t.Fatalf("an active rollout was rewritten")
	}
	if !strings.Contains(string(mustRead(t, other)), `"model_provider":"zhiban_ai_managed"`) {
		t.Fatalf("a file that is not a rollout was rewritten")
	}
	for _, entry := range mustDir(t, filepath.Dir(settled)) {
		if strings.HasPrefix(entry.Name(), ".zhiban-remap-") {
			t.Fatalf("temporary file left behind: %s", entry.Name())
		}
	}
}

func TestRemapRefusesUnsafeIdsAndIsANoOpWithoutSessions(t *testing.T) {
	home := t.TempDir()
	if result := Remap(context.Background(), home, "zhiban_ai_managed", "x'; DROP TABLE threads; --", time.Now()); result.Rollouts != 0 || len(result.Errors) != 1 {
		t.Fatalf("Remap() with an unsafe id = %+v", result)
	}
	if result := Remap(context.Background(), home, "zhiban_ai_managed", "openai", time.Now()); result.Rollouts != 0 || result.IndexRows != -1 || len(result.Errors) != 0 {
		t.Fatalf("Remap() on an empty home = %+v", result)
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return content
}

func mustDir(t *testing.T, path string) []os.DirEntry {
	t.Helper()
	entries, err := os.ReadDir(path)
	if err != nil {
		t.Fatal(err)
	}
	return entries
}

// 改写只换了服务商名,会话并没有变新:保留原修改时间。否则我们自己刚改过的文件会被
// 两分钟内的下一次改记(恢复官方后马上再接入)当成"正在使用"而跳过。
func TestRemapKeepsTheRolloutModificationTime(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	path := writeRollout(t, home, "17", "rollout-2026-09-17T15-21-00-a.jsonl",
		`{"type":"session_meta","payload":{"id":"a","model_provider":"zhiban_ai_managed"}}`)
	age(t, path, time.Hour)
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if result := Remap(context.Background(), home, "zhiban_ai_managed", "openai", time.Now()); result.Rollouts != 1 {
		t.Fatalf("first remap = %+v", result)
	}
	after, err := os.Stat(path)
	if err != nil || !after.ModTime().Equal(before.ModTime()) {
		t.Fatalf("modification time moved: %v -> %v (%v)", before.ModTime(), after.ModTime(), err)
	}
	// Straight back, no waiting: our own rewrite is not a running Codex.
	if result := Remap(context.Background(), home, "openai", "zhiban_ai_managed", time.Now()); result.Rollouts != 1 || result.SkippedActive != 0 {
		t.Fatalf("remap straight back = %+v", result)
	}
}
