package hermes

// HermesLayout implements controlplane.WorkspaceLayout for the Hermes runtime framework.
// Hermes uses a single flat workspace root at /opt/data (no per-agent subdirectories).
type HermesLayout struct{}

// WorkspacePath returns /opt/data. Hermes has a single workspace root shared by all agents.
func (HermesLayout) WorkspacePath(_ string) string {
	return "/opt/data"
}

// AgentDirPath returns /opt/data. Hermes identity files live at the workspace root.
func (HermesLayout) AgentDirPath(_ string) string {
	return "/opt/data"
}

// SkillsDir returns /opt/data/skills.
func (HermesLayout) SkillsDir(_ string) string {
	return "/opt/data/skills"
}
