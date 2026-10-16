// drivev3_recycle.go — F06 Phase 2.2e: recycle list / preview / restore / purge 端点.
//
// 3 个 URL:
//
//	GET    /api/agent-bus/v1/drive/recycle                            ACL manager+ on space
//	GET    /api/agent-bus/v1/drive/recycle/{uuid}/preview              ACL manager+; 已软删图片预览
//	POST   /api/agent-bus/v1/drive/recycle/{uuid}/restore              ACL manager+; 配额不变
//	DELETE /api/agent-bus/v1/drive/recycle/{uuid}/purge                ACL manager+; 释放配额 + store.Delete
package clientdrive

import (
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// driveV3RecycleList GET /drive/recycle?limit=...: 列 caller manager+ space 内回收行.
func (h *Handlers) DriveV3RecycleList(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Recycle == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 recycle service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	limit := parseLimitQuery(r, 50, 200)
	resp, err := h.Drivev3Recycle.List(r.Context(), accountID, tenantID, limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3RecyclePreview GET /drive/recycle/{uuid}/preview: 为已软删图片签 inline URL.
func (h *Handlers) DriveV3RecyclePreview(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Recycle == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 recycle service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3Recycle.Preview(r.Context(), accountID, tenantID, r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3RecycleRestore POST /drive/recycle/{uuid}/restore: 反向软删 + tombstone 回收行.
func (h *Handlers) DriveV3RecycleRestore(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Recycle == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 recycle service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	if err := h.Drivev3Recycle.Restore(r.Context(), accountID, tenantID, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// driveV3RecyclePurge DELETE /drive/recycle/{uuid}/purge: 物理删 + 释放配额.
func (h *Handlers) DriveV3RecyclePurge(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Recycle == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 recycle service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	if err := h.Drivev3Recycle.Purge(r.Context(), accountID, tenantID, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
