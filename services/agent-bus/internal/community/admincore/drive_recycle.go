// drive_recycle.go — F06 Phase B admin: 租户云盘回收站 admin endpoints.
//
// 3 个 URL:
//
//	GET    /api/admin/v1/tenant/drive/recycle                       tenant.drive.manage_recycle
//	POST   /api/admin/v1/tenant/drive/recycle/{uuid}/restore        tenant.drive.manage_recycle
//	DELETE /api/admin/v1/tenant/drive/recycle/{uuid}/purge          tenant.drive.manage_recycle
//
// 与 bus client (/api/agent-bus/v1/drive/recycle/*) 区别: admin 看全租户跨账户回收行;
// caller 已通过 admin perm 把关, service 不再做 caller-ownership check.
//
// 实现: svcdrivev3.AdminRecycleSvc.
package admincore

import (
	"context"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdrivev3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// DriveRecycleAdminService — admin 回收站服务窄抽象.
type DriveRecycleAdminService interface {
	List(ctx context.Context, tenantID int64, limit int, cursor int64) ([]svcdrivev3.AdminRecycleItem, int64, error)
	Restore(ctx context.Context, tenantID int64, recycleUUID string, updatedBy int64) error
	Purge(ctx context.Context, tenantID int64, recycleUUID string) error
}

func (h *Handlers) listTenantDriveRecycle(w http.ResponseWriter, r *http.Request) {
	if h.DriveRecycleAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin recycle service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	cursor, _ := strconv.ParseInt(q.Get("cursor"), 10, 64)
	items, next, err := h.DriveRecycleAdmin.List(r.Context(), tid, limit, cursor)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items, "next_cursor": next})
}

func (h *Handlers) restoreTenantDriveRecycle(w http.ResponseWriter, r *http.Request) {
	if h.DriveRecycleAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin recycle service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	caller := middleware.MustAccountID(r.Context())
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	if err := h.DriveRecycleAdmin.Restore(r.Context(), tid, uuid, caller); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) purgeTenantDriveRecycle(w http.ResponseWriter, r *http.Request) {
	if h.DriveRecycleAdmin == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: admin recycle service not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return
	}
	if err := h.DriveRecycleAdmin.Purge(r.Context(), tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
