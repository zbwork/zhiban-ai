// inheritance.go — 默认装配继承算法 (M6 §3.5 + Phase A §4.3).
//
// 触发时机:
//  1. 新建 agent (M3 wizard publish) — 由 svcagent 调; Phase A 没接入(留 Phase B).
//  2. admin reset-defaults endpoint — POST /api/admin/v1/tenant/agents/:uuid/capabilities/reset-defaults
//
// 算法 (与 M6 §3.5 伪代码一致):
//   - self_hosted → 装配池空 (boundaries §2.3, 平台 skill 一律不可借用)
//   - 对每个 is_system=true skill / app:
//     1. hosting 过滤 (available_to_platform_managed / available_to_hybrid)
//     2. 兼容矩阵 (compatibility.required_models / .required_runtimes / .blocked_agent_tags)
//     3. 租户强开关 (tenant_composer_defaults.behavior)
//     4. 装配: source='borrow', pinned = skill.default_pinned, sort_order = skill.sort_order
package composer

import "context"

func (s *impl) DeriveDefaultBindings(ctx context.Context, agent *AgentInfo) ([]Binding, error) {
	if agent == nil {
		return nil, nil
	}
	if integrationModeOrDefault(agent.IntegrationMode) == "self_hosted" {
		return []Binding{}, nil
	}

	out := []Binding{}

	skills, err := s.repo.ListSkills(ctx, true) // 仅平台预置 (is_system=true)
	if err != nil {
		return nil, err
	}
	for i := range skills {
		sk := &skills[i]
		if !s.skillDefaultEligible(sk, agent) {
			continue
		}
		attached := sk.DefaultAttached
		behavior, ok, err := s.repo.GetTenantComposerDefault(ctx, agent.TenantID, sk.ID)
		if err != nil {
			return nil, err
		}
		if ok {
			switch behavior {
			case "force_on":
				attached = true
			case "force_off":
				attached = false
			}
		}
		if !attached {
			continue
		}
		out = append(out, Binding{
			DigitalEmpID:   agent.ID,
			CapabilityKind: "composer_skill",
			CapabilityUUID: sk.UUID,
			SortOrder:      0, // Phase A: 按 skill 默认排序; admin 可后续 PATCH
			Pinned:         sk.DefaultPinned,
		})
	}

	apps, err := s.repo.ListApps(ctx, true)
	if err != nil {
		return nil, err
	}
	for i := range apps {
		a := &apps[i]
		if !s.appDefaultEligible(a, agent) {
			continue
		}
		attached := a.DefaultAttached
		behavior, ok, err := s.repo.GetTenantAppDefault(ctx, agent.TenantID, a.ID)
		if err != nil {
			return nil, err
		}
		if ok {
			switch behavior {
			case "force_on":
				attached = true
			case "force_off":
				attached = false
			}
		}
		if !attached {
			continue
		}
		out = append(out, Binding{
			DigitalEmpID:   agent.ID,
			CapabilityKind: "app",
			CapabilityUUID: a.UUID,
			SortOrder:      0,
			Pinned:         a.DefaultPinned,
		})
	}

	return out, nil
}

// ListAvailableCapabilities 返回所有 hosting + 兼容矩阵 通过的 system skill / app
// (Phase A: tenant 自建 skill/app 不在 Phase A scope, 不出现在 available pool).
//
// 与 DeriveDefaultBindings 区别: 不读 default_attached, 不读 tenant force_on/off —
// 这是 "可装池", 管理员可手动装的全部候选; 是否默认装走 reset-defaults 算法.
//
// Phase A 限制:
//   - 仅返回 is_system=true (tenant_id IS NULL) 的 skill/app
//   - status='published' (skill) / 'active' (app) 才出现
//   - tenant force_off 不影响 available (管理员仍可看到, 知道存在; reset-defaults 才会跳)
func (s *impl) ListAvailableCapabilities(ctx context.Context, agent *AgentInfo) ([]Binding, error) {
	if agent == nil {
		return nil, nil
	}
	if integrationModeOrDefault(agent.IntegrationMode) == "self_hosted" {
		return []Binding{}, nil
	}
	out := []Binding{}

	skills, err := s.repo.ListSkills(ctx, true)
	if err != nil {
		return nil, err
	}
	for i := range skills {
		sk := &skills[i]
		if !s.skillDefaultEligible(sk, agent) {
			continue
		}
		out = append(out, Binding{
			DigitalEmpID:   agent.ID,
			CapabilityKind: "composer_skill",
			CapabilityUUID: sk.UUID,
			Pinned:         sk.DefaultPinned,
		})
	}

	apps, err := s.repo.ListApps(ctx, true)
	if err != nil {
		return nil, err
	}
	for i := range apps {
		a := &apps[i]
		if !s.appDefaultEligible(a, agent) {
			continue
		}
		out = append(out, Binding{
			DigitalEmpID:   agent.ID,
			CapabilityKind: "app",
			CapabilityUUID: a.UUID,
			Pinned:         a.DefaultPinned,
		})
	}

	return out, nil
}

// skillDefaultEligible hosting + compatibility 过滤. 不读 tenant defaults.
// F02 v0.3: IntegrationMode 空 = platform_managed (env-aware 派生待 runtime_environments DI 接入)。
func (s *impl) skillDefaultEligible(sk *Skill, agent *AgentInfo) bool {
	if sk.Status != "published" {
		return false
	}
	switch integrationModeOrDefault(agent.IntegrationMode) {
	case "platform_managed":
		if !sk.AvailableToPlatformManaged {
			return false
		}
	case "hybrid":
		if !sk.AvailableToHybrid {
			return false
		}
	default:
		return false
	}
	if !compatibilityMatch(sk.Compatibility, agent) {
		return false
	}
	return true
}

func (s *impl) appDefaultEligible(a *App, agent *AgentInfo) bool {
	if a.Status != "active" {
		return false
	}
	switch integrationModeOrDefault(agent.IntegrationMode) {
	case "platform_managed":
		return true
	case "hybrid":
		return a.AvailableToHybrid
	default:
		return false
	}
}

// integrationModeOrDefault: F02 v0.3 兼容垫片, 空字符串视为 platform_managed (最常见路径)。
func integrationModeOrDefault(m string) string {
	if m == "" {
		return "platform_managed"
	}
	return m
}

// compatibilityMatch 检查 skill.compatibility 与 agent 是否兼容.
//
// 支持的键:
//   - required_models    []string  — agent.ModelPrimary 必须在内
//   - required_runtimes  []string  — Phase A 不强校 (没注入 runtime code; 留 Phase B)
//   - blocked_agent_tags []string  — agent.Tags 任一命中即拒
func compatibilityMatch(c map[string]any, agent *AgentInfo) bool {
	if len(c) == 0 {
		return true
	}
	if got := stringSlice(c["required_models"]); len(got) > 0 {
		if agent.ModelPrimary == "" {
			return false
		}
		hit := false
		for _, m := range got {
			if m == agent.ModelPrimary {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	if blocked := stringSlice(c["blocked_agent_tags"]); len(blocked) > 0 {
		for _, t := range agent.Tags {
			for _, b := range blocked {
				if t == b {
					return false
				}
			}
		}
	}
	return true
}

func stringSlice(v any) []string {
	if v == nil {
		return nil
	}
	if arr, ok := v.([]any); ok {
		out := make([]string, 0, len(arr))
		for _, x := range arr {
			if s, ok := x.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	}
	if arr, ok := v.([]string); ok {
		return arr
	}
	return nil
}

// ResetDefaults admin endpoint: 清空当前 composer_skill/app binding 后跑 DeriveDefaultBindings.
//
// 幂等: 重复调用对同一 agent + 同一 platform skill 集合产生相同 binding 集合.
// 事务: 删 + 插 + pg_notify 在同一个 tx (由 repo 实现保证).
func (s *impl) ResetDefaults(ctx context.Context, actorAccountID int64, agent *AgentInfo) ([]Binding, error) {
	bindings, err := s.DeriveDefaultBindings(ctx, agent)
	if err != nil {
		return nil, err
	}
	notifyPayloads := []string{
		"digital_employees:" + itoa(agent.ID),
	}
	if err := s.repo.ResetBindingsForAgent(ctx, agent.ID, bindings, notifyPayloads); err != nil {
		return nil, err
	}
	// audit (best-effort).
	if s.audit != nil {
		_ = s.audit.PublishWithTx(ctx, "audit.agent.capabilities_reset_defaults",
			agent.TenantID,
			"agent_capabilities_reset:"+itoa(agent.ID),
			map[string]any{
				"resource_kind":    "agent",
				"resource_uuid":    agent.UUID,
				"de_id":            agent.ID,
				"account_id":       actorAccountID,
				"binding_count":    len(bindings),
				"integration_mode": agent.IntegrationMode,
			})
	}
	// Phase A 缓存失效兜底: listener 也会响应 digital_employees NOTIFY, 这里再调一次双保险.
	s.cache.invalidate(agent.ID)
	return bindings, nil
}

func itoa(i int64) string {
	// 不引 strconv 是为了让本文件不依赖 fmt/strconv (cyclomatic 整齐); 这里 inline.
	if i == 0 {
		return "0"
	}
	buf := [20]byte{}
	neg := false
	if i < 0 {
		neg = true
		i = -i
	}
	pos := len(buf)
	for i > 0 {
		pos--
		buf[pos] = byte('0' + (i % 10))
		i /= 10
	}
	if neg {
		pos--
		buf[pos] = '-'
	}
	return string(buf[pos:])
}
