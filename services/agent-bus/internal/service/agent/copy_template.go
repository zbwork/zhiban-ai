// copy_template.go — doc-15 P1/P2: 平台模板 → 租户数字员工**副本**模型。
//
// 模型：平台「数字员工模板」是 blueprint（`tenant_id IS NULL` / `source='platform'` / `visibility='platform'`）；
// 租户「数字员工」是模板的**快照副本**（copy-on-create），复制后与模板**解耦**——平台模板更新不回灌副本。
//
// 本文件提供平台模板读取与底层快照复制能力：
//   - ListPublishedPlatformTemplates：列出"已发布平台模板"（供租户侧 picker 数据源）。
//   - CopyTemplateToTenant：把一个已发布平台模板复制成一份**租户自己的** draft 数字员工行。
//
// fail-closed：模板必须是 published 平台模板，否则拒绝复制（不复制半坏/未发布/跨租户数据）。
// 幂等：同一 (tenant, template_source_uuid) 已有副本则复用，不重复建；显式初始化重入只补齐缺失的平台 KB binding。
// 编排：复制编排型模板时，主控 `metadata.orchestration.child_agent_uuids` 指向的是**平台模板**成员 uuid，
//
//	必须用调用方提供的 ChildRemap（平台模板 uuid → 租户副本 uuid）重映射；未命中的成员**不伪造 uuid**，
//	记入 MissingChildUUIDs 由上层提示/补选。
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// MetadataTemplateSourceKey 是租户副本 metadata 里记录来源平台模板 uuid 的键（幂等 + 追踪用，不做 live-link 回灌）。
const MetadataTemplateSourceKey = "template_source_uuid"
const supportBuiltinRuntimeKind = "support_builtin"

func isSupportBuiltinAgent(de *dom.DigitalEmployee) bool {
	if de == nil || de.Metadata == nil {
		return false
	}
	return strings.TrimSpace(toString(de.Metadata["runtime_kind"])) == supportBuiltinRuntimeKind ||
		strings.TrimSpace(toString(de.Metadata["agent_key"])) == "zhiban-support"
}

func toString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// CopyOpts 控制副本的初始可见性 / 部门 / runtime / 编排 child 重映射。
//
// 注意：CopyTemplateToTenant **始终创建 draft**（安全、永远有效）。要让副本对客户端可见，调用方在复制后
// 走既有发布流程（PublishVersion，会创建版本快照 + runtime 同步）——直接写 status=published 但无版本快照的行
// 在 chat 路径会 fail-closed 不可用，故复制阶段不直接发布（见 doc-15 §3.4/§4：先 copy(draft) 再 publish）。
type CopyOpts struct {
	// Visibility 副本可见性：空 → "tenant"（全租户可见）；"workspace" 需配 WorkspaceID。
	Visibility string
	// WorkspaceID 绑定部门（visibility=workspace 时必填）。nil → 不绑部门。
	WorkspaceID *int64
	// ContactEnabled 是否进客户端通讯录。nil → 继承模板；非 nil → 显式设置（租户初始化传 true）。
	ContactEnabled *bool
	// RuntimeEnvironmentID 副本绑定的**租户可用** runtime（调用方按租户已开放的平台 runtime 解析）。
	// nil → 继承模板的 runtime（可能对租户不可用，发布时会 fail-closed，调用方需注意）。
	RuntimeEnvironmentID *int64
	// ChildRemap 编排型：平台模板成员 uuid → 租户副本 uuid。未命中的成员记入 MissingChildUUIDs。
	ChildRemap map[string]string
	// PublishAfterCopy 复制后是否立即发布（租户初始化 = true，使副本 published 对客户端可见）。
	// 发布走既有 PublishVersion（创建版本快照 + runtime 同步）。**必须有可用 runtime**（RuntimeEnvironmentID 非空）；
	// 无 runtime / 发布失败 → 保持 draft 并在 CopyResult.PublishSkippedReason 说明，**不产出 published 但不可用的坏员工**。
	// 手动「从模板创建」预填 = false（用户编辑后自行保存草稿/发布）。
	PublishAfterCopy bool
	// SeededByInit 标记租户初始化自动种子。仅该路径豁免 digital_employee_limit。
	SeededByInit bool
}

// CopyResult 复制结果 + 诚实的缺口报告（不静默）。
type CopyResult struct {
	Agent                *dom.DigitalEmployee
	Reused               bool     // true = 幂等命中既有副本，未新建
	RepairedKBBindings   int      // 显式初始化重入时，仅新增到既有副本的缺失平台 KB binding 数
	Published            bool     // true = PublishAfterCopy 且发布成功（副本 status=published）
	PublishSkippedReason string   // PublishAfterCopy 但未发布的原因（no_runtime / 发布错误）；空 = 未要求发布或已发布
	MissingChildUUIDs    []string // 编排成员未在 ChildRemap 命中（未复制/未发布）；不伪造 uuid
	SkippedBindings      []string // 未复制的能力绑定（kind:uuid），含不可装配/复制失败的平台 KB
	// RepairedSkillBindings 显式初始化重入时，按模板补到既有副本 agent_skill_bindings 的技能数（additive-only）。
	RepairedSkillBindings int
}

// platformSkillBindingCopier 由 postgres agent repository 实现：把模板的 composer_skill 能力绑定翻译成副本的
// agent_skill_bindings（租户编辑器与 ZAP 会话下发的真相源）。幂等、additive-only；过滤规则在 repository 内。
type platformSkillBindingCopier interface {
	CopyPlatformSkillBindings(ctx context.Context, templateID, copyID, createdBy int64) (int, []string, error)
}

// platformKBBindingCopier 由 postgres agent repository 实现。service 只编排复制策略，
// canonical agent_kb_bindings 的查询和写入必须留在 repository 层。
type platformKBBindingCopier interface {
	CopyPlatformKBBindings(ctx context.Context, templateID, copyID, createdBy int64, overwrite bool) (int, []string, error)
}

// ListPublishedPlatformTemplates 列出已发布平台模板（blueprint）的**一页**。
// 供租户侧「从模板创建」picker（分页 + 搜索 + 类型筛选）。只读，不含租户私有数据。
//
//   - kind: "single" / "orchestrator" 按 metadata.agent_kind 过滤（仓储不支持 metadata 过滤，本层后置裁剪）；空 = 全部。
//   - keyword: 透传仓储按 name/intro 等模糊搜（repo 能力）。
//   - limit/offset: 分页；total 为该查询（已发布平台模板 + keyword）的总数，供分页 UI。
func (s *impl) ListPublishedPlatformTemplates(ctx context.Context, kind, keyword string, limit, offset int) ([]dom.DigitalEmployee, int64, error) {
	items, total, err := s.repo.List(ctx, dom.Filter{
		Source:     "platform",
		Visibility: "platform",
		Status:     "published",
		Keyword:    keyword,
		Limit:      limit,
		Offset:     offset,
	})
	if err != nil {
		return nil, 0, err
	}
	// 防御性二次过滤（fail-closed）：不信任查询是唯一闸，确保该路径只暴露已发布平台模板，
	// 绝不漏出未发布 / 租户私有 / 非平台数据（即使上游 repo / 调用被误改）。
	out := make([]dom.DigitalEmployee, 0, len(items))
	for _, it := range items {
		if it.Source != "platform" || it.TenantID != 0 || it.Visibility != "platform" || it.Status != "published" {
			continue
		}
		if kind != "" {
			ak, _ := it.Metadata["agent_kind"].(string)
			if ak == "" {
				ak = "single"
			}
			if ak != kind {
				continue
			}
		}
		out = append(out, it)
	}
	return out, total, nil
}

// GetPublishedPlatformTemplate 取单个已发布平台模板（租户「从模板创建」精确预填取数）。
// fail-closed：uuid 不存在 / 未发布 / 非平台模板（草稿、租户私有、其它来源）一律视为「不存在」，
// 返回 ErrNotFound，绝不让租户后台经此路径读到未发布或非平台资产。
func (s *impl) GetPublishedPlatformTemplate(ctx context.Context, uuid string) (*dom.DigitalEmployee, error) {
	if uuid == "" {
		return nil, apperr.ErrInvalidParams.Withf("template uuid 必填")
	}
	tpl, err := s.repo.GetByUUID(ctx, uuid)
	if err != nil {
		// 仓储 not-found 原样透传为 not-found；其它错误透传。
		return nil, err
	}
	if tpl.Source != "platform" || tpl.TenantID != 0 || tpl.Visibility != "platform" || tpl.Status != "published" {
		return nil, apperr.ErrNotFound.Withf("平台模板不存在或未发布")
	}
	return tpl, nil
}

// findTenantCopyOfTemplate 幂等查找：该租户是否已有指向同一平台模板的副本。
// 用 repo.FindByTemplateSource（SQL 精确命中 tenant_id + metadata.template_source_uuid，不分页扫描、不漏数据）。
// 无命中 → (nil,nil)；其它错误透传。
func (s *impl) findTenantCopyOfTemplate(ctx context.Context, tenantID int64, templateUUID string) (*dom.DigitalEmployee, error) {
	e, err := s.repo.FindByTemplateSource(ctx, tenantID, templateUUID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return nil, nil
		}
		return nil, err
	}
	return e, nil
}

// CopyTemplateToTenant 把一个已发布平台模板复制成一份租户自己的 draft 数字员工。
// 旧的幂等复制底层能力；当前产品入口由 CreateTenantFromTemplate 创建独立快照。
func (s *impl) CopyTemplateToTenant(ctx context.Context, accountID, tenantID int64, templateUUID string, opts CopyOpts) (*CopyResult, error) {
	if tenantID <= 0 {
		return nil, apperr.ErrForbidden.Withf("CopyTemplateToTenant 需要租户上下文")
	}
	if templateUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("template uuid 必填")
	}

	tpl, err := s.repo.GetByUUID(ctx, templateUUID)
	if err != nil {
		return nil, err
	}
	// fail-closed：必须是已发布的平台模板，不复制未发布 / 跨租户 / 非平台数据。
	if tpl.Source != "platform" || tpl.TenantID != 0 || tpl.Visibility != "platform" {
		return nil, apperr.ErrInvalidParams.Withf("不是平台模板，拒绝复制")
	}
	if tpl.Status != "published" {
		return nil, apperr.ErrInvalidParams.Withf("平台模板未发布，拒绝复制")
	}

	if tpl.ExecutionLocus == "local" {
		return nil, apperr.ErrInvalidParams.Withf("本地模板请在电脑客户端创建个人数字员工")
	}

	// 幂等：已有副本 → 不重复建。但若要求发布且既有副本仍是 draft（如上次 no_runtime），本次补发布
	// （doc-15 P1 返修：避免曾经 no_runtime 创建的 draft 永远不会发布）。绝不重复创建、不覆盖其它业务字段。
	if existing, ferr := s.findTenantCopyOfTemplate(ctx, tenantID, templateUUID); ferr != nil {
		return nil, ferr
	} else if existing != nil {
		res := &CopyResult{Agent: existing, Reused: true}
		// 兼容旧的幂等复制调用时，只补齐历史副本漏装的平台 KB binding。
		// additive-only：不覆盖已有参数、不删除任何 binding，也不扩展成模板其它字段同步。
		if opts.SeededByInit {
			res.RepairedKBBindings, res.SkippedBindings = s.copyTemplateKBBindings(ctx, tpl.ID, existing.ID, accountID, false)
			// 技能同样 additive-only 补齐（"从平台模板补齐"修复历史副本没抄进新表的技能）。
			var skSkipped []string
			res.RepairedSkillBindings, skSkipped = s.copyTemplateSkillBindings(ctx, tpl.ID, existing.ID, accountID)
			res.SkippedBindings = append(res.SkippedBindings, skSkipped...)
			if res.RepairedKBBindings > 0 || res.RepairedSkillBindings > 0 {
				s.notify(ctx, agentPayload(existing.ID))
				if existing.Status == "published" {
					s.enqueueRuntimeResync(ctx, existing.TenantID, existing.UUID, "binding_change")
				}
				s.auditAfter(ctx, "audit.agent.platform_kb_bindings_repaired", tenantID, accountID,
					"agent_platform_kb_repair:"+strconv.FormatInt(existing.ID, 10),
					map[string]any{
						"resource_kind":           "agent",
						"resource_uuid":           existing.UUID,
						"template_uuid":           templateUUID,
						"repaired_kb_bindings":    res.RepairedKBBindings,
						"repaired_skill_bindings": res.RepairedSkillBindings,
					})
			}
		}
		if !opts.PublishAfterCopy || existing.Status == "published" {
			return res, nil
		}
		for _, item := range res.SkippedBindings {
			if strings.HasPrefix(item, "knowledge_base:") {
				res.PublishSkippedReason = "knowledge_base_binding_unavailable"
				return res, nil
			}
		}
		// 需要补发布：确保有可用 runtime。
		if !isSupportBuiltinAgent(existing) && (existing.RuntimeEnvironmentID == nil || *existing.RuntimeEnvironmentID <= 0) {
			if opts.RuntimeEnvironmentID == nil || *opts.RuntimeEnvironmentID <= 0 {
				res.PublishSkippedReason = "no_runtime"
				return res, nil
			}
			// 仅安全更新 RuntimeEnvironmentID（载入的是完整行，其它字段原样写回，不覆盖业务字段）。
			existing.RuntimeEnvironmentID = opts.RuntimeEnvironmentID
			updated, uerr := s.Update(ctx, accountID, tenantID, existing)
			if uerr != nil {
				res.PublishSkippedReason = "runtime_update_failed: " + uerr.Error()
				return res, nil
			}
			existing = updated
			res.Agent = updated
		}
		_, published, perr := s.PublishVersion(ctx, accountID, tenantID, existing.ID, "tenant init re-publish from template "+templateUUID)
		if perr != nil {
			res.PublishSkippedReason = perr.Error()
			return res, nil
		}
		res.Agent = published
		res.Published = true
		return res, nil
	}

	// 组装副本：复制业务字段，强制租户归属 / source=enterprise / draft。
	visibility := opts.Visibility
	if visibility == "" {
		visibility = "tenant"
	}
	contactEnabled := tpl.ContactEnabled
	if opts.ContactEnabled != nil {
		contactEnabled = *opts.ContactEnabled
	}
	runtimeEnv := tpl.RuntimeEnvironmentID
	if !isSupportBuiltinAgent(tpl) && opts.RuntimeEnvironmentID != nil {
		runtimeEnv = opts.RuntimeEnvironmentID
	}

	meta, missing := buildCopyMetadata(tpl.Metadata, templateUUID, opts.ChildRemap)
	if opts.SeededByInit {
		meta["tenant_init_seed"] = true
	}

	copyAgent := &dom.DigitalEmployee{
		Name:                 tpl.Name,
		AvatarURL:            tpl.AvatarURL,
		Intro:                tpl.Intro,
		Description:          tpl.Description,
		WelcomeMsg:           tpl.WelcomeMsg,
		RecommendedQuestions: cloneStrings(tpl.RecommendedQuestions),
		Tags:                 cloneStrings(tpl.Tags),
		PositionLabel:        tpl.PositionLabel,
		Badges:               cloneStrings(tpl.Badges),
		ModelPrimary:         tpl.ModelPrimary,
		ModelFallbacks:       cloneStrings(tpl.ModelFallbacks),
		Temperature:          tpl.Temperature,
		ContextWindow:        tpl.ContextWindow,
		ToolAllow:            cloneStrings(tpl.ToolAllow),
		ToolDeny:             cloneStrings(tpl.ToolDeny),
		CapabilitiesDeclared: tpl.CapabilitiesDeclared,
		SupportsGroupChat:    tpl.SupportsGroupChat,
		AllowInviteToGroup:   tpl.AllowInviteToGroup,
		RuntimeEnvironmentID: runtimeEnv,
		A2ACardJSON:          tpl.A2ACardJSON,
		Metadata:             meta,
		// 强制租户归属 + 复制语义：
		Visibility:     visibility,
		WorkspaceID:    opts.WorkspaceID,
		ContactEnabled: contactEnabled,
		Source:         "enterprise",
		Status:         "draft", // 始终 draft；发布走既有 PublishVersion（doc-15 §3.4）
		// A2A 入站白名单不跨租户复制：交给 Create 使用当前默认协作口径（mode=all）。
		CallableByAgentsJSON: "",
	}

	// 复用既有 Create（强制 TenantID/CreatorID、校验 runtime bindable、审计、notify）。
	out, err := s.create(ctx, accountID, tenantID, copyAgent, opts.SeededByInit)
	if err != nil {
		return nil, err
	}

	// 复制能力绑定（v1 只复制 composer_skill / app；其余 kind 记入 SkippedBindings）。
	skipped := s.copyTemplateBindings(ctx, tpl.ID, out.ID)
	_, kbSkipped := s.copyTemplateKBBindings(ctx, tpl.ID, out.ID, accountID, true)
	skipped = append(skipped, kbSkipped...)
	// 技能：老表 composer_skill 绑定翻译成 agent_skill_bindings，否则租户侧看不到、runtime 会话 agent_skills=[]。
	_, skSkipped := s.copyTemplateSkillBindings(ctx, tpl.ID, out.ID, accountID)
	skipped = append(skipped, skSkipped...)

	result := &CopyResult{Agent: out, MissingChildUUIDs: missing, SkippedBindings: skipped}

	// PublishAfterCopy（租户初始化）：必须有可用 runtime 才发布；否则保持 draft + 说明，绝不产出坏 published。
	if opts.PublishAfterCopy {
		for _, item := range skipped {
			if strings.HasPrefix(item, "knowledge_base:") {
				result.PublishSkippedReason = "knowledge_base_binding_unavailable"
				return result, nil
			}
		}
		if !isSupportBuiltinAgent(out) && (out.RuntimeEnvironmentID == nil || *out.RuntimeEnvironmentID <= 0) {
			result.PublishSkippedReason = "no_runtime"
			return result, nil
		}
		_, published, perr := s.PublishVersion(ctx, accountID, tenantID, out.ID, "tenant init from template "+templateUUID)
		if perr != nil {
			result.PublishSkippedReason = perr.Error() // 发布/同步失败 → 保持 draft，诚实记录
			return result, nil
		}
		result.Agent = published
		result.Published = true
	}
	return result, nil
}

// copyTemplateBindings 把模板的能力绑定复制到副本。v1 只复制 composer_skill / app（borrow）。
// 返回未复制的绑定（kind:uuid）。best-effort：单条复制失败记入 skipped，不中断整体复制。
func (s *impl) copyTemplateBindings(ctx context.Context, templateID, copyID int64) []string {
	binds, err := s.repo.ListBindings(ctx, templateID)
	if err != nil || len(binds) == 0 {
		return nil
	}
	var skipped []string
	for _, b := range binds {
		// knowledge_base 已切到 agent_kb_bindings 单一真相源；旧表中的同名记录是开发期
		// cutover 前残留，不能再据此判定模板缺失绑定或阻止租户副本发布。
		if b.CapabilityKind == "a2a_invoke" || b.CapabilityKind == "knowledge_base" {
			continue
		}
		if b.CapabilityKind != "composer_skill" && b.CapabilityKind != "app" {
			skipped = append(skipped, b.CapabilityKind+":"+b.CapabilityUUID)
			continue
		}
		nb := &dom.CapabilityBinding{
			DigitalEmpID:   copyID,
			CapabilityKind: b.CapabilityKind,
			CapabilityUUID: b.CapabilityUUID,
			Source:         "borrow",
			GrantedTools:   cloneStrings(b.GrantedTools),
			GrantedScopes:  cloneStrings(b.GrantedScopes),
			SortOrder:      b.SortOrder,
			Pinned:         b.Pinned,
			RecallConfig:   b.RecallConfig,
		}
		if _, err := s.repo.AddBinding(ctx, nb); err != nil {
			skipped = append(skipped, b.CapabilityKind+":"+b.CapabilityUUID)
		}
	}
	return skipped
}

// copyTemplateSkillBindings 把模板技能绑定翻译到副本的 agent_skill_bindings（见 platformSkillBindingCopier）。
// 纯单测/未注入 copier 且无 pool → 跳过；生产进程有 pool 却未注入 → fail-closed 记 skipped。
func (s *impl) copyTemplateSkillBindings(ctx context.Context, templateID, copyID, createdBy int64) (int, []string) {
	copier, ok := s.repo.(platformSkillBindingCopier)
	if !ok {
		if s.pool == nil {
			return 0, nil
		}
		return 0, []string{"skill:*"}
	}
	copied, skipped, err := copier.CopyPlatformSkillBindings(ctx, templateID, copyID, createdBy)
	if err != nil {
		skipped = append(skipped, "skill:*")
	}
	return copied, skipped
}

func (s *impl) copyTemplateKBBindings(ctx context.Context, templateID, copyID, createdBy int64, overwrite bool) (int, []string) {
	copier, ok := s.repo.(platformKBBindingCopier)
	if !ok {
		// 纯单测/未启用 KB 集成可没有 copier；生产进程有 pool 却未注入正确 repository 时 fail-closed。
		if s.pool == nil {
			return 0, nil
		}
		return 0, []string{"knowledge_base:*"}
	}
	copied, skipped, err := copier.CopyPlatformKBBindings(ctx, templateID, copyID, createdBy, overwrite)
	if err != nil {
		skipped = append(skipped, "knowledge_base:*")
	}
	return copied, skipped
}

// buildCopyMetadata 深拷贝模板 metadata（JSON round-trip 避免共享 map），写入 template_source_uuid，
// 并对编排型 child_agent_uuids 做 remap（未命中记入 missing，不伪造 uuid）。
func buildCopyMetadata(src map[string]any, templateUUID string, childRemap map[string]string) (map[string]any, []string) {
	meta := map[string]any{}
	if len(src) > 0 {
		if raw, err := json.Marshal(src); err == nil {
			_ = json.Unmarshal(raw, &meta)
		}
	}
	meta[MetadataTemplateSourceKey] = templateUUID

	var missing []string
	if kind, _ := meta["agent_kind"].(string); kind == "orchestrator" {
		orch, _ := meta["orchestration"].(map[string]any)
		if orch == nil {
			orch = map[string]any{}
		}
		rawChildren, _ := orch["child_agent_uuids"].([]any)
		remapped := make([]any, 0, len(rawChildren))
		for _, c := range rawChildren {
			cu, _ := c.(string)
			if cu == "" {
				continue
			}
			if tenantUUID, ok := childRemap[cu]; ok && tenantUUID != "" {
				remapped = append(remapped, tenantUUID)
			} else {
				missing = append(missing, cu) // 未命中：不伪造 uuid
			}
		}
		orch["child_agent_uuids"] = remapped
		meta["orchestration"] = orch
	}
	return meta, missing
}

func cloneStrings(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	out := make([]string, len(in))
	copy(out, in)
	return out
}

func isOrchestratorTemplate(tpl dom.DigitalEmployee) bool {
	kind, _ := tpl.Metadata["agent_kind"].(string)
	return kind == "orchestrator"
}
