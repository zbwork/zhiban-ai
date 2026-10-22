// knowledge.go — Bus client KB endpoints (M8 Phase A).
//
// 路由: /api/agent-bus/v1/knowledge-bases/* + /api/agent-bus/v1/knowledge-bases/:uuid/search.
//
// 与 docs/tasks/m8-knowledge-bases.md §T8.3 / §T8.5 一致:
//   - 服务层显式接 accountID / tenantID / perms (从 claims.Perms 取);
//   - upload 走 multipart/form-data; content-type 必须是 F07 支持的文档 MIME.
package clientknowledge

import (
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

type Handlers struct{ Knowledge svckb.Service }

// uploadMaxMemory multipart 解析时驻留内存上限; 超出走临时文件.
const uploadMaxMemory = 4 * 1024 * 1024 // 4MB

func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	items, err := h.Knowledge.ListKB(r.Context(), accID, tid, perms)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) Get(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	kb, err := h.Knowledge.GetKB(r.Context(), accID, tid, perms, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, kb)
}

func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	var body svckb.CreateKBReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Knowledge.CreateKB(r.Context(), accID, tid, perms, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) Patch(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	var body svckb.PatchKBReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Knowledge.PatchKB(r.Context(), accID, tid, perms, uuid, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) Delete(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	if err := h.Knowledge.DeleteKB(r.Context(), accID, tid, perms, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) ListFolders(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	items, err := h.Knowledge.ListFolders(r.Context(), accID, tid, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) CreateFolder(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	var body svckb.CreateFolderReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Knowledge.CreateFolder(r.Context(), accID, tid, perms, uuid, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) PatchFolder(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	folderUUID := r.PathValue("folder_uuid")
	var body svckb.PatchFolderReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Knowledge.PatchFolder(r.Context(), accID, tid, perms, uuid, folderUUID, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) DeleteFolder(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	folderUUID := r.PathValue("folder_uuid")
	if err := h.Knowledge.DeleteFolder(r.Context(), accID, tid, perms, uuid, folderUUID); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) ListDocs(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	q := r.URL.Query()
	page := atoiOr(q.Get("page"), 1)
	pageSize := atoiOr(q.Get("page_size"), 50)
	if page < 1 {
		page = 1
	}
	offset := (page - 1) * pageSize
	items, total, err := h.Knowledge.ListDocumentsPaged(r.Context(), accID, tid, uuid, strings.TrimSpace(q.Get("kb_folder_uuid")), pageSize, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total})
}

func (h *Handlers) DownloadDoc(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	docUUID := r.PathValue("doc_uuid")
	out, err := h.Knowledge.DownloadDocument(r.Context(), accID, tid, uuid, docUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	fileName := strings.TrimSpace(out.Title)
	if fileName == "" {
		fileName = docUUID
	}
	mediaType, _, mimeErr := mime.ParseMediaType(out.MimeType)
	if mimeErr != nil {
		mediaType = "application/octet-stream"
	}
	disposition := "attachment"
	switch mediaType {
	case "application/pdf", "text/plain", "image/png", "image/jpeg", "image/jpg", "image/gif", "image/tif", "image/tiff":
		disposition = "inline"
	}
	w.Header().Set("Content-Type", mediaType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Content-Length", strconv.Itoa(len(out.Content)))
	w.Header().Set("Content-Disposition", mime.FormatMediaType(disposition, map[string]string{"filename": fileName}))
	_, _ = w.Write(out.Content)
}

func (h *Handlers) UploadDoc(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	ct := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Type")))
	var req svckb.UploadDocReq
	switch {
	case strings.HasPrefix(ct, "multipart/form-data"):
		r.Body = http.MaxBytesReader(w, r.Body, svckb.DefaultDocMaxBytes+(1<<20))
		if err := r.ParseMultipartForm(uploadMaxMemory); err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
			return
		}
		defer r.MultipartForm.RemoveAll()
		file, fh, err := r.FormFile("file")
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("file part missing: %v", err))
			return
		}
		defer file.Close()
		buf, err := io.ReadAll(file)
		if err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		req.Title = strings.TrimSpace(r.FormValue("title"))
		if req.Title == "" {
			req.Title = fh.Filename
		}
		req.MimeType = strings.ToLower(strings.TrimSpace(r.FormValue("mime_type")))
		if req.MimeType == "" {
			req.MimeType = fh.Header.Get("Content-Type")
		}
		req.KBFolderUUID = strings.TrimSpace(r.FormValue("kb_folder_uuid"))
		req.Content = buf
	default:
		// 直接 PUT raw body (smoke 用; spec 主路径是 multipart).
		buf, err := io.ReadAll(http.MaxBytesReader(w, r.Body, svckb.DefaultDocMaxBytes))
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
			return
		}
		req.Title = strings.TrimSpace(r.URL.Query().Get("title"))
		req.MimeType = strings.ToLower(strings.TrimSpace(r.URL.Query().Get("mime_type")))
		if req.MimeType == "" {
			req.MimeType = r.Header.Get("Content-Type")
		}
		req.KBFolderUUID = strings.TrimSpace(r.URL.Query().Get("kb_folder_uuid"))
		req.Content = buf
	}
	out, err := h.Knowledge.UploadDocument(r.Context(), accID, tid, perms, uuid, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) DeleteDoc(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	docUUID := r.PathValue("doc_uuid")
	if err := h.Knowledge.DeleteDocument(r.Context(), accID, tid, perms, uuid, docUUID); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

func (h *Handlers) PatchDoc(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	perms := ClaimsPerms(r)
	uuid := r.PathValue("uuid")
	docUUID := r.PathValue("doc_uuid")
	var body svckb.PatchDocumentReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Knowledge.PatchDocument(r.Context(), accID, tid, perms, uuid, docUUID, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) Search(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	var body svckb.SearchReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Knowledge.Search(r.Context(), accID, tid, uuid, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// claimsPerms 从 ctx 取 JWT claims.Perms; 不存在 / 不可读取时返空集合.
//
// Bus Client API 不挂 RequirePermission, 但 Auth middleware 已注入 claims; service 层
// 用 perms 做 KB 写闸 (tenant.kb.update).
func ClaimsPerms(r *http.Request) []string {
	c, ok := middleware.Claims(r.Context())
	if !ok || c == nil {
		return nil
	}
	return c.Perms
}

func atoiOr(s string, fallback int) int {
	v, err := strconv.Atoi(s)
	if err != nil {
		return fallback
	}
	return v
}

func (h *Handlers) LinkFromDrive(w http.ResponseWriter, r *http.Request) {
	var body struct {
		DriveFileUUID string `json:"drive_file_uuid"`
		KBFolderUUID  string `json:"kb_folder_uuid"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	out, err := h.Knowledge.LinkFromDrive(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), ClaimsPerms(r), r.PathValue("uuid"), body.DriveFileUUID, body.KBFolderUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}
func (h *Handlers) Register(mux *http.ServeMux, auth func(http.Handler) http.Handler) {
	for pattern, fn := range map[string]http.HandlerFunc{
		"GET /knowledge-bases": h.List, "POST /knowledge-bases": h.Create,
		"GET /knowledge-bases/{uuid}": h.Get, "PATCH /knowledge-bases/{uuid}": h.Patch, "DELETE /knowledge-bases/{uuid}": h.Delete,
		"GET /knowledge-bases/{uuid}/folders/tree": h.ListFolders, "POST /knowledge-bases/{uuid}/folders": h.CreateFolder,
		"PATCH /knowledge-bases/{uuid}/folders/{folder_uuid}": h.PatchFolder, "DELETE /knowledge-bases/{uuid}/folders/{folder_uuid}": h.DeleteFolder,
		"GET /knowledge-bases/{uuid}/documents": h.ListDocs, "POST /knowledge-bases/{uuid}/documents/upload": h.UploadDoc,
		"GET /knowledge-bases/{uuid}/documents/{doc_uuid}/download": h.DownloadDoc,
		"PATCH /knowledge-bases/{uuid}/documents/{doc_uuid}":        h.PatchDoc, "DELETE /knowledge-bases/{uuid}/documents/{doc_uuid}": h.DeleteDoc,
		"POST /knowledge-bases/{uuid}/search": h.Search, "POST /knowledge-bases/{uuid}/documents/link-from-drive": h.LinkFromDrive,
	} {
		method, path, _ := strings.Cut(pattern, " ")
		mux.Handle(method+" /api/agent-bus/v1"+path, auth(fn))
	}
}
