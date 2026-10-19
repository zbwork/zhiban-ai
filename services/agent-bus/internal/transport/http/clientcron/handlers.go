// cron.go — Bus client cron endpoints (M9 Phase A).
//
// 路由前缀 /api/agent-bus/v1/cron/*; 与 docs/tasks/m9-agent-tasks-cron.md §2.1 一致.
package clientcron

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svccron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/cron"
)

func (h *Handlers) ListJobs(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	items, err := h.Cron.ListJobs(r.Context(), accID, tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) CreateJob(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	var body svccron.CreateJobReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Cron.CreateJob(r.Context(), accID, tid, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) GetJob(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.GetJob(r.Context(), accID, tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) PatchJob(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	var body svccron.PatchJobReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Cron.PatchJob(r.Context(), accID, tid, uuid, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) DeleteJob(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	if err := h.Cron.DeleteJob(r.Context(), accID, tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) RunNow(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.RunNow(r.Context(), accID, tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) Pause(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.Pause(r.Context(), accID, tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) Resume(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.Resume(r.Context(), accID, tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) ListJobRuns(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	before := r.URL.Query().Get("before_uuid")
	items, err := h.Cron.ListRunsForJob(r.Context(), accID, tid, uuid, before, limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) ListRuns(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	before := r.URL.Query().Get("before_uuid")
	items, err := h.Cron.ListRuns(r.Context(), accID, tid, before, limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) GetRun(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.GetRun(r.Context(), accID, tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) OpenChat(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.OpenChat(r.Context(), accID, tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// G3 / F08 §3.1.1 · GET /cron/prompt-templates · 客户端可见模板列表.
func (h *Handlers) ListPromptTemplates(w http.ResponseWriter, r *http.Request) {
	_ = middleware.MustAccountID(r.Context()) // 仅鉴权强制
	tid := middleware.MustTenantID(r.Context())
	items, err := h.Cron.ListVisiblePromptTemplates(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

// G3 / F08 §3.1.1 · GET /cron/prompt-templates/{uuid}/variables · 模板详情 + 变量 schema.
func (h *Handlers) GetPromptTemplateVariables(w http.ResponseWriter, r *http.Request) {
	_ = middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.GetVisiblePromptTemplateVariables(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

type Handlers struct{ Cron svccron.Service }
