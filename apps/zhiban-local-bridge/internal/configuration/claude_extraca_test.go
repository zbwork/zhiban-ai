package configuration

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
)

const testCABundle = "/etc/ssl/cert.pem"

func (f *globalFixture) claudeSettingsPath() string {
	return filepath.Join(f.claudeDir, "settings.json")
}

func (f *globalFixture) claudeSettings(t *testing.T) map[string]any {
	t.Helper()
	var root map[string]any // a fresh map: Unmarshal merges into an existing one
	if err := json.Unmarshal(mustReadFile(t, f.claudeSettingsPath()), &root); err != nil {
		t.Fatal(err)
	}
	return root
}

func (f *globalFixture) claudeEnv(t *testing.T) map[string]any {
	t.Helper()
	env, _ := f.claudeSettings(t)["env"].(map[string]any)
	return env
}

// The switch points Claude Code at the system's root bundle, and 恢复官方配置
// takes it away again: the file the user had comes back byte for byte.
func TestClaudeSwitchAddsSystemRootBundle(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.manager.systemCABundle = testCABundle
	before := []byte(`{"theme":"light","env":{"HTTPS_PROXY":"http://127.0.0.1:7890"}}`)
	mustWriteFile(t, f.claudeSettingsPath(), before, 0o600)
	f.switchTo(t, TargetClaudeCLI)
	env := f.claudeEnv(t)
	if env[claudeExtraCAName] != testCABundle || env["HTTPS_PROXY"] != "http://127.0.0.1:7890" {
		t.Fatalf("env = %+v", env)
	}
	status, _ := f.manager.Status(context.Background(), TargetClaudeCLI)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() = %+v", status)
	}
	f.restore(t, TargetClaudeCLI)
	if got := string(mustReadFile(t, f.claudeSettingsPath())); got != string(before) {
		t.Fatalf("restored settings = %s", got)
	}
}

// An enterprise user already names their own bundle: it is theirs to keep,
// and its presence is neither an upgrade nor drift.
func TestClaudeSwitchKeepsTheUsersOwnCABundle(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.manager.systemCABundle = testCABundle
	mustWriteFile(t, f.claudeSettingsPath(), []byte(`{"env":{"NODE_EXTRA_CA_CERTS":"/opt/corp/ca.pem"}}`), 0o600)
	f.switchTo(t, TargetClaudeCLI)
	if env := f.claudeEnv(t); env[claudeExtraCAName] != "/opt/corp/ca.pem" {
		t.Fatalf("env = %+v", env)
	}
	status, _ := f.manager.Status(context.Background(), TargetClaudeCLI)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() = %+v", status)
	}
}

// Where there is no bundle to offer (Windows) nothing is written or asked for.
func TestClaudeSwitchWithoutSystemBundleWritesNothing(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.manager.systemCABundle = ""
	f.switchTo(t, TargetClaudeCLI)
	if _, present := f.claudeEnv(t)[claudeExtraCAName]; present {
		t.Fatalf("env = %+v", f.claudeEnv(t))
	}
	if status, _ := f.manager.Status(context.Background(), TargetClaudeCLI); status.GlobalUpgradeAvailable {
		t.Fatalf("Status() = %+v", status)
	}
}

// Users switched by 1.2.6 and earlier lack the key. That is an upgrade the App
// applies silently (switch_global → verify), never drift; the plan must really
// write although the managed region is already identical; and restore still
// returns exactly what the user had.
func TestClaudeSwitchedWithoutRootBundleIsUpgradeAvailable(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.manager.systemCABundle = "" // what 1.2.6 wrote: no key, no record of it
	mustWriteFile(t, f.claudeSettingsPath(), []byte(`{"theme":"light"}`), 0o600)
	f.switchTo(t, TargetClaudeCLI)
	f.rewriteManifest(t, TargetClaudeCLI, func(item *globalManifest) {
		var original claudeGlobalOriginal
		if err := json.Unmarshal(item.Original, &original); err != nil {
			t.Fatal(err)
		}
		delete(original.Values, claudeExtraCAKey)
		item.Original, _ = json.Marshal(original)
	})

	f.manager.systemCABundle = testCABundle // the user updates Zhiban
	status, _ := f.manager.Status(context.Background(), TargetClaudeCLI)
	if status.GlobalDrifted || !status.GlobalUpgradeAvailable {
		t.Fatalf("Status() for a 1.2.6 switch = %+v", status)
	}
	f.switchTo(t, TargetClaudeCLI) // fails the test if the plan answers "none"
	if env := f.claudeEnv(t); env[claudeExtraCAName] != testCABundle {
		t.Fatalf("env after the silent re-switch = %+v", env)
	}
	status, _ = f.manager.Status(context.Background(), TargetClaudeCLI)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() after the re-switch = %+v", status)
	}
	plan, err := f.manager.PlanWithType(context.Background(), TargetClaudeCLI, f.installs[TargetClaudeCLI].InstallationID, PlanTypeSwitchGlobal)
	if err != nil || plan.Action != ActionNone {
		t.Fatalf("second plan = %+v, %v", plan, err)
	}

	// The user swaps in a bundle of their own: not drift, not an upgrade.
	root := f.claudeSettings(t)
	root["env"].(map[string]any)[claudeExtraCAName] = "/opt/corp/ca.pem"
	mustWriteFile(t, f.claudeSettingsPath(), []byte(mustJSON(t, root)), 0o600)
	status, _ = f.manager.Status(context.Background(), TargetClaudeCLI)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() after the user's own bundle = %+v", status)
	}

	// The file changed since the switch, so restore is structural. The
	// re-switch recorded that the user had no such key: it goes, theme stays.
	f.restore(t, TargetClaudeCLI)
	restored := f.claudeSettings(t)
	if _, present := restored["env"]; present || restored["theme"] != "light" || len(restored) != 1 {
		t.Fatalf("settings after restore = %+v", restored)
	}
}

// A Zhiban-routed settings.json whose manifest is gone has no originals at
// all: only the value Zhiban writes is removed, a bundle of the user's stays.
func TestClaudeRestoreWithoutManifestRemovesOnlyZhibansBundle(t *testing.T) {
	t.Parallel()
	for value, kept := range map[string]bool{testCABundle: false, "/opt/corp/ca.pem": true} {
		f := newGlobalFixture(t)
		f.manager.systemCABundle = testCABundle
		mustWriteFile(t, f.claudeSettingsPath(), []byte(mustJSON(t, map[string]any{
			"apiKeyHelper": "'/Applications/Old Zhiban.app/Contents/MacOS/zhiban-local-bridge' credential get --target claude_cli",
			"env":          map[string]any{"ANTHROPIC_BASE_URL": "https://api.airick.cn", claudeExtraCAName: value, "OTHER": "1"},
		})), 0o600)
		f.restore(t, TargetClaudeCLI)
		env := f.claudeEnv(t)
		if _, present := env[claudeExtraCAName]; present != kept || env["OTHER"] != "1" {
			t.Fatalf("%s: env after restore = %+v", value, env)
		}
	}
}
