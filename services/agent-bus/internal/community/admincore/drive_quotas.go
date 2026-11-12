// drive_quotas.go — F06 Phase B admin: 租户云盘配额 admin endpoints.
//
// 2 个 URL:
//
//	GET  /api/admin/v1/tenant/drive/quotas                         tenant.drive.manage_quota
//	PUT  /api/admin/v1/tenant/drive/quotas/accounts/{account_id}   tenant.drive.manage_quota
//
// 不暴露 PUT /tenant/drive/quotas (修改 tenant_quota_bytes) — 按 F06 拍定: 总额度由平台 admin 管;
// 前端 wrapper 之前的 setTenantQuota() 已废, 仅看 readonly 总额. 平台总额管理待 platform 端点.
//
// 实现: svcdrivev3.AdminQuotaSvc.
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

// DriveQuotaAdminService — admin 配额服务窄抽象 (cmd/admin 注入 *svcdrivev3.AdminQuotaSvc).
type DriveQuotaAdminService interface {
	GetTenantSummary(ctx context.Context, tenantID int64) (*svcdrivev3.AdminTenantQuotaSummary, error)
	UpsertAccountQuota(ctx context.Context, tenantID, accountID, quotaBytes, updatedBy int64) error
}

func (h *Handlers) getTenantDriveQuotas(w http.ResponseWriter, r *http.Request) {
	if h.DriveQuotaAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin quota service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	resp, err := h.DriveQuotaAdmin.GetTenantSummary(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

type putAccountQuotaReq struct {
	QuotaBytes int64 `json:"quota_bytes"`
}

func (h *Handlers) putTenantDriveAccountQuota(w http.ResponseWriter, r *http.Request) {
	if h.DriveQuotaAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin quota service not wired"))
		return
	}
	aidStr := r.PathValue("account_id")
	aid, err := strconv.ParseInt(aidStr, 10, 64)
	if err != nil || aid <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("account_id must be positive integer"))
		return
	}
	var req putAccountQuotaReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	caller := middleware.MustAccountID(r.Context())
	if err := h.DriveQuotaAdmin.UpsertAccountQuota(r.Context(), tid, aid, req.QuotaBytes, caller); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
