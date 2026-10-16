package agentctl

// OpenClawLayout implements controlplane.WorkspaceLayout for the OpenClaw runtime framework.
// It returns the same paths as the package-level WorkspacePath / AgentDirPath functions
// (local mode paths; see ctl.go).
type OpenClawLayout struct{}

// WorkspacePath returns /data/.openclaw/workspace/<agentKey> (local mode).
func (OpenClawLayout) WorkspacePath(agentKey string) string {
	return WorkspacePath(agentKey)
}

// AgentDirPath returns /data/.openclaw/agents/<agentKey>/agent (local mode).
func (OpenClawLayout) AgentDirPath(agentKey string) string {
	return AgentDirPath(agentKey)
}

// SkillsDir returns /data/.openclaw/workspace/<agentKey>/skills (local mode).
func (OpenClawLayout) SkillsDir(agentKey string) string {
	return WorkspacePath(agentKey) + "/skills"
}
