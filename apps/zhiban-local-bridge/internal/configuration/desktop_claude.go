package configuration

// Claude Desktop (M3, target claude_desktop). Claude Desktop reads its
// single-machine third-party inference configuration from the "config
// library": ~/Library/Application Support/Claude-3p/configLibrary/_meta.json
// names the applied entry and <id>.json holds that entry's keys (spike S2,
// 2026-09-09). Zhiban owns exactly one entry with a fixed id: switching writes
// that file and points appliedId at it; the user's own entries are never
// edited. Restoring removes Zhiban's entry and points appliedId back.
//
// The credential helper must be an executable that runs with no arguments and
// prints the token, and it must not live under Desktop/Documents/Downloads
// (macOS TCC blocks the app there), so the Bridge writes a one-line wrapper in
// its own Application Support directory that execs itself with the fixed
// `credential get --target claude_desktop` arguments.

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
)

const (
	// ZhibanClaudeDesktopConfigID is the configLibrary entry Zhiban owns.
	ZhibanClaudeDesktopConfigID   = "5a7d0b3c-2e41-4c8f-9b16-3f0e8d6a2c19"
	zhibanClaudeDesktopConfigName = "知办 AI"
	// The account area at the bottom-left of Claude.app shows
	// deploymentDisplayName / deploymentDisplaySubtitle in third-party mode
	// (schema keys since 1.24012.0; older builds drop unknown keys with a
	// notice). Without them the app falls back to the machine name (test Mac,
	// 2026-09-17) while Codex shows "Zhiban AI" from its provider name.
	zhibanClaudeDesktopDeploymentName     = "知办 AI"
	zhibanClaudeDesktopDeploymentSubtitle = "知办模型 API"
	claudeDesktopSupportDir               = "Claude-3p"
	claudeDesktopLibraryDir               = "configLibrary"
	claudeDesktopMetaFile                 = "_meta.json"
	claudeDesktopHelperName               = "claude-desktop-credential"
	// ClaudeDesktopHelperExecutable is the file name the Bridge copies itself
	// to for Claude Desktop on Windows. The app executes
	// inferenceCredentialHelper with execFile and no arguments, so a shell
	// wrapper is not an option there; a second copy of the Bridge under this
	// name recognises itself by its file name at startup and behaves as
	// `credential get --target claude_desktop` (cmd/zhiban-local-bridge).
	ClaudeDesktopHelperExecutable = "zhiban-claude-desktop-helper.exe"
	claudeDesktopHelperTTLSeconds = 600
	fileKindClaudeDesktopLibrary  = "claude_desktop_config_library"
)

// claudeDesktopManagedKeys is the managed region of Zhiban's library entry.
var claudeDesktopManagedKeys = []string{
	"inferenceProvider", "inferenceGatewayBaseUrl", "inferenceCredentialKind", "inferenceCredentialHelper",
	"inferenceCredentialHelperTtlSec", "inferenceModels", "chatTabEnabled", "modelDiscoveryEnabled",
}

// claudeDesktopManagedKeysV2 is the schema 2 region, before model discovery.
var claudeDesktopManagedKeysV2 = []string{
	"inferenceProvider", "inferenceGatewayBaseUrl", "inferenceCredentialKind", "inferenceCredentialHelper",
	"inferenceCredentialHelperTtlSec", "inferenceModels", "chatTabEnabled",
}

// claudeDesktopOriginal records what the switch changed in _meta.json.
type claudeDesktopOriginal struct {
	MetaExisted       bool   `json:"meta_existed"`
	PreviousAppliedID string `json:"previous_applied_id"`
}

// claudeDesktopLibraryDir is the config library under the platform's
// Claude-3p root (desktop_paths_other.go / desktop_paths_windows.go, which
// also hold the credential helper's location and how it is written).
func (m *Manager) claudeDesktopLibraryDir() string {
	return filepath.Join(m.claudeDesktopSupportRoot(), claudeDesktopLibraryDir)
}

func (m *Manager) claudeDesktopConfigPath() string {
	return filepath.Join(m.claudeDesktopLibraryDir(), ZhibanClaudeDesktopConfigID+".json")
}

func (m *Manager) claudeDesktopMetaPath() string {
	return filepath.Join(m.claudeDesktopLibraryDir(), claudeDesktopMetaFile)
}

// renderClaudeDesktopConfig is the full content of Zhiban's library entry.
func (m *Manager) renderClaudeDesktopConfig(profile GatewayProfile) ([]byte, error) {
	if strings.TrimSpace(profile.Model) == "" {
		return nil, ErrProfileUnavailable
	}
	root := map[string]any{
		"inferenceProvider":               "gateway",
		"inferenceGatewayBaseUrl":         profile.BaseURL,
		"inferenceCredentialKind":         "helper-script",
		"inferenceCredentialHelper":       m.claudeDesktopHelperPath(),
		"inferenceCredentialHelperTtlSec": claudeDesktopHelperTTLSeconds,
		"chatTabEnabled":                  true,
		// The app fills its model picker from the gateway's model list at
		// launch: the relay group decides which models appear (contract §2.7.2).
		// No inferenceModels: when that list is non-empty the app shows only
		// it and uses discovery just to label its entries (1.49585.0, test Mac
		// 2026-09-15: "10 found … picker = 1 (inferenceModels)").
		"modelDiscoveryEnabled": true,
		// Not part of the managed region on purpose: an entry written before
		// these keys existed is "upgrade available" (the App rewrites it in the
		// background), never "drifted".
		"deploymentDisplayName":     zhibanClaudeDesktopDeploymentName,
		"deploymentDisplaySubtitle": zhibanClaudeDesktopDeploymentSubtitle,
	}
	return encodeJSONObject(root)
}

// claudeDesktopService reports whether Zhiban's library entry routes to the
// Zhiban gateway through the Bridge helper. Whether the entry is the applied
// one is checked separately against _meta.json.
func (m *Manager) claudeDesktopService(content []byte) (string, error) {
	root, err := decodeJSONObject(content)
	if err != nil {
		return ServiceUnknown, err
	}
	provider, _ := root["inferenceProvider"].(string)
	baseURL, _ := root["inferenceGatewayBaseUrl"].(string)
	helper, _ := root["inferenceCredentialHelper"].(string)
	if provider == "gateway" && m.isZhibanGateway(TargetClaudeDesktop, baseURL) && helper == m.claudeDesktopHelperPath() {
		return ServiceZhiban, nil
	}
	return ServiceOfficial, nil
}

// claudeDesktopApplied reports whether _meta.json points at Zhiban's entry.
func (m *Manager) claudeDesktopApplied() bool {
	meta, err := m.snapshot(m.claudeDesktopMetaPath(), false)
	if err != nil || !meta.Exists {
		return false
	}
	root, err := decodeJSONObject(meta.Bytes)
	if err != nil {
		return false
	}
	applied, _ := root["appliedId"].(string)
	return applied == ZhibanClaudeDesktopConfigID
}

// claudeDesktopFingerprint covers the managed keys of Zhiban's entry.
func claudeDesktopFingerprint(content []byte) (string, error) {
	return claudeDesktopKeysFingerprint(content, claudeDesktopManagedKeys)
}

func claudeDesktopKeysFingerprint(content []byte, keys []string) (string, error) {
	root, err := decodeJSONObject(content)
	if err != nil {
		return "", ErrGlobalParseFailed
	}
	type entry struct {
		Key     string `json:"key"`
		Present bool   `json:"present"`
		Value   any    `json:"value"`
	}
	entries := make([]entry, 0, len(keys))
	for _, key := range keys {
		value, present := root[key]
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

// claudeDesktopMetaSwitch computes _meta.json with Zhiban's entry present and
// applied, preserving every other field and entry.
func (m *Manager) claudeDesktopMetaSwitch(before fileSnapshot) ([]byte, claudeDesktopOriginal, error) {
	root := map[string]any{}
	original := claudeDesktopOriginal{MetaExisted: before.Exists}
	if before.Exists {
		decoded, err := decodeJSONObject(before.Bytes)
		if err != nil {
			return nil, original, ErrGlobalParseFailed
		}
		root = decoded
		original.PreviousAppliedID, _ = root["appliedId"].(string)
		if original.PreviousAppliedID == ZhibanClaudeDesktopConfigID {
			// Re-switching (or adopting) an index that already applies Zhiban's
			// entry: restore must never point back at it.
			original.PreviousAppliedID = ""
		}
	}
	entries, _ := root["entries"].([]any)
	if _, exists := root["entries"]; exists && entries == nil {
		return nil, original, ErrGlobalParseFailed
	}
	found := false
	for _, item := range entries {
		entry, ok := item.(map[string]any)
		if !ok {
			return nil, original, ErrGlobalParseFailed
		}
		if id, _ := entry["id"].(string); id == ZhibanClaudeDesktopConfigID {
			entry["name"] = zhibanClaudeDesktopConfigName
			found = true
		}
	}
	if !found {
		entries = append(entries, map[string]any{"id": ZhibanClaudeDesktopConfigID, "name": zhibanClaudeDesktopConfigName})
	}
	root["entries"] = entries
	root["appliedId"] = ZhibanClaudeDesktopConfigID
	content, err := encodeJSONObject(root)
	return content, original, err
}

// claudeDesktopMetaRestore computes _meta.json without Zhiban's entry, with
// appliedId pointing back at what it was (or the first remaining entry). It
// reports removeFile when nothing is left and Zhiban created the file.
func (m *Manager) claudeDesktopMetaRestore(item globalManifest, now fileSnapshot) (content []byte, removeFile bool, err error) {
	var original claudeDesktopOriginal
	if err := json.Unmarshal(item.Original, &original); err != nil {
		return nil, false, ErrGlobalNotSwitched
	}
	if !now.Exists {
		return nil, false, nil
	}
	root, err := decodeJSONObject(now.Bytes)
	if err != nil {
		return nil, false, ErrGlobalParseFailed
	}
	entries, _ := root["entries"].([]any)
	kept := make([]any, 0, len(entries))
	previousStillThere := false
	for _, item := range entries {
		entry, ok := item.(map[string]any)
		if !ok {
			return nil, false, ErrGlobalParseFailed
		}
		id, _ := entry["id"].(string)
		if id == ZhibanClaudeDesktopConfigID {
			continue
		}
		if id == original.PreviousAppliedID && id != "" {
			previousStillThere = true
		}
		kept = append(kept, entry)
	}
	if len(kept) == 0 && !original.MetaExisted {
		return nil, true, nil
	}
	root["entries"] = kept
	applied, _ := root["appliedId"].(string)
	if applied == ZhibanClaudeDesktopConfigID || applied == "" {
		switch {
		case previousStillThere:
			root["appliedId"] = original.PreviousAppliedID
		case len(kept) > 0:
			first, _ := kept[0].(map[string]any)
			root["appliedId"], _ = first["id"].(string)
		default:
			root["appliedId"] = ""
		}
	}
	content, err = encodeJSONObject(root)
	return content, false, err
}

var errClaudeDesktopMetaChanged = errors.New("configuration: claude desktop config library changed")
