package configuration

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	testZhibanRolloutMeta  = `{"timestamp":"2026-09-17T07:21:00.000Z","type":"session_meta","payload":{"id":"a","model_provider":"zhiban_ai_managed"}}`
	testZhibanRolloutEvent = `{"timestamp":"2026-09-17T07:21:01.000Z","type":"event_msg","payload":{"type":"session_configured","model_provider_id":"zhiban_ai_managed"}}`
)

func (f *globalFixture) writeZhibanRollout(t *testing.T, name string) string {
	t.Helper()
	dir := filepath.Join(f.manager.codexHome, "sessions", "2026", "09", "17")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	mustWriteFile(t, path, []byte(testZhibanRolloutMeta+"\n"+testZhibanRolloutEvent+"\n"), 0o600)
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRestoredCodexProviderIDFollowsTheRestoredFile(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name     string
		restored string
		removed  bool
		want     string
	}{
		{"user provider", "model = \"o3\"\nmodel_provider = \"beeai\"\n\n[model_providers.beeai]\nname = \"x\"\n", false, "beeai"},
		{"no provider line", "model = \"o3\"\n\n[mcp_servers.fs]\ncommand = \"npx\"\n", false, "openai"},
		{"provider line inside a table is not top-level", "model = \"o3\"\n\n[profiles.a]\nmodel_provider = \"beeai\"\n", false, "openai"},
		{"file removed", "", true, "openai"},
	}
	for _, tc := range cases {
		if got := restoredCodexProviderID([]byte(tc.restored), tc.removed); got != tc.want {
			t.Errorf("%s: restoredCodexProviderID() = %q, want %q", tc.name, got, tc.want)
		}
	}
}

// seedZhibanIndex writes a Codex index database with one Zhiban-period
// thread and one official one; it reports false without sqlite3.
func (f *globalFixture) seedZhibanIndex(t *testing.T) (string, bool) {
	t.Helper()
	sqlite, err := exec.LookPath("sqlite3")
	if err != nil {
		return "", false
	}
	database := filepath.Join(f.manager.codexHome, "state_5.sqlite")
	seed := "CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT);" +
		"INSERT INTO threads VALUES('a','zhiban_ai_managed'),('b','openai');"
	if output, err := exec.Command(sqlite, "-batch", database, seed).CombinedOutput(); err != nil {
		t.Fatalf("seed index: %v: %s", err, output)
	}
	return database, true
}

func TestGlobalCodexRestoreRepointsZhibanThreadsAtTheRestoredProvider(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("model = \"o3\"\nmodel_provider = \"beeai\"\n\n[model_providers.beeai]\nname = \"BeeAI\"\nbase_url = \"https://example.invalid/v1\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	rollout := f.writeZhibanRollout(t, "rollout-2026-09-17T15-21-00-a.jsonl")
	database, haveIndex := f.seedZhibanIndex(t)

	status := f.restore(t, TargetCodexCLI)
	if status.CodexSessionsRemapped != 1 || status.CodexSessionsSkipped != 0 {
		t.Fatalf("restore status = %+v", status)
	}
	got := string(mustReadFile(t, rollout))
	if strings.Contains(got, "zhiban_ai_managed") || !strings.Contains(got, `"model_provider":"beeai"`) || !strings.Contains(got, `"model_provider_id":"beeai"`) {
		t.Fatalf("rollout after restore =\n%s", got)
	}
	if !haveIndex {
		t.Log("sqlite3 not on PATH; index assertions skipped")
		return
	}
	if status.CodexSessionsIndexed != 1 || len(status.CodexSessionsErrors) != 0 {
		t.Fatalf("restore status = %+v", status)
	}
	output, err := exec.Command("sqlite3", "-batch", database, "SELECT id||'='||model_provider FROM threads ORDER BY id;").CombinedOutput()
	if err != nil {
		t.Fatal(err)
	}
	if rows := strings.TrimSpace(string(output)); rows != "a=beeai\nb=openai" {
		t.Fatalf("index after restore = %q", rows)
	}
}

func TestGlobalCodexRestoreRepointsThreadsAtOpenAIWhenTheUserNamedNoProvider(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.switchTo(t, TargetCodexCLI)
	rollout := f.writeZhibanRollout(t, "rollout-2026-09-17T15-21-00-b.jsonl")

	status := f.restore(t, TargetCodexCLI)
	if status.CodexSessionsRemapped != 1 {
		t.Fatalf("restore status = %+v", status)
	}
	if got := string(mustReadFile(t, rollout)); !strings.Contains(got, `"model_provider":"openai"`) {
		t.Fatalf("rollout after restore =\n%s", got)
	}
}

func (f *globalFixture) indexRows(t *testing.T, database string) string {
	t.Helper()
	output, err := exec.Command("sqlite3", "-batch", database, "SELECT id||'='||model_provider FROM threads ORDER BY id;").CombinedOutput()
	if err != nil {
		t.Fatalf("read index: %v: %s", err, output)
	}
	return strings.TrimSpace(string(output))
}

// 2026-09-21 测试机:知办 → 恢复官方 → 再切回知办后,知办时期的老会话能打开,但续聊
// 一直 reconnecting。恢复时的改记是单向的:切回后索引库里 6 个线程仍全是 openai,
// Codex 续聊按线程自己记的服务商去连 wss://chatgpt.com(后台日志实锤)。用户拍板:
// 切到哪边,历史会话全部跟到哪边。同步放在"检测通过"之后——知办线路确实能用了才把
// 会话改过来,也顺带治好已经卡在这个状态的用户(他们不会再点一次切换)。
func TestCodexThreadsFollowTheSwitchBackToZhiban(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.switchTo(t, TargetCodexCLI)
	rollout := f.writeZhibanRollout(t, "rollout-2026-09-17T15-21-00-a.jsonl")
	database, haveIndex := f.seedZhibanIndex(t)
	if !haveIndex {
		t.Skip("sqlite3 not on PATH")
	}
	f.restore(t, TargetCodexCLI)
	if rows := f.indexRows(t, database); rows != "a=openai\nb=openai" {
		t.Fatalf("index after restore = %q", rows)
	}

	f.switchTo(t, TargetCodexCLI)
	// Switching alone moves nothing: the relay has not been shown to work yet.
	if rows := f.indexRows(t, database); rows != "a=openai\nb=openai" {
		t.Fatalf("index after switching back = %q", rows)
	}
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); err != nil {
		t.Fatalf("RecordGlobalVerification: %v", err)
	}
	// Every thread follows, the official-period one too.
	if rows := f.indexRows(t, database); rows != "a=zhiban_ai_managed\nb=zhiban_ai_managed" {
		t.Fatalf("index after the verified switch back = %q", rows)
	}
	got := string(mustReadFile(t, rollout))
	if strings.Contains(got, `"openai"`) || !strings.Contains(got, `"model_provider":"zhiban_ai_managed"`) || !strings.Contains(got, `"model_provider_id":"zhiban_ai_managed"`) {
		t.Fatalf("rollout after the verified switch back =\n%s", got)
	}

	// Nothing left to move: a later check leaves the rollouts as they are.
	before, err := os.Stat(rollout)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); err != nil {
		t.Fatalf("second RecordGlobalVerification: %v", err)
	}
	after, err := os.Stat(rollout)
	if err != nil || !after.ModTime().Equal(before.ModTime()) {
		t.Fatalf("rollout rewritten again: %v -> %v (%v)", before.ModTime(), after.ModTime(), err)
	}

	// And back again: restoring returns every thread to the official provider.
	f.restore(t, TargetCodexCLI)
	if rows := f.indexRows(t, database); rows != "a=openai\nb=openai" {
		t.Fatalf("index after the second restore = %q", rows)
	}
}

// 用户原来用的是自己的服务商:恢复时线程跟回那个服务商,再切回知办时也要从它跟回来。
func TestCodexThreadsFollowBackFromTheUsersOwnProvider(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("model = \"o3\"\nmodel_provider = \"beeai\"\n\n[model_providers.beeai]\nname = \"BeeAI\"\nbase_url = \"https://example.invalid/v1\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	database, haveIndex := f.seedZhibanIndex(t)
	if !haveIndex {
		t.Skip("sqlite3 not on PATH")
	}
	f.restore(t, TargetCodexCLI)
	if rows := f.indexRows(t, database); rows != "a=beeai\nb=openai" {
		t.Fatalf("index after restore = %q", rows)
	}
	f.switchTo(t, TargetCodexCLI)
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); err != nil {
		t.Fatalf("RecordGlobalVerification: %v", err)
	}
	if rows := f.indexRows(t, database); rows != "a=zhiban_ai_managed\nb=zhiban_ai_managed" {
		t.Fatalf("index after the verified switch back = %q", rows)
	}
}
