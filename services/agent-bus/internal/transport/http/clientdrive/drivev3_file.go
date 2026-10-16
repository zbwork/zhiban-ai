// drivev3_file.go — F06 Phase 2.2d + 2.2f: file detail / preview / download / rename / move / delete.
//
// 6 个 URL:
//
//	GET    /api/agent-bus/v1/drive/files/{uuid}             — 2.2d
//	GET    /api/agent-bus/v1/drive/files/{uuid}/preview     — 2.2d
//	GET    /api/agent-bus/v1/drive/files/{uuid}/download    — 2.2f (替换 legacy)
//	PATCH  /api/agent-bus/v1/drive/files/{uuid}             — 2.2d
//	POST   /api/agent-bus/v1/drive/files/{uuid}/move        — 2.2d
//	DELETE /api/agent-bus/v1/drive/files/{uuid}             — 2.2d
//
// ACL 语义: GET / preview / download = viewer+; PATCH / move / DELETE = editor+;
// copy_status guard 在 service 层 (preview 放行任何状态, 其它 endpoint 要求 'ready').
package clientdrive

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// driveV3FileGet GET /drive/files/{uuid}: 取详情 (含 copy_status). ACL viewer+.
func (h *Handlers) DriveV3FileGet(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	resp, err := h.Drivev3File.Get(r.Context(), accountID, r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FilePreview GET /drive/files/{uuid}/preview: 签 inline GET URL. ACL viewer+.
func (h *Handlers) DriveV3FilePreview(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3File.Preview(r.Context(), accountID, tenantID, r.PathValue("uuid"), r.URL.Query().Get("sha256"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FileDownload GET /drive/files/{uuid}/download: 签 attachment GET URL.
// ACL viewer+; copy_status='ready' guard (拒 copying / copy_failed 中的部分文件下载).
// 返 JSON {url, expires_at, name}; 不做 302 跳转 (与 legacy 区别; 客户端 SDK 自行决定如何消费 URL).
func (h *Handlers) DriveV3FileDownload(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3File.Download(r.Context(), accountID, tenantID, r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FileRenameReq PATCH /drive/files/{uuid} body.
type driveV3FileRenameReq struct {
	Name string `json:"name"`
}

// driveV3FileRename PATCH /drive/files/{uuid}: 改 name. ACL editor+; copy_status='ready'.
func (h *Handlers) DriveV3FileRename(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	var req driveV3FileRenameReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	resp, err := h.Drivev3File.Rename(r.Context(), accountID, r.PathValue("uuid"), req.Name)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FileMoveReq POST /drive/files/{uuid}/move body.
//   - new_folder_uuid 留空 → 移到目标 space 根 (drive_folder_id=NULL).
//   - new_space_uuid 留空 → 同 space 内移动 (Phase 2.2d 行为).
//   - new_space_uuid 非空 → Phase 2.11/2.12 跨 space move
//     (sync inline server-side copy; copy_status='copying' → 'ready' / 'copy_failed').
type driveV3FileMoveReq struct {
	NewFolderUUID string `json:"new_folder_uuid"`
	NewSpaceUUID  string `json:"new_space_uuid,omitempty"`
}

// driveV3FileMove POST /drive/files/{uuid}/move: 同 space / 跨 space move.
// ACL editor+; copy_status='ready' guard (src 必须 ready 才能移动).
func (h *Handlers) DriveV3FileMove(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	var req driveV3FileMoveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	resp, err := h.Drivev3File.Move(r.Context(), accountID, r.PathValue("uuid"), req.NewSpaceUUID, req.NewFolderUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FileRetryCopy POST /drive/files/{uuid}/retry-copy: Phase 2.11/2.12.
// 重做 server-side Copy (copy_failed → copying → ready/copy_failed). ACL editor+.
func (h *Handlers) DriveV3FileRetryCopy(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	resp, err := h.Drivev3File.RetryCopy(r.Context(), accountID, r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FileCancelCopy POST /drive/files/{uuid}/cancel-copy: Phase 2.11/2.12.
// 放弃 copy_failed 行: hard delete + release dst quota. ACL editor+.
func (h *Handlers) DriveV3FileCancelCopy(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	if err := h.Drivev3File.CancelCopy(r.Context(), accountID, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"ok": true})
}

// driveV3FileListVersions GET /drive/files/{uuid}/versions: 列历史版本 (DESC). ACL viewer+.
// versions repo 未注入 (旧 wiring) → 500 drive.versions_not_wired.
func (h *Handlers) DriveV3FileListVersions(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	resp, err := h.Drivev3File.ListVersions(r.Context(), accountID, r.PathValue("uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": resp})
}

// driveV3FileRestoreVersion POST /drive/files/{uuid}/versions/{version_no}/restore: 把历史版本提为当前.
// ACL editor+; copy_status='ready' guard.
func (h *Handlers) DriveV3FileRestoreVersion(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	versionStr := r.PathValue("version_no")
	versionNo, err := strconv.Atoi(versionStr)
	if err != nil || versionNo <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("version_no must be positive integer"))
		return
	}
	resp, err := h.Drivev3File.RestoreVersion(r.Context(), accountID, r.PathValue("uuid"), versionNo)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FileDelete DELETE /drive/files/{uuid}: 软删. ACL editor+; copy_status='ready'.
// drive_recycle_bin 写入 + 用量释放在 Phase 2.2e 接入.
func (h *Handlers) DriveV3FileDelete(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3File == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 file service not wired"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	if err := h.Drivev3File.Delete(r.Context(), accountID, r.PathValue("uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
