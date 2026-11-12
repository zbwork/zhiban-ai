// tenant_skill.go — F03 v0.9.1 租户 admin 域 SkillHub HTTP 入口（spec §3.2）。
//
// 路由统一前缀 /api/admin/v1/tenant/* + tenantPerm 鉴权（act_scope=tenant + 权限点）。
// platform admin 的 SkillHub 在 skill.go。
package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
)

// ----------------------------------------------------------------------------
// DTO
// ----------------------------------------------------------------------------

type tenantDisableSkillBody struct {
	DisableReason string `json:"disable_reason,omitempty"`
}

type tenantPreferenceBody struct {
	Behavior string `json:"behavior"`
	Note     string `json:"note,omitempty"`
}

type attachAgentSkillBody struct {
	SkillUUID       string          `json:"skill_uuid"`
	Pinned          bool            `json:"pinned,omitempty"`
	SortOrder       int             `json:"sort_order,omitempty"`
	PinnedVersionID *int64          `json:"pinned_version_id,omitempty"`
	DefaultParams   json.RawMessage `json:"default_params,omitempty"`
	Source          string          `json:"source,omitempty"`
}

type patchAgentBindingBody struct {
	Pinned          *bool           `json:"pinned,omitempty"`
	SortOrder       *int            `json:"sort_order,omitempty"`
	PinnedVersionID *int64          `json:"pinned_version_id,omitempty"`
	ClearPinnedVer  bool            `json:"clear_pinned_version,omitempty"`
	DefaultParams   json.RawMessage `json:"default_params,omitempty"`
}

type agentBindingDTO struct {
	BindingID       int64           `json:"binding_id"`
	AgentID         int64           `json:"agent_id"`
	SkillID         int64           `json:"skill_id"`
	SkillUUID       string          `json:"skill_uuid"`
	SkillCode       string          `json:"skill_code"`
	SkillName       string          `json:"skill_name"`
	Pinned          bool            `json:"pinned"`
	SortOrder       int             `json:"sort_order"`
	PinnedVersionID *int64          `json:"pinned_version_id,omitempty"`
	DefaultParams   json.RawMessage `json:"default_params"`
	Source          string          `json:"source"`
	CreatedAt       string          `json:"created_at"`
	UpdatedAt       string          `json:"updated_at"`
}

func toBindingDTO(v domskill.AgentBindingView) agentBindingDTO {
	dp := json.RawMessage(v.Binding.DefaultParams)
	if len(dp) == 0 {
		dp = json.RawMessage("{}")
	}
	dto := agentBindingDTO{
		BindingID:       v.Binding.ID,
		AgentID:         v.Binding.AgentID,
		SkillID:         v.Binding.SkillID,
		Pinned:          v.Binding.Pinned,
		SortOrder:       v.Binding.SortOrder,
		PinnedVersionID: v.Binding.PinnedVersionID,
		DefaultParams:   dp,
		Source:          v.Binding.Source,
		CreatedAt:       v.Binding.CreatedAt.Format(time.RFC3339),
		UpdatedAt:       v.Binding.UpdatedAt.Format(time.RFC3339),
	}
	if v.Skill != nil {
		dto.SkillUUID = v.Skill.UUID
		dto.SkillCode = v.Skill.Code
		dto.SkillName = v.Skill.Name
	}
	return dto
}

type tenantSkillDTO struct {
	skillDTO
	TenantDisabled   bool   `json:"tenant_disabled"`
	DisableReason    string `json:"disable_reason,omitempty"`
	TenantPreference string `json:"tenant_preference,omitempty"`
}

type availableSkillDTO struct {
	SkillUUID         string `json:"skill_uuid"`
	Code              string `json:"code"`
	Name              string `json:"name"`
	ScopeKind         string `json:"scope_kind"`
	Kind              string `json:"kind"`
	IconURL           string `json:"icon_url,omitempty"`
	IsAttached        bool   `json:"is_attached"`
	IsDefaultAttached bool   `json:"is_default_attached"`
	TenantPreference  string `json:"tenant_preference,omitempty"`
}

// ----------------------------------------------------------------------------
// 禁用 / 解禁 平台技能（§3.2.A）
// ----------------------------------------------------------------------------

func (h *Handlers) tenantDisableSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	body, _ := readJSON[tenantDisableSkillBody](r)
	tid := middleware.MustTenantID(r.Context())
	aid := middleware.MustAccountID(r.Context())
	in := domskill.DisableTenantSkillInput{
		TenantID:      tid,
		SkillUUID:     uuid,
		DisableReason: body.DisableReason,
	}
	if aid > 0 {
		in.DisabledBy = &aid
	}
	d, err := h.Skill.DisableTenantSkill(r.Context(), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"tenant_id":      d.TenantID,
		"skill_uuid":     uuid,
		"disabled_at":    d.DisabledAt.Format(time.RFC3339),
		"disabled_by":    d.DisabledBy,
		"disable_reason": d.DisableReason,
	})
}

func (h *Handlers) tenantEnableSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	if err := h.Skill.EnableTenantSkill(r.Context(), tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----------------------------------------------------------------------------
// 租户偏好（§3.2 PUT/DELETE /tenant/skill-preferences/{skill_uuid}）
// ----------------------------------------------------------------------------

func (h *Handlers) tenantListPreferences(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	prefs, skills, err := h.Skill.ListTenantPreferences(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	type item struct {
		SkillUUID string `json:"skill_uuid"`
		SkillCode string `json:"skill_code"`
		SkillName string `json:"skill_name"`
		Behavior  string `json:"behavior"`
		Note      string `json:"note,omitempty"`
		UpdatedAt string `json:"updated_at"`
	}
	items := make([]item, 0, len(prefs))
	for i, p := range prefs {
		var uuid, code, name string
		if i < len(skills) {
			uuid, code, name = skills[i].UUID, skills[i].Code, skills[i].Name
		}
		items = append(items, item{
			SkillUUID: uuid, SkillCode: code, SkillName: name,
			Behavior: p.Behavior, Note: p.Note,
			UpdatedAt: p.UpdatedAt.Format(time.RFC3339),
		})
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}

func (h *Handlers) tenantSetPreference(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	body, err := readJSON[tenantPreferenceBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	tid := middleware.MustTenantID(r.Context())
	aid := middleware.MustAccountID(r.Context())
	in := domskill.SetTenantPreferenceInput{
		TenantID:  tid,
		SkillUUID: uuid,
		Behavior:  body.Behavior,
		Note:      body.Note,
	}
	if aid > 0 {
		in.UpdatedBy = &aid
	}
	p, err := h.Skill.SetTenantPreference(r.Context(), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"skill_uuid": uuid,
		"behavior":   p.Behavior,
		"note":       p.Note,
		"updated_at": p.UpdatedAt.Format(time.RFC3339),
	})
}

func (h *Handlers) tenantClearPreference(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	if err := h.Skill.ClearTenantPreference(r.Context(), tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----------------------------------------------------------------------------
// agent × skill 装配（§3.2.B-C）
// ----------------------------------------------------------------------------

func (h *Handlers) tenantListAgentSkills(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	tid := middleware.MustTenantID(r.Context())
	views, err := h.Skill.ListAgentBindings(r.Context(), tid, agentUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]agentBindingDTO, 0, len(views))
	for _, v := range views {
		items = append(items, toBindingDTO(v))
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}

func (h *Handlers) tenantListAvailableSkills(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	tid := middleware.MustTenantID(r.Context())
	views, err := h.Skill.ListAvailableForAgent(r.Context(), tid, agentUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]availableSkillDTO, 0, len(views))
	iconURLs := make([]string, 0, len(views))
	for _, v := range views {
		if v.Skill.IconURL != "" {
			iconURLs = append(iconURLs, v.Skill.IconURL)
		}
	}
	resolvedIcons := h.resolveMediaURLMap(r.Context(), iconURLs)
	for _, v := range views {
		dto := availableSkillDTO{
			SkillUUID:         v.Skill.UUID,
			Code:              v.Skill.Code,
			Name:              v.Skill.Name,
			ScopeKind:         v.Skill.ScopeKind,
			Kind:              v.Skill.Kind,
			IconURL:           resolvedIcons[v.Skill.IconURL],
			IsAttached:        v.IsAttached,
			IsDefaultAttached: v.IsDefaultAttached,
			TenantPreference:  v.TenantPreference,
		}
		items = append(items, dto)
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}

func (h *Handlers) tenantAttachAgentSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	body, err := readJSON[attachAgentSkillBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	tid := middleware.MustTenantID(r.Context())
	aid := middleware.MustAccountID(r.Context())
	in := domskill.AttachAgentSkillInput{
		TenantID:        tid,
		AgentUUID:       agentUUID,
		SkillUUID:       body.SkillUUID,
		Pinned:          body.Pinned,
		SortOrder:       body.SortOrder,
		PinnedVersionID: body.PinnedVersionID,
		DefaultParams:   []byte(body.DefaultParams),
		Source:          body.Source,
	}
	if aid > 0 {
		in.CreatedBy = &aid
	}
	b, err := h.Skill.AttachAgentSkill(r.Context(), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"binding_id":        b.ID,
		"agent_id":          b.AgentID,
		"skill_id":          b.SkillID,
		"pinned":            b.Pinned,
		"sort_order":        b.SortOrder,
		"pinned_version_id": b.PinnedVersionID,
		"source":            b.Source,
		"created_at":        b.CreatedAt.Format(time.RFC3339),
	})
}

func (h *Handlers) tenantPatchAgentBinding(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	bid, err := strconv.ParseInt(r.PathValue("binding_id"), 10, 64)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("binding_id invalid"))
		return
	}
	body, err := readJSON[patchAgentBindingBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	tid := middleware.MustTenantID(r.Context())
	aid := middleware.MustAccountID(r.Context())
	in := domskill.PatchAgentBindingInput{
		TenantID:        tid,
		AgentUUID:       agentUUID,
		BindingID:       bid,
		Pinned:          body.Pinned,
		SortOrder:       body.SortOrder,
		PinnedVersionID: body.PinnedVersionID,
		ClearPinnedVer:  body.ClearPinnedVer,
		DefaultParams:   []byte(body.DefaultParams),
	}
	if aid > 0 {
		in.UpdatedBy = &aid
	}
	b, err := h.Skill.PatchAgentBinding(r.Context(), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"binding_id":        b.ID,
		"pinned":            b.Pinned,
		"sort_order":        b.SortOrder,
		"pinned_version_id": b.PinnedVersionID,
		"updated_at":        b.UpdatedAt.Format(time.RFC3339),
	})
}

func (h *Handlers) tenantDetachAgentSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	agentUUID := r.PathValue("agent_uuid")
	bid, err := strconv.ParseInt(r.PathValue("binding_id"), 10, 64)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("binding_id invalid"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	if err := h.Skill.DetachAgentSkill(r.Context(), tid, agentUUID, bid); err != nil {
		encode.JSONError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ----------------------------------------------------------------------------
// 租户视角技能列表 / 版本（spec §3.2 GET /tenant/skills）
// ----------------------------------------------------------------------------

func (h *Handlers) tenantListSkills(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	tid := middleware.MustTenantID(r.Context())
	views, total, err := h.Skill.ListTenantSkills(r.Context(), tid, svcskill.ListTenantSkillsFilter{
		Kind: q.Get("kind"), Status: q.Get("status"), Keyword: q.Get("q"),
		Limit: limit, Offset: offset,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	iconURLs := make([]string, 0, len(views))
	for _, v := range views {
		if v.Skill.IconURL != "" {
			iconURLs = append(iconURLs, v.Skill.IconURL)
		}
	}
	resolvedIcons := h.resolveMediaURLMap(r.Context(), iconURLs)
	out := make([]tenantSkillDTO, 0, len(views))
	for _, v := range views {
		dto := toSkillDTO(v.Skill)
		if v.Skill.IconURL != "" {
			dto.IconURL = resolvedIcons[v.Skill.IconURL]
		}
		dto.UsageExampleImages = h.resolveSkillUsageExampleImages(r.Context(), dto.UsageExampleImages)
		out = append(out, tenantSkillDTO{
			skillDTO:         dto,
			TenantDisabled:   v.TenantDisabled,
			DisableReason:    v.DisableReason,
			TenantPreference: v.TenantPreference,
		})
	}
	encode.JSON(w, map[string]any{"items": out, "total": total})
}

func (h *Handlers) tenantListSkillVersions(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	vers, err := h.Skill.ListTenantSkillVersions(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out := make([]versionDTO, 0, len(vers))
	for i := range vers {
		out = append(out, toVersionDTO(&vers[i]))
	}
	encode.JSON(w, map[string]any{"items": out, "total": len(out)})
}

// ============================================================================
// F03 §3.2 租户自建技能 CRUD (Phase A 后补, P1 收口)
// ============================================================================
//
// 设计:
//   - 复用 service.go 已有的 CreateSkill / PatchSkill / SoftDeleteSkill,
//     这些方法 scope-agnostic, 但本 handler 在 service 调用前后强制 scope=tenant +
//     tenant_id=ctx.tenant 校验, 防止跨租户写入。
//   - Create: 强制 ScopeKind=tenant, TenantID=ctx.tenant。
//   - Get/Patch/Delete: 先 GetSkill 校验 scope=tenant AND tenant_id 匹配, 防止
//     租户 admin 通过 uuid 改/删平台技能或别租户技能。
//   - 版本管理: 同样先校验父技能归属本租户, 再调 service。

// tenantCreateSkill · POST /api/admin/v1/tenant/skills
func (h *Handlers) tenantCreateSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	body, err := readJSON[createSkillBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	aid := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	in := domskill.CreateSkillInput{
		Code: body.Code, Name: body.Name, Description: body.Description,
		UsageExample: body.UsageExample, UsageExampleImages: []byte(body.UsageExampleImages),
		IconURL: body.IconURL, Placeholder: body.Placeholder, SubmitLabel: body.SubmitLabel,
		Kind: body.Kind, BuiltinKey: body.BuiltinKey, ExecutionMode: body.ExecutionMode,
		// 关键: 写死 tenant scope; 即便 body 里塞了 scope_kind 字段也被覆盖。
		ScopeKind:        domskill.ScopeTenant,
		TenantID:         &tid,
		Source:           body.Source,
		Visibility:       body.Visibility,
		CategoryID:       body.CategoryID,
		LabelIDs:         body.LabelIDs,
		HostingModes:     body.HostingModes,
		AgentCompat:      []byte(body.AgentCompat),
		InputChipsSchema: []byte(body.InputChipsSchema),
		DefaultAttached:  body.DefaultAttached,
		DefaultPinned:    body.DefaultPinned,
		SortOrder:        body.SortOrder,
	}
	if aid > 0 {
		in.CreatedBy = &aid
	}
	sk, ver, err := h.Skill.CreateSkill(r.Context(), in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	resp := map[string]any{
		"uuid":       sk.UUID,
		"code":       sk.Code,
		"scope_kind": sk.ScopeKind,
		"status":     sk.Status,
		"created_at": sk.CreatedAt.Format(time.RFC3339),
	}
	if ver != nil {
		resp["auto_created_version_uuid"] = ver.UUID
	} else {
		resp["auto_created_version_uuid"] = nil
	}
	encode.JSON(w, resp)
}

// tenantGetSkill · GET /api/admin/v1/tenant/skills/{uuid}
// 允许读: scope=platform (公开) 或 scope=tenant 且属于本租户。
func (h *Handlers) tenantGetSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	sk, err := h.Skill.GetSkill(r.Context(), uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if sk.ScopeKind == domskill.ScopeTenant {
		if sk.TenantID == nil || *sk.TenantID != tid {
			encode.JSONError(w, apperr.ErrForbidden.Withf("skill.cross_tenant"))
			return
		}
	} else if sk.ScopeKind != domskill.ScopePlatform {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("skill.scope_invalid"))
		return
	}
	dto := h.toSkillDTOResolved(r.Context(), sk)
	if ids, lerr := h.Skill.ListSkillLabelIDs(r.Context(), sk.ID); lerr == nil && ids != nil {
		dto.LabelIDs = ids
	}
	encode.JSON(w, dto)
}

// tenantPatchSkill · PATCH /api/admin/v1/tenant/skills/{uuid}
// 仅允许编辑 scope=tenant 且属于本租户的技能。
func (h *Handlers) tenantPatchSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	if err := h.checkTenantSkillOwnership(r, uuid, tid); err != nil {
		encode.JSONError(w, err)
		return
	}
	body, err := readJSON[patchSkillBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	aid := middleware.MustAccountID(r.Context())
	in := domskill.PatchSkillInput{
		Name: body.Name, Description: body.Description, UsageExample: body.UsageExample, IconURL: body.IconURL,
		Placeholder: body.Placeholder, SubmitLabel: body.SubmitLabel,
		ExecutionMode: body.ExecutionMode, Visibility: body.Visibility,
		Source:     body.Source,
		CategoryID: body.CategoryID,
		LabelIDs:   body.LabelIDs, HostingModes: body.HostingModes,
		DefaultAttached: body.DefaultAttached, DefaultPinned: body.DefaultPinned,
		SortOrder: body.SortOrder, Status: body.Status,
	}
	if body.AgentCompat != nil {
		in.AgentCompat = []byte(*body.AgentCompat)
	}
	if body.UsageExampleImages != nil {
		in.UsageExampleImages = []byte(*body.UsageExampleImages)
	}
	if body.InputChipsSchema != nil {
		in.InputChipsSchema = []byte(*body.InputChipsSchema)
	}
	if aid > 0 {
		in.UpdatedBy = &aid
	}
	sk, err := h.Skill.PatchSkill(r.Context(), uuid, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, h.toSkillDTOResolved(r.Context(), sk))
}

// tenantDeleteSkill · DELETE /api/admin/v1/tenant/skills/{uuid} (软删)
func (h *Handlers) tenantDeleteSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	if err := h.checkTenantSkillOwnership(r, uuid, tid); err != nil {
		encode.JSONError(w, err)
		return
	}
	aid := middleware.MustAccountID(r.Context())
	if err := h.Skill.SoftDeleteSkill(r.Context(), uuid, aid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "deleted": true})
}

// checkTenantSkillOwnership · 通用 guard:
// 校验 uuid 对应技能 scope=tenant 且 tenant_id=tid; 非则返 ErrForbidden/InvalidParams。
// 任何写 / 删 endpoint 都应该先调它。
func (h *Handlers) checkTenantSkillOwnership(r *http.Request, uuid string, tid int64) error {
	sk, err := h.Skill.GetSkill(r.Context(), uuid)
	if err != nil {
		return err
	}
	if sk.ScopeKind != domskill.ScopeTenant {
		return apperr.ErrForbidden.Withf("skill.not_tenant_owned (cannot modify platform skill)")
	}
	if sk.TenantID == nil || *sk.TenantID != tid {
		return apperr.ErrForbidden.Withf("skill.cross_tenant")
	}
	return nil
}

// ============================================================================
// tenant 版本管理 (复用 service 版本方法 + scope ownership 前置校验)
// ============================================================================

// tenantCreateAgentVersion · POST /api/admin/v1/tenant/skills/{uuid}/versions
func (h *Handlers) tenantCreateAgentVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	if err := h.checkTenantSkillOwnership(r, uuid, tid); err != nil {
		encode.JSONError(w, err)
		return
	}
	body, err := readJSON[createAgentVersionBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	v, err := h.Skill.CreateAgentVersion(r.Context(), domskill.CreateAgentVersionInput{
		SkillUUID: uuid, Version: body.Version, Changelog: body.Changelog,
		PackageURL: body.PackageURL, PackageSHA256: body.PackageSHA256, PackageSizeBytes: body.PackageSizeBytes,
		InputChipsSchemaSnapshot: []byte(body.InputChipsSchemaSnapshot),
		AgentCompatSnapshot:      []byte(body.AgentCompatSnapshot),
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toVersionDTO(v))
}

// tenantCreateBuiltinVersion · POST /api/admin/v1/tenant/skills/{uuid}/builtin-versions
func (h *Handlers) tenantCreateBuiltinVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	tid := middleware.MustTenantID(r.Context())
	if err := h.checkTenantSkillOwnership(r, uuid, tid); err != nil {
		encode.JSONError(w, err)
		return
	}
	body, err := readJSON[createBuiltinVersionBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	v, err := h.Skill.CreateBuiltinVersion(r.Context(), domskill.CreateBuiltinVersionInput{
		SkillUUID: uuid, Version: body.Version, Changelog: body.Changelog,
		GrayscalePct: body.GrayscalePct, GrayscaleStrategy: body.GrayscaleStrategy,
		GrayscaleAllowlist: body.GrayscaleAllowlist,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toVersionDTO(v))
}

// tenantPublishVersion · POST /api/admin/v1/tenant/skills/{uuid}/versions/{vuuid}/publish
func (h *Handlers) tenantPublishVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	skillUUID := r.PathValue("uuid")
	vuuid := r.PathValue("vuuid")
	tid := middleware.MustTenantID(r.Context())
	if err := h.checkTenantSkillOwnership(r, skillUUID, tid); err != nil {
		encode.JSONError(w, err)
		return
	}
	body, err := readJSON[publishVersionBody](r)
	if err != nil {
		body = publishVersionBody{}
	}
	aid := middleware.MustAccountID(r.Context())
	in := domskill.PublishVersionInput{
		GrayscalePct: body.GrayscalePct, GrayscaleStrategy: body.GrayscaleStrategy,
		GrayscaleAllowlist: body.GrayscaleAllowlist,
	}
	if aid > 0 {
		in.PublishedBy = &aid
	}
	v, err := h.Skill.PublishVersion(r.Context(), vuuid, in)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toVersionDTO(v))
}

// 一行避免编译器 "imported and not used"; service 包用了同名常量, 这里保持 import。
var _ = svcskill.ListTenantSkillsFilter{}
var _ = strconv.Atoi

// requireTenantOwnedSkill · middleware: 路径里的 {uuid} 对应技能必须 scope=tenant 且属于
// 本租户; 否则 403。用于把 platform handler (patchVersion/uploadSkillPackage 等)
// 当成 tenant handler 复用 — 不必每个 endpoint 都手写 wrapper。
func (h *Handlers) requireTenantOwnedSkill(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		uuid := r.PathValue("uuid")
		tid := middleware.MustTenantID(r.Context())
		if err := h.checkTenantSkillOwnership(r, uuid, tid); err != nil {
			encode.JSONError(w, err)
			return
		}
		next.ServeHTTP(w, r)
	})
}
