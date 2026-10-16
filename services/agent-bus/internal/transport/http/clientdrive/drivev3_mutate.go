// drivev3_mutate.go — F06 Phase 2.2b: drive folder mutation client endpoints (drivev3 backed).
//
// 4 个 URL (替换 legacy router.go 中 h.Drive 的 2 个 POST/PATCH folder, 新增 :move + DELETE):
//
//	POST   /api/agent-bus/v1/drive/folders                 — 新建 folder
//	PATCH  /api/agent-bus/v1/drive/folders/{uuid}          — 改名 (body: name)
//	POST   /api/agent-bus/v1/drive/folders/{uuid}/move     — 同 space 移动 (body: new_parent_uuid)
//	DELETE /api/agent-bus/v1/drive/folders/{uuid}          — 软删 (必须 empty)
//
// ACL/系统目录 guard / 防环 / 同名冲突等全由 svcdriv3.FolderSvc 把守; handler 仅做 IO + 入参 decode.
package clientdrive

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcdriv3 "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

// createFolderReq POST /drive/folders 请求体.
//
// parent_uuid 留空 → 在 space 根下建; 非空 → 在指定 folder 下建 (必须同 space).
type createFolderReq struct {
	SpaceUUID  string `json:"space_uuid"`
	ParentUUID string `json:"parent_uuid,omitempty"`
	Name       string `json:"name"`
}

// renameFolderReq PATCH /drive/folders/{uuid} 请求体.
//
// 仅支持 rename; move 走 :move 端点; 不再像 legacy 那样接收 new_parent_uuid 双重职责.
type renameFolderReq struct {
	Name string `json:"name"`
}

// moveFolderReq POST /drive/folders/{uuid}/move 请求体.
//
// new_parent_uuid 空字符串 = 移到 space 根; 非空 = 移到同 space 下指定 folder.
type moveFolderReq struct {
	NewParentUUID string `json:"new_parent_uuid"`
}

// driveV3FolderCreate POST /drive/folders
func (h *Handlers) DriveV3FolderCreate(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Folder == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 folder service not wired"))
		return
	}
	var req createFolderReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	folder, err := h.Drivev3Folder.Create(r.Context(), accountID, tenantID, req.SpaceUUID, req.ParentUUID, req.Name)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, svcdriv3.FolderToDTO(folder, req.ParentUUID))
}

// driveV3FolderRename PATCH /drive/folders/{uuid}
func (h *Handlers) DriveV3FolderRename(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Folder == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 folder service not wired"))
		return
	}
	folderUUID := r.PathValue("uuid")
	if folderUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("folder uuid required"))
		return
	}
	var req renameFolderReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	folder, err := h.Drivev3Folder.Rename(r.Context(), accountID, folderUUID, req.Name)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// rename 不改 parent; parent_uuid 经 repo 反查父节点 (root → 空).
	parentUUID := ""
	if folder.ParentID != nil {
		if p, perr := h.Drivev3Folders.GetByID(r.Context(), *folder.ParentID); perr == nil && p != nil {
			parentUUID = p.UUID
		}
	}
	encode.JSON(w, svcdriv3.FolderToDTO(folder, parentUUID))
}

// driveV3FolderMove POST /drive/folders/{uuid}/move
func (h *Handlers) DriveV3FolderMove(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Folder == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 folder service not wired"))
		return
	}
	folderUUID := r.PathValue("uuid")
	if folderUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("folder uuid required"))
		return
	}
	var req moveFolderReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	folder, err := h.Drivev3Folder.MoveSameSpace(r.Context(), accountID, folderUUID, req.NewParentUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, svcdriv3.FolderToDTO(folder, req.NewParentUUID))
}

// driveV3FolderDelete DELETE /drive/folders/{uuid}[?recursive=true]
//
// B2: recursive=true 时级联子树 (子 folders + 子 files 一并软删 + 各写 recycle 行);
// 缺省 (或 recursive=false) 保留老语义: 非空 → 409 drive.folder_not_empty.
// 接受值: "true", "1" (大小写不敏感); 其它一律 false.
func (h *Handlers) DriveV3FolderDelete(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Folder == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 folder service not wired"))
		return
	}
	folderUUID := r.PathValue("uuid")
	if folderUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("folder uuid required"))
		return
	}
	recursive := false
	switch strings.ToLower(r.URL.Query().Get("recursive")) {
	case "true", "1":
		recursive = true
	}
	accountID := middleware.MustAccountID(r.Context())
	if err := h.Drivev3Folder.Delete(r.Context(), accountID, folderUUID, recursive); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
