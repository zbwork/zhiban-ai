package configuration

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type globalFixture struct {
	manager   *Manager
	home      string
	helper    string
	probes    []string
	installs  map[string]Installation
	clock     time.Time
	profiles  map[Environment]map[string]GatewayProfile
	codexPath string
	claudeDir string
}

func newGlobalFixture(t *testing.T) *globalFixture {
	t.Helper()
	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "Zhiban Local Bridge.app", "Contents", "MacOS", "zhiban-local-bridge"))
	codex := writeExecutable(t, filepath.Join(home, ".codex", "packages", "standalone", "current", "bin", "codex"))
	claude := writeExecutable(t, filepath.Join(home, ".local", "share", "claude", "versions", testClaudeVersion))
	f := &globalFixture{
		home: home, helper: helper, clock: time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC),
		installs: map[string]Installation{
			TargetCodexCLI:  {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
			TargetClaudeCLI: {TargetID: TargetClaudeCLI, InstallationID: "claude-install", Executable: claude, Version: testClaudeVersion},
		},
		profiles: map[Environment]map[string]GatewayProfile{
			EnvironmentProd: {
				TargetCodexCLI:  {Version: testProfile, BaseURL: "https://api.airick.cn/v1", Model: "gpt-5.6-luna"},
				TargetClaudeCLI: {Version: testProfile, BaseURL: "https://api.airick.cn", Model: "gpt-5.6-luna"},
			},
		},
		codexPath: filepath.Join(home, ".codex", "config.toml"),
		claudeDir: filepath.Join(home, ".claude"),
	}
	manager, err := NewManager(ManagerConfig{
		HomeDir: home, HelperExecutable: helper, Profiles: f.profiles,
		SupportedVersions: map[string]string{TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			installation, ok := f.installs[targetID]
			if !ok || installation.InstallationID != installationID {
				return Installation{}, ErrInstallationChanged
			}
			return installation, nil
		},
		ResolveAuthorization: func(context.Context, string) (AuthorizationProfile, error) {
			return AuthorizationProfile{Environment: EnvironmentProd, ProfileVersion: testProfile}, nil
		},
		Probe: func(context.Context, Installation, string) error { return nil },
		ProbeGlobal: func(_ context.Context, installation Installation) error {
			f.probes = append(f.probes, installation.TargetID)
			return nil
		},
		Now: func() time.Time { f.clock = f.clock.Add(time.Second); return f.clock },
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	f.manager = manager
	return f
}

func (f *globalFixture) switchTo(t *testing.T, targetID string) Status {
	t.Helper()
	plan, err := f.manager.PlanWithType(context.Background(), targetID, f.installs[targetID].InstallationID, PlanTypeSwitchGlobal)
	if err != nil {
		t.Fatalf("PlanWithType(switch_global %s) error = %v", targetID, err)
	}
	if plan.Action != ActionSwitchGlobal || plan.PlanID == "" {
		t.Fatalf("switch plan = %+v", plan)
	}
	status, err := f.manager.Execute(context.Background(), plan.PlanID)
	if err != nil {
		t.Fatalf("Execute(switch %s) error = %v", targetID, err)
	}
	return status
}

func (f *globalFixture) restore(t *testing.T, targetID string) Status {
	t.Helper()
	plan, err := f.manager.PlanWithType(context.Background(), targetID, "", PlanTypeRestoreGlobal)
	if err != nil {
		t.Fatalf("PlanWithType(restore_global %s) error = %v", targetID, err)
	}
	if plan.Action != ActionRestoreGlobal {
		t.Fatalf("restore plan = %+v", plan)
	}
	status, err := f.manager.Execute(context.Background(), plan.PlanID)
	if err != nil {
		t.Fatalf("Execute(restore %s) error = %v", targetID, err)
	}
	return status
}

func TestGlobalSwitchRewritesClaudeSettingsAndRestoresExactly(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	original := "{\n  \"theme\": \"dark\",\n  \"env\": {\n    \"ANTHROPIC_AUTH_TOKEN\": \"sk-other-relay\",\n    \"ANTHROPIC_BASE_URL\": \"https://other.example\",\n    \"KEEP_ME\": \"1\"\n  },\n  \"permissions\": {\"allow\": [\"Bash\"]}\n}\n"
	settingsPath := filepath.Join(f.claudeDir, "settings.json")
	mustWriteFile(t, settingsPath, []byte(original), 0o600)

	before, err := f.manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || before.CurrentService != ServiceOfficial || before.GlobalSwitched {
		t.Fatalf("Status() before switch = %+v, %v", before, err)
	}

	status := f.switchTo(t, TargetClaudeCLI)
	if status.CurrentService != ServiceZhiban || !status.GlobalSwitched || !status.GlobalBackupAvailable || status.GlobalDrifted ||
		status.GlobalVerificationLevel != VerificationL1 {
		t.Fatalf("Status() after switch = %+v", status)
	}
	if len(f.probes) != 1 || f.probes[0] != TargetClaudeCLI {
		t.Fatalf("probes = %v", f.probes)
	}
	var written map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &written); err != nil {
		t.Fatal(err)
	}
	env := written["env"].(map[string]any)
	if env["ANTHROPIC_BASE_URL"] != "https://api.airick.cn" || env["KEEP_ME"] != "1" || written["theme"] != "dark" ||
		written["model"] != "gpt-5.6-luna" || !strings.HasSuffix(written["apiKeyHelper"].(string), " credential get --target claude_cli") {
		t.Fatalf("switched settings = %v", written)
	}
	if _, leaked := env["ANTHROPIC_AUTH_TOKEN"]; leaked {
		t.Fatal("static token must be removed so the helper is used")
	}
	if written["permissions"] == nil {
		t.Fatal("unrelated keys must survive")
	}
	backups, _ := os.ReadDir(f.manager.backupsDir())
	if len(backups) != 1 || !strings.HasPrefix(backups[0].Name(), "claude_cli-") {
		t.Fatalf("backups = %v", backups)
	}
	manifest := mustReadFile(t, f.manager.globalManifestPath(TargetClaudeCLI))
	if !strings.Contains(string(manifest), "sk-other-relay") {
		t.Fatal("manifest must record the replaced token so restore can put it back")
	}

	// Switching again while already switched is a no-op plan.
	again, err := f.manager.PlanWithType(context.Background(), TargetClaudeCLI, "claude-install", PlanTypeSwitchGlobal)
	if err != nil || again.Action != ActionNone {
		t.Fatalf("second switch plan = %+v, %v", again, err)
	}

	restored := f.restore(t, TargetClaudeCLI)
	if restored.CurrentService != ServiceOfficial || restored.GlobalSwitched {
		t.Fatalf("Status() after restore = %+v", restored)
	}
	if got := string(mustReadFile(t, settingsPath)); got != original {
		t.Fatalf("restore must reproduce the original bytes:\n%s", got)
	}
	if _, err := os.Stat(f.manager.globalManifestPath(TargetClaudeCLI)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("manifest still present after restore: %v", err)
	}
	if _, err := f.manager.PlanWithType(context.Background(), TargetClaudeCLI, "", PlanTypeRestoreGlobal); !errors.Is(err, ErrGlobalNotSwitched) {
		t.Fatalf("restore when not switched error = %v", err)
	}
}

func TestGlobalSwitchRestoreKeepsUserEditsMadeAfterSwitch(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	settingsPath := filepath.Join(f.claudeDir, "settings.json")
	mustWriteFile(t, settingsPath, []byte(`{"env":{"ANTHROPIC_BASE_URL":"https://other.example"},"model":"claude-sonnet-4"}`+"\n"), 0o600)
	f.switchTo(t, TargetClaudeCLI)

	// The user adds a key after the switch: restore must keep it and only
	// revert what the switch touched.
	var current map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &current); err != nil {
		t.Fatal(err)
	}
	current["includeCoAuthoredBy"] = false
	edited, _ := json.MarshalIndent(current, "", "  ")
	mustWriteFile(t, settingsPath, append(edited, '\n'), 0o600)
	// A key outside the managed region is not drift: the switch still routes
	// exactly as written, so nothing is demoted.
	afterEdit, err := f.manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || afterEdit.GlobalDrifted || afterEdit.CurrentService != ServiceZhiban {
		t.Fatalf("Status() after user edit = %+v, %v", afterEdit, err)
	}

	f.restore(t, TargetClaudeCLI)
	var restored map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &restored); err != nil {
		t.Fatal(err)
	}
	env := restored["env"].(map[string]any)
	if restored["includeCoAuthoredBy"] != false || restored["model"] != "claude-sonnet-4" || env["ANTHROPIC_BASE_URL"] != "https://other.example" {
		t.Fatalf("restored = %v", restored)
	}
	if _, present := restored["apiKeyHelper"]; present {
		t.Fatal("apiKeyHelper must be removed on restore")
	}
}

func TestGlobalSwitchCreatesMissingClaudeSettingsAndRemovesThemOnRestore(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	settingsPath := filepath.Join(f.claudeDir, "settings.json")
	f.switchTo(t, TargetClaudeCLI)
	if _, err := os.Stat(settingsPath); err != nil {
		t.Fatalf("settings not created: %v", err)
	}
	f.restore(t, TargetClaudeCLI)
	if _, err := os.Stat(settingsPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("settings should be removed when it did not exist before: %v", err)
	}
}

// Contract §2.7.2 "受管注释": the marker comment is ASCII and recognised by
// prefix, so one that another program re-encoded into mojibake on Windows
// (2026-09-15 real machine) is removed instead of surviving every restore.
func TestCodexMarkerRecognisedByPrefixAndRemovedOnRestore(t *testing.T) {
	t.Parallel()
	for _, letter := range codexBlockBegin {
		if letter > 0x7f {
			t.Fatalf("marker must be ASCII: %q", codexBlockBegin)
		}
	}
	const mangled = "# >>> zhiban-ai-managed: managed by Zhiban AI, restored by 鎭㈠瀹樻柟閰嶇疆 >>>"
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("model = \"o3\"\n\n[projects.'c:\\users\\admin']\ntrust_level = \"trusted\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	// Codex Desktop rewrote the file and a stale mangled marker ended up above
	// the first table, beside the one this switch wrote.
	switched := string(mustReadFile(t, f.codexPath))
	mustWriteFile(t, f.codexPath, []byte(strings.Replace(switched, "[projects.", mangled+"\n[projects.", 1)), 0o600)
	if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); status.GlobalDrifted {
		t.Fatalf("a comment line is not drift: %+v", status)
	}
	f.restore(t, TargetCodexCLI)
	restored := string(mustReadFile(t, f.codexPath))
	if strings.Contains(restored, "zhiban-ai-managed") || strings.Contains(restored, "zhiban_ai_managed") {
		t.Fatalf("restored config keeps Zhiban lines:\n%s", restored)
	}
	if !strings.Contains(restored, "[projects.") || !strings.Contains(restored, `model = "o3"`) {
		t.Fatalf("restored config lost user content:\n%s", restored)
	}
}

func TestGlobalSwitchRewritesCodexConfigWithMarkedBlock(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	original := "# my codex config\nmodel = \"o3\"\nmodel_reasoning_effort = \"high\"\napproval_policy = \"never\"\n\n[mcp_servers.fs]\ncommand = \"npx\"\nargs = [\"-y\", \"mcp-fs\"]\n\n[profiles.work]\nmodel = \"gpt-5\"\n"
	mustWriteFile(t, f.codexPath, []byte(original), 0o600)
	status := f.switchTo(t, TargetCodexCLI)
	if status.CurrentService != ServiceZhiban {
		t.Fatalf("Status() after switch = %+v", status)
	}
	switched := string(mustReadFile(t, f.codexPath))
	lines := strings.Split(switched, "\n")
	if lines[0] != `model_provider = "zhiban_ai_managed"` || lines[1] != `model = "gpt-5.6-luna"` {
		t.Fatalf("top-level lines = %q", lines[:3])
	}
	for _, want := range []string{"# my codex config", `model_reasoning_effort = "high"`, "[mcp_servers.fs]", "[profiles.work]", `model = "gpt-5"`,
		codexBlockBegin, "[model_providers.zhiban_ai_managed]", `base_url = "https://api.airick.cn/v1"`, "requires_openai_auth = false", codexImageGenerationHeaderLine,
		"[model_providers.zhiban_ai_managed.auth]", `args = ["credential", "get", "--target", "codex_cli"]`} {
		if !strings.Contains(switched, want) {
			t.Fatalf("switched config missing %q:\n%s", want, switched)
		}
	}
	if strings.Contains(switched, codexBlockEnd) {
		t.Fatalf("end marker must not be written any more (Codex appends its own tables before a trailing comment):\n%s", switched)
	}
	if strings.Count(switched, "model = \"o3\"") != 0 {
		t.Fatalf("original top-level model must be replaced:\n%s", switched)
	}
	if strings.Contains(switched, "lctd.") || strings.Contains(switched, "sk-") {
		t.Fatal("no credential may be written into config.toml")
	}

	f.restore(t, TargetCodexCLI)
	if got := string(mustReadFile(t, f.codexPath)); got != original {
		t.Fatalf("restore must reproduce the original bytes:\n%s", got)
	}

	// Drifted restore: user appended a table after the switch.
	f.switchTo(t, TargetCodexCLI)
	mustWriteFile(t, f.codexPath, append(mustReadFile(t, f.codexPath), []byte("\n[mcp_servers.git]\ncommand = \"git-mcp\"\n")...), 0o600)
	f.restore(t, TargetCodexCLI)
	restored := string(mustReadFile(t, f.codexPath))
	if !strings.HasPrefix(restored, "model = \"o3\"\n") || !strings.Contains(restored, "[mcp_servers.git]") ||
		strings.Contains(restored, "zhiban_ai_managed") || strings.Contains(restored, codexBlockBegin) {
		t.Fatalf("drifted restore = \n%s", restored)
	}
}

func TestGlobalSwitchRefusesForeignZhibanTableAndRollsBackOnProbeFailure(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("[model_providers.zhiban_ai_managed]\nbase_url = \"https://evil.example\"\n"), 0o600)
	if _, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal); !errors.Is(err, ErrGlobalConflict) {
		t.Fatalf("Plan() with foreign table error = %v", err)
	}

	f2 := newGlobalFixture(t)
	original := "model = \"o3\"\n"
	mustWriteFile(t, f2.codexPath, []byte(original), 0o600)
	f2.manager.probeGlobalFunc = func(context.Context, Installation) error { return errors.New("codex refused config") }
	plan, err := f2.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f2.manager.Execute(context.Background(), plan.PlanID); !errors.Is(err, ErrValidationFailed) {
		t.Fatalf("Execute() with failing probe error = %v", err)
	}
	if got := string(mustReadFile(t, f2.codexPath)); got != original {
		t.Fatalf("config must be rolled back after probe failure:\n%s", got)
	}
	status, _ := f2.manager.Status(context.Background(), TargetCodexCLI)
	if status.CurrentService != ServiceOfficial || status.GlobalSwitched {
		t.Fatalf("Status() after rollback = %+v", status)
	}
}

func TestGlobalVerificationRecordedAndDroppedOnChange(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.switchTo(t, TargetCodexCLI)
	recorded, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion)
	if err != nil || recorded.VerificationLevel != VerificationL3 || recorded.LastVerifiedAt == "" {
		t.Fatalf("RecordGlobalVerification() = %+v, %v", recorded, err)
	}
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalVerificationLevel != VerificationL3 || status.GlobalLastVerifiedAt != recorded.LastVerifiedAt {
		t.Fatalf("Status() after verification = %+v", status)
	}
	// Anything outside the managed region — a comment, Codex's own tables —
	// keeps the recorded L3.
	mustWriteFile(t, f.codexPath, append(mustReadFile(t, f.codexPath), []byte("# edited\n")...), 0o600)
	status, _ = f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalVerificationLevel != VerificationL3 || status.GlobalDrifted {
		t.Fatalf("Status() after unrelated edit = %+v", status)
	}
	// Changing a managed key drops it and blocks recording until re-switched.
	tampered := strings.Replace(string(mustReadFile(t, f.codexPath)), "requires_openai_auth = false", "requires_openai_auth = true", 1)
	mustWriteFile(t, f.codexPath, []byte(tampered), 0o600)
	status, _ = f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalVerificationLevel != VerificationL1 || !status.GlobalDrifted {
		t.Fatalf("Status() after managed edit = %+v", status)
	}
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("RecordGlobalVerification() on drift error = %v", err)
	}
}

func TestGlobalVerificationKeepsL3ForUserInstalledVersion(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.switchTo(t, TargetCodexCLI)
	// The global switch never required the locked version, so the L3 a real
	// request proved on the user's own newer install must not fall back to L1
	// just because verified_version differs from the locked one.
	recorded, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, "0.999.0")
	if err != nil || recorded.VerificationLevel != VerificationL3 || recorded.LastVerifiedAt == "" {
		t.Fatalf("RecordGlobalVerification() with user-installed version = %+v, %v", recorded, err)
	}
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalVerificationLevel != VerificationL3 || status.GlobalLastVerifiedAt != recorded.LastVerifiedAt || status.GlobalDrifted {
		t.Fatalf("Status() after verification = %+v", status)
	}
	global, _ := f.manager.GlobalStatus(context.Background(), TargetCodexCLI)
	if global.VerificationLevel != VerificationL3 || global.CurrentService != ServiceZhiban {
		t.Fatalf("GlobalStatus() after verification = %+v", global)
	}
}

func TestGlobalCodexSelfWrittenTableIsNotDriftAndRestoreKeepsIt(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	// No config.toml before the switch, as on a fresh install.
	f.switchTo(t, TargetCodexCLI)
	recorded, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion)
	if err != nil || recorded.VerificationLevel != VerificationL3 {
		t.Fatalf("RecordGlobalVerification() = %+v, %v", recorded, err)
	}

	// Codex's first run records the working directory's trust after our tables.
	mustWriteFile(t, f.codexPath, append(mustReadFile(t, f.codexPath), []byte("\n[projects.\"/Users/ethan\"]\ntrust_level = \"trusted\"\n")...), 0o600)

	status, err := f.manager.Status(context.Background(), TargetCodexCLI)
	if err != nil || status.GlobalDrifted || status.CurrentService != ServiceZhiban ||
		status.GlobalVerificationLevel != VerificationL3 || status.GlobalLastVerifiedAt != recorded.LastVerifiedAt {
		t.Fatalf("Status() after Codex wrote [projects] = %+v, %v", status, err)
	}
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); err != nil {
		t.Fatalf("re-verification after Codex wrote [projects] error = %v", err)
	}
	again, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal)
	if err != nil || again.Action != ActionNone {
		t.Fatalf("switch plan after Codex wrote [projects] = %+v, %v", again, err)
	}

	// Restore drops only Zhiban's lines and tables; the file stays because
	// Codex's table is in it, even though the file did not exist before.
	f.restore(t, TargetCodexCLI)
	if got := string(mustReadFile(t, f.codexPath)); got != "[projects.\"/Users/ethan\"]\ntrust_level = \"trusted\"\n" {
		t.Fatalf("restore must keep Codex's own table and nothing of Zhiban's:\n%s", got)
	}
	status, _ = f.manager.Status(context.Background(), TargetCodexCLI)
	if status.CurrentService != ServiceOfficial || status.GlobalSwitched {
		t.Fatalf("Status() after restore = %+v", status)
	}
}

func TestGlobalCodexLegacyManifestRestoreKeepsTableInsideOldMarkers(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	// Exactly what build 11905 left on the test Mac: no config.toml before the
	// switch, a schema 1 manifest, and Codex's [projects] table inserted before
	// the end marker that build still wrote.
	block, _ := f.manager.renderCodexBlock("https://api.airick.cn/v1")
	applied := "model_provider = \"zhiban_ai_managed\"\nmodel = \"gpt-5.6-luna\"\n\n" + block + codexBlockEnd + "\n"
	drifted := strings.Replace(applied, codexBlockEnd+"\n", "\n[projects.\"/Users/ethan\"]\ntrust_level = \"trusted\"\n"+codexBlockEnd+"\n", 1)
	legacy := `{"schema_version":1,"target_id":"codex_cli","profile_version":"` + testProfile + `","file_kind":"codex_config_global","applied_sha256":"` + digest([]byte(applied)) +
		`","original_existed":false,"original":{"model_provider_line":null,"model_line":null},"verified_at":"2026-09-09T01:58:10Z","verification_level":"l3","verified_version":"` + testCodexVersion +
		`","verified_config_sha256":"` + digest([]byte(applied)) + `"}` + "\n"
	mustWriteFile(t, f.manager.globalManifestPath(TargetCodexCLI), []byte(legacy), 0o600)
	mustWriteFile(t, f.codexPath, []byte(drifted), 0o600)

	// A schema 1 manifest only knows the whole-file hash, so this still reads as drift…
	status, err := f.manager.Status(context.Background(), TargetCodexCLI)
	if err != nil || !status.GlobalSwitched || !status.GlobalDrifted || status.CurrentService != ServiceZhiban || status.GlobalVerificationLevel != VerificationL1 {
		t.Fatalf("Status() with legacy manifest = %+v, %v", status, err)
	}
	// …but restore must neither delete the file nor Codex's table.
	f.restore(t, TargetCodexCLI)
	if got := string(mustReadFile(t, f.codexPath)); got != "[projects.\"/Users/ethan\"]\ntrust_level = \"trusted\"\n" {
		t.Fatalf("legacy restore = \n%s", got)
	}

	// Switching again writes a schema 2 manifest; from then on Codex's
	// additions are not drift and restore keeps every one of them.
	f.switchTo(t, TargetCodexCLI)
	var manifest globalManifest
	if err := json.Unmarshal(mustReadFile(t, f.manager.globalManifestPath(TargetCodexCLI)), &manifest); err != nil ||
		manifest.SchemaVersion != globalManifestSchema || !validDigest(manifest.ManagedSHA256) || !manifest.OriginalExisted {
		t.Fatalf("manifest after re-switch = %+v, %v", manifest, err)
	}
	mustWriteFile(t, f.codexPath, append(mustReadFile(t, f.codexPath), []byte("\n[projects.\"/Users/ethan/work\"]\ntrust_level = \"trusted\"\n")...), 0o600)
	status, _ = f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalDrifted || status.CurrentService != ServiceZhiban {
		t.Fatalf("Status() after second Codex write = %+v", status)
	}
	f.restore(t, TargetCodexCLI)
	restored := string(mustReadFile(t, f.codexPath))
	if !strings.Contains(restored, "[projects.\"/Users/ethan\"]") || !strings.Contains(restored, "[projects.\"/Users/ethan/work\"]") ||
		strings.Contains(restored, "zhiban") || strings.Contains(restored, "model_provider") {
		t.Fatalf("restore after re-switch = \n%s", restored)
	}
}

func TestGlobalCodexManagedRegionEditIsDrift(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("model = \"o3\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); err != nil {
		t.Fatal(err)
	}
	switched := string(mustReadFile(t, f.codexPath))

	// Pointing our provider table elsewhere is drift even though the provider
	// name — and therefore current_service — is unchanged.
	mustWriteFile(t, f.codexPath, []byte(strings.Replace(switched, "https://api.airick.cn/v1", "https://evil.example/v1", 1)), 0o600)
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if !status.GlobalDrifted || status.GlobalVerificationLevel != VerificationL1 || status.CurrentService != ServiceZhiban {
		t.Fatalf("Status() after base_url edit = %+v", status)
	}
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("RecordGlobalVerification() on drift error = %v", err)
	}
	// Switching again is allowed to repair it: the table is ours, not a foreign conflict.
	plan, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal)
	if err != nil || plan.Action != ActionSwitchGlobal {
		t.Fatalf("switch plan after tamper = %+v, %v", plan, err)
	}

	// Pointing the top-level provider elsewhere reads as official and drifted.
	mustWriteFile(t, f.codexPath, []byte(strings.Replace(switched, `model_provider = "zhiban_ai_managed"`, `model_provider = "openai"`, 1)), 0o600)
	status, _ = f.manager.Status(context.Background(), TargetCodexCLI)
	if !status.GlobalDrifted || status.CurrentService != ServiceOfficial || status.GlobalVerificationLevel == VerificationL3 {
		t.Fatalf("Status() after provider edit = %+v", status)
	}
}

func TestGlobalClaudeSelfRewriteKeepsL3AndRestoreKeepsAddedKeys(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	settingsPath := filepath.Join(f.claudeDir, "settings.json")
	f.switchTo(t, TargetClaudeCLI) // no settings.json before
	recorded, err := f.manager.RecordGlobalVerification(context.Background(), TargetClaudeCLI, testClaudeVersion)
	if err != nil || recorded.VerificationLevel != VerificationL3 {
		t.Fatalf("RecordGlobalVerification() = %+v, %v", recorded, err)
	}

	// Claude Code rewrites settings.json itself: its own key order and
	// indentation, plus keys of its own.
	var current map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &current); err != nil {
		t.Fatal(err)
	}
	rewritten := "{\n\t\"includeCoAuthoredBy\": false,\n\t\"env\": " + mustJSON(t, current["env"]) + ",\n\t\"model\": " + mustJSON(t, current["model"]) +
		",\n\t\"apiKeyHelper\": " + mustJSON(t, current["apiKeyHelper"]) + ",\n\t\"permissions\": {\"allow\": [\"Bash\"]}\n}"
	mustWriteFile(t, settingsPath, []byte(rewritten), 0o600)
	status, err := f.manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || status.GlobalDrifted || status.CurrentService != ServiceZhiban || status.GlobalVerificationLevel != VerificationL3 {
		t.Fatalf("Status() after Claude rewrote settings = %+v, %v", status, err)
	}
	again, err := f.manager.PlanWithType(context.Background(), TargetClaudeCLI, "claude-install", PlanTypeSwitchGlobal)
	if err != nil || again.Action != ActionNone {
		t.Fatalf("switch plan after Claude rewrote settings = %+v, %v", again, err)
	}

	// Changing a managed key is drift.
	mustWriteFile(t, settingsPath, []byte(strings.Replace(rewritten, "https://api.airick.cn", "https://evil.example", 1)), 0o600)
	status, _ = f.manager.Status(context.Background(), TargetClaudeCLI)
	if !status.GlobalDrifted || status.GlobalVerificationLevel == VerificationL3 {
		t.Fatalf("Status() after base URL edit = %+v", status)
	}
	mustWriteFile(t, settingsPath, []byte(rewritten), 0o600)

	// Restore keeps Claude's keys and does not delete the file even though it
	// did not exist before the switch.
	f.restore(t, TargetClaudeCLI)
	var restored map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &restored); err != nil {
		t.Fatal(err)
	}
	if restored["includeCoAuthoredBy"] != false || restored["permissions"] == nil || len(restored) != 2 {
		t.Fatalf("restored = %v", restored)
	}
}

func TestGlobalReswitchAfterDriftKeepsFirstOriginalForRestore(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	original := "model = \"o3\"\n\n[mcp_servers.fs]\ncommand = \"npx\"\n"
	mustWriteFile(t, f.codexPath, []byte(original), 0o600)
	f.switchTo(t, TargetCodexCLI)

	// The user (or something else) points our provider table elsewhere;
	// 一键修复 re-switches. The repaired manifest must still remember the
	// pre-Zhiban file, not the tampered Zhiban-routed one.
	tampered := strings.Replace(string(mustReadFile(t, f.codexPath)), "https://api.airick.cn/v1", "https://evil.example/v1", 1)
	mustWriteFile(t, f.codexPath, []byte(tampered), 0o600)
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if !status.GlobalDrifted {
		t.Fatalf("Status() after tamper = %+v", status)
	}
	repaired := f.switchTo(t, TargetCodexCLI)
	if repaired.GlobalDrifted || repaired.CurrentService != ServiceZhiban {
		t.Fatalf("Status() after repair = %+v", repaired)
	}
	if got := string(mustReadFile(t, f.codexPath)); strings.Contains(got, "evil.example") || !strings.Contains(got, "[mcp_servers.fs]") {
		t.Fatalf("repaired config = \n%s", got)
	}
	var manifest globalManifest
	if err := json.Unmarshal(mustReadFile(t, f.manager.globalManifestPath(TargetCodexCLI)), &manifest); err != nil {
		t.Fatal(err)
	}
	var recorded codexGlobalOriginal
	if err := json.Unmarshal(manifest.Original, &recorded); err != nil || recorded.ModelProviderLine != nil || recorded.ModelLine == nil || *recorded.ModelLine != `model = "o3"` {
		t.Fatalf("manifest original after repair = %s, %v", manifest.Original, err)
	}

	f.restore(t, TargetCodexCLI)
	if got := string(mustReadFile(t, f.codexPath)); got != original {
		t.Fatalf("restore after repair must return to the pre-Zhiban file:\n%s", got)
	}
}

func TestGlobalReswitchWithoutOriginalKeepsCodexTablesOnRestore(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.switchTo(t, TargetCodexCLI) // no config.toml before
	mustWriteFile(t, f.codexPath, append(mustReadFile(t, f.codexPath), []byte("\n[projects.\"/Users/ethan\"]\ntrust_level = \"trusted\"\n")...), 0o600)
	tampered := strings.Replace(string(mustReadFile(t, f.codexPath)), "requires_openai_auth = false", "requires_openai_auth = true", 1)
	mustWriteFile(t, f.codexPath, []byte(tampered), 0o600)

	repaired := f.switchTo(t, TargetCodexCLI)
	if repaired.GlobalDrifted {
		t.Fatalf("Status() after repair = %+v", repaired)
	}
	var manifest globalManifest
	if err := json.Unmarshal(mustReadFile(t, f.manager.globalManifestPath(TargetCodexCLI)), &manifest); err != nil || manifest.OriginalExisted {
		t.Fatalf("manifest after repair = %+v, %v", manifest, err)
	}

	// The file is byte-identical to what the repair wrote, but it carries
	// Codex's table: restore must keep that and not delete the file.
	f.restore(t, TargetCodexCLI)
	if got := string(mustReadFile(t, f.codexPath)); got != "[projects.\"/Users/ethan\"]\ntrust_level = \"trusted\"\n" {
		t.Fatalf("restore after repair = \n%s", got)
	}
}

func mustJSON(t *testing.T, value any) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

func TestGlobalSwitchWithoutCredentialHelperInFileAndOverlayCoexist(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	// Overlay flow keeps working independently of the global switch.
	plan, err := f.manager.Plan(context.Background(), TargetClaudeCLI, "claude-install")
	if err != nil || plan.Action != ActionCreate {
		t.Fatalf("overlay Plan() = %+v, %v", plan, err)
	}
	if _, err := f.manager.Execute(context.Background(), plan.PlanID); err != nil {
		t.Fatalf("overlay Execute() error = %v", err)
	}
	f.switchTo(t, TargetClaudeCLI)
	status, err := f.manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || status.State != StateConfigured || status.CurrentService != ServiceZhiban {
		t.Fatalf("Status() with both = %+v, %v", status, err)
	}
}

// 2026-09-15 · The switch refuses a Codex older than the minimum switchable
// version even when the App offers it, and writes nothing.
func TestSwitchGlobalRefusesTooOldCodex(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	old := f.installs[TargetCodexCLI]
	old.Version = "0.130.0"
	f.installs[TargetCodexCLI] = old
	if _, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal); !errors.Is(err, ErrVersionTooOld) {
		t.Fatalf("PlanWithType(switch_global) error = %v, want ErrVersionTooOld", err)
	}
	if _, err := os.Lstat(f.codexPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("config.toml must not be written: %v", err)
	}
}

// The user deletes apiKeyHelper by hand (the file is then judged official),
// connects again, and later restores: what comes back must be the file from
// before the first switch, not the half-stripped one with Zhiban's gateway
// (2026-09-18 Windows 12800: 恢复官方配置 left ANTHROPIC_BASE_URL on the
// gateway and the official service got 401).
func TestGlobalClaudeReswitchAfterHandEditKeepsFirstBackupForRestore(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	original := "{\n  \"theme\": \"dark\"\n}\n"
	settingsPath := filepath.Join(f.claudeDir, "settings.json")
	mustWriteFile(t, settingsPath, []byte(original), 0o600)
	f.switchTo(t, TargetClaudeCLI)

	var written map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &written); err != nil {
		t.Fatal(err)
	}
	delete(written, "apiKeyHelper")
	edited, _ := json.MarshalIndent(written, "", "  ")
	mustWriteFile(t, settingsPath, edited, 0o600)
	status, err := f.manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || status.CurrentService != ServiceOfficial {
		t.Fatalf("Status() after deleting the helper = %+v, %v", status, err)
	}

	if again := f.switchTo(t, TargetClaudeCLI); again.CurrentService != ServiceZhiban {
		t.Fatalf("Status() after re-switch = %+v", again)
	}
	restored := f.restore(t, TargetClaudeCLI)
	if restored.CurrentService != ServiceOfficial || restored.GlobalSwitched {
		t.Fatalf("Status() after restore = %+v", restored)
	}
	if got := string(mustReadFile(t, settingsPath)); got != original {
		t.Fatalf("restore must return to the pre-Zhiban file:\n%s", got)
	}
}

// Same leftovers without any switch record (cleared state directory): the
// switch adopts the file with Zhiban's keys stripped, so restore removes them.
func TestGlobalClaudeLeftoversWithoutRecordAreStrippedOnSwitch(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	leftover := "{\n  \"env\": {\n    \"ANTHROPIC_BASE_URL\": \"https://api.airick.cn\",\n    \"CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY\": \"1\",\n    \"KEEP_ME\": \"1\"\n  },\n  \"theme\": \"dark\"\n}\n"
	settingsPath := filepath.Join(f.claudeDir, "settings.json")
	mustWriteFile(t, settingsPath, []byte(leftover), 0o600)
	status, err := f.manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || status.CurrentService != ServiceOfficial || status.GlobalSwitched {
		t.Fatalf("Status() with leftovers = %+v, %v", status, err)
	}
	f.switchTo(t, TargetClaudeCLI)
	f.restore(t, TargetClaudeCLI)
	var restored map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &restored); err != nil {
		t.Fatal(err)
	}
	env, _ := restored["env"].(map[string]any)
	if _, has := env["ANTHROPIC_BASE_URL"]; has {
		t.Fatalf("gateway URL survived restore: %v", restored)
	}
	if _, has := env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"]; has {
		t.Fatalf("discovery flag survived restore: %v", restored)
	}
	if env["KEEP_ME"] != "1" || restored["theme"] != "dark" {
		t.Fatalf("user keys lost: %v", restored)
	}
	if _, has := restored["apiKeyHelper"]; has {
		t.Fatalf("helper survived restore: %v", restored)
	}
}
