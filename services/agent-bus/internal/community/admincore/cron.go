// cron.go — Admin tenant cron endpoints (M9 Phase A T9.7).
//
// 走 tenant.agent.update perm (admin force-disable / clear-admin-flag); 列表走 tenant.agent.read.
// **不实现** admin Web 页面 (本批仅后端 API + curl 验证).
package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/google/uuid"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svccron "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/cron"
)

func (h *Handlers) listTenantCronJobs(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSON(w, map[string]any{"items": []any{}})
		return
	}
	tid := middleware.MustTenantID(r.Context())
	items, err := h.Cron.AdminListTenantJobs(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) adminForceDisableCron(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	actor := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.AdminForceDisable(r.Context(), tid, actor, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// adminCronCapabilityDryRun · M9G T-M9G-4: 列出 enabled 但当前规则下不允许的 cron job.
// **不**自动 disable, 仅 read-only 报表; 走 platform.cron.read (admin web 决议页消费).
//
// query: limit (默认 1000, 上限 5000).
func (h *Handlers) adminCronCapabilityDryRun(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	report, err := h.Cron.AdminCapabilityDryRun(r.Context(), limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, report)
}

// ===== F08 §5.1/§5.3 · platform 跨租户定时任务运营监控 (/cron-jobs, 只读) =====
//
// 全部 platform scope, 走 platform.cron.read guard; 显式跨租户, 不取 MustTenantID。
// V1 只读: overview 概览 + 失败排行, list 后端分页, {uuid} 详情 + 最近运行记录。

func (h *Handlers) platformCronOverview(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	out, err := h.Cron.PlatformCronOverview(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) platformListCronJobs(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSON(w, map[string]any{"items": []any{}, "total": 0})
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	onlyFail := q.Get("only_consecutive_failure")
	out, err := h.Cron.PlatformListCronJobs(r.Context(), svccron.PlatformCronListReq{
		TenantKeyword:          q.Get("tenant_keyword"),
		TaskKeyword:            q.Get("task_keyword"),
		Status:                 q.Get("status"),
		LastResult:             q.Get("last_result"),
		OnlyConsecutiveFailure: onlyFail == "true" || onlyFail == "1",
		Limit:                  limit,
		Offset:                 offset,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) platformGetCronJob(w http.ResponseWriter, r *http.Request) {
	// 先校验 path uuid 格式: 手输的坏 uuid 拦成 400, 不进 repo 的 $1::uuid cast (否则 PG cast error → 500)。
	// 合法但不存在/软删的 uuid 仍由 service/repo 走 404 (GetJobByUUID 返 ErrNotFound)。
	jobUUID := r.PathValue("uuid")
	if _, err := uuid.Parse(jobUUID); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid cron job uuid"))
		return
	}
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	runLimit, _ := strconv.Atoi(r.URL.Query().Get("run_limit"))
	out, err := h.Cron.PlatformGetCronJob(r.Context(), jobUUID, runLimit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) adminClearCronAdminFlag(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	actor := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.AdminClearAdminFlag(r.Context(), tid, actor, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// G4 / F08 §5.2 · GET /tenant/cron-prompt-templates · admin 视角列表 (含 draft + platform 只读).
func (h *Handlers) adminListTenantPromptTemplates(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSON(w, map[string]any{"items": []any{}})
		return
	}
	tid := middleware.MustTenantID(r.Context())
	items, err := h.Cron.AdminListTenantPromptTemplates(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

// I 增量 · GET /tenant/cron-prompt-templates/{uuid} · admin scope 详情 (含 body + variables).
//
// admin web 编辑 drawer 用; list DTO 无 body/variables, 不能拿来回填表单.
// 走 tenant.agent.read perm (与 list 一致).
func (h *Handlers) adminGetTenantPromptTemplate(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	out, err := h.Cron.AdminGetTenantPromptTemplate(r.Context(), tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// G4 · POST /tenant/cron-prompt-templates · 建租户模板 (scope=tenant 强制).
func (h *Handlers) adminCreateTenantPromptTemplate(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	actor := middleware.MustAccountID(r.Context())
	var body svccron.CreatePromptTemplateReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Cron.AdminCreateTenantPromptTemplate(r.Context(), tid, actor, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// G4 · PATCH /tenant/cron-prompt-templates/{uuid} · platform / is_system 拒.
func (h *Handlers) adminPatchTenantPromptTemplate(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	actor := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	var body svccron.PatchPromptTemplateReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Cron.AdminPatchTenantPromptTemplate(r.Context(), tid, actor, uuid, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// G4 · DELETE /tenant/cron-prompt-templates/{uuid} · 软删; 被引用 / platform / is_system 拒.
func (h *Handlers) adminDeleteTenantPromptTemplate(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	actor := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	if err := h.Cron.AdminDeleteTenantPromptTemplate(r.Context(), tid, actor, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// ===== 平台控制台 · 平台模板 CRUD (scope=platform) =====
//
// 与租户路径的差异: 无 tenant id (scope=platform 全局), 写权限走 platform.cron.create/update/delete;
// is_system 内置种子由 service 层拒改拒删。

// GET /platform/cron-prompt-templates · 平台模板列表 (全状态, 含跨租户引用数)。
func (h *Handlers) adminListPlatformPromptTemplates(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSON(w, map[string]any{"items": []any{}})
		return
	}
	items, err := h.Cron.AdminListPlatformPromptTemplates(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

// GET /platform/cron-prompt-templates/{uuid} · 平台模板详情 (含 body + variables)。
func (h *Handlers) adminGetPlatformPromptTemplate(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	out, err := h.Cron.AdminGetPlatformPromptTemplate(r.Context(), r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// POST /platform/cron-prompt-templates · 建平台模板 (全租户员工可选用其 active 版)。
func (h *Handlers) adminCreatePlatformPromptTemplate(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	actor := middleware.MustAccountID(r.Context())
	var body svccron.CreatePromptTemplateReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Cron.AdminCreatePlatformPromptTemplate(r.Context(), actor, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// PATCH /platform/cron-prompt-templates/{uuid} · 改平台模板; is_system 拒。
func (h *Handlers) adminPatchPlatformPromptTemplate(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	actor := middleware.MustAccountID(r.Context())
	var body svccron.PatchPromptTemplateReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Cron.AdminPatchPlatformPromptTemplate(r.Context(), actor, r.PathValue("uuid"), body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// DELETE /platform/cron-prompt-templates/{uuid} · 软删; is_system / 被任意租户引用拒。
func (h *Handlers) adminDeletePlatformPromptTemplate(w http.ResponseWriter, r *http.Request) {
	if h.Cron == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("cron service not wired"))
		return
	}
	actor := middleware.MustAccountID(r.Context())
	if err := h.Cron.AdminDeletePlatformPromptTemplate(r.Context(), actor, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// getTenantCronJobDetail F25 返修 · GET /tenant/cron-jobs/{uuid}?run_limit=
// 租户 admin 任务详情 + 最近运行记录（净化：无 payload/rendered_prompt，错误仅摘要）。
func (h *Handlers) getTenantCronJobDetail(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	if tid <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	jobUUID := r.PathValue("uuid")
	if jobUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	runLimit, _ := strconv.Atoi(r.URL.Query().Get("run_limit"))
	out, err := h.Cron.AdminGetTenantJob(r.Context(), tid, jobUUID, runLimit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}
