package configuration

// Global switch ("切换为知办模型 API" / "恢复官方配置"): the CC Switch model.
//
// Unlike the managed overlay (a separate profile/settings file selected only
// when Zhiban launches the CLI), the global switch rewrites the user's own
// configuration so the tool routes to the Zhiban relay from every entry point
// (their terminal, IDE extensions, the desktop app that shares the file).
//
//   - Claude Code: ~/.claude/settings.json — apiKeyHelper, env.ANTHROPIC_BASE_URL,
//     env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY, model; any static
//     ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY is removed because it would take
//     precedence over the helper.
//   - Codex: ~/.codex/config.toml — top-level model_provider / model (and
//     model_catalog_json when the compatible catalog validates, codex_catalog.go)
//     plus a marked [model_providers.zhiban_ai_managed] table with
//     requires_openai_auth = false (no ChatGPT sign-in needed) and the header
//     that enables Codex's built-in image generation.
//
// Before the first write the whole original file is copied to the Zhiban
// backups directory (rotated) and the original values of every key we touch
// are recorded in a global manifest. "恢复官方配置" restores the exact backup
// when the file is still byte-identical to what we wrote, and otherwise
// reverts only the managed region (the keys and tables listed above) so
// everything else in the file survives.
//
// Drift ("global_drifted"), L3 persistence and "already switched" are judged
// on the managed region alone, never on the whole file: both CLIs rewrite
// their own configuration (Codex records [projects."…"] trust on first run,
// Claude Code rewrites settings.json), and such unrelated changes must not
// demote the switch or make restore destructive.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/catalog"
)

const (
	PlanTypeSwitchGlobal  = "switch_global"
	PlanTypeRestoreGlobal = "restore_global"

	ActionSwitchGlobal  = "switch_global"
	ActionRestoreGlobal = "restore_global"

	ServiceOfficial = "official"
	ServiceZhiban   = "zhiban"
	ServiceUnknown  = "unknown"

	CodexGlobalProviderID = "zhiban_ai_managed"

	globalManifestSchema = 3 // managed region without the tool-written model (2026-09-14)
	// globalManifestSchemaModelRegion fingerprints included the model the tool
	// writes back when the user picks another one (2026-09-09 – 09-14).
	globalManifestSchemaModelRegion = 2
	globalManifestSchemaLegacy      = 1 // whole-file applied_sha256 only (written before 2026-09-09)
	maxBackups                      = 10
	// codexBlockBegin is written as a human-readable header above the Zhiban
	// tables. codexBlockEnd is no longer written (Codex appends its own tables
	// before a trailing comment, which made the marker swallow them) but is
	// still recognised so files written by earlier builds restore cleanly.
	// Neither marker carries meaning: the managed region is found by table name.
	// ASCII only: on Windows another program once rewrote the Chinese of an
	// older marker in the wrong encoding (2026-09-15, see isCodexMarker).
	codexBlockBegin = "# >>> zhiban-ai-managed: managed by Zhiban AI, restore via Zhiban >>>"
	codexBlockEnd   = "# <<< zhiban-ai-managed <<<"
)

var (
	ErrGlobalNotSwitched  = errors.New("configuration: global configuration not switched by zhiban")
	ErrGlobalConflict     = errors.New("configuration: global configuration conflict")
	ErrGlobalParseFailed  = errors.New("configuration: global configuration not parseable")
	codexTopLevelModel    = regexp.MustCompile(`^\s*model\s*=`)
	codexTopLevelProvider = regexp.MustCompile(`^\s*model_provider\s*=`)
	codexTableHeader      = regexp.MustCompile(`^\s*\[`)
	codexZhibanTable      = regexp.MustCompile(`^\s*\[model_providers\.zhiban_ai_managed(\.auth)?\]`)
	codexBaseURLKey       = regexp.MustCompile(`^\s*base_url\s*=`)
	codexTopLevelCatalog  = regexp.MustCompile(`^\s*model_catalog_json\s*=`)
	// codexTopLevelAnalytics matches the user's own analytics.enabled line so a
	// switch can carry it across and a restore can put it back. The switch no
	// longer writes one itself: see codexAnalyticsOffLine (contract §2.7.2
	// "不关闭 Codex 分析上报").
	codexTopLevelAnalytics = regexp.MustCompile(`^\s*analytics\.enabled\s*=`)
)

// codexAnalyticsOffLine is the line switches wrote between 2026-09-15 and
// 2026-09-21 to skip Codex's exit-time analytics post (~7-8 s behind a system
// proxy). It also stops the desktop app's Statsig client, which is how OpenAI
// ships feature gates, so Computer Use and Browser Use resolve to
// statsig-disabled and the app strips their wiring out of config.toml on every
// launch. Codex's [analytics] table has no finer knob (config/src/types.rs,
// deny_unknown_fields), so the switch writes nothing and codexAnalyticsOffStale
// clears the line from machines switched under the old behaviour.
const codexAnalyticsOffLine = "analytics.enabled = false"

// codexImageGenerationHeaderLine: Codex (0.144.1+) loads its built-in image_gen
// tool, which calls {base_url}/images/generations through the active provider,
// only when the provider carries a non-empty x-openai-actor-authorization
// header or the user signed in with ChatGPT. The value is not checked. The same
// header also enables the standalone web search tool, which the relay does not
// serve (/v1/alpha/search → 500); accepted, see contract §2.7.2 "Codex 内置生图".
const codexImageGenerationHeaderLine = `http_headers = { "x-openai-actor-authorization" = "zhiban-ai" }`

// GlobalStatus is the "当前服务" view of the user's own configuration.
type GlobalStatus struct {
	TargetID          string `json:"target_id"`
	CurrentService    string `json:"current_service"`
	ConfigExists      bool   `json:"config_exists"`
	SwitchedByZhiban  bool   `json:"switched_by_zhiban"`
	BackupAvailable   bool   `json:"backup_available"`
	Drifted           bool   `json:"drifted"`
	ProfileVersion    string `json:"profile_version,omitempty"`
	VerificationLevel string `json:"verification_level"`
	LastVerifiedAt    string `json:"last_verified_at,omitempty"`
	// UpgradeAvailable: switched, not drifted, but what the current Bridge
	// writes has moved on (model discovery keys missing, or the Codex
	// executables changed since the model catalog was validated). The App
	// silently re-runs the switch.
	UpgradeAvailable bool `json:"upgrade_available,omitempty"`
}

// globalManifest records what the switch changed so it can be undone.
//
// AppliedSHA256 is the whole-file hash of what the switch wrote; it only
// decides whether restore may use the byte-exact backup. ManagedSHA256 is the
// managed-region fingerprint of the same content and is what drift is judged
// against. Schema 1 manifests have no fingerprint and fall back to the
// whole-file hash until the next successful verification upgrades them.
type globalManifest struct {
	SchemaVersion         int             `json:"schema_version"`
	TargetID              string          `json:"target_id"`
	ProfileVersion        string          `json:"profile_version"`
	FileKind              string          `json:"file_kind"`
	AppliedSHA256         string          `json:"applied_sha256"`
	ManagedSHA256         string          `json:"managed_sha256,omitempty"` // schema 2
	BackupFile            string          `json:"backup_file,omitempty"`
	OriginalExisted       bool            `json:"original_existed"`
	Original              json.RawMessage `json:"original"`
	VerifiedAt            string          `json:"verified_at,omitempty"`
	VerificationLevel     string          `json:"verification_level,omitempty"`
	VerifiedVersion       string          `json:"verified_version,omitempty"`
	VerifiedManagedSHA256 string          `json:"verified_managed_sha256,omitempty"` // schema 2
	VerifiedConfigSHA256  string          `json:"verified_config_sha256,omitempty"`  // schema 1 only
	// ModelCatalog records the last Codex model catalog decision (codex_catalog.go).
	ModelCatalog *codexCatalogRecord `json:"model_catalog,omitempty"`
}

// claudeGlobalOriginal keeps the pre-switch value of every settings.json key
// the switch touches; a nil entry means the key was absent.
type claudeGlobalOriginal struct {
	Values        map[string]*json.RawMessage `json:"values"`
	EnvWasPresent bool                        `json:"env_was_present"`
}

// codexGlobalOriginal keeps the pre-switch top-level lines the switch replaced.
type codexGlobalOriginal struct {
	ModelProviderLine *string `json:"model_provider_line"`
	ModelLine         *string `json:"model_line"`
	ModelCatalogLine  *string `json:"model_catalog_line,omitempty"`
	AnalyticsLine     *string `json:"analytics_line,omitempty"`
}

// claudeGatewayDiscoveryKey makes Claude Code list the gateway's claude-*
// models (GET {ANTHROPIC_BASE_URL}/v1/models) in /model (contract §2.7.2
// "模型选择").
const claudeGatewayDiscoveryKey = "env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"

// claudeGlobalKeys are the settings.json keys the switch writes and restore reverts.
var claudeGlobalKeys = []string{"apiKeyHelper", "model", "env.ANTHROPIC_BASE_URL", "env.ANTHROPIC_AUTH_TOKEN", "env.ANTHROPIC_API_KEY", claudeGatewayDiscoveryKey}

// claudeRegionKeys is the managed region: model is written by the switch but
// Claude Code writes the user's /model choice back to it, so it is not drift.
var claudeRegionKeys = []string{"apiKeyHelper", "env.ANTHROPIC_BASE_URL", "env.ANTHROPIC_AUTH_TOKEN", "env.ANTHROPIC_API_KEY", claudeGatewayDiscoveryKey}

// claudeRegionKeysModel is the schema 2 region.
var claudeRegionKeysModel = []string{"apiKeyHelper", "model", "env.ANTHROPIC_BASE_URL", "env.ANTHROPIC_AUTH_TOKEN", "env.ANTHROPIC_API_KEY"}

func (m *Manager) globalConfigPath(targetID string) string {
	switch globalFamily(targetID) {
	case familyCodex:
		return filepath.Join(m.codexHome, "config.toml")
	case familyClaudeDesktop:
		return m.claudeDesktopConfigPath()
	default:
		return filepath.Join(m.homeDir, ".claude", "settings.json")
	}
}

func (m *Manager) globalManifestPath(targetID string) string {
	return filepath.Join(m.homeDir, "Library", "Application Support", applicationSupportID, "local-coding-tools", "state", manifestOwner(targetID)+".global.json")
}

func (m *Manager) backupsDir() string {
	return filepath.Join(m.homeDir, "Library", "Application Support", applicationSupportID, "local-coding-tools", "backups")
}

func globalFileKind(targetID string) string {
	switch globalFamily(targetID) {
	case familyCodex:
		return "codex_config_global"
	case familyClaudeDesktop:
		return fileKindClaudeDesktopLibrary
	default:
		return "claude_settings_global"
	}
}

// GlobalStatus reports which service the user's own configuration points at.
func (m *Manager) GlobalStatus(_ context.Context, targetID string) (GlobalStatus, error) {
	if !validTarget(targetID) {
		return GlobalStatus{}, ErrInvalidInput
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.globalStatusLocked(targetID)
}

func (m *Manager) globalStatusLocked(targetID string) (GlobalStatus, error) {
	status := GlobalStatus{TargetID: targetID, CurrentService: ServiceOfficial, VerificationLevel: VerificationL0}
	config, err := m.snapshot(m.globalConfigPath(targetID), false)
	if err != nil {
		return GlobalStatus{}, err
	}
	status.ConfigExists = config.Exists
	if config.Exists {
		service, serviceErr := m.detectService(targetID, config.Bytes)
		if serviceErr != nil {
			status.CurrentService = ServiceUnknown
		} else {
			status.CurrentService = service
		}
	}
	state, err := m.snapshot(m.globalManifestPath(targetID), false)
	if err != nil {
		return GlobalStatus{}, err
	}
	item, ok := decodeGlobalManifest(targetID, state.Bytes)
	if !state.Exists || !ok {
		m.markUnowned(targetID, config, &status)
		return status, nil
	}
	status.SwitchedByZhiban = true
	status.ProfileVersion = item.ProfileVersion
	status.Drifted = m.globalDrifted(targetID, item, config)
	if targetID == TargetClaudeDesktop && !m.claudeDesktopApplied() {
		// Zhiban's library entry exists but _meta.json no longer points at
		// it: the app is not routing through Zhiban, whatever the entry says.
		status.CurrentService = ServiceOfficial
		status.Drifted = true
	}
	if item.BackupFile != "" {
		if info, statErr := os.Stat(filepath.Join(m.backupsDir(), item.BackupFile)); statErr == nil && info.Mode().IsRegular() {
			status.BackupAvailable = true
		}
	}
	if status.CurrentService == ServiceZhiban {
		status.VerificationLevel = VerificationL1
		recorded := item.VerificationLevel
		// The global switch accepts whichever version the user installed
		// (planGlobalLocked never gates on the locked version), so a recorded
		// level stands while the managed region is intact; verified_version is
		// informational. Requiring it to equal the locked version turned a
		// passing L3 into VERIFY-NOT_CONFIGURED on a user-installed newer CLI
		// (2026-09-10 Windows: npm codex 0.154.0 vs locked 0.153.4).
		if IsDesktopTarget(targetID) && recorded == VerificationL3 {
			// Desktop applications cannot run an automatic real request: their
			// ceiling is L2 ("已配置"), never the CLI's L3 even on a shared
			// manifest, and the publisher's auto-update moves their version.
			recorded = VerificationL2
		}
		if (recorded == VerificationL3 || recorded == VerificationL2) && m.verifiedRegionIntact(targetID, item, config) &&
			item.VerifiedVersion != "" && validTimestamp(item.VerifiedAt) {
			status.VerificationLevel = recorded
			status.LastVerifiedAt = item.VerifiedAt
		}
		if !status.Drifted {
			status.UpgradeAvailable = m.globalUpgradeAvailable(targetID, item, config)
		}
	}
	return status, nil
}

// globalUpgradeAvailable reports whether a switched, intact configuration is
// missing what the current Bridge writes (contract §2.7.2 "模型选择"): the
// model discovery keys, or a Codex model catalog decision covering the
// executables now on the machine. Judged on content, not the manifest schema,
// so a verification that upgrades the schema cannot hide it.
func (m *Manager) globalUpgradeAvailable(targetID string, item globalManifest, config fileSnapshot) bool {
	if !config.Exists {
		return false
	}
	switch globalFamily(targetID) {
	case familyClaudeCLI:
		root, err := decodeJSONObject(config.Bytes)
		if err != nil {
			return false
		}
		env := nestedEnv(root)
		value, _ := lookupClaudeKey(root, env, claudeGatewayDiscoveryKey)
		text, _ := value.(string)
		return text != "1" || claudeExtraCAMissing(env, m.systemCABundle)
	case familyClaudeDesktop:
		root, err := decodeJSONObject(config.Bytes)
		if err != nil {
			return false
		}
		enabled, _ := root["modelDiscoveryEnabled"].(bool)
		// An entry switched before 2026-09-15 still pins the picker to the
		// profile's one model.
		_, pinned := root["inferenceModels"]
		// An entry switched before 2026-09-17 shows the machine name instead
		// of "知办 AI" in the app's account area.
		name, _ := root["deploymentDisplayName"].(string)
		return !enabled || pinned || name == ""
	case familyCodex:
		return m.codexCatalogStale(item) || codexAnalyticsOffStale(item, config.Bytes) || codexImageGenerationHeaderMissing(config.Bytes)
	default:
		return false
	}
}

// claudeDesktopDisplayCurrent reports whether a switched Claude Desktop entry
// already carries the account-area keys this Bridge writes. They sit outside
// the managed region (so sameManagedRegion cannot see them, and their absence
// is never drift); without this check the plan would call an entry from
// before 2026-09-17 good enough to skip and the background rewrite for
// upgrade_available would never add them. Other targets: always true.
func claudeDesktopDisplayCurrent(targetID string, before, desired []byte) bool {
	if globalFamily(targetID) != familyClaudeDesktop {
		return true
	}
	current, err := decodeJSONObject(before)
	if err != nil {
		return false
	}
	wanted, err := decodeJSONObject(desired)
	if err != nil {
		return false
	}
	for _, key := range []string{"deploymentDisplayName", "deploymentDisplaySubtitle"} {
		if current[key] != wanted[key] {
			return false
		}
	}
	return true
}

// codexImageGenerationHeaderMissing reports whether the Zhiban provider table
// of a switched config.toml lacks the header that enables Codex image generation.
func codexImageGenerationHeaderMissing(content []byte) bool {
	_, rest := splitCodexTopLevel(string(content))
	inside, sawTable := false, false
	for _, line := range rest {
		if codexTableHeader.MatchString(line) {
			inside = strings.TrimSpace(line) == "[model_providers."+CodexGlobalProviderID+"]"
			sawTable = sawTable || inside
			continue
		}
		if inside && strings.TrimSpace(line) == codexImageGenerationHeaderLine {
			return false
		}
	}
	return sawTable
}

// codexAnalyticsOffStale reports whether a switched config.toml still carries
// the analytics.enabled = false line an older switch wrote. The manifest tells
// ours apart from the user's: a switch records their line in analytics_line and
// writes it back verbatim, so a file holding exactly the off line while the
// record has none is ours to drop. Without that check a user who set the same
// value themselves would look permanently upgradeable.
func codexAnalyticsOffStale(item globalManifest, content []byte) bool {
	if codexAnalyticsLineValue(content) != codexAnalyticsOffLine {
		return false
	}
	var original codexGlobalOriginal
	if len(item.Original) > 0 && json.Unmarshal(item.Original, &original) == nil && original.AnalyticsLine != nil {
		return false
	}
	return true
}

// codexAnalyticsLineValue returns the top-level analytics.enabled line, trimmed.
func codexAnalyticsLineValue(content []byte) string {
	top, _ := splitCodexTopLevel(string(content))
	for _, line := range top {
		if codexTopLevelAnalytics.MatchString(line) {
			return strings.TrimSpace(line)
		}
	}
	return ""
}

func nestedEnv(root map[string]any) map[string]any {
	env, _ := root["env"].(map[string]any)
	return env
}

// globalDrifted reports whether the managed region no longer matches what the
// switch wrote. A missing file is always drift. Schema 1 manifests only know
// the whole-file hash, so any change counts until they are upgraded.
func (m *Manager) globalDrifted(targetID string, item globalManifest, config fileSnapshot) bool {
	if !config.Exists {
		return true
	}
	if item.ManagedSHA256 == "" {
		return item.AppliedSHA256 != config.SHA256
	}
	return !m.regionMatches(targetID, item.SchemaVersion, config.Bytes, item.ManagedSHA256)
}

// verifiedRegionIntact reports whether the managed region is still the one a
// recorded L3 verified.
func (m *Manager) verifiedRegionIntact(targetID string, item globalManifest, config fileSnapshot) bool {
	if !config.Exists {
		return false
	}
	if item.VerifiedManagedSHA256 != "" {
		return m.regionMatches(targetID, item.SchemaVersion, config.Bytes, item.VerifiedManagedSHA256)
	}
	return item.VerifiedConfigSHA256 != "" && item.VerifiedConfigSHA256 == config.SHA256
}

// regionMatches compares content's managed region with a recorded fingerprint
// under the manifest's schema. Schema 2 regions contained the model, which the
// tool rewrites when the user picks another one: the recorded fingerprint was
// taken with the profile's model alias, so the current value is replaced by
// each alias before comparing.
func (m *Manager) regionMatches(targetID string, schema int, content []byte, recorded string) bool {
	if recorded == "" {
		return false
	}
	if schema != globalManifestSchemaModelRegion {
		fingerprint, err := managedFingerprint(targetID, content)
		return err == nil && fingerprint == recorded
	}
	for _, fingerprint := range m.modelRegionFingerprints(targetID, content) {
		if fingerprint == recorded {
			return true
		}
	}
	return false
}

// modelRegionFingerprints returns the schema 2 fingerprints of content with its
// model as found and replaced by every profile alias of the target.
func (m *Manager) modelRegionFingerprints(targetID string, content []byte) []string {
	models := []*string{nil}
	seen := map[string]struct{}{}
	for _, byTarget := range m.profiles {
		if profile, ok := byTarget[profileTarget(targetID)]; ok && profile.Model != "" {
			if _, dup := seen[profile.Model]; !dup {
				seen[profile.Model] = struct{}{}
				model := profile.Model
				models = append(models, &model)
			}
		}
	}
	result := make([]string, 0, len(models))
	for _, model := range models {
		var fingerprint string
		var err error
		switch globalFamily(targetID) {
		case familyClaudeCLI:
			fingerprint, err = claudeKeysFingerprint(content, claudeRegionKeysModel, model)
		case familyClaudeDesktop:
			fingerprint, err = claudeDesktopKeysFingerprint(content, claudeDesktopManagedKeysV2)
		case familyCodex:
			fingerprint = codexRegionFingerprint(content, true, model)
		default:
			err = ErrInvalidInput
		}
		if err == nil {
			result = append(result, fingerprint)
		}
	}
	return result
}

// detectService inspects the user's file and reports whether it already
// routes to the Zhiban relay through the credential helper.
func (m *Manager) detectService(targetID string, content []byte) (string, error) {
	switch globalFamily(targetID) {
	case familyClaudeDesktop:
		return m.claudeDesktopService(content)
	case familyClaudeCLI:
		root, err := decodeJSONObject(content)
		if err != nil {
			return ServiceUnknown, err
		}
		helper, _ := root["apiKeyHelper"].(string)
		env, _ := root["env"].(map[string]any)
		baseURL, _ := env["ANTHROPIC_BASE_URL"].(string)
		if strings.HasSuffix(helper, " credential get --target claude_cli") && m.isZhibanGateway(targetID, baseURL) {
			return ServiceZhiban, nil
		}
		return ServiceOfficial, nil
	case familyCodex:
		top, _ := splitCodexTopLevel(string(content))
		for _, line := range top {
			if codexTopLevelProvider.MatchString(line) {
				value := strings.TrimSpace(strings.SplitN(line, "=", 2)[1])
				if unquoted, err := strconv.Unquote(value); err == nil && unquoted == CodexGlobalProviderID {
					return ServiceZhiban, nil
				}
				return ServiceOfficial, nil
			}
		}
		return ServiceOfficial, nil
	default:
		return ServiceUnknown, ErrInvalidInput
	}
}

// markUnowned handles a status without a readable switch record (B3,
// contract §2.7): a file that is recognisably Zhiban's is reported drifted, so
// the App offers 一键修复 (which adopts it); a Claude Desktop entry the app no
// longer applies is not routing through Zhiban at all.
func (m *Manager) markUnowned(targetID string, config fileSnapshot, status *GlobalStatus) {
	if status.CurrentService != ServiceZhiban {
		return
	}
	if m.unownedZhibanConfig(targetID, config) {
		status.Drifted = true
		return
	}
	if targetID == TargetClaudeDesktop {
		status.CurrentService = ServiceOfficial
	}
}

// unownedZhibanConfig reports whether a file routes to a Zhiban gateway. It is
// stricter than detectService for Codex, whose provider name alone could be
// borrowed by somebody else's table: that stays a conflict.
func (m *Manager) unownedZhibanConfig(targetID string, config fileSnapshot) bool {
	if !config.Exists {
		return false
	}
	service, err := m.detectService(targetID, config.Bytes)
	if err != nil || service != ServiceZhiban {
		return false
	}
	switch globalFamily(targetID) {
	case familyCodex:
		return m.isZhibanGateway(targetID, codexZhibanBaseURL(config.Bytes))
	case familyClaudeDesktop:
		return m.claudeDesktopApplied()
	default:
		// detectService already requires Zhiban's helper shape and gateway.
		return true
	}
}

// unownedManifest stands in for the missing switch record of an unowned
// Zhiban file: no backup (so restore reverts structurally) and an "original"
// that keeps only what is not recognisably Zhiban's.
func (m *Manager) unownedManifest(targetID string, config fileSnapshot) (globalManifest, bool) {
	if !m.unownedZhibanConfig(targetID, config) {
		return globalManifest{}, false
	}
	item := globalManifest{
		SchemaVersion: globalManifestSchema, TargetID: manifestOwner(targetID), FileKind: globalFileKind(targetID),
		OriginalExisted: true,
	}
	var original any
	switch globalFamily(targetID) {
	case familyCodex:
		codex := codexGlobalOriginal{}
		top, _ := splitCodexTopLevel(string(config.Bytes))
		for _, line := range top {
			if codexTopLevelModel.MatchString(line) && codex.ModelLine == nil && !m.isZhibanModel(targetID, codexLineValue(line)) {
				value := line
				codex.ModelLine = &value
			}
			if codexTopLevelCatalog.MatchString(line) && codex.ModelCatalogLine == nil && codexLineValue(line) != m.codexCatalogPath() {
				value := line
				codex.ModelCatalogLine = &value
			}
			if codexTopLevelAnalytics.MatchString(line) && codex.AnalyticsLine == nil && strings.TrimSpace(line) != codexAnalyticsOffLine {
				value := line
				codex.AnalyticsLine = &value
			}
		}
		original = codex
	case familyClaudeCLI:
		root, err := decodeJSONObject(config.Bytes)
		if err != nil {
			return globalManifest{}, false
		}
		original = m.claudeStrippedOriginal(targetID, root)
	case familyClaudeDesktop:
		original = claudeDesktopOriginal{MetaExisted: true}
	}
	encoded, err := json.Marshal(original)
	if err != nil {
		return globalManifest{}, false
	}
	item.Original = encoded
	return item, true
}

// claudeStrippedOriginal is a settings.json original that keeps only what is
// not recognisably Zhiban's among the managed keys.
func (m *Manager) claudeStrippedOriginal(targetID string, root map[string]any) claudeGlobalOriginal {
	env, envPresent := root["env"].(map[string]any)
	claude := claudeGlobalOriginal{Values: map[string]*json.RawMessage{}, EnvWasPresent: envPresent}
	for _, key := range claudeGlobalKeys {
		value, present := lookupClaudeKey(root, env, key)
		if present && !m.zhibanClaudeValue(targetID, key, value) {
			claude.Values[key] = rawValue(value, true)
		}
	}
	if value, present := lookupClaudeKey(root, env, claudeExtraCAKey); present {
		if text, isText := value.(string); !isText || m.systemCABundle == "" || text != m.systemCABundle {
			claude.Values[claudeExtraCAKey] = rawValue(value, true)
		}
	}
	return claude
}

// claudeLeftoverManifest handles a settings.json that no longer routes to
// Zhiban as a whole (the user deleted apiKeyHelper, or pointed the gateway
// elsewhere) but still carries keys the switch wrote: the gateway URL, the
// model-discovery flag, the helper, the root bundle. Recording that file as
// the user's original would make 恢复官方配置 hand the official service a
// Zhiban gateway with no credentials (2026-09-18 Windows 12800: 401 after
// restore). Like unownedManifest it stands in for the missing record with the
// Zhiban values stripped.
func (m *Manager) claudeLeftoverManifest(targetID string, config fileSnapshot) (globalManifest, bool) {
	if globalFamily(targetID) != familyClaudeCLI || !config.Exists || !m.claudeZhibanLeftover(targetID, config.Bytes) {
		return globalManifest{}, false
	}
	root, err := decodeJSONObject(config.Bytes)
	if err != nil {
		return globalManifest{}, false
	}
	encoded, err := json.Marshal(m.claudeStrippedOriginal(targetID, root))
	if err != nil {
		return globalManifest{}, false
	}
	return globalManifest{
		SchemaVersion: globalManifestSchema, TargetID: manifestOwner(targetID), FileKind: globalFileKind(targetID),
		OriginalExisted: true, Original: encoded,
	}, true
}

// claudeZhibanLeftover reports whether settings.json holds any value the
// switch writes (model excluded: Claude Code writes the user's /model choice
// there, so it is theirs to keep).
func (m *Manager) claudeZhibanLeftover(targetID string, content []byte) bool {
	root, err := decodeJSONObject(content)
	if err != nil {
		return false
	}
	env, _ := root["env"].(map[string]any)
	for _, key := range []string{"apiKeyHelper", "env.ANTHROPIC_BASE_URL", claudeGatewayDiscoveryKey} {
		if value, present := lookupClaudeKey(root, env, key); present && m.zhibanClaudeValue(targetID, key, value) {
			return true
		}
	}
	if value, present := lookupClaudeKey(root, env, claudeExtraCAKey); present && m.systemCABundle != "" {
		if text, isText := value.(string); isText && text == m.systemCABundle {
			return true
		}
	}
	return false
}

// zhibanClaudeValue reports whether a managed settings.json value is one the
// switch writes.
func (m *Manager) zhibanClaudeValue(targetID, key string, value any) bool {
	text, _ := value.(string)
	switch key {
	case "apiKeyHelper":
		return strings.HasSuffix(text, " credential get --target claude_cli")
	case "model":
		return m.isZhibanModel(targetID, text)
	case "env.ANTHROPIC_BASE_URL":
		return m.isZhibanGateway(targetID, text)
	case claudeGatewayDiscoveryKey:
		return text == "1"
	default:
		return false
	}
}

// isZhibanModel reports whether model is the model alias of any environment's
// profile for the target.
func (m *Manager) isZhibanModel(targetID, model string) bool {
	if model == "" {
		return false
	}
	for _, byTarget := range m.profiles {
		if profile, ok := byTarget[profileTarget(targetID)]; ok && profile.Model == model {
			return true
		}
	}
	return false
}

// codexLineValue returns the unquoted string value of a `key = "value"` line.
func codexLineValue(line string) string {
	parts := strings.SplitN(line, "=", 2)
	if len(parts) != 2 {
		return ""
	}
	value, err := strconv.Unquote(strings.TrimSpace(parts[1]))
	if err != nil {
		return ""
	}
	return value
}

// codexZhibanBaseURL returns base_url from the [model_providers.zhiban_ai_managed] table.
func codexZhibanBaseURL(content []byte) string {
	inTable := false
	for _, line := range strings.Split(string(content), "\n") {
		if codexTableHeader.MatchString(line) {
			inTable = strings.TrimSpace(line) == "[model_providers.zhiban_ai_managed]"
			continue
		}
		if inTable && codexBaseURLKey.MatchString(line) {
			return codexLineValue(line)
		}
	}
	return ""
}

func (m *Manager) isZhibanGateway(targetID, baseURL string) bool {
	for _, byTarget := range m.profiles {
		if profile, ok := byTarget[profileTarget(targetID)]; ok && strings.TrimRight(profile.BaseURL, "/") == strings.TrimRight(baseURL, "/") {
			return true
		}
	}
	return false
}

// planGlobalLocked prepares a switch or restore plan. The caller holds m.mu.
func (m *Manager) planGlobalLocked(ctx context.Context, targetID, installationID, planType string, prebuiltCatalog *codexCatalogResult) (Plan, error) {
	configPath := m.globalConfigPath(targetID)
	manifestPath := m.globalManifestPath(targetID)
	configBefore, err := m.snapshot(configPath, false)
	if err != nil {
		return Plan{}, err
	}
	manifestBefore, err := m.snapshot(manifestPath, false)
	if err != nil {
		return Plan{}, err
	}
	expiresAt := m.now().UTC().Add(planTTL)
	planID, err := m.newPlanID()
	if err != nil {
		return Plan{}, err
	}

	switch planType {
	case PlanTypeSwitchGlobal:
		installation, err := m.resolveInstallation(ctx, targetID, installationID)
		if err != nil || installation.TargetID != targetID || installation.InstallationID != installationID {
			return Plan{}, ErrInstallationChanged
		}
		if _, tooOld := catalog.MinimumSwitchVersion(targetID, installation.Version); tooOld {
			return Plan{}, ErrVersionTooOld
		}
		installation, err = desktopProbeInstallation(installation)
		if err != nil {
			return Plan{}, ErrInstallationChanged
		}
		if installation.Executable != "" {
			if err := validateExecutable(installation.Executable); err != nil {
				return Plan{}, ErrInstallationChanged
			}
		}
		if err := validateExecutable(m.helperExecutable); err != nil {
			return Plan{}, err
		}
		helperInfo, err := os.Stat(m.helperExecutable)
		if err != nil {
			return Plan{}, ErrUnsafePath
		}
		authorization, err := m.resolveAuthorization(ctx, targetID)
		if err != nil {
			return Plan{}, ErrAuthorizationMissing
		}
		profile, ok := m.profiles[authorization.Environment][profileTarget(targetID)]
		if !ok || profile.Version != authorization.ProfileVersion {
			return Plan{}, ErrProfileUnavailable
		}
		recorded, switched := decodeGlobalManifest(targetID, manifestBefore.Bytes)
		// B3: a Zhiban-routed file without a record is taken over. The switch
		// renders from that file minus Zhiban's region, and that is also what
		// the manifest records as the pre-switch original, so a later restore
		// cannot bring the old Zhiban lines back.
		renderBefore := configBefore
		var adoptedOriginal *fileSnapshot
		if !switched {
			item, unowned := m.unownedManifest(targetID, configBefore)
			if !unowned {
				item, unowned = m.claudeLeftoverManifest(targetID, configBefore)
			}
			if unowned {
				stripped, removeFile, err := m.renderRestore(targetID, item, configBefore)
				if err != nil {
					return Plan{}, err
				}
				renderBefore = fileSnapshot{}
				if !removeFile {
					renderBefore = snapshotForContent(stripped, fileModeOr(configBefore, 0o600))
				}
				adoptedOriginal = &renderBefore
			}
		}
		var codexCatalog *codexCatalogResult
		catalogPath := ""
		catalogBefore := fileSnapshot{}
		if globalFamily(targetID) == familyCodex && m.codexCatalogEnabledFeature() {
			result := codexCatalogResult{}
			if prebuiltCatalog != nil {
				result = *prebuiltCatalog
			}
			codexCatalog = &result
			if result.Content != nil {
				catalogPath = m.codexCatalogPath()
			}
			if catalogBefore, err = m.snapshot(m.codexCatalogPath(), false); err != nil {
				return Plan{}, err
			}
		}
		desired, original, err := m.renderGlobal(targetID, renderBefore, profile, switched, catalogPath)
		if err != nil {
			return Plan{}, err
		}
		var extra *extraFile
		if targetID == TargetClaudeDesktop {
			metaBefore, err := m.snapshot(m.claudeDesktopMetaPath(), false)
			if err != nil {
				return Plan{}, err
			}
			metaDesired, metaOriginal, err := m.claudeDesktopMetaSwitch(metaBefore)
			if err != nil {
				return Plan{}, err
			}
			original, _ = json.Marshal(metaOriginal)
			extra = &extraFile{Path: m.claudeDesktopMetaPath(), Before: metaBefore, Desired: metaDesired}
		}
		action := ActionSwitchGlobal
		if switched && recorded.ProfileVersion == authorization.ProfileVersion && configBefore.Exists && sameManagedRegion(targetID, configBefore.Bytes, desired) &&
			claudeDesktopDisplayCurrent(targetID, configBefore.Bytes, desired) &&
			claudeExtraCACurrent(targetID, configBefore.Bytes, desired) &&
			(extra == nil || bytes.Equal(extra.Before.Bytes, extra.Desired)) &&
			m.codexCatalogUnchanged(manifestBefore, configBefore, catalogBefore, codexCatalog, catalogPath) &&
			codexAnalyticsLineValue(configBefore.Bytes) == codexAnalyticsLineValue(desired) &&
			// …and the record still describes this file. A record left behind by
			// an interrupted write (Windows 12015: the config was rewritten but
			// its manifest was not) reads as drift, and "一键修复" could never
			// clear it while the plan called the file good enough to skip:
			// verify then kept reporting VERIFY-NOT_CONFIGURED.
			!m.globalDrifted(targetID, recorded, configBefore) {
			// Already switched and the managed region is exactly what this
			// profile would write: rewriting would only reshuffle the file
			// around whatever the CLI added since, so leave it alone.
			action = ActionNone
		}
		public := Plan{PlanID: planID, TargetID: targetID, Action: action, ProfileVersion: authorization.ProfileVersion, ExpiresAt: expiresAt.Format(time.RFC3339)}
		m.plans[planID] = pendingPlan{
			Public: public, ExpiresAt: expiresAt, Installation: installation, Authorization: authorization, HelperInfo: helperInfo,
			ConfigPath: configPath, ManifestPath: manifestPath, Desired: desired, ConfigBefore: configBefore, ManifestBefore: manifestBefore,
			Global: true, GlobalOriginal: original, Extra: extra, AdoptedOriginal: adoptedOriginal,
			CodexCatalog: codexCatalog, CatalogBefore: catalogBefore,
		}
		return public, nil
	case PlanTypeRestoreGlobal:
		item, ok := decodeGlobalManifest(targetID, manifestBefore.Bytes)
		unowned := false
		if !manifestBefore.Exists || !ok {
			// B3: no record, but the file is recognisably Zhiban's — remove
			// Zhiban's region (after a backup) instead of reporting "nothing
			// to restore" while the file keeps routing to Zhiban.
			if item, ok = m.unownedManifest(targetID, configBefore); !ok {
				return Plan{}, ErrGlobalNotSwitched
			}
			unowned = true
		}
		restored, removeFile, err := m.renderRestore(targetID, item, configBefore)
		if err != nil {
			return Plan{}, err
		}
		var extra *extraFile
		if targetID == TargetClaudeDesktop {
			metaBefore, err := m.snapshot(m.claudeDesktopMetaPath(), false)
			if err != nil {
				return Plan{}, err
			}
			metaDesired, removeMeta, err := m.claudeDesktopMetaRestore(item, metaBefore)
			if err != nil {
				return Plan{}, err
			}
			extra = &extraFile{Path: m.claudeDesktopMetaPath(), Before: metaBefore, Desired: metaDesired, Remove: removeMeta}
		}
		public := Plan{PlanID: planID, TargetID: targetID, Action: ActionRestoreGlobal, ProfileVersion: item.ProfileVersion, ExpiresAt: expiresAt.Format(time.RFC3339)}
		m.plans[planID] = pendingPlan{
			Public: public, ExpiresAt: expiresAt, ConfigPath: configPath, ManifestPath: manifestPath,
			Desired: restored, ConfigBefore: configBefore, ManifestBefore: manifestBefore, Global: true,
			RestoreRemovesFile: removeFile, Extra: extra, BackupBeforeRestore: unowned,
		}
		return public, nil
	default:
		return Plan{}, ErrInvalidInput
	}
}

// executeGlobalLocked applies a switch or restore plan with rollback.
func (m *Manager) executeGlobalLocked(ctx context.Context, plan pendingPlan) (Status, error) {
	configNow, err := m.snapshot(plan.ConfigPath, false)
	if err != nil {
		return Status{}, err
	}
	manifestNow, err := m.snapshot(plan.ManifestPath, false)
	if err != nil {
		return Status{}, err
	}
	if !sameSnapshot(configNow, plan.ConfigBefore) || !sameSnapshot(manifestNow, plan.ManifestBefore) {
		return Status{}, ErrPreconditionChanged
	}
	if plan.Extra != nil {
		extraNow, err := m.snapshot(plan.Extra.Path, false)
		if err != nil {
			return Status{}, err
		}
		if !sameSnapshot(extraNow, plan.Extra.Before) {
			return Status{}, ErrPreconditionChanged
		}
	}
	targetID := plan.Public.TargetID

	switch plan.Public.Action {
	case ActionNone:
		return m.fullStatusLocked(targetID)
	case ActionSwitchGlobal:
		installation, err := m.resolveInstallation(ctx, targetID, plan.Installation.InstallationID)
		if err == nil {
			installation, err = desktopProbeInstallation(installation)
		}
		if err != nil || installation.Executable != plan.Installation.Executable {
			return Status{}, ErrInstallationChanged
		}
		authorization, err := m.resolveAuthorization(ctx, targetID)
		if err != nil || authorization != plan.Authorization {
			return Status{}, ErrPreconditionChanged
		}
		helperInfo, err := os.Stat(m.helperExecutable)
		if err != nil || !sameFileInfo(plan.HelperInfo, helperInfo) {
			return Status{}, ErrPreconditionChanged
		}
		// The file a restore must return to: the user's own file for CLIs, the
		// config library index for Claude Desktop (Zhiban's entry is entirely
		// Zhiban's, so it is never backed up).
		backupSource := plan.ConfigBefore
		if plan.Extra != nil {
			backupSource = plan.Extra.Before
		} else if plan.AdoptedOriginal != nil {
			backupSource = *plan.AdoptedOriginal
		}
		backupName := ""
		if backupSource.Exists {
			backupName, err = m.writeBackup(manifestOwner(targetID), backupSource.Bytes)
			if err != nil {
				return Status{}, err
			}
		}
		if targetID == TargetClaudeDesktop {
			if err := m.ensureClaudeDesktopHelper(); err != nil {
				return Status{}, err
			}
		}
		// The catalog file goes first: a config.toml naming a missing catalog
		// stops Codex from starting.
		catalogApplied := fileSnapshot{}
		if plan.CodexCatalog != nil && plan.CodexCatalog.Content != nil {
			if err := m.atomicWriteCAS(m.codexCatalogPath(), plan.CodexCatalog.Content, 0o600, plan.CatalogBefore); err != nil {
				return Status{}, err
			}
			catalogApplied = snapshotForContent(plan.CodexCatalog.Content, 0o600)
		}
		rollbackCatalog := func() {
			if catalogApplied.Exists {
				_ = m.restoreSnapshotCAS(m.codexCatalogPath(), catalogApplied, plan.CatalogBefore)
			}
		}
		if err := m.atomicWriteCAS(plan.ConfigPath, plan.Desired, fileModeOr(plan.ConfigBefore, 0o600), plan.ConfigBefore); err != nil {
			rollbackCatalog()
			return Status{}, err
		}
		written, err := m.snapshot(plan.ConfigPath, false)
		if err != nil || !written.Exists || !bytes.Equal(written.Bytes, plan.Desired) {
			_ = m.restoreSnapshotCAS(plan.ConfigPath, snapshotForContent(plan.Desired, fileModeOr(plan.ConfigBefore, 0o600)), plan.ConfigBefore)
			rollbackCatalog()
			return Status{}, ErrValidationFailed
		}
		if err := m.probeGlobal(ctx, installation); err != nil {
			if rollbackErr := m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore); rollbackErr != nil {
				return Status{}, errors.Join(ErrValidationFailed, ErrRollbackFailed)
			}
			rollbackCatalog()
			return Status{}, ErrValidationFailed
		}
		if plan.CodexCatalog != nil && plan.CodexCatalog.Content == nil && plan.CatalogBefore.Exists {
			// Disabled now: config.toml no longer names the file.
			_ = m.removeSnapshotCAS(m.codexCatalogPath(), plan.CatalogBefore)
		}
		if plan.Extra != nil {
			if err := m.atomicWriteCAS(plan.Extra.Path, plan.Extra.Desired, fileModeOr(plan.Extra.Before, 0o600), plan.Extra.Before); err != nil {
				if rollbackErr := m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore); rollbackErr != nil {
					return Status{}, errors.Join(err, ErrRollbackFailed)
				}
				return Status{}, err
			}
		}
		managed, err := managedFingerprint(targetID, plan.Desired)
		if err != nil {
			_ = m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore)
			return Status{}, ErrValidationFailed
		}
		manifest := globalManifest{
			SchemaVersion: globalManifestSchema, TargetID: manifestOwner(targetID), ProfileVersion: plan.Public.ProfileVersion,
			FileKind: globalFileKind(targetID), AppliedSHA256: digest(plan.Desired), ManagedSHA256: managed, BackupFile: backupName,
			OriginalExisted: backupSource.Exists, Original: plan.GlobalOriginal,
		}
		if plan.CodexCatalog != nil {
			record := plan.CodexCatalog.Record
			manifest.ModelCatalog = &record
		}
		if previous, ok := decodeGlobalManifest(targetID, plan.ManifestBefore.Bytes); ok && plan.ConfigBefore.Exists {
			service, serviceErr := m.detectService(targetID, plan.ConfigBefore.Bytes)
			stillZhiban := serviceErr == nil && service == ServiceZhiban
			// A Claude file judged official only because the user removed
			// one of the two keys still carries the other: same rule.
			if !stillZhiban && globalFamily(targetID) == familyClaudeCLI {
				stillZhiban = m.claudeZhibanLeftover(targetID, plan.ConfigBefore.Bytes)
			}
			if stillZhiban {
				// Re-switching a file that still routes to Zhiban (一键修复 after
				// the managed region drifted): what "恢复官方配置" must return to
				// is the pre-Zhiban state the first switch recorded, not the
				// current Zhiban-routed lines and their backup.
				manifest.BackupFile = previous.BackupFile
				manifest.OriginalExisted = previous.OriginalExisted
				manifest.Original = previous.Original
				if globalFamily(targetID) == familyClaudeCLI {
					manifest.Original = adoptExtraCAOriginal(previous.Original, plan.GlobalOriginal)
				}
			}
		}
		encoded, err := json.Marshal(manifest)
		if err != nil {
			_ = m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore)
			return Status{}, ErrValidationFailed
		}
		encoded = append(encoded, '\n')
		if err := m.atomicWriteCAS(plan.ManifestPath, encoded, 0o600, plan.ManifestBefore); err != nil {
			if rollbackErr := m.restoreSnapshotCAS(plan.ConfigPath, written, plan.ConfigBefore); rollbackErr != nil {
				return Status{}, errors.Join(err, ErrRollbackFailed)
			}
			return Status{}, err
		}
		return m.fullStatusLocked(targetID)
	case ActionRestoreGlobal:
		if plan.BackupBeforeRestore {
			// Without a record there is no earlier backup: keep the file as it
			// was before Zhiban's region is removed.
			source := plan.ConfigBefore
			if plan.Extra != nil {
				source = plan.Extra.Before
			}
			if source.Exists {
				if _, err := m.writeBackup(manifestOwner(targetID), source.Bytes); err != nil {
					return Status{}, err
				}
			}
		}
		if plan.RestoreRemovesFile {
			if err := m.removeSnapshotCAS(plan.ConfigPath, plan.ConfigBefore); err != nil {
				return Status{}, err
			}
		} else if err := m.atomicWriteCAS(plan.ConfigPath, plan.Desired, fileModeOr(plan.ConfigBefore, 0o600), plan.ConfigBefore); err != nil {
			return Status{}, err
		}
		if plan.Extra != nil {
			switch {
			case plan.Extra.Remove:
				if err := m.removeSnapshotCAS(plan.Extra.Path, plan.Extra.Before); err != nil {
					return Status{}, err
				}
			case plan.Extra.Desired != nil:
				if err := m.atomicWriteCAS(plan.Extra.Path, plan.Extra.Desired, fileModeOr(plan.Extra.Before, 0o600), plan.Extra.Before); err != nil {
					return Status{}, err
				}
			}
		}
		if err := m.removeSnapshotCAS(plan.ManifestPath, plan.ManifestBefore); err != nil {
			return Status{}, err
		}
		if globalFamily(targetID) == familyCodex {
			if catalogNow, err := m.snapshot(m.codexCatalogPath(), false); err == nil && catalogNow.Exists {
				_ = m.removeSnapshotCAS(m.codexCatalogPath(), catalogNow)
			}
			status, err := m.fullStatusLocked(targetID)
			if err != nil {
				return status, err
			}
			return m.remapCodexSessionsAfterRestore(ctx, status, plan.Desired, plan.RestoreRemovesFile), nil
		}
		return m.fullStatusLocked(targetID)
	default:
		return Status{}, ErrInvalidInput
	}
}

// RecordGlobalVerification stores a successful L3 for the global switch.
func (m *Manager) RecordGlobalVerification(ctx context.Context, targetID, installedVersion string) (GlobalStatus, error) {
	if !validTarget(targetID) || !validSafeValue(installedVersion) {
		return GlobalStatus{}, ErrInvalidInput
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	config, err := m.snapshot(m.globalConfigPath(targetID), false)
	if err != nil {
		return GlobalStatus{}, err
	}
	state, err := m.snapshot(m.globalManifestPath(targetID), false)
	if err != nil {
		return GlobalStatus{}, err
	}
	item, ok := decodeGlobalManifest(targetID, state.Bytes)
	if !state.Exists || !ok || !config.Exists {
		return GlobalStatus{}, ErrPreconditionChanged
	}
	fingerprint, err := managedFingerprint(targetID, config.Bytes)
	if err != nil || m.globalDrifted(targetID, item, config) {
		return GlobalStatus{}, ErrPreconditionChanged
	}
	upgradeRegion := item.ManagedSHA256 == "" || item.SchemaVersion != globalManifestSchema
	level := VerificationL3
	if IsDesktopTarget(targetID) {
		// Desktop applications are verified up to L2 (configuration parses,
		// helper runs, credential exchanges). Never let that demote an L3 the
		// CLI recorded on a shared manifest.
		level = VerificationL2
		if item.VerificationLevel == VerificationL3 && m.verifiedRegionIntact(targetID, item, config) && validTimestamp(item.VerifiedAt) {
			if globalFamily(targetID) == familyCodex {
				m.syncCodexSessionsToZhiban(ctx, item)
			}
			return m.globalStatusLocked(targetID)
		}
	}
	if upgradeRegion {
		// Schema 1 (file byte-identical to what the switch wrote) or schema 2
		// (region intact apart from the model): the region is ours, so record
		// it under the current schema.
		item.ManagedSHA256 = fingerprint
	}
	item.SchemaVersion = globalManifestSchema
	item.VerifiedAt = m.now().UTC().Format(time.RFC3339)
	item.VerificationLevel = level
	item.VerifiedVersion = installedVersion
	item.VerifiedManagedSHA256 = fingerprint
	item.VerifiedConfigSHA256 = ""
	encoded, err := json.Marshal(item)
	if err != nil {
		return GlobalStatus{}, ErrInvalidInput
	}
	encoded = append(encoded, '\n')
	if err := m.atomicWriteCAS(m.globalManifestPath(targetID), encoded, 0o600, state); err != nil {
		return GlobalStatus{}, err
	}
	if globalFamily(targetID) == familyCodex {
		m.syncCodexSessionsToZhiban(ctx, item)
	}
	return m.globalStatusLocked(targetID)
}

// renderGlobal produces the switched file content and the originals record.
// switched tells whether a Zhiban manifest already exists for this file: only
// then is an existing [model_providers.zhiban_ai_managed] table ours to
// replace; otherwise it was written by something else and is a conflict.
// A file that already routes to Zhiban keeps its model: the tool wrote the
// user's own choice there. catalogPath names the Codex model catalog to
// reference ("" writes none).
func (m *Manager) renderGlobal(targetID string, before fileSnapshot, profile GatewayProfile, switched bool, catalogPath string) ([]byte, json.RawMessage, error) {
	keepModel := false
	if before.Exists {
		if service, err := m.detectService(targetID, before.Bytes); err == nil && service == ServiceZhiban {
			keepModel = true
		}
	}
	switch globalFamily(targetID) {
	case familyClaudeDesktop:
		// Zhiban's library entry is entirely Zhiban's; the originals record
		// (previous appliedId) is filled in by the caller from _meta.json.
		content, err := m.renderClaudeDesktopConfig(profile)
		return content, json.RawMessage("{}"), err
	case familyClaudeCLI:
		root := map[string]any{}
		if before.Exists {
			decoded, err := decodeJSONObject(before.Bytes)
			if err != nil {
				return nil, nil, ErrGlobalParseFailed
			}
			root = decoded
		}
		original := claudeGlobalOriginal{Values: map[string]*json.RawMessage{}}
		env, envPresent := root["env"].(map[string]any)
		if _, exists := root["env"]; exists && !envPresent {
			return nil, nil, ErrGlobalParseFailed
		}
		original.EnvWasPresent = envPresent
		if !envPresent {
			env = map[string]any{}
		}
		for _, key := range claudeGlobalKeys {
			original.Values[key] = rawValue(lookupClaudeKey(root, env, key))
		}
		original.Values[claudeExtraCAKey] = rawValue(lookupClaudeKey(root, env, claudeExtraCAKey))
		quotedHelper, err := shellQuote(m.helperExecutable)
		if err != nil {
			return nil, nil, err
		}
		root["apiKeyHelper"] = quotedHelper + " credential get --target claude_cli"
		if _, present := root["model"]; profile.Model != "" && !(keepModel && present) {
			root["model"] = profile.Model
		}
		env["ANTHROPIC_BASE_URL"] = profile.BaseURL
		env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"
		delete(env, "ANTHROPIC_AUTH_TOKEN")
		delete(env, "ANTHROPIC_API_KEY")
		ensureClaudeExtraCA(env, m.systemCABundle)
		root["env"] = env
		content, err := encodeJSONObject(root)
		if err != nil {
			return nil, nil, err
		}
		originalJSON, _ := json.Marshal(original)
		return content, originalJSON, nil
	case familyCodex:
		text := ""
		if before.Exists {
			text = string(before.Bytes)
		}
		top, rest := splitCodexTopLevel(text)
		original := codexGlobalOriginal{}
		kept := make([]string, 0, len(top))
		for _, line := range top {
			switch {
			case codexTopLevelProvider.MatchString(line) && original.ModelProviderLine == nil:
				value := line
				original.ModelProviderLine = &value
			case codexTopLevelModel.MatchString(line) && original.ModelLine == nil:
				value := line
				original.ModelLine = &value
			case codexTopLevelCatalog.MatchString(line) && original.ModelCatalogLine == nil:
				value := line
				original.ModelCatalogLine = &value
			// Re-rendering a file this tool already switched: an
			// analytics.enabled = false in it is the one an older switch wrote,
			// not the user's, so it is dropped rather than carried across.
			case codexTopLevelAnalytics.MatchString(line) && original.AnalyticsLine == nil &&
				!(switched && strings.TrimSpace(line) == codexAnalyticsOffLine):
				value := line
				original.AnalyticsLine = &value
			case switched && codexTopLevelAnalytics.MatchString(line) && strings.TrimSpace(line) == codexAnalyticsOffLine:
				// Dropped: see above.
			case isCodexMarker(line):
				// Re-rendered with the block below; without any table before
				// ours the marker sits in the top-level section.
			default:
				kept = append(kept, line)
			}
		}
		body, hadManaged := removeCodexManaged(rest)
		if hadManaged && !switched {
			return nil, nil, ErrGlobalConflict
		}
		head := []string{"model_provider = " + strconv.Quote(CodexGlobalProviderID)}
		switch {
		case keepModel && original.ModelLine != nil:
			head = append(head, *original.ModelLine)
		case profile.Model != "":
			head = append(head, "model = "+strconv.Quote(profile.Model))
		}
		if catalogPath != "" {
			head = append(head, "model_catalog_json = "+strconv.Quote(catalogPath))
		}
		// Only the user's own analytics.enabled line comes back; the switch adds
		// none of its own (contract §2.7.2 "不关闭 Codex 分析上报"). Dropping the
		// line an older switch left behind is what lets the desktop app keep
		// Computer Use and Browser Use wired up.
		if original.AnalyticsLine != nil {
			head = append(head, *original.AnalyticsLine)
		}
		lines := append(head, kept...)
		lines = append(lines, body...)
		block, err := m.renderCodexBlock(profile.BaseURL)
		if err != nil {
			return nil, nil, err
		}
		content := strings.TrimRight(strings.Join(lines, "\n"), "\n")
		if content != "" {
			content += "\n\n"
		}
		content += block
		originalJSON, _ := json.Marshal(original)
		return []byte(content), originalJSON, nil
	default:
		return nil, nil, ErrInvalidInput
	}
}

// renderRestore computes the pre-switch content. When the file is still
// byte-identical to what the switch wrote and a backup of the pre-switch file
// exists, that backup is used. Otherwise only the managed region is reverted —
// Zhiban's keys and tables — so the user's later edits and the CLI's own
// additions survive; removeFile is true only when the file did not exist
// before the switch and nothing but Zhiban's region was in it.
func (m *Manager) renderRestore(targetID string, item globalManifest, current fileSnapshot) (content []byte, removeFile bool, err error) {
	if globalFamily(targetID) == familyClaudeDesktop {
		// The whole entry is Zhiban's: remove it. The backup this target
		// records is _meta.json (restored structurally by the caller as the
		// plan's extra file), so the backup shortcut below must not apply:
		// it wrote the library index into the entry file on the 2026-09-10
		// Windows machine, where an index already existed before the switch.
		return nil, true, nil
	}
	if !current.Exists {
		if !item.OriginalExisted {
			return nil, true, nil
		}
		if item.BackupFile != "" {
			backup, err := m.readBackup(item.BackupFile)
			return backup, false, err
		}
		return nil, false, ErrGlobalConflict
	}
	if item.AppliedSHA256 == current.SHA256 && item.OriginalExisted && item.BackupFile != "" {
		if backup, err := m.readBackup(item.BackupFile); err == nil {
			return backup, false, nil
		}
	}
	// Everything else is a structured revert of the managed region. That
	// includes a byte-identical file whose original did not exist: after a
	// re-switch the applied content may carry tables the CLI added in
	// between, and those must survive; the file goes only when nothing is left.
	switch globalFamily(targetID) {
	case familyClaudeCLI:
		root, err := decodeJSONObject(current.Bytes)
		if err != nil {
			return nil, false, ErrGlobalParseFailed
		}
		var original claudeGlobalOriginal
		if err := json.Unmarshal(item.Original, &original); err != nil {
			return nil, false, ErrGlobalNotSwitched
		}
		env, _ := root["env"].(map[string]any)
		if env == nil {
			env = map[string]any{}
		}
		for _, key := range claudeGlobalKeys {
			value := original.Values[key]
			applyClaudeKey(root, env, key, value)
		}
		restoreClaudeExtraCA(env, original.Values, m.systemCABundle)
		if len(env) == 0 && !original.EnvWasPresent {
			delete(root, "env")
		} else {
			root["env"] = env
		}
		if len(root) == 0 && !item.OriginalExisted {
			return nil, true, nil
		}
		content, err := encodeJSONObject(root)
		return content, false, err
	case familyCodex:
		var original codexGlobalOriginal
		if err := json.Unmarshal(item.Original, &original); err != nil {
			return nil, false, ErrGlobalNotSwitched
		}
		top, rest := splitCodexTopLevel(string(current.Bytes))
		kept := make([]string, 0, len(top))
		for _, line := range top {
			if codexTopLevelProvider.MatchString(line) || codexTopLevelModel.MatchString(line) || codexTopLevelCatalog.MatchString(line) ||
				codexTopLevelAnalytics.MatchString(line) || isCodexMarker(line) {
				continue
			}
			kept = append(kept, line)
		}
		head := []string{}
		if original.ModelProviderLine != nil {
			head = append(head, *original.ModelProviderLine)
		}
		if original.ModelLine != nil {
			head = append(head, *original.ModelLine)
		}
		if original.ModelCatalogLine != nil {
			head = append(head, *original.ModelCatalogLine)
		}
		if original.AnalyticsLine != nil {
			head = append(head, *original.AnalyticsLine)
		}
		body, _ := removeCodexManaged(rest)
		lines := append(head, kept...)
		lines = append(lines, body...)
		for len(lines) > 0 && strings.TrimSpace(lines[0]) == "" {
			lines = lines[1:] // the separator the switch put in front of its block
		}
		text := strings.TrimRight(strings.Join(lines, "\n"), "\n")
		if text == "" {
			if !item.OriginalExisted {
				return nil, true, nil
			}
			return []byte{}, false, nil
		}
		return []byte(text + "\n"), false, nil
	default:
		return nil, false, ErrInvalidInput
	}
}

func (m *Manager) renderCodexBlock(gatewayBaseURL string) (string, error) {
	return codexBlockBegin + "\n" +
		"[model_providers." + CodexGlobalProviderID + "]\n" +
		"name = \"Zhiban AI\"\n" +
		"base_url = " + strconv.Quote(gatewayBaseURL) + "\n" +
		"wire_api = \"responses\"\n" +
		"requires_openai_auth = false\n" +
		codexImageGenerationHeaderLine + "\n\n" +
		"[model_providers." + CodexGlobalProviderID + ".auth]\n" +
		"command = " + strconv.Quote(m.helperExecutable) + "\n" +
		"args = [\"credential\", \"get\", \"--target\", \"codex_cli\"]\n" +
		"timeout_ms = 5000\n" +
		"refresh_interval_ms = 300000\n", nil
}

// probeGlobal validates the switched file the way the CLI will read it: no
// --profile / --settings, so the global configuration itself is parsed.
func (m *Manager) probeGlobal(ctx context.Context, installation Installation) error {
	if installation.TargetID == TargetClaudeDesktop {
		// Nothing to run: the entry was rendered by Zhiban and parses by
		// construction; the app validates it at launch.
		return nil
	}
	if m.probeGlobalFunc != nil {
		return m.probeGlobalFunc(ctx, installation)
	}
	if installation.Executable == "" {
		// A desktop package whose core cannot be run here (Windows MSIX):
		// the config it shares with the CLI is validated by the CLI's probe.
		return nil
	}
	probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	var arguments []string
	switch installation.TargetID {
	case TargetCodexCLI, TargetCodexDesktop:
		// Codex Desktop bundles a CLI core, which
		// reads the same config.toml; desktopProbeInstallation pointed
		// Executable at it.
		arguments = []string{"mcp", "list"}
	case TargetClaudeCLI:
		arguments = []string{"--version"}
	default:
		return ErrInvalidInput
	}
	return m.runQuietProbe(probeCtx, installation.Executable, arguments)
}

func (m *Manager) writeBackup(targetID string, content []byte) (string, error) {
	name := targetID + "-" + m.now().UTC().Format("20060102-150405") + ".bak"
	path := filepath.Join(m.backupsDir(), name)
	if err := m.atomicWriteCAS(path, content, 0o600, fileSnapshot{}); err != nil {
		return "", err
	}
	m.rotateBackups(targetID)
	return name, nil
}

func (m *Manager) readBackup(name string) ([]byte, error) {
	if name == "" || strings.ContainsAny(name, "/\\") || strings.HasPrefix(name, ".") {
		return nil, ErrUnsafePath
	}
	snapshot, err := m.snapshot(filepath.Join(m.backupsDir(), name), false)
	if err != nil {
		return nil, err
	}
	if !snapshot.Exists {
		return nil, ErrGlobalConflict
	}
	return snapshot.Bytes, nil
}

func (m *Manager) rotateBackups(targetID string) {
	entries, err := os.ReadDir(m.backupsDir())
	if err != nil {
		return
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.Type().IsRegular() && strings.HasPrefix(entry.Name(), targetID+"-") && strings.HasSuffix(entry.Name(), ".bak") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	for len(names) > maxBackups {
		_ = os.Remove(filepath.Join(m.backupsDir(), names[0]))
		names = names[1:]
	}
}

func decodeGlobalManifest(targetID string, content []byte) (globalManifest, bool) {
	var item globalManifest
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&item) != nil || decoder.Decode(&struct{}{}) != io.EOF ||
		item.TargetID != manifestOwner(targetID) || item.FileKind != globalFileKind(targetID) ||
		!validSafeValue(item.ProfileVersion) || !validDigest(item.AppliedSHA256) ||
		(item.VerifiedConfigSHA256 != "" && !validDigest(item.VerifiedConfigSHA256)) ||
		(item.VerifiedManagedSHA256 != "" && !validDigest(item.VerifiedManagedSHA256)) {
		return globalManifest{}, false
	}
	if item.ModelCatalog != nil && (item.ModelCatalog.SHA256 != "" && !validDigest(item.ModelCatalog.SHA256) ||
		item.ModelCatalog.Enabled != (item.ModelCatalog.SHA256 != "") || len(item.ModelCatalog.Validated) > codexCatalogMaxExecutables) {
		return globalManifest{}, false
	}
	switch item.SchemaVersion {
	case globalManifestSchema, globalManifestSchemaModelRegion:
		if !validDigest(item.ManagedSHA256) {
			return globalManifest{}, false
		}
	case globalManifestSchemaLegacy:
		if item.ManagedSHA256 != "" || item.VerifiedManagedSHA256 != "" {
			return globalManifest{}, false
		}
	default:
		return globalManifest{}, false
	}
	return item, true
}

func decodeJSONObject(content []byte) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("trailing content")
	}
	root, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("not an object")
	}
	return root, nil
}

func encodeJSONObject(root map[string]any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(root); err != nil {
		return nil, ErrInvalidInput
	}
	return buffer.Bytes(), nil
}

func lookupClaudeKey(root, env map[string]any, key string) (any, bool) {
	if strings.HasPrefix(key, "env.") {
		value, ok := env[strings.TrimPrefix(key, "env.")]
		return value, ok
	}
	value, ok := root[key]
	return value, ok
}

func applyClaudeKey(root, env map[string]any, key string, value *json.RawMessage) {
	var decoded any
	present := value != nil
	if present {
		if json.Unmarshal(*value, &decoded) != nil {
			present = false
		}
	}
	if strings.HasPrefix(key, "env.") {
		name := strings.TrimPrefix(key, "env.")
		if present {
			env[name] = decoded
		} else {
			delete(env, name)
		}
		return
	}
	if present {
		root[key] = decoded
	} else {
		delete(root, key)
	}
}

func rawValue(value any, present bool) *json.RawMessage {
	if !present {
		return nil
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	raw := json.RawMessage(encoded)
	return &raw
}

// splitCodexTopLevel returns the lines before the first table header and the rest.
func splitCodexTopLevel(text string) ([]string, []string) {
	if text == "" {
		return nil, nil
	}
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	for index, line := range lines {
		if codexTableHeader.MatchString(line) {
			return lines[:index], lines[index:]
		}
	}
	return lines, nil
}

// removeCodexManaged drops the Zhiban-owned tables
// ([model_providers.zhiban_ai_managed] and its .auth table, each up to the
// next table header) and the marker comments from the lines that follow the
// top-level section, and reports whether such a table was present. Every
// other table is kept in place — including ones Codex appended after the
// switch, such as [projects."…"], even when an older build's end marker put
// them "inside" the block.
func removeCodexManaged(lines []string) ([]string, bool) {
	result := make([]string, 0, len(lines))
	hadManaged := false
	skipping := false
	for _, line := range lines {
		if isCodexMarker(line) {
			continue
		}
		if codexTableHeader.MatchString(line) {
			wasSkipping := skipping
			skipping = codexZhibanTable.MatchString(line)
			if skipping {
				hadManaged = true
			} else if wasSkipping && len(result) > 0 && strings.TrimSpace(result[len(result)-1]) != "" {
				result = append(result, "") // keep tables visually separated where ours sat between them
			}
		}
		if skipping {
			continue
		}
		result = append(result, line)
	}
	for len(result) > 0 && strings.TrimSpace(result[len(result)-1]) == "" {
		result = result[:len(result)-1]
	}
	return result, hadManaged
}

// isCodexMarker matches Zhiban's marker comments by prefix: older builds wrote
// other text after it, and a Windows file seen on 2026-09-15 carried one whose
// Chinese had been re-encoded into mojibake by another writer, which an exact
// match left behind after every restore.
func isCodexMarker(line string) bool {
	trimmed := strings.TrimSpace(line)
	return strings.HasPrefix(trimmed, codexMarkerBeginPrefix) || strings.HasPrefix(trimmed, codexMarkerEndPrefix)
}

const (
	codexMarkerBeginPrefix = "# >>> zhiban-ai-managed"
	codexMarkerEndPrefix   = "# <<< zhiban-ai-managed"
)

// managedFingerprint hashes the managed region of a global configuration —
// the keys and tables the switch owns and nothing else. Two files with the
// same fingerprint route the tool identically as far as Zhiban is concerned;
// anything the CLI or the user changes outside the region is not drift.
func managedFingerprint(targetID string, content []byte) (string, error) {
	switch globalFamily(targetID) {
	case familyClaudeCLI:
		return claudeManagedFingerprint(content)
	case familyClaudeDesktop:
		return claudeDesktopFingerprint(content)
	case familyCodex:
		return codexManagedFingerprint(content), nil
	default:
		return "", ErrInvalidInput
	}
}

// sameManagedRegion reports whether two file contents carry the same managed region.
func sameManagedRegion(targetID string, left, right []byte) bool {
	if bytes.Equal(left, right) {
		return true
	}
	leftPrint, err := managedFingerprint(targetID, left)
	if err != nil {
		return false
	}
	rightPrint, err := managedFingerprint(targetID, right)
	return err == nil && leftPrint == rightPrint
}

// claudeManagedFingerprint covers exactly claudeRegionKeys, each with its
// presence and canonical JSON value, in fixed order.
func claudeManagedFingerprint(content []byte) (string, error) {
	return claudeKeysFingerprint(content, claudeRegionKeys, nil)
}

// claudeKeysFingerprint fingerprints keys; model, when given, stands in for
// the file's model value (schema 2 comparison).
func claudeKeysFingerprint(content []byte, keys []string, model *string) (string, error) {
	root, err := decodeJSONObject(content)
	if err != nil {
		return "", ErrGlobalParseFailed
	}
	env, _ := root["env"].(map[string]any)
	type entry struct {
		Key     string `json:"key"`
		Present bool   `json:"present"`
		Value   any    `json:"value"`
	}
	entries := make([]entry, 0, len(keys))
	for _, key := range keys {
		value, present := lookupClaudeKey(root, env, key)
		if key == "model" && model != nil {
			value, present = *model, true
		}
		if !present {
			value = nil
		}
		entries = append(entries, entry{Key: key, Present: present, Value: value})
	}
	encoded, err := json.Marshal(entries)
	if err != nil {
		return "", ErrGlobalParseFailed
	}
	return digest(encoded), nil
}

// codexManagedFingerprint covers the top-level model_provider line and the
// bodies of the two [model_providers.zhiban_ai_managed] tables, in file order,
// with blank and comment lines dropped so the markers and any reformatting
// Codex applies elsewhere do not count. Pointing the provider or the table at
// anything else changes the fingerprint; the model Codex writes back from
// /model and the model catalog line do not.
func codexManagedFingerprint(content []byte) string {
	return codexRegionFingerprint(content, false, nil)
}

// codexRegionFingerprint optionally includes the model line (schema 2), with
// model standing in for the file's value when given.
func codexRegionFingerprint(content []byte, includeModel bool, model *string) string {
	top, rest := splitCodexTopLevel(string(content))
	region := make([]string, 0, 16)
	sawModel := false
	for _, line := range top {
		switch {
		case codexTopLevelProvider.MatchString(line):
			region = append(region, strings.TrimSpace(line))
		case includeModel && codexTopLevelModel.MatchString(line):
			sawModel = true
			if model != nil {
				region = append(region, "model = "+strconv.Quote(*model))
			} else {
				region = append(region, strings.TrimSpace(line))
			}
		}
	}
	if includeModel && !sawModel && model != nil {
		region = append(region, "model = "+strconv.Quote(*model))
	}
	inside := false
	for _, line := range rest {
		if codexTableHeader.MatchString(line) {
			inside = codexZhibanTable.MatchString(line)
		}
		trimmed := strings.TrimSpace(line)
		if !inside || trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		region = append(region, trimmed)
	}
	return digest([]byte(strings.Join(region, "\n")))
}

func fileModeOr(snapshot fileSnapshot, fallback os.FileMode) os.FileMode {
	if snapshot.Exists && snapshot.Mode != 0 {
		return snapshot.Mode
	}
	return fallback
}
