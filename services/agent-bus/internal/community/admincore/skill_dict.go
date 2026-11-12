// skill_dict.go — F03 v0.9.1 字典管理写接口 + sandbox preview。
//
// 平台 admin 域写操作；走 platform.skill.create/update/delete 权限点（与 SkillHub 主体共用）。
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

func middlewareAccountIDPtr(r *http.Request) *int64 {
	aid := middleware.MustAccountID(r.Context())
	if aid <= 0 {
		return nil
	}
	return &aid
}

// ----------------------------------------------------------------------------
// DTO 映射 — domain struct 没有 json tag, 直出会变成 PascalCase + []byte base64,
// admin web 全程读 snake_case 字段, 必须经 DTO 才能保证一致。
//
// 关键: BuiltinKey.MinClientVersions 是 []byte (DB jsonb 直读), 直出会被 Go
// encoding/json 当字节流编成 base64; 这里转 json.RawMessage, 让客户端拿到原 JSON
// {"ios":"1.5.0",...}; 空 / 无效 JSON 时统一发 nil → omitempty。
// ----------------------------------------------------------------------------

type categoryDTO struct {
	ID           int64     `json:"id"`
	Code         string    `json:"code"`
	Name         string    `json:"name"`
	CategoryKind string    `json:"category_kind"`
	Description  string    `json:"description,omitempty"`
	SortOrder    int       `json:"sort_order"`
	Status       string    `json:"status"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
	IsDeleted    bool      `json:"is_deleted"`
}

type labelDTO struct {
	ID          int64     `json:"id"`
	Code        string    `json:"code"`
	Name        string    `json:"name"`
	Description string    `json:"description,omitempty"`
	SortOrder   int       `json:"sort_order"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
	IsDeleted   bool      `json:"is_deleted"`
}

type builtinKeyDTO struct {
	ID                        int64           `json:"id"`
	Code                      string          `json:"code"`
	Name                      string          `json:"name"`
	Description               string          `json:"description,omitempty"`
	SupportedPlatforms        []string        `json:"supported_platforms"`
	MinClientVersions         json.RawMessage `json:"min_client_versions,omitempty"`
	DefaultExecutionMode      string          `json:"default_execution_mode"`
	DefaultNativeCapabilities []string        `json:"default_native_capabilities"`
	Status                    string          `json:"status"`
	RegisteredBy              *int64          `json:"registered_by,omitempty"`
	RegisteredAt              time.Time       `json:"registered_at"`
	UpdatedAt                 time.Time       `json:"updated_at"`
	IsDeleted                 bool            `json:"is_deleted"`
}

func toCategoryDTO(c *domskill.Category) categoryDTO {
	return categoryDTO{
		ID: c.ID, Code: c.Code, Name: c.Name, CategoryKind: c.CategoryKind,
		Description: c.Description, SortOrder: c.SortOrder, Status: c.Status,
		CreatedAt: c.CreatedAt, UpdatedAt: c.UpdatedAt, IsDeleted: c.IsDeleted,
	}
}

func toLabelDTO(l *domskill.Label) labelDTO {
	return labelDTO{
		ID: l.ID, Code: l.Code, Name: l.Name, Description: l.Description,
		SortOrder: l.SortOrder, Status: l.Status,
		CreatedAt: l.CreatedAt, UpdatedAt: l.UpdatedAt, IsDeleted: l.IsDeleted,
	}
}

func toBuiltinKeyDTO(b *domskill.BuiltinKey) builtinKeyDTO {
	platforms := b.SupportedPlatforms
	if platforms == nil {
		platforms = []string{}
	}
	caps := b.DefaultNativeCapabilities
	if caps == nil {
		caps = []string{}
	}
	var minVer json.RawMessage
	if len(b.MinClientVersions) > 0 && json.Valid(b.MinClientVersions) {
		// Copy out so后续修改 domain 不影响前端响应缓存。
		minVer = append(json.RawMessage(nil), b.MinClientVersions...)
	}
	return builtinKeyDTO{
		ID: b.ID, Code: b.Code, Name: b.Name, Description: b.Description,
		SupportedPlatforms:        platforms,
		MinClientVersions:         minVer,
		DefaultExecutionMode:      b.DefaultExecutionMode,
		DefaultNativeCapabilities: caps,
		Status:                    b.Status,
		RegisteredBy:              b.RegisteredBy,
		RegisteredAt:              b.RegisteredAt,
		UpdatedAt:                 b.UpdatedAt,
		IsDeleted:                 b.IsDeleted,
	}
}

// ----------------------------------------------------------------------------
// categories
// ----------------------------------------------------------------------------

type categoryBody struct {
	Code         string `json:"code"`
	Name         string `json:"name"`
	CategoryKind string `json:"category_kind"`
	Description  string `json:"description,omitempty"`
	SortOrder    int    `json:"sort_order,omitempty"`
}

type categoryPatchBody struct {
	Code        *string `json:"code,omitempty"`
	Name        *string `json:"name,omitempty"`
	Description *string `json:"description,omitempty"`
	SortOrder   *int    `json:"sort_order,omitempty"`
	Status      *string `json:"status,omitempty"`
}

func (h *Handlers) createSkillCategory(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	body, err := readJSON[categoryBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	c := &domskill.Category{
		Code: body.Code, Name: body.Name, CategoryKind: body.CategoryKind,
		Description: body.Description, SortOrder: body.SortOrder,
	}
	if err := h.Skill.CreateCategory(r.Context(), c); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toCategoryDTO(c))
}

func (h *Handlers) patchSkillCategory(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id invalid"))
		return
	}
	body, err := readJSON[categoryPatchBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	fields := buildPatchFields(map[string]any{
		"code": body.Code, "name": body.Name, "description": body.Description,
		"sort_order": body.SortOrder, "status": body.Status,
	})
	c, err := h.Skill.PatchCategory(r.Context(), id, fields)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toCategoryDTO(c))
}

func (h *Handlers) deleteSkillCategory(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id invalid"))
		return
	}
	aid := middlewareAccountIDPtr(r)
	if err := h.Skill.DeleteCategory(r.Context(), id, aid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"id": id, "deleted": true})
}

// ----------------------------------------------------------------------------
// labels
// ----------------------------------------------------------------------------

type labelBody struct {
	Code        string `json:"code"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	SortOrder   int    `json:"sort_order,omitempty"`
}

type labelPatchBody struct {
	Code        *string `json:"code,omitempty"`
	Name        *string `json:"name,omitempty"`
	Description *string `json:"description,omitempty"`
	SortOrder   *int    `json:"sort_order,omitempty"`
	Status      *string `json:"status,omitempty"`
}

func (h *Handlers) createSkillLabel(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	body, err := readJSON[labelBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	l := &domskill.Label{
		Code: body.Code, Name: body.Name, Description: body.Description, SortOrder: body.SortOrder,
	}
	if err := h.Skill.CreateLabel(r.Context(), l); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toLabelDTO(l))
}

func (h *Handlers) patchSkillLabel(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id invalid"))
		return
	}
	body, err := readJSON[labelPatchBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	fields := buildPatchFields(map[string]any{
		"code": body.Code, "name": body.Name, "description": body.Description,
		"sort_order": body.SortOrder, "status": body.Status,
	})
	out, err := h.Skill.PatchLabel(r.Context(), id, fields)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toLabelDTO(out))
}

func (h *Handlers) deleteSkillLabel(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id invalid"))
		return
	}
	aid := middlewareAccountIDPtr(r)
	if err := h.Skill.DeleteLabel(r.Context(), id, aid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"id": id, "deleted": true})
}

// ----------------------------------------------------------------------------
// builtin keys
// ----------------------------------------------------------------------------

type builtinKeyBody struct {
	Code                      string          `json:"code"`
	Name                      string          `json:"name"`
	Description               string          `json:"description,omitempty"`
	SupportedPlatforms        []string        `json:"supported_platforms"`
	MinClientVersions         json.RawMessage `json:"min_client_versions,omitempty"`
	DefaultExecutionMode      string          `json:"default_execution_mode"`
	DefaultNativeCapabilities []string        `json:"default_native_capabilities,omitempty"`
	Status                    string          `json:"status,omitempty"`
}

type builtinKeyPatchBody struct {
	Name                      *string         `json:"name,omitempty"`
	Description               *string         `json:"description,omitempty"`
	SupportedPlatforms        *[]string       `json:"supported_platforms,omitempty"`
	MinClientVersions         json.RawMessage `json:"min_client_versions,omitempty"`
	DefaultExecutionMode      *string         `json:"default_execution_mode,omitempty"`
	DefaultNativeCapabilities *[]string       `json:"default_native_capabilities,omitempty"`
	Status                    *string         `json:"status,omitempty"`
}

func (h *Handlers) createBuiltinSkillKey(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	body, err := readJSON[builtinKeyBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	b := &domskill.BuiltinKey{
		Code: body.Code, Name: body.Name, Description: body.Description,
		SupportedPlatforms:        body.SupportedPlatforms,
		MinClientVersions:         []byte(body.MinClientVersions),
		DefaultExecutionMode:      body.DefaultExecutionMode,
		DefaultNativeCapabilities: body.DefaultNativeCapabilities,
		Status:                    body.Status,
	}
	if err := h.Skill.CreateBuiltinKey(r.Context(), b); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toBuiltinKeyDTO(b))
}

func (h *Handlers) patchBuiltinSkillKey(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id invalid"))
		return
	}
	body, err := readJSON[builtinKeyPatchBody](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	fields := map[string]any{}
	if body.Name != nil {
		fields["name"] = *body.Name
	}
	if body.Description != nil {
		fields["description"] = *body.Description
	}
	if body.SupportedPlatforms != nil {
		fields["supported_platforms"] = *body.SupportedPlatforms
	}
	if len(body.MinClientVersions) > 0 {
		fields["min_client_versions"] = string(body.MinClientVersions)
	}
	if body.DefaultExecutionMode != nil {
		fields["default_execution_mode"] = *body.DefaultExecutionMode
	}
	if body.DefaultNativeCapabilities != nil {
		fields["default_native_capabilities"] = *body.DefaultNativeCapabilities
	}
	if body.Status != nil {
		fields["status"] = *body.Status
	}
	out, err := h.Skill.PatchBuiltinKey(r.Context(), id, fields)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toBuiltinKeyDTO(out))
}

func (h *Handlers) deleteBuiltinSkillKey(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id invalid"))
		return
	}
	aid := middlewareAccountIDPtr(r)
	if err := h.Skill.DeleteBuiltinKey(r.Context(), id, aid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"id": id, "deleted": true})
}

// ----------------------------------------------------------------------------
// §4.7 SKILL.md zip 上传
// ----------------------------------------------------------------------------

func (h *Handlers) uploadSkillPackage(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	vuuid := r.PathValue("vuuid")

	// multipart 解析；上限按 50MB 留点冗余。
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("parse multipart: %v", err))
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("missing file field: %v", err))
		return
	}
	defer file.Close()
	if header.Size <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("empty file"))
		return
	}

	out, err := h.Skill.UploadSkillPackage(r.Context(), svcskill.UploadPackageInput{
		SkillUUID:   uuid,
		VersionUUID: vuuid,
		Body:        file,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// uploadSkillIcon — multipart 上传图标。落 OSS 后返回 storage_uri (oss:// 形态，
// admin 写到 skills.icon_url) + signed_url (即时预览/回显)。
//
// 与 SKILL.md 包不同：图标按内容寻址（sha256.<ext>），不绑定特定 skill_uuid，
// 多个 skill 可以共享同一份图标对象（去重）。前端在调 create/patch 时把
// storage_uri 作为 icon_url 提交。
func (h *Handlers) uploadSkillIcon(w http.ResponseWriter, r *http.Request) {
	if h.Media != nil {
		h.uploadSkillIconMedia(w, r)
		return
	}
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("media service not configured"))
		return
	}
	if err := r.ParseMultipartForm(4 << 20); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("parse multipart: %v", err))
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("missing file field: %v", err))
		return
	}
	defer file.Close()
	if header.Size <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("empty file"))
		return
	}
	out, err := h.Skill.UploadSkillIcon(r.Context(), svcskill.UploadIconInput{
		Body:        file,
		ContentType: header.Header.Get("Content-Type"),
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// ----------------------------------------------------------------------------
// §3.7 sandbox preview
// ----------------------------------------------------------------------------

type previewBody struct {
	VersionUUID string         `json:"version_uuid,omitempty"`
	Params      map[string]any `json:"params"`
}

func (h *Handlers) previewSkill(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	body, _ := readJSON[previewBody](r)
	out, err := h.Skill.PreviewSkill(r.Context(), domskill.PreviewSkillInput{
		SkillUUID: uuid, VersionUUID: body.VersionUUID, Params: body.Params,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// ----------------------------------------------------------------------------
// helper：构造 PATCH fields，nil = 不动
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// F03 §4.7 R1：版本文件浏览
// ----------------------------------------------------------------------------

func (h *Handlers) listSkillVersionFiles(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	vuuid := r.PathValue("vuuid")
	files, err := h.Skill.ListVersionFiles(r.Context(), uuid, vuuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if files == nil {
		files = []svcskill.VersionFileEntry{}
	}
	encode.JSON(w, map[string]any{"items": files, "total": len(files)})
}

func (h *Handlers) getSkillVersionFileContent(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	vuuid := r.PathValue("vuuid")
	path := r.URL.Query().Get("path")
	if path == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("path required"))
		return
	}
	out, err := h.Skill.GetVersionFileContent(r.Context(), uuid, vuuid, path)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) getSkillVersionDownloadURL(w http.ResponseWriter, r *http.Request) {
	if h.Skill == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("skill svc not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	vuuid := r.PathValue("vuuid")
	url, err := h.Skill.SignVersionPackageURL(r.Context(), uuid, vuuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"url": url})
}

func buildPatchFields(in map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range in {
		if v == nil {
			continue
		}
		switch p := v.(type) {
		case *string:
			if p != nil {
				out[k] = *p
			}
		case *int:
			if p != nil {
				out[k] = *p
			}
		default:
			out[k] = v
		}
	}
	return out
}
