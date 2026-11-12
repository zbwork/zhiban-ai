// skill.go — F03 v0.9.1 平台 admin 域 SkillHub HTTP 入口（spec §3.1）。
//
// 当前 slice 已实现：
//
//   - POST   /api/admin/v1/platform/skills                                  创建技能（kind=builtin 时同步建 v0.1.0 draft）
//   - GET    /api/admin/v1/platform/skills                                  列表（多维筛选 + 分页）
//   - GET    /api/admin/v1/platform/skills/{uuid}                           详情
//   - PATCH  /api/admin/v1/platform/skills/{uuid}                           编辑元字段
//   - DELETE /api/admin/v1/platform/skills/{uuid}                           删除（写 deleted_at，不混用 status，不级联 version）
//   - GET    /api/admin/v1/platform/skills/{uuid}/versions                  版本列表
//   - POST   /api/admin/v1/platform/skills/{uuid}/versions                  上传 agent 新版本（v0.9.1: JSON+package_url，zip 解析后续切片）
//   - POST   /api/admin/v1/platform/skills/{uuid}/builtin-versions          builtin 发新版本
//   - PATCH  /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}          PATCH changelog/grayscale
//   - POST   /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/publish  draft→published（首版同时切 active）
//   - POST   /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/archive  published→archived（不变量 A+B）
//   - POST   /api/admin/v1/platform/skills/{uuid}/versions/{vuuid}/rollback latest 切到此 published 版本
//   - GET    /api/admin/v1/platform/skill-categories                        分类只读
//   - GET    /api/admin/v1/platform/skill-labels                            能力标签只读
//   - GET    /api/admin/v1/platform/builtin-skill-keys                      builtin_key 白名单只读
//
// 字典写操作 / 租户域 / agent 绑定 / 租户禁用 / 用户 override / handshake / chip rail / sandbox preview 留下个切片。
package admincore

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ----------------------------------------------------------------------------
// DTO（snake_case 跟客户端 / spec §3 一致；用 json tag 显式约束）
// ----------------------------------------------------------------------------

type skillDTO struct {
	ID                 int64           `json:"id"`
	UUID               string          `json:"uuid"`
	Code               string          `json:"code"`
	Name               string          `json:"name"`
	Description        string          `json:"description,omitempty"`
	UsageExample       string          `json:"usage_example,omitempty"`
	UsageExampleImages json.RawMessage `json:"usage_example_images"`
	IconURL            string          `json:"icon_url,omitempty"`
	Placeholder        string          `json:"placeholder,omitempty"`
	SubmitLabel        string          `json:"submit_label,omitempty"`
	Kind               string          `json:"kind"`
	BuiltinKey         *string         `json:"builtin_key,omitempty"`
	ExecutionMode      string          `json:"execution_mode"`
	ScopeKind          string          `json:"scope_kind"`
	TenantID           *int64          `json:"tenant_id,omitempty"`
	Source             string          `json:"source"`
	Visibility         string          `json:"visibility"`
	CategoryID         *int64          `json:"category_id,omitempty"`
	InputChipsSchema   json.RawMessage `json:"input_chips_schema"`
	HostingModes       []string        `json:"hosting_modes"`
	AgentCompat        json.RawMessage `json:"agent_compat"`
	LabelIDs           []int64         `json:"label_ids"`
	DefaultAttached    bool            `json:"default_attached"`
	DefaultPinned      bool            `json:"default_pinned"`
	SortOrder          int             `json:"sort_order"`
	LatestVersionID    *int64          `json:"latest_version_id,omitempty"`
	Status             string          `json:"status"`
	InstallCount       int64           `json:"install_count"`
	MarketingVisible   bool            `json:"marketing_visible"`
	BillingType        string          `json:"billing_type"`
	PricingMode        string          `json:"pricing_mode"`
	DefaultCredits     *int64          `json:"default_credits"`
	OperationCount     int64           `json:"operation_count"`
	CreatedAt          string          `json:"created_at"`
	UpdatedAt          string          `json:"updated_at"`
}

// toSkillDTOResolved 在 toSkillDTO 基础上，把 oss:// 形态的 icon_url 现签为
// 可访问 URL（v0.9 OSS 不开公共桶时使用）。
func (h *Handlers) toSkillDTOResolved(ctx context.Context, sk *domskill.Skill) skillDTO {
	dto := toSkillDTO(sk)
	dto.IconURL = h.resolveMediaURL(ctx, dto.IconURL)
	dto.UsageExampleImages = h.resolveSkillUsageExampleImages(ctx, dto.UsageExampleImages)
	return dto
}

func toSkillDTO(s *domskill.Skill) skillDTO {
	chips := json.RawMessage(s.InputChipsSchema)
	if len(chips) == 0 {
		chips = json.RawMessage(`[]`)
	}
	compat := json.RawMessage(s.AgentCompat)
	if len(compat) == 0 {
		compat = json.RawMessage(`{}`)
	}
	return skillDTO{
		ID:   s.ID,
		UUID: s.UUID, Code: s.Code, Name: s.Name, Description: s.Description,
		UsageExample: s.UsageExample, UsageExampleImages: json.RawMessage(defaultJSONArr(s.UsageExampleImages)),
		IconURL: s.IconURL, Placeholder: s.Placeholder, SubmitLabel: s.SubmitLabel,
		Kind: s.Kind, BuiltinKey: s.BuiltinKey, ExecutionMode: s.ExecutionMode,
		ScopeKind: s.ScopeKind, TenantID: s.TenantID,
		Source: s.Source, Visibility: s.Visibility,
		CategoryID:       s.CategoryID,
		InputChipsSchema: chips, HostingModes: s.HostingModes, AgentCompat: compat,
		LabelIDs:        []int64{},
		DefaultAttached: s.DefaultAttached, DefaultPinned: s.DefaultPinned,
		SortOrder: s.SortOrder, LatestVersionID: s.LatestVersionID,
		Status: s.Status, InstallCount: s.InstallCount,
		MarketingVisible: s.MarketingVisible,
		BillingType:      s.BillingType, PricingMode: s.PricingMode,
		DefaultCredits: s.DefaultCreditsPerCall, OperationCount: s.OperationCount,
		CreatedAt: s.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
		UpdatedAt: s.UpdatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
}

func (h *Handlers) resolveSkillUsageExampleImages(ctx context.Context, raw json.RawMessage) json.RawMessage {
	items := parseSkillUsageExampleImages(raw)
	if len(items) == 0 {
		return json.RawMessage(`[]`)
	}
	uris := make([]string, 0, len(items))
	for _, item := range items {
		if item.StorageURI != "" {
			uris = append(uris, item.StorageURI)
		}
	}
	resolved := h.resolveMediaURLMap(ctx, uris)
	out := make([]skillUsageExampleImageDTO, 0, len(items))
	for _, item := range items {
		url := item.StorageURI
		if v, ok := resolved[item.StorageURI]; ok {
			url = v
		}
		out = append(out, skillUsageExampleImageDTO{
			StorageURI: item.StorageURI,
			URL:        url,
			FileName:   item.FileName,
		})
	}
	buf, _ := json.Marshal(out)
	return json.RawMessage(buf)
}

type skillUsageExampleImageDTO struct {
	StorageURI string `json:"storage_uri,omitempty"`
	URL        string `json:"url"`
	FileName   string `json:"file_name,omitempty"`
}

func parseSkillUsageExampleImages(raw json.RawMessage) []skillUsageExampleImageDTO {
	if len(raw) == 0 {
		return nil
	}
	var objects []skillUsageExampleImageDTO
	if err := json.Unmarshal(raw, &objects); err == nil {
		out := objects[:0]
		for _, item := range objects {
			if item.StorageURI == "" {
				item.StorageURI = item.URL
			}
			if item.StorageURI != "" {
				out = append(out, item)
			}
		}
		return out
	}
	var urls []string
	if err := json.Unmarshal(raw, &urls); err != nil {
		return nil
	}
	out := make([]skillUsageExampleImageDTO, 0, len(urls))
	for _, url := range urls {
		if strings.TrimSpace(url) != "" {
			out = append(out, skillUsageExampleImageDTO{StorageURI: strings.TrimSpace(url)})
		}
	}
	return out
}

func defaultJSONArr(raw []byte) []byte {
	if len(raw) == 0 {
		return []byte(`[]`)
	}
	return raw
}

type versionDTO struct {
	ID                       int64           `json:"id"`
	UUID                     string          `json:"uuid"`
	SkillID                  int64           `json:"skill_id"`
	Version                  string          `json:"version"`
	Status                   string          `json:"status"`
	Changelog                string          `json:"changelog,omitempty"`
	PackageURL               string          `json:"package_url,omitempty"`
	PackageSizeBytes         *int64          `json:"package_size_bytes,omitempty"`
	PackageSHA256            string          `json:"package_sha256,omitempty"`
	InputChipsSchemaSnapshot json.RawMessage `json:"input_chips_schema_snapshot,omitempty"`
	AgentCompatSnapshot      json.RawMessage `json:"agent_compat_snapshot,omitempty"`
	GrayscalePct             int             `json:"grayscale_pct"`
	GrayscaleStrategy        string          `json:"grayscale_strategy"`
	GrayscaleAllowlist       []int64         `json:"grayscale_allowlist"`
	PublishedAt              string          `json:"published_at,omitempty"`
	CreatedAt                string          `json:"created_at"`
	UpdatedAt                string          `json:"updated_at"`
}

func toVersionDTO(v *domskill.SkillVersion) versionDTO {
	out := versionDTO{
		ID: v.ID, UUID: v.UUID, SkillID: v.SkillID, Version: v.Version, Status: v.Status, Changelog: v.Changelog,
		PackageURL: v.PackageURL, PackageSizeBytes: v.PackageSizeBytes, PackageSHA256: v.PackageSHA256,
		InputChipsSchemaSnapshot: json.RawMessage(v.InputChipsSchemaSnapshot),
		AgentCompatSnapshot:      json.RawMessage(v.AgentCompatSnapshot),
		GrayscalePct:             v.GrayscalePct, GrayscaleStrategy: v.GrayscaleStrategy,
		GrayscaleAllowlist: v.GrayscaleAllowlist,
		CreatedAt:          v.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
		UpdatedAt:          v.UpdatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
	if v.PublishedAt != nil {
		out.PublishedAt = v.PublishedAt.Format("2006-01-02T15:04:05Z07:00")
	}
	if out.GrayscaleAllowlist == nil {
		out.GrayscaleAllowlist = []int64{}
	}
	return out
}

// ----------------------------------------------------------------------------
// skills CRUD
// ----------------------------------------------------------------------------

type createSkillBody struct {
	Code               string          `json:"code"`
	Name               string          `json:"name"`
	Description        string          `json:"description"`
	UsageExample       string          `json:"usage_example"`
	UsageExampleImages json.RawMessage `json:"usage_example_images"`
	IconURL            string          `json:"icon_url"`
	Placeholder        string          `json:"placeholder"`
	SubmitLabel        string          `json:"submit_label"`
	Kind               string          `json:"kind"`
	BuiltinKey         *string         `json:"builtin_key"`
	ExecutionMode      string          `json:"execution_mode"`
	Source             string          `json:"source"`
	Visibility         string          `json:"visibility"`
	CategoryID         *int64          `json:"category_id"`
	LabelIDs           []int64         `json:"label_ids"`
	HostingModes       []string        `json:"hosting_modes"`
	AgentCompat        json.RawMessage `json:"agent_compat"`
	InputChipsSchema   json.RawMessage `json:"input_chips_schema"`
	DefaultAttached    bool            `json:"default_attached"`
	DefaultPinned      bool            `json:"default_pinned"`
	SortOrder          int             `json:"sort_order"`
}

func (h *Handlers) createPlatformSkill(w http.ResponseWriter, r *http.Request) {
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
	in := domskill.CreateSkillInput{
		Code: body.Code, Name: body.Name, Description: body.Description,
		UsageExample: body.UsageExample, UsageExampleImages: []byte(body.UsageExampleImages),
		IconURL: body.IconURL, Placeholder: body.Placeholder, SubmitLabel: body.SubmitLabel,
		Kind: body.Kind, BuiltinKey: body.BuiltinKey, ExecutionMode: body.ExecutionMode,
		ScopeKind: domskill.ScopePlatform, TenantID: nil, // platform admin 强制平台域
		Source: body.Source, Visibility: body.Visibility,
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
		"created_at": sk.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
	if ver != nil {
		resp["auto_created_version_uuid"] = ver.UUID
	} else {
		resp["auto_created_version_uuid"] = nil
	}
	encode.JSON(w, resp)
}

func (h *Handlers) listPlatformSkills(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	q := r.URL.Query()
	f := domskill.ListFilter{
		ScopeKind:    domskill.ScopePlatform,
		Kind:         q.Get("kind"),
		Status:       q.Get("status"),
		Source:       q.Get("source"),
		Visibility:   q.Get("visibility"),
		BillingType:  q.Get("billing_type"),
		PricingMode:  q.Get("pricing_mode"),
		DefaultPrice: q.Get("default_price"),
		Operations:   q.Get("operations"),
		Keyword:      q.Get("q"),
	}
	if v := q.Get("category_id"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			f.CategoryID = &n
		}
	}
	if v := q.Get("label_ids"); v != "" {
		for _, p := range strings.Split(v, ",") {
			if n, err := strconv.ParseInt(strings.TrimSpace(p), 10, 64); err == nil {
				f.LabelIDs = append(f.LabelIDs, n)
			}
		}
	}
	f.Limit, _ = strconv.Atoi(q.Get("limit"))
	f.Offset, _ = strconv.Atoi(q.Get("offset"))

	items, total, err := h.Skill.ListSkills(r.Context(), f)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// 批量取 label_ids 避免 N+1
	skillIDs := make([]int64, 0, len(items))
	for i := range items {
		skillIDs = append(skillIDs, items[i].ID)
	}
	labelMap, _ := h.Skill.ListLabelIDsBySkillIDs(r.Context(), skillIDs)

	iconURLs := make([]string, 0, len(items))
	for i := range items {
		if items[i].IconURL != "" {
			iconURLs = append(iconURLs, items[i].IconURL)
		}
	}
	resolvedIcons := h.resolveMediaURLMap(r.Context(), iconURLs)
	out := make([]skillDTO, 0, len(items))
	for i := range items {
		dto := toSkillDTO(&items[i])
		if items[i].IconURL != "" {
			dto.IconURL = resolvedIcons[items[i].IconURL]
		}
		dto.UsageExampleImages = h.resolveSkillUsageExampleImages(r.Context(), dto.UsageExampleImages)
		if ids, ok := labelMap[items[i].ID]; ok && ids != nil {
			dto.LabelIDs = ids
		}
		out = append(out, dto)
	}
	encode.JSON(w, map[string]any{"items": out, "total": total})
}

func (h *Handlers) getPlatformSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	sk, err := h.Skill.GetSkill(r.Context(), uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if sk.ScopeKind != domskill.ScopePlatform {
		encode.JSONError(w, apperr.ErrForbidden.Withf("skill not in platform scope"))
		return
	}
	dto := h.toSkillDTOResolved(r.Context(), sk)
	if ids, err := h.Skill.ListSkillLabelIDs(r.Context(), sk.ID); err == nil && ids != nil {
		dto.LabelIDs = ids
	}
	encode.JSON(w, dto)
}

type patchSkillBody struct {
	Name               *string          `json:"name"`
	Description        *string          `json:"description"`
	UsageExample       *string          `json:"usage_example"`
	UsageExampleImages *json.RawMessage `json:"usage_example_images"`
	IconURL            *string          `json:"icon_url"`
	Placeholder        *string          `json:"placeholder"`
	SubmitLabel        *string          `json:"submit_label"`
	ExecutionMode      *string          `json:"execution_mode"`
	Visibility         *string          `json:"visibility"`
	Source             *string          `json:"source"`
	CategoryID         *int64           `json:"category_id"`
	LabelIDs           *[]int64         `json:"label_ids"`
	HostingModes       *[]string        `json:"hosting_modes"`
	AgentCompat        *json.RawMessage `json:"agent_compat"`
	InputChipsSchema   *json.RawMessage `json:"input_chips_schema"`
	DefaultAttached    *bool            `json:"default_attached"`
	DefaultPinned      *bool            `json:"default_pinned"`
	SortOrder          *int             `json:"sort_order"`
	Status             *string          `json:"status"`
	MarketingVisible   *bool            `json:"marketing_visible"`
}

func (h *Handlers) patchPlatformSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
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
		MarketingVisible: body.MarketingVisible,
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

func (h *Handlers) deletePlatformSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	aid := middleware.MustAccountID(r.Context())
	if err := h.Skill.SoftDeleteSkill(r.Context(), uuid, aid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "deleted": true})
}

// ----------------------------------------------------------------------------
// versions
// ----------------------------------------------------------------------------

func (h *Handlers) listSkillVersions(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	items, err := h.Skill.ListVersions(r.Context(), uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out := make([]versionDTO, 0, len(items))
	for i := range items {
		out = append(out, toVersionDTO(&items[i]))
	}
	encode.JSON(w, map[string]any{"items": out})
}

type createAgentVersionBody struct {
	Version                  string          `json:"version"`
	Changelog                string          `json:"changelog"`
	PackageURL               string          `json:"package_url"`
	PackageSHA256            string          `json:"package_sha256"`
	PackageSizeBytes         int64           `json:"package_size_bytes"`
	InputChipsSchemaSnapshot json.RawMessage `json:"input_chips_schema_snapshot"`
	AgentCompatSnapshot      json.RawMessage `json:"agent_compat_snapshot"`
}

func (h *Handlers) createAgentVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
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

type createBuiltinVersionBody struct {
	Version            string  `json:"version"`
	Changelog          string  `json:"changelog"`
	GrayscalePct       int     `json:"grayscale_pct"`
	GrayscaleStrategy  string  `json:"grayscale_strategy"`
	GrayscaleAllowlist []int64 `json:"grayscale_allowlist"`
}

func (h *Handlers) createBuiltinVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
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

type patchVersionBody struct {
	Changelog          *string  `json:"changelog"`
	GrayscalePct       *int     `json:"grayscale_pct"`
	GrayscaleStrategy  *string  `json:"grayscale_strategy"`
	GrayscaleAllowlist *[]int64 `json:"grayscale_allowlist"`
}

func (h *Handlers) patchVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	vuuid := r.PathValue("vuuid")
	body, err := readJSON[patchVersionBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	v, err := h.Skill.PatchVersion(r.Context(), vuuid, domskill.PatchVersionInput{
		Changelog: body.Changelog, GrayscalePct: body.GrayscalePct,
		GrayscaleStrategy: body.GrayscaleStrategy, GrayscaleAllowlist: body.GrayscaleAllowlist,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toVersionDTO(v))
}

type publishVersionBody struct {
	GrayscalePct       *int    `json:"grayscale_pct"`
	GrayscaleStrategy  *string `json:"grayscale_strategy"`
	GrayscaleAllowlist []int64 `json:"grayscale_allowlist"`
}

func (h *Handlers) publishVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	vuuid := r.PathValue("vuuid")
	body, err := readJSON[publishVersionBody](r)
	if err != nil {
		// publish 接受空 body
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

func (h *Handlers) archiveVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	v, err := h.Skill.ArchiveVersion(r.Context(), r.PathValue("vuuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toVersionDTO(v))
}

func (h *Handlers) rollbackVersion(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	v, err := h.Skill.RollbackLatest(r.Context(), r.PathValue("vuuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toVersionDTO(v))
}

// ----------------------------------------------------------------------------
// 字典只读
// ----------------------------------------------------------------------------

func (h *Handlers) listSkillCategories(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	f := dictListFilterFromRequest(r)
	items, total, err := h.Skill.ListCategories(r.Context(), f)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out := make([]categoryDTO, 0, len(items))
	for i := range items {
		out = append(out, toCategoryDTO(&items[i]))
	}
	encode.JSON(w, map[string]any{"items": out, "total": total, "limit": f.Limit, "offset": f.Offset})
}

func (h *Handlers) listSkillLabels(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	f := dictListFilterFromRequest(r)
	items, total, err := h.Skill.ListLabels(r.Context(), f)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out := make([]labelDTO, 0, len(items))
	for i := range items {
		out = append(out, toLabelDTO(&items[i]))
	}
	encode.JSON(w, map[string]any{"items": out, "total": total, "limit": f.Limit, "offset": f.Offset})
}

func (h *Handlers) listBuiltinSkillKeys(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	f := dictListFilterFromRequest(r)
	items, total, err := h.Skill.ListBuiltinKeys(r.Context(), f)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out := make([]builtinKeyDTO, 0, len(items))
	for i := range items {
		out = append(out, toBuiltinKeyDTO(&items[i]))
	}
	encode.JSON(w, map[string]any{"items": out, "total": total, "limit": f.Limit, "offset": f.Offset})
}

func dictListFilterFromRequest(r *http.Request) domskill.DictListFilter {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	return domskill.DictListFilter{
		Status:        q.Get("status"),
		Keyword:       q.Get("q"),
		ExecutionMode: q.Get("execution_mode"),
		Limit:         limit,
		Offset:        offset,
	}
}

// ----------------------------------------------------------------------------
// 工具：受限 JSON 解码
// ----------------------------------------------------------------------------

// readJSON 读取并解析 JSON body；body > 1MB 直接返 400。
func readJSON[T any](r *http.Request) (T, error) {
	var out T
	if r.Body == nil {
		return out, apperr.ErrInvalidParams.Withf("empty body")
	}
	defer r.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1024*1024))
	if err != nil {
		return out, apperr.ErrInvalidParams.Wrap(err)
	}
	if len(raw) == 0 {
		return out, apperr.ErrInvalidParams.Withf("empty body")
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&out); err != nil {
		return out, apperr.ErrInvalidParams.Withf("invalid json: %v", err)
	}
	return out, nil
}
