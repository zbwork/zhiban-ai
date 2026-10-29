package configuration

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// Contract §2.7.2 "模型选择" and schema 3: the model the tool writes back is
// not drift, the switch enables gateway model discovery, and Codex gets a
// compatible model catalog validated by every local Codex.

func TestGlobalModelChoiceInToolIsNotDriftAndReswitchKeepsIt(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("model = \"o3\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); err != nil {
		t.Fatal(err)
	}
	// Codex /model writes the choice back to the top-level model line.
	switched := string(mustReadFile(t, f.codexPath))
	picked := strings.Replace(switched, `model = "gpt-5.6-luna"`, "model = \"gpt-5.5\"\nmodel_reasoning_effort = \"high\"", 1)
	mustWriteFile(t, f.codexPath, []byte(picked), 0o600)
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalDrifted || status.GlobalVerificationLevel != VerificationL3 {
		t.Fatalf("Status() after /model = %+v", status)
	}
	plan, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal)
	if err != nil || plan.Action != ActionNone {
		t.Fatalf("re-switch plan after /model = %+v, %v", plan, err)
	}
	// Restore still returns the pre-switch model.
	f.restore(t, TargetCodexCLI)
	restored := string(mustReadFile(t, f.codexPath))
	if !strings.Contains(restored, `model = "o3"`) || strings.Contains(restored, "gpt-5.5") {
		t.Fatalf("restored config = %q", restored)
	}

	settingsPath := filepath.Join(f.claudeDir, "settings.json")
	mustWriteFile(t, settingsPath, []byte("{\"model\": \"opus\"}\n"), 0o600)
	f.switchTo(t, TargetClaudeCLI)
	var settings map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &settings); err != nil {
		t.Fatal(err)
	}
	env, _ := settings["env"].(map[string]any)
	if settings["model"] != "gpt-5.6-luna" || env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] != "1" {
		t.Fatalf("switched settings = %+v", settings)
	}
	settings["model"] = "claude-opus-5"
	mustWriteFile(t, settingsPath, []byte(mustJSON(t, settings)), 0o600)
	status, _ = f.manager.Status(context.Background(), TargetClaudeCLI)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Claude Status() after /model = %+v", status)
	}
	f.restore(t, TargetClaudeCLI)
	settings = nil
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &settings); err != nil {
		t.Fatal(err)
	}
	if settings["model"] != "opus" || settings["env"] != nil {
		t.Fatalf("restored settings = %+v", settings)
	}
}

func TestGlobalSchema2ManifestIgnoresModelAndOffersUpgrade(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	settingsPath := filepath.Join(f.claudeDir, "settings.json")
	f.switchTo(t, TargetClaudeCLI)
	// What a 2026-09-09 – 09-14 switch left behind: no discovery key, and a
	// schema 2 fingerprint that included the model.
	var settings map[string]any
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &settings); err != nil {
		t.Fatal(err)
	}
	delete(settings["env"].(map[string]any), "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY")
	old := []byte(mustJSON(t, settings))
	mustWriteFile(t, settingsPath, old, 0o600)
	legacy, err := claudeKeysFingerprint(old, claudeRegionKeysModel, nil)
	if err != nil {
		t.Fatal(err)
	}
	f.rewriteManifest(t, TargetClaudeCLI, func(item *globalManifest) {
		item.SchemaVersion = globalManifestSchemaModelRegion
		item.ManagedSHA256 = legacy
		item.AppliedSHA256 = digest(old)
	})

	settings["model"] = "claude-opus-5"
	mustWriteFile(t, settingsPath, []byte(mustJSON(t, settings)), 0o600)
	status, _ := f.manager.Status(context.Background(), TargetClaudeCLI)
	if status.GlobalDrifted || !status.GlobalUpgradeAvailable {
		t.Fatalf("Status() with schema 2 manifest = %+v", status)
	}
	// Editing a managed key is still drift under schema 2.
	settings["apiKeyHelper"] = "/tmp/other credential get --target claude_cli"
	tampered := []byte(mustJSON(t, settings))
	mustWriteFile(t, settingsPath, tampered, 0o600)
	if status, _ := f.manager.Status(context.Background(), TargetClaudeCLI); !status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() after helper edit = %+v", status)
	}
	settings["apiKeyHelper"] = mustClaudeHelper(t, old)
	mustWriteFile(t, settingsPath, []byte(mustJSON(t, settings)), 0o600)

	// The silent upgrade re-switches: discovery on, the user's model kept.
	plan, err := f.manager.PlanWithType(context.Background(), TargetClaudeCLI, "claude-install", PlanTypeSwitchGlobal)
	if err != nil || plan.Action != ActionSwitchGlobal {
		t.Fatalf("upgrade plan = %+v, %v", plan, err)
	}
	if _, err := f.manager.Execute(context.Background(), plan.PlanID); err != nil {
		t.Fatal(err)
	}
	settings = nil
	if err := json.Unmarshal(mustReadFile(t, settingsPath), &settings); err != nil {
		t.Fatal(err)
	}
	if settings["model"] != "claude-opus-5" || settings["env"].(map[string]any)["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] != "1" {
		t.Fatalf("upgraded settings = %+v", settings)
	}
	status, _ = f.manager.Status(context.Background(), TargetClaudeCLI)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable || f.manifest(t, TargetClaudeCLI).SchemaVersion != globalManifestSchema {
		t.Fatalf("Status() after upgrade = %+v", status)
	}
}

func TestGlobalSchema2VerificationUpgradesTheCodexRegion(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.switchTo(t, TargetCodexCLI)
	content := mustReadFile(t, f.codexPath)
	f.rewriteManifest(t, TargetCodexCLI, func(item *globalManifest) {
		item.SchemaVersion = globalManifestSchemaModelRegion
		item.ManagedSHA256 = codexRegionFingerprint(content, true, nil)
	})
	picked := strings.Replace(string(content), `model = "gpt-5.6-luna"`, `model = "gpt-6-astra"`, 1)
	mustWriteFile(t, f.codexPath, []byte(picked), 0o600)
	if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); status.GlobalDrifted {
		t.Fatalf("Status() with schema 2 manifest after /model = %+v", status)
	}
	recorded, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion)
	if err != nil || recorded.VerificationLevel != VerificationL3 {
		t.Fatalf("RecordGlobalVerification() = %+v, %v", recorded, err)
	}
	item := f.manifest(t, TargetCodexCLI)
	if item.SchemaVersion != globalManifestSchema || item.ManagedSHA256 != codexManagedFingerprint([]byte(picked)) {
		t.Fatalf("manifest after verification = %+v", item)
	}
	mustWriteFile(t, f.codexPath, []byte(strings.Replace(picked, `model = "gpt-6-astra"`, `model = "gpt-5.5"`, 1)), 0o600)
	if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); status.GlobalDrifted || status.GlobalVerificationLevel != VerificationL3 {
		t.Fatalf("Status() after schema 3 upgrade and /model = %+v", status)
	}
}

func TestClaudeDesktopEntryEnablesModelDiscovery(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.withDesktop(t)
	f.switchTo(t, TargetClaudeDesktop)
	entryPath := f.manager.claudeDesktopConfigPath()
	var entry map[string]any
	if err := json.Unmarshal(mustReadFile(t, entryPath), &entry); err != nil {
		t.Fatal(err)
	}
	if entry["modelDiscoveryEnabled"] != true {
		t.Fatalf("entry = %+v", entry)
	}
	status, _ := f.manager.Status(context.Background(), TargetClaudeDesktop)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() = %+v", status)
	}
	// An entry written before discovery, with a schema 2 manifest.
	delete(entry, "modelDiscoveryEnabled")
	old := []byte(mustJSON(t, entry))
	mustWriteFile(t, entryPath, old, 0o600)
	legacy, err := claudeDesktopKeysFingerprint(old, claudeDesktopManagedKeysV2)
	if err != nil {
		t.Fatal(err)
	}
	f.rewriteManifest(t, TargetClaudeDesktop, func(item *globalManifest) {
		item.SchemaVersion = globalManifestSchemaModelRegion
		item.ManagedSHA256 = legacy
	})
	status, _ = f.manager.Status(context.Background(), TargetClaudeDesktop)
	if status.GlobalDrifted || !status.GlobalUpgradeAvailable {
		t.Fatalf("Status() for pre-discovery entry = %+v", status)
	}
}

// An entry written before 2026-09-17 has no deploymentDisplayName, so the
// app's account area shows the machine name. That is an upgrade (the App
// rewrites the entry in the background), never drift: the key is outside the
// managed region and nothing the user did.
func TestClaudeDesktopEntryWithoutDeploymentNameIsUpgradeAvailable(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.withDesktop(t)
	f.switchTo(t, TargetClaudeDesktop)
	entryPath := f.manager.claudeDesktopConfigPath()
	var entry map[string]any
	if err := json.Unmarshal(mustReadFile(t, entryPath), &entry); err != nil {
		t.Fatal(err)
	}
	if entry["deploymentDisplayName"] != zhibanClaudeDesktopDeploymentName {
		t.Fatalf("entry = %+v", entry)
	}
	delete(entry, "deploymentDisplayName")
	delete(entry, "deploymentDisplaySubtitle")
	mustWriteFile(t, entryPath, []byte(mustJSON(t, entry)), 0o600)
	status, _ := f.manager.Status(context.Background(), TargetClaudeDesktop)
	if status.GlobalDrifted || !status.GlobalUpgradeAvailable {
		t.Fatalf("Status() for entry without deployment name = %+v", status)
	}
	// Re-switching (what the App does for upgrade_available) writes the keys back.
	f.switchTo(t, TargetClaudeDesktop)
	if err := json.Unmarshal(mustReadFile(t, entryPath), &entry); err != nil {
		t.Fatal(err)
	}
	status, _ = f.manager.Status(context.Background(), TargetClaudeDesktop)
	if entry["deploymentDisplayName"] != zhibanClaudeDesktopDeploymentName || status.GlobalUpgradeAvailable || status.GlobalDrifted {
		t.Fatalf("after re-switch entry = %+v status = %+v", entry, status)
	}
}

func TestClaudeDesktopEntryPinnedToOneModelIsUpgraded(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.withDesktop(t)
	f.switchTo(t, TargetClaudeDesktop)
	entryPath := f.manager.claudeDesktopConfigPath()
	var entry map[string]any
	if err := json.Unmarshal(mustReadFile(t, entryPath), &entry); err != nil {
		t.Fatal(err)
	}
	// Written 2026-09-14 – 09-15: discovery on, but inferenceModels pinned the
	// picker to the profile's model, so discovery never reached the menu.
	entry["inferenceModels"] = []any{map[string]any{"name": testDesktopModel, "labelOverride": "知办 AI · " + testDesktopModel}}
	pinned := []byte(mustJSON(t, entry))
	mustWriteFile(t, entryPath, pinned, 0o600)
	fingerprint, err := claudeDesktopFingerprint(pinned)
	if err != nil {
		t.Fatal(err)
	}
	f.rewriteManifest(t, TargetClaudeDesktop, func(item *globalManifest) {
		item.ManagedSHA256 = fingerprint
		item.AppliedSHA256 = digest(pinned)
	})
	status, _ := f.manager.Status(context.Background(), TargetClaudeDesktop)
	if status.GlobalDrifted || !status.GlobalUpgradeAvailable {
		t.Fatalf("Status() for pinned entry = %+v", status)
	}

	// The silent upgrade re-switches and drops the pin.
	plan, err := f.manager.PlanWithType(context.Background(), TargetClaudeDesktop, "claude-desktop-install", PlanTypeSwitchGlobal)
	if err != nil || plan.Action != ActionSwitchGlobal {
		t.Fatalf("upgrade plan = %+v, %v", plan, err)
	}
	if _, err := f.manager.Execute(context.Background(), plan.PlanID); err != nil {
		t.Fatal(err)
	}
	entry = nil
	if err := json.Unmarshal(mustReadFile(t, entryPath), &entry); err != nil {
		t.Fatal(err)
	}
	if _, stillPinned := entry["inferenceModels"]; stillPinned || entry["modelDiscoveryEnabled"] != true {
		t.Fatalf("entry after upgrade = %+v", entry)
	}
	status, _ = f.manager.Status(context.Background(), TargetClaudeDesktop)
	if status.CurrentService != ServiceZhiban || status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() after upgrade = %+v", status)
	}
}

func TestMergeCodexCatalogBuildsCompatibleSuperset(t *testing.T) {
	t.Parallel()
	content, err := mergeCodexCatalog([]versionedCodexCatalog{
		{Version: "0.144.1", Models: oldBundledCatalog()},
		{Version: "0.154.0-alpha.6.2", Models: newBundledCatalog()},
	}, []string{"gpt-5.6-luna", "gpt-6-astra", "gpt-5.5", "codex-auto-review", "qwen3.8-max"})
	if err != nil {
		t.Fatal(err)
	}
	models, err := decodeCodexCatalog(content)
	if err != nil {
		t.Fatal(err)
	}
	bySlug := map[string]map[string]any{}
	for _, model := range models {
		bySlug[model["slug"].(string)] = model
	}
	if _, ok := bySlug["qwen3.8-max"]; ok || len(bySlug) != 5 {
		t.Fatalf("slugs = %v", keysOf(bySlug))
	}
	if bySlug["gpt-5.2"]["visibility"] != "hide" || bySlug["codex-auto-review"]["visibility"] != "hide" ||
		bySlug["gpt-6-astra"]["visibility"] != "list" || bySlug["gpt-5.6-luna"]["visibility"] != "list" {
		t.Fatalf("visibility = %+v", bySlug)
	}
	luna := bySlug["gpt-5.6-luna"]
	// Newest metadata wins; the field only the older version still emits is kept.
	if luna["display_name"] != "GPT-5.6 Luna (new)" || luna["supports_reasoning_summaries"] != false || luna["base_instructions"] != "old luna prompt" {
		t.Fatalf("luna = %+v", luna)
	}
	astra := bySlug["gpt-6-astra"]
	if astra["supports_reasoning_summaries"] != true || astra["supports_parallel_tool_calls"] != true {
		t.Fatalf("astra = %+v", astra)
	}
	if _, err := mergeCodexCatalog([]versionedCodexCatalog{{Version: "0.153.4", Models: newBundledCatalog()}}, []string{"qwen3.8-max"}); err == nil {
		t.Fatal("mergeCodexCatalog() without a served model should be disabled")
	}
	if compareCodexVersions("0.154.0-alpha.6.2", "0.154.0") >= 0 || compareCodexVersions("0.154.0-alpha.6.2", "0.153.4") <= 0 {
		t.Fatal("compareCodexVersions() ordering")
	}
}

func TestGlobalCodexSwitchWritesValidatedCatalogAndRestoreRemovesIt(t *testing.T) {
	t.Parallel()
	f := newCatalogFixture(t)
	mustWriteFile(t, f.codexPath, []byte("model = \"o3\"\nmodel_catalog_json = \"/Users/me/my-catalog.json\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	config := string(mustReadFile(t, f.codexPath))
	catalogPath := f.manager.codexCatalogPath()
	if codexCatalogLineValue([]byte(config)) != catalogPath || !strings.Contains(config, "model = \"gpt-5.6-luna\"\nmodel_catalog_json = ") {
		t.Fatalf("switched config = %q", config)
	}
	models, err := decodeCodexCatalog(mustReadFile(t, catalogPath))
	if err != nil || len(models) != 5 {
		t.Fatalf("catalog = %v, %v", models, err)
	}
	item := f.manifest(t, TargetCodexCLI)
	if item.ModelCatalog == nil || !item.ModelCatalog.Enabled || item.ModelCatalog.SHA256 != digest(mustReadFile(t, catalogPath)) ||
		len(item.ModelCatalog.Validated) != 2 || item.ModelCatalog.Validated[0].Version == "" {
		t.Fatalf("manifest catalog = %+v", item.ModelCatalog)
	}
	for _, binary := range f.binaries {
		if binary.parsed == 0 {
			t.Fatalf("catalog not validated by %s", binary.version)
		}
	}
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() = %+v", status)
	}
	// Re-planning with nothing changed is a no-op.
	if plan, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal); err != nil || plan.Action != ActionNone {
		t.Fatalf("re-switch plan = %+v, %v", plan, err)
	}

	f.restore(t, TargetCodexCLI)
	restored := string(mustReadFile(t, f.codexPath))
	if restored != "model = \"o3\"\nmodel_catalog_json = \"/Users/me/my-catalog.json\"\n" {
		t.Fatalf("restored config = %q", restored)
	}
	if _, err := os.Stat(catalogPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("catalog file after restore: %v", err)
	}
}

func TestGlobalCodexCatalogDisabledWhenAnyCodexRejectsIt(t *testing.T) {
	t.Parallel()
	f := newCatalogFixture(t)
	// An older core that requires a field no local Codex emits.
	f.binaries[f.oldPath].requires = append(f.binaries[f.oldPath].requires, "legacy_only_field")
	f.switchTo(t, TargetCodexCLI)
	if value := codexCatalogLineValue(mustReadFile(t, f.codexPath)); value != "" {
		t.Fatalf("catalog line written although validation failed: %q", value)
	}
	if _, err := os.Stat(f.manager.codexCatalogPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("catalog file exists: %v", err)
	}
	item := f.manifest(t, TargetCodexCLI)
	if item.ModelCatalog == nil || item.ModelCatalog.Enabled || len(item.ModelCatalog.Validated) != 2 {
		t.Fatalf("manifest catalog = %+v", item.ModelCatalog)
	}
	if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); status.GlobalUpgradeAvailable {
		t.Fatalf("a recorded disabled decision must not loop the upgrade: %+v", status)
	}

	g := newCatalogFixture(t)
	g.relayErr = errors.New("relay down")
	g.switchTo(t, TargetCodexCLI)
	if value := codexCatalogLineValue(mustReadFile(t, g.codexPath)); value != "" {
		t.Fatalf("catalog line without a model list: %q", value)
	}

	h := newCatalogFixture(t)
	// A desktop application whose core cannot be located (Windows) cannot be validated.
	h.executablePaths = append(h.executablePaths, filepath.Join(h.home, "AppData", "OpenAI.Codex"))
	h.switchTo(t, TargetCodexCLI)
	if value := codexCatalogLineValue(mustReadFile(t, h.codexPath)); value != "" {
		t.Fatalf("catalog line with an unlocatable desktop core: %q", value)
	}
}

func TestGlobalCodexCatalogFollowsExecutablesAndRelay(t *testing.T) {
	t.Parallel()
	f := newCatalogFixture(t)
	f.switchTo(t, TargetCodexCLI)
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); err != nil {
		t.Fatal(err)
	}
	catalogPath := f.manager.codexCatalogPath()

	// A Codex desktop application appears: the decision no longer covers it.
	bundle := filepath.Join(f.home, "Applications", "Codex.app")
	core := writeExecutable(t, filepath.Join(bundle, "Contents", "Resources", "codex"))
	f.binaries[core] = &fakeCodexBinary{version: "0.142.5", bundled: oldBundledCatalog(), requires: []string{"supports_reasoning_summaries", "supports_parallel_tool_calls"}}
	f.executablePaths = append(f.executablePaths, bundle)
	f.clock = f.clock.Add(2 * codexExecutablesCacheTTL)
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if !status.GlobalUpgradeAvailable || status.GlobalDrifted {
		t.Fatalf("Status() after a new Codex = %+v", status)
	}

	// verify.execute refreshes: the relay group dropped gpt-5.5.
	f.relayIDs = []string{"gpt-5.6-luna", "gpt-6-astra"}
	if err := f.manager.RefreshGlobalModelCatalog(context.Background(), TargetCodexCLI); err != nil {
		t.Fatal(err)
	}
	models, err := decodeCodexCatalog(mustReadFile(t, catalogPath))
	if err != nil {
		t.Fatal(err)
	}
	for _, model := range models {
		if model["slug"] == "gpt-5.5" && model["visibility"] != "hide" {
			t.Fatalf("gpt-5.5 still listed: %+v", model)
		}
	}
	status, _ = f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalUpgradeAvailable || status.GlobalDrifted || status.GlobalVerificationLevel != VerificationL3 {
		t.Fatalf("Status() after refresh = %+v", status)
	}
	if item := f.manifest(t, TargetCodexCLI); len(item.ModelCatalog.Validated) != 3 {
		t.Fatalf("validated = %+v", item.ModelCatalog.Validated)
	}

	// The new core rejects the catalog: the line and the file go, nothing drifts.
	f.binaries[core].requires = append(f.binaries[core].requires, "legacy_only_field")
	f.relayIDs = []string{"gpt-5.6-luna"}
	if err := f.manager.RefreshGlobalModelCatalog(context.Background(), TargetCodexCLI); err != nil {
		t.Fatal(err)
	}
	if value := codexCatalogLineValue(mustReadFile(t, f.codexPath)); value != "" {
		t.Fatalf("catalog line kept after validation failure: %q", value)
	}
	if _, err := os.Stat(catalogPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("catalog file kept: %v", err)
	}
	status, _ = f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalDrifted || status.GlobalUpgradeAvailable || status.GlobalVerificationLevel != VerificationL3 {
		t.Fatalf("Status() after disabling = %+v", status)
	}
}

func TestGlobalCodexSwitchIsNotHeldUpByASlowGateway(t *testing.T) {
	t.Parallel()
	f := newCatalogFixture(t)
	f.manager.catalogPlanBudget = 200 * time.Millisecond
	f.manager.gatewayModelIDs = func(ctx context.Context, _, _ string) ([]string, error) {
		<-ctx.Done() // the exchange or the relay hangs
		return nil, ctx.Err()
	}
	started := time.Now()
	f.switchTo(t, TargetCodexCLI)
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("switch took %s", elapsed)
	}
	if value := codexCatalogLineValue(mustReadFile(t, f.codexPath)); value != "" {
		t.Fatalf("catalog line without a model list: %q", value)
	}
	if item := f.manifest(t, TargetCodexCLI); item.ModelCatalog == nil || item.ModelCatalog.Enabled || len(item.ModelCatalog.Validated) != 2 {
		t.Fatalf("manifest catalog = %+v", item.ModelCatalog)
	}
	// verify.execute decides again with its own time.
	f.manager.gatewayModelIDs = func(context.Context, string, string) ([]string, error) { return f.relayIDs, nil }
	if err := f.manager.RefreshGlobalModelCatalog(context.Background(), TargetCodexCLI); err != nil {
		t.Fatal(err)
	}
	if value := codexCatalogLineValue(mustReadFile(t, f.codexPath)); value != f.manager.codexCatalogPath() {
		t.Fatalf("catalog line after refresh = %q", value)
	}
}

// The switch leaves analytics alone: writing analytics.enabled = false stops
// the desktop app's Statsig client, which costs the user Computer Use and
// Browser Use (contract §2.7.2 "不关闭 Codex 分析上报").
func TestGlobalCodexSwitchNeverWritesAnalyticsAndKeepsTheUserLine(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	mustWriteFile(t, f.codexPath, []byte("model = \"o3\"\n"), 0o600)
	f.switchTo(t, TargetCodexCLI)
	switched := string(mustReadFile(t, f.codexPath))
	if codexAnalyticsLineValue([]byte(switched)) != "" {
		t.Fatalf("switch wrote an analytics line: %q", switched)
	}
	if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() after switch = %+v", status)
	}

	// A line the user set themselves survives the switch and the restore.
	g := newGlobalFixture(t)
	mustWriteFile(t, g.codexPath, []byte("analytics.enabled = false\nmodel = \"o3\"\n"), 0o600)
	g.switchTo(t, TargetCodexCLI)
	switched = string(mustReadFile(t, g.codexPath))
	if codexAnalyticsLineValue([]byte(switched)) != codexAnalyticsOffLine {
		t.Fatalf("the user's analytics line did not survive the switch: %q", switched)
	}
	// Theirs, so it is not something a silent upgrade should strip.
	if status, _ := g.manager.Status(context.Background(), TargetCodexCLI); status.GlobalUpgradeAvailable || status.GlobalDrifted {
		t.Fatalf("Status() with the user's analytics line = %+v", status)
	}
	g.restore(t, TargetCodexCLI)
	if restored := string(mustReadFile(t, g.codexPath)); restored != "analytics.enabled = false\nmodel = \"o3\"\n" {
		t.Fatalf("restored config = %q", restored)
	}
}

// A machine switched between 2026-09-15 and 2026-09-21 still carries the line
// the old switch wrote; the silent upgrade has to take it back out.
func TestGlobalCodexStaleAnalyticsOffLineIsRemovedBySilentUpgrade(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.switchTo(t, TargetCodexCLI)
	old := strings.Replace(string(mustReadFile(t, f.codexPath)), `model = "gpt-5.6-luna"`,
		"model = \"gpt-5.5\"\n"+codexAnalyticsOffLine, 1)
	mustWriteFile(t, f.codexPath, []byte(old), 0o600)
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalDrifted || !status.GlobalUpgradeAvailable {
		t.Fatalf("Status() with the stale analytics line = %+v", status)
	}
	plan, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal)
	if err != nil || plan.Action != ActionSwitchGlobal {
		t.Fatalf("upgrade plan = %+v, %v", plan, err)
	}
	if _, err := f.manager.Execute(context.Background(), plan.PlanID); err != nil {
		t.Fatal(err)
	}
	upgraded := string(mustReadFile(t, f.codexPath))
	if codexAnalyticsLineValue([]byte(upgraded)) != "" || !strings.Contains(upgraded, `model = "gpt-5.5"`) {
		t.Fatalf("upgraded config = %q", upgraded)
	}
	if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); status.GlobalUpgradeAvailable || status.GlobalDrifted {
		t.Fatalf("Status() after upgrade = %+v", status)
	}
}

func TestGlobalCodexSwitchWritesImageGenerationHeaderInProviderTable(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	original := "model = \"o3\"\n\n[mcp_servers.fs]\ncommand = \"npx\"\n"
	mustWriteFile(t, f.codexPath, []byte(original), 0o600)
	f.switchTo(t, TargetCodexCLI)
	switched := string(mustReadFile(t, f.codexPath))
	provider := "[model_providers." + CodexGlobalProviderID + "]"
	start, auth := strings.Index(switched, provider), strings.Index(switched, provider[:len(provider)-1]+".auth]")
	header := strings.Index(switched, codexImageGenerationHeaderLine)
	if start < 0 || auth < 0 || header < start || header > auth || strings.Count(switched, "x-openai-actor-authorization") != 1 {
		t.Fatalf("header must sit once in the provider table, before .auth:\n%s", switched)
	}
	if strings.Count(switched, `"Accept-Language" = "zh-CN"`) != 1 {
		t.Fatalf("managed provider must carry the Chinese language header once:\n%s", switched)
	}
	if codexImageGenerationHeaderMissing([]byte(switched)) {
		t.Fatal("codexImageGenerationHeaderMissing() = true right after the switch")
	}
	if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); status.GlobalDrifted || status.GlobalUpgradeAvailable {
		t.Fatalf("Status() after switch = %+v", status)
	}
	// The header is part of the Zhiban table: removing it is drift.
	mustWriteFile(t, f.codexPath, []byte(strings.Replace(switched, codexImageGenerationHeaderLine+"\n", "", 1)), 0o600)
	if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); !status.GlobalDrifted {
		t.Fatalf("Status() without the header = %+v", status)
	}
	// Restore drops it with the table, keeping the user's own tables.
	mustWriteFile(t, f.codexPath, []byte(switched+"\n[projects.\"/a\"]\ntrust_level = \"trusted\"\n"), 0o600)
	f.restore(t, TargetCodexCLI)
	restored := string(mustReadFile(t, f.codexPath))
	if strings.Contains(restored, "x-openai-actor-authorization") || !strings.Contains(restored, "[mcp_servers.fs]") || !strings.Contains(restored, `[projects."/a"]`) {
		t.Fatalf("restored config = %q", restored)
	}
	// A config without the Zhiban table never reports the header missing.
	if codexImageGenerationHeaderMissing([]byte(original)) {
		t.Fatal("codexImageGenerationHeaderMissing() = true without a Zhiban table")
	}
}

func TestGlobalCodexMissingImageGenerationHeaderIsAddedBySilentUpgrade(t *testing.T) {
	t.Parallel()
	for name, legacyHeaders := range map[string]string{
		"no headers": "",
		"actor only": "http_headers = { \"x-openai-actor-authorization\" = \"zhiban-ai\" }\n",
	} {
		t.Run(name, func(t *testing.T) {
			f := newGlobalFixture(t)
			f.switchTo(t, TargetCodexCLI)
			// A config switched before the header existed, with the user's model choice.
			switched := strings.Replace(string(mustReadFile(t, f.codexPath)), codexImageGenerationHeaderLine+"\n", legacyHeaders, 1)
			old := strings.Replace(switched, `model = "gpt-5.6-luna"`, `model = "gpt-5.5"`, 1)
			mustWriteFile(t, f.codexPath, []byte(old), 0o600)
			// Its manifest recorded the region the older Bridge wrote.
			item := f.manifest(t, TargetCodexCLI)
			item.ManagedSHA256 = codexManagedFingerprint([]byte(old))
			item.AppliedSHA256 = digest([]byte(old))
			encoded, err := json.Marshal(item)
			if err != nil {
				t.Fatal(err)
			}
			mustWriteFile(t, f.manager.globalManifestPath(TargetCodexCLI), encoded, 0o600)
			status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
			if status.GlobalDrifted || !status.GlobalUpgradeAvailable {
				t.Fatalf("Status() without the header = %+v", status)
			}
			plan, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal)
			if err != nil || plan.Action != ActionSwitchGlobal {
				t.Fatalf("upgrade plan = %+v, %v", plan, err)
			}
			if _, err := f.manager.Execute(context.Background(), plan.PlanID); err != nil {
				t.Fatal(err)
			}
			upgraded := string(mustReadFile(t, f.codexPath))
			if codexImageGenerationHeaderMissing([]byte(upgraded)) || !strings.Contains(upgraded, `model = "gpt-5.5"`) {
				t.Fatalf("upgraded config = %q", upgraded)
			}
			if status, _ := f.manager.Status(context.Background(), TargetCodexCLI); status.GlobalUpgradeAvailable || status.GlobalDrifted {
				t.Fatalf("Status() after upgrade = %+v", status)
			}
		})
	}
}

func TestWithCodexCatalogLinePlacement(t *testing.T) {
	t.Parallel()
	content := []byte("model_provider = \"zhiban_ai_managed\"\nmodel = \"gpt-5.5\"\npersonality = \"x\"\n\n[projects.\"/a\"]\ntrust_level = \"trusted\"\n")
	with := string(withCodexCatalogLine(content, "/h/.codex/zhiban-ai-model-catalog.json"))
	if !strings.HasPrefix(with, "model_provider = \"zhiban_ai_managed\"\nmodel = \"gpt-5.5\"\nmodel_catalog_json = \"/h/.codex/zhiban-ai-model-catalog.json\"\npersonality") {
		t.Fatalf("with line = %q", with)
	}
	if without := string(withCodexCatalogLine([]byte(with), "")); without != string(content) {
		t.Fatalf("without line = %q", without)
	}
}

// --- fixtures

type fakeCodexBinary struct {
	version  string
	bundled  []map[string]any
	requires []string
	parsed   int
}

type catalogFixture struct {
	*globalFixture
	binaries        map[string]*fakeCodexBinary
	executablePaths []string
	relayIDs        []string
	relayErr        error
	oldPath         string
}

func newCatalogFixture(t *testing.T) *catalogFixture {
	t.Helper()
	g := newGlobalFixture(t)
	f := &catalogFixture{globalFixture: g, binaries: map[string]*fakeCodexBinary{}}
	cli := g.installs[TargetCodexCLI].Executable
	f.oldPath = writeExecutable(t, filepath.Join(g.home, ".nvm", "versions", "node", "v24", "bin", "codex"))
	f.binaries[cli] = &fakeCodexBinary{version: "0.153.4", bundled: newBundledCatalog()}
	f.binaries[f.oldPath] = &fakeCodexBinary{version: "0.144.1", bundled: oldBundledCatalog(), requires: []string{"supports_reasoning_summaries", "supports_parallel_tool_calls"}}
	f.executablePaths = []string{cli, f.oldPath}
	f.relayIDs = []string{"gpt-5.6-luna", "gpt-6-astra", "gpt-5.5", "codex-auto-review", "qwen3.8-max"}
	m := g.manager
	m.codexExecutables = func(context.Context) ([]string, error) {
		return append([]string(nil), f.executablePaths...), nil
	}
	m.gatewayModelIDs = func(_ context.Context, targetID, baseURL string) ([]string, error) {
		if targetID != TargetCodexCLI || baseURL != "https://api.airick.cn/v1" {
			return nil, errors.New("unexpected gateway request")
		}
		return f.relayIDs, f.relayErr
	}
	m.codexCommand = f.run
	return f
}

func (f *catalogFixture) run(_ context.Context, executable string, arguments []string, codexHome string) ([]byte, error) {
	binary, ok := f.binaries[executable]
	if !ok || codexHome == "" || codexHome == f.manager.codexHome {
		return nil, errors.New("unexpected codex invocation")
	}
	switch strings.Join(arguments, " ") {
	case "--version":
		return []byte("codex-cli " + binary.version + "\n"), nil
	case "debug models --bundled":
		return json.Marshal(map[string]any{"models": binary.bundled})
	case "debug models":
		config, err := os.ReadFile(filepath.Join(codexHome, "config.toml"))
		if err != nil {
			return nil, err
		}
		content, err := os.ReadFile(codexCatalogLineValue(config))
		if err != nil {
			return nil, err
		}
		models, err := decodeCodexCatalog(content)
		if err != nil {
			return nil, err
		}
		for _, model := range models {
			for _, field := range binary.requires {
				if _, ok := model[field]; !ok {
					return nil, errors.New("missing field " + field)
				}
			}
		}
		binary.parsed++
		return content, nil
	}
	return nil, errors.New("unexpected arguments")
}

func (f *globalFixture) manifest(t *testing.T, targetID string) globalManifest {
	t.Helper()
	item, ok := decodeGlobalManifest(targetID, mustReadFile(t, f.manager.globalManifestPath(targetID)))
	if !ok {
		t.Fatalf("manifest for %s does not decode", targetID)
	}
	return item
}

func (f *globalFixture) rewriteManifest(t *testing.T, targetID string, change func(*globalManifest)) {
	t.Helper()
	item := f.manifest(t, targetID)
	change(&item)
	encoded, err := json.Marshal(item)
	if err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, f.manager.globalManifestPath(targetID), append(encoded, '\n'), 0o600)
}

func mustClaudeHelper(t *testing.T, content []byte) string {
	t.Helper()
	var settings map[string]any
	if err := json.Unmarshal(content, &settings); err != nil {
		t.Fatal(err)
	}
	return settings["apiKeyHelper"].(string)
}

func bundledModel(slug, visibility string, extra map[string]any) map[string]any {
	model := map[string]any{
		"slug": slug, "display_name": slug, "visibility": visibility, "supported_in_api": true, "priority": 1,
		"supported_reasoning_levels": []any{map[string]any{"effort": "medium", "description": "m"}},
	}
	for key, value := range extra {
		model[key] = value
	}
	return model
}

func newBundledCatalog() []map[string]any {
	return []map[string]any{
		bundledModel("gpt-6-astra", "list", nil),
		bundledModel("gpt-5.6-luna", "list", map[string]any{"display_name": "GPT-5.6 Luna (new)", "supported_reasoning_levels": []any{}}),
		bundledModel("gpt-5.5", "list", nil),
		bundledModel("gpt-5.2", "list", nil),
		bundledModel("codex-auto-review", "hide", nil),
	}
}

func oldBundledCatalog() []map[string]any {
	return []map[string]any{
		bundledModel("gpt-5.6-luna", "list", map[string]any{"display_name": "GPT-5.6 Luna (old)", "supports_reasoning_summaries": false, "supports_parallel_tool_calls": true, "base_instructions": "old luna prompt"}),
		bundledModel("gpt-5.2", "list", map[string]any{"supports_reasoning_summaries": true, "supports_parallel_tool_calls": true}),
	}
}

func keysOf(values map[string]map[string]any) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// Windows 12015 真机:配置被改写过、manifest 没跟上(写入中断),卡片显示「配置
// 被改动」。此时文件内容恰好等于本 profile 要写的内容,计划一旦回 action=none
// 就永远刷不新 manifest,「一键修复」无效、verify 一直 VERIFY-NOT_CONFIGURED。
func TestDriftedRecordIsRewrittenEvenWhenTheFileAlreadyMatches(t *testing.T) {
	t.Parallel()
	f := newGlobalFixture(t)
	f.switchTo(t, TargetCodexCLI)
	if _, err := f.manager.RecordGlobalVerification(context.Background(), TargetCodexCLI, testCodexVersion); err != nil {
		t.Fatal(err)
	}
	// The record no longer describes the file (an interrupted write left the
	// previous fingerprint behind); the file itself is what the switch writes.
	f.rewriteManifest(t, TargetCodexCLI, func(item *globalManifest) {
		item.ManagedSHA256 = digest([]byte("stale"))
		item.VerifiedManagedSHA256 = item.ManagedSHA256
	})
	status, _ := f.manager.Status(context.Background(), TargetCodexCLI)
	if !status.GlobalDrifted {
		t.Fatalf("Status() with a stale record = %+v", status)
	}

	plan, err := f.manager.PlanWithType(context.Background(), TargetCodexCLI, "codex-install", PlanTypeSwitchGlobal)
	if err != nil || plan.Action != ActionSwitchGlobal {
		t.Fatalf("repair plan = %+v, %v (must not be action=none)", plan, err)
	}
	if _, err := f.manager.Execute(context.Background(), plan.PlanID); err != nil {
		t.Fatal(err)
	}
	status, _ = f.manager.Status(context.Background(), TargetCodexCLI)
	if status.GlobalDrifted || status.CurrentService != ServiceZhiban || !status.GlobalSwitched {
		t.Fatalf("Status() after repair = %+v", status)
	}
}
