// drivev3_sharedspace.go — F06 Phase 2.2e: shared-space create/list/update/archive 端点.
//
// 2 个 URL:
//
//	POST   /api/agent-bus/v1/drive/shared-spaces        caller = owner (default = manager)
//	GET    /api/agent-bus/v1/drive/shared-spaces        caller 可访问 (owner OR ACL grant)
//	PATCH  /api/agent-bus/v1/drive/shared-spaces/{uuid} caller manager+
//	DELETE /api/agent-bus/v1/drive/shared-spaces/{uuid} caller manager+
package clientdrive

import (
	"encoding/json"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// driveV3SharedSpaceCreateReq POST /drive/shared-spaces body.
type driveV3SharedSpaceCreateReq struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

// driveV3SharedSpaceUpdateReq PATCH /drive/shared-spaces/{uuid} body.
type driveV3SharedSpaceUpdateReq struct {
	Name        string  `json:"name"`
	Description *string `json:"description,omitempty"`
}

// driveV3SharedSpaceCreate POST /drive/shared-spaces: 创建 shared space; caller 即 owner.
func (h *Handlers) DriveV3SharedSpaceCreate(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	var req driveV3SharedSpaceCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3SharedSpace.Create(r.Context(), accountID, tenantID, req.Name, req.Description)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3SharedSpaceList GET /drive/shared-spaces: 返 caller viewer+ 的 shared space.
func (h *Handlers) DriveV3SharedSpaceList(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3SharedSpace.List(r.Context(), accountID, tenantID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3SharedSpaceUpdate PATCH /drive/shared-spaces/{uuid}: 改共享文件夹名称/描述。
func (h *Handlers) DriveV3SharedSpaceUpdate(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	var req driveV3SharedSpaceUpdateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3SharedSpace.Update(r.Context(), accountID, tenantID, r.PathValue("uuid"), req.Name, req.Description)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3SharedSpaceArchive DELETE /drive/shared-spaces/{uuid}: 归档隐藏共享文件夹。
func (h *Handlers) DriveV3SharedSpaceArchive(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	if err := h.Drivev3SharedSpace.Archive(r.Context(), accountID, tenantID, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// =====================================================
// B3: shared-space members 4 端点
//   POST   /drive/spaces/{uuid}/members                 manager+
//   GET    /drive/spaces/{uuid}/members                 viewer+
//   PATCH  /drive/spaces/{uuid}/members/{account_uuid}  manager+
//   DELETE /drive/spaces/{uuid}/members/{account_uuid}  manager+
// 路径前缀 /drive/spaces 而非 /drive/shared-spaces — members 概念未来可能扩展到其他 space kind
// (虽然 service 层目前 reject non-shared), URI 设计保持开放.
// =====================================================

// driveV3SpaceMemberAddReq POST /drive/spaces/{uuid}/members body.
type driveV3SpaceMemberAddReq struct {
	AccountUUID string `json:"account_uuid"`
	Role        string `json:"role"` // viewer | editor | manager
}

func (h *Handlers) DriveV3SpaceMemberAdd(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	var req driveV3SpaceMemberAddReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3SharedSpace.AddMember(r.Context(), accountID, tenantID, r.PathValue("uuid"), req.AccountUUID, req.Role)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) DriveV3SpaceMemberList(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	rows, err := h.Drivev3SharedSpace.ListMembers(r.Context(), accountID, tenantID, r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": rows})
}

// driveV3SpaceMemberUpdateReq PATCH /drive/spaces/{uuid}/members/{account_uuid} body.
type driveV3SpaceMemberUpdateReq struct {
	Role string `json:"role"`
}

func (h *Handlers) DriveV3SpaceMemberUpdate(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	var req driveV3SpaceMemberUpdateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3SharedSpace.UpdateMember(r.Context(), accountID, tenantID, r.PathValue("uuid"), r.PathValue("account_uuid"), req.Role)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) DriveV3SpaceMemberRemove(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	if err := h.Drivev3SharedSpace.RemoveMember(r.Context(), accountID, tenantID, r.PathValue("uuid"), r.PathValue("account_uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// =====================================================
// B4: shared folder members 4 端点
//   POST   /drive/folders/{uuid}/members                 manager+
//   GET    /drive/folders/{uuid}/members                 viewer+
//   PATCH  /drive/folders/{uuid}/members/{account_uuid}  manager+
//   DELETE /drive/folders/{uuid}/members/{account_uuid}  manager+
// 子目录默认继承上级账号协作者;写操作只写当前 folder direct grant。
// =====================================================

func (h *Handlers) DriveV3FolderMemberAdd(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	var req driveV3SpaceMemberAddReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3SharedSpace.AddFolderMember(r.Context(), accountID, tenantID, r.PathValue("uuid"), req.AccountUUID, req.Role)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) DriveV3FolderMemberList(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	rows, err := h.Drivev3SharedSpace.ListFolderMembers(r.Context(), accountID, tenantID, r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": rows})
}

func (h *Handlers) DriveV3FolderMemberUpdate(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	var req driveV3SpaceMemberUpdateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3SharedSpace.UpdateFolderMember(r.Context(), accountID, tenantID, r.PathValue("uuid"), r.PathValue("account_uuid"), req.Role)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) DriveV3FolderMemberRemove(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3SharedSpace == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 shared-space service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	if err := h.Drivev3SharedSpace.RemoveFolderMember(r.Context(), accountID, tenantID, r.PathValue("uuid"), r.PathValue("account_uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
