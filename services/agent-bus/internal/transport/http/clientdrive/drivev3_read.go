// drivev3_read.go — F06 Phase 2.2a: drive read-only client endpoints (drivev3 backed).
//
// 注册 4 个 URL (替换 router.go 中 legacy h.Drive 的对应 3 个 + 新增 1 个 :bootstrap):
//
//	POST /api/agent-bus/v1/drive:bootstrap
//	GET  /api/agent-bus/v1/drive/spaces                              (lazy backfill, Bootstrap 等价)
//	GET  /api/agent-bus/v1/drive/spaces/{uuid}/folders/tree
//	GET  /api/agent-bus/v1/drive/folders/{uuid}/children
//
// Legacy 路径 GET /drive/files (folder_id 查询参数) 暂保留 svcdrive 实现, 等 Phase 2.2d 切。
package clientdrive

import (
	"fmt"
	"net/http"
	"strconv"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdriv3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// driveV3Bootstrap POST /drive:bootstrap (新) 或 GET /drive/spaces (legacy 兼容).
func (h *Handlers) DriveV3Bootstrap(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3 == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 service not wired"))
		return
	}
	tenantID := middleware.MustTenantID(r.Context())
	accountID := middleware.MustAccountID(r.Context())
	// displayName 暂简化为 fmt.Sprintf("u%d", accountID) (Phase 2.9 接 F01 拿真名)
	displayName := fmt.Sprintf("u%d", accountID)
	resp, err := h.Drivev3.Bootstrap(r.Context(), tenantID, accountID, displayName)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, svcdriv3.BootstrapToDTO(resp))
}

// driveV3FolderTree GET /drive/spaces/{uuid}/folders/tree.
// ACL: space viewer+ 必检.
func (h *Handlers) DriveV3FolderTree(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3 == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 not wired"))
		return
	}
	spaceUUID := r.PathValue("uuid")
	accountID := middleware.MustAccountID(r.Context())

	// 通过 SpaceRepo 解 uuid → id
	space, err := h.Drivev3Spaces.GetByUUID(r.Context(), spaceUUID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if space == nil {
		encode.JSONError(w, apperr.ErrNotFound.Withf("space"))
		return
	}

	// ACL check
	role, err := h.Drivev3ACL.CheckEffectiveRole(r.Context(), accountID, dom.ACLTargetSpace, space.ID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if !RoleAtLeast(role, dom.ACLRoleViewer) {
		encode.JSONError(w, apperr.ErrForbidden.Withf("drive.acl.forbidden"))
		return
	}

	resp, err := h.Drivev3.FolderTree(r.Context(), space.ID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, &svcdriv3.FolderTreeDTO{Items: svcdriv3.FoldersTreeToDTO(resp.Items)})
}

// driveV3FolderChildren GET /drive/folders/{uuid}/children.
func (h *Handlers) DriveV3FolderChildren(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3 == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 not wired"))
		return
	}
	folderUUID := r.PathValue("uuid")
	accountID := middleware.MustAccountID(r.Context())

	// 通过 FolderRepo 解 uuid → id
	folder, err := h.Drivev3Folders.GetByUUID(r.Context(), folderUUID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if folder == nil {
		encode.JSONError(w, apperr.ErrNotFound.Withf("folder"))
		return
	}

	// ACL check
	role, err := h.Drivev3ACL.CheckEffectiveRole(r.Context(), accountID, dom.ACLTargetFolder, folder.ID)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if !RoleAtLeast(role, dom.ACLRoleViewer) {
		encode.JSONError(w, apperr.ErrForbidden.Withf("drive.acl.forbidden"))
		return
	}

	// 解析分页参数
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	pageSize, _ := strconv.Atoi(r.URL.Query().Get("page_size"))
	resp, err := h.Drivev3.FolderChildren(r.Context(), folder.ID, page, pageSize)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, &svcdriv3.FolderChildrenDTO{
		Folders: svcdriv3.FoldersChildrenToDTO(resp.Folders, folder.UUID),
		Files:   svcdriv3.FilesToDTO(resp.Files, folder.UUID),
		Total:   resp.Total,
	})
}

// RoleAtLeast 判断 have >= want 权限大小; ACL viewer+ checker.
func RoleAtLeast(have, want dom.ACLRole) bool {
	rank := map[dom.ACLRole]int{"": 0, dom.ACLRoleViewer: 1, dom.ACLRoleEditor: 2, dom.ACLRoleManager: 3}
	return rank[have] >= rank[want]
}
