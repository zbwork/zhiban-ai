// Bus transport for chat 附件 (Batch 3C T3.7 / T3.8 — Slice A1/Phase 2.Z-pre-1 cutover).
//
// 路由 (JSON shape 与 legacy svcmf 完全一致, 客户端无需改):
//
//	POST /api/agent-bus/v1/message-files/presign     → drive.ChatUploadSvc.Presign
//	POST /api/agent-bus/v1/message-files/confirm     → drive.ChatUploadSvc.Confirm
//	GET  /api/agent-bus/v1/message-files/{uuid}/download → 302 → object 存储签名 URL
//	GET  /api/agent-bus/v1/message-files/{uuid}/preview  → 302 → object 存储签名 URL
//
// 底层从 legacy message_files 表 + svcmf 切到 drive_files (scope='chat') +
// conversation_message_files (cmf, bind 时写). 业务编排见 drive.ChatUploadSvc.
package clientfiles

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

func (h *Handlers) Upload(w http.ResponseWriter, r *http.Request) {
	if h.ChatUpload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("message-files service not wired"))
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
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	resp, err := h.ChatUpload.Upload(r.Context(), accID, tid, drive.ChatUploadReq{
		FileName:         fileName,
		FileSize:         header.Size,
		MimeType:         mimeType,
		ConversationUUID: strings.TrimSpace(r.FormValue("conversation_uuid")),
		Body:             file,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) Presign(w http.ResponseWriter, r *http.Request) {
	if h.ChatUpload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("message-files service not wired"))
		return
	}
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	var req drive.ChatPresignReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	resp, err := h.ChatUpload.Presign(r.Context(), accID, tid, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) Confirm(w http.ResponseWriter, r *http.Request) {
	if h.ChatUpload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("message-files service not wired"))
		return
	}
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	var req drive.ChatConfirmReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	resp, err := h.ChatUpload.Confirm(r.Context(), accID, tid, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) Download(w http.ResponseWriter, r *http.Request) {
	h.DownloadOrPreview(w, r, false)
}

func (h *Handlers) Preview(w http.ResponseWriter, r *http.Request) {
	h.DownloadOrPreview(w, r, true)
}

func (h *Handlers) DownloadOrPreview(w http.ResponseWriter, r *http.Request, inline bool) {
	if h.ChatUpload == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("message-files service not wired"))
		return
	}
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("file_uuid required"))
		return
	}
	var (
		resp *drive.ChatDownloadResp
		err  error
	)
	if inline {
		resp, err = h.ChatUpload.Preview(r.Context(), accID, tid, uuid)
	} else {
		resp, err = h.ChatUpload.Download(r.Context(), accID, tid, uuid)
	}
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if r.Header.Get("Accept") == "application/json" {
		encode.JSON(w, resp)
		return
	}
	http.Redirect(w, r, resp.URL, http.StatusFound)
}
