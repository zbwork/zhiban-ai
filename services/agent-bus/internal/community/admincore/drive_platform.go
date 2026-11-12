// drive_platform.go — F06 Phase B admin: 平台云盘 usage + workers endpoints.
//
//	GET  /api/admin/v1/platform/drive/usage                    platform.drive.read_usage
//	GET  /api/admin/v1/platform/drive/usage/summary            platform.drive.read_usage
//	GET  /api/admin/v1/platform/drive/workers                  platform.drive.read_workers
//	GET  /api/admin/v1/platform/drive/workers/{job}/failures   platform.drive.read_workers   (2026-07-06)
//	POST /api/admin/v1/platform/drive/workers/{job}/trigger    platform.drive.manage_workers (2026-07-06)
//
// 实现: svcdrivev3.AdminUsageSvc + svcdrivev3.AdminWorkersSvc.
package admincore

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdrivev3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// DriveUsageAdminService — 平台用量服务窄抽象.
type DriveUsageAdminService interface {
	List(ctx context.Context, tenantID int64, q, tenantStatus, sort string, limit, offset int) (*svcdrivev3.AdminUsageListResp, error)
	Summary(ctx context.Context, tenantID int64, q, tenantStatus string) (*svcdrivev3.AdminUsageSummaryResp, error)
}

// DriveWorkersAdminService — drive-worker 状态服务窄抽象.
type DriveWorkersAdminService interface {
	List(ctx context.Context) (*svcdrivev3.AdminWorkersListResp, error)
	ListFailures(ctx context.Context, job string, limit, offset int) (*svcdrivev3.AdminWorkerFailuresResp, error)
	Trigger(ctx context.Context, job string, requestedBy int64) (*svcdrivev3.AdminWorkerTriggerResp, error)
}

// DrivePlatformQuotaService — F06 v0.3.1 §3.3 平台调整租户总额度窄抽象.
type DrivePlatformQuotaService interface {
	SetTenantQuota(ctx context.Context, tenantID, quotaBytes, updatedBy int64) error
}

func (h *Handlers) listPlatformDriveUsage(w http.ResponseWriter, r *http.Request) {
	if h.DriveUsageAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin usage service not wired"))
		return
	}
	q := r.URL.Query()
	tid, _ := strconv.ParseInt(q.Get("tenant_id"), 10, 64)
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	resp, err := h.DriveUsageAdmin.List(r.Context(), tid, q.Get("q"), q.Get("tenant_status"), q.Get("sort"), limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// getPlatformDriveUsageSummary GET /api/admin/v1/platform/drive/usage/summary.
// 汇总卡数据; 过滤参数 (q / tenant_id / tenant_status) 与列表一致, 不分页.
// 权限: platform.drive.read_usage (列表的聚合视图, 不单设权限).
func (h *Handlers) getPlatformDriveUsageSummary(w http.ResponseWriter, r *http.Request) {
	if h.DriveUsageAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin usage service not wired"))
		return
	}
	q := r.URL.Query()
	tid, _ := strconv.ParseInt(q.Get("tenant_id"), 10, 64)
	resp, err := h.DriveUsageAdmin.Summary(r.Context(), tid, q.Get("q"), q.Get("tenant_status"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) listPlatformDriveWorkers(w http.ResponseWriter, r *http.Request) {
	if h.DriveWorkersAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin workers service not wired"))
		return
	}
	resp, err := h.DriveWorkersAdmin.List(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// listPlatformDriveWorkerFailures GET /api/admin/v1/platform/drive/workers/{job}/failures.
// 权限: platform.drive.read_workers; query limit/offset 后端分页.
func (h *Handlers) listPlatformDriveWorkerFailures(w http.ResponseWriter, r *http.Request) {
	if h.DriveWorkersAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin workers service not wired"))
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	resp, err := h.DriveWorkersAdmin.ListFailures(r.Context(), r.PathValue("job"), limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// triggerPlatformDriveWorker POST /api/admin/v1/platform/drive/workers/{job}/trigger.
// 权限: platform.drive.manage_workers (与 read_workers 分开授予).
// 幂等: 已有未消费请求返 already_pending=true, 不重复入队.
func (h *Handlers) triggerPlatformDriveWorker(w http.ResponseWriter, r *http.Request) {
	if h.DriveWorkersAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin workers service not wired"))
		return
	}
	caller := middleware.MustAccountID(r.Context())
	resp, err := h.DriveWorkersAdmin.Trigger(r.Context(), r.PathValue("job"), caller)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// putPlatformDriveTenantQuotaReq F06 v0.3.1 §3.3 body shape.
type putPlatformDriveTenantQuotaReq struct {
	QuotaBytes int64 `json:"quota_bytes"`
}

// putPlatformDriveTenantQuota PUT /api/admin/v1/platform/drive/tenants/{tenant_id}/quota.
// 权限: platform.drive.manage_quota (新增, 与 manage_storage 分开授予).
// body: { quota_bytes }; -1 = 无限. 小于实时 used → 412 drive.quota_below_used.
// updatedBy = platform admin caller account id.
func (h *Handlers) putPlatformDriveTenantQuota(w http.ResponseWriter, r *http.Request) {
	if h.DrivePlatformQuota == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: platform quota service not wired"))
		return
	}
	tidStr := r.PathValue("tenant_id")
	tid, err := strconv.ParseInt(tidStr, 10, 64)
	if err != nil || tid <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("tenant_id must be positive integer"))
		return
	}
	var req putPlatformDriveTenantQuotaReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	caller := middleware.MustAccountID(r.Context())
	if err := h.DrivePlatformQuota.SetTenantQuota(r.Context(), tid, req.QuotaBytes, caller); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
