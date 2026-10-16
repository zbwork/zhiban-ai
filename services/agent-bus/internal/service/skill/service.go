// Package skill 是 F03 v0.9.1 技能服务层 — 编排领域接口 + 业务校验。
//
// 详见 docs/features/F03-skills.md §3。
package skill

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	dombilling "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/billing"
	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// AgentLookup 解 agent_uuid → (id, tenant_id, integration_mode) 的窄抽象，
// 由 cmd/admin / cmd/bus 注入；service 借此在租户域 / 客户端域操作时定位 agent。
//
// 与 composer.AgentLookup 相同形态但本包独立持有，避免循环依赖。
type AgentLookup interface {
	GetAgentByUUID(ctx context.Context, uuid string) (*AgentInfo, error)
}

// AgentInfo skill service 视角下的 agent 关键字段。
type AgentInfo struct {
	ID               int64
	UUID             string
	TenantID         int64
	CreatorID        int64
	Source           string
	IntegrationMode  string // self_hosted / hybrid / platform_managed
	RuntimeFramework string // openclaw / hermes / dsh / codex_app_server / zap
	RuntimeKind      string // metadata.runtime_kind；support_builtin 禁止客户端正式技能绑定
	AgentKey         string // metadata.agent_key；zhiban-support 兼容识别
}

// AgentInfoFromEmployee shares the local-engine identity between Bus and Admin.
// Cloud framework is resolved by the caller from its runtime environment.
func AgentInfoFromEmployee(e *domagent.DigitalEmployee) *AgentInfo {
	info := &AgentInfo{ID: e.ID, UUID: e.UUID, TenantID: e.TenantID, CreatorID: e.CreatorID, Source: e.Source}
	if e.Metadata != nil {
		info.RuntimeKind, _ = e.Metadata["runtime_kind"].(string)
		info.AgentKey, _ = e.Metadata["agent_key"].(string)
	}
	if e.ExecutionLocus == "local" {
		info.IntegrationMode = "platform_managed"
		info.RuntimeFramework = e.LocalEngine
		if info.RuntimeFramework == "" {
			info.RuntimeFramework = "dsh"
		}
	}
	return info
}

// Service 业务实现；通过 domain.Repository 操作 SQL。
type Service struct {
	repo     domskill.Repository
	agents   AgentLookup   // 可空：仅平台 admin 域不需要 agent 解析时；租户/客户端域必填。
	cfg      Config        // §11 env 配置快照
	packages *PackageStore // §4.7 SKILL.md zip 对象存储；可空（平台云盘未配置时）
	billing  dombilling.Service
	audit    AuditPublisher
	// resync (doc-12 §11.5 Task C/C-2): 绑定变化后入队运行端增量同步信号 (Attach/Patch→install resync; Detach→skill_unbind 卸载)。
	// 可空 (单测/未接通)。**这里才是 Task B install 真实绑定表 agent_skill_bindings 的写入点** (不是 agent.AddBinding)。
	resync RuntimeResyncEnqueuer
}

// AuditPublisher mirrors the existing admin audit adapter contract. Bundle
// events are platform scoped and never include package contents or signed URLs.
type AuditPublisher interface {
	PublishWithTx(ctx context.Context, topic string, tenantID int64, idempKey string, payload map[string]any) error
}

// RuntimeResyncEnqueuer 入队运行端增量同步信号 (doc-12 §11.5 Task C/C-2)。由 cmd 用 runtime_resync_outbox 仓储实现。
// **不阻塞绑定操作、不改历史会话**; 失败 best-effort (信号缺失下次绑定变化会再触发, 或登录预热兜底)。
type RuntimeResyncEnqueuer interface {
	EnqueueResync(ctx context.Context, tenantID int64, deUUID, reason string) error
	EnqueueSkillUnbind(ctx context.Context, tenantID int64, deUUID, skillUUID string) error
}

// SetPackageStore 注入 §4.7 SKILL.md 包存储；cmd/admin 启动时构造好后调用。
func (s *Service) SetPackageStore(p *PackageStore) { s.packages = p }

func (s *Service) SetBillingService(b dombilling.Service) { s.billing = b }

func (s *Service) SetAuditPublisher(a AuditPublisher) { s.audit = a }

// SetRuntimeResync 注入运行端增量同步入队器 (doc-12 §11.5 Task C/C-2); cmd/admin 启动时调。nil → 不入队。
func (s *Service) SetRuntimeResync(e RuntimeResyncEnqueuer) { s.resync = e }

// enqueueResync 绑定 install 变化后入队全量 resync (best-effort, 不阻塞)。reason ∈ binding_change 等。
func (s *Service) enqueueResync(ctx context.Context, tenantID int64, deUUID, reason string) {
	if s.resync == nil || tenantID <= 0 || deUUID == "" {
		return
	}
	_ = s.resync.EnqueueResync(ctx, tenantID, deUUID, reason) // best-effort: 失败下次变化/登录预热兜底
}

// New 构造（仅平台 admin 域使用；租户/客户端路由请用 NewWithAgents）。
func New(repo domskill.Repository) *Service {
	return &Service{repo: repo, cfg: LoadConfig()}
}

// NewWithAgents 构造完整 service（含 agent 解析）。
func NewWithAgents(repo domskill.Repository, agents AgentLookup) *Service {
	return &Service{repo: repo, agents: agents, cfg: LoadConfig()}
}

// 编译期断言：实现 domain.Service。
var _ domskill.Service = (*Service)(nil)

// codePattern 业务唯一 key 正则（spec §3.1.A）。
var codePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{2,63}$`)

// semverPattern 接受 v0.9.1 范围内的 semver MAJOR.MINOR.PATCH。
// pre-release / build 后续切片再扩。
var semverPattern = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

// emptyJSONArr 主表 input_chips_schema 强制 [] 时用。
var emptyJSONArr = []byte(`[]`)
var emptyJSONObj = []byte(`{}`)

// ============================================================================
// skills CRUD
// ============================================================================

// CreateSkill 对应 §3.1.A POST /platform/skills（kind=builtin 时同步建 v0.1.0 draft）。
func (s *Service) CreateSkill(ctx context.Context, in domskill.CreateSkillInput) (*domskill.Skill, *domskill.SkillVersion, error) {
	return s.createSkill(ctx, in, codePattern)
}

func (s *Service) createSkill(ctx context.Context, in domskill.CreateSkillInput, acceptedCodePattern *regexp.Regexp) (*domskill.Skill, *domskill.SkillVersion, error) {
	if err := validateCreateSkill(in, acceptedCodePattern); err != nil {
		return nil, nil, err
	}

	// 主表 input_chips_schema 真值源约束：kind=agent 必为 [] 空数组。
	chips := in.InputChipsSchema
	if in.Kind == domskill.KindAgent {
		chips = emptyJSONArr
	} else if len(chips) == 0 {
		chips = emptyJSONArr
	}

	compat := in.AgentCompat
	if len(compat) == 0 {
		compat = emptyJSONObj
	}

	// kind=builtin 必校 builtin_key 在白名单 + status=active。
	if in.Kind == domskill.KindBuiltin {
		if in.BuiltinKey == nil || *in.BuiltinKey == "" {
			return nil, nil, apperr.ErrInvalidParams.Withf("skill.builtin_key_required")
		}
		bk, err := s.repo.GetBuiltinKeyByCode(ctx, *in.BuiltinKey)
		if err != nil {
			if appe, ok := apperr.AsError(err); ok && appe.Code == apperr.NotFound {
				return nil, nil, apperr.ErrInvalidParams.Withf("skill.builtin_key_not_in_whitelist")
			}
			return nil, nil, err
		}
		if bk.Status != domskill.BuiltinKeyActive {
			return nil, nil, apperr.ErrInvalidParams.Withf("skill.builtin_key_deprecated")
		}
	}

	hosting := in.HostingModes
	if len(hosting) == 0 {
		hosting = []string{domskill.HostingPlatformManaged, domskill.HostingHybrid}
	}

	sk := &domskill.Skill{
		Code:               in.Code,
		Name:               in.Name,
		Description:        in.Description,
		UsageExample:       in.UsageExample,
		UsageExampleImages: normalizedUsageExampleImages(in.UsageExampleImages),
		IconURL:            in.IconURL,
		Placeholder:        in.Placeholder,
		SubmitLabel:        in.SubmitLabel,
		Kind:               in.Kind,
		BuiltinKey:         in.BuiltinKey,
		ExecutionMode:      in.ExecutionMode,
		ScopeKind:          in.ScopeKind,
		TenantID:           in.TenantID,
		Source:             in.Source,
		Visibility:         in.Visibility,
		CategoryID:         in.CategoryID,
		InputChipsSchema:   chips,
		HostingModes:       hosting,
		AgentCompat:        compat,
		DefaultAttached:    in.DefaultAttached,
		DefaultPinned:      in.DefaultPinned,
		SortOrder:          in.SortOrder,
		Status:             domskill.StatusDraft,
		CreatedBy:          in.CreatedBy,
	}
	if err := s.repo.CreateSkill(ctx, sk); err != nil {
		return nil, nil, err
	}

	// 标签绑定（可选）。
	if len(in.LabelIDs) > 0 {
		if err := s.repo.ReplaceSkillLabels(ctx, sk.ID, in.LabelIDs); err != nil {
			return sk, nil, err
		}
	}

	// kind=builtin：自动建 v0.1.0 draft + snapshot 主表当前。
	var autoVer *domskill.SkillVersion
	if sk.Kind == domskill.KindBuiltin {
		v := &domskill.SkillVersion{
			SkillID:                  sk.ID,
			Version:                  "0.1.0",
			Status:                   domskill.VersionStatusDraft,
			InputChipsSchemaSnapshot: chips,
			AgentCompatSnapshot:      compat,
			GrayscalePct:             100,
			GrayscaleStrategy:        domskill.GrayscaleTenantHash,
			GrayscaleAllowlist:       []int64{}, // DB NOT NULL
		}
		if err := s.repo.CreateVersion(ctx, v); err != nil {
			return sk, nil, err
		}
		autoVer = v
	}

	return sk, autoVer, nil
}

func validateCreateSkill(in domskill.CreateSkillInput, acceptedCodePattern *regexp.Regexp) error {
	if !acceptedCodePattern.MatchString(in.Code) {
		return apperr.ErrInvalidParams.Withf("skill.code_invalid: must match %s", acceptedCodePattern.String())
	}
	if in.Name == "" {
		return apperr.ErrInvalidParams.Withf("skill.name_required")
	}
	switch in.Kind {
	case domskill.KindAgent, domskill.KindBuiltin:
	default:
		return apperr.ErrInvalidParams.Withf("skill.kind_invalid")
	}
	if in.Kind == domskill.KindAgent && in.BuiltinKey != nil && *in.BuiltinKey != "" {
		return apperr.ErrInvalidParams.Withf("skill.kind_inconsistency: kind=agent must not carry builtin_key")
	}
	switch in.ExecutionMode {
	case domskill.ExecutionSyncInline, domskill.ExecutionAsyncFloating:
	default:
		return apperr.ErrInvalidParams.Withf("skill.execution_mode_invalid")
	}
	if in.Kind == domskill.KindAgent && in.ExecutionMode != domskill.ExecutionSyncInline {
		return apperr.ErrInvalidParams.Withf("skill.kind_agent_must_sync_inline")
	}
	switch in.ScopeKind {
	case domskill.ScopePlatform:
		if in.TenantID != nil {
			return apperr.ErrInvalidParams.Withf("skill.scope_platform_must_not_carry_tenant")
		}
	case domskill.ScopeTenant:
		if in.TenantID == nil || *in.TenantID <= 0 {
			return apperr.ErrInvalidParams.Withf("skill.scope_tenant_must_carry_tenant")
		}
	default:
		return apperr.ErrInvalidParams.Withf("skill.scope_kind_invalid")
	}
	switch in.Source {
	case domskill.SourceInternal, domskill.SourceOpenSource, domskill.SourceThirdParty:
	default:
		return apperr.ErrInvalidParams.Withf("skill.source_invalid")
	}
	switch in.Visibility {
	case domskill.VisibilityPrivate, domskill.VisibilityWorkspace,
		domskill.VisibilityTenant, domskill.VisibilityPlatform:
	default:
		return apperr.ErrInvalidParams.Withf("skill.visibility_invalid")
	}
	for _, h := range in.HostingModes {
		if h != domskill.HostingPlatformManaged && h != domskill.HostingHybrid {
			return apperr.ErrInvalidParams.Withf("skill.hosting_modes_invalid: %q", h)
		}
	}
	if _, err := normalizeUsageExampleImages(in.UsageExampleImages); err != nil {
		return err
	}
	// kind=agent 必须空 input_chips_schema（DB CHECK 也会兜底；这里 service 给好错误码）
	if in.Kind == domskill.KindAgent && len(in.InputChipsSchema) > 0 {
		var arr []any
		if err := json.Unmarshal(in.InputChipsSchema, &arr); err != nil || len(arr) > 0 {
			return apperr.ErrInvalidParams.Withf("skill.chips_source_of_truth_violation: kind=agent 主表 input_chips_schema 必须 []，真值在版本 snapshot")
		}
	}
	return nil
}

func normalizedUsageExampleImages(raw []byte) []byte {
	out, err := normalizeUsageExampleImages(raw)
	if err != nil {
		return emptyJSONArr
	}
	return out
}

func normalizeUsageExampleImages(raw []byte) ([]byte, error) {
	if len(raw) == 0 {
		return emptyJSONArr, nil
	}
	var arr []map[string]any
	if err := json.Unmarshal(raw, &arr); err != nil {
		return nil, apperr.ErrInvalidParams.Withf("skill.usage_example_images_invalid")
	}
	if len(arr) > 6 {
		return nil, apperr.ErrInvalidParams.Withf("skill.usage_example_images_too_many")
	}
	out := make([]map[string]string, 0, len(arr))
	for _, item := range arr {
		storageURI := strings.TrimSpace(stringFromAny(item["storage_uri"]))
		if storageURI == "" {
			storageURI = strings.TrimSpace(stringFromAny(item["url"]))
		}
		fileName := strings.TrimSpace(stringFromAny(item["file_name"]))
		if fileName == "" {
			fileName = strings.TrimSpace(stringFromAny(item["fileName"]))
		}
		if storageURI == "" {
			continue
		}
		if !(strings.HasPrefix(storageURI, "oss://skill-example-images/") ||
			strings.HasPrefix(storageURI, "https://") ||
			strings.HasPrefix(storageURI, "http://")) {
			return nil, apperr.ErrInvalidParams.Withf("skill.usage_example_images_invalid")
		}
		out = append(out, map[string]string{
			"storage_uri": storageURI,
			"file_name":   fileName,
		})
	}
	buf, err := json.Marshal(out)
	if err != nil {
		return nil, err
	}
	return buf, nil
}

func stringFromAny(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// GetSkill 直传 repo。
func (s *Service) GetSkill(ctx context.Context, uuid string) (*domskill.Skill, error) {
	return s.repo.GetSkillByUUID(ctx, uuid, false)
}

// ListSkills 直传 repo。
func (s *Service) ListSkills(ctx context.Context, f domskill.ListFilter) ([]domskill.Skill, int64, error) {
	return s.repo.ListSkills(ctx, f)
}

// ListMarketingShowcase 官网技能商店（对外营销）展示：平台精选技能公开投影，直传 repo。
func (s *Service) ListMarketingShowcase(ctx context.Context, limit int) ([]domskill.ShowcaseItem, error) {
	return s.repo.ListMarketingShowcase(ctx, limit)
}

// PatchSkill 字段白名单 + kind 一致性校验（不允许通过 PATCH 改 kind / scope_kind / code / tenant_id / builtin_key）。
func (s *Service) PatchSkill(ctx context.Context, uuid string, in domskill.PatchSkillInput) (*domskill.Skill, error) {
	cur, err := s.repo.GetSkillByUUID(ctx, uuid, false)
	if err != nil {
		return nil, err
	}
	fields := map[string]any{}
	if in.Name != nil {
		if *in.Name == "" {
			return nil, apperr.ErrInvalidParams.Withf("skill.name_required")
		}
		fields["name"] = *in.Name
	}
	if in.Description != nil {
		fields["description"] = *in.Description
	}
	if in.UsageExample != nil {
		fields["usage_example"] = *in.UsageExample
	}
	if in.UsageExampleImages != nil {
		images, err := normalizeUsageExampleImages(in.UsageExampleImages)
		if err != nil {
			return nil, err
		}
		fields["usage_example_images"] = string(images)
	}
	if in.IconURL != nil {
		fields["icon_url"] = *in.IconURL
	}
	if in.Placeholder != nil {
		fields["placeholder"] = *in.Placeholder
	}
	if in.SubmitLabel != nil {
		fields["submit_label"] = *in.SubmitLabel
	}
	if in.ExecutionMode != nil {
		switch *in.ExecutionMode {
		case domskill.ExecutionSyncInline, domskill.ExecutionAsyncFloating:
		default:
			return nil, apperr.ErrInvalidParams.Withf("skill.execution_mode_invalid")
		}
		if cur.Kind == domskill.KindAgent && *in.ExecutionMode != domskill.ExecutionSyncInline {
			return nil, apperr.ErrInvalidParams.Withf("skill.kind_agent_must_sync_inline")
		}
		fields["execution_mode"] = *in.ExecutionMode
	}
	if in.Visibility != nil {
		switch *in.Visibility {
		case domskill.VisibilityPrivate, domskill.VisibilityWorkspace,
			domskill.VisibilityTenant, domskill.VisibilityPlatform:
		default:
			return nil, apperr.ErrInvalidParams.Withf("skill.visibility_invalid")
		}
		fields["visibility"] = *in.Visibility
	}
	if in.ClearCategory {
		fields["category_id"] = nil
	} else if in.CategoryID != nil {
		fields["category_id"] = *in.CategoryID
	}
	if in.Source != nil {
		switch *in.Source {
		case domskill.SourceInternal, domskill.SourceOpenSource, domskill.SourceThirdParty:
		default:
			return nil, apperr.ErrInvalidParams.Withf("skill.source_invalid")
		}
		fields["source"] = *in.Source
	}
	if in.HostingModes != nil {
		for _, h := range *in.HostingModes {
			if h != domskill.HostingPlatformManaged && h != domskill.HostingHybrid {
				return nil, apperr.ErrInvalidParams.Withf("skill.hosting_modes_invalid: %q", h)
			}
		}
		fields["hosting_modes"] = *in.HostingModes
	}
	if in.AgentCompat != nil {
		fields["agent_compat"] = string(in.AgentCompat)
	}
	if in.InputChipsSchema != nil {
		// kind=agent 不能改主表 input_chips_schema（D27 约束）。
		if cur.Kind == domskill.KindAgent {
			var arr []any
			if err := json.Unmarshal(in.InputChipsSchema, &arr); err != nil || len(arr) > 0 {
				return nil, apperr.ErrInvalidParams.Withf("skill.chips_source_of_truth_violation")
			}
			// agent 类允许传 [] 维持 NoOp，不设 fields（DB CHECK 会过）
		} else {
			fields["input_chips_schema"] = string(in.InputChipsSchema)
		}
	}
	if in.DefaultAttached != nil {
		fields["default_attached"] = *in.DefaultAttached
	}
	if in.DefaultPinned != nil {
		fields["default_pinned"] = *in.DefaultPinned
	}
	if in.SortOrder != nil {
		fields["sort_order"] = *in.SortOrder
	}
	if in.Status != nil {
		switch *in.Status {
		case domskill.StatusDraft, domskill.StatusActive, domskill.StatusArchived:
		default:
			return nil, apperr.ErrInvalidParams.Withf("skill.status_invalid")
		}
		fields["status"] = *in.Status
	}
	if in.MarketingVisible != nil {
		fields["marketing_visible"] = *in.MarketingVisible
	}

	updated, err := s.repo.PatchSkill(ctx, uuid, fields, in.UpdatedBy)
	if err != nil {
		return nil, err
	}

	// 标签全量替换（in.LabelIDs 非 nil 即使空数组也替换）。
	if in.LabelIDs != nil {
		if err := s.repo.ReplaceSkillLabels(ctx, updated.ID, *in.LabelIDs); err != nil {
			return updated, err
		}
	}

	return updated, nil
}

// SoftDeleteSkill 删除（spec §3.1.0.A：仅写删除字段，不混用 status，不级联 version）。
func (s *Service) SoftDeleteSkill(ctx context.Context, uuid string, accountID int64) error {
	_ = accountID // 后续 audit 用
	sk, err := s.repo.GetSkillByUUID(ctx, uuid, false)
	if err != nil {
		return err
	}
	if err := s.repo.SoftDeleteSkill(ctx, uuid); err != nil {
		return err
	}
	s.notifyf(ctx, "skills:%d", sk.ID)
	return nil
}

// ============================================================================
// 版本生命周期
// ============================================================================

// CreateAgentVersion 上传新 agent 版本（draft）；spec §3.1.B。
//
// 两种使用模式：
//  1. 「先传包再建版本」（spec 原始假设）：调用方先把 zip 上传到对象存储拿到
//     URL/sha256/size，再调本接口；此时三个字段必填且校验。
//  2. 「先建版本再调 upload-package」（admin 新建技能 + zip 一步出 UX）：
//     调用方传 sentinel PackageURL="pending://upload"、PackageSizeBytes=0、
//     PackageSHA256=""；版本以 draft 状态创建，由后续 UploadSkillPackage 回写
//     真实 package_url / package_sha256 / package_size_bytes（spec §4.7）。
//     发布前的检查仍由 PublishVersion 兜底，确保 pending 版本不能直接 publish。
func (s *Service) CreateAgentVersion(ctx context.Context, in domskill.CreateAgentVersionInput) (*domskill.SkillVersion, error) {
	if !semverPattern.MatchString(in.Version) {
		return nil, apperr.ErrInvalidParams.Withf("skill.version_invalid: must be semver MAJOR.MINOR.PATCH")
	}
	pendingUpload := in.PackageURL == "pending://upload"
	if !pendingUpload {
		if in.PackageURL == "" {
			return nil, apperr.ErrInvalidParams.Withf("skill.package_url_required")
		}
		if in.PackageSizeBytes <= 0 {
			return nil, apperr.ErrInvalidParams.Withf("skill.package_size_required")
		}
		if in.PackageSizeBytes > domskill.PackageMaxBytes {
			return nil, apperr.ErrInvalidParams.Withf("skill.package_too_large")
		}
	}

	sk, err := s.repo.GetSkillByUUID(ctx, in.SkillUUID, false)
	if err != nil {
		return nil, err
	}
	if sk.Kind != domskill.KindAgent {
		return nil, apperr.ErrInvalidParams.Withf("skill.kind_not_agent: use /builtin-versions for builtin skills")
	}

	chips := in.InputChipsSchemaSnapshot
	if len(chips) == 0 {
		chips = emptyJSONArr
	}
	compat := in.AgentCompatSnapshot
	if len(compat) == 0 {
		compat = emptyJSONObj
	}

	v := &domskill.SkillVersion{
		SkillID:                  sk.ID,
		Version:                  in.Version,
		Status:                   domskill.VersionStatusDraft,
		Changelog:                in.Changelog,
		PackageURL:               in.PackageURL,
		PackageSHA256:            in.PackageSHA256,
		PackageSizeBytes:         &in.PackageSizeBytes,
		InputChipsSchemaSnapshot: chips,
		AgentCompatSnapshot:      compat,
		GrayscalePct:             100,
		GrayscaleStrategy:        domskill.GrayscaleTenantHash,
		GrayscaleAllowlist:       []int64{}, // DB BIGINT[] NOT NULL，避免 nil 触发 23502
	}
	if err := s.repo.CreateVersion(ctx, v); err != nil {
		return nil, err
	}
	return v, nil
}

// CreateBuiltinVersion 发 builtin 新版本；spec §3.1.C.3。
func (s *Service) CreateBuiltinVersion(ctx context.Context, in domskill.CreateBuiltinVersionInput) (*domskill.SkillVersion, error) {
	if !semverPattern.MatchString(in.Version) {
		return nil, apperr.ErrInvalidParams.Withf("skill.version_invalid")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, in.SkillUUID, false)
	if err != nil {
		return nil, err
	}
	if sk.Kind != domskill.KindBuiltin {
		return nil, apperr.ErrInvalidParams.Withf("skill.kind_not_builtin")
	}

	// 差异校验：跟最新 published version snapshot 比较。
	latest, err := s.repo.GetLatestPublishedVersion(ctx, sk.ID)
	if err != nil {
		return nil, err
	}
	if latest != nil {
		if jsonEqual(latest.InputChipsSchemaSnapshot, sk.InputChipsSchema) &&
			jsonEqual(latest.AgentCompatSnapshot, sk.AgentCompat) {
			return nil, apperr.ErrInvalidParams.Withf("skill.schema_no_change")
		}
	}

	pct := in.GrayscalePct
	if pct == 0 {
		pct = 100
	}
	strategy := in.GrayscaleStrategy
	if strategy == "" {
		strategy = domskill.GrayscaleTenantHash
	}

	v := &domskill.SkillVersion{
		SkillID:                  sk.ID,
		Version:                  in.Version,
		Status:                   domskill.VersionStatusDraft,
		Changelog:                in.Changelog,
		InputChipsSchemaSnapshot: sk.InputChipsSchema,
		AgentCompatSnapshot:      sk.AgentCompat,
		GrayscalePct:             pct,
		GrayscaleStrategy:        strategy,
		GrayscaleAllowlist:       in.GrayscaleAllowlist,
	}
	if v.GrayscaleAllowlist == nil {
		v.GrayscaleAllowlist = []int64{} // DB NOT NULL
	}
	if err := s.repo.CreateVersion(ctx, v); err != nil {
		return nil, err
	}
	return v, nil
}

// PatchVersion 改 changelog / grayscale；status ∈ (draft, published) 才允许；
// 改 grayscale_pct < 100 必须保证至少有一个其他 100 baseline（不变量 A）。
func (s *Service) PatchVersion(ctx context.Context, uuid string, in domskill.PatchVersionInput) (*domskill.SkillVersion, error) {
	cur, err := s.repo.GetVersionByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if cur.Status == domskill.VersionStatusArchived {
		return nil, apperr.ErrConflict.Withf("skill.version_status_locked")
	}

	fields := map[string]any{}
	newPct := cur.GrayscalePct
	if in.Changelog != nil {
		fields["changelog"] = *in.Changelog
	}
	if in.GrayscalePct != nil {
		if *in.GrayscalePct < 0 || *in.GrayscalePct > 100 {
			return nil, apperr.ErrInvalidParams.Withf("skill.grayscale_pct_invalid")
		}
		fields["grayscale_pct"] = *in.GrayscalePct
		newPct = *in.GrayscalePct
	}
	if in.GrayscaleStrategy != nil {
		switch *in.GrayscaleStrategy {
		case domskill.GrayscaleTenantHash, domskill.GrayscaleAgentHash,
			domskill.GrayscaleUserHash, domskill.GrayscaleTenantAllowlist:
		default:
			return nil, apperr.ErrInvalidParams.Withf("skill.grayscale_strategy_invalid")
		}
		fields["grayscale_strategy"] = *in.GrayscaleStrategy
	}
	if in.GrayscaleAllowlist != nil {
		fields["grayscale_allowlist"] = *in.GrayscaleAllowlist
	}

	// 不变量 A：改后若 < 100 且当前 published，必须排除自身后还有 100 baseline。
	if cur.Status == domskill.VersionStatusPublished && newPct < 100 {
		n, err := s.repo.CountPublishedFullBaselineExcluding(ctx, cur.SkillID, cur.ID)
		if err != nil {
			return nil, err
		}
		if n == 0 {
			return nil, apperr.ErrInvalidParams.Withf("skill.no_baseline_for_grayscale")
		}
	}

	return s.repo.UpdateVersion(ctx, uuid, fields)
}

// PublishVersion draft → published；首版同时把 skill 切 active；按 published_at 单调更新 latest。
func (s *Service) PublishVersion(ctx context.Context, uuid string, in domskill.PublishVersionInput) (*domskill.SkillVersion, error) {
	cur, err := s.repo.GetVersionByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if cur.Status != domskill.VersionStatusDraft {
		return nil, apperr.ErrConflict.Withf("skill.version_status_locked")
	}
	sk, err := s.repo.GetSkillByID(ctx, cur.SkillID)
	if err != nil {
		return nil, err
	}
	// Agent 技能走「先建版本再传包」流程，未上传完成的 draft 不允许 publish。
	// Builtin 技能没有 SKILL.md 包，不应被 package_url 拦截。
	if sk.Kind == domskill.KindAgent && (cur.PackageURL == "" || cur.PackageURL == "pending://upload") {
		return nil, apperr.ErrInvalidParams.Withf("skill.package_pending_upload")
	}

	// 灰度参数（覆盖 cur）。
	pct := cur.GrayscalePct
	if in.GrayscalePct != nil {
		pct = *in.GrayscalePct
	}
	strategy := cur.GrayscaleStrategy
	if in.GrayscaleStrategy != nil {
		strategy = *in.GrayscaleStrategy
	}
	allowlist := cur.GrayscaleAllowlist
	if in.GrayscaleAllowlist != nil {
		allowlist = in.GrayscaleAllowlist
	}

	// 不变量 A：< 100 时 skill 必须已有至少一个 100 published baseline。
	if pct < 100 {
		latest, err := s.repo.GetLatestPublishedVersion(ctx, cur.SkillID)
		if err != nil {
			return nil, err
		}
		if latest == nil {
			return nil, apperr.ErrInvalidParams.Withf("skill.no_baseline_for_grayscale")
		}
		// 必须 >= 1 个 100 baseline（latest 不一定 100，所以再 count 一下）。
		n, err := s.repo.CountPublishedFullBaselineExcluding(ctx, cur.SkillID, 0)
		if err != nil {
			return nil, err
		}
		if n == 0 {
			return nil, apperr.ErrInvalidParams.Withf("skill.no_baseline_for_grayscale")
		}
	}

	// 把 publish 流程合成 2 条 SQL（详见 repo.PublishVersionAtomic 注释）：
	//   - skill_versions: 灰度 + status=published + published_at
	//   - skills: latest_version_id（按 published_at 单调）+ 首版 draft→active
	// 替代原先 5 条串行 RTT，远端 PG 链路下端到端可省 ~2 秒（spec §3.1.B/§3.1.0.D）。
	if allowlist == nil {
		allowlist = []int64{}
	}
	updatedVer, err := s.repo.PublishVersionAtomic(ctx, uuid, pct, strategy, allowlist)
	if err != nil {
		return nil, err
	}
	_ = sk // skill 信息已并入原子 SQL；此处保留变量便于后续 audit/notify 拓展。

	s.notifyf(ctx, "skills:%d", cur.SkillID)
	return updatedVer, nil
}

// ArchiveVersion published → archived；spec §3.1.D 不变量 A+B 校验。
func (s *Service) ArchiveVersion(ctx context.Context, uuid string) (*domskill.SkillVersion, error) {
	cur, err := s.repo.GetVersionByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if cur.Status != domskill.VersionStatusPublished {
		return nil, apperr.ErrConflict.Withf("skill.version_status_locked")
	}

	sk, err := s.repo.GetSkillByID(ctx, cur.SkillID)
	if err != nil {
		return nil, err
	}
	// A. 不能 archive 当前 latest。
	if sk.LatestVersionID != nil && *sk.LatestVersionID == cur.ID {
		return nil, apperr.ErrConflict.Withf("skill.cannot_archive_current_latest")
	}
	// B. 不能 archive 最后一个 100% baseline。
	if cur.GrayscalePct == 100 {
		n, err := s.repo.CountPublishedFullBaselineExcluding(ctx, cur.SkillID, cur.ID)
		if err != nil {
			return nil, err
		}
		if n == 0 {
			return nil, apperr.ErrConflict.Withf("skill.cannot_archive_last_baseline")
		}
	}

	if err := s.repo.UpdateVersionStatus(ctx, cur.ID, domskill.VersionStatusArchived); err != nil {
		return nil, err
	}
	s.notifyf(ctx, "skills:%d", cur.SkillID)
	return s.repo.GetVersionByID(ctx, cur.ID)
}

// RollbackLatest 把 skill.latest_version_id 切到指定 published 版本；spec §3.1.E。
func (s *Service) RollbackLatest(ctx context.Context, uuid string) (*domskill.SkillVersion, error) {
	v, err := s.repo.GetVersionByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if v.Status != domskill.VersionStatusPublished {
		return nil, apperr.ErrConflict.Withf("skill.version_status_locked")
	}
	if err := s.repo.UpdateSkillLatestVersion(ctx, v.SkillID, v.ID); err != nil {
		return nil, err
	}
	s.notifyf(ctx, "skills:%d", v.SkillID)
	return v, nil
}

// ListVersions 按 created_at DESC。
func (s *Service) ListVersions(ctx context.Context, skillUUID string) ([]domskill.SkillVersion, error) {
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID, true)
	if err != nil {
		return nil, err
	}
	return s.repo.ListVersions(ctx, sk.ID)
}

// ============================================================================
// 字典只读
// ============================================================================

func (s *Service) ListCategories(ctx context.Context, f domskill.DictListFilter) ([]domskill.Category, int64, error) {
	return s.repo.ListCategories(ctx, f)
}
func (s *Service) ListLabels(ctx context.Context, f domskill.DictListFilter) ([]domskill.Label, int64, error) {
	return s.repo.ListLabels(ctx, f)
}
func (s *Service) ListBuiltinKeys(ctx context.Context, f domskill.DictListFilter) ([]domskill.BuiltinKey, int64, error) {
	return s.repo.ListBuiltinKeys(ctx, f)
}

// ============================================================================
// 字典写（spec §3.1 字典管理）
// ============================================================================

func (s *Service) CreateCategory(ctx context.Context, c *domskill.Category) error {
	if !codePattern.MatchString(c.Code) {
		return apperr.ErrInvalidParams.Withf("category.code_invalid")
	}
	if c.Name == "" {
		return apperr.ErrInvalidParams.Withf("category.name_required")
	}
	if c.CategoryKind == "" {
		c.CategoryKind = domskill.CategoryScenario
	}
	if c.CategoryKind != domskill.CategoryFoundation && c.CategoryKind != domskill.CategoryScenario {
		return apperr.ErrInvalidParams.Withf("category.kind_invalid")
	}
	return s.repo.CreateCategory(ctx, c)
}

func (s *Service) PatchCategory(ctx context.Context, id int64, fields map[string]any) (*domskill.Category, error) {
	if code, ok := fields["code"].(string); ok && !codePattern.MatchString(code) {
		return nil, apperr.ErrInvalidParams.Withf("category.code_invalid")
	}
	return s.repo.PatchCategory(ctx, id, fields)
}

func (s *Service) DeleteCategory(ctx context.Context, id int64, deletedBy *int64) error {
	return s.repo.DeleteCategory(ctx, id, deletedBy)
}

func (s *Service) CreateLabel(ctx context.Context, l *domskill.Label) error {
	if !codePattern.MatchString(l.Code) {
		return apperr.ErrInvalidParams.Withf("label.code_invalid")
	}
	if l.Name == "" {
		return apperr.ErrInvalidParams.Withf("label.name_required")
	}
	return s.repo.CreateLabel(ctx, l)
}

func (s *Service) PatchLabel(ctx context.Context, id int64, fields map[string]any) (*domskill.Label, error) {
	if code, ok := fields["code"].(string); ok && !codePattern.MatchString(code) {
		return nil, apperr.ErrInvalidParams.Withf("label.code_invalid")
	}
	return s.repo.PatchLabel(ctx, id, fields)
}

func (s *Service) DeleteLabel(ctx context.Context, id int64, deletedBy *int64) error {
	return s.repo.DeleteLabel(ctx, id, deletedBy)
}

func (s *Service) CreateBuiltinKey(ctx context.Context, b *domskill.BuiltinKey) error {
	if !codePattern.MatchString(b.Code) {
		return apperr.ErrInvalidParams.Withf("builtin_key.code_invalid")
	}
	if b.Name == "" {
		return apperr.ErrInvalidParams.Withf("builtin_key.name_required")
	}
	if b.Status == "" {
		b.Status = domskill.BuiltinKeyActive
	}
	if b.Status != domskill.BuiltinKeyActive && b.Status != domskill.BuiltinKeyDeprecated {
		return apperr.ErrInvalidParams.Withf("builtin_key.status_invalid")
	}
	if err := s.repo.CreateBuiltinKey(ctx, b); err != nil {
		return err
	}
	s.notifyf(ctx, "builtin_skill_keys:%d", b.ID)
	return nil
}

func (s *Service) PatchBuiltinKey(ctx context.Context, id int64, fields map[string]any) (*domskill.BuiltinKey, error) {
	out, err := s.repo.PatchBuiltinKey(ctx, id, fields)
	if err != nil {
		return nil, err
	}
	s.notifyf(ctx, "builtin_skill_keys:%d", id)
	return out, nil
}

func (s *Service) DeleteBuiltinKey(ctx context.Context, id int64, deletedBy *int64) error {
	if err := s.repo.DeleteBuiltinKey(ctx, id, deletedBy); err != nil {
		return err
	}
	s.notifyf(ctx, "builtin_skill_keys:%d", id)
	return nil
}

// ============================================================================
// §3.7 sandbox preview
// ============================================================================

// PreviewSkill 只做参数有效性校验 + 渲染一份示例 user_message_metadata，不真调 runtime。
func (s *Service) PreviewSkill(ctx context.Context, in domskill.PreviewSkillInput) (*domskill.PreviewSkillOutput, error) {
	if in.SkillUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("skill_uuid required")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, in.SkillUUID, false)
	if err != nil {
		return nil, err
	}
	var ver *domskill.SkillVersion
	if in.VersionUUID != "" {
		ver, err = s.repo.GetVersionByUUID(ctx, in.VersionUUID)
		if err != nil {
			return nil, err
		}
		if ver.SkillID != sk.ID {
			return nil, apperr.ErrInvalidParams.Withf("version.skill_mismatch")
		}
	} else if sk.LatestVersionID != nil {
		ver, _ = s.repo.GetVersionByID(ctx, *sk.LatestVersionID)
	}

	chipsRaw := sk.InputChipsSchema
	if ver != nil && len(ver.InputChipsSchemaSnapshot) > 0 {
		chipsRaw = ver.InputChipsSchemaSnapshot
	}
	verrs := validatePreviewParams(chipsRaw, in.Params)

	out := &domskill.PreviewSkillOutput{
		SkillUUID: sk.UUID,
		UserMessageSample: map[string]any{
			"active_skill_uuid":        sk.UUID,
			"active_skill_kind":        sk.Kind,
			"active_skill_code":        sk.Code,
			"active_skill_builtin_key": sk.BuiltinKey,
			"skill_params":             in.Params,
		},
		ValidationErrors: verrs,
	}
	if ver != nil {
		out.Version = ver.Version
		out.VersionUUID = ver.UUID
	}
	return out, nil
}

// ApplyDefaultBindings 在 agent 创建后调用：把所有 default_attached=true 且
// active+latest published skill 自动装配到该 agent，source=default_inherit。
// 已存在装配的 skill 跳过。
//
// 失败一个 skill 不阻断其它（保证最终一致；后续可由 admin 手动 retry）。
func (s *Service) ApplyDefaultBindings(ctx context.Context, agentID, accountID int64) (int, error) {
	if agentID <= 0 {
		return 0, apperr.ErrInvalidParams.Withf("agent_id required")
	}
	skills, _, err := s.repo.ListSkills(ctx, domskill.ListFilter{
		Status: domskill.StatusActive,
		Limit:  500,
	})
	if err != nil {
		return 0, err
	}
	count := 0
	for i := range skills {
		sk := skills[i]
		if !sk.DefaultAttached {
			continue
		}
		if sk.LatestVersionID == nil {
			continue
		}
		b := &domskill.AgentBinding{
			AgentID:         agentID,
			SkillID:         sk.ID,
			Pinned:          true,
			SortOrder:       0,
			PinnedVersionID: sk.LatestVersionID,
			Source:          domskill.BindingSourceDefaultInherit,
			CreatedBy:       &accountID,
			UpdatedBy:       &accountID,
		}
		if err := s.repo.UpsertAgentBinding(ctx, b); err != nil {
			continue
		}
		count++
	}
	if count > 0 {
		s.notifyf(ctx, "agent_skill_bindings:%d", agentID)
	}
	return count, nil
}

// UploadPackageInput — 走 admin multipart 上传 SKILL.md zip 时传入。
type UploadPackageInput struct {
	SkillUUID   string
	VersionUUID string
	Body        io.Reader
	UpdatedBy   *int64
}

// UploadPackageOutput — 写入对象存储 + 回写 skill_versions 行后的结果。
type UploadPackageOutput struct {
	StorageKey               string          `json:"storage_key"`
	PackageURLPlaceholder    string          `json:"package_url_placeholder"` // 未签名的 oss://… 形态，仅回显；落库存 storage key
	PackageSize              int64           `json:"package_size_bytes"`
	PackageSHA256            string          `json:"package_sha256"`
	InputChipsSchemaSnapshot json.RawMessage `json:"input_chips_schema_snapshot,omitempty"`
}

// UploadSkillPackage 把 admin 上传的 SKILL.md zip 流落对象存储 + 写回 skill_versions 行。
//
// 仅允许在 status='draft' 的版本上调用；publish 之后不可改包（spec §4.2 R3）。
func (s *Service) UploadSkillPackage(ctx context.Context, in UploadPackageInput) (*UploadPackageOutput, error) {
	if s.packages == nil {
		return nil, apperr.ErrInternal.Withf("skill package store not configured (configure platform drive storage active default)")
	}
	if in.SkillUUID == "" || in.VersionUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("skill_uuid + version_uuid required")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, in.SkillUUID, false)
	if err != nil {
		return nil, err
	}
	if sk.Kind != domskill.KindAgent {
		return nil, apperr.ErrInvalidParams.Withf("skill.kind != agent; only agent skills accept SKILL.md zip")
	}
	ver, err := s.repo.GetVersionByUUID(ctx, in.VersionUUID)
	if err != nil {
		return nil, err
	}
	if ver.SkillID != sk.ID {
		return nil, apperr.ErrInvalidParams.Withf("version.skill_mismatch")
	}
	if ver.Status != domskill.VersionStatusDraft {
		return nil, apperr.ErrConflict.Withf("skill.version_not_draft: status=%s", ver.Status)
	}

	res, err := s.packages.Upload(ctx, in.SkillUUID, ver.Version, in.Body)
	if err != nil {
		return nil, apperr.ErrInvalidParams.Withf("upload: %v", err)
	}

	// 解 frontmatter 出 input_chips_schema 写入 snapshot；YAML 待 v0.9.2，此处只接受 JSON。
	//
	// 关键策略：仅当版本现有 snapshot 为空时才写入自动解析结果。
	// 这让 admin 在版本创建时手填的 snapshot（CreateAgentVersion body 传入）
	// 不会被 zip 自动解析覆盖 —— 即"自动解析 + 手动覆盖"两套都能走。
	var snapshotJSON []byte
	if len(ver.InputChipsSchemaSnapshot) == 0 {
		if fm, err := ParseSkillMDFrontmatter(res.SkillMD); err == nil && len(fm) > 0 {
			var probe map[string]any
			if json.Unmarshal(fm, &probe) == nil {
				if chips, ok := probe["input_chips_schema"]; ok {
					if b, mErr := json.Marshal(chips); mErr == nil {
						snapshotJSON = b
					}
				}
			}
		}
	}

	fields := map[string]any{
		"package_url":        res.StorageKey, // 存 storage key；运行时 SignDownloadURL
		"package_sha256":     res.StorageSHA256,
		"package_size_bytes": res.StorageSize,
	}
	if len(snapshotJSON) > 0 {
		fields["input_chips_schema_snapshot"] = string(snapshotJSON)
	}
	if _, err := s.repo.UpdateVersion(ctx, in.VersionUUID, fields); err != nil {
		return nil, err
	}

	// §4.7 R1：双写文件清单到 skill_version_files；对象存储 zip 仍是真值源，本表是投影。
	// 失败不阻塞 upload 链路（zip 已落对象存储、版本元信息已更新），返回时记一个 hint
	// 让管理后台能感知到 manifest 缺失（用户可以重新上传同 zip 触发重写）。
	if len(res.Files) > 0 {
		manifest := make([]domskill.VersionFile, 0, len(res.Files))
		for _, pf := range res.Files {
			manifest = append(manifest, domskill.VersionFile{
				VersionID:   ver.ID,
				Path:        pf.Path,
				SizeBytes:   pf.SizeBytes,
				SHA256:      pf.SHA256,
				ContentType: pf.ContentType,
				IsBinary:    pf.IsBinary,
				Truncated:   pf.Truncated,
				ContentText: pf.ContentText,
			})
		}
		if err := s.repo.ReplaceVersionFiles(ctx, ver.ID, manifest); err != nil {
			// 记日志但不返错；upload 整体仍算成功。后续的 list/preview 走 ListVersionFiles
			// 会返回空，admin 前端可显示"文件清单缺失，请重新上传"的提示。
			// TODO(F03): 接入 logger 后正式记录；当前先 swallow。
			_ = err
		}
	}

	s.notifyf(ctx, "skills:%d", sk.ID)

	// 返回时统一把 snapshot 字段填回——若本次自动解析了用新值；否则用版本上原有手填值。
	finalSnapshot := snapshotJSON
	if len(finalSnapshot) == 0 {
		finalSnapshot = ver.InputChipsSchemaSnapshot
	}
	return &UploadPackageOutput{
		StorageKey: res.StorageKey, PackageURLPlaceholder: "oss://" + res.StorageKey,
		PackageSize: res.StorageSize, PackageSHA256: res.StorageSHA256,
		InputChipsSchemaSnapshot: json.RawMessage(finalSnapshot),
	}, nil
}

// UploadIconInput — admin multipart 上传图标时传入。
type UploadIconInput struct {
	Body        io.Reader
	ContentType string
}

// UploadIconOutput — 落对象存储后的结果。StorageURI 是写库形态（"oss://..."），
// SignedURL 是即时预览/回显形态。
type UploadIconOutput struct {
	StorageKey string `json:"storage_key"`
	StorageURI string `json:"storage_uri"`
	SignedURL  string `json:"signed_url"`
	Size       int64  `json:"size_bytes"`
	SHA256     string `json:"sha256"`
}

// UploadSkillIcon 把 admin 上传的图标流落对象存储（skill-icons/<sha256>.<ext>）。
//
// 与 UploadSkillPackage 不同的是：图标不绑定特定 skill_uuid，按内容寻址，
// 多个 skill 可以共享同一份图标对象（去重）。
// VersionFileEntry 是 list 文件清单 DTO（不含 content）。
type VersionFileEntry struct {
	Path        string `json:"path"`
	SizeBytes   int64  `json:"size_bytes"`
	SHA256      string `json:"sha256"`
	ContentType string `json:"content_type"`
	IsBinary    bool   `json:"is_binary"`
	Truncated   bool   `json:"truncated"`
}

// VersionFileContent 是单文件预览 DTO。
type VersionFileContent struct {
	Path        string `json:"path"`
	SizeBytes   int64  `json:"size_bytes"`
	SHA256      string `json:"sha256"`
	ContentType string `json:"content_type"`
	IsBinary    bool   `json:"is_binary"`
	Truncated   bool   `json:"truncated"`
	Content     string `json:"content"`     // is_binary / truncated 时为空
	TotalLines  int    `json:"total_lines"` // content 实际行数
}

// ListVersionFiles 查指定 version_uuid 下的文件清单（spec §4.7 R1）。
//
// 验证 skill_uuid 与 version 关联，避免越权读到其他 skill 的版本文件。
func (s *Service) ListVersionFiles(ctx context.Context, skillUUID, versionUUID string) ([]VersionFileEntry, error) {
	if skillUUID == "" || versionUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("skill_uuid+version_uuid required")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID, false)
	if err != nil {
		return nil, err
	}
	ver, err := s.repo.GetVersionByUUID(ctx, versionUUID)
	if err != nil {
		return nil, err
	}
	if ver.SkillID != sk.ID {
		return nil, apperr.ErrInvalidParams.Withf("version.skill_mismatch")
	}
	files, err := s.repo.ListVersionFiles(ctx, ver.ID)
	if err != nil {
		return nil, err
	}
	out := make([]VersionFileEntry, 0, len(files))
	for i := range files {
		out = append(out, VersionFileEntry{
			Path:        files[i].Path,
			SizeBytes:   files[i].SizeBytes,
			SHA256:      files[i].SHA256,
			ContentType: files[i].ContentType,
			IsBinary:    files[i].IsBinary,
			Truncated:   files[i].Truncated,
		})
	}
	return out, nil
}

// GetVersionFileContent 取单文件预览（spec §4.7 R1）。
func (s *Service) GetVersionFileContent(ctx context.Context, skillUUID, versionUUID, path string) (*VersionFileContent, error) {
	if skillUUID == "" || versionUUID == "" || path == "" {
		return nil, apperr.ErrInvalidParams.Withf("skill_uuid+version_uuid+path required")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID, false)
	if err != nil {
		return nil, err
	}
	ver, err := s.repo.GetVersionByUUID(ctx, versionUUID)
	if err != nil {
		return nil, err
	}
	if ver.SkillID != sk.ID {
		return nil, apperr.ErrInvalidParams.Withf("version.skill_mismatch")
	}
	f, err := s.repo.GetVersionFile(ctx, ver.ID, path)
	if err != nil {
		return nil, err
	}
	totalLines := 0
	if f.ContentText != "" {
		// strings.Count + 1（最后一行可能没换行符）
		totalLines = strings.Count(f.ContentText, "\n") + 1
	}
	return &VersionFileContent{
		Path:        f.Path,
		SizeBytes:   f.SizeBytes,
		SHA256:      f.SHA256,
		ContentType: f.ContentType,
		IsBinary:    f.IsBinary,
		Truncated:   f.Truncated,
		Content:     f.ContentText,
		TotalLines:  totalLines,
	}, nil
}

// SignVersionPackageURL 给 admin 前端"下载完整技能包"按钮用：把版本上记的
// storage_key 现签一个临时 URL（TTL = AGBUS_SKILL_PACKAGE_CDN_URL_TTL）。
func (s *Service) SignVersionPackageURL(ctx context.Context, skillUUID, versionUUID string) (string, error) {
	if s.packages == nil {
		return "", apperr.ErrInternal.Withf("skill package store not configured (configure platform drive storage active default)")
	}
	sk, err := s.repo.GetSkillByUUID(ctx, skillUUID, false)
	if err != nil {
		return "", err
	}
	ver, err := s.repo.GetVersionByUUID(ctx, versionUUID)
	if err != nil {
		return "", err
	}
	if ver.SkillID != sk.ID {
		return "", apperr.ErrInvalidParams.Withf("version.skill_mismatch")
	}
	if ver.PackageURL == "" || ver.PackageURL == "pending://upload" {
		return "", apperr.ErrInvalidParams.Withf("skill.package_pending_upload")
	}
	url, _, err := s.packages.SignURL(ctx, ver.PackageURL, 0)
	if err != nil {
		return "", err
	}
	return url, nil
}

func (s *Service) UploadSkillIcon(ctx context.Context, in UploadIconInput) (*UploadIconOutput, error) {
	if s.packages == nil {
		return nil, apperr.ErrInternal.Withf("skill package store not configured (configure platform drive storage active default)")
	}
	res, err := s.packages.UploadIcon(ctx, in.Body, in.ContentType)
	if err != nil {
		return nil, apperr.ErrInvalidParams.Withf("upload icon: %v", err)
	}
	signed, _, err := s.packages.SignURL(ctx, res.StorageKey, 0)
	if err != nil {
		// 上传成功但签名失败 → 仍返回 storage 信息，前端可在 patch 后由 list/get 重新签名。
		signed = ""
	}
	return &UploadIconOutput{
		StorageKey: res.StorageKey,
		StorageURI: res.StorageURI,
		SignedURL:  signed,
		Size:       res.Size,
		SHA256:     res.SHA256,
	}, nil
}

// UploadAgentAvatar 复用后台图片上传管线，但使用 agent-avatars/ 前缀，
// 返回 storage_uri 供 digital_employees.avatar_url 持久化。
func (s *Service) UploadAgentAvatar(ctx context.Context, in UploadIconInput) (*UploadIconOutput, error) {
	if s.packages == nil {
		return nil, apperr.ErrInternal.Withf("skill package store not configured (configure platform drive storage active default)")
	}
	res, err := s.packages.UploadImage(ctx, in.Body, in.ContentType, "agent-avatars/", 0)
	if err != nil {
		return nil, apperr.ErrInvalidParams.Withf("upload avatar: %v", err)
	}
	signed, _, err := s.packages.SignURL(ctx, res.StorageKey, 0)
	if err != nil {
		signed = ""
	}
	return &UploadIconOutput{
		StorageKey: res.StorageKey,
		StorageURI: res.StorageURI,
		SignedURL:  signed,
		Size:       res.Size,
		SHA256:     res.SHA256,
	}, nil
}

// ListSkillLabelIDs 单条技能的 label_id 列表（顺序按 sort_order, id）。
func (s *Service) ListSkillLabelIDs(ctx context.Context, skillID int64) ([]int64, error) {
	labels, err := s.repo.ListSkillLabels(ctx, skillID)
	if err != nil {
		return nil, err
	}
	out := make([]int64, 0, len(labels))
	for i := range labels {
		out = append(out, labels[i].ID)
	}
	return out, nil
}

// ListLabelIDsBySkillIDs 批量取多个 skill 的 label_id（用于 list 页避免 N+1）。
func (s *Service) ListLabelIDsBySkillIDs(ctx context.Context, skillIDs []int64) (map[int64][]int64, error) {
	return s.repo.ListLabelIDsBySkillIDs(ctx, skillIDs)
}

// ResolveIconURL 把存库的 icon_url 解析成可外链的 URL；
// 如果是 oss:// 形态，调 PackageStore.SignURL 现签；其它（http(s):// 或空）原样返回。
//
// 用于 Skill DTO 输出阶段，让前端始终拿到可用 URL，不暴露 oss key。
func (s *Service) ResolveIconURL(ctx context.Context, raw string) string {
	if raw == "" {
		return raw
	}
	if !strings.HasPrefix(raw, "oss://") {
		return raw
	}
	if s.packages == nil {
		return raw
	}
	key := strings.TrimPrefix(raw, "oss://")
	url, _, err := s.packages.SignURL(ctx, key, 0)
	if err != nil || url == "" {
		return raw
	}
	return url
}

// validatePreviewParams 浅校验 input_chips_schema：检查 required keys 是否齐全 +
// 类型粗检（spec §1.4 14 类 chip 完整 schema 校验留 §4.2 publish 链路；preview 这里仅基本检查）。
func validatePreviewParams(chipsJSON []byte, params map[string]any) []string {
	if len(chipsJSON) == 0 {
		return nil
	}
	var chips []map[string]any
	if err := json.Unmarshal(chipsJSON, &chips); err != nil {
		return []string{"input_chips_schema.parse_failed: " + err.Error()}
	}
	errs := []string{}
	for _, chip := range chips {
		key, _ := chip["key"].(string)
		if key == "" {
			continue
		}
		required, _ := chip["required"].(bool)
		if required {
			if _, ok := params[key]; !ok {
				errs = append(errs, "missing required param: "+key)
			}
		}
	}
	return errs
}

// ============================================================================
// 内部辅助
// ============================================================================

// jsonEqual 把两个 JSON 字节串解码成 interface{} 后比较；忽略 key 顺序。
func jsonEqual(a, b []byte) bool {
	if len(a) == 0 && len(b) == 0 {
		return true
	}
	var x, y any
	if err := json.Unmarshal(a, &x); err != nil {
		return false
	}
	if err := json.Unmarshal(b, &y); err != nil {
		return false
	}
	return fmt.Sprintf("%#v", normalizeJSON(x)) == fmt.Sprintf("%#v", normalizeJSON(y))
}

// normalizeJSON 把 map 内的 key 排序逻辑通过 marshal/unmarshal 间接实现 — 这里做简化：
// JSON 序列化时 Go 的 encoding/json 会按 key 字母序输出 map，所以 marshal 后再 unmarshal
// 已经稳定；不需要额外排序。
func normalizeJSON(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, vv := range t {
			out[k] = normalizeJSON(vv)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, vv := range t {
			out[i] = normalizeJSON(vv)
		}
		return out
	default:
		return t
	}
}
