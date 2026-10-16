// drivev3_upload.go — F06 Phase 2.2c + Phase 2.M: drive 上传 staging→final 流程 client endpoints.
//
// 4 个 URL:
//
//	POST /api/agent-bus/v1/drive/files:presign-put          (single ≤10MB / multipart ≥10MB 自动分流)
//	POST /api/agent-bus/v1/drive/files:complete-multipart   (Phase 2.M strategy A: 自动 enter confirm 后半段)
//	POST /api/agent-bus/v1/drive/files:confirm              (single 用)
//	POST /api/agent-bus/v1/drive/files:refresh-part-urls    (Phase 2.M: 重签 part presign, staging_key 不变)
//
// ACL editor+ / 配额 / Stat verify / Copy / 重名等全由 svcdriv3.UploadSvc 把守;
// handler 只做 IO + 入参 decode.
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

// driveV3FilesUpload POST /drive/files:upload.
// Proxy-upload variant for clients that cannot reach the object-store write
// endpoint. Service still uses the existing staging key + confirm path.
func (h *Handlers) DriveV3FilesUpload(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Upload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 upload service not wired"))
		return
	}
	if err := r.ParseMultipartForm(uploadMaxMemory); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("parse multipart: %v", err))
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("missing file field: %v", err))
		return
	}
	defer file.Close()
	if header.Size <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("empty file"))
		return
	}
	fileName := strings.TrimSpace(r.FormValue("file_name"))
	if fileName == "" {
		fileName = header.Filename
	}
	mimeType := strings.ToLower(strings.TrimSpace(r.FormValue("mime_type")))
	if mimeType == "" {
		mimeType = strings.ToLower(strings.TrimSpace(header.Header.Get("Content-Type")))
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3Upload.UploadProxy(r.Context(), accountID, tenantID, svcdriv3.ProxyUploadReq{
		PresignPutReq: svcdriv3.PresignPutReq{
			SpaceUUID:  strings.TrimSpace(r.FormValue("space_uuid")),
			FolderUUID: strings.TrimSpace(r.FormValue("folder_uuid")),
			FileName:   fileName,
			MimeType:   mimeType,
			SizeBytes:  header.Size,
		},
		Body: file,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"file": resp})
}

// driveV3FilesPresignPut POST /drive/files:presign-put.
// 本 slice 仅 single 模式; 大文件 multipart 在后续 slice.
func (h *Handlers) DriveV3FilesPresignPut(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Upload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 upload service not wired"))
		return
	}
	var req svcdriv3.PresignPutReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3Upload.PresignPut(r.Context(), accountID, tenantID, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FilesCompleteMultipart POST /drive/files:complete-multipart.
// F06 Phase 2.M strategy A: 一次 HTTP 调用做 S3 Complete + Stat + Copy + INSERT + quota + ticket=done.
func (h *Handlers) DriveV3FilesCompleteMultipart(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Upload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 upload service not wired"))
		return
	}
	var req svcdriv3.CompleteMultipartReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3Upload.CompleteMultipart(r.Context(), accountID, tenantID, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"file": resp})
}

// driveV3FilesRefreshPartURLs POST /drive/files:refresh-part-urls.
// F06 Phase 2.M / §3.2 line 938: 重签 multipart part PUT URL (staging_key + upload_id 不变).
func (h *Handlers) DriveV3FilesRefreshPartURLs(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Upload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 upload service not wired"))
		return
	}
	var req svcdriv3.RefreshPartURLsReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3Upload.RefreshPartURLs(r.Context(), accountID, tenantID, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

// driveV3FilesConfirm POST /drive/files:confirm.
func (h *Handlers) DriveV3FilesConfirm(w http.ResponseWriter, r *http.Request) {
	if h.Drivev3Upload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("drive: v3 upload service not wired"))
		return
	}
	var req svcdriv3.ConfirmReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())
	resp, err := h.Drivev3Upload.Confirm(r.Context(), accountID, tenantID, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"file": resp})
}
