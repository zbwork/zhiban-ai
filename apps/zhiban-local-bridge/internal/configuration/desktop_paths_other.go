//go:build !windows

package configuration

import "path/filepath"

// claudeDesktopSupportRoot is where Claude Desktop keeps its third-party
// configuration on macOS: ~/Library/Application Support/Claude-3p.
func (m *Manager) claudeDesktopSupportRoot() string {
	return filepath.Join(m.homeDir, "Library", "Application Support", claudeDesktopSupportDir)
}

// claudeDesktopHelperPath is the no-argument credential helper the app runs.
func (m *Manager) claudeDesktopHelperPath() string {
	return filepath.Join(m.homeDir, "Library", "Application Support", applicationSupportID, "local-coding-tools", claudeDesktopHelperName)
}

// ensureClaudeDesktopHelper writes (or refreshes) the one-line shell wrapper
// that execs the Bridge with the fixed credential arguments.
func (m *Manager) ensureClaudeDesktopHelper() error {
	quoted, err := shellQuote(m.helperExecutable)
	if err != nil {
		return err
	}
	content := []byte("#!/bin/sh\n# Written by Zhiban AI for Claude Desktop (inferenceCredentialHelper).\nexec " + quoted + " credential get --target " + TargetClaudeDesktop + "\n")
	path := m.claudeDesktopHelperPath()
	current, err := m.snapshot(path, true)
	if err != nil {
		return err
	}
	if current.Exists && string(current.Bytes) == string(content) && current.Mode.Perm() == 0o700 {
		return nil
	}
	return m.atomicWriteCAS(path, content, 0o700, current)
}
