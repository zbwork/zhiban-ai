package controlplane

import "strings"

// WorkspaceLayout generates framework-specific workspace paths for agents and skills.
type WorkspaceLayout interface {
	WorkspacePath(agentKey string) string
	AgentDirPath(agentKey string) string
	SkillsDir(agentKey string) string
}

// LayoutRegistry maps framework names to their WorkspaceLayout.
type LayoutRegistry struct {
	layouts map[string]WorkspaceLayout
}

// LayoutEntry pairs a framework name with its WorkspaceLayout.
type LayoutEntry struct {
	Framework string
	Layout    WorkspaceLayout
}

// NewLayoutRegistry creates a LayoutRegistry from the given entries.
func NewLayoutRegistry(entries ...LayoutEntry) *LayoutRegistry {
	r := &LayoutRegistry{layouts: make(map[string]WorkspaceLayout, len(entries))}
	for _, e := range entries {
		r.layouts[strings.ToLower(e.Framework)] = e.Layout
	}
	return r
}

// For returns the layout for the given framework. Returns nil if not registered.
func (r *LayoutRegistry) For(framework string) WorkspaceLayout {
	if r == nil {
		return nil
	}
	return r.layouts[strings.ToLower(framework)]
}

// OverrideAgentSpec replaces WorkspacePath/AgentDirPath in spec using the layout for the
// given framework. If the framework has no registered layout, spec is returned unchanged.
func (r *LayoutRegistry) OverrideAgentSpec(framework string, spec AgentSpec) AgentSpec {
	l := r.For(framework)
	if l == nil {
		return spec
	}
	spec.WorkspacePath = l.WorkspacePath(spec.AgentKey)
	spec.AgentDirPath = l.AgentDirPath(spec.AgentKey)
	return spec
}

// OverrideSkillSpec replaces WorkspacePath in spec using the layout for the given framework.
// If the framework has no registered layout, spec is returned unchanged.
func (r *LayoutRegistry) OverrideSkillSpec(framework string, spec SkillSpec) SkillSpec {
	l := r.For(framework)
	if l == nil {
		return spec
	}
	spec.WorkspacePath = l.WorkspacePath(spec.AgentKey)
	return spec
}

// OverrideSkillUninstallSpec replaces WorkspacePath in spec using the layout for the
// given framework. If the framework has no registered layout, spec is returned unchanged.
func (r *LayoutRegistry) OverrideSkillUninstallSpec(framework string, spec SkillUninstallSpec) SkillUninstallSpec {
	l := r.For(framework)
	if l == nil {
		return spec
	}
	spec.WorkspacePath = l.WorkspacePath(spec.AgentKey)
	return spec
}
