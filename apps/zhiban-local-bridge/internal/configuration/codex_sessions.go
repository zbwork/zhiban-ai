package configuration

// Codex threads after "恢复官方配置" (contract §2.7.2 "Codex 恢复官方配置后的历史
// 会话", 2026-09-18): every thread created while the file routed to Zhiban
// names zhiban_ai_managed in Codex's index database, and the desktop app
// re-loads the configuration with that id when the thread is opened — once
// the provider table is gone the thread cannot be opened at all. After the
// restore succeeds the threads are re-pointed at the provider the restore
// brought back (codexsessions.Remap). The app only reads the index afresh
// after a restart, which the App's restore banner already asks for.
//
// The other direction (2026-09-21, contract same entry): a thread continues
// on the provider it records, not on the one config.toml names. After
// 知办 → 恢复官方 → 知办 the Zhiban-period threads still named openai and kept
// connecting to wss://chatgpt.com — "reconnecting" for ever on a machine that
// cannot reach it. The product decision: threads follow the side the user
// switched to, all of them (syncCodexSessionsToZhiban).

import (
	"context"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/codexsessions"
)

// codexDefaultProviderID is what Codex uses when config.toml names none.
const codexDefaultProviderID = "openai"

// restoredCodexProviderID returns the provider id the restored config.toml
// resolves to: its top-level model_provider line, else Codex's default.
func restoredCodexProviderID(restored []byte, removed bool) string {
	if removed {
		return codexDefaultProviderID
	}
	top, _ := splitCodexTopLevel(string(restored))
	for _, line := range top {
		if codexTopLevelProvider.MatchString(line) {
			if value := codexLineValue(line); value != "" {
				return value
			}
		}
	}
	return codexDefaultProviderID
}

// remapCodexSessionsAfterRestore re-points the Zhiban-period threads and
// reports the counts on the status. It never fails the restore.
func (m *Manager) remapCodexSessionsAfterRestore(ctx context.Context, status Status, restored []byte, removed bool) Status {
	toID := restoredCodexProviderID(restored, removed)
	result := codexsessions.Remap(ctx, m.codexHome, CodexGlobalProviderID, toID, time.Now())
	if result.IndexRows > 0 {
		status.CodexSessionsIndexed = result.IndexRows
	}
	status.CodexSessionsRemapped = result.Rollouts
	status.CodexSessionsSkipped = result.SkippedActive
	status.CodexSessionsErrors = result.Errors
	return status
}

// syncCodexSessionsToZhiban re-points every thread still recorded under the
// official provider — and under the provider the user's own file named before
// the switch, which is where a restore sends the Zhiban-period threads — at
// Zhiban's. It runs after a verification passed, not at the switch: threads
// only move once the relay has been shown to work, and a user already stuck
// in this state (he will not switch again) is healed by the next check.
// Best effort, like the restore direction: a verification never fails on it.
func (m *Manager) syncCodexSessionsToZhiban(ctx context.Context, item globalManifest) {
	from := []string{codexDefaultProviderID}
	if item.OriginalExisted && item.BackupFile != "" {
		if backup, err := m.readBackup(item.BackupFile); err == nil {
			if own := restoredCodexProviderID(backup, false); own != codexDefaultProviderID {
				from = append(from, own)
			}
		}
	}
	for _, fromID := range from {
		if fromID == CodexGlobalProviderID {
			continue
		}
		// The wall clock, as in the restore direction: rollout modification
		// times are real ones, whatever clock the manager was given. Every run
		// looks at the rollouts again (first line only): one skipped as active
		// last time — index row already moved — must not stay behind, or an
		// index rebuilt from the rollouts brings the old provider back.
		codexsessions.Remap(ctx, m.codexHome, fromID, CodexGlobalProviderID, time.Now())
	}
}
