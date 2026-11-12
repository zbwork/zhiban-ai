// kb_providers.go · M8B admin API (最小子集; 见 docs/tasks 中 §A3.4 / B-3-1).
//
// 暂只实现 list + health-check; CRUD (POST/PATCH/DELETE) + set-default 留 follow-up.
// 全部 platform.kb_provider.read / .manage perm.
package admincore

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"

	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	repokb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/knowledge"
)

// KBProviderRepoCRUD · admin POST/PATCH/DELETE/set-default 需要的扩展接口.
// *repokb.Repo 已实现这套方法.
type KBProviderRepoCRUD interface {
	KBProviderRepo
	CreateProvider(ctx context.Context, in repokb.ProviderCRUDInput) (*domkb.ProviderConfig, error)
	PatchProvider(ctx context.Context, providerUUID string, name, endpointURL, apiKeyRef, status *string, settings *map[string]any) (*domkb.ProviderConfig, error)
	DeleteProvider(ctx context.Context, providerUUID string) error
	SetDefaultProvider(ctx context.Context, providerUUID string) (*domkb.ProviderConfig, error)
}

// validateSecretRef · admin POST/PATCH 时校验 settings.api_token_secret_ref 与
// api_key_ref 只允许 env:// 或 value:// (与 cmd/bus resolveSecretRef 同语义).
func validateSecretRef(ref string) error {
	if ref == "" {
		return nil
	}
	if strings.HasPrefix(ref, "env://") || strings.HasPrefix(ref, "value://") {
		return nil
	}
	return apperr.ErrInvalidParams.Withf("secret_ref must start with env:// or value://; got %q", ref)
}

// kbProviderCreateBody · POST body (DisallowUnknownFields 严格校验).
type kbProviderCreateBody struct {
	ProviderKind string         `json:"provider_kind"`
	Name         string         `json:"name"`
	EndpointURL  string         `json:"endpoint_url,omitempty"`
	APIKeyRef    string         `json:"api_key_ref,omitempty"`
	Settings     map[string]any `json:"settings,omitempty"`
	IsDefault    *bool          `json:"is_default,omitempty"`
}

func (h *Handlers) createKBProvider(w http.ResponseWriter, r *http.Request) {
	if h.KBProviderRepo == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo not wired"))
		return
	}
	crud, ok := h.KBProviderRepo.(KBProviderRepoCRUD)
	if !ok {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo CRUD not wired"))
		return
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	var body kbProviderCreateBody
	if err := dec.Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	body.ProviderKind = strings.TrimSpace(body.ProviderKind)
	body.Name = strings.TrimSpace(body.Name)
	if body.ProviderKind == "" || body.Name == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("provider_kind / name required"))
		return
	}
	switch body.ProviderKind {
	case "stub", "dify", "tablestore", "ragflow":
	default:
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("provider_kind must be stub|dify|tablestore|ragflow"))
		return
	}
	if err := validateSecretRef(body.APIKeyRef); err != nil {
		encode.JSONError(w, err)
		return
	}
	if body.Settings != nil {
		if v, ok := body.Settings["api_token_secret_ref"].(string); ok {
			if err := validateSecretRef(v); err != nil {
				encode.JSONError(w, err)
				return
			}
		}
	}
	out, err := crud.CreateProvider(r.Context(), repokb.ProviderCRUDInput{
		ProviderKind: body.ProviderKind, Name: body.Name,
		EndpointURL: body.EndpointURL, APIKeyRef: body.APIKeyRef,
		Settings: body.Settings, IsDefault: body.IsDefault,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, providerDTO(out))
}

type kbProviderPatchBody struct {
	Name        *string         `json:"name,omitempty"`
	EndpointURL *string         `json:"endpoint_url,omitempty"`
	APIKeyRef   *string         `json:"api_key_ref,omitempty"`
	Settings    *map[string]any `json:"settings,omitempty"`
	// Status · 仅允许 admin 写 'active' / 'disabled' (启用/禁用)。
	// 'degraded' 是 health-check 探测失败后由后端自动写, 不接受外部 PATCH。
	Status *string `json:"status,omitempty"`
}

func (h *Handlers) patchKBProvider(w http.ResponseWriter, r *http.Request) {
	if h.KBProviderRepo == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo not wired"))
		return
	}
	crud, ok := h.KBProviderRepo.(KBProviderRepoCRUD)
	if !ok {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo CRUD not wired"))
		return
	}
	uuid := r.PathValue("provider_uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("provider_uuid required"))
		return
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	var body kbProviderPatchBody
	if err := dec.Decode(&body); err != nil && err != io.EOF {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if body.APIKeyRef != nil {
		if err := validateSecretRef(*body.APIKeyRef); err != nil {
			encode.JSONError(w, err)
			return
		}
	}
	if body.Settings != nil {
		if v, ok := (*body.Settings)["api_token_secret_ref"].(string); ok {
			if err := validateSecretRef(v); err != nil {
				encode.JSONError(w, err)
				return
			}
		}
	}
	// status 字段只允许 admin 切 active <-> disabled (启用/禁用); 'degraded' 是 health-check
	// 自动写的状态, 不接受外部直接置位 (避免绕过探测把不健康的 provider 标成 degraded)。
	if body.Status != nil {
		s := strings.TrimSpace(*body.Status)
		if s != "active" && s != "disabled" {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("status must be 'active' or 'disabled'; got %q", *body.Status))
			return
		}
		body.Status = &s
	}
	out, err := crud.PatchProvider(r.Context(), uuid, body.Name, body.EndpointURL, body.APIKeyRef, body.Status, body.Settings)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, providerDTO(out))
}

func (h *Handlers) deleteKBProvider(w http.ResponseWriter, r *http.Request) {
	if h.KBProviderRepo == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo not wired"))
		return
	}
	crud, ok := h.KBProviderRepo.(KBProviderRepoCRUD)
	if !ok {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo CRUD not wired"))
		return
	}
	uuid := r.PathValue("provider_uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("provider_uuid required"))
		return
	}
	if err := crud.DeleteProvider(r.Context(), uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"provider_uuid": uuid, "deleted": true})
}

func (h *Handlers) setDefaultKBProvider(w http.ResponseWriter, r *http.Request) {
	if h.KBProviderRepo == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo not wired"))
		return
	}
	crud, ok := h.KBProviderRepo.(KBProviderRepoCRUD)
	if !ok {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo CRUD not wired"))
		return
	}
	uuid := r.PathValue("provider_uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("provider_uuid required"))
		return
	}
	out, err := crud.SetDefaultProvider(r.Context(), uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if h.KBProviderResolver != nil {
		h.KBProviderResolver.Invalidate(out.ID)
	}
	encode.JSON(w, providerDTO(out))
}

func providerDTO(p *domkb.ProviderConfig) map[string]any {
	if p == nil {
		return nil
	}
	return map[string]any{
		"provider_uuid": p.UUID,
		"provider_kind": p.ProviderKind,
		"name":          p.Name,
		"endpoint_url":  p.EndpointURL,
		"api_key_ref":   p.APIKeyRef,
		"settings":      p.Settings,
		"admin_email":   p.AdminEmail,
		"is_default":    p.IsDefault,
		"status":        p.Status,
	}
}

// listKBProviders · GET /api/admin/v1/platform/kb-providers
func (h *Handlers) listKBProviders(w http.ResponseWriter, r *http.Request) {
	if h.KBProviderRepo == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo not wired"))
		return
	}
	items, err := h.KBProviderRepo.ListProviders(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// DTO: 暴露 provider_uuid (service 内查 id 反解); api_key_ref 不脱敏 (本身就是引用串, 不是 secret).
	out := make([]map[string]any, 0, len(items))
	for i := range items {
		p := items[i]
		out = append(out, map[string]any{
			"provider_uuid": p.UUID,
			"provider_kind": p.ProviderKind,
			"name":          p.Name,
			"endpoint_url":  p.EndpointURL,
			"api_key_ref":   p.APIKeyRef,
			"settings":      p.Settings,
			"admin_email":   p.AdminEmail,
			"is_default":    p.IsDefault,
			"status":        p.Status,
		})
	}
	encode.JSON(w, map[string]any{"items": out})
}

// healthCheckKBProvider · POST /api/admin/v1/platform/kb-providers/{provider_uuid}/health-check
//
// Codex 第二轮 P1 闭环: 不再假写 active. 必须经 KBHealthChecker 实际探测:
//   - Dify → HealthCheck() (GET /v1/datasets)
//   - Stub → always active
//   - 成功 → status='active', message=描述; 失败 → status='degraded', message=错误文本
//
// 数据库 update + (可选) resolver.Invalidate 由 health checker / handler 协同完成.
func (h *Handlers) healthCheckKBProvider(w http.ResponseWriter, r *http.Request) {
	if h.KBProviderRepo == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb provider repo not wired"))
		return
	}
	if h.KBHealthChecker == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("kb health checker not wired"))
		return
	}
	uuid := r.PathValue("provider_uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("provider_uuid required"))
		return
	}
	// UUID → ID 反查 (Repo 没暴露 GetByUUID; 先 ListProviders 后匹配).
	items, err := h.KBProviderRepo.ListProviders(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var providerID int64
	for i := range items {
		if items[i].UUID == uuid {
			providerID = items[i].ID
			break
		}
	}
	if providerID == 0 {
		encode.JSONError(w, apperr.ErrNotFound.Withf("kb provider %s not found", uuid))
		return
	}
	status, message, healthErr := h.KBHealthChecker.Check(r.Context(), providerID)
	if status == "" {
		// 防御性: checker 实现总应返非空 status.
		status = "degraded"
	}
	if err := h.KBProviderRepo.UpdateProviderHealth(r.Context(), providerID, status, message); err != nil {
		encode.JSONError(w, err)
		return
	}
	if h.KBProviderResolver != nil {
		h.KBProviderResolver.Invalidate(providerID)
	}
	resp := map[string]any{
		"provider_uuid": uuid,
		"provider_id":   strconv.FormatInt(providerID, 10),
		"status":        status,
		"message":       message,
	}
	if healthErr != nil {
		// 注意: 写 DB 已成功; 这里把 error 一并暴露给 admin web 调试.
		resp["health_error"] = healthErr.Error()
	}
	encode.JSON(w, resp)
}
