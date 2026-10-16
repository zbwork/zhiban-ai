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

const (
	testCodexDesktopVersion  = "26.623.141536"
	testClaudeDesktopVersion = "1.46388.4"
	testDesktopModel         = "claude-sonnet-4-6"
)

// withDesktop adds the two desktop bundles (as directories with the parts the
// switch relies on) and their profiles to a global fixture.
func (f *globalFixture) withDesktop(t *testing.T) (codexBundle, claudeBundle string) {
	t.Helper()
	codexBundle = filepath.Join(f.home, "Applications", "Codex.app")
	writeExecutable(t, filepath.Join(codexBundle, "Contents", "Resources", "codex"))
	if err := os.MkdirAll(filepath.Join(codexBundle, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	claudeBundle = filepath.Join(f.home, "Applications", "Claude.app")
	if err := os.MkdirAll(filepath.Join(claudeBundle, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.installs[TargetCodexDesktop] = Installation{TargetID: TargetCodexDesktop, InstallationID: "codex-desktop-install", Executable: codexBundle, Version: testCodexDesktopVersion}
	f.installs[TargetClaudeDesktop] = Installation{TargetID: TargetClaudeDesktop, InstallationID: "claude-desktop-install", Executable: claudeBundle, Version: testClaudeDesktopVersion}
	desktopProfile := GatewayProfile{Version: testProfile, BaseURL: "https://api.airick.cn", Model: testDesktopModel}
	f.profiles[EnvironmentProd][TargetClaudeDesktop] = desktopProfile
	if f.manager.profiles[EnvironmentProd] == nil {
		f.manager.profiles[EnvironmentProd] = map[string]GatewayProfile{}
	}
	f.manager.profiles[EnvironmentProd][TargetClaudeDesktop] = desktopProfile
	f.manager.supportedVersions[TargetCodexDesktop] = testCodexDesktopVersion
	f.manager.supportedVersions[TargetClaudeDesktop] = testClaudeDesktopVersion
	return codexBundle, claudeBundle
}

func TestCodexDesktopSharesTheCLIConfigurationAndManifest(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	codexBundle, _ := f.withDesktop(t)
	var probed []string
	f.manager.probeGlobalFunc = func(_ context.Context, installation Installation) error {
		probed = append(probed, installation.Executable)
		return nil
	}

	// Switching through the desktop row rewrites ~/.codex/config.toml, probes
	// the core bundled in the app, and records the manifest under codex_cli.
	status := f.switchTo(t, TargetCodexDesktop)
	if status.CurrentService != ServiceZhiban || !status.GlobalSwitched || status.GlobalVerificationLevel != VerificationL1 {
		t.Fatalf("Status(codex_desktop) after switch = %+v", status)
	}
	if len(probed) != 1 || probed[0] != filepath.Join(codexBundle, "Contents", "Resources", "codex") {
		t.Fatalf("probed executables = %v", probed)
	}
	if _, err := os.Stat(f.manager.globalManifestPath(TargetCodexCLI)); err != nil {
		t.Fatalf("manifest must live under codex_cli: %v", err)
	}
	if f.manager.globalManifestPath(TargetCodexDesktop) != f.manager.globalManifestPath(TargetCodexCLI) {
		t.Fatal("desktop and CLI must share the manifest path")
	}
	if !strings.Contains(string(mustReadFile(t, f.codexPath)), `--target", "codex_cli"`) {
		t.Fatal("the shared config must keep the codex_cli helper target")
	}
	cli, err := f.manager.Status(context.Background(), TargetCodexCLI)
	if err != nil || cli.CurrentService != ServiceZhiban || !cli.GlobalSwitched || cli.GlobalDrifted {
		t.Fatalf("Status(codex_cli) after desktop switch = %+v, %v", cli, err)
	}

	// The CLI row can switch again: nothing to do.
	again, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal)
	if err != nil || again.Action != ActionNone {
		t.Fatalf("Plan(codex_cli switch) after desktop switch = %+v, %v", again, err)
	}

	// Desktop verification records L2; the CLI's L3 is never borrowed by the
	// desktop row and never demoted by a later desktop L2.
	desktop, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexDesktop, testCodexDesktopVersion)
	if err != nil || desktop.VerificationLevel != VerificationL2 {
		t.Fatalf("RecordGlobalVerification(codex_desktop) = %+v, %v", desktop, err)
	}
	cliRecorded, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion)
	if err != nil || cliRecorded.VerificationLevel != VerificationL3 {
		t.Fatalf("RecordGlobalVerification(codex_cli) = %+v, %v", cliRecorded, err)
	}
	desktopStatus, _ := f.manager.Status(context.Background(), TargetCodexDesktop)
	cliStatus, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if desktopStatus.GlobalVerificationLevel != VerificationL2 || cliStatus.GlobalVerificationLevel != VerificationL3 {
		t.Fatalf("levels: desktop=%s cli=%s", desktopStatus.GlobalVerificationLevel, cliStatus.GlobalVerificationLevel)
	}
	if again, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexDesktop, "26.903.61454"); err != nil || again.VerificationLevel != VerificationL2 {
		t.Fatalf("desktop L2 after CLI L3 = %+v, %v", again, err)
	}
	if cliStatus, _ = f.manager.Status(context.Background(), TargetCodexCLI); cliStatus.GlobalVerificationLevel != VerificationL3 {
		t.Fatalf("CLI L3 must survive a desktop L2 record: %+v", cliStatus)
	}

	// Overlay plan types are meaningless for a desktop target.
	if _, err := f.manager.PlanWithType(context.Background(), TargetCodexDesktop, "codex-desktop-install", PlanTypeEnable); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("PlanWithType(desktop enable) error = %v", err)
	}
	overlay, err := f.manager.Status(context.Background(), TargetCodexDesktop)
	if err != nil || overlay.State != StateNotConfigured {
		t.Fatalf("desktop overlay state = %+v, %v", overlay, err)
	}

	// Restoring through the desktop row restores the shared file.
	restored := f.restore(t, TargetCodexDesktop)
	if restored.CurrentService != ServiceOfficial || restored.GlobalSwitched {
		t.Fatalf("Status(codex_desktop) after restore = %+v", restored)
	}
	if _, err := os.Stat(f.codexPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("config.toml must be removed (it did not exist before): %v", err)
	}
}

func TestCodexDesktopSwitchRequiresTheBundledCore(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	codexBundle, _ := f.withDesktop(t)
	if err := os.Remove(filepath.Join(codexBundle, "Contents", "Resources", "codex")); err != nil {
		t.Fatal(err)
	}
	if _, err := f.manager.PlanWithType(context.Background(), TargetCodexDesktop, "codex-desktop-install", PlanTypeSwitchGlobal); !errors.Is(err, ErrInstallationChanged) {
		t.Fatalf("Plan(switch) without bundled core error = %v", err)
	}
}

func TestClaudeDesktopSwitchWritesLibraryEntryAndHelper(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.withDesktop(t)
	metaPath := f.manager.claudeDesktopMetaPath()
	entryPath := f.manager.claudeDesktopConfigPath()

	before, err := f.manager.Status(context.Background(), TargetClaudeDesktop)
	if err != nil || before.CurrentService != ServiceOfficial || before.GlobalSwitched || before.State != StateNotConfigured {
		t.Fatalf("Status() before = %+v, %v", before, err)
	}

	status := f.switchTo(t, TargetClaudeDesktop)
	if status.CurrentService != ServiceZhiban || !status.GlobalSwitched || status.GlobalDrifted || status.GlobalVerificationLevel != VerificationL1 || status.GlobalBackupAvailable {
		t.Fatalf("Status() after switch = %+v", status)
	}
	if len(f.probes) != 0 {
		t.Fatalf("Claude Desktop has nothing to probe, got %v", f.probes)
	}

	var meta map[string]any
	if err := json.Unmarshal(mustReadFile(t, metaPath), &meta); err != nil {
		t.Fatal(err)
	}
	entries, _ := meta["entries"].([]any)
	if meta["appliedId"] != ZhibanClaudeDesktopConfigID || len(entries) != 1 {
		t.Fatalf("_meta.json = %v", meta)
	}
	var entry map[string]any
	if err := json.Unmarshal(mustReadFile(t, entryPath), &entry); err != nil {
		t.Fatal(err)
	}
	helperPath := f.manager.claudeDesktopHelperPath()
	if entry["inferenceProvider"] != "gateway" || entry["inferenceGatewayBaseUrl"] != "https://api.airick.cn" ||
		entry["inferenceCredentialKind"] != "helper-script" || entry["inferenceCredentialHelper"] != helperPath ||
		entry["chatTabEnabled"] != true || entry["inferenceCredentialHelperTtlSec"] != float64(claudeDesktopHelperTTLSeconds) {
		t.Fatalf("entry = %v", entry)
	}
	if _, pinned := entry["inferenceModels"]; pinned || entry["modelDiscoveryEnabled"] != true {
		t.Fatalf("the picker must come from discovery, entry = %v", entry)
	}
	if entry["deploymentDisplayName"] != zhibanClaudeDesktopDeploymentName || entry["deploymentDisplaySubtitle"] != zhibanClaudeDesktopDeploymentSubtitle {
		t.Fatalf("the account area must show Zhiban, not the machine name, entry = %v", entry)
	}
	if strings.Contains(string(mustReadFile(t, entryPath)), "sk-") {
		t.Fatal("no credential may be written into the entry")
	}
	helperInfo, err := os.Stat(helperPath)
	if err != nil || helperInfo.Mode().Perm() != 0o700 {
		t.Fatalf("helper wrapper = %v, %v", helperInfo, err)
	}
	helper := string(mustReadFile(t, helperPath))
	if !strings.HasPrefix(helper, "#!/bin/sh\n") || !strings.Contains(helper, "credential get --target claude_desktop") || !strings.Contains(helper, f.helper) {
		t.Fatalf("helper wrapper = %q", helper)
	}

	// Switching again is a no-op; verification records L2.
	again, err := f.manager.PlanWithType(context.Background(), TargetClaudeDesktop, "claude-desktop-install", PlanTypeSwitchGlobal)
	if err != nil || again.Action != ActionNone {
		t.Fatalf("second switch plan = %+v, %v", again, err)
	}
	recorded, err := f.manager.RecordGlobalVerification(context.Background(), TargetClaudeDesktop, testClaudeDesktopVersion)
	if err != nil || recorded.VerificationLevel != VerificationL2 || recorded.LastVerifiedAt == "" {
		t.Fatalf("RecordGlobalVerification(claude_desktop) = %+v, %v", recorded, err)
	}

	// The user picks another entry in the app: no longer routed through Zhiban.
	meta["entries"] = append(entries, map[string]any{"id": "d281ada9-93c2-44f0-8467-fac6fc8949ed", "name": "Default"})
	meta["appliedId"] = "d281ada9-93c2-44f0-8467-fac6fc8949ed"
	edited, _ := json.MarshalIndent(meta, "", "  ")
	mustWriteFile(t, metaPath, append(edited, '\n'), 0o600)
	drifted, _ := f.manager.Status(context.Background(), TargetClaudeDesktop)
	if drifted.CurrentService != ServiceOfficial || !drifted.GlobalDrifted || !drifted.GlobalSwitched {
		t.Fatalf("Status() after appliedId changed = %+v", drifted)
	}
	// 一键修复 re-applies Zhiban's entry without touching the user's.
	repaired := f.switchTo(t, TargetClaudeDesktop)
	if repaired.CurrentService != ServiceZhiban || repaired.GlobalDrifted {
		t.Fatalf("Status() after re-switch = %+v", repaired)
	}
	if err := json.Unmarshal(mustReadFile(t, metaPath), &meta); err != nil {
		t.Fatal(err)
	}
	if entries, _ = meta["entries"].([]any); meta["appliedId"] != ZhibanClaudeDesktopConfigID || len(entries) != 2 {
		t.Fatalf("_meta.json after re-switch = %v", meta)
	}

	// Restore: Zhiban's entry disappears, the user's entry becomes applied.
	restored := f.restore(t, TargetClaudeDesktop)
	if restored.CurrentService != ServiceOfficial || restored.GlobalSwitched {
		t.Fatalf("Status() after restore = %+v", restored)
	}
	if _, err := os.Stat(entryPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Zhiban entry must be removed: %v", err)
	}
	if err := json.Unmarshal(mustReadFile(t, metaPath), &meta); err != nil {
		t.Fatal(err)
	}
	entries, _ = meta["entries"].([]any)
	if meta["appliedId"] != "d281ada9-93c2-44f0-8467-fac6fc8949ed" || len(entries) != 1 {
		t.Fatalf("_meta.json after restore = %v", meta)
	}
}

func TestClaudeDesktopRestoreRemovesLibraryZhibanCreated(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.withDesktop(t)
	f.switchTo(t, TargetClaudeDesktop)
	f.restore(t, TargetClaudeDesktop)
	for _, path := range []string{f.manager.claudeDesktopMetaPath(), f.manager.claudeDesktopConfigPath()} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s must be removed when Zhiban created the library: %v", filepath.Base(path), err)
		}
	}
}

func TestClaudeDesktopSwitchKeepsExistingLibraryEntries(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.withDesktop(t)
	metaPath := f.manager.claudeDesktopMetaPath()
	// The app already wrote a Default entry (as on the test Mac).
	mustWriteFile(t, metaPath, []byte("{\n  \"appliedId\": \"d281ada9-93c2-44f0-8467-fac6fc8949ed\",\n  \"entries\": [\n    {\n      \"id\": \"d281ada9-93c2-44f0-8467-fac6fc8949ed\",\n      \"name\": \"Default\"\n    }\n  ]\n}\n"), 0o600)
	mustWriteFile(t, filepath.Join(filepath.Dir(metaPath), "d281ada9-93c2-44f0-8467-fac6fc8949ed.json"), []byte("{\"inferenceProvider\":\"gateway\",\"inferenceGatewayBaseUrl\":\"https://other.example\"}\n"), 0o600)

	status := f.switchTo(t, TargetClaudeDesktop)
	if status.CurrentService != ServiceZhiban || !status.GlobalBackupAvailable {
		t.Fatalf("Status() after switch = %+v", status)
	}
	var meta map[string]any
	if err := json.Unmarshal(mustReadFile(t, metaPath), &meta); err != nil {
		t.Fatal(err)
	}
	entries, _ := meta["entries"].([]any)
	if meta["appliedId"] != ZhibanClaudeDesktopConfigID || len(entries) != 2 || entries[0].(map[string]any)["name"] != "Default" {
		t.Fatalf("_meta.json after switch = %v", meta)
	}
	if !strings.Contains(string(mustReadFile(t, filepath.Join(filepath.Dir(metaPath), "d281ada9-93c2-44f0-8467-fac6fc8949ed.json"))), "other.example") {
		t.Fatal("the user's own entry must not be touched")
	}

	// Restore with a pre-existing index: the index is what was backed up, and
	// the entry file is removed rather than overwritten with that backup
	// (which is what happened on the 2026-09-10 Windows machine).
	f.restore(t, TargetClaudeDesktop)
	if err := json.Unmarshal(mustReadFile(t, metaPath), &meta); err != nil {
		t.Fatal(err)
	}
	entries, _ = meta["entries"].([]any)
	if meta["appliedId"] != "d281ada9-93c2-44f0-8467-fac6fc8949ed" || len(entries) != 1 || entries[0].(map[string]any)["id"] != "d281ada9-93c2-44f0-8467-fac6fc8949ed" {
		t.Fatalf("_meta.json after restore = %v", meta)
	}
	if _, err := os.Stat(f.manager.claudeDesktopConfigPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Zhiban entry must be removed on restore, got %v", err)
	}
}

func TestDesktopTargetHelpersInConfiguration(t *testing.T) {
	t.Parallel()
	if globalFamily(TargetCodexDesktop) != familyCodex || globalFamily(TargetClaudeDesktop) != familyClaudeDesktop || globalFamily(TargetClaudeCLI) != familyClaudeCLI {
		t.Fatal("globalFamily mismatch")
	}
	if manifestOwner(TargetCodexDesktop) != TargetCodexCLI || manifestOwner(TargetClaudeDesktop) != TargetClaudeDesktop || profileTarget(TargetCodexDesktop) != TargetCodexCLI {
		t.Fatal("manifestOwner/profileTarget mismatch")
	}
	if !IsDesktopTarget(TargetClaudeDesktop) || IsDesktopTarget(TargetCodexCLI) || !validTarget(TargetCodexDesktop) || validTarget("codex_web") {
		t.Fatal("target validation mismatch")
	}
}

// NewManager must accept the two desktop versions main.go passes alongside the
// mandatory CLI versions, and still refuse unknown targets or a missing CLI.
func TestNewManagerAcceptsDesktopSupportedVersions(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	build := func(versions map[string]string) error {
		_, err := NewManager(ManagerConfig{
			HomeDir: home, HelperExecutable: filepath.Join(home, "bridge"),
			Profiles: map[Environment]map[string]GatewayProfile{EnvironmentProd: {
				TargetCodexCLI:      {Version: testProfile, BaseURL: "https://api.airick.cn/v1", Model: "gpt-5.6-luna"},
				TargetClaudeDesktop: {Version: testProfile, BaseURL: "https://api.airick.cn", Model: "claude-sonnet-4-6"},
			}},
			SupportedVersions: versions,
			ResolveInstallation: func(context.Context, string, string) (Installation, error) {
				return Installation{}, ErrInstallationChanged
			},
			ResolveAuthorization: func(context.Context, string) (AuthorizationProfile, error) {
				return AuthorizationProfile{}, ErrAuthorizationMissing
			},
		})
		return err
	}
	if err := build(map[string]string{
		TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion,
		TargetCodexDesktop: testCodexDesktopVersion, TargetClaudeDesktop: testClaudeDesktopVersion,
	}); err != nil {
		t.Fatalf("NewManager(four targets) error = %v", err)
	}
	if err := build(map[string]string{TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion}); err != nil {
		t.Fatalf("NewManager(two CLI targets) error = %v", err)
	}
	if err := build(map[string]string{TargetCodexCLI: testCodexVersion, TargetClaudeDesktop: testClaudeDesktopVersion}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("NewManager(missing claude_cli) error = %v", err)
	}
	if err := build(map[string]string{TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion, "codex_web": "1"}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("NewManager(unknown target) error = %v", err)
	}
}
