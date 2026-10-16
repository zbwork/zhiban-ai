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

func newVerifiedFixture(t *testing.T) (*Manager, string, map[string]Installation) {
	t.Helper()
	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "Zhiban Local Bridge.app", "Contents", "MacOS", "zhiban-local-bridge"))
	codex := writeExecutable(t, filepath.Join(home, ".codex", "packages", "standalone", "current", "bin", "codex"))
	claude := writeExecutable(t, filepath.Join(home, ".local", "share", "claude", "versions", testClaudeVersion))
	installations := map[string]Installation{
		TargetCodexCLI:  {TargetID: TargetCodexCLI, InstallationID: "codex-install", Executable: codex, Version: testCodexVersion},
		TargetClaudeCLI: {TargetID: TargetClaudeCLI, InstallationID: "claude-install", Executable: claude, Version: testClaudeVersion},
	}
	manager := newTestManager(t, home, helper, installations, func(context.Context, Installation, string) error { return nil }, time.Now)
	for target, installation := range installations {
		plan, err := manager.Plan(context.Background(), target, installation.InstallationID)
		if err != nil {
			t.Fatalf("Plan(%s) error = %v", target, err)
		}
		if _, err := manager.Execute(context.Background(), plan.PlanID); err != nil {
			t.Fatalf("Execute(%s) error = %v", target, err)
		}
	}
	return manager, home, installations
}

func TestManagerRendersModelAliasAndAutoupdaterGuard(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	manager, err := NewManager(ManagerConfig{
		HomeDir: home, HelperExecutable: helper,
		Profiles: map[Environment]map[string]GatewayProfile{
			EnvironmentProd: {
				TargetCodexCLI:  {Version: testProfile, BaseURL: "https://api.airick.cn/v1", Model: "gpt-5.6-luna"},
				TargetClaudeCLI: {Version: testProfile, BaseURL: "https://api.airick.cn", Model: "gpt-5.6-luna"},
			},
		},
		SupportedVersions: map[string]string{TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion},
		ResolveInstallation: func(context.Context, string, string) (Installation, error) {
			return Installation{}, ErrInstallationChanged
		},
		ResolveAuthorization: func(context.Context, string) (AuthorizationProfile, error) {
			return AuthorizationProfile{}, ErrAuthorizationMissing
		},
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	codex, err := manager.render(TargetCodexCLI, manager.profiles[EnvironmentProd][TargetCodexCLI])
	if err != nil {
		t.Fatalf("render(codex) error = %v", err)
	}
	for _, want := range []string{`model_provider = "zhiban_ai_managed"`, `model = "gpt-5.6-luna"`, `base_url = "https://api.airick.cn/v1"`, `wire_api = "responses"`} {
		if !strings.Contains(string(codex), want) {
			t.Fatalf("Codex profile missing %q:\n%s", want, codex)
		}
	}
	claude, err := manager.render(TargetClaudeCLI, manager.profiles[EnvironmentProd][TargetClaudeCLI])
	if err != nil {
		t.Fatalf("render(claude) error = %v", err)
	}
	var settings claudeManagedSettings
	if err := json.Unmarshal(claude, &settings); err != nil {
		t.Fatalf("decode Claude overlay: %v\n%s", err, claude)
	}
	if settings.Model != "gpt-5.6-luna" || settings.Env.DisableAutoupdater != "1" || settings.Env.AnthropicBaseURL != "https://api.airick.cn" {
		t.Fatalf("Claude overlay = %+v", settings)
	}
	if err := validateManagedContent(TargetClaudeCLI, claude); err != nil {
		t.Fatalf("validateManagedContent(claude) error = %v", err)
	}

	if _, err := NewManager(ManagerConfig{
		HomeDir: home, HelperExecutable: helper,
		Profiles: map[Environment]map[string]GatewayProfile{
			EnvironmentProd: {TargetCodexCLI: {Version: testProfile, BaseURL: "https://api.airick.cn/v1", Model: "bad model"}},
		},
		SupportedVersions: map[string]string{TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion},
		ResolveInstallation: func(context.Context, string, string) (Installation, error) {
			return Installation{}, ErrInstallationChanged
		},
		ResolveAuthorization: func(context.Context, string) (AuthorizationProfile, error) {
			return AuthorizationProfile{}, ErrAuthorizationMissing
		},
	}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("NewManager() with unsafe model error = %v", err)
	}
}

func TestManagerRecordsL3AndFallsBackWhenConfigurationChanges(t *testing.T) {
	t.Parallel()
	manager, home, installations := newVerifiedFixture(t)

	before, err := manager.Status(context.Background(), TargetCodexCLI)
	if err != nil || before.VerificationLevel != VerificationL1 || before.LastVerifiedAt != "" {
		t.Fatalf("Status() before verification = %+v, %v", before, err)
	}
	if _, err := manager.RecordVerification(context.Background(), TargetCodexCLI, "bad version"); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("RecordVerification(bad version) error = %v", err)
	}
	recorded, err := manager.RecordVerification(context.Background(), TargetCodexCLI, testCodexVersion)
	if err != nil || recorded.State != StateConfigured || recorded.VerificationLevel != VerificationL3 || recorded.LastVerifiedAt == "" {
		t.Fatalf("RecordVerification() = %+v, %v", recorded, err)
	}
	if _, err := time.Parse(time.RFC3339, recorded.LastVerifiedAt); err != nil {
		t.Fatalf("LastVerifiedAt = %q: %v", recorded.LastVerifiedAt, err)
	}
	again, err := manager.Status(context.Background(), TargetCodexCLI)
	if err != nil || again.VerificationLevel != VerificationL3 || again.LastVerifiedAt != recorded.LastVerifiedAt {
		t.Fatalf("Status() after verification = %+v, %v", again, err)
	}
	manifestBytes := mustReadFile(t, manager.manifestPath(TargetCodexCLI))
	for _, forbidden := range []string{home, "gpt-", "apiKeyHelper"} {
		if strings.Contains(string(manifestBytes), forbidden) {
			t.Fatalf("manifest leaks %q: %s", forbidden, manifestBytes)
		}
	}
	if !strings.Contains(string(manifestBytes), `"schema_version":2`) || !strings.Contains(string(manifestBytes), `"verification_level":"l3"`) {
		t.Fatalf("manifest = %s", manifestBytes)
	}

	// A verification recorded for a different locked version must not count.
	other, err := manager.RecordVerification(context.Background(), TargetClaudeCLI, "9.9.9")
	if err != nil || other.VerificationLevel != VerificationL1 {
		t.Fatalf("RecordVerification(other version) = %+v, %v", other, err)
	}

	// Re-applying the configuration (same content, plan action none) keeps l3;
	// a content change drops back to l1.
	plan, err := manager.Plan(context.Background(), TargetCodexCLI, installations[TargetCodexCLI].InstallationID)
	if err != nil || plan.Action != ActionNone {
		t.Fatalf("Plan() after verification = %+v, %v", plan, err)
	}
	status, err := manager.Execute(context.Background(), plan.PlanID)
	if err != nil || status.VerificationLevel != VerificationL3 {
		t.Fatalf("Execute(none) = %+v, %v", status, err)
	}
	configPath := manager.configPath(TargetCodexCLI)
	content := mustReadFile(t, configPath)
	mustWriteFile(t, configPath, append(content, []byte("# user edit\n")...), 0o600)
	changed, err := manager.Status(context.Background(), TargetCodexCLI)
	if err != nil || changed.State != StateConflict {
		t.Fatalf("Status() after user edit = %+v, %v", changed, err)
	}
	if _, err := manager.RecordVerification(context.Background(), TargetCodexCLI, testCodexVersion); !errors.Is(err, ErrPreconditionChanged) {
		t.Fatalf("RecordVerification() on conflict error = %v", err)
	}
	if _, err := manager.RecordVerification(context.Background(), TargetClaudeCLI, testClaudeVersion); err != nil {
		t.Fatalf("RecordVerification(claude) error = %v", err)
	}
	restored, err := manager.Restore(context.Background(), TargetClaudeCLI)
	if err != nil || restored.State != StateNotConfigured || restored.VerificationLevel != VerificationL0 {
		t.Fatalf("Restore() = %+v, %v", restored, err)
	}
}

func TestManagerReadsSchemaOneManifestAsLevelOne(t *testing.T) {
	t.Parallel()
	manager, _, _ := newVerifiedFixture(t)
	manifestPath := manager.manifestPath(TargetClaudeCLI)
	configSHA := digest(mustReadFile(t, manager.configPath(TargetClaudeCLI)))
	legacy := `{"schema_version":1,"target_id":"claude_cli","profile_version":"` + testProfile + `","file_kind":"claude_settings_overlay","applied_sha256":"` + configSHA + `"}` + "\n"
	mustWriteFile(t, manifestPath, []byte(legacy), 0o600)
	status, err := manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || status.State != StateConfigured || status.VerificationLevel != VerificationL1 || status.ProfileVersion != testProfile {
		t.Fatalf("Status() with schema 1 manifest = %+v, %v", status, err)
	}
	recorded, err := manager.RecordVerification(context.Background(), TargetClaudeCLI, testClaudeVersion)
	if err != nil || recorded.VerificationLevel != VerificationL3 {
		t.Fatalf("RecordVerification() on schema 1 = %+v, %v", recorded, err)
	}
	upgraded := mustReadFile(t, manifestPath)
	if !strings.Contains(string(upgraded), `"schema_version":2`) {
		t.Fatalf("manifest not upgraded: %s", upgraded)
	}

	tampered := strings.Replace(string(upgraded), `"verification_level":"l3"`, `"verification_level":"l9"`, 1)
	mustWriteFile(t, manifestPath, []byte(tampered), 0o600)
	status, err = manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || status.State != StateConflict {
		t.Fatalf("Status() with tampered manifest = %+v, %v", status, err)
	}
	if _, err := os.Stat(manifestPath); err != nil {
		t.Fatalf("manifest missing: %v", err)
	}
}

func TestManagerRepairPlanRewritesConflictedManagedFile(t *testing.T) {
	t.Parallel()
	manager, _, installations := newVerifiedFixture(t)
	configPath := manager.configPath(TargetClaudeCLI)
	original := mustReadFile(t, configPath)
	mustWriteFile(t, configPath, []byte(`{"broken": true}`), 0o600)
	if status, err := manager.Status(context.Background(), TargetClaudeCLI); err != nil || status.State != StateConflict {
		t.Fatalf("Status() after tamper = %+v, %v", status, err)
	}
	installationID := installations[TargetClaudeCLI].InstallationID

	plan, err := manager.Plan(context.Background(), TargetClaudeCLI, installationID)
	if err != nil || plan.Action != ActionConflict || plan.PlanID != "" {
		t.Fatalf("enable Plan() on conflict = %+v, %v", plan, err)
	}
	if _, err := manager.PlanWithType(context.Background(), TargetClaudeCLI, installationID, "upgrade"); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("PlanWithType(bad type) error = %v", err)
	}
	repair, err := manager.PlanWithType(context.Background(), TargetClaudeCLI, installationID, PlanTypeRepair)
	if err != nil || repair.Action != ActionRepair || repair.PlanID == "" {
		t.Fatalf("repair Plan() = %+v, %v", repair, err)
	}
	status, err := manager.Execute(context.Background(), repair.PlanID)
	if err != nil || status.State != StateConfigured || status.VerificationLevel != VerificationL1 {
		t.Fatalf("repair Execute() = %+v, %v", status, err)
	}
	if repaired := mustReadFile(t, configPath); string(repaired) != string(original) {
		t.Fatalf("repaired content differs from rendered profile:\n%s", repaired)
	}
	if again, err := manager.PlanWithType(context.Background(), TargetClaudeCLI, installationID, PlanTypeRepair); err != nil || again.Action != ActionNone {
		t.Fatalf("repair Plan() after repair = %+v, %v", again, err)
	}
}

func TestManagerFailsClosedOnEnterpriseManagedPolicyConflict(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	helper := writeExecutable(t, filepath.Join(home, "helper"))
	claude := writeExecutable(t, filepath.Join(home, ".local", "share", "claude", "versions", testClaudeVersion))
	policyPath := filepath.Join(home, "managed-settings.json")
	installations := map[string]Installation{
		TargetClaudeCLI: {TargetID: TargetClaudeCLI, InstallationID: "claude-install", Executable: claude, Version: testClaudeVersion},
	}
	manager, err := NewManager(ManagerConfig{
		HomeDir: home, HelperExecutable: helper, ClaudeManagedPolicyPath: policyPath,
		Profiles: map[Environment]map[string]GatewayProfile{
			EnvironmentProd: {
				TargetCodexCLI:  {Version: testProfile, BaseURL: "https://api.airick.cn/v1"},
				TargetClaudeCLI: {Version: testProfile, BaseURL: "https://api.airick.cn"},
			},
		},
		SupportedVersions: map[string]string{TargetCodexCLI: testCodexVersion, TargetClaudeCLI: testClaudeVersion},
		ResolveInstallation: func(_ context.Context, targetID, installationID string) (Installation, error) {
			installation, ok := installations[targetID]
			if !ok || installation.InstallationID != installationID {
				return Installation{}, ErrInstallationChanged
			}
			return installation, nil
		},
		ResolveAuthorization: func(context.Context, string) (AuthorizationProfile, error) {
			return AuthorizationProfile{Environment: EnvironmentProd, ProfileVersion: testProfile}, nil
		},
		Probe: func(context.Context, Installation, string) error { return nil },
	})
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}

	// No policy file: normal enable.
	plan, err := manager.Plan(context.Background(), TargetClaudeCLI, "claude-install")
	if err != nil || plan.Action != ActionCreate {
		t.Fatalf("Plan() without policy = %+v, %v", plan, err)
	}
	if _, err := manager.Execute(context.Background(), plan.PlanID); err != nil {
		t.Fatalf("Execute() error = %v", err)
	}

	// A managed policy that only sets unrelated keys is not a conflict.
	mustWriteFile(t, policyPath, []byte(`{"permissions":{"allow":["Bash"]},"env":{"FOO":"1"}}`), 0o644)
	status, err := manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || status.PolicyConflict || status.State != StateConfigured {
		t.Fatalf("Status() with unrelated policy = %+v, %v", status, err)
	}

	// A policy pinning the gateway keys is a conflict: status flags it and
	// enable/repair/launch fail closed.
	mustWriteFile(t, policyPath, []byte(`{"env":{"ANTHROPIC_BASE_URL":"https://corp.example"}}`), 0o644)
	status, err = manager.Status(context.Background(), TargetClaudeCLI)
	if err != nil || !status.PolicyConflict || status.ErrorCode != "LCT-CLAUDE_CLI-CONFIG-POLICY_CONFLICT" {
		t.Fatalf("Status() with conflicting policy = %+v, %v", status, err)
	}
	if _, err := manager.Plan(context.Background(), TargetClaudeCLI, "claude-install"); !errors.Is(err, ErrPolicyConflict) {
		t.Fatalf("Plan() with conflicting policy error = %v", err)
	}
	if _, err := manager.PlanWithType(context.Background(), TargetClaudeCLI, "claude-install", PlanTypeRepair); !errors.Is(err, ErrPolicyConflict) {
		t.Fatalf("repair Plan() with conflicting policy error = %v", err)
	}
	if _, err := manager.ResolveLaunchConfiguration(context.Background(), TargetClaudeCLI, testProfile); !errors.Is(err, ErrPolicyConflict) {
		t.Fatalf("ResolveLaunchConfiguration() with conflicting policy error = %v", err)
	}
	mustWriteFile(t, policyPath, []byte(`{"apiKeyHelper":"/corp/helper"}`), 0o644)
	if status, _ := manager.Status(context.Background(), TargetClaudeCLI); !status.PolicyConflict {
		t.Fatalf("apiKeyHelper policy not detected: %+v", status)
	}
	// Codex has no managed policy file to check.
	if status, err := manager.Status(context.Background(), TargetCodexCLI); err != nil || status.PolicyConflict {
		t.Fatalf("Status(codex) = %+v, %v", status, err)
	}
}
