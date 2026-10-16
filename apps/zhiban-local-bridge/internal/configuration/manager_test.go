package configuration

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

const (
	testCodexVersion  = "0.153.4"
	testClaudeVersion = "2.1.263"
	testProfile       = "2026.09.07.1"
)

func TestManagerCreatesIsolatedProfilesWithoutChangingUserConfig(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "Zhiban Local Bridge.app", "Contents", "MacOS", "zhiban-local-bridge"))
	codex := writeExecutable(t, filepath.Join(home, ".codex", "packages", "standalone", "current", "bin", "codex"))
	claude := writeExecutable(t, filepath.Join(home, ".local", "share", "claude", "versions", testClaudeVersion))
	codexBase := filepath.Join(home, ".codex", "config.toml")
	claudeBase := filepath.Join(home, ".claude", "settings.json")
	mustWriteFile(t, codexBase, []byte("model = \"user-model\"\n"), 0o600)
	mustWriteFile(t, claudeBase, []byte(`{"theme":"dark"}`), 0o600)

	var probes []string
	manager := newTestManager(t, home, helper, map[string]Installation{
		TargetCodexCLI:  {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
		TargetClaudeCLI: {TargetID: TargetClaudeCLI, InstallationID: "claude-install", Executable: claude, Version: testClaudeVersion},
	}, func(_ context.Context, installation Installation, targetPath string) error {
		probes = append(probes, installation.TargetID+":"+filepath.Base(targetPath))
		return nil
	}, time.Now)

	for target, installationID := range map[string]string{TargetCodexCLI: "codex-install", TargetClaudeCLI: "claude-install"} {
		plan, err := manager.Plan(context.Background(), target, installationID)
		if err != nil {
			t.Fatalf("Plan(%s) error = %v", target, err)
		}
		if plan.PlanID == "" || plan.Action != ActionCreate || plan.ProfileVersion != testProfile {
			t.Fatalf("Plan(%s) = %+v", target, plan)
		}
		status, err := manager.Execute(context.Background(), plan.PlanID)
		if err != nil {
			t.Fatalf("Execute(%s) error = %v", target, err)
		}
		if status.State != StateConfigured || status.VerificationLevel != "l1" || status.ProfileVersion != testProfile {
			t.Fatalf("Execute(%s) status = %+v", target, status)
		}
	}

	if got := string(mustReadFile(t, codexBase)); got != "model = \"user-model\"\n" {
		t.Fatalf("Codex base config changed: %q", got)
	}
	if got := string(mustReadFile(t, claudeBase)); got != `{"theme":"dark"}` {
		t.Fatalf("Claude base config changed: %q", got)
	}

	codexManaged := string(mustReadFile(t, filepath.Join(home, ".codex", CodexProfileFileName)))
	for _, want := range []string{
		`model_provider = "zhiban_ai_managed"`,
		`[model_providers.zhiban_ai_managed.auth]`,
		`args = ["credential", "get", "--target", "codex_cli"]`,
	} {
		if !strings.Contains(codexManaged, want) {
			t.Fatalf("Codex managed profile missing %q: %s", want, codexManaged)
		}
	}
	if strings.Contains(codexManaged, "[profiles.") || strings.Contains(codexManaged, "lctd.") {
		t.Fatalf("Codex managed profile contains legacy profile or credential: %s", codexManaged)
	}

	claudeManagedPath := filepath.Join(home, "Library", "Application Support", applicationSupportID, "local-coding-tools", "claude", "settings.json")
	claudeManaged := string(mustReadFile(t, claudeManagedPath))
	if !strings.Contains(claudeManaged, `"apiKeyHelper"`) ||
		!strings.Contains(claudeManaged, `"ANTHROPIC_BASE_URL"`) ||
		!strings.Contains(claudeManaged, `credential get --target claude_cli`) ||
		strings.Contains(claudeManaged, "ANTHROPIC_API_KEY") || strings.Contains(claudeManaged, "lctd.") {
		t.Fatalf("Claude managed settings are unsafe: %s", claudeManaged)
	}
	if !strings.Contains(claudeManaged, `'`+helper+`'`) {
		t.Fatalf("Claude helper path was not shell quoted: %s", claudeManaged)
	}
	sort.Strings(probes)
	if strings.Join(probes, ",") != "claude_cli:settings.json,codex_cli:"+CodexProfileFileName {
		t.Fatalf("probes = %v", probes)
	}

	for _, target := range []string{TargetCodexCLI, TargetClaudeCLI} {
		status, err := manager.Status(context.Background(), target)
		if err != nil || status.State != StateConfigured {
			t.Fatalf("Status(%s) = %+v, %v", target, status, err)
		}
		manifest := string(mustReadFile(t, manager.manifestPath(target)))
		for _, forbidden := range []string{home, helper, "beeaicloud", "apiKeyHelper"} {
			if strings.Contains(manifest, forbidden) {
				t.Fatalf("manifest leaks %q: %s", forbidden, manifest)
			}
		}
	}
}

func TestManagerResolvesOnlyCurrentManagedLaunchConfiguration(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	claude := writeExecutable(t, filepath.Join(home, "claude"))
	manager := newTestManager(t, home, helper, map[string]Installation{
		TargetCodexCLI:  {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
		TargetClaudeCLI: {TargetID: TargetClaudeCLI, InstallationID: "claude-install", Executable: claude, Version: testClaudeVersion},
	}, nil, time.Now)

	if _, err := manager.ResolveLaunchConfiguration(context.Background(), TargetCodexCLI, testProfile); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("unconfigured error = %v, want ErrPreconditionChanged", err)
	}
	for target, installationID := range map[string]string{TargetCodexCLI: "codex-install", TargetClaudeCLI: "claude-install"} {
		plan, err := manager.Plan(context.Background(), target, installationID)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := manager.Execute(context.Background(), plan.PlanID); err != nil {
			t.Fatal(err)
		}
	}

	codexLaunch, err := manager.ResolveLaunchConfiguration(context.Background(), TargetCodexCLI, testProfile)
	if err != nil {
		t.Fatal(err)
	}
	if codexLaunch.TargetID != TargetCodexCLI || codexLaunch.ProfileVersion != testProfile || strings.Join(codexLaunch.Arguments, " ") != "--profile zhiban-ai-managed" {
		t.Fatalf("Codex launch configuration = %+v", codexLaunch)
	}
	claudeLaunch, err := manager.ResolveLaunchConfiguration(context.Background(), TargetClaudeCLI, testProfile)
	if err != nil {
		t.Fatal(err)
	}
	wantSettings := filepath.Join(home, "Library", "Application Support", applicationSupportID, "local-coding-tools", "claude", "settings.json")
	if claudeLaunch.TargetID != TargetClaudeCLI || claudeLaunch.ProfileVersion != testProfile || len(claudeLaunch.Arguments) != 2 || claudeLaunch.Arguments[0] != "--settings" || claudeLaunch.Arguments[1] != wantSettings {
		t.Fatalf("Claude launch configuration = %+v", claudeLaunch)
	}
	if _, err := manager.ResolveLaunchConfiguration(context.Background(), TargetCodexCLI, "2026.09.07.2"); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("profile drift error = %v, want ErrPreconditionChanged", err)
	}

	mustWriteFile(t, filepath.Join(home, ".codex", CodexProfileFileName), []byte("user edit\n"), 0o600)
	if _, err := manager.ResolveLaunchConfiguration(context.Background(), TargetCodexCLI, testProfile); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("configuration drift error = %v, want ErrPreconditionChanged", err)
	}
}

func TestManagerRefusesUnmanagedAndUserModifiedFiles(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	manager := newTestManager(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, nil, time.Now)
	managedPath := filepath.Join(home, ".codex", CodexProfileFileName)
	mustWriteFile(t, managedPath, []byte("user_owned = true\n"), 0o600)

	plan, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if plan.Action != ActionConflict || plan.PlanID != "" {
		t.Fatalf("unmanaged plan = %+v", plan)
	}
	if got := string(mustReadFile(t, managedPath)); got != "user_owned = true\n" {
		t.Fatalf("unmanaged file changed: %q", got)
	}

	os.Remove(managedPath)
	created, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), created.PlanID); err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, managedPath, append(mustReadFile(t, managedPath), []byte("# user edit\n")...), 0o600)

	status, err := manager.Status(context.Background(), TargetCodexCLI)
	if err != nil || status.State != StateConflict || status.ErrorCode != "LCT-CODEX_CLI-CONFIG-CONFLICT" {
		t.Fatalf("modified status = %+v, %v", status, err)
	}
	plan, err = manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil || plan.Action != ActionConflict || plan.PlanID != "" {
		t.Fatalf("modified plan = %+v, %v", plan, err)
	}
	if _, err := manager.Restore(context.Background(), TargetCodexCLI); !errors.Is(err, ErrConflict) {
		t.Fatalf("Restore modified error = %v, want conflict", err)
	}
}

func TestManagerIsIdempotentUpdatesOwnedConfigAndRestores(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	profiles := testProfiles("https://gateway-one.example/v1")
	manager := newTestManagerWithProfiles(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, nil, time.Now, profiles)

	create, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), create.PlanID); err != nil {
		t.Fatal(err)
	}
	noop, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil || noop.Action != ActionNone {
		t.Fatalf("noop plan = %+v, %v", noop, err)
	}
	if _, err := manager.Execute(context.Background(), noop.PlanID); err != nil {
		t.Fatal(err)
	}

	profiles[EnvironmentProd][TargetCodexCLI] = GatewayProfile{Version: testProfile, BaseURL: "https://gateway-two.example/v1"}
	manager = newTestManagerWithProfiles(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, nil, time.Now, profiles)
	update, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil || update.Action != ActionUpdate {
		t.Fatalf("update plan = %+v, %v", update, err)
	}
	if _, err := manager.Execute(context.Background(), update.PlanID); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(mustReadFile(t, filepath.Join(home, ".codex", CodexProfileFileName))), "gateway-two.example") {
		t.Fatal("owned profile was not updated")
	}

	profiles[EnvironmentProd][TargetCodexCLI] = GatewayProfile{Version: "2026.09.07.2", BaseURL: "https://gateway-two.example/v1"}
	manager = newTestManagerWithProfiles(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, nil, time.Now, profiles)
	profileOnlyUpdate, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil || profileOnlyUpdate.Action != ActionUpdate {
		t.Fatalf("profile-only update plan = %+v, %v", profileOnlyUpdate, err)
	}
	statusAfterProfileUpdate, err := manager.Execute(context.Background(), profileOnlyUpdate.PlanID)
	if err != nil || statusAfterProfileUpdate.ProfileVersion != "2026.09.07.2" {
		t.Fatalf("profile-only update status = %+v, %v", statusAfterProfileUpdate, err)
	}

	status, err := manager.Restore(context.Background(), TargetCodexCLI)
	if err != nil || status.State != StateNotConfigured {
		t.Fatalf("Restore status = %+v, %v", status, err)
	}
	if _, err := os.Lstat(filepath.Join(home, ".codex", CodexProfileFileName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("managed profile still exists: %v", err)
	}
	if _, err := os.Lstat(manager.manifestPath(TargetCodexCLI)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("manifest still exists: %v", err)
	}
}

func TestManagerRollsBackOnProbeFailure(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	manager := newTestManager(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, func(context.Context, Installation, string) error { return errors.New("parse rejected") }, time.Now)

	plan, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), plan.PlanID); !errors.Is(err, ErrValidationFailed) {
		t.Fatalf("Execute error = %v, want validation failure", err)
	}
	if _, err := os.Lstat(filepath.Join(home, ".codex", CodexProfileFileName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed profile was not removed: %v", err)
	}
	if _, err := os.Lstat(manager.manifestPath(TargetCodexCLI)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed manifest was not removed: %v", err)
	}
}

func TestManagerDoesNotOverwriteChangeAfterFinalPrecheck(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	managedPath := filepath.Join(home, ".codex", CodexProfileFileName)
	if err := os.MkdirAll(filepath.Dir(managedPath), 0o700); err != nil {
		t.Fatal(err)
	}
	resolveCalls := 0
	manager, err := NewManager(ManagerConfig{
		HomeDir:          home,
		HelperExecutable: helper,
		Profiles:         testProfiles("https://api.beeaicloud.com/v1"),
		SupportedVersions: map[string]string{
			TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion,
		},
		ResolveInstallation: func(context.Context, string, string) (Installation, error) {
			return Installation{
				TargetID: TargetCodexCLI, InstallationID: "codex-install",
				Executable: codex, Version: testCodexVersion,
			}, nil
		},
		ResolveAuthorization: func(context.Context, string) (AuthorizationProfile, error) {
			resolveCalls++
			if resolveCalls == 2 {
				if err := os.WriteFile(managedPath, []byte("user-change\n"), 0o600); err != nil {
					return AuthorizationProfile{}, err
				}
			}
			return AuthorizationProfile{Environment: EnvironmentProd, ProfileVersion: testProfile}, nil
		},
		Probe:  func(context.Context, Installation, string) error { return nil },
		Random: strings.NewReader(strings.Repeat("C", 512)),
	})
	if err != nil {
		t.Fatal(err)
	}

	plan, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), plan.PlanID); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("Execute error = %v, want precondition changed", err)
	}
	if got := string(mustReadFile(t, managedPath)); got != "user-change\n" {
		t.Fatalf("concurrent user change was overwritten: %q", got)
	}
}

func TestManagerDoesNotRollbackOverChangeMadeDuringProbe(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	manager := newTestManager(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, func(_ context.Context, _ Installation, managedPath string) error {
		if err := os.WriteFile(managedPath, []byte("user-change-during-probe\n"), 0o600); err != nil {
			return err
		}
		return errors.New("parse rejected")
	}, time.Now)

	plan, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), plan.PlanID); !errors.Is(err, ErrRollbackFailed) {
		t.Fatalf("Execute error = %v, want rollback failed after preserving concurrent change", err)
	}
	if got := string(mustReadFile(t, filepath.Join(home, ".codex", CodexProfileFileName))); got != "user-change-during-probe\n" {
		t.Fatalf("change made during probe was overwritten: %q", got)
	}
}

func TestManagerRejectsSymlinkedManagedParent(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	outside := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	if err := os.Symlink(outside, filepath.Join(home, ".codex")); err != nil {
		t.Fatal(err)
	}
	manager := newTestManager(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, nil, time.Now)

	if _, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install"); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("Plan error = %v, want unsafe path", err)
	}
	if entries, err := os.ReadDir(outside); err != nil || len(entries) != 0 {
		t.Fatalf("symlink destination was changed: entries=%v, error=%v", entries, err)
	}
}

func TestManagedFileMutationStaysBoundToOpenedDirectory(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	outside := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	manager := newTestManager(t, home, helper, nil, nil, time.Now)
	managedPath := filepath.Join(home, ".codex", CodexProfileFileName)
	managed, err := manager.openManagedFile(managedPath, true)
	if err != nil {
		t.Fatal(err)
	}
	defer managed.close()

	pinnedParent := filepath.Join(home, ".codex-pinned")
	if err := os.Rename(filepath.Join(home, ".codex"), pinnedParent); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(home, ".codex")); err != nil {
		t.Fatal(err)
	}
	content := []byte("pinned-directory\n")
	if err := managed.atomicWriteCAS(content, 0o600, fileSnapshot{}); err != nil {
		t.Fatal(err)
	}
	if got := string(mustReadFile(t, filepath.Join(pinnedParent, CodexProfileFileName))); got != string(content) {
		t.Fatalf("pinned directory content = %q", got)
	}
	if entries, err := os.ReadDir(outside); err != nil || len(entries) != 0 {
		t.Fatalf("replacement symlink destination was changed: entries=%v, error=%v", entries, err)
	}
}

func TestSwappedWriteRollbackPreservesNewTargetAndDisplacedOldFile(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	manager := newTestManager(t, home, helper, nil, nil, time.Now)
	managedPath := filepath.Join(home, ".codex", CodexProfileFileName)
	managed, err := manager.openManagedFile(managedPath, true)
	if err != nil {
		t.Fatal(err)
	}
	defer managed.close()

	oldContent := []byte("old-user-content\n")
	if err := managed.atomicWriteCAS(oldContent, 0o600, fileSnapshot{}); err != nil {
		t.Fatal(err)
	}
	desiredContent := []byte("zhiban-desired\n")
	temporaryName, err := managed.createTemporary(desiredContent, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer secureUnlinkAt(int(managed.parent.Fd()), temporaryName)
	if err := secureRenameSwapAt(
		int(managed.parent.Fd()), temporaryName,
		int(managed.parent.Fd()), managed.name,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(managedPath, []byte("new-user-content\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	cleanup, err := managed.rollbackSwappedWrite(
		temporaryName,
		snapshotForContent(desiredContent, 0o600),
	)
	if cleanup || !errors.Is(err, ErrRollbackFailed) {
		t.Fatalf("rollback result = cleanup %v, error %v", cleanup, err)
	}
	if got := string(mustReadFile(t, managedPath)); got != "new-user-content\n" {
		t.Fatalf("new target content was changed: %q", got)
	}
	displaced, err := managed.snapshotName(temporaryName)
	if err != nil || string(displaced.Bytes) != string(oldContent) {
		t.Fatalf("displaced old file = %+v, error %v", displaced, err)
	}
}

func TestManagerDoesNotFollowInterceptedManifestPath(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	outside := filepath.Join(t.TempDir(), "outside.json")
	mustWriteFile(t, outside, []byte("outside-owned\n"), 0o600)
	var manager *Manager
	manager = newTestManager(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, func(context.Context, Installation, string) error {
		manifestPath := manager.manifestPath(TargetCodexCLI)
		if err := os.MkdirAll(filepath.Dir(manifestPath), 0o700); err != nil {
			return err
		}
		return os.Symlink(outside, manifestPath)
	}, time.Now)

	plan, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), plan.PlanID); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("Execute error = %v, want unsafe path", err)
	}
	if _, err := os.Lstat(filepath.Join(home, ".codex", CodexProfileFileName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("managed profile was not rolled back: %v", err)
	}
	if info, err := os.Lstat(manager.manifestPath(TargetCodexCLI)); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("concurrent manifest path was unexpectedly changed: info=%v, error=%v", info, err)
	}
	if got := string(mustReadFile(t, outside)); got != "outside-owned\n" {
		t.Fatalf("symlink destination changed: %q", got)
	}
}

func TestManagerRejectsExpiredReplayedAndChangedPlans(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	now := time.Date(2026, 9, 7, 10, 0, 0, 0, time.UTC)
	manager := newTestManager(t, home, helper, map[string]Installation{
		TargetCodexCLI: {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
	}, nil, func() time.Time { return now })

	expired, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(planTTL + time.Second)
	if _, err := manager.Execute(context.Background(), expired.PlanID); !errors.Is(err, ErrPlanExpired) {
		t.Fatalf("expired Execute error = %v", err)
	}

	now = now.Add(time.Second)
	changed, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, filepath.Join(home, ".codex", CodexProfileFileName), []byte("raced = true\n"), 0o600)
	if _, err := manager.Execute(context.Background(), changed.PlanID); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("changed Execute error = %v", err)
	}

	os.Remove(filepath.Join(home, ".codex", CodexProfileFileName))
	replay, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), replay.PlanID); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), replay.PlanID); !errors.Is(err, ErrPlanNotFound) {
		t.Fatalf("replayed Execute error = %v", err)
	}
}

func TestManagerRejectsUnsupportedVersionAndUnsafeHelper(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	installation := Installation{TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: "0.152.0"}
	manager := newTestManager(t, home, helper, map[string]Installation{TargetCodexCLI: installation}, nil, time.Now)
	if _, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install"); !errors.Is(err, ErrUnsupportedVersion) {
		t.Fatalf("unsupported version error = %v", err)
	}

	installation.Version = testCodexVersion
	if err := os.Chmod(helper, 0o777); err != nil {
		t.Fatal(err)
	}
	manager = newTestManager(t, home, helper, map[string]Installation{TargetCodexCLI: installation}, nil, time.Now)
	if _, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install"); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("unsafe helper error = %v", err)
	}
}

func TestRunProbeUsesOfflineConfigurationLoadingCommands(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := filepath.Join(home, "codex")
	mustWriteFile(t, codex, []byte("#!/bin/sh\n[ \"$*\" = \"--profile zhiban-ai-managed mcp list\" ]\n"), 0o700)
	claude := filepath.Join(home, "claude")
	mustWriteFile(t, claude, []byte("#!/bin/sh\n[ \"$*\" = \"--settings "+filepath.Join(home, "settings.json")+" --version\" ]\n"), 0o700)
	manager := newTestManager(t, home, helper, nil, nil, time.Now)

	if err := manager.runProbe(context.Background(), Installation{
		TargetID: TargetCodexCLI, Executable: codex,
	}, filepath.Join(home, CodexProfileFileName)); err != nil {
		t.Fatalf("Codex runProbe error = %v", err)
	}
	if err := manager.runProbe(context.Background(), Installation{
		TargetID: TargetClaudeCLI, Executable: claude,
	}, filepath.Join(home, "settings.json")); err != nil {
		t.Fatalf("Claude runProbe error = %v", err)
	}
}

func TestValidateManagedContentRejectsUnknownClaudeSettings(t *testing.T) {
	t.Parallel()

	valid := []byte(`{"$schema":"https://json.schemastore.org/claude-code-settings.json","apiKeyHelper":"'/fixed/helper' credential get --target claude_cli","env":{"ANTHROPIC_BASE_URL":"https://gateway.example"}}`)
	if err := validateManagedContent(TargetClaudeCLI, valid); err != nil {
		t.Fatalf("valid Claude settings error = %v", err)
	}
	unknown := []byte(`{"$schema":"https://json.schemastore.org/claude-code-settings.json","apiKeyHelper":"helper","env":{"ANTHROPIC_BASE_URL":"https://gateway.example"},"permissions":{"allow":["Bash(*)"]}}`)
	if err := validateManagedContent(TargetClaudeCLI, unknown); !errors.Is(err, ErrValidationFailed) {
		t.Fatalf("unknown Claude settings error = %v", err)
	}
}

func TestNewManagerRejectsMissingOrUnsafeGatewayProfiles(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	base := ManagerConfig{
		HomeDir:          home,
		HelperExecutable: helper,
		SupportedVersions: map[string]string{
			TargetCodexCLI:  testCodexVersion,
			TargetClaudeCLI: testClaudeVersion,
		},
		ResolveInstallation: func(context.Context, string, string) (Installation, error) {
			return Installation{}, ErrInstallationChanged
		},
		ResolveAuthorization: func(context.Context, string) (AuthorizationProfile, error) {
			return AuthorizationProfile{}, ErrAuthorizationMissing
		},
	}
	if _, err := NewManager(base); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("missing profiles error = %v", err)
	}
	base.Profiles = map[Environment]map[string]GatewayProfile{
		EnvironmentProd: {
			TargetCodexCLI: {Version: testProfile, BaseURL: "http://remote.example/v1"},
		},
	}
	if _, err := NewManager(base); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("unsafe profile error = %v", err)
	}
}

func TestExecuteRejectsAuthorizationOrHelperChangesAfterPlan(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	codex := writeExecutable(t, filepath.Join(home, "codex"))
	authorization := AuthorizationProfile{
		Environment: EnvironmentProd, ProfileVersion: testProfile,
	}
	manager, err := NewManager(ManagerConfig{
		HomeDir:          home,
		HelperExecutable: helper,
		Profiles:         testProfiles("https://api.beeaicloud.com/v1"),
		SupportedVersions: map[string]string{
			TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion,
		},
		ResolveInstallation: func(context.Context, string, string) (Installation, error) {
			return Installation{
				TargetID: TargetCodexCLI, InstallationID: "codex-install",
				Executable: codex, Version: testCodexVersion,
			}, nil
		},
		ResolveAuthorization: func(context.Context, string) (AuthorizationProfile, error) {
			return authorization, nil
		},
		Probe:  func(context.Context, Installation, string) error { return nil },
		Random: strings.NewReader(strings.Repeat("P", 512)),
	})
	if err != nil {
		t.Fatal(err)
	}

	authorizationPlan, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	authorization.ProfileVersion = "2026.09.07.2"
	if _, err := manager.Execute(context.Background(), authorizationPlan.PlanID); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("changed authorization Execute error = %v", err)
	}
	authorization.ProfileVersion = testProfile

	helperPlan, err := manager.Plan(context.Background(), TargetCodexCLI, "codex-install")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(helper, 0o777); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Execute(context.Background(), helperPlan.PlanID); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("changed helper Execute error = %v", err)
	}
	if _, err := os.Lstat(filepath.Join(home, ".codex", CodexProfileFileName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("configuration was written after precondition change: %v", err)
	}
}

func newTestManager(
	t *testing.T,
	home, helper string,
	installations map[string]Installation,
	probe ProbeFunc,
	now func() time.Time,
) *Manager {
	t.Helper()
	return newTestManagerWithProfiles(t, home, helper, installations, probe, now, testProfiles("https://api.beeaicloud.com/v1"))
}

func newTestManagerWithProfiles(
	t *testing.T,
	home, helper string,
	installations map[string]Installation,
	probe ProbeFunc,
	now func() time.Time,
	profiles map[Environment]map[string]GatewayProfile,
) *Manager {
	t.Helper()
	manager, err := NewManager(ManagerConfig{
		HomeDir:          home,
		HelperExecutable: helper,
		Profiles:         profiles,
		SupportedVersions: map[string]string{
			TargetCodexCLI:  testCodexVersion,
			TargetClaudeCLI: testClaudeVersion,
		},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			installation, ok := installations[targetID]
			if !ok || installation.InstallationID != installationID {
				return Installation{}, ErrInstallationChanged
			}
			return installation, nil
		},
		ResolveAuthorization: func(_ context.Context, targetID string) (AuthorizationProfile, error) {
			profile, ok := profiles[EnvironmentProd][targetID]
			if !ok {
				return AuthorizationProfile{}, ErrProfileUnavailable
			}
			return AuthorizationProfile{Environment: EnvironmentProd, ProfileVersion: profile.Version}, nil
		},
		Probe:  probe,
		Now:    now,
		Random: strings.NewReader(strings.Repeat("R", 512)),
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	return manager
}

func testProfiles(codexURL string) map[Environment]map[string]GatewayProfile {
	return map[Environment]map[string]GatewayProfile{
		EnvironmentProd: {
			TargetCodexCLI:  {Version: testProfile, BaseURL: codexURL},
			TargetClaudeCLI: {Version: testProfile, BaseURL: "https://api.beeaicloud.com"},
		},
	}
}

func writeExecutable(t *testing.T, path string) string {
	t.Helper()
	mustWriteFile(t, path, []byte("#!/bin/sh\nexit 0\n"), 0o700)
	return path
}

func mustWriteFile(t *testing.T, path string, content []byte, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, content, mode); err != nil {
		t.Fatal(err)
	}
}

func mustReadFile(t *testing.T, path string) []byte {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return content
}
