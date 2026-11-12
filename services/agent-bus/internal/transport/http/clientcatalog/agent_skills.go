package clientcatalog

import (
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"strings"
)

func ApplyAgentSkillBindingCapabilities(out map[string]any, e *domagent.DigitalEmployee, accountID int64, framework string) {
	// ZAP-1.1 §11 接通后 (ADR-0035 修订), zap/dsh 员工都支持客户端技能绑定; 仅 support_builtin 内置客服不支持。
	supports := !isSupportBuiltinForSkillBindings(e)
	out["supports_model_selection"] = !isSupportBuiltinForSkillBindings(e) && (e.ExecutionLocus == "local" || framework == "openclaw" || framework == "hermes" || framework == "dsh")
	out["supports_skill_bindings"] = supports
	out["can_manage_skills"] = supports && accountID > 0 && e.CreatorID == accountID
}

func isSupportBuiltinForSkillBindings(e *domagent.DigitalEmployee) bool {
	if e == nil || e.Metadata == nil {
		return false
	}
	runtimeKind, _ := e.Metadata["runtime_kind"].(string)
	agentKey, _ := e.Metadata["agent_key"].(string)
	return strings.EqualFold(strings.TrimSpace(runtimeKind), "support_builtin") ||
		strings.EqualFold(strings.TrimSpace(agentKey), "zhiban-support")
}

// AgentSkillBindingMaps AgentBindingView → 客户端 skills DTO。
// clientAgentDetail（逐条）与 clientAgentDetailsForList（批量）共用，保证两路径字段永远一致。
func AgentSkillBindingMaps(views []domskill.AgentBindingView, resolvedIcons map[string]string) []map[string]any {
	skills := make([]map[string]any, 0, len(views))
	for _, view := range views {
		if view.Skill == nil {
			continue
		}
		iconURL := view.Skill.IconURL
		if resolved, ok := resolvedIcons[view.Skill.IconURL]; ok {
			iconURL = resolved
		}
		skills = append(skills, map[string]any{
			"slug":         view.Skill.Code,
			"name":         view.Skill.Name,
			"skillName":    view.Skill.Name,
			"status":       view.Skill.Status,
			"isInstalled":  true,
			"iconUrl":      iconURL,
			"billing_type": view.Skill.BillingType,
			"pricing_mode": view.Skill.PricingMode,
		})
	}
	return skills
}
