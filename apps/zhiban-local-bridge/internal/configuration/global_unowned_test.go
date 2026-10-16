package configuration

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// B3 (contract §2.7, 2026-09-14): the user's file still routes to Zhiban, but
// the Bridge has no (readable) switch record for it — the App support folder
// was cleaned, the App reinstalled, or another build wrote it. Status must say
// so, "恢复官方配置" must really remove Zhiban's region, and "一键修复" must
// take the file over instead of refusing it.

func (f *globalFixture) loseManifest(t *testing.T, targetID string) {
	t.Helper()
	if err := os.Remove(f.manager.globalManifestPath(targetID)); err != nil {
		t.Fatalf("remove manifest: %v", err)
	}
}

func (f *globalFixture) backupCount(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir(f.manager.backupsDir())
	if errors.Is(err, os.ErrNotExist) {
		return 0
	}
	if err != nil {
		t.Fatal(err)
	}
	return len(entries)
}

func TestGlobalUnownedCodexConfigIsReportedAndRestoredToOfficial(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("model = \"o3\"\n\n[mcp_servers.fs]\ncommand = \"npx\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	f.loseManifest(t, TargetCodexCLI)

	status, err := f.manager.Status(context.Background(), TargetCodexCLI)
	if err != nil || status.CurrentService != ServiceZhiban || status.GlobalSwitched || !status.GlobalDrifted {
		t.Fatalf("Status() of an unowned Zhiban config = %+v, %v", status, err)
	}

	backupsBefore := f.backupCount(t)
	restored := f.restore(t, TargetCodexCLI)
	if restored.CurrentService != ServiceOfficial || restored.GlobalDrifted || restored.GlobalSwitched {
		t.Fatalf("Status() after restoring an unowned config = %+v", restored)
	}
	got := string(mustReadFile(t, f.codexPath))
	if strings.Contains(got, "zhiban_ai_managed") || strings.Contains(got, codexBlockBegin) || strings.Contains(got, "gpt-5.6-luna") ||
		!strings.Contains(got, "[mcp_servers.fs]") {
		t.Fatalf("restored unowned config = \n%s", got)
	}
	if f.backupCount(t) != backupsBefore+1 {
		t.Fatalf("the unowned file must be backed up before it is rewritten")
	}
}

func TestGlobalUnownedCodexConfigIsAdoptedBySwitchAndRestoresWithoutZhiban(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("approval_policy = \"never\"\n\n[mcp_servers.fs]\ncommand = \"npx\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	f.loseManifest(t, TargetCodexCLI)
	// Written by another build: an old helper path and a model the user picked.
	orphan := strings.Replace(string(mustReadFile(t, f.codexPath)), `model = "gpt-5.6-luna"`, `model = "o3"`, 1)
	orphan = strings.Replace(orphan, f.helper, "/Applications/Old Zhiban.app/Contents/MacOS/zhiban-local-bridge", 1)
	mustWriteFile(t, f.codexPath, []byte(orphan), 0o600)

	adopted := f.switchTo(t, TargetCodexCLI)
	if adopted.CurrentService != ServiceZhiban || !adopted.GlobalSwitched || adopted.GlobalDrifted {
		t.Fatalf("Status() after adopting = %+v", adopted)
	}
	switched := string(mustReadFile(t, f.codexPath))
	if strings.Contains(switched, "Old Zhiban.app") || !strings.Contains(switched, f.helper) ||
		strings.Count(switched, "[model_providers.zhiban_ai_managed]") != 1 || !strings.Contains(switched, "[mcp_servers.fs]") {
		t.Fatalf("adopted config = \n%s", switched)
	}

	f.restore(t, TargetCodexCLI)
	got := string(mustReadFile(t, f.codexPath))
	if strings.Contains(got, "zhiban_ai_managed") || strings.Contains(got, "gpt-5.6-luna") ||
		!strings.Contains(got, `model = "o3"`) || !strings.Contains(got, `approval_policy = "never"`) || !strings.Contains(got, "[mcp_servers.fs]") {
		t.Fatalf("restore after adopting must leave the user's own lines only:\n%s", got)
	}
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if status.CurrentService != ServiceOfficial {
		t.Fatalf("Status() after restore = %+v", status)
	}
}

func TestGlobalForeignCodexProviderIsNeitherAdoptedNorRestored(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	// Our provider name, somebody else's gateway: not ours to take over.
	mustWriteFile(t, f.codexPath, []byte("model_provider = \"zhiban_ai_managed\"\n\n[model_providers.zhiban_ai_managed]\nbase_url = \"https://evil.example/v1\"\n"), 0o600)
	if _, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal); !errors.Is(err, ErrGlobalConflict) {
		t.Fatalf("switch over a foreign provider error = %v", err)
	}
	if _, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "", PlanTypeRestoreGlobal); !errors.Is(err, ErrGlobalNotSwitched) {
		t.Fatalf("restore of a foreign provider error = %v", err)
	}
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalDrifted {
		t.Fatalf("a foreign provider must not be reported as Zhiban's unowned config: %+v", status)
	}
}

func TestGlobalUnownedClaudeSettingsAreRestoredAndAdopted(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	settings := filepath.Join(f.claudeDir, "settings.json")
	unowned := map[string]any{
		"apiKeyHelper": "'/Applications/Old Zhiban.app/Contents/MacOS/zhiban-local-bridge' credential get --target claude_cli",
		"model":        "gpt-5.6-luna",
		"theme":        "dark",
		"env": map[string]any{
			"ANTHROPIC_BASE_URL": "https://api.airick.cn",
			"OTHER":              "1",
		},
	}
	mustWriteFile(t, settings, []byte(mustJSON(t, unowned)), 0o600)

	status, err := f.manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || status.CurrentService != ServiceZhiban || status.GlobalSwitched || !status.GlobalDrifted {
		t.Fatalf("Status() of unowned Claude settings = %+v, %v", status, err)
	}
	f.restore(t, TargetClaudeCLI)
	var root map[string]any
	if err := json.Unmarshal(mustReadFile(t, settings), &root); err != nil {
		t.Fatal(err)
	}
	env, _ := root["env"].(map[string]any)
	if _, ok := root["apiKeyHelper"]; ok || root["model"] != nil || root["theme"] != "dark" || env["OTHER"] != "1" || env["ANTHROPIC_BASE_URL"] != nil {
		t.Fatalf("restored unowned Claude settings = %v", root)
	}

	// Same file again, this time 一键修复: adopted, and a later restore leaves
	// no Zhiban key behind (the first switch's "original" must not be ours).
	mustWriteFile(t, settings, []byte(mustJSON(t, unowned)), 0o600)
	adopted := f.switchTo(t, TargetClaudeCLI)
	if !adopted.GlobalSwitched || adopted.GlobalDrifted || adopted.CurrentService != ServiceZhiban {
		t.Fatalf("Status() after adopting Claude settings = %+v", adopted)
	}
	f.restore(t, TargetClaudeCLI)
	root = nil
	if err := json.Unmarshal(mustReadFile(t, settings), &root); err != nil {
		t.Fatal(err)
	}
	env, _ = root["env"].(map[string]any)
	if _, ok := root["apiKeyHelper"]; ok || root["model"] != nil || env["ANTHROPIC_BASE_URL"] != nil || root["theme"] != "dark" || env["OTHER"] != "1" {
		t.Fatalf("restore after adopting Claude settings = %v", root)
	}
}

func TestGlobalUnownedClaudeDesktopEntry(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.withDesktop(t)
	metaPath := f.manager.claudeDesktopMetaPath()
	userEntry := "d281ada9-93c2-44f0-8467-fac6fc8949ed"
	mustWriteFile(t, metaPath, []byte(mustJSON(t, map[string]any{
		"appliedId": userEntry, "entries": []any{map[string]any{"id": userEntry, "name": "Default"}},
	})), 0o600)
	f.switchTo(t, TargetClaudeDesktop)
	f.loseManifest(t, TargetClaudeDesktop)

	status, err := f.manager.Status(context.Background(), TargetClaudeDesktop)
	if err != nil || status.CurrentService != ServiceZhiban || status.GlobalSwitched || !status.GlobalDrifted {
		t.Fatalf("Status() of an unowned desktop entry = %+v, %v", status, err)
	}

	// Adopt, lose the record again, then restore: the entry goes and the app
	// points at the user's own entry, never back at Zhiban's.
	f.switchTo(t, TargetClaudeDesktop)
	f.loseManifest(t, TargetClaudeDesktop)
	f.restore(t, TargetClaudeDesktop)
	var meta map[string]any
	if err := json.Unmarshal(mustReadFile(t, metaPath), &meta); err != nil {
		t.Fatal(err)
	}
	if meta["appliedId"] != userEntry {
		t.Fatalf("_meta.json after restoring an unowned entry = %v", meta)
	}
	if _, err := os.Stat(f.manager.claudeDesktopConfigPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Zhiban entry must be removed, got %v", err)
	}

	// An entry the app no longer applies is not "switched" at all.
	f.switchTo(t, TargetClaudeDesktop)
	f.loseManifest(t, TargetClaudeDesktop)
	mustWriteFile(t, metaPath, []byte(mustJSON(t, map[string]any{
		"appliedId": userEntry, "entries": []any{map[string]any{"id": userEntry, "name": "Default"}, map[string]any{"id": ZhibanClaudeDesktopConfigID, "name": "知办 AI"}},
	})), 0o600)
	status, _ = f.manager.Status(context.Background(), TargetClaudeDesktop)
	if status.CurrentService != ServiceOfficial || status.GlobalDrifted {
		t.Fatalf("Status() with the entry not applied = %+v", status)
	}
}
