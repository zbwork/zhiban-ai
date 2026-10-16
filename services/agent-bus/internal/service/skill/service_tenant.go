// service_tenant.go — F03 v0.9.1 租户 admin / 客户端 域 service 实现。
//
// 详见 docs/features/F03-skills.md §3.2 / §3.3 / §4.9 / §4.10。
package skill

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ============================================================================
// 租户禁用 / 解禁（§3.2.A）
// ============================================================================

// DisableTenantSkill 禁用某平台技能（仅 platform skill 可禁；tenant 自有技能用 DELETE）。
func (s *Service) DisableTenantSkill(ctx context.Context, in domskill.DisableTenantSkillInput) (*domskill.TenantDisable, error) {
	if in.TenantID <= 0 || in.SkillUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id and skill_uuid required")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, in.SkillUUID, false)
	if err != nil {
		return nil, err
	}
	if sk.ScopeKind != domskill.ScopePlatform {
		return nil, apperr.ErrInvalidParams.Withf("skill.cannot_disable_tenant_owned")
	}
	d := &domskill.TenantDisable{
		TenantID:      in.TenantID,
		SkillID:       sk.ID,
		DisableReason: in.DisableReason,
		DisabledBy:    in.DisabledBy,
	}
	if err := s.repo.UpsertTenantDisable(ctx, d); err != nil {
		return nil, err
	}
	s.notifyf(ctx, "tenant_skill_disables:%d", in.TenantID)
	return d, nil
}

// EnableTenantSkill 解禁；删 tenant_skill_disables 行。
func (s *Service) EnableTenantSkill(ctx context.Context, tenantID int64, skillUUID string) error {
	if tenantID <= 0 || skillUUID == "" {
		return apperr.ErrInvalidParams.Withf("tenant_id and skill_uuid required")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID, false)
	if err != nil {
		return err
	}
	if err := s.repo.DeleteTenantDisable(ctx, tenantID, sk.ID); err != nil {
		return err
	}
	s.notifyf(ctx, "tenant_skill_disables:%d", tenantID)
	return nil
}

// ============================================================================
// 租户偏好（§3.2 PUT/DELETE /tenant/skill-preferences/{skill_uuid}）
// ============================================================================

// ListTenantPreferences 返回 (preferences, 对应 skill 元) 两并行切片。
func (s *Service) ListTenantPreferences(ctx context.Context, tenantID int64) ([]domskill.TenantPreference, []domskill.Skill, error) {
	if tenantID <= 0 {
		return nil, nil, apperr.ErrInvalidParams.Withf("tenant_id required")
	}
	prefs, err := s.repo.ListTenantPreferences(ctx, tenantID)
	if err != nil {
		return nil, nil, err
	}
	skills := make([]domskill.Skill, 0, len(prefs))
	for _, p := range prefs {
		sk, err := s.repo.GetSkillByID(ctx, p.SkillID)
		if err != nil {
			continue
		}
		skills = append(skills, *sk)
	}
	return prefs, skills, nil
}

// SetTenantPreference 写 force_on / force_off。
func (s *Service) SetTenantPreference(ctx context.Context, in domskill.SetTenantPreferenceInput) (*domskill.TenantPreference, error) {
	if in.TenantID <= 0 || in.SkillUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id and skill_uuid required")
	}
	if in.Behavior != domskill.PreferenceForceOn && in.Behavior != domskill.PreferenceForceOff {
		return nil, apperr.ErrInvalidParams.Withf("behavior invalid")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, in.SkillUUID, false)
	if err != nil {
		return nil, err
	}
	if sk.ScopeKind != domskill.ScopePlatform {
		return nil, apperr.ErrInvalidParams.Withf("skill.preference_only_for_platform")
	}
	p := &domskill.TenantPreference{
		TenantID:  in.TenantID,
		SkillID:   sk.ID,
		Behavior:  in.Behavior,
		Note:      in.Note,
		CreatedBy: in.UpdatedBy,
		UpdatedBy: in.UpdatedBy,
	}
	if err := s.repo.UpsertTenantPreference(ctx, p); err != nil {
		return nil, err
	}
	s.notifyf(ctx, "tenant_skill_preferences:%d", in.TenantID)
	return p, nil
}

// ClearTenantPreference 清除偏好。
func (s *Service) ClearTenantPreference(ctx context.Context, tenantID int64, skillUUID string) error {
	if tenantID <= 0 || skillUUID == "" {
		return apperr.ErrInvalidParams.Withf("tenant_id and skill_uuid required")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID, false)
	if err != nil {
		return err
	}
	if err := s.repo.DeleteTenantPreference(ctx, tenantID, sk.ID); err != nil {
		return err
	}
	s.notifyf(ctx, "tenant_skill_preferences:%d", tenantID)
	return nil
}

// ============================================================================
// 租户视角技能列表 / 版本 — 让租户 admin 在仅有 tenant.skill.read 时也能看到平台技能 + 自有技能 + 禁用 / 偏好覆盖
// ============================================================================

// ListTenantSkillsFilter 控制 ListTenantSkills 返回集。空字段视为不筛选。
type ListTenantSkillsFilter struct {
	Kind    string // agent / builtin
	Status  string // draft / active / archived；默认仅 active（避免 admin 看到 archived 平台垃圾）
	Keyword string
	Limit   int
	Offset  int
}

// ListTenantSkills 返回 (平台 active + 本租户全部) skills，并 overlay 当前租户的 disable / preference。
//
// 设计动机（spec §3.2 GET /api/admin/v1/tenant/skills 的语义"平台 + 本租户 + 禁用状态"）：
// 租户 admin 不应被迫调 platform.skill.read 网关；该 endpoint 在 tenant.skill.read 下统一返回。
func (s *Service) ListTenantSkills(ctx context.Context, tenantID int64, f ListTenantSkillsFilter) ([]domskill.TenantSkillView, int64, error) {
	if tenantID <= 0 {
		return nil, 0, apperr.ErrInvalidParams.Withf("tenant_id required")
	}
	limit := f.Limit
	if limit <= 0 {
		limit = 200
	}
	status := f.Status
	if status == "" {
		status = domskill.StatusActive
	}
	// 4 个独立查询: platform skills / tenant skills / disables / preferences。
	// 旧实现串行 → 远程 dev DB 每个 round-trip 都付 latency, 总耗时 = 4 × t_query。
	// 改并行: 4 个 goroutine 各自 Acquire 一条 pool 连接, 总耗时 = max(t_query)。
	// (admin pool MaxConns=20, 远超 4, 不会饥饿。)
	var (
		platformSkills []domskill.Skill
		tenantSkills   []domskill.Skill
		disables       []domskill.TenantDisable
		prefs          []domskill.TenantPreference
		errPlatform    error
		errTenant      error
	)
	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		platformSkills, _, errPlatform = s.repo.ListSkills(ctx, domskill.ListFilter{
			ScopeKind: domskill.ScopePlatform, Kind: f.Kind, Status: status, Keyword: f.Keyword,
			Limit: limit,
		})
	}()
	go func() {
		defer wg.Done()
		// 本租户自有技能不应用 status=active 默认值: 用户刚建的 draft 也要看到, 否则
		// "新建后列表里找不到" (企业技能页) / "草稿无法继续编辑" 都会被静默丢弃。
		// status 默认 active 只对平台技能 overlay 有意义 (隐藏平台草稿垃圾)。
		tenantStatus := f.Status
		tenantSkills, _, errTenant = s.repo.ListSkills(ctx, domskill.ListFilter{
			ScopeKind: domskill.ScopeTenant, TenantID: &tenantID,
			Kind: f.Kind, Status: tenantStatus, Keyword: f.Keyword, Limit: limit,
		})
	}()
	go func() {
		defer wg.Done()
		disables, _ = s.repo.ListTenantDisables(ctx, tenantID)
	}()
	go func() {
		defer wg.Done()
		prefs, _ = s.repo.ListTenantPreferences(ctx, tenantID)
	}()
	wg.Wait()
	if errPlatform != nil {
		return nil, 0, errPlatform
	}
	if errTenant != nil {
		return nil, 0, errTenant
	}
	disableMap := map[int64]*domskill.TenantDisable{}
	for i := range disables {
		disableMap[disables[i].SkillID] = &disables[i]
	}
	prefMap := map[int64]string{}
	for _, p := range prefs {
		prefMap[p.SkillID] = p.Behavior
	}
	views := make([]domskill.TenantSkillView, 0, len(platformSkills)+len(tenantSkills))
	for i := range platformSkills {
		sk := platformSkills[i]
		v := domskill.TenantSkillView{Skill: &sk, TenantPreference: prefMap[sk.ID]}
		if d, ok := disableMap[sk.ID]; ok {
			v.TenantDisabled = true
			v.DisableReason = d.DisableReason
		}
		views = append(views, v)
	}
	for i := range tenantSkills {
		sk := tenantSkills[i]
		views = append(views, domskill.TenantSkillView{Skill: &sk, TenantPreference: prefMap[sk.ID]})
	}
	return views, int64(len(views)), nil
}

// ListTenantSkillVersions 返回 published 版本（租户 admin pin 用）。
//
// 校验：该 skill 必须 scope=platform 或 scope=tenant AND tenant_id=tenantID，
// 防止越权窥探它租户的 tenant 私有技能。
func (s *Service) ListTenantSkillVersions(ctx context.Context, tenantID int64, skillUUID string) ([]domskill.SkillVersion, error) {
	if tenantID <= 0 || skillUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id and skill_uuid required")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID, false)
	if err != nil {
		return nil, err
	}
	if sk.ScopeKind == domskill.ScopeTenant {
		if sk.TenantID == nil || *sk.TenantID != tenantID {
			return nil, apperr.ErrForbidden.Withf("skill.cross_tenant")
		}
	} else if sk.ScopeKind != domskill.ScopePlatform {
		return nil, apperr.ErrInvalidParams.Withf("skill.scope_invalid")
	}
	all, err := s.repo.ListVersions(ctx, sk.ID)
	if err != nil {
		return nil, err
	}
	out := make([]domskill.SkillVersion, 0, len(all))
	for _, v := range all {
		if v.Status == domskill.VersionStatusPublished {
			out = append(out, v)
		}
	}
	return out, nil
}

// ============================================================================
// agent × skill 装配（§3.2.B-C, §3.2 PATCH/DELETE binding）
// ============================================================================

// ReplacePlatformAgentSkills keeps the canonical runtime binding table aligned
// with the platform template editor. Platform employees are shared read-only,
// so their bindings live on the platform row and are read with the caller's
// tenant policy at execution time.
func (s *Service) ReplacePlatformAgentSkills(ctx context.Context, agentID int64, skillUUIDs []string, accountID int64) error {
	if agentID <= 0 {
		return apperr.ErrInvalidParams.Withf("agent_id required")
	}
	current, err := s.repo.ListAgentBindings(ctx, agentID)
	if err != nil {
		return err
	}
	currentBySkillID := make(map[int64]domskill.AgentBinding, len(current))
	for _, binding := range current {
		currentBySkillID[binding.SkillID] = binding
	}
	keep := make(map[int64]struct{}, len(skillUUIDs))
	for index, skillUUID := range skillUUIDs {
		skillUUID = strings.TrimSpace(skillUUID)
		if skillUUID == "" {
			continue
		}
		skill, getErr := s.repo.GetSkillByUUID(ctx, skillUUID, false)
		if getErr != nil {
			return getErr
		}
		if skill.ScopeKind != domskill.ScopePlatform || skill.TenantID != nil {
			return apperr.ErrInvalidParams.Withf("platform employee can only bind platform skills")
		}
		if _, duplicate := keep[skill.ID]; duplicate {
			continue
		}
		keep[skill.ID] = struct{}{}
		createdBy := (*int64)(nil)
		if accountID > 0 {
			createdBy = &accountID
		}
		if err := s.repo.UpsertAgentBinding(ctx, &domskill.AgentBinding{
			AgentID:       agentID,
			SkillID:       skill.ID,
			Pinned:        false,
			SortOrder:     (index + 1) * 10,
			DefaultParams: []byte("{}"),
			Source:        domskill.BindingSourceManualAttach,
			CreatedBy:     createdBy,
			UpdatedBy:     createdBy,
		}); err != nil {
			return err
		}
	}
	for skillID, binding := range currentBySkillID {
		if _, ok := keep[skillID]; ok {
			continue
		}
		if err := s.repo.DeleteAgentBinding(ctx, binding.ID); err != nil {
			return err
		}
	}
	s.notifyf(ctx, "agent_skill_bindings:%d", agentID)
	return nil
}

// AttachAgentSkill 装配一项技能到数字员工；spec §3.2.B 校验链。
func (s *Service) AttachAgentSkill(ctx context.Context, in domskill.AttachAgentSkillInput) (*domskill.AgentBinding, error) {
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	if in.TenantID <= 0 || in.AgentUUID == "" || in.SkillUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id / agent_uuid / skill_uuid required")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, in.AgentUUID)
	if err != nil {
		return nil, err
	}
	if ag.TenantID != in.TenantID {
		return nil, apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	if ag.IntegrationMode == "self_hosted" {
		return nil, apperr.ErrInvalidParams.Withf("skill.self_hosted_forbidden")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, in.SkillUUID, false)
	if err != nil {
		return nil, err
	}
	if err := s.assertSkillUsableForTenant(ctx, sk, ag, in.TenantID); err != nil {
		return nil, err
	}
	source := in.Source
	if source == "" {
		source = domskill.BindingSourceManualAttach
	}
	b := &domskill.AgentBinding{
		AgentID:         ag.ID,
		SkillID:         sk.ID,
		Pinned:          in.Pinned,
		SortOrder:       in.SortOrder,
		PinnedVersionID: in.PinnedVersionID,
		DefaultParams:   in.DefaultParams,
		Source:          source,
		CreatedBy:       in.CreatedBy,
		UpdatedBy:       in.CreatedBy,
	}
	if err := s.repo.UpsertAgentBinding(ctx, b); err != nil {
		return nil, err
	}
	s.notifyf(ctx, "agent_skill_bindings:%d", ag.ID)
	// doc-12 §11.5 Task C/C-2: 绑定技能 (install) 后增量同步 (best-effort; published 才真正传播)。
	s.enqueueResync(ctx, ag.TenantID, ag.UUID, "binding_change")
	return b, nil
}

// PatchAgentBinding 编辑 binding 字段；只处理本租户 agent 名下的 binding。
func (s *Service) PatchAgentBinding(ctx context.Context, in domskill.PatchAgentBindingInput) (*domskill.AgentBinding, error) {
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	if in.BindingID <= 0 || in.AgentUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("binding_id and agent_uuid required")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, in.AgentUUID)
	if err != nil {
		return nil, err
	}
	if ag.TenantID != in.TenantID {
		return nil, apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	cur, err := s.repo.GetAgentBindingByID(ctx, in.BindingID)
	if err != nil {
		return nil, err
	}
	if cur.AgentID != ag.ID {
		return nil, apperr.ErrForbidden.Withf("binding.agent_mismatch")
	}
	fields := map[string]any{}
	if in.Pinned != nil {
		fields["pinned"] = *in.Pinned
	}
	if in.SortOrder != nil {
		fields["sort_order"] = *in.SortOrder
	}
	if in.ClearPinnedVer {
		fields["pinned_version_id"] = nil
	} else if in.PinnedVersionID != nil {
		fields["pinned_version_id"] = *in.PinnedVersionID
	}
	if in.DefaultParams != nil {
		fields["default_params"] = string(in.DefaultParams)
	}
	if in.UpdatedBy != nil {
		fields["updated_by"] = *in.UpdatedBy
	}
	updated, err := s.repo.PatchAgentBinding(ctx, in.BindingID, fields)
	if err != nil {
		return nil, err
	}
	s.notifyf(ctx, "agent_skill_bindings:%d", ag.ID)
	// doc-12 §11.5 Task C: 版本 pin/字段变化后增量同步 (best-effort; 重装会拉新版本包)。
	s.enqueueResync(ctx, ag.TenantID, ag.UUID, "binding_change")
	return updated, nil
}

// DetachAgentSkill 解绑（spec §3.2 DELETE /skills/{binding_id}）。
func (s *Service) DetachAgentSkill(ctx context.Context, tenantID int64, agentUUID string, bindingID int64) error {
	if s.agents == nil {
		return apperr.ErrInternal.Withf("agent lookup not wired")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, agentUUID)
	if err != nil {
		return err
	}
	if ag.TenantID != tenantID {
		return apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	cur, err := s.repo.GetAgentBindingByID(ctx, bindingID)
	if err != nil {
		return err
	}
	if cur.AgentID != ag.ID {
		return apperr.ErrForbidden.Withf("binding.agent_mismatch")
	}
	// doc-12 §11.5 Task C-2: 删除前解析被解绑技能的 uuid (运行端按 uuid→slug 删 skills/<slug>/)。
	// 解析失败不阻塞解绑 (best-effort): 只是少一次卸载信号。
	var unbindSkillUUID string
	if s.resync != nil {
		if sk, serr := s.repo.GetSkillByID(ctx, cur.SkillID); serr == nil && sk != nil {
			unbindSkillUUID = sk.UUID
		}
	}
	if err := s.repo.DeleteAgentBinding(ctx, bindingID); err != nil {
		return err
	}
	s.notifyf(ctx, "agent_skill_bindings:%d", ag.ID)
	// 解绑成功后入队 skill_unbind (Bus worker → skill_unregister 删运行端 skills/<slug>/)。best-effort, 不改历史会话。
	if s.resync != nil && unbindSkillUUID != "" && ag.TenantID > 0 {
		_ = s.resync.EnqueueSkillUnbind(ctx, ag.TenantID, ag.UUID, unbindSkillUUID)
	}
	return nil
}

// ListAgentBindings 列已装配（含 skill 元数据）。
func (s *Service) ListAgentBindings(ctx context.Context, tenantID int64, agentUUID string) ([]domskill.AgentBindingView, error) {
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, agentUUID)
	if err != nil {
		return nil, err
	}
	if ag.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	bindings, err := s.repo.ListAgentBindings(ctx, ag.ID)
	if err != nil {
		return nil, err
	}
	out := make([]domskill.AgentBindingView, 0, len(bindings))
	for i := range bindings {
		b := bindings[i]
		sk, err := s.repo.GetSkillByID(ctx, b.SkillID)
		if err != nil {
			continue
		}
		out = append(out, domskill.AgentBindingView{Binding: &b, Skill: sk})
	}
	return out, nil
}

// ListAgentBindingsByAgentIDs 批量版 ListAgentBindings（客户端 /agents 列表 hydrate 用）。
// 与逐条版的差异仅在查询形态：tenant 隔离由 repo 层 digital_employees 联表强制
// （跨租户 agentID 静默不返回），无需再逐个 GetAgentByUUID 回查。
// 返回 map 缺失的 agentID 表示无绑定（或不属于该租户）。
func (s *Service) ListAgentBindingsByAgentIDs(ctx context.Context, tenantID int64, agentIDs []int64) (map[int64][]domskill.AgentBindingView, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("tenant_id required")
	}
	if len(agentIDs) == 0 {
		return map[int64][]domskill.AgentBindingView{}, nil
	}
	return s.repo.ListAgentBindingViewsByAgentIDs(ctx, tenantID, agentIDs)
}

// ReplaceClientAgentSkillBindings 用客户端提交的 code/slug 替换数字员工正式核心技能绑定。
// 这和 /skill-overrides 的临时挂载不同：正式绑定会被 runtime ensure 解析为 skill_register。
func (s *Service) ReplaceClientAgentSkillBindings(ctx context.Context, in domskill.ReplaceClientAgentSkillBindingsInput) error {
	if in.AccountID <= 0 || in.TenantID <= 0 || in.AgentUUID == "" {
		return apperr.ErrInvalidParams.Withf("account_id, tenant_id and agent_uuid required")
	}
	if s.agents == nil {
		return apperr.ErrInternal.Withf("agent lookup not wired")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, in.AgentUUID)
	if err != nil {
		return err
	}
	if ag.TenantID != in.TenantID {
		return apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	if ag.CreatorID != in.AccountID {
		return apperr.ErrForbidden.Withf("agent.skill_binding_owner_required")
	}
	// ZAP framework 不再整体拒绝: 平台自营 dsh-runtime (ADR-0035) 按 ZAP-1.1 §11 消费 skills 节;
	// 其它外部 ZAP runtime 对该节可忽略。self_hosted 的空集由 BuildZapSessionSkills 保证 (boundaries §2.3)。
	if strings.EqualFold(strings.TrimSpace(ag.RuntimeKind), "support_builtin") ||
		strings.EqualFold(strings.TrimSpace(ag.AgentKey), "zhiban-support") {
		return apperr.ErrForbidden.Withf("agent.skill_binding_unsupported_runtime")
	}

	codes := normalizeSkillCodes(in.SkillCodes)
	desired := make(map[int64]*domskill.Skill, len(codes))
	ordered := make([]*domskill.Skill, 0, len(codes))
	for _, code := range codes {
		sk, err := s.resolveClientSkillByCode(ctx, in.AccountID, in.TenantID, in.AgentUUID, code)
		if err != nil {
			return err
		}
		if err := s.assertSkillUsableForTenant(ctx, sk, ag, in.TenantID); err != nil {
			return err
		}
		if _, ok := desired[sk.ID]; ok {
			continue
		}
		desired[sk.ID] = sk
		ordered = append(ordered, sk)
	}

	current, err := s.ListAgentBindings(ctx, in.TenantID, in.AgentUUID)
	if err != nil {
		return err
	}
	currentBySkillID := make(map[int64]domskill.AgentBindingView, len(current))
	for _, view := range current {
		if view.Skill == nil || view.Binding == nil {
			continue
		}
		currentBySkillID[view.Skill.ID] = view
		if _, keep := desired[view.Skill.ID]; keep {
			continue
		}
		// default_inherit 由平台/租户默认装配策略维护，客户端替换核心技能不主动移除。
		if view.Binding.Source == domskill.BindingSourceDefaultInherit {
			continue
		}
		if err := s.DetachAgentSkill(ctx, in.TenantID, in.AgentUUID, view.Binding.ID); err != nil {
			return err
		}
	}

	for i, sk := range ordered {
		if _, exists := currentBySkillID[sk.ID]; exists {
			continue
		}
		if _, err := s.AttachAgentSkill(ctx, domskill.AttachAgentSkillInput{
			TenantID:  in.TenantID,
			AgentUUID: in.AgentUUID,
			SkillUUID: sk.UUID,
			SortOrder: i,
			Source:    domskill.BindingSourceManualAttach,
			CreatedBy: in.UpdatedBy,
		}); err != nil {
			return err
		}
	}
	return nil
}

func normalizeSkillCodes(values []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(values))
	for _, value := range values {
		code := strings.TrimSpace(value)
		if code == "" {
			continue
		}
		key := strings.ToLower(code)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, code)
	}
	return out
}

func (s *Service) resolveClientSkillByCode(ctx context.Context, accountID, tenantID int64, agentUUID, code string) (*domskill.Skill, error) {
	views, _, err := s.ListClientSkills(ctx, domskill.ListClientSkillsInput{
		AccountID: accountID,
		TenantID:  tenantID,
		AgentUUID: agentUUID,
		Keyword:   code,
		Limit:     200,
	})
	if err != nil {
		return nil, err
	}
	for _, view := range views {
		if view.Skill == nil {
			continue
		}
		if strings.EqualFold(view.Skill.Code, code) || view.Skill.UUID == code {
			return view.Skill, nil
		}
	}
	return nil, apperr.ErrInvalidParams.Withf("skill.not_available:%s", code)
}

// ListAvailableForAgent §3.2.C 可装池 — agent 视角下能装的全集。
func (s *Service) ListAvailableForAgent(ctx context.Context, tenantID int64, agentUUID string) ([]domskill.AvailableSkillView, error) {
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, agentUUID)
	if err != nil {
		return nil, err
	}
	if ag.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	if ag.IntegrationMode == "self_hosted" {
		return []domskill.AvailableSkillView{}, nil
	}

	// 1) 取所有 platform + 本租户 skills（active），过滤掉 archived/deleted
	platformSkills, _, err := s.repo.ListSkills(ctx, domskill.ListFilter{
		ScopeKind: domskill.ScopePlatform, Status: domskill.StatusActive, Limit: 200,
	})
	if err != nil {
		return nil, err
	}
	tenantSkills, _, err := s.repo.ListSkills(ctx, domskill.ListFilter{
		ScopeKind: domskill.ScopeTenant, TenantID: &tenantID,
		Status: domskill.StatusActive, Limit: 200,
	})
	if err != nil {
		return nil, err
	}
	all := append(platformSkills, tenantSkills...)

	// 2) 取已装、租户禁用、租户偏好
	attachedSet := map[int64]bool{}
	bindings, _ := s.repo.ListAgentBindings(ctx, ag.ID)
	for _, b := range bindings {
		attachedSet[b.SkillID] = true
	}
	disables, _ := s.repo.ListTenantDisables(ctx, tenantID)
	disabledSet := map[int64]bool{}
	for _, d := range disables {
		disabledSet[d.SkillID] = true
	}
	prefs, _ := s.repo.ListTenantPreferences(ctx, tenantID)
	prefMap := map[int64]string{}
	for _, p := range prefs {
		prefMap[p.SkillID] = p.Behavior
	}

	out := make([]domskill.AvailableSkillView, 0, len(all))
	for i := range all {
		sk := all[i]
		// 平台技能若被本租户禁用则不进可装池
		if sk.ScopeKind == domskill.ScopePlatform && disabledSet[sk.ID] {
			continue
		}
		// hosting_modes 必含 agent.integration_mode
		if !hostingModeMatch(sk.HostingModes, ag.IntegrationMode) {
			continue
		}
		if !agentRuntimeCompatMatch(sk.AgentCompat, ag.RuntimeFramework) {
			continue
		}
		out = append(out, domskill.AvailableSkillView{
			Skill:             &sk,
			IsAttached:        attachedSet[sk.ID],
			IsDefaultAttached: sk.DefaultAttached,
			TenantPreference:  prefMap[sk.ID],
		})
	}
	return out, nil
}

// assertSkillUsableForTenant 校验 §3.2.B 中后半部分（scope/disable/hosting/agent_compat）。
func (s *Service) assertSkillUsableForTenant(ctx context.Context, sk *domskill.Skill, ag *AgentInfo, tenantID int64) error {
	if sk.Status != domskill.StatusActive {
		return apperr.ErrInvalidParams.Withf("skill.not_active")
	}
	switch sk.ScopeKind {
	case domskill.ScopePlatform:
		// ok
	case domskill.ScopeTenant:
		if sk.TenantID == nil || *sk.TenantID != tenantID {
			return apperr.ErrForbidden.Withf("skill.cross_tenant")
		}
	default:
		return apperr.ErrInvalidParams.Withf("skill.scope_invalid")
	}
	if sk.ScopeKind == domskill.ScopePlatform {
		disabled, err := s.repo.IsTenantSkillDisabled(ctx, tenantID, sk.ID)
		if err != nil {
			return err
		}
		if disabled {
			return apperr.ErrForbidden.Withf("skill.disabled_in_tenant")
		}
	}
	if !hostingModeMatch(sk.HostingModes, ag.IntegrationMode) {
		return apperr.ErrInvalidParams.Withf("skill.hosting_mode_mismatch")
	}
	if !agentRuntimeCompatMatch(sk.AgentCompat, ag.RuntimeFramework) {
		return apperr.ErrInvalidParams.Withf("skill.runtime_mismatch")
	}
	return nil
}

func agentRuntimeCompatMatch(raw []byte, framework string) bool {
	if len(raw) == 0 {
		return true
	}
	var compat struct {
		RequiredRuntimes []string `json:"required_runtimes"`
	}
	if err := json.Unmarshal(raw, &compat); err != nil {
		return false
	}
	if len(compat.RequiredRuntimes) == 0 {
		return true
	}
	framework = strings.ToLower(strings.TrimSpace(framework))
	if framework == "" {
		return false
	}
	for _, runtime := range compat.RequiredRuntimes {
		rt := strings.ToLower(strings.TrimSpace(runtime))
		if rt == framework {
			return true
		}
		// 两个本地引擎均通过宿主消费 ZAP 技能包；不相互冒充引擎。
		if (framework == "dsh" || framework == "codex_app_server") && rt == "zap" {
			return true
		}
	}
	return false
}

func hostingModeMatch(modes []string, integrationMode string) bool {
	mode := integrationMode
	if mode == "" {
		mode = "platform_managed" // 默认；详 composer/adapters.go 注释
	}
	if mode == "self_hosted" {
		return false
	}
	for _, m := range modes {
		if m == mode {
			return true
		}
	}
	return false
}

// ============================================================================
// 客户端 chip rail 装载（§3.3.A）
// ============================================================================

// GetSkillRail 返回当前 (account × agent) 视角下可装载的 chip rail。
//
// 算法（spec §3.3.A 服务端组装步骤）：
//  1. 取 agent 已绑定（agent_skill_bindings）
//  2. 应用 user_agent_skill_overrides（attach/detach）
//  3. 平台技能过 tenant_skill_disables（命中即剔除）
//  4. status='active' 闸口
//  5. 按灰度（§4.9）挑出实际版本，读 skill_versions.input_chips_schema_snapshot
//  6. builtin 兼容裁剪（§4.10）
func (s *Service) GetSkillRail(ctx context.Context, in domskill.GetSkillRailInput) (*domskill.SkillRail, error) {
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	if in.AccountID <= 0 || in.TenantID <= 0 || in.AgentUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("account_id / tenant_id / agent_uuid required")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, in.AgentUUID)
	if err != nil {
		return nil, err
	}
	if ag.TenantID != in.TenantID && ag.Source != "platform" {
		return nil, apperr.ErrForbidden.Withf("agent.cross_tenant")
	}

	bindings, err := s.repo.ListAgentBindings(ctx, ag.ID)
	if err != nil {
		return nil, err
	}
	overrides, err := s.repo.ListUserOverrides(ctx, in.AccountID, ag.ID)
	if err != nil {
		return nil, err
	}
	disables, _ := s.repo.ListTenantDisables(ctx, in.TenantID)
	disabledSet := map[int64]bool{}
	for _, d := range disables {
		disabledSet[d.SkillID] = true
	}

	// 客户端支持的 builtin keys（裁剪 builtin 类）
	supportedBuiltin := map[string]bool{}
	if in.ClientPlatform != "" && in.DeviceID != "" {
		hands, _ := s.repo.GetHandshakesForAccount(ctx, in.AccountID)
		for _, h := range hands {
			if h.ClientPlatform != in.ClientPlatform {
				continue
			}
			for _, k := range h.SupportedBuiltinKeys {
				supportedBuiltin[k] = true
			}
		}
	}

	// 用 map[skill_id] -> entry 合并：先 binding，override.attach 覆盖/补充，override.detach 删
	type entry struct {
		skillID         int64
		pinned          bool
		sortOrder       int
		pinnedVersionID *int64
		defaultParams   []byte
		source          string
	}
	merged := map[int64]*entry{}
	for _, b := range bindings {
		dp := b.DefaultParams
		if len(dp) == 0 {
			dp = []byte("{}")
		}
		merged[b.SkillID] = &entry{
			skillID:         b.SkillID,
			pinned:          b.Pinned,
			sortOrder:       b.SortOrder,
			pinnedVersionID: b.PinnedVersionID,
			defaultParams:   dp,
			source:          b.Source,
		}
	}
	for _, o := range overrides {
		switch o.Behavior {
		case domskill.OverrideTemporaryAttach:
			if _, ok := merged[o.SkillID]; !ok {
				merged[o.SkillID] = &entry{
					skillID:       o.SkillID,
					pinned:        false,
					sortOrder:     0,
					defaultParams: []byte("{}"),
					source:        "temporary_attach",
				}
			}
		case domskill.OverrideTemporaryDetach:
			delete(merged, o.SkillID)
		}
	}

	chipRail := []domskill.SkillRailItem{}
	moreDrawer := []domskill.SkillRailItem{}

	for _, e := range merged {
		sk, err := s.repo.GetSkillByID(ctx, e.skillID)
		if err != nil {
			continue
		}
		if sk.Status != domskill.StatusActive {
			continue
		}
		if sk.ScopeKind == domskill.ScopePlatform && disabledSet[sk.ID] {
			continue
		}
		if sk.ScopeKind == domskill.ScopeTenant && (sk.TenantID == nil || *sk.TenantID != in.TenantID) {
			continue
		}
		if !agentRuntimeCompatMatch(sk.AgentCompat, ag.RuntimeFramework) {
			continue
		}
		// builtin 兼容裁剪
		if sk.Kind == domskill.KindBuiltin && in.ClientPlatform != "" {
			if sk.BuiltinKey == nil || !supportedBuiltin[*sk.BuiltinKey] {
				continue
			}
		}

		// 选实际生效版本
		ver, err := s.pickVersionForRail(ctx, sk, e.pinnedVersionID, in.TenantID, ag.ID, in.AccountID)
		if err != nil {
			continue
		}

		// builtin 类版本可能不存在 published baseline；agent 类必须有
		var verStr, verUUID string
		var snapshot []byte
		if ver != nil {
			verStr = ver.Version
			verUUID = ver.UUID
			snapshot = ver.InputChipsSchemaSnapshot
		} else if sk.Kind == domskill.KindAgent {
			// agent 必须有 published；没有则不上 rail
			continue
		} else {
			// builtin 没版本时退回主表 chips
			snapshot = sk.InputChipsSchema
		}

		item := domskill.SkillRailItem{
			SkillUUID:        sk.UUID,
			Code:             sk.Code,
			Name:             sk.Name,
			IconURL:          sk.IconURL,
			Kind:             sk.Kind,
			ExecutionMode:    sk.ExecutionMode,
			Pinned:           e.pinned,
			SortOrder:        e.sortOrder,
			Source:           e.source,
			DefaultParams:    e.defaultParams,
			Version:          verStr,
			VersionUUID:      verUUID,
			InputChipsSchema: snapshot,
			BillingType:      sk.BillingType,
			PricingMode:      sk.PricingMode,
		}
		if e.pinned {
			chipRail = append(chipRail, item)
		} else {
			moreDrawer = append(moreDrawer, item)
		}
	}

	sort.SliceStable(chipRail, func(i, j int) bool {
		if chipRail[i].SortOrder != chipRail[j].SortOrder {
			return chipRail[i].SortOrder > chipRail[j].SortOrder
		}
		return chipRail[i].SkillUUID < chipRail[j].SkillUUID
	})
	sort.SliceStable(moreDrawer, func(i, j int) bool {
		if moreDrawer[i].SortOrder != moreDrawer[j].SortOrder {
			return moreDrawer[i].SortOrder > moreDrawer[j].SortOrder
		}
		return moreDrawer[i].SkillUUID < moreDrawer[j].SkillUUID
	})

	cfgVer := fmt.Sprintf("v1-%d", time.Now().Unix())
	return &domskill.SkillRail{
		AgentUUID:       ag.UUID,
		ChipRail:        chipRail,
		MoreDrawer:      moreDrawer,
		ConfigVersion:   cfgVer,
		CacheTTLSeconds: 300,
	}, nil
}

// pickVersionForRail 选实际生效版本（pin/灰度/最新发布）。
func (s *Service) pickVersionForRail(ctx context.Context, sk *domskill.Skill, pinnedVersionID *int64, tenantID, agentID, accountID int64) (*domskill.SkillVersion, error) {
	if pinnedVersionID != nil && *pinnedVersionID > 0 {
		v, err := s.repo.GetVersionByID(ctx, *pinnedVersionID)
		if err == nil && v.Status == domskill.VersionStatusPublished {
			return v, nil
		}
	}
	versions, err := s.repo.ListVersions(ctx, sk.ID)
	if err != nil {
		return nil, err
	}
	publishedFull := []domskill.SkillVersion{}
	publishedGray := []domskill.SkillVersion{}
	for _, v := range versions {
		if v.Status != domskill.VersionStatusPublished {
			continue
		}
		if v.GrayscalePct >= 100 && len(v.GrayscaleAllowlist) == 0 {
			publishedFull = append(publishedFull, v)
		} else {
			publishedGray = append(publishedGray, v)
		}
	}
	// 灰度命中优先（最新）
	for i := len(publishedGray) - 1; i >= 0; i-- {
		v := publishedGray[i]
		if grayscaleHit(&v, tenantID, agentID, accountID) {
			return &v, nil
		}
	}
	// 否则取最新 baseline
	if len(publishedFull) > 0 {
		return &publishedFull[len(publishedFull)-1], nil
	}
	return nil, nil
}

// grayscaleHit 实现 §4.9：tenant_hash / agent_hash / user_hash / tenant_allowlist。
func grayscaleHit(v *domskill.SkillVersion, tenantID, agentID, accountID int64) bool {
	if v.GrayscalePct >= 100 && len(v.GrayscaleAllowlist) == 0 {
		return true
	}
	if v.GrayscaleStrategy == domskill.GrayscaleTenantAllowlist {
		for _, t := range v.GrayscaleAllowlist {
			if t == tenantID {
				return true
			}
		}
		return false
	}
	if v.GrayscalePct <= 0 {
		return false
	}
	var key int64
	switch v.GrayscaleStrategy {
	case domskill.GrayscaleAgentHash:
		key = agentID
	case domskill.GrayscaleUserHash:
		key = accountID
	default:
		key = tenantID
	}
	hashed := stableHashPct(v.ID, key)
	return hashed < v.GrayscalePct
}

// stableHashPct 把 (versionID, key) 映射到 [0, 100) 的稳定整数。
func stableHashPct(versionID, key int64) int {
	var buf [16]byte
	binary.BigEndian.PutUint64(buf[:8], uint64(versionID))
	binary.BigEndian.PutUint64(buf[8:], uint64(key))
	sum := sha256.Sum256(buf[:])
	v := binary.BigEndian.Uint32(sum[:4])
	return int(v % 100)
}

// ============================================================================
// 用户临时挂/摘（§3.3.B）
// ============================================================================

func (s *Service) UpsertUserOverride(ctx context.Context, in domskill.UpsertUserOverrideInput) (*domskill.UserOverride, error) {
	if s.agents == nil {
		return nil, apperr.ErrInternal.Withf("agent lookup not wired")
	}
	if in.Behavior != domskill.OverrideTemporaryAttach && in.Behavior != domskill.OverrideTemporaryDetach {
		return nil, apperr.ErrInvalidParams.Withf("behavior invalid")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, in.AgentUUID)
	if err != nil {
		return nil, err
	}
	if ag.TenantID != in.TenantID {
		return nil, apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, in.SkillUUID, false)
	if err != nil {
		return nil, err
	}
	// attach 校禁用 + scope；detach 不校（让用户能去除 default_inherit）
	if in.Behavior == domskill.OverrideTemporaryAttach {
		if err := s.assertSkillUsableForTenant(ctx, sk, ag, in.TenantID); err != nil {
			return nil, err
		}
	}
	o := &domskill.UserOverride{
		AccountID: in.AccountID,
		TenantID:  in.TenantID,
		AgentID:   ag.ID,
		SkillID:   sk.ID,
		Behavior:  in.Behavior,
		ExpiresAt: in.ExpiresAt,
	}
	if err := s.repo.UpsertUserOverride(ctx, o); err != nil {
		return nil, err
	}
	s.notifyf(ctx, "user_agent_skill_overrides:%d:%d", in.AccountID, ag.ID)
	return o, nil
}

func (s *Service) DeleteUserOverride(ctx context.Context, accountID, tenantID int64, agentUUID, skillUUID string) error {
	if s.agents == nil {
		return apperr.ErrInternal.Withf("agent lookup not wired")
	}
	ag, err := s.agents.GetAgentByUUID(ctx, agentUUID)
	if err != nil {
		return err
	}
	if ag.TenantID != tenantID {
		return apperr.ErrForbidden.Withf("agent.cross_tenant")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID, false)
	if err != nil {
		return err
	}
	if err := s.repo.DeleteUserOverride(ctx, accountID, ag.ID, sk.ID); err != nil {
		return err
	}
	s.notifyf(ctx, "user_agent_skill_overrides:%d:%d", accountID, ag.ID)
	return nil
}

// ============================================================================
// 客户端 handshake（§3.3.D）
// ============================================================================

func (s *Service) UpsertHandshake(ctx context.Context, in domskill.UpsertHandshakeInput) error {
	if in.AccountID <= 0 || in.ClientPlatform == "" || in.DeviceID == "" {
		return apperr.ErrInvalidParams.Withf("account_id / client_platform / device_id required")
	}
	switch in.ClientPlatform {
	case domskill.ClientPlatformIOS, domskill.ClientPlatformAndroid,
		domskill.ClientPlatformMacOS, domskill.ClientPlatformWindows, domskill.ClientPlatformWeb:
	default:
		return apperr.ErrInvalidParams.Withf("client_platform invalid")
	}
	keys := in.SupportedBuiltinKeys
	if keys == nil {
		keys = []string{}
	}
	h := &domskill.ClientHandshake{
		AccountID:            in.AccountID,
		ClientPlatform:       in.ClientPlatform,
		DeviceID:             in.DeviceID,
		ClientVersion:        in.ClientVersion,
		SupportedBuiltinKeys: keys,
	}
	return s.repo.UpsertHandshake(ctx, h)
}

// ============================================================================
// 客户端广场列表（§3.3.C）
// ============================================================================

func (s *Service) ListClientSkills(ctx context.Context, in domskill.ListClientSkillsInput) ([]domskill.ClientSkillView, int64, error) {
	if in.TenantID <= 0 {
		return nil, 0, apperr.ErrInvalidParams.Withf("tenant_id required")
	}

	// 取 platform active + tenant 自有 active 两批
	platformList, _, err := s.repo.ListSkills(ctx, domskill.ListFilter{
		ScopeKind: domskill.ScopePlatform, Status: domskill.StatusActive,
		CategoryID: in.CategoryID, Keyword: in.Keyword, Source: in.Source, Limit: 200,
	})
	if err != nil {
		return nil, 0, err
	}
	tenantList, _, err := s.repo.ListSkills(ctx, domskill.ListFilter{
		ScopeKind: domskill.ScopeTenant, TenantID: &in.TenantID, Status: domskill.StatusActive,
		CategoryID: in.CategoryID, Keyword: in.Keyword, Source: in.Source, Limit: 200,
	})
	if err != nil {
		return nil, 0, err
	}
	all := append(platformList, tenantList...)

	// 租户禁用过滤
	disables, _ := s.repo.ListTenantDisables(ctx, in.TenantID)
	disabledSet := map[int64]bool{}
	for _, d := range disables {
		disabledSet[d.SkillID] = true
	}

	// 已装 / 临时挂集合（仅当传 agent_uuid 时）
	attachedSet := map[int64]bool{}
	tempAttachedSet := map[int64]bool{}
	if in.AgentUUID != "" && s.agents != nil {
		if ag, err := s.agents.GetAgentByUUID(ctx, in.AgentUUID); err == nil && ag.TenantID == in.TenantID {
			bindings, _ := s.repo.ListAgentBindings(ctx, ag.ID)
			for _, b := range bindings {
				attachedSet[b.SkillID] = true
			}
			overrides, _ := s.repo.ListUserOverrides(ctx, in.AccountID, ag.ID)
			for _, o := range overrides {
				if o.Behavior == domskill.OverrideTemporaryAttach {
					tempAttachedSet[o.SkillID] = true
				}
			}
		}
	}

	out := make([]domskill.ClientSkillView, 0, len(all))
	for i := range all {
		sk := all[i]
		if sk.ScopeKind == domskill.ScopePlatform && disabledSet[sk.ID] {
			continue
		}
		out = append(out, domskill.ClientSkillView{
			Skill:               &sk,
			IsAttachedToAgent:   attachedSet[sk.ID],
			IsTemporaryAttached: tempAttachedSet[sk.ID],
		})
	}
	sortClientSkills(out, in.SortBy, in.SortOrder)

	total := int64(len(out))
	limit := in.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	offset := in.Offset
	if offset < 0 {
		offset = 0
	}
	if offset >= len(out) {
		return []domskill.ClientSkillView{}, total, nil
	}
	end := offset + limit
	if end > len(out) {
		end = len(out)
	}
	page := out[offset:end]
	s.hydrateLatestVersions(ctx, page)
	return page, total, nil
}

// hydrateLatestVersions 给当前页的技能填 latest published 版本号（§1.5.4 详情元信息）。
// 只按分页后的页内 latest_version_id 一次批量查；失败仅降级不返回错误（版本号是展示增强字段）。
func (s *Service) hydrateLatestVersions(ctx context.Context, page []domskill.ClientSkillView) {
	ids := make([]int64, 0, len(page))
	seen := map[int64]bool{}
	for i := range page {
		if id := page[i].Skill.LatestVersionID; id != nil && *id > 0 && !seen[*id] {
			seen[*id] = true
			ids = append(ids, *id)
		}
	}
	if len(ids) == 0 {
		return
	}
	names, err := s.repo.ListVersionNamesByIDs(ctx, ids)
	if err != nil {
		return
	}
	for i := range page {
		if id := page[i].Skill.LatestVersionID; id != nil {
			page[i].LatestVersion = names[*id]
		}
	}
}

func sortClientSkills(items []domskill.ClientSkillView, sortBy, sortOrder string) {
	desc := sortOrder == "" || sortOrder == "desc"
	switch sortBy {
	case "", "install_count", "download_count":
		sort.SliceStable(items, func(i, j int) bool {
			left := items[i].Skill.InstallCount
			right := items[j].Skill.InstallCount
			if left == right {
				if desc {
					return items[i].Skill.ID > items[j].Skill.ID
				}
				return items[i].Skill.ID < items[j].Skill.ID
			}
			if desc {
				return left > right
			}
			return left < right
		})
	case "updated_at":
		sort.SliceStable(items, func(i, j int) bool {
			left := items[i].Skill.UpdatedAt
			right := items[j].Skill.UpdatedAt
			if left.Equal(right) {
				if desc {
					return items[i].Skill.ID > items[j].Skill.ID
				}
				return items[i].Skill.ID < items[j].Skill.ID
			}
			if desc {
				return left.After(right)
			}
			return left.Before(right)
		})
	}
}

// MarshalDefaultParams 给 transport 层方便用：把 map[string]any 序列化成 []byte。
func MarshalDefaultParams(m map[string]any) ([]byte, error) {
	if m == nil {
		return []byte("{}"), nil
	}
	return json.Marshal(m)
}

// notify 发 PG NOTIFY 但 swallow 错误（spec §4.6：失败时下次拉接口重新组装兜底）。
func (s *Service) notify(ctx context.Context, payload string) {
	_ = s.repo.NotifyConfigChange(ctx, payload)
}

// notifyf format wrapper.
func (s *Service) notifyf(ctx context.Context, format string, args ...any) {
	s.notify(ctx, fmt.Sprintf(format, args...))
}
