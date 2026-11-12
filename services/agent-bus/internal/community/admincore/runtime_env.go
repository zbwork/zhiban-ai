// runtime_env.go: M3 v1.1 admin 端 Agent 平台环境管理 (Stage 4-5)。
//
// Platform 端 (复用现有 /platform/runtimes 列表/CRUD + 新增):
//   - POST /api/admin/v1/platform/runtimes/{uuid}/set-as-default
//   - DELETE /api/admin/v1/platform/runtimes/{uuid}/m3 (pre-check 强约束)
//
// Tenant 端:
//   - GET    /api/admin/v1/tenant/runtime-environments
//   - POST   /api/admin/v1/tenant/runtime-environments/enablements
//   - DELETE /api/admin/v1/tenant/runtime-environments/enablements/{uuid}
//   - POST   /api/admin/v1/tenant/runtime-environments/enablements/{uuid}/set-default
//   - POST   /api/admin/v1/tenant/runtime-environments/custom
//   - PATCH  /api/admin/v1/tenant/runtime-environments/custom/{uuid}
//   - DELETE /api/admin/v1/tenant/runtime-environments/custom/{uuid}
package admincore

import (
	"encoding/json"
	svcruntime "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtime"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"

	domenv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/runtimeenv"
)

// ===== platform =====

func (h *Handlers) listPlatformRuntimeEnvs(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	includeDisabled := r.URL.Query().Get("include_disabled") == "true"
	items, err := h.RuntimeEnv.ListPlatform(r.Context(), includeDisabled)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": len(items)})
}

func (h *Handlers) setPlatformDefault(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	actorID := middleware.MustAccountID(r.Context())
	if err := h.RuntimeEnv.SetPlatformDefault(r.Context(), actorID, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) deletePlatformRuntimeEnv(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	actorID := middleware.MustAccountID(r.Context())
	if err := h.RuntimeEnv.DeletePlatform(r.Context(), actorID, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// ===== tenant =====

func (h *Handlers) listTenantRuntimeEnvs(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	res, err := h.RuntimeEnv.ListTenant(r.Context(), tid, limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}

type enableReq struct {
	RuntimeEnvironmentUUID string `json:"runtime_environment_uuid"`
	IsDefault              bool   `json:"is_default"`
}

func (h *Handlers) enableTenantRuntime(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	acc := middleware.MustAccountID(r.Context())
	var body enableReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	en, err := h.RuntimeEnv.Enable(r.Context(), tid, acc, body.RuntimeEnvironmentUUID, body.IsDefault)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, en)
}

func (h *Handlers) disableTenantRuntime(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	if err := h.RuntimeEnv.Disable(r.Context(), tid, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) setTenantEnablementDefault(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	if err := h.RuntimeEnv.SetEnablementDefault(r.Context(), tid, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) createTenantCustomEnv(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	acc := middleware.MustAccountID(r.Context())
	var body domenv.CreateCustomInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.RuntimeEnv.CreateTenantCustom(r.Context(), tid, acc, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) patchTenantCustomEnv(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	var body domenv.PatchCustomInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	acc := middleware.MustAccountID(r.Context())
	out, err := h.RuntimeEnv.PatchTenantCustom(r.Context(), tid, acc, r.PathValue("uuid"), body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) deleteTenantCustomEnv(w http.ResponseWriter, r *http.Request) {
	if h.RuntimeEnv == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtimeenv service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	if err := h.RuntimeEnv.DeleteTenantCustom(r.Context(), tid, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) tenantProbe(w http.ResponseWriter, r *http.Request) {
	h.runProbe(w, r, "tenant")
}

func (h *Handlers) runProbe(w http.ResponseWriter, r *http.Request, scope string) {
	if h.RuntimeProbe == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("runtime probe service not wired"))
		return
	}
	var req svcruntime.ProbeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	req.Scope = scope
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	if scope == "platform" {
		tid = 0 // platform probe 不绑租户
	}
	res, err := h.RuntimeProbe.Probe(r.Context(), accID, tid, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, res)
}
