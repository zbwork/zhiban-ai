package configuration

// Codex model catalog (contract §2.7.2 "模型选择").
//
// Codex lists models from its own catalog format only: a relay's OpenAI-style
// /models fails to decode and Codex falls back to the catalog bundled with each
// binary, which does not match the relay group. model_catalog_json replaces
// that catalog, but a file Codex cannot parse stops it from starting, and the
// CLI and the desktop application's core that share ~/.codex/config.toml are
// routinely different versions: a catalog exported by 0.153 is rejected by
// 0.144 and older ("missing field supports_reasoning_summaries", 2026-09-14).
//
// So the Bridge writes a compatible superset instead of any one version's
// catalog: the entries of the newest local Codex, with the fields older
// versions still require filled in, models the relay does not serve hidden.
// It is enabled only when every Codex executable on the machine parses it,
// and the executables it was validated against are recorded so a newly
// installed or updated Codex triggers a re-validation.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/shellenv"
)

const (
	codexCatalogFileName       = "zhiban-ai-model-catalog.json"
	codexCatalogCommandTimeout = 20 * time.Second
	codexCatalogMaxOutput      = 32 << 20
	codexExecutablesCacheTTL   = time.Minute
	codexCatalogMaxExecutables = 16
	// codexCatalogPlanBudget keeps config.plan well inside the App's 15 s RPC timeout.
	codexCatalogPlanBudget = 8 * time.Second
	// maxCodexCatalogBytes bounds the catalog file (secure_file.go); Codex
	// 0.153's own catalog is about 515 KB.
	maxCodexCatalogBytes = 8 << 20
)

// CodexExecutablesFunc lists the real paths of every trusted Codex executable
// that reads ~/.codex/config.toml: CLI installations and desktop application
// bundles (the core inside a bundle is located here).
type CodexExecutablesFunc func(context.Context) ([]string, error)

// GatewayModelIDsFunc returns the model ids the target's member key may use on
// the gateway at baseURL.
type GatewayModelIDsFunc func(ctx context.Context, targetID, baseURL string) ([]string, error)

// CodexCommandFunc runs a Codex executable with CODEX_HOME set to codexHome
// and returns its standard output (tests replace it).
type CodexCommandFunc func(ctx context.Context, executable string, arguments []string, codexHome string) ([]byte, error)

// codexCatalogRecord is the last catalog decision, kept in the global manifest.
type codexCatalogRecord struct {
	Enabled   bool                     `json:"enabled"`
	SHA256    string                   `json:"sha256,omitempty"`
	Validated []codexCatalogExecutable `json:"validated"`
}

// codexCatalogExecutable identifies one executable the decision covered.
// Path is empty for a desktop application whose core could not be located.
type codexCatalogExecutable struct {
	Path    string `json:"path"`
	Version string `json:"version,omitempty"`
	Size    int64  `json:"size"`
	ModTime int64  `json:"mod_time"`
}

// codexCatalogResult is a freshly built catalog; Content is nil when disabled.
type codexCatalogResult struct {
	Content []byte
	Record  codexCatalogRecord
}

var errCodexCatalogDisabled = errors.New("configuration: codex model catalog disabled")

func (m *Manager) codexCatalogPath() string {
	return filepath.Join(m.codexHome, codexCatalogFileName)
}

// codexCatalogEnabledFeature reports whether the Bridge was wired for catalogs.
func (m *Manager) codexCatalogEnabledFeature() bool {
	return m.codexExecutables != nil && m.gatewayModelIDs != nil
}

// localCodexExecutables resolves the executables without running them. A
// desktop bundle whose core is missing yields an entry with an empty path.
func (m *Manager) localCodexExecutables(ctx context.Context, fresh bool) ([]codexCatalogExecutable, bool) {
	if m.codexExecutables == nil {
		return nil, false
	}
	m.catalogMu.Lock()
	defer m.catalogMu.Unlock()
	now := m.now()
	if !fresh && m.codexExecutablesCache != nil && now.Sub(m.codexExecutablesCachedAt) < codexExecutablesCacheTTL {
		return m.codexExecutablesCache, true
	}
	listCtx, cancel := context.WithTimeout(ctx, codexCatalogCommandTimeout)
	defer cancel()
	paths, err := m.codexExecutables(listCtx)
	if err != nil || len(paths) > codexCatalogMaxExecutables {
		return nil, false
	}
	seen := map[string]struct{}{}
	result := make([]codexCatalogExecutable, 0, len(paths))
	for _, path := range paths {
		executable := codexCatalogExecutable{}
		core := path
		if strings.HasSuffix(strings.TrimRight(path, string(filepath.Separator)), ".app") {
			core, _ = desktopCodexCore(path)
		}
		if info, statErr := os.Stat(core); statErr == nil && info.Mode().IsRegular() && validateExecutable(core) == nil {
			executable = codexCatalogExecutable{Path: core, Size: info.Size(), ModTime: info.ModTime().Unix()}
		}
		key := executable.Path
		if key == "" {
			key = "missing:" + path
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, executable)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Path < result[j].Path })
	m.codexExecutablesCache = result
	m.codexExecutablesCachedAt = now
	return result, true
}

// codexCatalogStale reports whether the executables sharing config.toml are no
// longer the ones the recorded catalog decision covered.
func (m *Manager) codexCatalogStale(item globalManifest) bool {
	if !m.codexCatalogEnabledFeature() {
		return false
	}
	current, ok := m.localCodexExecutables(context.Background(), false)
	if !ok {
		return false
	}
	if item.ModelCatalog == nil {
		return true
	}
	return !sameCodexExecutables(current, item.ModelCatalog.Validated)
}

func sameCodexExecutables(left, right []codexCatalogExecutable) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index].Path != right[index].Path || left[index].Size != right[index].Size || left[index].ModTime != right[index].ModTime {
			return false
		}
	}
	return true
}

func sameCodexCatalogRecord(left *codexCatalogRecord, right codexCatalogRecord) bool {
	return left != nil && left.Enabled == right.Enabled && left.SHA256 == right.SHA256 &&
		sameCodexExecutables(left.Validated, right.Validated)
}

// prebuildCodexCatalog builds the catalog a Codex switch_global plan needs,
// before the manager lock is taken and within codexCatalogPlanBudget. It
// returns nil when the plan is not a Codex switch or cannot be authorized
// (planGlobalLocked then fails on its own checks).
func (m *Manager) prebuildCodexCatalog(ctx context.Context, targetID, planType string) *codexCatalogResult {
	if planType != PlanTypeSwitchGlobal || !validTarget(targetID) || globalFamily(targetID) != familyCodex || !m.codexCatalogEnabledFeature() {
		return nil
	}
	authorization, err := m.resolveAuthorization(ctx, targetID)
	if err != nil {
		return nil
	}
	profile, ok := m.profiles[authorization.Environment][profileTarget(targetID)]
	if !ok || profile.Version != authorization.ProfileVersion {
		return nil
	}
	limit := m.catalogPlanBudget
	if limit <= 0 {
		limit = codexCatalogPlanBudget
	}
	budget, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	result := m.buildCodexCatalog(budget, targetID, profile)
	return &result
}

// buildCodexCatalog lists the relay's models, merges the local catalogs and
// validates the result with every local Codex. It never fails the caller: a
// catalog that cannot be built or validated is simply disabled.
func (m *Manager) buildCodexCatalog(ctx context.Context, targetID string, profile GatewayProfile) codexCatalogResult {
	result := codexCatalogResult{}
	if !m.codexCatalogEnabledFeature() || strings.TrimSpace(profile.Model) == "" {
		return result
	}
	executables, ok := m.localCodexExecutables(ctx, true)
	if !ok || len(executables) == 0 {
		return result
	}
	executables = append([]codexCatalogExecutable(nil), executables...)
	result.Record.Validated = executables
	for _, executable := range executables {
		if executable.Path == "" {
			return result
		}
	}
	listCtx, cancel := context.WithTimeout(ctx, codexCatalogCommandTimeout)
	ids, err := m.gatewayModelIDs(listCtx, targetID, profile.BaseURL)
	cancel()
	if err != nil || len(ids) == 0 {
		return result
	}
	workspace, err := os.MkdirTemp("", "zhiban-codex-catalog-")
	if err != nil {
		return result
	}
	defer os.RemoveAll(workspace)

	catalogs := make([]versionedCodexCatalog, 0, len(executables))
	for index := range executables {
		version, bundled, err := m.readBundledCodexCatalog(ctx, workspace, executables[index].Path)
		if err != nil {
			return result
		}
		executables[index].Version = version
		catalogs = append(catalogs, versionedCodexCatalog{Version: version, Models: bundled})
	}
	result.Record.Validated = executables
	content, err := mergeCodexCatalog(catalogs, ids)
	if err != nil {
		return result
	}
	catalogFile := filepath.Join(workspace, "catalog.json")
	if err := os.WriteFile(catalogFile, content, 0o600); err != nil {
		return result
	}
	for _, executable := range executables {
		if !m.codexParsesCatalog(ctx, workspace, executable.Path, catalogFile, profile.Model) {
			return result
		}
	}
	result.Content = content
	result.Record.Enabled = true
	result.Record.SHA256 = digest(content)
	return result
}

type versionedCodexCatalog struct {
	Version string
	Models  []map[string]any
}

func (m *Manager) runCodex(ctx context.Context, executable string, arguments []string, codexHome string) ([]byte, error) {
	if m.codexCommand != nil {
		return m.codexCommand(ctx, executable, arguments, codexHome)
	}
	runCtx, cancel := context.WithTimeout(ctx, codexCatalogCommandTimeout)
	defer cancel()
	command := quietProbeCommand(runCtx, m.homeDir, codexHome, executable, arguments)
	command.Env = shellenv.PrependPath(command.Env, shellenv.NodeDirs(runCtx, executable, m.nodeLookup))
	command.Stdin = nil
	output := &limitedBuffer{limit: codexCatalogMaxOutput}
	command.Stdout = output
	command.Stderr = io.Discard
	if err := command.Run(); err != nil || output.exceeded {
		return nil, errCodexCatalogDisabled
	}
	return output.Bytes(), nil
}

// readBundledCodexCatalog returns the executable's version and bundled catalog.
func (m *Manager) readBundledCodexCatalog(ctx context.Context, workspace, executable string) (string, []map[string]any, error) {
	home, err := os.MkdirTemp(workspace, "home-")
	if err != nil {
		return "", nil, err
	}
	versionOutput, err := m.runCodex(ctx, executable, []string{"--version"}, home)
	if err != nil {
		return "", nil, err
	}
	version := codexVersionFromOutput(versionOutput)
	if version == "" {
		return "", nil, errCodexCatalogDisabled
	}
	output, err := m.runCodex(ctx, executable, []string{"debug", "models", "--bundled"}, home)
	if err != nil {
		return "", nil, err
	}
	models, err := decodeCodexCatalog(output)
	if err != nil {
		return "", nil, err
	}
	return version, models, nil
}

// codexParsesCatalog runs `debug models` against a CODEX_HOME whose only
// configuration is the catalog: Codex exits non-zero when it cannot parse it.
func (m *Manager) codexParsesCatalog(ctx context.Context, workspace, executable, catalogFile, defaultModel string) bool {
	home, err := os.MkdirTemp(workspace, "check-")
	if err != nil {
		return false
	}
	config := "model_catalog_json = " + strconv.Quote(catalogFile) + "\n"
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte(config), 0o600); err != nil {
		return false
	}
	output, err := m.runCodex(ctx, executable, []string{"debug", "models"}, home)
	if err != nil {
		return false
	}
	models, err := decodeCodexCatalog(output)
	if err != nil {
		return false
	}
	for _, model := range models {
		if slug, _ := model["slug"].(string); slug == defaultModel {
			return true
		}
	}
	return false
}

func decodeCodexCatalog(content []byte) ([]map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(bytes.TrimSpace(content)))
	decoder.UseNumber()
	var document struct {
		Models []map[string]any `json:"models"`
	}
	if err := decoder.Decode(&document); err != nil || len(document.Models) == 0 {
		return nil, errCodexCatalogDisabled
	}
	for _, model := range document.Models {
		if slug, _ := model["slug"].(string); strings.TrimSpace(slug) == "" {
			return nil, errCodexCatalogDisabled
		}
	}
	return document.Models, nil
}

// codexVersionFromOutput reads "codex-cli 0.153.4" (or a bare version).
func codexVersionFromOutput(output []byte) string {
	fields := strings.Fields(strings.TrimSpace(string(output)))
	for index := len(fields) - 1; index >= 0; index-- {
		field := fields[index]
		if field != "" && field[0] >= '0' && field[0] <= '9' && strings.Contains(field, ".") && validSafeValue(field) {
			return field
		}
	}
	return ""
}

// compareCodexVersions orders "0.154.0-alpha.6.2"-style versions by their
// numeric release part, a pre-release sorting before its release.
func compareCodexVersions(left, right string) int {
	leftRelease, leftPre, _ := strings.Cut(left, "-")
	rightRelease, rightPre, _ := strings.Cut(right, "-")
	if order := catalog.CompareVersions(leftRelease, rightRelease); order != 0 {
		return order
	}
	switch {
	case leftPre == rightPre:
		return 0
	case leftPre == "":
		return 1
	case rightPre == "":
		return -1
	}
	return catalog.CompareVersions(leftPre, rightPre)
}

// mergeCodexCatalog builds the compatible superset: for every slug the entry of
// the newest version that bundles it, with the fields older versions require
// filled in from any version that still emits them (or a safe default), and
// every slug the relay does not serve hidden. Relay models that no local Codex
// has metadata for are left out.
func mergeCodexCatalog(catalogs []versionedCodexCatalog, relayIDs []string) ([]byte, error) {
	sorted := append([]versionedCodexCatalog(nil), catalogs...)
	sort.SliceStable(sorted, func(i, j int) bool { return compareCodexVersions(sorted[i].Version, sorted[j].Version) > 0 })
	served := make(map[string]struct{}, len(relayIDs))
	for _, id := range relayIDs {
		served[id] = struct{}{}
	}
	entries := map[string]map[string]any{}
	order := []string{}
	for _, versioned := range sorted {
		for _, model := range versioned.Models {
			slug, _ := model["slug"].(string)
			existing, ok := entries[slug]
			if !ok {
				entries[slug] = cloneJSONObject(model)
				order = append(order, slug)
				continue
			}
			// An older version's fields the newer entry no longer carries.
			for key, value := range model {
				if _, present := existing[key]; !present {
					existing[key] = value
				}
			}
		}
	}
	visible := 0
	models := make([]any, 0, len(order))
	for _, slug := range order {
		entry := entries[slug]
		if _, ok := entry["supports_reasoning_summaries"]; !ok {
			levels, _ := entry["supported_reasoning_levels"].([]any)
			entry["supports_reasoning_summaries"] = len(levels) > 0
		}
		if _, ok := entry["supports_parallel_tool_calls"]; !ok {
			entry["supports_parallel_tool_calls"] = true
		}
		if _, ok := served[slug]; !ok {
			entry["visibility"] = "hide"
		} else if visibility, _ := entry["visibility"].(string); visibility == "list" {
			visible++
		}
		models = append(models, entry)
	}
	if visible == 0 {
		return nil, errCodexCatalogDisabled
	}
	encoded, err := json.Marshal(map[string]any{"models": models})
	if err != nil {
		return nil, err
	}
	return append(encoded, '\n'), nil
}

func cloneJSONObject(source map[string]any) map[string]any {
	clone := make(map[string]any, len(source))
	for key, value := range source {
		clone[key] = value
	}
	return clone
}

// withCodexCatalogLine sets (path != "") or removes the top-level
// model_catalog_json line, placing it after the model (or provider) line.
func withCodexCatalogLine(content []byte, path string) []byte {
	top, rest := splitCodexTopLevel(string(content))
	lines := make([]string, 0, len(top)+1)
	insertAfter := -1
	for _, line := range top {
		if codexTopLevelCatalog.MatchString(line) {
			continue
		}
		lines = append(lines, line)
		if codexTopLevelModel.MatchString(line) || (insertAfter < 0 && codexTopLevelProvider.MatchString(line)) {
			insertAfter = len(lines) - 1
		}
	}
	if path != "" {
		entry := "model_catalog_json = " + strconv.Quote(path)
		if insertAfter < 0 {
			lines = append([]string{entry}, lines...)
		} else {
			lines = append(lines[:insertAfter+1], append([]string{entry}, lines[insertAfter+1:]...)...)
		}
	}
	lines = append(lines, rest...)
	text := strings.Join(lines, "\n")
	if text != "" {
		text += "\n"
	}
	return []byte(text)
}

// codexCatalogLineValue returns the model_catalog_json value of a config.toml.
func codexCatalogLineValue(content []byte) string {
	top, _ := splitCodexTopLevel(string(content))
	for _, line := range top {
		if codexTopLevelCatalog.MatchString(line) {
			return codexLineValue(line)
		}
	}
	return ""
}

type limitedBuffer struct {
	bytes.Buffer
	limit    int
	exceeded bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.limit {
		b.exceeded = true
		return len(p), nil
	}
	return b.Buffer.Write(p)
}

// codexCatalogUnchanged reports whether a re-switch would leave the catalog
// decision, the catalog file and the config.toml line exactly as they are.
func (m *Manager) codexCatalogUnchanged(manifestBefore, configBefore, catalogBefore fileSnapshot, result *codexCatalogResult, catalogPath string) bool {
	if result == nil {
		return true
	}
	item, ok := decodeGlobalManifest(TargetCodexCLI, manifestBefore.Bytes)
	if !ok || !sameCodexCatalogRecord(item.ModelCatalog, result.Record) {
		return false
	}
	if codexCatalogLineValue(configBefore.Bytes) != catalogPath {
		return false
	}
	if result.Content == nil {
		return !catalogBefore.Exists
	}
	return catalogBefore.Exists && bytes.Equal(catalogBefore.Bytes, result.Content)
}

// RefreshGlobalModelCatalog re-decides the Codex model catalog of a switched,
// intact configuration: verify.execute scope=global calls it once the
// credential exchange succeeded, so a changed relay group or a newly
// installed Codex takes effect without a new switch. The catalog line and file
// are outside the managed region: changing them is not drift.
func (m *Manager) RefreshGlobalModelCatalog(ctx context.Context, targetID string) error {
	if globalFamily(targetID) != familyCodex || !m.codexCatalogEnabledFeature() {
		return nil
	}
	configPath := m.globalConfigPath(targetID)
	manifestPath := m.globalManifestPath(targetID)
	m.mu.Lock()
	profile, observedConfig, observedState, err := m.refreshableCodexConfig(targetID)
	m.mu.Unlock()
	if err != nil {
		return err
	}
	// Built without the lock: it runs every local Codex and asks the gateway.
	result := m.buildCodexCatalog(ctx, targetID, profile)

	m.mu.Lock()
	defer m.mu.Unlock()
	config, err := m.snapshot(configPath, false)
	if err != nil {
		return err
	}
	state, err := m.snapshot(manifestPath, false)
	if err != nil {
		return err
	}
	if !sameSnapshot(config, observedConfig) || !sameSnapshot(state, observedState) {
		return ErrPreconditionChanged
	}
	item, _ := decodeGlobalManifest(targetID, state.Bytes)
	catalogPath := ""
	if result.Content != nil {
		catalogPath = m.codexCatalogPath()
	}
	catalogBefore, err := m.snapshot(m.codexCatalogPath(), false)
	if err != nil {
		return err
	}
	if m.codexCatalogUnchanged(state, config, catalogBefore, &result, catalogPath) {
		return nil
	}
	desired := withCodexCatalogLine(config.Bytes, catalogPath)
	if result.Content != nil {
		if err := m.atomicWriteCAS(m.codexCatalogPath(), result.Content, 0o600, catalogBefore); err != nil {
			return err
		}
	}
	if !bytes.Equal(desired, config.Bytes) {
		if err := m.atomicWriteCAS(configPath, desired, fileModeOr(config, 0o600), config); err != nil {
			return err
		}
		if item.AppliedSHA256 == config.SHA256 {
			// Still the file the switch wrote, apart from our own line.
			item.AppliedSHA256 = digest(desired)
		}
	}
	if result.Content == nil && catalogBefore.Exists {
		_ = m.removeSnapshotCAS(m.codexCatalogPath(), catalogBefore)
	}
	record := result.Record
	item.ModelCatalog = &record
	encoded, err := json.Marshal(item)
	if err != nil {
		return ErrInvalidInput
	}
	return m.atomicWriteCAS(manifestPath, append(encoded, '\n'), 0o600, state)
}

// refreshableCodexConfig checks that a Codex configuration is switched and
// intact and returns the profile it was written from. The caller holds mu.
func (m *Manager) refreshableCodexConfig(targetID string) (GatewayProfile, fileSnapshot, fileSnapshot, error) {
	config, err := m.snapshot(m.globalConfigPath(targetID), false)
	if err != nil {
		return GatewayProfile{}, fileSnapshot{}, fileSnapshot{}, err
	}
	state, err := m.snapshot(m.globalManifestPath(targetID), false)
	if err != nil {
		return GatewayProfile{}, fileSnapshot{}, fileSnapshot{}, err
	}
	item, ok := decodeGlobalManifest(targetID, state.Bytes)
	if !state.Exists || !ok || !config.Exists || m.globalDrifted(targetID, item, config) {
		return GatewayProfile{}, fileSnapshot{}, fileSnapshot{}, ErrPreconditionChanged
	}
	if service, err := m.detectService(targetID, config.Bytes); err != nil || service != ServiceZhiban {
		return GatewayProfile{}, fileSnapshot{}, fileSnapshot{}, ErrPreconditionChanged
	}
	profile, ok := m.codexProfileFor(item.ProfileVersion, codexZhibanBaseURL(config.Bytes))
	if !ok {
		return GatewayProfile{}, fileSnapshot{}, fileSnapshot{}, ErrProfileUnavailable
	}
	return profile, config, state, nil
}

// codexProfileFor finds the Codex profile a switched file was written from.
func (m *Manager) codexProfileFor(profileVersion, baseURL string) (GatewayProfile, bool) {
	for _, byTarget := range m.profiles {
		profile, ok := byTarget[TargetCodexCLI]
		if ok && profile.Version == profileVersion && strings.TrimRight(profile.BaseURL, "/") == strings.TrimRight(baseURL, "/") {
			return profile, true
		}
	}
	return GatewayProfile{}, false
}
