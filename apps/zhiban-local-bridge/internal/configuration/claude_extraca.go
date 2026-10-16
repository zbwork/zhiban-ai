package configuration

// Claude Code's extra root certificates (contract §2.7.2 "Claude Code 的根证书
// 补充", 2026-09-17, macOS). From 2.1.26x on Claude Code merges the keychain's
// certificates into its bundled store. A cross-signed "DigiCert Global Root
// G2" left in the login keychain sends the path to the old "DigiCert Global
// Root CA", which the bundled store no longer has, and every DigiCert-G2 site
// — the Zhiban gateway among them — fails in a second with "SSL certificate
// verification failed" (two production users; 2.1.263 / 2.1.267 / 2.1.274 all
// fail on such a machine, so a newer catalog version does not help).
//
// NODE_EXTRA_CA_CERTS pointing at the system's own root bundle puts the old
// root back. It only ever adds trust, so users who were never affected see no
// change. The key is outside the managed-region fingerprint: replacing it with
// a corporate bundle is not drift, its absence is global_upgrade_available.

import (
	"encoding/json"
	"os"
	"runtime"
)

const (
	claudeExtraCAName = "NODE_EXTRA_CA_CERTS"
	claudeExtraCAKey  = "env." + claudeExtraCAName
	macOSRootBundle   = "/etc/ssl/cert.pem"
)

// detectSystemCABundle returns the root bundle the switch points Claude Code
// at, or "" where there is none to offer (Windows; a macOS without the file).
func detectSystemCABundle() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	if info, err := os.Stat(macOSRootBundle); err != nil || !info.Mode().IsRegular() {
		return ""
	}
	return macOSRootBundle
}

// ensureClaudeExtraCA writes the bundle unless the user already names one of
// their own (an enterprise proxy's certificates), which is left alone.
func ensureClaudeExtraCA(env map[string]any, bundle string) {
	if bundle == "" {
		return
	}
	if _, present := env[claudeExtraCAName]; !present {
		env[claudeExtraCAName] = bundle
	}
}

// claudeExtraCAMissing reports whether a switched settings.json still lacks
// the key on a platform that has a bundle to offer.
func claudeExtraCAMissing(env map[string]any, bundle string) bool {
	if bundle == "" {
		return false
	}
	_, present := env[claudeExtraCAName]
	return !present
}

// claudeExtraCACurrent reports whether rewriting would leave the key as it
// is. It is outside the managed-region fingerprint, so the plan has to ask
// separately before it answers action "none".
func claudeExtraCACurrent(targetID string, before, desired []byte) bool {
	if globalFamily(targetID) != familyClaudeCLI {
		return true
	}
	beforeRoot, err := decodeJSONObject(before)
	if err != nil {
		return false
	}
	desiredRoot, err := decodeJSONObject(desired)
	if err != nil {
		return false
	}
	return nestedEnv(beforeRoot)[claudeExtraCAName] == nestedEnv(desiredRoot)[claudeExtraCAName]
}

// adoptExtraCAOriginal completes the originals of a manifest written before
// the switch knew this key (1.2.6 and earlier). Such a Bridge never touched
// it, so what the file holds just before this re-switch is still the user's
// own value (usually none): record it once and "恢复官方配置" returns exactly
// that. A key the first switch already recorded stays as recorded.
func adoptExtraCAOriginal(previous, beforeThisSwitch json.RawMessage) json.RawMessage {
	var recorded, current claudeGlobalOriginal
	if json.Unmarshal(previous, &recorded) != nil || json.Unmarshal(beforeThisSwitch, &current) != nil || recorded.Values == nil {
		return previous
	}
	if _, known := recorded.Values[claudeExtraCAKey]; known {
		return previous
	}
	value, seen := current.Values[claudeExtraCAKey]
	if !seen {
		return previous
	}
	recorded.Values[claudeExtraCAKey] = value
	encoded, err := json.Marshal(recorded)
	if err != nil {
		return previous
	}
	return encoded
}

// restoreClaudeExtraCA reverts the key: to the recorded original when the
// manifest has one, otherwise (a Zhiban-routed file whose manifest is gone)
// only a value that is the bundle Zhiban writes is removed.
func restoreClaudeExtraCA(env map[string]any, original map[string]*json.RawMessage, bundle string) {
	if value, recorded := original[claudeExtraCAKey]; recorded {
		applyClaudeKey(nil, env, claudeExtraCAKey, value)
		return
	}
	if text, isText := env[claudeExtraCAName].(string); isText && bundle != "" && text == bundle {
		delete(env, claudeExtraCAName)
	}
}
